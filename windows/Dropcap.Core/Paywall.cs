namespace Dropcap.Core;

// 유료 기사 표시(G-14)와 같은 소식의 무료 보도 안내(G-15 · D-9). 맥 Core/Paywall.swift 와 같은 규칙·수치.
// ① sources.json 의 paywall(hard·metered) ② 직접 추가한 출처는 주소의 도메인(알려진 곳) ③ 사용자가 연 기사의 본문 추리기 결과를
// 출처별로 쌓아 실패율이 높으면 '막힌 곳'으로 배운다. 원문 링크는 언제나 남긴다.
public enum PaywallKind { Hard, Metered, Learned }

public static class PaywallKinds
{
    public static string Raw(this PaywallKind k) => k.ToString().ToLowerInvariant();

    public static PaywallKind? Parse(string? raw) => raw switch
    {
        "hard" => PaywallKind.Hard,
        "metered" => PaywallKind.Metered,
        _ => null,
    };

    public static string Label(this PaywallKind k) => k switch
    {
        PaywallKind.Hard => "유료 기사",
        PaywallKind.Metered => "일부 유료(무료 건수 제한)",
        _ => "자주 막히는 곳",
    };

    // 열기 전에 다른 보도를 먼저 권할 만큼 막히는가
    public static bool Blocks(this PaywallKind k) => k != PaywallKind.Metered;

    // 마우스를 올리면 보이는 이유
    public static string Help(this PaywallKind k) => k.Label() + (k.Blocks() ? " — 열면 같은 소식의 무료 보도를 먼저 권합니다" : "");
}

public static class Paywall
{
    // sources.json 에 없는(직접 추가한) 출처도 알아보게: 널리 알려진 유료 매체
    public static readonly IReadOnlyDictionary<string, PaywallKind> KnownDomains = new Dictionary<string, PaywallKind>
    {
        ["ft.com"] = PaywallKind.Hard, ["economist.com"] = PaywallKind.Hard, ["wsj.com"] = PaywallKind.Hard, ["bloomberg.com"] = PaywallKind.Hard,
        ["barrons.com"] = PaywallKind.Hard, ["thetimes.co.uk"] = PaywallKind.Hard, ["thetimes.com"] = PaywallKind.Hard,
        ["theinformation.com"] = PaywallKind.Hard, ["nikkei.com"] = PaywallKind.Hard, ["asia.nikkei.com"] = PaywallKind.Hard,
        ["nytimes.com"] = PaywallKind.Metered, ["washingtonpost.com"] = PaywallKind.Metered, ["theatlantic.com"] = PaywallKind.Metered,
        ["newyorker.com"] = PaywallKind.Metered, ["wired.com"] = PaywallKind.Metered, ["marketwatch.com"] = PaywallKind.Metered,
        ["telegraph.co.uk"] = PaywallKind.Metered, ["newscientist.com"] = PaywallKind.Metered, ["statnews.com"] = PaywallKind.Metered,
        ["businessinsider.com"] = PaywallKind.Metered, ["foreignpolicy.com"] = PaywallKind.Metered, ["hbr.org"] = PaywallKind.Metered,
    };

    // 배워서 '막히는 곳'으로 보는 기준: 5번 이상 열었고 60% 넘게 막힘
    public const int LearnMinTries = 5;
    public const double LearnFailRate = 0.6;

    public static PaywallKind? DomainKind(string link)
    {
        if (!Uri.TryCreate(link, UriKind.Absolute, out var u) || string.IsNullOrEmpty(u.Host)) return null;
        var host = u.Host.ToLowerInvariant();
        if (host.StartsWith("www.")) host = host[4..];
        // 하위 도메인(edition.ft.com 등)은 뒤에서부터 맞춰 본다
        var parts = host.Split('.').ToList();
        while (parts.Count >= 2)
        {
            if (KnownDomains.TryGetValue(string.Join('.', parts), out var k)) return k;
            parts.RemoveAt(0);
        }
        return null;
    }

    public static PaywallKind? Kind(string sourceId, string link, Dictionary<string, SourceMeta>? meta = null,
                                    IReadOnlyDictionary<string, Database.ExtractStat>? stats = null)
    {
        meta ??= Sections.Meta;
        if (meta.TryGetValue(sourceId, out var m) && PaywallKinds.Parse(m.Paywall) is { } p) return p;
        if (DomainKind(link) is { } d) return d;
        if (stats is not null && stats.TryGetValue(sourceId, out var s) && s.Tries >= LearnMinTries && s.FailRate >= LearnFailRate) return PaywallKind.Learned;
        return null;
    }

    // 본문은 추렸지만 맛보기만 나오고 구독을 권하는 글(유료벽 뒤)인가
    public static readonly string[] WallPhrases =
    [
        "subscribe to continue", "subscribe to read", "subscribers only", "subscriber-only", "to continue reading",
        "sign in to continue", "already a subscriber", "create a free account to continue", "this article is for subscribers",
        "unlock this article", "become a member to read", "유료 회원", "구독자 전용", "로그인 후 이용", "유료 기사", "프리미엄 회원",
    ];

    public static bool LooksBlocked(IEnumerable<Block> blocks)
    {
        var texts = blocks.Select(b => b.Text).OfType<string>().ToList();
        if (texts.Sum(t => t.Length) >= 1500) return false; // 본문이 충분하면 끝의 구독 안내 문구는 무시
        var lower = string.Join(" ", texts).ToLowerInvariant();
        return WallPhrases.Any(lower.Contains);
    }

    // 같은 소식 중 열리는 보도: 유료가 아니고(배운 막힘 포함), 숨긴 출처가 아니고, 자기 자신이 아닌 것. 공식 발표 > 국내 > 언론, 최신 순
    public static List<NewsItem> FreeAlternatives(NewsItem item, IEnumerable<NewsItem> story, IReadOnlySet<string> hidden,
                                                  Dictionary<string, SourceMeta>? meta = null,
                                                  IReadOnlyDictionary<string, Database.ExtractStat>? stats = null, int limit = 3)
    {
        var rank = new Dictionary<string, int> { ["lab"] = 0, ["kr"] = 1, ["press"] = 2 };
        var seen = new HashSet<string> { item.SourceId };
        return story
            .Where(s => s.Key != item.Key && !hidden.Contains(s.SourceId) && s.Link.Length > 0 && s.ItemKind == ItemKind.Article
                        && Kind(s.SourceId, s.Link, meta, stats) is null)
            .OrderBy(s => rank.GetValueOrDefault(s.Tier, 3)).ThenByDescending(s => s.Date ?? DateTimeOffset.MinValue)
            .Where(s => seen.Add(s.SourceId))
            .Take(limit).ToList();
    }
}

// 앱 안에서 쓰는 쪽: 출처별 기록을 기억해 두고 화면(자물쇠)·읽기 창(무료 보도 권하기)에 알려 준다
public sealed class PaywallBook
{
    private static PaywallBook? shared;
    private static readonly object sharedGate = new();
    public static PaywallBook Shared { get { lock (sharedGate) return shared ??= new PaywallBook(Database.Shared); } set { lock (sharedGate) shared = value; } }

    // 이미 만들어 둔 것(없으면 null — 시험에서 DB 를 만들지 않게 화면 데이터는 이것만 본다)
    public static PaywallBook? Loaded { get { lock (sharedGate) return shared; } }

    private readonly Database db;
    private volatile IReadOnlyDictionary<string, Database.ExtractStat> stats;
    public IReadOnlyDictionary<string, Database.ExtractStat> Stats => stats;

    public PaywallBook(Database db)
    {
        this.db = db;
        try { stats = db.ExtractStats(); } catch { stats = new Dictionary<string, Database.ExtractStat>(); }
    }

    public PaywallKind? Kind(NewsItem item)
    {
        if (item.ItemKind != ItemKind.Article || item.Link.Length == 0) return null;
        return Paywall.Kind(item.SourceId, item.Link, stats: stats);
    }

    // 사용자가 연 기사의 결과(미리 받기는 스크립트 없이 해서 실패가 잦으므로 세지 않는다 — 부르는 쪽이 interactive 일 때만)
    public void Record(NewsItem item, bool failed, bool blocked)
    {
        if (item.Id == AppModel.PreviewId || item.SourceId.Length == 0) return;
        try
        {
            db.RecordExtract(item.SourceId, failed, blocked);
            stats = db.ExtractStats();
        }
        catch { }
    }

    // 같은 스토리에서 무료로 읽을 수 있는 보도
    public List<NewsItem> Alternatives(NewsItem item, Magazine magazine, IReadOnlySet<string> hidden)
    {
        if (magazine.ClusterId(item.Key) is not { } c) return new();
        return Paywall.FreeAlternatives(item, magazine.StoryItems(c), hidden, stats: stats);
    }
}
