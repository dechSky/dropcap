using Dropcap.Core;

namespace Dropcap.Ui;

// 화면에 보내는 기사 한 줄(상단바 창·매거진·스토리 공용). 색·분야 이름은 웹 쪽 CSS(cat-*) 가 정한다.
public sealed record ItemView
{
    public string Key { get; init; } = "";
    public string Title { get; init; } = "";        // 보이는 제목(한국어 있으면 한국어)
    public string Original { get; init; } = "";     // 원제목
    public bool Translated { get; init; }
    public string Link { get; init; } = "";
    public string Source { get; init; } = "";
    public string SourceId { get; init; } = "";
    public string Initial { get; init; } = "";
    public string Color { get; init; } = "#3B82F6";  // 출처 색
    public string Tier { get; init; } = "";
    public string TierLabel { get; init; } = "";
    public string Category { get; init; } = "other"; // model·research…(CSS cat-*)
    public string CategoryLabel { get; init; } = "";
    public string Kind { get; init; } = "article";
    public string KindLabel { get; init; } = "";
    public bool External { get; init; }              // 영상·팟캐스트는 원래 앱·브라우저로
    public int Related { get; init; }
    public List<string> RelatedNames { get; init; } = new();
    public string Time { get; init; } = "";          // 몇 분 전
    public long? Date { get; init; }                 // 유닉스 밀리초(정렬·표시용)
    public string Summary { get; init; } = "";
    public string? Image { get; init; }
    public bool Important { get; init; }
    public bool Read { get; init; }
    public bool Saved { get; init; }
    public string? Paywall { get; init; }            // hard · metered · learned(G-14 자물쇠). 없으면 무료
    public string? PaywallHelp { get; init; }        // 마우스를 올리면 보이는 이유

    // 화면 CSS 에 들어가는 색은 #RRGGBB 만(출처 정보가 깨져도 스타일이 새지 않게)
    public static string SafeColor(string? hex) =>
        hex is { Length: 7 } h && h[0] == '#' && h.Skip(1).All(Uri.IsHexDigit) ? h : "#3B82F6";

    public static ItemView From(NewsItem it, AppModel? m, DateTimeOffset? now = null)
    {
        var src = m?.SourceById(it.SourceId);
        var pw = it.ItemKind == ItemKind.Article && it.Link.Length > 0 ? Core.Paywall.Kind(it.SourceId, it.Link, stats: PaywallBook.Loaded?.Stats) : null;
        return new ItemView
        {
            Key = it.Key, Title = it.DisplayTitle, Original = it.Title, Translated = it.TitleKo is not null && it.TitleKo != it.Title,
            Link = it.Link, Source = it.SourceName, SourceId = it.SourceId, Initial = it.Initial, Color = SafeColor(src?.Color),
            Tier = it.Tier, TierLabel = Resources.TierLabel(it.Tier),
            Category = it.Category.Raw(), CategoryLabel = it.Category.Label(), Kind = it.ItemKind.Raw(), KindLabel = it.ItemKind.Label(),
            External = it.ItemKind.OpensExternally(), Related = it.Related?.Count ?? 0, RelatedNames = it.Related ?? new(),
            Time = RelativeTime.Format(it.Date, now), Date = it.Date?.ToUnixTimeMilliseconds(), Summary = it.Summary,
            Image = it.Image, Important = it.Important == true, Read = m?.IsRead(it) ?? false, Saved = m?.IsSaved(it) ?? false,
            Paywall = pw?.Raw(), PaywallHelp = pw?.Help(),
        };
    }
}

// 상단바·매거진이 함께 쓰는 기사 찾기
public static class Lookup
{
    public static NewsItem? Find(AppModel m, string key, Magazine? mag = null) =>
        m.State.Recent.FirstOrDefault(i => i.Key == key) ?? m.State.Saved.FirstOrDefault(i => i.Key == key)
        ?? (mag is null ? null : mag.Stored(key)?.Item);
}
