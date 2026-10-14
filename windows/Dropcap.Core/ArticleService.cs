using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Dropcap.Core;

public enum BlockKind { H, P, Li, Quote, Pre, Img, Cap }

public sealed record Block
{
    [JsonConverter(typeof(LowerEnum<BlockKind>))] public BlockKind Type { get; init; }
    public string? Text { get; init; }
    public string? Src { get; init; }
    public string? Original { get; init; }
}

public sealed record Article
{
    public string? Title { get; init; }
    public string? Byline { get; init; }
    public string? SiteName { get; init; }
    public List<Block> Blocks { get; init; } = new();

    // 본문으로 볼 만한가: 글 블록 2개 이상, 280자 넘게
    public bool LooksLikeArticle => Blocks.Count(b => b.Text is not null) >= 2 && Blocks.Select(b => b.Text).OfType<string>().Sum(t => t.Length) > 280;
}

public enum Stage { Extracting = 0, Original = 1, Translating = 2, Done = 3, Failed = 4 }

// 기사 하나의 "읽을 수 있는 상태"(맥 PreparedArticle 과 같은 모양 — stage 는 숫자)
public sealed record PreparedArticle
{
    public Stage Stage { get; init; } = Stage.Extracting;
    public string Title { get; init; } = "";
    public string OriginalTitle { get; init; } = "";
    public List<Block> Blocks { get; init; } = new();   // 번역됐으면 text=번역, original=원문
    public bool Translated { get; init; }
    public string Engine { get; init; } = "";
    public List<string>? Summary { get; init; }
    public bool Summarizing { get; init; }
    public string Fallback { get; init; } = "";          // 본문을 못 추렸을 때 보여 줄 요약 번역
}

// 본문 추출(Readability.js)을 실제로 돌리는 쪽 — 윈도우 앱은 WebView2 로 구현한다
public interface IArticleExtractor
{
    // 빠른 길(R-01): 받아 둔 HTML 을 스크립트 없이 해석. 바깥 요청은 모두 막는다(S-10).
    Task<Article?> FromHtmlAsync(string html, Uri baseUri);
    // 느린 길(R-02): 사용자가 연 기사만 실제로 띄운다(S-06).
    Task<Article?> FromLiveAsync(Uri url);
}

public static class ArticleExtraction
{
    // 1) 빠른 길: HTML 만 받아 스크립트·그림·글꼴 없이 바로 본문을 추린다(대부분의 언론사는 여기서 끝남)
    // 2) 느린 길: 스크립트로 본문을 그리는 사이트만 실제로 띄운다(allowScripts — 사용자가 직접 연 기사일 때만)
    public static async Task<Article?> ExtractAsync(IArticleExtractor x, string link, bool allowScripts)
    {
        if (!Uri.TryCreate(link, UriKind.Absolute, out var url) || !await UrlSafety.ResolvesPublicAsync(link)) return null;
        try
        {
            if (await FeedService.Shared.FetchWithEncodingAsync(link) is { } got)
            {
                var html = SafeHttp.Decode(got.Data, got.Encoding ?? SniffCharset(got.Data));
                if (await x.FromHtmlAsync(html, url) is { LooksLikeArticle: true } fast) return fast;
            }
        }
        catch (Exception) { }
        if (!allowScripts) return null;
        var slow = await x.FromLiveAsync(url);
        return slow is { LooksLikeArticle: true } ? slow : null;
    }

    // <meta charset="euc-kr"> 처럼 문서 안에 적힌 인코딩을 찾는다
    public static string SniffCharset(byte[] data)
    {
        var head = Encoding.UTF8.GetString(data, 0, Math.Min(data.Length, 4096)).ToLowerInvariant();
        var m = Regex.Match(head, """charset=["']?([a-z0-9_\-]+)""");
        return m.Success ? m.Groups[1].Value : "utf-8";
    }
}

// 기사 하나를 "읽을 수 있는 상태"로 준비한다: 본문 추리기 → 번역 → 3줄 요약.
// 알림이 뜨는 순간 미리 준비해 두고(미리 받기), 한 번 준비한 기사는 디스크에 남겨 다시 열면 바로 뜬다(R-15·R-16).
public sealed class ArticleService
{
    public static ArticleService? Shared { get; set; }

    private readonly IArticleExtractor extractor;
    private readonly Func<IEnumerable<string>> savedLinks;
    private readonly object gate = new();
    private readonly Dictionary<string, PreparedArticle> memory = new();
    private readonly List<string> order = new();
    private readonly Dictionary<string, Task<PreparedArticle>> inflight = new();
    private readonly Dictionary<string, Dictionary<Guid, Action<PreparedArticle>>> listeners = new();
    private readonly string dir;
    public const int DiskLimit = 150;
    public const int MemoryLimit = 40;

    public ArticleService(IArticleExtractor extractor, Func<IEnumerable<string>> savedLinks, string? dir = null)
    {
        this.extractor = extractor;
        this.savedLinks = savedLinks;
        this.dir = dir ?? Path.Combine(Store.Dir, "articles");
        Directory.CreateDirectory(this.dir);
    }

    // 진행 상황을 받아 보기(읽기 창). 돌려받은 id 로 그만 받기.
    public Guid Observe(string link, Action<PreparedArticle> cb)
    {
        var id = Guid.NewGuid();
        lock (gate)
        {
            if (!listeners.TryGetValue(link, out var m)) listeners[link] = m = new();
            m[id] = cb;
        }
        return id;
    }

    public void StopObserving(string link, Guid id) { lock (gate) if (listeners.TryGetValue(link, out var m)) m.Remove(id); }

    public PreparedArticle? Cached(string link)
    {
        lock (gate) if (memory.TryGetValue(link, out var m) && m.Stage == Stage.Done) return m; // 실패한 기사는 다음에 다시 시도
        var f = FileFor(link);
        try
        {
            if (!File.Exists(f)) return null;
            var a = Json.Decode<PreparedArticle>(File.ReadAllText(f));
            if (a is null || a.Stage != Stage.Done) return null;
            lock (gate) memory[link] = a;
            File.SetLastWriteTimeUtc(f, DateTime.UtcNow); // 최근에 쓴 것을 오래 남김
            return a;
        }
        catch { return null; }
    }

    // 이미 준비 중이면 같은 작업을 기다린다
    // interactive: 사용자가 연 기사(스크립트가 필요한 사이트도 띄움). 미리 받기는 false — 스크립트 없이 빠른 길만(S-06).
    public async Task<PreparedArticle> PrepareAsync(NewsItem item, bool interactive = true)
    {
        Task<PreparedArticle>? running;
        lock (gate) inflight.TryGetValue(item.Link, out running);
        if (running is not null && Cached(item.Link) is { Summarizing: true }) return await running; // 요약까지 기다림
        if (Cached(item.Link) is { } c) return c;
        if (running is not null)
        {
            var r = await running;
            // 미리 받기가 스크립트 없이 실패했으면, 사용자가 열었을 때는 제대로 다시 시도
            if (r.Stage == Stage.Failed && interactive)
            {
                lock (gate) if (inflight.TryGetValue(item.Link, out var t) && t == running) inflight.Remove(item.Link);
                return await PrepareAsync(item, true);
            }
            return r;
        }
        var task = RunAsync(item, interactive);
        lock (gate) inflight[item.Link] = task;
        var result = await task;
        lock (gate) if (inflight.TryGetValue(item.Link, out var t2) && t2 == task) inflight.Remove(item.Link);
        return result;
    }

    // 알림이 뜬 소식을 뒤에서 하나씩 미리 준비
    public void Prefetch(IEnumerable<NewsItem> items)
    {
        var list = items.ToList();
        _ = Task.Run(async () =>
        {
            foreach (var it in list.Where(i => i.Id != AppModel.PreviewId && i.Link.Length > 0))
                try { await PrepareAsync(it, interactive: false); } catch { }
        });
    }

    private void Emit(string link, PreparedArticle a)
    {
        List<Action<PreparedArticle>> cbs;
        lock (gate)
        {
            if (!memory.ContainsKey(link))
            {
                order.Add(link);
                if (order.Count > MemoryLimit) { memory.Remove(order[0]); order.RemoveAt(0); } // 메모리에는 최근 40개만
            }
            memory[link] = a;
            cbs = listeners.TryGetValue(link, out var m) ? m.Values.ToList() : new();
        }
        foreach (var cb in cbs) cb(a);
    }

    private async Task<PreparedArticle> RunAsync(NewsItem item, bool interactive)
    {
        await Task.Yield();
        var a = new PreparedArticle { Title = item.DisplayTitle, OriginalTitle = item.Title };
        Emit(item.Link, a);
        var art = await ArticleExtraction.ExtractAsync(extractor, item.Link, interactive);
        if (art is null)
        {
            if (!interactive)
            {
                // 미리 받기 실패는 조용히 넘기고, 열 때 다시 시도
                lock (gate) memory.Remove(item.Link);
                return new PreparedArticle { Stage = Stage.Failed, Title = item.DisplayTitle, OriginalTitle = item.Title };
            }
            a = a with { Fallback = await Translator.Shared.TranslateAsync(item.Summary), Stage = Stage.Failed };
            Emit(item.Link, a);
            return a;
        }
        var artTitle = StripSiteName(FeedParser.NonEmpty(art.Title) ?? item.Title, item.SourceName, item.Title);
        var blocks = art.Blocks.ToList();
        a = a with { OriginalTitle = artTitle, Blocks = blocks };
        var texts = blocks.Select(b => b.Text).OfType<string>().ToList();
        var foreign = Translator.LooksForeign(FeedParser.Prefix(string.Join(" ", texts), 2000));

        if (foreign)
        {
            // 원문을 먼저 보여 주고, 위에서부터 번역으로 바꿔 끼운다(R-04)
            a = a with { Title = item.TitleKo ?? artTitle, Stage = Stage.Translating };
            Emit(item.Link, a);
            var idx = Enumerable.Range(0, blocks.Count).Where(i => blocks[i].Text is not null && blocks[i].Type != BlockKind.Pre).ToList();
            var chunks = new[] { idx.Take(8).ToList(), idx.Skip(8).ToList() };
            for (var n = 0; n < 2; n++)
            {
                var chunk = chunks[n];
                if (chunk.Count == 0 && n != 0) continue;
                var inputs = (n == 0 ? new List<string> { artTitle } : new()).Concat(chunk.Select(i => blocks[i].Text!)).ToList();
                var outs = await Translator.Shared.TranslateManyAsync(inputs);
                var title = a.Title;
                if (n == 0) { title = outs[0]; outs.RemoveAt(0); }
                var nb = a.Blocks.ToList();
                for (var k = 0; k < chunk.Count; k++)
                {
                    var i = chunk[k];
                    nb[i] = nb[i] with { Original = art.Blocks[i].Text, Text = outs[k] };
                }
                a = a with { Title = title, Blocks = nb, Translated = true };
                Emit(item.Link, a);
            }
            a = a with { Engine = Translator.Shared.LastEngine };
        }
        else
        {
            a = a with { Title = artTitle };
        }
        var canSummarize = await Summarizer.AvailableAsync();
        a = a with { Stage = Stage.Done, Summarizing = canSummarize };
        Emit(item.Link, a);
        if (canSummarize)
        {
            a = a with { Summary = await Summarizer.SummarizeAsync(artTitle, texts), Summarizing = false };
            Emit(item.Link, a);
        }
        Save(item.Link, a);
        return a;
    }

    // 웹 문서 제목 끝의 사이트 이름(" - AI타임스", " | The Verge")은 출처가 이미 위에 보이므로 뗀다(맥과 같음)
    public static string StripSiteName(string title, string source, string feedTitle)
    {
        static string Norm(string s) => new(s.ToLowerInvariant().Where(char.IsLetterOrDigit).ToArray());
        foreach (var sep in new[] { " - ", " | ", " – ", " — ", " :: ", " · " })
        {
            var i = title.LastIndexOf(sep, StringComparison.Ordinal);
            if (i < 0) continue;
            var head = title[..i].Trim();
            var tail = title[(i + sep.Length)..].Trim();
            if (head.Length == 0) continue;
            if (Norm(tail) == Norm(source) || Norm(head) == Norm(feedTitle) || (Norm(source).Length > 0 && Norm(tail).Contains(Norm(source)))) return head;
        }
        return title;
    }

    // MARK: 디스크
    public string FileFor(string link)
    {
        var h = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(link)))[..24];
        return Path.Combine(dir, h + ".json");
    }

    private void Save(string link, PreparedArticle a)
    {
        try { Store.AtomicWrite(FileFor(link), Json.Encode(a)); } catch { return; }
        Trim();
    }

    // 오래된 것부터 지워 개수를 지킨다. 저장한 기사는 오프라인으로 읽을 수 있게 지우지 않는다(C-24).
    internal void Trim()
    {
        var files = new DirectoryInfo(dir).GetFiles("*.json");
        if (files.Length <= DiskLimit) return;
        var pinned = savedLinks().Select(l => Path.GetFileName(FileFor(l))).ToHashSet();
        foreach (var f in files.OrderBy(f => f.LastWriteTimeUtc).Where(f => !pinned.Contains(f.Name)).Take(files.Length - DiskLimit))
            try { f.Delete(); } catch { }
    }
}
