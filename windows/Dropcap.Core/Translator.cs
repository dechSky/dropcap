using System.Collections.Concurrent;
using System.Text.Json;

namespace Dropcap.Core;

// 한국어 번역. 윈도우에는 무료 기기 내 번역이 없으므로(T-05 ⊘) 구글 번역 공개 엔드포인트(gtx)를 쓴다.
// 실패하면 원문을 그대로 돌려준다.
public sealed class Translator
{
    public static readonly Translator Shared = new();
    public Translator() { }

    public const string EngineGoogle = "Google 번역";
    public const string EngineNone = "번역 안 함";

    private readonly ConcurrentDictionary<string, string> cache = new();
    public string LastEngine { get; private set; } = EngineNone;

    // 시험에서 네트워크 없이 바꿔 끼우기 위한 자리(text, target) → 번역 또는 null
    internal Func<string, string, Task<string?>>? Backend { get; set; }

    // 오래 켜 둬도 무한히 커지지 않게 4000개를 넘으면 비운다(T-03 — 기사 본문 번역도 여기로 모이므로 이 한 곳에서 지킨다)
    public const int CacheLimit = 4000;
    public int CacheCount => cache.Count;
    public void Remember(string source, string translated)
    {
        if (cache.Count >= CacheLimit) cache.Clear();
        cache[source] = translated;
    }

    // T-01: 한글 비율 20% 미만이면 번역 대상
    public static bool LooksForeign(string text)
    {
        var s = text.Where(c => !char.IsWhiteSpace(c)).ToArray();
        if (s.Length == 0) return false;
        var hangul = s.Count(c => c >= '가' && c <= '힣');
        return (double)hangul / s.Length < 0.2;
    }

    // 한국어 제목을 영어로(같은 소식 비교용). 실패하면 null.
    public async Task<string?[]> ToEnglishAsync(IReadOnlyList<string> texts) =>
        await Task.WhenAll(texts.Select(t => Google(t, "en")));

    public async Task<string> TranslateAsync(string text)
    {
        var src = text.Trim();
        if (!LooksForeign(src)) return text;
        if (cache.TryGetValue(src, out var c)) return c;
        return (await TranslateManyAsync([src])).FirstOrDefault() ?? src;
    }

    public async Task<List<string>> TranslateManyAsync(IReadOnlyList<string> texts) => (await TranslateManyReportingAsync(texts)).Texts;

    // 번역과 함께 '이번 번역에 쓴 엔진'(T-08 · A-24: 앱 전체에 하나인 LastEngine 은 다른 번역이 동시에 돌면 틀리게 보였다).
    // 윈도우는 엔진이 구글 하나라 새로 번역했거나 캐시(=구글 번역 결과)에서 꺼낸 것이 있으면 구글, 번역할 것이 없었으면 '번역 안 함'.
    public async Task<(List<string> Texts, string Engine)> TranslateManyReportingAsync(IReadOnlyList<string> texts)
    {
        var cached = texts.Any(t => cache.ContainsKey(t));
        var (o, fresh) = await TranslateManyRawAsync(texts);
        return (o, fresh || cached ? EngineGoogle : EngineNone);
    }

    // 여러 문단을 한 번에. 순서를 지킨다(T-02). 새로 번역했는지를 함께 돌려준다
    private async Task<(List<string> Texts, bool Fresh)> TranslateManyRawAsync(IReadOnlyList<string> texts)
    {
        var result = texts.ToList();
        var todo = new List<int>();
        for (var i = 0; i < texts.Count; i++)
        {
            if (cache.TryGetValue(texts[i], out var hit)) result[i] = hit;
            else if (LooksForeign(texts[i])) todo.Add(i);
        }
        if (todo.Count == 0) return (result, false);

        // 문단 여러 개를 빈 줄로 이어 한 번에 보내고(요청 수를 줄여 빠르게), 묶음들은 동시에 보낸다.
        // 돌아온 문단 수가 안 맞으면 그 묶음만 문단별로 다시 보낸다.
        var batches = new List<List<int>> { new() };
        var size = 0;
        foreach (var i in todo)
        {
            var n = texts[i].Length;
            if (size + n > 3800 && batches[^1].Count > 0) { batches.Add(new()); size = 0; }
            batches[^1].Add(i);
            size += n + 2;
        }
        var outs = await Task.WhenAll(batches.Where(b => b.Count > 0).Select(async batch =>
        {
            var joined = string.Join("\n\n", batch.Select(i => texts[i].Replace("\n", " ")));
            if (await Google(joined, "ko") is { } got)
            {
                var parts = got.Split("\n\n").Select(p => p.Trim()).Where(p => p.Length > 0).ToList();
                if (parts.Count == batch.Count) return batch.Zip(parts).ToList();
            }
            var one = new List<(int, string)>();
            foreach (var i in batch) if (await Google(texts[i], "ko") is { } t) one.Add((i, t));
            return one;
        }));
        foreach (var pairs in outs)
            foreach (var (i, t) in pairs) { result[i] = t; Remember(texts[i], t); }
        LastEngine = EngineGoogle;
        return (result, true);
    }

    // 한 번에 보낼 수 있는 길이(구글 공개 엔드포인트). 이보다 긴 문단은 문장 단위로 나눠 보내고 이어 붙인다(T-08 · A-25: 예전엔 뒤가 잘렸다)
    public const int RequestLimit = 4500;

    private async Task<string?> Google(string text, string target)
    {
        if (text.Length <= RequestLimit) return await GoogleOnce(text, target);
        var parts = new List<string>();
        foreach (var chunk in SentenceChunks(text, RequestLimit))
        {
            if (await GoogleOnce(chunk, target) is not { } t) return null;
            parts.Add(t);
        }
        return string.Join(" ", parts);
    }

    // 문장 경계에서 max 글자 이하로 묶는다. 한 문장이 max 보다 길면 그 문장만 max 씩 자른다. 이어 붙이면 원문 그대로(맥 sentenceChunks).
    // 맥은 기기 내 문장 나누기(NLTokenizer), 여기는 문장 끝 부호(. ! ? 。 ！ ？ …) 뒤 공백에서 나눈다(공백은 앞 문장에 붙임)
    public static List<string> SentenceChunks(string text, int max)
    {
        if (text.Length <= max) return [text];
        var sentences = System.Text.RegularExpressions.Regex.Split(text, @"(?<=[.!?。！？…][""'”’)\]]?\s)").Where(s => s.Length > 0).ToList();
        var o = new List<string>();
        var cur = new System.Text.StringBuilder();
        foreach (var s in sentences)
        {
            if (s.Length > max)
            {
                if (cur.Length > 0) { o.Add(cur.ToString()); cur.Clear(); }
                var rest = s;
                while (rest.Length > max) { o.Add(rest[..max]); rest = rest[max..]; }
                cur.Append(rest);
            }
            else if (cur.Length + s.Length > max) { o.Add(cur.ToString()); cur.Clear().Append(s); }
            else cur.Append(s);
        }
        if (cur.Length > 0) o.Add(cur.ToString());
        return o;
    }

    private async Task<string?> GoogleOnce(string text, string target)
    {
        if (Backend is { } b) return await b(text, target);
        var q = FeedParser.Prefix(text, RequestLimit);
        var url = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=" + target + "&dt=t&q=" + Uri.EscapeDataString(q);
        try
        {
            var r = await SafeHttp.GetAsync(url, timeout: TimeSpan.FromSeconds(15), maxBody: 2L << 20);   // 번역 응답은 2MB 까지(보안 점검)
            if (r.Status != 200) return null;
            using var doc = JsonDocument.Parse(r.Body);
            if (doc.RootElement.ValueKind != JsonValueKind.Array || doc.RootElement.GetArrayLength() == 0) return null;
            var segs = doc.RootElement[0];
            if (segs.ValueKind != JsonValueKind.Array) return null;
            var sb = new System.Text.StringBuilder();
            foreach (var seg in segs.EnumerateArray())
                if (seg.ValueKind == JsonValueKind.Array && seg.GetArrayLength() > 0 && seg[0].ValueKind == JsonValueKind.String)
                    sb.Append(seg[0].GetString());
            return sb.Length == 0 ? null : sb.ToString();
        }
        catch
        {
            return null;
        }
    }
}
