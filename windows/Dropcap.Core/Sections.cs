using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Dropcap.Core;

// 일반 뉴스 분야(정치·경제·…·AI). shared/categories.json 을 읽고, 없으면 같은 내용의 기본값을 쓴다(G-01, 맥 Sections.swift 와 같음).
// AI 하위 분류(모델·연구·정책·투자·보안)는 Categories(ai-topics.json)로 남는다.
public sealed record NewsSection(string Id, string Name, string Symbol, string Color, bool? Flow = null, bool? More = null)
{
    public bool IsFlow => Flow == true;     // 분야가 아니라 흐름(주요 뉴스)
    public bool IsMore => More == true;     // 처음 고르기 화면의 '더 보기'
    public string Icon => Sections.IconFor(Symbol);
}

// sources.json 출처 항목의 분야 관련 필드
public sealed record SourceMeta(string Id, string? Section = null, string? Lang = null, string? Region = null, string? Tier = null, bool? DefaultOn = null, string? Name = null, string? Paywall = null);

public static class Sections
{
    public const string Top = "top", Ai = "ai";

    public static readonly IReadOnlyList<NewsSection> Builtin =
    [
        new("top", "주요 뉴스", "star.fill", "#FF9F0A", Flow: true),
        new("politics", "정치", "building.columns", "#5E5CE6"),
        new("economy", "경제", "chart.line.uptrend.xyaxis", "#30C759"),
        new("society", "사회", "person.3", "#FF6B35"),
        new("world", "국제", "globe.asia.australia", "#0A84FF"),
        new("tech", "IT", "desktopcomputer", "#64D2FF"),
        new("ai", "AI", "sparkles", "#BF5AF2"),
        new("science", "과학", "atom", "#32ADE6"),
        new("life", "생활·건강", "heart.text.square", "#FF375F"),
        new("culture", "문화·연예", "theatermasks", "#FFD60A"),
        new("sports", "스포츠", "sportscourt", "#34C759"),
        new("climate", "기후·환경", "leaf", "#30D158", More: true),
    ];

    // 맥 SF Symbols 이름 → 이 판의 아이콘 이름(web/ui.js · Toast/Icons.cs)
    private static readonly Dictionary<string, string> SymbolIcons = new()
    {
        ["star.fill"] = "star.fill", ["building.columns"] = "cat.policy", ["chart.line.uptrend.xyaxis"] = "cat.business",
        ["person.3"] = "people", ["globe.asia.australia"] = "globe", ["desktopcomputer"] = "desktop", ["sparkles"] = "sparkles",
        ["atom"] = "atom", ["heart.text.square"] = "heart", ["theatermasks"] = "masks", ["sportscourt"] = "sport", ["leaf"] = "leaf",
    };
    public static string IconFor(string symbol) => SymbolIcons.GetValueOrDefault(symbol, "cat.other");

    private sealed record FileShape(List<NewsSection>? Sections);

    public static IReadOnlyList<NewsSection>? Load(string path)
    {
        try
        {
            var f = JsonSerializer.Deserialize<FileShape>(File.ReadAllText(path), Json.Options);
            return f?.Sections is { Count: > 0 } s ? s : null;
        }
        catch { return null; }
    }

    public static Dictionary<string, SourceMeta> LoadMeta(string path)
    {
        try
        {
            var o = JsonNode.Parse(File.ReadAllText(path)) as JsonObject;
            var list = o?["sources"]?.Deserialize<List<SourceMeta>>(Json.Options) ?? new();
            var d = new Dictionary<string, SourceMeta>();
            foreach (var m in list) d.TryAdd(m.Id, m);
            return d;
        }
        catch { return new(); }
    }

    private static IReadOnlyList<NewsSection>? all;
    private static Dictionary<string, SourceMeta>? meta;
    public static IReadOnlyList<NewsSection> All => all ??= Load(Resources.PathOf("categories.json")) ?? Builtin;
    public static Dictionary<string, SourceMeta> Meta => meta ??= LoadMeta(Resources.PathOf("sources.json"));

    // 시험에서 다른 자료로 바꿀 때
    internal static void Use(IReadOnlyList<NewsSection>? sections, Dictionary<string, SourceMeta>? m) { all = sections; meta = m; placeCache.Clear(); }

    public static NewsSection? ById(string? id) => id is null ? null : All.FirstOrDefault(s => s.Id == id);
    public static string Name(string id) => ById(id)?.Name ?? id;
    public static int Order(string id) { var i = All.ToList().FindIndex(s => s.Id == id); return i < 0 ? 99 : i; }
    // 처음 고르기 화면에 보이는 분야(흐름 제외)
    public static IEnumerable<NewsSection> Pickable => All.Where(s => !s.IsFlow);

    // 출처의 분야: sources.json 의 section → 없으면(예전 판 sources.json·추천 채널) AI 시절 출처이므로 ai.
    // 사용자가 주소로 직접 추가한 출처는 모른다(null) → 기사 낱말로 정한다.
    public static string? SectionOfSource(string id, Dictionary<string, SourceMeta>? m = null)
    {
        m ??= Meta;
        if (m.TryGetValue(id, out var s) && s.Section is { } sec) return sec;
        if (m.ContainsKey(id) || id.StartsWith("cat-", StringComparison.Ordinal)) return Ai;
        return null;
    }

    public static string RegionOf(string sourceId, string tier, Dictionary<string, SourceMeta>? m = null) =>
        (m ?? Meta).TryGetValue(sourceId, out var s) && s.Region is { } r ? r : (tier == "kr" ? "kr" : "intl");

    public static List<SourceMeta> SourcesIn(string section, Dictionary<string, SourceMeta>? m = null) =>
        (m ?? Meta).Values.Where(s => s.Section == section).OrderBy(s => s.Name ?? s.Id, StringComparer.Ordinal).ToList();

    // MARK: 기사의 분야(G-02)
    // 대표 분야 하나 + 칩 여러 개. 출처의 분야가 1순위, 출처가 '주요'·모름이면 낱말 규칙으로 보충.
    // AI 는 다른 분야 글에서도 끌어온다(aiPattern).
    public sealed record Placement(string Primary, List<string> Chips);

    public static Placement Place(NewsItem it, Dictionary<string, SourceMeta>? m = null, Regex? aiRegex = null)
    {
        aiRegex ??= Resources.AiRegex;
        var text = $"{it.Title} {it.TitleKo ?? ""} {it.Summary}";
        var primary = SectionOfSource(it.SourceId, m);
        if (primary is null || primary == Top) primary = Classify(text) ?? primary ?? Top;
        var chips = new List<string> { primary };
        if (primary != Ai && aiRegex.IsMatch(text)) chips.Add(Ai);
        if (primary != Top && Classify(text) is { } g && g != primary && !chips.Contains(g) && g != Ai) chips.Add(g);
        return new Placement(primary, chips);
    }

    // 기사마다 한 번만 정해 기억한다(목록·지면을 그릴 때마다 다시 계산하지 않게)
    private static readonly ConcurrentDictionary<string, Placement> placeCache = new();
    public static Placement CachedPlace(NewsItem it)
    {
        var k = it.Key + "\u0001" + (it.TitleKo ?? "");
        if (placeCache.TryGetValue(k, out var p)) return p;
        p = Place(it);
        if (placeCache.Count > 20000) placeCache.Clear();
        placeCache[k] = p;
        return p;
    }

    // '전체'·'주요' 피드에서 온 글의 분야를 낱말로 짐작한다. 앞에 있는 규칙이 먼저(성격이 뚜렷한 것부터)
    private static readonly (string Section, string[] Words)[] Rules =
    [
        ("sports", ["야구", "축구", "농구", "배구", "골프", "올림픽", "월드컵", "kbo", "k리그", "프로야구", "홈런", "득점", "premier league", "nba", "nfl", "fifa", "olympic", "tournament", "championship"]),
        ("politics", ["대통령", "국회", "여당", "야당", "국민의힘", "민주당", "의원", "장관", "총리", "선거", "탄핵", "청와대", "대통령실", "북한", "국정", "president", "parliament", "congress", "senate", "election", "minister", "lawmakers", "white house"]),
        ("economy", ["증시", "코스피", "코스닥", "주가", "금리", "환율", "물가", "부동산", "아파트값", "수출", "기준금리", "한국은행", "실적", "매출", "영업이익", "stocks", "inflation", "interest rate", "fed", "earnings", "economy", "gdp", "tariff", "market"]),
        ("world", ["미국", "중국", "일본", "러시아", "우크라이나", "이스라엘", "유럽", "트럼프", "시진핑", "푸틴", "ukraine", "israel", "gaza", "china", "russia", "un "]),
        ("science", ["연구진", "우주", "nasa", "위성", "발사체", "유전자", "세포", "물리학", "천문", "scientists", "researchers", "space", "physics", "genome"]),
        ("life", ["건강", "질환", "병원", "환자", "치료", "백신", "다이어트", "여행", "날씨", "health", "disease", "hospital", "vaccine", "cancer"]),
        ("culture", ["영화", "드라마", "가수", "배우", "아이돌", "공연", "전시", "콘서트", "k팝", "케이팝", "film", "movie", "album", "concert", "actor", "box office"]),
        ("climate", ["기후", "탄소", "온실가스", "폭염", "climate", "carbon", "emissions"]),
        ("tech", ["스마트폰", "반도체", "앱 ", "애플", "삼성전자", "구글", "소프트웨어", "해킹", "iphone", "chip", "software", "apple", "google", "microsoft"]),
        ("society", ["경찰", "검찰", "법원", "재판", "사고", "화재", "사망", "교육", "학교", "노조", "police", "court", "trial"]),
    ];

    private static readonly Regex Hangul = new("[가-힣]");

    // 영어는 낱말 경계로, 한국어는 조사가 붙으므로 부분 일치
    private static readonly (string Section, Regex? English, string[] Korean)[] Compiled = Rules.Select(r =>
    {
        var english = r.Words.Where(w => !Hangul.IsMatch(w)).ToList();
        var korean = r.Words.Where(w => Hangul.IsMatch(w)).ToArray();
        var pattern = string.Join("|", english.Select(w => @"\b" + Regex.Escape(w.Trim()) + @"\b"));
        return (r.Section, english.Count == 0 ? null : new Regex(pattern, RegexOptions.CultureInvariant), korean);
    }).ToArray();

    public static string? Classify(string text)
    {
        var t = text.ToLowerInvariant();
        foreach (var (sec, re, korean) in Compiled)
            if ((re?.IsMatch(t) ?? false) || korean.Any(k => t.Contains(k, StringComparison.Ordinal))) return sec;
        return null;
    }
}

public static class NewsItemSections
{
    // 대표 분야 id
    public static string Section(this NewsItem it) => Sections.CachedPlace(it).Primary;
    // 이 기사에 다는 분야 칩(대표 포함)
    public static List<string> SectionChips(this NewsItem it) => Sections.CachedPlace(it).Chips;
    public static bool InSection(this NewsItem it, string id) => it.SectionChips().Contains(id);

    // 화면에 보이는 '분야' 표시(N-05): AI 분야 글은 그 안의 하위 분류(모델·연구…)까지, 나머지는 분야 이름
    public static string TopicLabel(this NewsItem it) => it.Section() == Sections.Ai ? "AI·" + it.Category.Label() : Sections.Name(it.Section());
    public static string TopicIcon(this NewsItem it) => it.Section() == Sections.Ai ? it.Category.Glyph() : Sections.ById(it.Section())?.Icon ?? "cat.other";
    public static DualColor TopicColor(this NewsItem it) =>
        it.Section() == Sections.Ai ? it.Category.Color() : Sections.ById(it.Section()) is { } s ? DualColor.Fixed(s.Color) : DualColor.Gray;
}
