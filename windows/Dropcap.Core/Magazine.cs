using System.Globalization;
using System.Text.Json.Serialization;

namespace Dropcap.Core;

public enum IssueKind { Daily, Weekly }

public static class IssueKinds
{
    public static string Raw(this IssueKind k) => k == IssueKind.Daily ? "daily" : "weekly";
}

// 호(발행본): 표지 기사 하나 + 분야별 지면. 기사 자체는 DB 에 있고 여기엔 순서만 둔다.
public sealed record Issue
{
    public sealed record Section
    {
        public NewsCategory Category { get; init; }
        public List<string> Keys { get; init; } = new();
        public string? Kind { get; init; }   // 영상·논문 등 구독 채널 지면이면 그 종류
        [JsonPropertyName("section")] public string? SectionId { get; init; } // 일반 뉴스 분야 지면이면 그 분야 id(G-10, 예전에 엮은 호에는 없음)

        [JsonIgnore] public string Id => Kind ?? (SectionId is { } s ? "s-" + s : Category.Raw());
        [JsonIgnore] public string Label => Kind is not null ? ItemKinds.Parse(Kind).Label()
            : Dropcap.Core.Sections.ById(SectionId) is { } sec ? sec.Name
            : (Category.IsOther() ? "그 밖의 소식" : Category.Label());
        [JsonIgnore] public string Glyph => Kind is not null ? "kind." + ItemKinds.Parse(Kind).Raw() : Dropcap.Core.Sections.ById(SectionId)?.Icon ?? Category.Glyph();
        [JsonIgnore] public DualColor Color => Kind is null && Dropcap.Core.Sections.ById(SectionId) is { } sec2 ? DualColor.Fixed(sec2.Color) : Categories.KindColor(Kind, Category);
    }

    public string Id { get; init; } = "";          // daily-2026-10-13 · weekly-2026-W41
    [JsonConverter(typeof(LowerEnum<IssueKind>))] public IssueKind Kind { get; init; }
    public DateTimeOffset Date { get; init; }       // 발행 시각
    public DateTimeOffset From { get; init; }
    public DateTimeOffset To { get; init; }
    public string? Cover { get; init; }             // 표지 기사 key
    public List<Section> Sections { get; init; } = new();
    public int Count { get; init; }

    // 기사가 너무 적은 호(앱을 막 쓰기 시작한 주 등) — 목록에 '기록 적음'으로 표시
    [JsonIgnore] public bool IsThin => Count < Magazine.ThinIssue;

    private static readonly CultureInfo Ko = new("ko-KR");

    [JsonIgnore]
    public string Title => Kind == IssueKind.Daily
        ? $"{To.ToLocalTime().AddSeconds(-60).ToString("M월 d일 dddd", Ko)} 호"
        : $"주간 · {From.ToLocalTime().ToString("M월 d일", Ko)}–{To.ToLocalTime().AddSeconds(-1).ToString("M월 d일", Ko)}";
}

// 매거진 편집국: 기사를 모으고(DB), 스토리로 묶고, 점수를 매겨 호를 엮는다.
// DB 를 쓰는 일은 모두 동기 함수 — 화면에서는 Task.Run 으로 부른다(Q-07).
public sealed class Magazine
{
    private readonly Database db;
    private readonly FeedService feeds;
    private readonly object gate = new();
    private bool enriching;

    // 관심사 가중치(분야, 출처) → 0~1.5. AppModel 이 넣어 준다.
    public Func<NewsCategory, string?, double> Interest { get; set; } = (_, _) => 0;
    // 상태에서 오는 값(AppModel 이 넣어 줌)
    public Func<SourceFilter> Filter { get; set; } = () => new SourceFilter();               // 보여 줄 출처(S-13 — 숨긴·꺼진·해지한 출처 글은 뺌)
    public Func<List<string>?> Chosen { get; set; } = () => null;                           // 고른 분야(G-10)
    public Func<PolicyLimits> Limits { get; set; } = () => new PolicyLimits();
    public Func<string, bool> IsFollowed { get; set; } = _ => false;

    private readonly List<(Database.Cluster Cluster, NewsItem Item)> grown = new();   // 이번에 팔로우한 스토리에 붙은 새 보도
    public List<(Database.Cluster Cluster, NewsItem Item)> TakeGrown() { lock (gate) { var g = grown.ToList(); grown.Clear(); return g; } }

    public int LayoutRevision { get; private set; }   // 숨긴 출처·고른 분야가 바뀜(알림 띠 없이 바로 다시 엮음)
    public event Action? LayoutChanged;
    public void Refresh() { LayoutRevision++; LayoutChanged?.Invoke(); }

    public int Revision { get; private set; }        // 새 기사가 들어올 때마다 바뀜(화면 갱신용)
    public int ImageRevision { get; private set; }   // 사진만 채워졌을 때(조용히 다시 그림)
    public List<Issue> Archive { get; private set; }
    public bool Preparing { get; set; }              // 첫 호를 엮는 중
    public event Action? Changed;
    public event Action? ImagesChanged;

    public Magazine(Database db, FeedService? feeds = null)
    {
        this.db = db;
        this.feeds = feeds ?? FeedService.Shared;
        Archive = ArchiveOrder(db.Issues());
    }

    public void NotifyChanged() => Changed?.Invoke();

    // MARK: 받아 넣기
    // 처음 실행: 예전 기록(최근 소식·저장)을 옮겨 온다. 이미 있으면 건너뜀.
    public void MigrateIfNeeded(AppState state)
    {
        if (db.ItemCount != 0) return;
        var items = state.Recent.Concat(state.Saved).ToList();
        if (items.Count == 0) return;
        Ingest(items.OrderBy(i => i.Date ?? DateTimeOffset.MinValue).ToList());
        PublishDue();
    }

    // 새로 들어온 기사 전부(같은 소식으로 묶여 알림에서 빠진 것도 포함)
    public void Ingest(IReadOnlyList<NewsItem> items, bool enrich = true)
    {
        if (items.Count == 0) return;
        lock (gate)
        {
            var since = DateTimeOffset.Now.AddDays(-7);
            var clusters = db.RecentClusters(since);
            // 스토리마다 대표 기사 하나(뜻 비교용)
            var reps = new Dictionary<string, NewsItem>();
            foreach (var c in clusters) if (db.ItemsInCluster(c.Id).LastOrDefault()?.Item is { } first) reps[c.Id] = first;
            foreach (var it in items)
            {
                var when = it.Date ?? DateTimeOffset.Now;
                // 이미 있는 기사는 스토리를 다시 정하지 않는다(대표가 자기 자신이면 '같은 출처'로 보여 새 스토리가 생기던 문제)
                if (db.Exists(it.Key))
                {
                    db.Upsert(it, null);
                    continue;
                }
                // 기사만 스토리로 묶는다(논문·릴리스·커뮤니티 글은 양이 많고 성격이 달라 제외)
                if (it.ItemKind is not (ItemKind.Article or ItemKind.Video))
                {
                    db.Upsert(it, null);
                    continue;
                }
                var (cid, joined) = Assign(it, when, clusters, reps);
                if (joined && IsFollowed(cid) && clusters.FirstOrDefault(c => c.Id == cid) is { } fc) grown.Add((fc, it));
                db.Upsert(it, cid);
            }
            Revision++;
        }
        Changed?.Invoke();
        if (enrich) _ = EnrichImagesAsync();
    }

    // 기사 하나를 스토리에 넣는다: 대표 기사와 같은 소식이면 그 스토리에, 아니면 새 스토리. (스토리 id, 기존 스토리에 붙었는지)
    // 스토리의 대표 기사와만 비교한다(낱말을 계속 보태면 눈덩이처럼 아무 기사나 붙는다)
    private (string Id, bool Joined) Assign(NewsItem it, DateTimeOffset when, List<Database.Cluster> clusters, Dictionary<string, NewsItem> reps)
    {
        var i = clusters.FindIndex(c => reps.TryGetValue(c.Id, out var r) && StoryMatch.Same(it, r));
        if (i >= 0)
        {
            var c = clusters[i];
            c.Size += 1;
            if (when > c.Last) c.Last = when;
            if (when < c.First) c.First = when;
            if (it.Tier == "lab") c.Title = it.DisplayTitle;   // 공식 발표 제목을 스토리 이름으로
            db.SaveCluster(c);
            return (c.Id, true);
        }
        var n = new Database.Cluster(Guid.NewGuid().ToString().ToUpperInvariant(), it.DisplayTitle, StoryMatch.Tokens(it.Title), when, when, 1);
        clusters.Add(n);
        db.SaveCluster(n);
        reps[n.Id] = it;
        return (n.Id, false);
    }

    // 사진이 없는 최근 기사는 페이지에서 og:image 를 찾아 채운다(한 번에 12개, 공개 주소만)(M-13)
    public async Task EnrichImagesAsync()
    {
        lock (gate) { if (enriching) return; enriching = true; }
        try
        {
            if (enrichTried.Count > 5000) enrichTried.Clear(); // 오래 켜 둬도 끝없이 커지지 않게
            var todo = ToEnrich(db.Items(DateTimeOffset.Now.AddDays(-3), limit: 300), enrichTried);
            var changed = false;
            foreach (var s in todo)
            {
                enrichTried.Add(s.Item.Key);
                if (await feeds.OgImageAsync(s.Item.Link) is { } img)
                {
                    db.SetImage(s.Item.Key, img);
                    changed = true;
                }
            }
            if (changed) { ImageRevision++; ImagesChanged?.Invoke(); }
        }
        finally { lock (gate) enriching = false; }
        await ScoreImagesAsync();
    }

    // 사진 점수 재기(M-24): 앱이 정한다(사진 받기·풀기·글자 인식). 없으면(시험) 재지 않는다
    public Func<string, Task<PhotoQuality.Score?>>? PhotoScorer { get; set; }
    private bool scoring;

    // 최근 36시간 기사 사진의 점수를 미리 잰다(표지·분야 대표 사진 고르기). 한 번에 16장, 이미 잰 것은 건너뜀
    public async Task ScoreImagesAsync()
    {
        if (PhotoScorer is not { } scorer) return;
        lock (gate) { if (scoring) return; scoring = true; }
        try
        {
            var recent = db.Items(DateTimeOffset.Now.AddHours(-36), limit: 400, articlesOnly: true)
                .Select(s => s.Item).Where(i => PhotoQuality.Usable(i.Image)).ToList();
            var known = db.ImageScores(recent.Select(i => i.Image!).ToList());
            var changed = false;
            foreach (var it in recent.Where(i => !known.ContainsKey(i.Image!)).DistinctBy(i => i.Image).Take(16))
            {
                PhotoQuality.Score? s;
                try { s = await scorer(it.Image!); } catch { s = null; }
                if (s is null) continue;
                db.SaveImageScore(it.Image!, s);
                if (!PhotoQuality.Good(s.Total)) changed = true;
            }
            if (changed) { ImageRevision++; ImagesChanged?.Invoke(); }
        }
        finally { lock (gate) scoring = false; }
    }

    public Dictionary<string, double> ImageScores(IEnumerable<string> urls) => db.ImageScores(urls.ToList());

    private readonly HashSet<string> enrichTried = new(); // 이번 실행에서 이미 찾아본 기사(사진이 없던 곳을 확인마다 다시 받지 않게)

    // 사진 없는 기사 중 아직 찾아보지 않은 것 12개(빼지 않으면 사진 없는 최신 12건만 확인마다 다시 받고, 그 뒤 기사는 영영 못 찾았다)
    public static List<Database.StoredItem> ToEnrich(IEnumerable<Database.StoredItem> items, IReadOnlySet<string> tried) =>
        items.Where(s => s.Item.Image is null && s.Item.Link.Length > 0 && !tried.Contains(s.Item.Key)).Take(12).ToList();

    // MARK: 점수(M-03)
    // 공식 발표·여러 곳 보도·중요 낱말·관심 분야는 위로, 오래될수록 아래로
    public double Score(Database.StoredItem s, int clusterSize, DateTimeOffset now)
    {
        var it = s.Item;
        var tier = it.Tier switch { "lab" => 2.2, "press" => 1.2, "kr" => 1.0, _ => 0.8 };
        var coverage = 1.6 * Math.Log(1 + Math.Max(clusterSize, 1));
        var important = it.Important == true ? 2.5 : 0;
        var interest = Interest(it.Category, it.SourceId);
        var hours = Math.Max(0, (now - (it.Date ?? s.FirstSeen)).TotalHours);
        var fresh = 2.0 * Math.Exp(-hours / 18);
        var picture = it.Image is null ? 0 : 0.4;
        return tier + coverage + important + interest + fresh + picture;
    }

    // MARK: 호 엮기(M-04)
    // only: 분야 지면(M-25 — 그 분야 칩이 달린 기사만, 구독 채널 지면 없이, 분야 지면 40건까지)
    public Issue MakeIssue(IssueKind kind, DateTimeOffset from, DateTimeOffset to, string id, string? only = null)
    {
        // 기사와 구독 채널 글을 따로(논문이 많아도 기사가 잘리지 않게)
        var filter = Filter();   // 숨긴·꺼진·해지한 출처는 스토리 대표를 고르기 전에 뺀다(G-11 · S-13)
        var stored = db.Items(from, to, limit: 4000, articlesOnly: true).Concat(only is null ? db.Items(from, to, limit: 800, channelsOnly: true) : [])
            .Where(s => filter.Shows(s.Item.SourceId))
            .Where(s => only is null || Dropcap.Core.Sections.CachedPlace(s.Item).Chips.Contains(only)).ToList();
        // 같은 스토리는 대표 하나만 지면에(점수 높은 것)
        var sizes = new Dictionary<string, int>();
        foreach (var s in stored) if (s.Cluster is { } c) sizes[c] = sizes.GetValueOrDefault(c) + 1;
        var best = new Dictionary<string, (Database.StoredItem S, double Score)>();
        var loose = new List<(Database.StoredItem S, double Score)>();
        foreach (var s in stored)
        {
            var sc = Score(s, s.Cluster is { } c0 ? sizes.GetValueOrDefault(c0, 1) : 1, to);
            if (s.Cluster is { } c)
            {
                if (!best.TryGetValue(c, out var b) || b.Score < sc) best[c] = (s, sc);
            }
            else loose.Add((s, sc));
        }
        var ranked = best.Values.Concat(loose).OrderByDescending(p => p.Score).ToList();
        var limit = kind == IssueKind.Weekly ? 60 : 90;
        var picked = ranked.Where(p => p.S.Item.ItemKind == ItemKind.Article).Take(limit).ToList();
        // 표지: 사진이 있는 기사 중 점수 1등(없으면 그냥 1등). 화면 캡처·글자 그림·로고로 잰 사진은 건너뛴다(M-24)
        // 주간 표지는 그 주 가장 많이 다룬 이야기(스토리 보도 수 → 점수 순) — 오늘 표지와 같아지지 않게
        var coverOrder = kind == IssueKind.Weekly
            ? picked.OrderByDescending(p => p.S.Cluster is { } c1 ? sizes.GetValueOrDefault(c1, 1) : 1).ThenByDescending(p => p.Score).ToList()
            : picked;
        var photoScores = db.ImageScores(coverOrder.Take(30).Select(p => p.S.Item.Image).OfType<string>().ToList());
        var coverPick = PhotoQuality.PickCover(coverOrder.Select(p => p.S.Item), photoScores);
        var cover = picked.FirstOrDefault(p => p.S.Item.Key == coverPick);
        if (cover.S is null) cover = coverOrder.FirstOrDefault();
        var coverKey = cover.S?.Item.Key;
        var articles = picked.Where(p => p.S.Item.Key != coverKey).Select(p => p.S).ToList();
        var sections = SectionPages(articles, stored, only is not null ? [only] : Chosen(), Limits(), only is not null ? SectionPageLimit : (kind == IssueKind.Weekly ? 8 : 12));
        // 구독 채널 지면: 종류별, 채널 하나당 4개까지(논문처럼 많은 곳이 지면을 덮지 않게)
        var channelSections = new List<Issue.Section>();
        foreach (var k in new[] { ItemKind.Video, ItemKind.Release, ItemKind.Paper, ItemKind.Podcast, ItemKind.Post })
        {
            var perSource = new Dictionary<string, int>();
            var keys = new List<string>();
            foreach (var p in ranked.Where(p => p.S.Item.ItemKind == k))
            {
                var n = perSource[p.S.Item.SourceId] = perSource.GetValueOrDefault(p.S.Item.SourceId) + 1;
                if (n <= 4) keys.Add(p.S.Item.Key);
            }
            if (keys.Count > 0) channelSections.Add(new() { Category = Categories.Other, Keys = keys.Take(12).ToList(), Kind = k.Raw() });
        }
        return new Issue
        {
            Id = id, Kind = kind, Date = DateTimeOffset.Now, From = from, To = to, Cover = coverKey,
            Sections = sections.Concat(channelSections).ToList(), Count = stored.Count(s => s.Item.ItemKind == ItemKind.Article),
        };
    }

    // 분야 지면(G-10): 주요 뉴스(국내 n곳·해외 n곳 넘게 보도된 소식 8건) → 고른 분야 → 나머지 분야(2건 이상) → 그 밖의 소식.
    // 기사는 한 지면에만(고른 분야에 걸린 칩이 있으면 그 분야, 없으면 대표 분야).
    public static List<Issue.Section> SectionPages(IReadOnlyList<Database.StoredItem> articles, IReadOnlyList<Database.StoredItem> stored, List<string>? chosen,
        PolicyLimits limits, int perSection, Dictionary<string, SourceMeta>? meta = null)
    {
        var picks = chosen ?? Dropcap.Core.Sections.All.Select(s => s.Id).ToList();
        // 스토리마다 국내·해외 출처 수(이 호의 기간 안에서)
        var outlets = new Dictionary<string, Dictionary<string, string>>();   // 스토리 → 출처 → 지역
        foreach (var s in stored)
            if (s.Cluster is { } c)
            {
                if (!outlets.TryGetValue(c, out var m)) outlets[c] = m = new();
                m[s.Item.SourceId] = Dropcap.Core.Sections.RegionOf(s.Item.SourceId, s.Item.Tier, meta);
            }
        Coverage Cov(Database.StoredItem s)
        {
            var m = s.Cluster is { } c && outlets.TryGetValue(c, out var o) ? o
                : new Dictionary<string, string> { [s.Item.SourceId] = Dropcap.Core.Sections.RegionOf(s.Item.SourceId, s.Item.Tier, meta) };
            return new Coverage(m.Values.Count(v => v == "kr"), m.Values.Count(v => v != "kr"));
        }
        var used = new HashSet<string>();
        var pages = new List<Issue.Section>();
        if (picks.Contains(Dropcap.Core.Sections.Top))
        {
            var keys = articles.Where(a => NotifyPolicy.Crosses(Cov(a), limits)).Select(a => a.Item.Key).Take(8).ToList();
            if (keys.Count > 0) { pages.Add(new() { Category = Categories.Other, Keys = keys, SectionId = Dropcap.Core.Sections.Top }); used.UnionWith(keys); }
        }
        var bySection = new Dictionary<string, List<string>>();
        foreach (var s in articles.Where(a => !used.Contains(a.Item.Key)))
        {
            var p = Dropcap.Core.Sections.Place(s.Item, meta);
            var home = p.Chips.FirstOrDefault(picks.Contains) ?? p.Primary;
            if (!bySection.TryGetValue(home, out var l)) bySection[home] = l = new();
            l.Add(s.Item.Key);
        }
        var leftovers = new List<string>();
        var order = Dropcap.Core.Sections.All.Select(s => s.Id).Where(id => id != Dropcap.Core.Sections.Top).ToList();
        foreach (var id in order.Where(picks.Contains).Concat(order.Where(id => !picks.Contains(id))))
        {
            if (!bySection.Remove(id, out var keys)) continue;
            // 고르지 않은 분야에서 한 건뿐이면 지면이 휑하므로 '그 밖의 소식'으로
            if (keys.Count >= 2 || picks.Contains(id)) pages.Add(new() { Category = Categories.Other, Keys = keys.Take(perSection).ToList(), SectionId = id });
            else leftovers.AddRange(keys);
        }
        leftovers.AddRange(bySection.Values.SelectMany(v => v));
        if (leftovers.Count > 0) pages.Add(new() { Category = Categories.Other, Keys = leftovers.Take(perSection).ToList() });
        return pages;
    }

    // 같은 소식을 다룬 출처 수(국내·해외, G-05). 스토리에 묶이지 않았으면 자기 하나.
    public Coverage RegionCoverage(NewsItem it, SourceFilter? filter = null)
    {
        var regions = new Dictionary<string, string> { [it.SourceId] = Dropcap.Core.Sections.RegionOf(it.SourceId, it.Tier) };
        if (db.ClusterOf(it.Key) is { } c)
            foreach (var s in db.ItemsInCluster(c))
                if (filter is null || filter.Shows(s.Item.SourceId)) regions[s.Item.SourceId] = Dropcap.Core.Sections.RegionOf(s.Item.SourceId, s.Item.Tier);
        return new Coverage(regions.Values.Count(v => v == "kr"), regions.Values.Count(v => v != "kr"));
    }

    // 스토리 보도를 해외·국내로 나눔(나란히 보기, G-12)
    public static (List<NewsItem> Intl, List<NewsItem> Kr) SplitByRegion(IEnumerable<NewsItem> items, Dictionary<string, SourceMeta>? meta = null)
    {
        var list = items.ToList();
        return (list.Where(i => Dropcap.Core.Sections.RegionOf(i.SourceId, i.Tier, meta) != "kr").ToList(),
                list.Where(i => Dropcap.Core.Sections.RegionOf(i.SourceId, i.Tier, meta) == "kr").ToList());
    }

    // 스토리 목록: 최근 24시간 안에 보도가 붙은 것(지금 커지는 스토리)과 나머지. 큰 것·최근 것이 앞
    public (List<Database.Cluster> Live, List<Database.Cluster> Past) StoryGroups(DateTimeOffset? now = null)
    {
        var n = now ?? DateTimeOffset.Now;
        double Rank(Database.Cluster c) => c.Size + Math.Max(0, 24 - (n - c.Last).TotalHours) / 6;
        var all = Stories().OrderByDescending(Rank).ThenByDescending(c => c.Last).ToList();
        var cut = n.AddHours(-24);
        return (all.Where(c => c.Last >= cut).ToList(), all.Where(c => c.Last < cut).ToList());
    }

    // 스토리 한눈에 요약(Ollama 가 있을 때) — 보도 수가 같으면 다시 만들지 않음
    private readonly Dictionary<string, (int Size, List<string> Lines)> digestCache = new();
    public async Task<List<string>?> StoryDigestAsync(Database.Cluster c)
    {
        lock (gate) if (digestCache.TryGetValue(c.Id, out var d) && d.Size == c.Size) return d.Lines;
        var items = StoryItems(c.Id);
        if (items.Count < 2) return null;
        var paras = items.Select(i => $"[{i.SourceName}] {i.DisplayTitle}. {FeedParser.Prefix(i.Summary, 400)}").ToList();
        if (await Summarizer.SummarizeAsync(c.Title, paras) is not { } lines) return null;
        lock (gate) digestCache[c.Id] = (c.Size, lines);
        return lines;
    }

    // 지금 진행 중인 오늘 호(전날 18시~지금)·이번 주 호(7일)(M-05)
    public Issue LiveDaily()
    {
        var start = new DateTimeOffset(DateTime.Today);
        return MakeIssue(IssueKind.Daily, start.AddHours(-6), DateTimeOffset.Now.AddSeconds(60), "live-daily");
    }

    // 분야 지면(M-25): 오늘 호와 같은 기간(전날 18시~지금)에 그 분야 칩이 달린 기사만으로 엮은 호(표지·건수도 그 분야)
    public const int SectionPageLimit = 40;
    public Issue LiveSection(string section)
    {
        var start = new DateTimeOffset(DateTime.Today);
        return MakeIssue(IssueKind.Daily, start.AddHours(-6), DateTimeOffset.Now.AddSeconds(60), "live-section-" + section, section);
    }

    // 머리 숫자(M-25 — 맥 Magazine.subtitle): 모두 실렸으면 "소식 N건", 아니면 "소식 N건 중 M건 실음", 분야가 있으면 " · 분야 K개"
    public static string Subtitle(int total, int shown, int sections, string noun = "소식")
    {
        var head = shown >= total ? $"{noun} {total}건" : $"{noun} {total}건 중 {shown}건 실음";
        return sections > 0 ? head + $" · 분야 {sections}개" : head;
    }

    // 스토리의 분야(M-26): 묶인 보도들의 대표 분야 다수결(같으면 분야 순서 앞). AI 면 AI 안 하위 분류도 다수결(같으면 분류 순서 앞)
    public static (string Section, NewsCategory? Category)? StoryTopic(IReadOnlyList<NewsItem> items, Func<NewsItem, string>? place = null)
    {
        if (items.Count == 0) return null;
        place ??= it => Dropcap.Core.Sections.CachedPlace(it).Primary;
        var secs = items.Select(place).ToList();
        var votes = new Dictionary<string, int>();
        foreach (var s in secs) votes[s] = votes.GetValueOrDefault(s) + 1;
        var sec = votes.OrderByDescending(v => v.Value).ThenBy(v => Dropcap.Core.Sections.Order(v.Key)).First().Key;
        if (sec != Dropcap.Core.Sections.Ai) return (sec, null);
        var cats = new Dictionary<NewsCategory, int>();
        for (var i = 0; i < items.Count; i++) if (secs[i] == Dropcap.Core.Sections.Ai) cats[items[i].Category] = cats.GetValueOrDefault(items[i].Category) + 1;
        var cat = cats.OrderByDescending(v => v.Value).ThenBy(v => v.Key.SortOrder()).Select(v => (NewsCategory?)v.Key).FirstOrDefault();
        return (sec, cat);
    }

    // 이번 주: 달력 한 주의 시작부터 지금까지(지난 주간과 이어짐 — 예전엔 '지금부터 7일 전'이라 지난 주간과 날이 겹쳤다)
    public Issue LiveWeekly() =>
        MakeIssue(IssueKind.Weekly, new DateTimeOffset(WeekRange(DateTime.Now).From), DateTimeOffset.Now.AddSeconds(60), "live-weekly");

    // 하루가 지나면 그날 호를, 일요일이 지나면 그 주 호를 발행해 지난 호에 남긴다
    public void PublishDue(DateTime? todayOverride = null)
    {
        var nowLocal = todayOverride ?? DateTime.Now;
        var today = nowLocal.Date;
        // 일간 호의 기간은 '오늘 호'와 같게: 전날 18시 ~ 그날 18시. 어제 호는 오늘 정오까지는 새 기사가 오면 다시 엮는다.
        for (var back = 3; back >= 1; back--)
        {
            var day = today.AddDays(-back);
            var id = "daily-" + DayId(day);
            var refresh = back == 1 && nowLocal.Hour < 12;
            if (db.HasIssue(id) && !refresh) continue;
            var issue = MakeIssue(IssueKind.Daily, new DateTimeOffset(day.AddHours(-6)), new DateTimeOffset(day.AddHours(18)), id);
            if (issue.Count > 0) db.SaveIssue(issue);
        }
        var last = WeekRange(WeekRange(today).From.AddHours(-1));
        var wid = "weekly-" + WeekId(last.From);
        if (!db.HasIssue(wid))
        {
            var issue = MakeIssue(IssueKind.Weekly, new DateTimeOffset(last.From), new DateTimeOffset(last.To), wid);
            if (issue.Count > 0) db.SaveIssue(issue);
        }
        // 분야 개편 전에 엮은 호는 그 기간 기사로 지금 규칙(분야 지면)에 맞춰 다시 엮는다(기사가 지워졌으면 그대로 둠)
        foreach (var old in db.Issues().Where(NeedsRebuild))
        {
            var again = MakeIssue(old.Kind, old.From, old.To, old.Id);
            if (again.Count > 0) db.SaveIssue(again);
        }
        db.Prune();
        Archive = ArchiveOrder(db.Issues());
        Changed?.Invoke();
    }

    // MARK: 지면 규칙(왼쪽 목록과 오른쪽 화면이 같은 기준을 쓰게 — 맥 SidebarRuleTests)
    public const int ThinIssue = 5;

    // 지난 호 목록: 최신부터 호의 끝 시각 순(주간은 그 주 끝 — 토요일 호 바로 위)
    public static List<Issue> ArchiveOrder(IEnumerable<Issue> issues) =>
        issues.OrderByDescending(i => i.To).ThenBy(i => i.Kind == IssueKind.Weekly ? 0 : 1).ToList();

    // 주간 범위: 달력 한 주(한국 달력처럼 일요일부터, 7일). 이번 주 진행 중 호와 지난 주간이 겹치지 않고 이어짐
    public static (DateTime From, DateTime To) WeekRange(DateTime local)
    {
        var start = local.Date.AddDays(-(int)local.DayOfWeek);
        return (start, start.AddDays(7));
    }

    // 분야 개편(분야 지면) 전에 엮은 호: 기사 지면에 분야 id 가 없고 예전 AI 분류(모델·제품…)로 나뉨 → 지금 규칙으로 다시 엮는다
    public static bool NeedsRebuild(Issue issue) =>
        issue.Sections.Any(s => s.Kind is null && s.SectionId is null && !s.Category.IsOther());

    // 최근 검색어: 맨 앞에 넣고 같은 것(대소문자 무시)은 하나로, 두 글자 이상, 8개까지
    public static List<string> RememberSearch(string q, IReadOnlyList<string> list, int max = 8)
    {
        var t = q.Trim();
        if (t.Length < 2) return list.ToList();
        return new[] { t }.Concat(list.Where(x => !string.Equals(x, t, StringComparison.OrdinalIgnoreCase))).Take(max).ToList();
    }

    public static string DayId(DateTime d) => d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
    public static string WeekId(DateTime d) => $"{ISOWeek.GetYear(d):0000}-W{ISOWeek.GetWeekOfYear(d):00}";

    // MARK: 꺼내 보기
    // 한 호를 화면에 그릴 재료를 한 번에(지면마다 DB 를 다시 읽지 않게)
    // Clusters: key → 스토리(카드 메뉴에서 DB 를 다시 읽지 않게)
    // Regions: 해외·국내가 섞인 스토리 → 보도들(카드의 '해외에서는·국내에서는' 두 줄, G-12)
    public sealed record Resolved(Issue Issue, Database.StoredItem? Cover, List<(Issue.Section Section, List<NewsItem> Items)> Sections, Dictionary<string, string> Clusters,
        Dictionary<string, List<NewsItem>>? Regions = null);

    public Resolved Resolve(Issue issue)
    {
        var keys = (issue.Cover is { } ck ? new[] { ck } : []).Concat(issue.Sections.SelectMany(s => s.Keys)).ToList();
        var map = new Dictionary<string, Database.StoredItem>();
        foreach (var s in db.ItemsByKeys(keys)) map.TryAdd(s.Item.Key, s);
        var filter = Filter();   // 엮은 뒤에 끈 출처도 지난 호·표지에서 빠진다(S-13)
        foreach (var k in map.Where(p => !filter.Shows(p.Value.Item.SourceId)).Select(p => p.Key).ToList()) map.Remove(k);
        var clusters = map.Where(p => p.Value.Cluster is not null).ToDictionary(p => p.Key, p => p.Value.Cluster!);
        // 여러 곳이 다룬 스토리만 보도를 꺼내 해외·국내가 섞였는지 본다
        var regions = new Dictionary<string, List<NewsItem>>();
        var sizes = db.Coverage(clusters.Keys.ToList());
        foreach (var (k, c) in clusters)
        {
            if (sizes.GetValueOrDefault(k, 1) < 2 || regions.ContainsKey(c)) continue;
            var items = filter.Visible(db.ItemsInCluster(c).Select(s => s.Item));
            var (intl, kr) = SplitByRegion(items);
            if (intl.Count > 0 && kr.Count > 0) regions[c] = items;
        }
        return new Resolved(issue, issue.Cover is { } c0 ? map.GetValueOrDefault(c0) : null,
            issue.Sections.Select(s => (s, s.Keys.Select(k => map.GetValueOrDefault(k)?.Item).OfType<NewsItem>().ToList()))
                .Where(p => p.Item2.Count > 0).ToList(), clusters, regions);
    }

    public Database.StoredItem? Stored(string key) => db.ItemsByKeys([key]).FirstOrDefault();
    public Dictionary<string, int> Coverage(IEnumerable<NewsItem> items) => db.Coverage(items.Select(i => i.Key).ToList());
    public string? StoredImage(string key) => db.Image(key);
    // 스토리의 보도들(꺼진·해지한·숨긴 출처 글은 빠짐, S-13)
    public List<NewsItem> StoryItems(string cluster) => Filter().Visible(db.ItemsInCluster(cluster).Select(s => s.Item));
    public Database.Cluster? Cluster(string id) => db.GetCluster(id);
    public string? ClusterId(string key) => db.ClusterOf(key);

    // 스토리: 최근 2주 동안 두 곳 이상이 다룬 것(M-14)
    // 지금 보이는 출처로만 두 곳 이상이 다룬 스토리(출처를 끄면 그 스토리의 보도 수도 줄어 목록에서 빠질 수 있음, S-13). 크기도 보이는 보도 수로
    public List<Database.Cluster> Stories()
    {
        var o = new List<Database.Cluster>();
        foreach (var c in db.RecentClusters(DateTimeOffset.Now.AddDays(-14)).Where(c => c.Size >= 2))
        {
            var items = StoryItems(c.Id);
            if (items.Select(i => i.SourceId).Distinct().Count() < 2) continue;
            o.Add(c with { Size = items.Count });
        }
        return o;
    }

    public List<NewsItem> Search(string q) => Filter().Visible(db.Search(q));
    // 최근 기사(지켜볼 낱말 하루 정리, N-27)
    public List<NewsItem> RecentItems(DateTimeOffset since) => Filter().Visible(db.Items(since, limit: 3000).Select(s => s.Item));
}
