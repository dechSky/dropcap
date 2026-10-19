using Dropcap.Core;
using SkiaSharp;

namespace Dropcap.Ui;

// 사진 점수 재기(M-24): 안전 로더로 받은 사진을 풀어 48×48·96×96 으로 줄이고(색 다양성·단색 바탕), 글자 면적은 앱이 준 글자 인식으로.
// 계산식은 Core 의 PhotoQuality(맥과 같음). 글자 인식이 없으면(맥에서 시험) 글자 면적 0 으로 본다.
public static class PhotoScorer
{
    // 앱(윈도우)이 정한다: 사진(JPEG 바이트) → 읽히는 글자가 덮는 면적 0~1. Windows.Media.Ocr(한·영 등 설치된 언어)
    public static Func<byte[], Task<double>>? TextRatio { get; set; }

    public static async Task<PhotoQuality.Score?> ScoreAsync(string url)
    {
        var bytes = await ImageLoader.Shared.JpegAsync(url);
        if (bytes is null) return null;
        var text = 0.0;
        if (TextRatio is { } t) { try { text = await t(bytes); } catch { text = 0; } }
        return await Task.Run(() => Score(bytes, text));
    }

    public static PhotoQuality.Score? Score(byte[] bytes, double textRatio)
    {
        using var codec = SKCodec.Create(new MemoryStream(bytes));   // 그림이 아니면 null
        if (codec is null || !ImageLoader.SafeDimensions(codec.Info)) return null;   // 압축 폭탄(보안 점검)
        using var bmp = SKBitmap.Decode(codec);
        if (bmp is null) return null;
        var colors = PhotoQuality.ColorVariety(Pixels(bmp, PhotoQuality.ColorSide));
        var flat = PhotoQuality.Flatness(Pixels(bmp, PhotoQuality.FlatSide));
        return PhotoQuality.Combine(PhotoQuality.AspectScore(bmp.Width, bmp.Height), PhotoQuality.SizeScore(bmp.Width, bmp.Height), textRatio, colors, flat);
    }

    // n×n RGBA 바이트(비율 무시하고 꽉 채워 줄임 — 맥 CGContext.draw 와 같음)
    private static byte[] Pixels(SKBitmap b, int n)
    {
        using var small = b.Resize(new SKImageInfo(n, n, SKColorType.Rgba8888, SKAlphaType.Premul), new SKSamplingOptions(SKFilterMode.Linear, SKMipmapMode.Linear));
        return small?.Bytes ?? [];
    }
}

// 분야의 '오늘 얼굴' 사진(분야 고르기 카드·매거진 분야 머리): 매거진 기록에서 그 분야의 최근 사진 기사, 없으면(처음 실행)
// 그 분야 기본 출처 피드를 바로 받아 고른다. 사진 점수(화면 캡처·글자 그림·로고 거름)를 넘는 첫 사진. 한 번 고른 사진은 실행 동안 기억.
public sealed class SectionPhotos
{
    public static SectionPhotos Shared { get; } = new();
    private readonly Dictionary<string, string> chosen = new();
    private readonly HashSet<string> loading = new();
    private readonly object gate = new();
    public event Action? Changed;

    // 고른 사진 주소(없으면 null — 화면은 색면만)
    public string? Url(string section) { lock (gate) return chosen.GetValueOrDefault(section); }

    public IReadOnlyDictionary<string, string> All { get { lock (gate) return new Dictionary<string, string>(chosen); } }

    // 시험에서 바꿔 끼우는 자리: 최근 기록 읽기 · 사진 고르기 · 그 분야 피드 받기
    internal Func<List<NewsItem>> Recent { get; set; } = () => Database.Shared.Items(DateTimeOffset.Now.AddDays(-3), limit: 3000).Select(x => x.Item).ToList();
    internal Func<IEnumerable<NewsItem>, Task<string?>> Pick { get; set; } = items => PickAsync(items);
    internal Func<string, Task<List<NewsItem>>> Feed { get; set; } = FeedItemsAsync;

    // 분야마다 한 번씩 찾는다(이미 찾았거나 찾는 중이면 건너뜀).
    // 최근 기록(3000건)은 한 번만 읽어 분야마다 나눠 쓴다 — 예전엔 분야마다(11번) 3000건씩 읽고 풀었다
    public void Load(IEnumerable<string> sections)
    {
        var want = new List<string>();
        foreach (var s in sections)
            lock (gate) { if (!chosen.ContainsKey(s) && loading.Add(s)) want.Add(s); }
        if (want.Count == 0) return;
        _ = Task.Run(async () =>
        {
            Dictionary<string, List<NewsItem>> bySection;
            try { bySection = Candidates(Recent(), want); }
            catch { bySection = new(); }
            await Task.WhenAll(want.Select(s => Task.Run(async () =>
            {
                try
                {
                    var url = await Pick(bySection.GetValueOrDefault(s) ?? new());
                    if (url is null) url = await Pick(await Feed(s));
                    if (url is null) return;
                    lock (gate) chosen[s] = url;
                    Changed?.Invoke();
                }
                catch { }
                finally { lock (gate) loading.Remove(s); }
            })));
        });
    }

    // 분야마다 그 분야 칩이 달린 최근 기사(기록 순서 그대로)
    internal static Dictionary<string, List<NewsItem>> Candidates(IEnumerable<NewsItem> recent, IReadOnlyCollection<string> sections)
    {
        var want = sections.ToHashSet();
        var o = new Dictionary<string, List<NewsItem>>();
        foreach (var it in recent)
            foreach (var c in it.SectionChips())
                if (want.Contains(c))
                {
                    if (!o.TryGetValue(c, out var list)) o[c] = list = new();
                    list.Add(it);
                }
        return o;
    }

    // 앞의 사진들을 재 가며(최대 limit 장) 기준을 넘는 첫 사진. 잰 점수는 DB 에 남긴다. 기준 밑 사진은 대신 쓰지 않는다.
    public static async Task<string?> PickAsync(IEnumerable<NewsItem> items, int limit = 6)
    {
        var cands = items.Where(i => PhotoQuality.Usable(i.Image)).Select(i => i.Image!).Distinct().Take(limit).ToList();
        if (cands.Count == 0) return null;
        var known = Database.Shared.ImageScores(cands);
        foreach (var url in cands)
        {
            if (known.TryGetValue(url, out var k))
            {
                if (PhotoQuality.Good(k) && await ImageLoader.Shared.JpegAsync(url) is not null) return url;
                continue;
            }
            if (await PhotoScorer.ScoreAsync(url) is not { } sc) continue;
            Database.Shared.SaveImageScore(url, sc);
            if (PhotoQuality.Good(sc.Total)) return url;
        }
        return null;
    }

    // 그 분야 기본(켤) 출처부터 차례로 받은 글들(사진 있는 글이 4개 나올 때까지 최대 세 곳)
    private static async Task<List<NewsItem>> FeedItemsAsync(string section)
    {
        var ids = Sections.SourcesIn(section).OrderBy(m => m.DefaultOn == true ? 0 : 1).Select(m => m.Id).ToList();
        var o = new List<NewsItem>();
        foreach (var id in ids.Take(3))
        {
            if (Resources.Config.Sources.FirstOrDefault(x => x.Id == id) is not { } src) continue;
            try { o.AddRange(await FeedService.Shared.ItemsAsync(src, conditional: false) ?? new()); } catch { continue; }
            if (o.Count(i => PhotoQuality.Usable(i.Image)) >= 4) break;
        }
        return o;
    }

    // 분야 이름의 영문 표기(유리 카드 위의 작은 글자) — 맥 SectionCardLab.english 와 같음
    public static string English(string id) => id switch
    {
        "politics" => "POLITICS", "economy" => "ECONOMY", "society" => "SOCIETY", "world" => "WORLD", "tech" => "TECH", "ai" => "AI",
        "science" => "SCIENCE", "life" => "LIFE · HEALTH", "culture" => "CULTURE", "sports" => "SPORTS", "climate" => "CLIMATE",
        _ => id.ToUpperInvariant(),
    };
}
