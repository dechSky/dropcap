using System.Globalization;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Dropcap.Core;

namespace Dropcap.Ui;

// 매거진 창(M 절). 맥 MagazineView 와 같은 내용·문구.
// 호 엮기·분야 거르기·정렬·검색·스크랩북 묶기는 여기서 하고, 화면(magazine.js)은 받은 그대로 그린다.
// DB 를 읽는 일은 모두 Task.Run 으로(화면 스레드를 막지 않게 — Q-07).
public sealed class MagazinePage(AppModel model, Magazine mag, Scrapbook book, IPlatform platform, Bridge bridge) : IPage
{
    public string Name => "magazine";

    // 화면에 보낸 기사(검색 결과·스크랩처럼 최근 목록에 없는 것도 다시 찾게)
    private readonly Dictionary<string, NewsItem> shown = new();
    private bool attached;

    // 분야 '오늘 얼굴' 사진(유리 띠). 시험에서는 바꿔 끼운다(바깥 피드를 받지 않게)
    public Action<IEnumerable<string>> LoadPhotos { get; set; } = ids => SectionPhotos.Shared.Load(ids);
    public Func<string, string?> PhotoUrl { get; set; } = id => SectionPhotos.Shared.Url(id);

    // MARK: 보기 데이터
    // 색은 라이트·다크 두 벌(#RRGGBB 만 — ItemView.SafeColor)
    public sealed record SideSection(string Id, string Name, string Icon, string Light, string Dark);
    public sealed record ArchiveRow(string Id, string Title, bool Weekly);
    public sealed record SidebarView(int Saved, int Scraps, List<ArchiveRow> Archive, string Sort, List<SideSection> Sections);

    public sealed record TopicView(string Label, string Icon, string Light, string Dark);   // 카드의 분야 표시(N-05 TopicChip 과 같은 이름)
    public sealed record ChipView(string Id, string Label, string Icon, string Light, string Dark, int Count);
    public sealed record RegionLines(List<string> Intl, List<string> Kr);                   // 카드의 '해외에서는·국내에서는' 두 줄(G-12)

    public sealed record CoverView(ItemView Item, string? Cluster, int Size);
    // 분야 지면 머리의 유리 띠(맥 SectionGlassCard 높이 92): 영문 이름 · 'N건 · 첫 기사 제목' · 오늘의 사진(없으면 색면)
    public sealed record GlassView(string English, string Sub, string? Photo);
    public sealed record SectionView(string Id, string? Section, string Label, string Icon, string Tone, string Light, string Dark, bool ShowTopic, List<ItemView> Items,
        GlassView? Glass = null);
    public sealed record EmptyView(bool Preparing, string Title, string Sub);
    // 오늘 호 완독(M-23): 대표 기사 key·읽은 수·다 읽음·다음 호 안내
    public sealed record TodayView(List<string> Keys, int Read, bool Done, string Next);
    // 저녁 정리(N-26): 줄마다 근거 번호(1부터 — 화면의 [n]), 근거 기사는 원제목 그대로
    public sealed record BriefLineView(string Text, List<int> Refs);
    public sealed record BriefItemView(string Key, string Title, string Source, string Link);
    public sealed record BriefView(string Section, string Title, string Time, string Light, string Dark, string Help, List<BriefLineView> Lines, List<BriefItemView> Items);
    public sealed record IssueView(string Id, string Title, bool Live, int Count, int SectionCount, string Sort, CoverView? Cover, EmptyView? Empty,
        List<SectionView> Sections, Dictionary<string, string> Clusters, int Revision, int ImageRevision, int LayoutRevision, bool Preparing,
        string? Focus, string? Sub, List<ChipView> Chips, List<ChipView> SubChips, Dictionary<string, TopicView> Topics, Dictionary<string, RegionLines> Regions,
        TodayView? Today = null, bool TodayDone = false, BriefView? Brief = null);

    public sealed record SourceChip(string Name, string Initial, string Color);
    public sealed record StoryCard(string Id, string Title, int Size, int Fresh, bool Following, string? Photo, TopicView? Topic, List<SourceChip> Sources, string Times);
    public sealed record StoriesView(List<StoryCard> Live, List<StoryCard> Past);
    public sealed record TimelineRow(ItemView Item, string When, bool First, string? Gap, string? Lede);
    public sealed record RegionColumn(string Title, string Icon, int Count, List<ItemView> Items);
    public sealed record StoryView(string Id, string Title, string Sub, bool Following, List<TimelineRow> Items, RegionColumn? Intl, RegionColumn? Kr);

    public sealed record SavedView(List<ItemView> Items, List<string> Archived, Dictionary<string, TopicView> Topics);
    public sealed record SearchView(string Q, List<ItemView>? Items, Dictionary<string, TopicView>? Topics = null);   // Items 가 null 이면 화면은 앞 결과를 그대로 둔다

    public sealed record FolderView(string Name, int Count);
    public sealed record ScrapView(string Id, string? Quote, string? Original, string Memo, string Collection);
    public sealed record ScrapGroup(ItemView Item, List<ScrapView> Scraps);
    public sealed record ScrapbookView(string Folder, List<FolderView> Folders, int Total, List<ScrapGroup> Groups);

    public sealed record ReduceView(string Hide, string? Less, List<string> Words);


    // MARK: 정렬(M-10) — 맥 MagSort 와 같은 규칙. 추천순은 편집 순서(점수) 그대로.
    public static readonly string[] Sorts = ["recommended", "newest", "coverage", "source"];

    public static List<NewsItem> Sort(IReadOnlyList<NewsItem> items, string sort)
    {
        var d = (NewsItem i) => i.Date ?? DateTimeOffset.MinValue;
        return sort switch
        {
            "newest" => items.OrderByDescending(d).ToList(),
            "coverage" => items.OrderByDescending(i => i.Related?.Count ?? 0).ToList(),   // 같으면 원래 순서(안정 정렬)
            "source" => items.OrderBy(i => i.SourceName, StringComparer.Ordinal).ThenByDescending(d).ToList(),
            _ => items.ToList(),
        };
    }

    // 마지막 줄에 카드 한 장만 남지 않게 칸 수를 고른다(맥 BalancedGrid.columns 와 같은 규칙 — 화면 magazine.js 의 columns 도 같음)
    public static int Columns(int fit, int count)
    {
        fit = Math.Max(1, fit);
        if (count <= fit || count % fit != 1) return Math.Min(fit, Math.Max(count, 1));
        if (fit + 1 <= 4 && count % (fit + 1) != 1 && count >= fit + 1) return fit + 1;   // 한 칸 더 넣어도 좁지 않으면
        if (fit > 2 && count % (fit - 1) != 1) return fit - 1;
        return fit;
    }

    public static string CurrentSort() => Prefs.Get("magSort", "recommended") is { } s && Sorts.Contains(s) ? s : "recommended";

    private static (string Light, string Dark) Tint(DualColor c) => (ItemView.SafeColor(c.Light), ItemView.SafeColor(c.Dark));

    // 옆 목록(M-01): 이번 호 · 분야(고른 분야마다) · 모아 보기 · 지난 호
    public SidebarView Sidebar() => new(model.State.Saved.Count, book.Scraps.Count,
        mag.Archive.Select(i => new ArchiveRow(i.Id, i.Title, i.Kind == IssueKind.Weekly)).ToList(), CurrentSort(),
        model.ChosenSections.Select(id =>
        {
            var s = Sections.ById(id);
            var (l, d) = Tint(s is null ? DualColor.Gray : DualColor.Fixed(s.Color));
            return new SideSection(id, s?.Name ?? id, s?.Icon ?? "cat.other", l, d);
        }).ToList());

    private ItemView View(NewsItem it, DateTimeOffset now)
    {
        lock (shown) shown[it.Key] = it;
        var v = ItemView.From(it, model, now);
        // 잡그림(로고·아바타 등)은 사진이 없는 것으로 — 사진 자리 없이 글만(맥 StoryCard·CoverStory)
        return v.Image is { } img && ImageKey.IsJunk(img) ? v with { Image = null } : v;
    }

    public static TopicView Topic(NewsItem it)
    {
        var (l, d) = Tint(it.TopicColor());
        return new TopicView(it.TopicLabel(), it.TopicIcon(), l, d);
    }

    private static Dictionary<string, TopicView> Topics(IEnumerable<NewsItem> items)
    {
        var o = new Dictionary<string, TopicView>();
        foreach (var it in items) o.TryAdd(it.Key, Topic(it));
        return o;
    }

    // 출처 이름(겹치지 않게, 앞에서부터 n곳)
    private static List<string> Names(IEnumerable<NewsItem> items, int n) => items.Select(i => i.SourceName).Distinct().Take(n).ToList();

    // 한 호(M-04~M-11·G-09·G-10). source: today · week · 지난 호 id. 없는 호면 null.
    // focus: 분야 칩·옆 목록 '분야'로 고른 한 분야(지면 이름 section:<id>), sub: AI 안의 하위 칩(모델·연구…)
    public async Task<IssueView?> IssueData(string source, string? sort = null, string? focus = null, string? sub = null)
    {
        if (sort is not null && Sorts.Contains(sort)) Prefs.Set("magSort", sort);
        var order = CurrentSort();
        var live = source is "today" or "week";
        if (focus is { Length: 0 }) focus = null;
        if (focus != Sections.Ai || sub is { Length: 0 }) sub = null;
        var built = await Task.Run(() =>
        {
            // 엮기 전에 판을 기억해 둔다(엮는 사이에 들어온 기사는 '새 소식' 띠로)
            var rev = mag.Revision;
            var img = mag.ImageRevision;
            var lay = mag.LayoutRevision;
            var issue = source switch
            {
                "today" => mag.LiveDaily(),
                "week" => mag.LiveWeekly(),
                _ => mag.Archive.FirstOrDefault(i => i.Id == source),
            };
            if (issue is null) return null;
            var r = mag.Resolve(issue);
            var size = r.Cover?.Cluster is { } c ? mag.Cluster(c)?.Size ?? 1 : 1;
            return new { r, size, rev, img, lay };
        });
        if (built is null) return null;
        var now = model.Now();
        var r = built.r;
        var preparing = mag.Preparing;

        // 분야 칩 줄(G-09): '전체' + 지면이 있는 분야(칩에 건수). 분야가 둘 이상이거나 한 분야를 볼 때만
        var counts = new Dictionary<string, int>();
        foreach (var p in r.Sections) if (p.Section.SectionId is { } sid) counts[sid] = counts.GetValueOrDefault(sid) + p.Items.Count;
        var chipIds = counts.Keys.ToList();
        if (focus is not null && !chipIds.Contains(focus) && Sections.ById(focus) is not null) chipIds.Add(focus);
        var chips = chipIds.Count > 1 || focus is not null
            ? chipIds.Select(id =>
            {
                var s = Sections.ById(id);
                var (l, d) = Tint(s is null ? DualColor.Gray : DualColor.Fixed(s.Color));
                return new ChipView(id, s?.Name ?? id, s?.Icon ?? "cat.other", l, d, counts.GetValueOrDefault(id));
            }).ToList()
            : new List<ChipView>();
        // AI 를 고르면 하위 칩(모델·연구·정책·투자·보안) 한 줄 더
        var subChips = focus == Sections.Ai
            ? Categories.All.Where(c => !c.IsOther()).Select(c => { var (l, d) = Tint(c.Color()); return new ChipView(c.Raw(), c.Label(), c.Glyph(), l, d, 0); }).ToList()
            : new List<ChipView>();

        // 한 분야만 볼 때는 표지 없이 그 분야 지면만(AI 하위 칩이면 그 분류만)
        var pages = focus is null ? r.Sections
            : r.Sections.Where(p => p.Section.SectionId == focus)
                .Select(p => (p.Section, Items: sub is null ? p.Items : p.Items.Where(i => i.Category.Raw() == sub).ToList()))
                .Where(p => p.Items.Count > 0).ToList();
        var cover = focus is null && r.Cover is { } cs ? new CoverView(View(cs.Item, now), cs.Cluster, built.size) : null;
        // M-12: 표지가 없으면 빈 지면 안내(첫 호를 엮는 중이면 그 안내)
        EmptyView? empty = null;
        if (focus is not null)
        {
            if (pages.Count == 0)
                empty = new EmptyView(false, live ? $"이번 호에는 아직 {Sections.Name(focus)} 소식이 없습니다" : $"이 호에는 {Sections.Name(focus)} 소식이 없습니다",
                    "새 소식이 들어오는 대로 지면이 채워집니다.");
        }
        else if (cover is null)
            empty = preparing && live
                ? new EmptyView(true, "첫 호를 엮는 중…", "구독한 출처에서 최근 사흘 소식을 모으고 번역하고 있어요. 잠시면 됩니다.")
                : new EmptyView(false, live ? "아직 이번 호에 실을 소식이 없습니다" : "이 호에는 소식이 없습니다", "새 소식이 들어오는 대로 지면이 채워집니다.");

        var glassIds = new List<string>();
        var sections = pages.Select(p =>
        {
            var (l, d) = Tint(p.Section.Color);
            // 주요 뉴스·그 밖의 소식처럼 여러 분야가 섞인 지면에서만 카드에 분야 표시
            var mixed = p.Section.Kind is null && (p.Section.SectionId is null || p.Section.SectionId == Sections.Top);
            var items = Sort(p.Items, order);
            // 분야 지면: 분야 고르기와 같은 유리 띠(구독 채널 지면·그 밖의 소식은 예전 머리 그대로)
            GlassView? glass = null;
            if (p.Section.Kind is null && p.Section.SectionId is { } sid && Sections.ById(sid) is not null)
            {
                glassIds.Add(sid);
                glass = new GlassView(SectionPhotos.English(sid), $"{items.Count}건 · " + (items.FirstOrDefault()?.DisplayTitle ?? ""), PhotoUrl(sid));
            }
            return new SectionView(p.Section.Id, p.Section.SectionId, p.Section.Label, p.Section.Glyph,
                p.Section.Kind is { } k ? "kind-" + k : "cat-" + p.Section.Category.Raw(), l, d, mixed,
                items.Select(i => View(i, now)).ToList(), glass);
        }).ToList();
        if (glassIds.Count > 0) LoadPhotos(glassIds);   // 아직 없는 분야만 찾는다(찾으면 'photos' 알림)

        // 오늘 호 완독(M-23): 오늘 호이고 한 분야만 보는 게 아닐 때 머리 아래 진행 막대
        var today = source == "today" && focus is null
            ? Today(TodayIssue.Keys(r.Cover?.Item.Key, r.Sections, model.ChosenSections), now) : null;
        // 저녁 정리(N-26): 오늘 호의 한 분야 지면 맨 위
        var brief = source == "today" && focus is not null ? BriefData(focus) : null;

        var all = (r.Cover is { } c0 && cover is not null ? new[] { c0.Item } : []).Concat(pages.SelectMany(p => p.Items)).ToList();
        // 해외·국내가 섞인 스토리의 카드에 두 줄(출처 이름 3곳까지)
        var regions = new Dictionary<string, RegionLines>();
        foreach (var it in pages.SelectMany(p => p.Items))
            if (r.Clusters.TryGetValue(it.Key, out var cid) && r.Regions?.GetValueOrDefault(cid) is { } story)
            {
                var (intl, kr) = Magazine.SplitByRegion(story);
                if (intl.Count > 0 && kr.Count > 0) regions[it.Key] = new RegionLines(Names(intl, 3), Names(kr, 3));
            }
        return new IssueView(r.Issue.Id, r.Issue.Title, live, r.Issue.Count, r.Issue.Sections.Count, order, cover, empty, sections, r.Clusters,
            built.rev, built.img, built.lay, preparing, focus, sub, chips, subChips, Topics(all), regions,
            today, source == "today" && TodayIssue.IsMarkedDone(now), brief);
    }

    // MARK: 오늘 호 완독(M-23) — 맥 TodayProgressView 와 같은 판단
    // 대표 기사를 다 읽으면 그날은 끝난 호로 정해 둔다(표지가 바뀌어도 그날은 '다 읽었어요', 새 소식 띠도 띄우지 않음)
    public TodayView Today(IReadOnlyList<string> keys, DateTimeOffset now)
    {
        var read = keys.Count(k => model.State.Read.ContainsKey(k));
        var all = keys.Count > 0 && read >= keys.Count;
        if (all && !TodayIssue.IsMarkedDone(now)) TodayIssue.MarkDone(now);
        var st = model.State.Settings;
        return new TodayView(keys.ToList(), read, all || TodayIssue.IsMarkedDone(now), TodayIssue.NextIssueText(st.DigestEnabled, st.DigestHour));
    }

    // MARK: 저녁 정리(N-26) — 오늘 만든 것이고 요약 줄이 있을 때만
    public const string BriefHelp = "이 PC 의 Ollama 가 아래 기사들의 제목·요약만 보고 만든 정리입니다. 틀릴 수 있어 근거 기사를 함께 둡니다.";

    public BriefView? BriefData(string section)
    {
        if (model.Brief(section) is not { Lines: { } lines } b) return null;
        lock (shown) foreach (var it in b.Items) shown[it.Key] = it;   // 근거 기사를 누르면 다시 찾게
        var s = Sections.ById(section);
        var (l, d) = Tint(s is null ? DualColor.Gray : DualColor.Fixed(s.Color));
        return new BriefView(section, $"저녁 정리 · {Sections.Name(section)}", RelativeTime.Clock(b.At), l, d, BriefHelp,
            lines.Select(x => new BriefLineView(x.Text, x.Refs.Where(i => i >= 0 && i < b.Items.Count).Select(i => i + 1).ToList())).ToList(),
            b.Items.Select(it => new BriefItemView(it.Key, it.Title, it.SourceName, it.Link)).ToList());
    }

    // MARK: 지면 넘기기(H-04): 옆 목록 순서 — 오늘·이번 주·분야들·스토리·저장·스크랩북·검색·지난 호
    public static List<string> PageOrder(IEnumerable<string> chosen, IEnumerable<string> archive) =>
        ["today", "week", .. chosen.Select(id => "section:" + id), "stories", "saved", "scrapbook", "search", .. archive.Select(id => "issue:" + id)];

    // 끝이면 null(부르는 쪽이 경고음). 한 스토리를 보는 중이면 '스토리' 자리에서
    public static string? Flip(string page, int dir, IReadOnlyList<string> order)
    {
        var here = page.StartsWith("story:", StringComparison.Ordinal) ? "stories" : page;
        var i = order.ToList().IndexOf(here);
        if (i < 0 || i + dir < 0 || i + dir >= order.Count) return null;
        return order[i + dir];
    }

    // MARK: 스토리(M-14)
    // 목록: 지금 커지는 스토리(최근 24시간)·지난 스토리(2주). 대표 사진·분야·다룬 출처·첫 보도/최근·새 보도 N·팔로우 표시
    public async Task<StoriesView> StoriesData()
    {
        var now = model.Now();
        var (live, past) = await Task.Run(() =>
        {
            var g = mag.StoryGroups(now);
            List<StoryCard> Cards(List<Database.Cluster> list) => list.Select(c => Card(c, mag.StoryItems(c.Id), now)).ToList();
            return (Cards(g.Live), Cards(g.Past));
        });
        return new StoriesView(live, past);
    }

    private StoryCard Card(Database.Cluster c, List<NewsItem> items, DateTimeOffset now)
    {
        var photo = items.Select(i => i.Image).FirstOrDefault(i => i is not null && !ImageKey.IsJunk(i));
        var lead = items.FirstOrDefault(i => i.Tier == "lab") ?? items.FirstOrDefault();
        var sources = items.GroupBy(i => i.SourceName).Take(6)
            .Select(g => new SourceChip(g.Key, g.First().Initial, ItemView.SafeColor(model.SourceById(g.First().SourceId)?.Color))).ToList();
        return new StoryCard(c.Id, c.Title, c.Size, model.UnseenReports(c), model.IsFollowing(c.Id), photo, lead is null ? null : Topic(lead), sources,
            $"첫 보도 {RelativeTime.Format(c.First, now)} · 최근 {RelativeTime.Format(c.Last, now)}");
    }

    // 한 스토리: 보도 줄기(먼저 보도한 곳부터, 간격·날짜·첫 문장) · 해외·국내 두 칸 · 팔로우. 열면 새 보도를 본 것으로
    public async Task<StoryView> StoryData(string id)
    {
        var (items, cluster) = await Task.Run(() => (mag.StoryItems(id), mag.Cluster(id)));
        model.MarkStorySeen(id, items.Count);
        var now = model.Now();
        var (intl, kr) = Magazine.SplitByRegion(items);
        RegionColumn? Col(string title, string icon, List<NewsItem> list) => intl.Count > 0 && kr.Count > 0
            ? new RegionColumn(title, icon, list.Count, list.Select(i => View(i, now)).ToList()) : null;
        return new StoryView(id, cluster?.Title ?? "스토리", $"{items.Count}곳 보도 · {Span(items)}", model.IsFollowing(id),
            items.Select((it, i) => new TimelineRow(View(it, now), RelativeTime.Clock(it.Date), i == 0, Gap(items, i), Lede(it))).ToList(),
            Col("해외에서는", "globe", intl), Col("국내에서는", "house", kr));
    }

    private static readonly CultureInfo Ko = new("ko-KR");

    // 보도가 이어진 기간
    public static string Span(IReadOnlyList<NewsItem> items)
    {
        var ds = items.Select(i => i.Date).OfType<DateTimeOffset>().ToList();
        if (ds.Count == 0) return "";
        var h = (ds.Max() - ds.Min()).TotalHours;
        return h < 1 ? "한 시간 안에 이어진 보도"
            : h < 48 ? $"{(int)Math.Round(h, MidpointRounding.AwayFromZero)}시간에 걸친 보도"
            : $"{(int)Math.Round(h / 24, MidpointRounding.AwayFromZero)}일에 걸친 보도";
    }

    // 앞 보도와의 간격: 날이 바뀌면 날짜, 아니면 'N시간 뒤'(30분 안이면 표시 안 함)
    public static string? Gap(IReadOnlyList<NewsItem> items, int i)
    {
        if (i <= 0 || items[i - 1].Date is not { } a || items[i].Date is not { } b) return null;
        var la = a.ToLocalTime();
        var lb = b.ToLocalTime();
        if (la.Date != lb.Date) return lb.ToString("M월 d일 (ddd)", Ko);
        var m = (b - a).TotalMinutes;
        if (m < 30) return null;
        return m < 90 ? $"{(int)Math.Round(m, MidpointRounding.AwayFromZero)}분 뒤" : $"{(int)Math.Round(m / 60, MidpointRounding.AwayFromZero)}시간 뒤";
    }

    private static readonly Regex Tags = new("<[^>]+>");
    private static readonly Regex Spaces = new(@"\s+");

    // 요약의 첫 문장(HTML 꼬리표 제거, 제목과 같으면 생략)
    public static string? Lede(NewsItem it)
    {
        var t = Spaces.Replace(Tags.Replace(it.Summary ?? "", " "), " ").Trim();
        var head = it.Title.Length > 20 ? it.Title[..20] : it.Title;
        if (t.Length <= 20 || t.StartsWith(head, StringComparison.Ordinal)) return null;
        return t.Length > 220 ? t[..220] : t;
    }

    // 저장 지면(M-15): 본문을 디스크에 받아 둔 기사는 "보관됨"
    public async Task<SavedView> SavedData()
    {
        var items = model.State.Saved.ToList();
        var archived = await Task.Run(() => ArticleService.Shared is { } svc
            ? items.Where(i => svc.Cached(i.Link) is not null).Select(i => i.Key).ToList()
            : new List<string>());
        var now = model.Now();
        return new SavedView(items.Select(i => View(i, now)).ToList(), archived, Topics(items));
    }

    // 검색(M-16): 입력 중에는 2글자부터, Enter 면 1글자도. 비우면 결과도 비움.
    public async Task<SearchView> SearchData(string q, bool submit)
    {
        if (q.Length == 0) return new SearchView(q, new());
        if (q.Length < 2 && !submit) return new SearchView(q, null);
        var list = await Task.Run(() => mag.Search(q));
        var now = model.Now();
        return new SearchView(q, list.Select(i => View(i, now)).ToList(), Topics(list));
    }

    // 스크랩북을 처음 열 때 폴더: 마지막으로 스크랩한 폴더, 없으면 내용이 있는 첫 폴더
    public static string InitialFolder(Scrapbook b)
    {
        if (Prefs.Get<string?>("lastScrapCollection", null) is { } last && b.Collections.Contains(last)) return last;
        return b.Collections.FirstOrDefault(c => b.Scraps.Any(s => s.Collection == c)) ?? Scrapbook.DefaultCollection;
    }

    // 스크랩북(M-17). repick: 보던 폴더가 비었으면 처음 폴더로 다시 고른다(다른 곳에 새 스크랩이 생겼을 때)
    public ScrapbookView ScrapbookData(string? folder, bool repick = false)
    {
        var scraps = book.Scraps;
        var f = folder is { } x && book.Collections.Contains(x) ? x : InitialFolder(book);
        if (repick && !scraps.Any(s => s.Collection == f)) f = InitialFolder(book);
        // 기사별로 묶기(최근 스크랩 순), 한 기사 안에서는 스크랩한 순서대로
        var order = new List<string>();
        var map = new Dictionary<string, List<Scrap>>();
        foreach (var s in scraps.Where(s => s.Collection == f))
        {
            if (!map.ContainsKey(s.Item.Key)) { order.Add(s.Item.Key); map[s.Item.Key] = new(); }
            map[s.Item.Key].Add(s);
        }
        var now = model.Now();
        var groups = order.Select(k => new ScrapGroup(View(map[k][0].Item, now),
            map[k].OrderBy(s => s.Created).Select(s => new ScrapView(s.Id, s.Quote, s.QuoteOriginal, s.Memo, s.Collection)).ToList())).ToList();
        return new ScrapbookView(f, book.Collections.Select(c => new FolderView(c, scraps.Count(s => s.Collection == c))).ToList(), scraps.Count, groups);
    }

    // 카드의 읽음·저장 표시만 다시(지면을 다시 엮지 않고)
    public object Marks(IEnumerable<string> keys)
    {
        var ks = keys.ToHashSet();
        return new
        {
            read = ks.Where(k => model.State.Read.ContainsKey(k)).ToList(),
            saved = model.State.Saved.Where(i => ks.Contains(i.Key)).Select(i => i.Key).ToList(),
        };
    }

    // MARK: 앱이 부르는 것
    // 한 번만: 새 기사·사진·스크랩·읽음 상태가 바뀌면 열린 매거진 창에 알린다(M-11)
    public void Attach()
    {
        if (attached) return;
        attached = true;
        mag.Changed += () => bridge.Emit(Name, "changed", Signal());
        mag.ImagesChanged += () => bridge.Emit(Name, "images", Signal());
        book.Changed += () => bridge.Emit(Name, "changed", Signal());
        model.Changed += () => bridge.Emit(Name, "changed", Signal());
        // 숨긴 출처·고른 분야가 바뀜: 화면은 띠 없이 바로 다시 엮는다(layoutRevision 이 바뀐 것으로 안다)
        mag.LayoutChanged += () => bridge.Emit(Name, "changed", Signal());
        // 분야 사진을 찾음: 유리 띠의 사진만 바꿔 끼운다(지면은 그대로)
        SectionPhotos.Shared.Changed += () => bridge.Emit(Name, "photos", SectionPhotos.Shared.All);
    }

    // 분야 → 사진 주소(찾은 것만)
    private Dictionary<string, string> PhotoUrls(JsonArray? ids)
    {
        var o = new Dictionary<string, string>();
        foreach (var n in ids ?? new())
            if (n is JsonValue v && v.TryGetValue<string>(out var id) && PhotoUrl(id) is { } u) o[id] = u;
        return o;
    }

    private object Signal() => new { revision = mag.Revision, imageRevision = mag.ImageRevision, layoutRevision = mag.LayoutRevision, preparing = mag.Preparing };

    // 이미 열린 창을 다른 지면으로(묶음 알림 › section:<id> 등). 새로 여는 창은 주소 ?page= 로.
    public void Go(string page) => bridge.Emit(Name, "go", page);

    public static string Url(string? page) => "magazine.html" + (page is { Length: > 0 } p ? "?page=" + Uri.EscapeDataString(p) : "");

    // MARK: 명령
    private async Task<NewsItem> Find(string key)
    {
        lock (shown) if (shown.TryGetValue(key, out var it)) return it;
        return await Task.Run(() => Lookup.Find(model, key, mag)) ?? throw new KeyNotFoundException("기사를 찾지 못함");
    }

    // 카드 오른쪽 클릭의 바로 줄이기(G-11, 맥 ReduceMenu): 이 출처 숨기기 / 이 분야 덜 받기(고른 분야이고 매거진만이 아닐 때) / 이 낱말 알리지 않기
    public ReduceView Reduce(NewsItem it)
    {
        var sec = model.NotifySection(it);
        var mode = model.Policy(sec).Mode;
        var less = model.ChosenSections.Contains(sec) && mode != NotifyMode.Magazine
            ? $"{Sections.Name(sec)} 덜 받기 — {(mode == NotifyMode.Instant ? "묶음으로" : "매거진에만")}" : null;
        return new ReduceView($"이 출처 숨기기 — {it.SourceName}", less, AppModel.TitleWords(it));
    }

    // 읽기 창 J·K 로 넘길 목록(H-05): 화면이 보낸 지면 순서의 key → 기사(화면에 보낸 것만)
    private List<NewsItem> Sequence(JsonArray? keys)
    {
        var o = new List<NewsItem>();
        if (keys is null) return o;
        lock (shown)
            foreach (var n in keys)
                if (n is JsonValue v && v.TryGetValue<string>(out var k) && shown.TryGetValue(k, out var it) && o.All(x => x.Key != k)) o.Add(it);
        return o;
    }

    private Scrap ScrapOf(string id) => book.Scraps.FirstOrDefault(s => s.Id == id) ?? throw new KeyNotFoundException("스크랩을 찾지 못함");

    public async Task<object?> Handle(string cmd, JsonObject a)
    {
        switch (cmd)
        {
            case "ready":
            case "sidebar": return Sidebar();
            case "issue": return await IssueData(a.Str("source", "today"), a.StrOrNull("sort"), a.StrOrNull("focus"), a.StrOrNull("sub"));
            case "stories": return await StoriesData();
            case "story": return await StoryData(a.Str("id"));

            // 스토리 팔로우: 새 보도가 붙으면 알림(지금 보도 수까지는 본 것으로)
            case "follow":
            {
                var id = a.Str("id");
                var size = await Task.Run(() => mag.StoryItems(id).Count);
                if (size == 0) throw new KeyNotFoundException("스토리를 찾지 못함");
                model.SetFollowing(id, a.Bool("on"), size);
                return new { following = model.IsFollowing(id) };
            }
            // 한눈에 요약: Ollama 가 있을 때만(없으면 칸을 띄우지 않음)
            case "canDigest": return await Summarizer.AvailableAsync();
            case "digest":
            {
                var id = a.Str("id");
                if (!await Summarizer.AvailableAsync() || await Task.Run(() => mag.Cluster(id)) is not { } c) return null;
                return await Task.Run(() => mag.StoryDigestAsync(c));
            }

            // 바로 줄이기(G-11)
            case "reduce": return Reduce(await Find(a.Str("key")));
            case "hideSource": model.HideSource((await Find(a.Str("key"))).SourceId); return null;
            case "lessOf": model.LessOf(model.NotifySection(await Find(a.Str("key")))); return null;
            case "muteWord":
            {
                var it = await Find(a.Str("key"));
                var w = a.Str("word");
                // 그 기사 제목에서 고른 낱말만(화면이 아무 낱말이나 넣지 못하게)
                if (!AppModel.TitleWords(it).Contains(w)) throw new InvalidOperationException("제목에 없는 낱말");
                model.MuteWord(w);
                return null;
            }
            case "saved": return await SavedData();
            case "search": return await SearchData(a.Str("q"), a.Bool("submit"));
            case "scrapbook": return ScrapbookData(a.StrOrNull("folder"), a.Bool("repick"));
            case "marks": return Marks((a["keys"] as JsonArray ?? new()).Select(n => n?.GetValue<string>() ?? ""));

            // 기사 열기: 기사·논문 등은 읽기 창, 영상·팟캐스트는 원래 앱·브라우저로
            case "open":
            {
                var it = await Find(a.Str("key"));
                model.MarkOpened(it);
                if (it.ItemKind.OpensExternally()) ExternalLink.Open(it.Link);
                else
                {
                    ReadingList.Remember(it, Sequence(a["seq"] as JsonArray));   // 연 지면(또는 저녁 정리 근거 기사)의 순서
                    platform.OpenReader(it);
                }
                return null;
            }
            case "toggleSaved": model.ToggleSaved(await Find(a.Str("key"))); return null;
            // 브라우저로: 키보드 O 는 읽음 처리까지(맥 ItemKeys.browser), 오른쪽 클릭 메뉴는 그대로
            case "browser":
            {
                var it = await Find(a.Str("key"));
                ExternalLink.Open(it.Link);
                if (a.Bool("read")) model.SetRead(it, true);
                return null;
            }
            case "toggleRead": { var it = await Find(a.Str("key")); model.SetRead(it, !model.IsRead(it)); return null; }
            case "todayProgress":
                return Today((a["keys"] as JsonArray ?? new()).Select(n => n?.GetValue<string>() ?? "").Where(k => k.Length > 0).ToList(), model.Now());
            case "flip":
            {
                var to = Flip(a.Str("page"), a.Bool("back") ? -1 : 1, PageOrder(model.ChosenSections, mag.Archive.Select(i => i.Id)));
                if (to is null) platform.Beep();
                return to;
            }
            case "photos": return PhotoUrls(a["ids"] as JsonArray);
            case "check": await model.CheckAllAsync(manual: false); return null;

            // 스크랩북(M-17·M-18)
            case "newFolder":
            {
                var name = a.Str("name");
                var ok = await Task.Run(() => book.CreateCollection(name));
                return new { ok, folder = name.Trim() };
            }
            case "renameFolder":
            {
                string from = a.Str("from"), to = a.Str("to");
                var ok = await Task.Run(() => book.Rename(from, to));
                return new { ok, folder = ok ? to.Trim() : from };
            }
            case "memo":
            {
                var s = ScrapOf(a.Str("id"));
                var memo = a.Str("memo");
                if (memo != s.Memo) await Task.Run(() => book.Update(s with { Memo = memo }));
                return null;
            }
            case "moveScrap":
            {
                var s = ScrapOf(a.Str("id"));
                var to = a.Str("to");
                if (!book.Collections.Contains(to)) throw new InvalidOperationException("없는 폴더");
                await Task.Run(() => book.Update(s with { Collection = to, Memo = a.StrOrNull("memo") ?? s.Memo }));
                return null;
            }
            case "deleteScrap": { var s = ScrapOf(a.Str("id")); await Task.Run(() => book.Remove(s)); return null; }
            case "copyMarkdown": platform.CopyText(book.Markdown(a.Str("folder"))); return null;
            case "saveMarkdown":
            {
                var f = a.Str("folder");
                return await platform.SaveTextFile($"{f}.md", book.Markdown(f));
            }
            case "close": platform.CloseWindow(Name); return null;
            default: throw new InvalidOperationException("모르는 명령 " + cmd);
        }
    }
}
