namespace Dropcap.Core;

// 유료 기사 표시(G-14)와 같은 소식의 무료 보도 안내(G-15 · D-9). 맥 Core/Paywall.swift 와 같은 규칙·수치.
// ① sources.json 의 paywall(hard·metered) ② 직접 추가한 출처는 주소의 도메인(알려진 곳) ③ 사용자가 연 기사의 본문 추리기 결과를
// 출처별로 쌓아 실패율이 높으면 '막힌 곳'으로 배운다. 원문 링크는 언제나 남긴다.
public enum PaywallKind { Hard, Metered, Learned, Teaser } // Teaser: 이 기사를 미리 받아 보니 맛보기(앞부분만)였음 — 출처·피드 표시보다 앞선다

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
        PaywallKind.Teaser => "앞부분만 공개된 기사",
        _ => "자주 막히는 곳",
    };

    // 목록·카드에서 자물쇠 옆에 붙는 짧은 글(맛보기만 — 다른 자물쇠와 구분)
    public static string? ShortText(this PaywallKind k) => k == PaywallKind.Teaser ? "앞부분만" : null;

    // 열기 전에 다른 보도를 먼저 권할 만큼 막히는가
    public static bool Blocks(this PaywallKind k) => k != PaywallKind.Metered;

    // 마우스를 올리면 보이는 이유
    public static string Help(this PaywallKind k) => k == PaywallKind.Teaser
        ? "미리 받아 보니 사이트가 앞부분만 공개한 기사예요 — 열면 같은 소식의 무료 보도를 먼저 권합니다"
        : k.Label() + (k.Blocks() ? " — 열면 같은 소식의 무료 보도를 먼저 권합니다" : "");
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

    // paid: 피드가 이 기사에 적은 표시(NewsItem.Paid) — 출처 값보다 앞선다. true 면 구독해야만(Hard), false 면 무료로 풀린 기사
    // teaser: 이 기사를 받아 보니 맛보기였음(PaywallBook.Teasers) — 무엇보다 앞선다
    public static PaywallKind? Kind(string sourceId, string link, Dictionary<string, SourceMeta>? meta = null,
                                    IReadOnlyDictionary<string, Database.ExtractStat>? stats = null, bool? paid = null, bool teaser = false)
    {
        if (teaser) return PaywallKind.Teaser;
        if (paid is { } pd) return pd ? PaywallKind.Hard : null;
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

    // 길이와 상관없이 맛보기로 보는 강한 문구(STAT+ 맛보기는 구독 권유 줄까지 1,500자를 넘는다)
    public static readonly System.Text.RegularExpressions.Regex StrongWall = new(
        @"exclusive (?:to|for) [^.]{0,30}subscribers|read the rest of this (?:story|article)|this article is for (?:paid )?subscribers|unlock this article|구독자 전용|유료 회원 전용|한경 프리미엄9?의 모든 콘텐츠",
        System.Text.RegularExpressions.RegexOptions.IgnoreCase);

    // 맛보기(유료벽 뒤 앞부분만)인가 — 맥 Paywall.isTeaser(mac/READER-CUT.md C). 지금의 문구 판정에 더해
    // 사이트가 유료라고 적었고(isAccessibleForFree=false · 한경 articlePayment) 본문이 1,500자 미만, 하드 유료 출처인데 2,500자 미만, 끝쪽에 강한 문구
    // ldBody: 사이트가 ld+json articleBody 로 적은 본문 글자 수. 우리 본문과 거의 같으면(±10%) 그 길이가 기사 전부다 —
    // 늘 isAccessibleForFree=false 라고 적지만 전문을 주는 사이트(Verge)의 짧은 기사를 맛보기로 잘못 보지 않게 '유료+1,500자' 규칙을 쓰지 않는다
    // (하드 유료 2,500자·강한 문구·구독 권유 문구 판정은 그대로 — 맥 ld-body-match)
    public const double LdBodySlack = 0.1;
    public static bool MatchesSiteBody(int length, int? ldBody) =>
        ldBody is > 0 && Math.Abs(length - ldBody.Value) <= ldBody.Value * LdBodySlack;

    public static bool IsTeaser(IReadOnlyList<Block> blocks, bool? paid, PaywallKind? kind, int? ldBody = null)
    {
        if (LooksBlocked(blocks)) return true;
        var texts = blocks.Select(b => b.Original ?? b.Text).OfType<string>().ToList();
        var length = texts.Sum(t => t.Length);
        if (StrongWall.IsMatch(string.Join(" ", texts.TakeLast(4)))) return true;
        // ld 본문과는 군더더기(기자 소개·'Follow topics…')를 뺀 길이로도 견준다(Verge: 뺀 뒤 899자 = ld 902자)
        var cleaned = BodyCleanup.DropJunk(blocks).Select(b => b.Original ?? b.Text).OfType<string>().Sum(t => t.Length);
        if (paid == true && length < 1500 && !MatchesSiteBody(length, ldBody) && !MatchesSiteBody(cleaned, ldBody)) return true;
        if (kind == PaywallKind.Hard && length < 2500) return true;
        return false;
    }

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
                                                  IReadOnlyDictionary<string, Database.ExtractStat>? stats = null, int limit = 3,
                                                  IReadOnlySet<string>? teasers = null)
    {
        var rank = new Dictionary<string, int> { ["lab"] = 0, ["kr"] = 1, ["press"] = 2 };
        var seen = new HashSet<string> { item.SourceId };
        return story
            .Where(s => s.Key != item.Key && !hidden.Contains(s.SourceId) && s.Link.Length > 0 && s.ItemKind == ItemKind.Article
                        && Kind(s.SourceId, s.Link, meta, stats, s.Paid, teasers?.Contains(s.Link) == true) is null)
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
    // 맛보기로 판정된 기사 주소(DB teasers) — 목록·카드·물방울이 열기 전부터 '앞부분만'을 보이게. 바뀌면 TeasersChanged
    private volatile IReadOnlySet<string> teasers;
    public IReadOnlySet<string> Teasers => teasers;
    public event Action? TeasersChanged;

    public PaywallBook(Database db)
    {
        this.db = db;
        try { stats = db.ExtractStats(); } catch { stats = new Dictionary<string, Database.ExtractStat>(); }
        try { teasers = db.TeaserLinks(); } catch { teasers = new HashSet<string>(); }
    }

    // 화면 표시용: 맛보기 판정 > 피드의 기사 표시 > 출처 값 > 배운 막힘
    public PaywallKind? Kind(NewsItem item)
    {
        if (item.ItemKind != ItemKind.Article || item.Link.Length == 0) return null;
        return Paywall.Kind(item.SourceId, item.Link, stats: stats, paid: item.Paid, teaser: teasers.Contains(item.Link));
    }

    // 맛보기 판정(Paywall.IsTeaser)에 넘기는 값: 지난 판정은 빼고 피드·출처만 본다(다시 받을 때 지난 판정에 끌려가지 않게)
    public PaywallKind? SourceKind(NewsItem item)
    {
        if (item.ItemKind != ItemKind.Article || item.Link.Length == 0) return null;
        return Paywall.Kind(item.SourceId, item.Link, stats: stats, paid: item.Paid);
    }

    // 본문을 받은 기사(미리 받기 포함)의 맛보기 판정을 남긴다 — 맛보기가 아니면 지난 기록을 지운다
    public void RecordTeaser(NewsItem item, bool teaser)
    {
        if (item.Id == AppModel.PreviewId || item.Link.Length == 0 || teaser == teasers.Contains(item.Link)) return;
        try { db.MarkTeaser(item.Link, teaser); } catch { return; }
        var next = new HashSet<string>(teasers);
        if (teaser) next.Add(item.Link); else next.Remove(item.Link);
        teasers = next;
        TeasersChanged?.Invoke();
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
        return Paywall.FreeAlternatives(item, magazine.StoryItems(c), hidden, stats: stats, teasers: teasers);
    }
}
