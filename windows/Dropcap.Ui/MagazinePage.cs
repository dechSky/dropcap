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
    // 화면에 보낸 보관 기사 줄(보관함은 한 번에 수천 줄 — shown 과 따로 두 묶음으로: 지금 것이 차면 앞 것을 버리고 지금 것을 앞으로).
    // 화면에 보이는 줄(최대 ArchiveLimitMax + OlderPage)은 늘 두 묶음 안에 있다
    private Dictionary<string, NewsItem> archShown = new(), archPrev = new();
    public const int ArchiveShownCap = 20_000;
    public const int ArchiveLimitMax = 10_000;
    private bool attached;

    // 분야 '오늘 얼굴' 사진(유리 띠). 시험에서는 바꿔 끼운다(바깥 피드를 받지 않게)
    public Action<IEnumerable<string>> LoadPhotos { get; set; } = ids => SectionPhotos.Shared.Load(ids);
    public Func<string, string?> PhotoUrl { get; set; } = id => SectionPhotos.Shared.Url(id);

    // MARK: 보기 데이터
    // 색은 라이트·다크 두 벌(#RRGGBB 만 — ItemView.SafeColor)
    public sealed record SideSection(string Id, string Name, string Icon, string Light, string Dark);
    public sealed record ArchiveRow(string Id, string Title, bool Weekly, bool Thin = false, int Count = 0, string? Reason = null);   // Thin: 기사가 너무 적은 호('기록 적음' — 흐리게, Reason 은 그 까닭)
    // 지난 호 묶음(이번 주 · 지난주 · 달별 — Folded 는 처음 접힘), EmptyDays: 그 기간에 호가 없는 날 수
    public sealed record ArchiveGroupView(string Id, string Title, List<ArchiveRow> Rows, int EmptyDays, bool Folded);
    // Checking·LastCheck: 새로 고침 단추(확인 중엔 눌리지 않음)와 '마지막 확인 n분 전'
    public sealed record SidebarView(int Saved, int Scraps, List<ArchiveRow> Archive, string Sort, List<SideSection> Sections,
        List<ArchiveGroupView>? Groups = null, bool Checking = false, string LastCheck = "");

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
        TodayView? Today = null, bool TodayDone = false, BriefView? Brief = null,
        string Head = "", string? Kicker = null, string? SectionPage = null, bool ChipsGo = false);
    // Head: 머리 숫자(M-25 — "소식 N건 중 M건 실음 · 분야 K개", 분야 지면은 "IT 소식 N건 중 M건 실음 · 출처 K곳")
    // SectionPage: 분야 지면(section:<id>)이면 그 분야 — 지면 머리(유리 띠)를 다시 달지 않는다
    // ChipsGo: 오늘 호의 분야 칩은 그 분야 지면으로 가는 길(칩 건수는 가는 곳과 달라 달지 않음)

    public sealed record SourceChip(string Name, string Initial, string Color);
    public sealed record StoryCard(string Id, string Title, int Size, int Fresh, bool Following, string? Photo, TopicView? Topic, List<SourceChip> Sources, string Times);
    public sealed record StoriesView(List<StoryCard> Live, List<StoryCard> Past);
    public sealed record TimelineRow(ItemView Item, string When, bool First, string? Gap, string? Lede);
    public sealed record RegionColumn(string Title, string Icon, int Count, List<ItemView> Items);
    public sealed record StoryView(string Id, string Title, string Sub, bool Following, List<TimelineRow> Items, RegionColumn? Intl, RegionColumn? Kr);

    public sealed record SavedView(List<ItemView> Items, List<string> Archived, Dictionary<string, TopicView> Topics, int Count = 0);   // Count: 왼쪽 목록 '저장 N' 과 같은 수
    public sealed record SearchView(string Q, List<ItemView>? Items, Dictionary<string, TopicView>? Topics = null,
        List<string>? Watch = null, List<string>? Recent = null,
        bool Archive = true, List<ArchivedRowView>? Older = null, bool OlderMore = false, int OlderNext = 0, string Found = "");   // Items 가 null 이면 화면은 앞 결과를 그대로 둔다. 빈 검색이면 지켜볼 낱말·최근 검색 칩
    // Archive: '오래된 기사 포함' 켜짐, Older: 보관 표에서 찾은 오래된 기사(최신순 200건씩), OlderNext: '더 보기'가 이어 꺼낼 자리, Found: 'N건' 줄

    // 보관함(지난 기사) 한 줄: 때 · 분야 점 · 제목 · 출처. Original: 한국어 제목이 있으면 원제목(오른쪽 클릭 메뉴)
    public sealed record ArchivedRowView(string Key, string Id, string Title, string? Original, string Source, string Section, string SectionName,
        string Light, string Dark, string When);
    public sealed record PeriodView(string Id, string Label);
    public sealed record DayBarView(string Key, string Label, int Count);   // 날짜별 건수 막대 하나(월·연). Key 는 그날 'yyyy-MM-dd'
    public sealed record FacetView(string Id, string Label, int Count);     // 분야·출처 거르기 메뉴 한 줄
    public sealed record DayIssueView(string Id, string Title);             // 일 보기의 '이 날의 호 보기'
    public sealed record ArchivePageView(string Period, List<PeriodView> Periods, string Anchor, string Title, string Head,
        bool CanPrev, bool CanNext, bool AtToday, List<ArchivedRowView> Items, bool More, int Total, int Limit,
        List<DayBarView>? Bars, int Peak, string? BarFrom, string? BarTo,
        string? Section, string SectionLabel, string? Source, string SourceLabel, List<FacetView> Sections, List<FacetView> Sources,
        DayIssueView? DayIssue, string? Empty);

    public sealed record FolderView(string Name, int Count);
    public sealed record ScrapView(string Id, string? Quote, string? Original, string Memo, string Collection);
    public sealed record ScrapGroup(ItemView Item, List<ScrapView> Scraps);
    public sealed record ScrapbookView(string Folder, List<FolderView> Folders, int Total, List<ScrapGroup> Groups, WeeklyView? Weekly = null);
    // 이번 주 모은 문장(M-27): 일요일 17시부터 스크랩북 첫머리에 지난 7일 문단 스크랩(최근 것부터 6개, 같은 문장은 한 번)
    public sealed record WeeklyQuote(string Key, string Quote, string Source, string Title, string Color);
    public sealed record WeeklyView(string Count, List<WeeklyQuote> Items);

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

    // 옆 목록(M-01): 이번 호 · 분야(고른 분야마다) · 모아 보기 · 지난 호(날짜 묶음)
    private static ArchiveRow Row(Issue i) => new(i.Id, i.Title, i.Kind == IssueKind.Weekly, i.IsThin, i.Count, Magazine.ThinReason(i));
    public SidebarView Sidebar() => new(model.State.Saved.Count, book.Scraps.Count,
        mag.Archive.Select(Row).ToList(), CurrentSort(),
        model.ChosenSections.Select(id =>
        {
            var s = Sections.ById(id);
            var (l, d) = Tint(s is null ? DualColor.Gray : DualColor.Fixed(s.Color));
            return new SideSection(id, s?.Name ?? id, s?.Icon ?? "cat.other", l, d);
        }).ToList(),
        Magazine.ArchiveGroups(mag.Archive, DateTime.Now).Select(g => new ArchiveGroupView(g.Id, g.Id == "this" ? "지난 호 · 이번 주" : g.Title, g.Issues.Select(Row).ToList(), g.EmptyDays, g.Folded)).ToList(),
        model.Checking, Magazine.LastCheckText(model.State.LastCheck, DateTimeOffset.Now));

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

    // 한 호(M-04~M-11·G-09·G-10·M-25). source: today · week · section:<분야 id> · 지난 호 id. 없는 호면 null.
    // focus: 분야 칩·옆 목록 '분야'로 고른 한 분야(지면 이름 section:<id>), sub: AI 안의 하위 칩(모델·연구…)
    public async Task<IssueView?> IssueData(string source, string? sort = null, string? focus = null, string? sub = null)
    {
        if (sort is not null && Sorts.Contains(sort)) Prefs.Set("magSort", sort);
        var order = CurrentSort();
        // 분야 지면(M-25): 오늘 호 기간의 그 분야 칩이 달린 기사만으로 따로 엮은 호(표지·건수도 그 분야). 칩은 AI 하위 칩만
        var sectionPage = source.StartsWith("section:", StringComparison.Ordinal) ? source["section:".Length..] : null;
        if (sectionPage is { Length: 0 }) return null;
        var live = source is "today" or "week" || sectionPage is not null;
        if (sectionPage is not null) focus = null;
        if (focus is { Length: 0 }) focus = null;
        if ((focus ?? sectionPage) != Sections.Ai || sub is { Length: 0 }) sub = null;
        var built = await Task.Run(() =>
        {
            // 엮기 전에 판을 기억해 둔다(엮는 사이에 들어온 기사는 '새 소식' 띠로)
            var rev = mag.Revision;
            var img = mag.ImageRevision;
            var lay = mag.LayoutRevision;
            var issue = sectionPage is not null ? mag.LiveSection(sectionPage) : source switch
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
        var chips = sectionPage is null && (chipIds.Count > 1 || focus is not null)
            ? chipIds.Select(id =>
            {
                var s = Sections.ById(id);
                var (l, d) = Tint(s is null ? DualColor.Gray : DualColor.Fixed(s.Color));
                return new ChipView(id, s?.Name ?? id, s?.Icon ?? "cat.other", l, d, counts.GetValueOrDefault(id));
            }).ToList()
            : new List<ChipView>();
        // AI 를 고르면 하위 칩(모델·연구·정책·투자·보안) 한 줄 더
        // 분야 지면 'AI' 는 그 분류 기사가 있는 하위 칩만 건수와 함께('기타'까지 — 칩 숫자의 합이 실린 수와 같게, 맥 AISubChips)
        var subChips = sectionPage == Sections.Ai
            ? Categories.All.Select(c => (c, n: (r.Cover is { } c1 ? new[] { c1.Item } : []).Concat(r.Sections.SelectMany(p => p.Items)).Count(i => i.Category.Raw() == c.Raw())))
                .Where(x => x.n > 0).Select(x => { var (l, d) = Tint(x.c.Color()); return new ChipView(x.c.Raw(), x.c.Label(), x.c.Glyph(), l, d, x.n); }).ToList()
            : focus == Sections.Ai
            ? Categories.All.Where(c => !c.IsOther()).Select(c => { var (l, d) = Tint(c.Color()); return new ChipView(c.Raw(), c.Label(), c.Glyph(), l, d, 0); }).ToList()
            : new List<ChipView>();

        // 한 분야만 볼 때는 표지 없이 그 분야 지면만(AI 하위 칩이면 그 분류만). 분야 지면은 표지째 하위 칩으로 거른다
        var pages = sectionPage is not null
            ? r.Sections.Select(p => (p.Section, Items: sub is null ? p.Items : p.Items.Where(i => i.Category.Raw() == sub).ToList())).Where(p => p.Items.Count > 0).ToList()
            : focus is null ? r.Sections
            : r.Sections.Where(p => p.Section.SectionId == focus)
                .Select(p => (p.Section, Items: sub is null ? p.Items : p.Items.Where(i => i.Category.Raw() == sub).ToList()))
                .Where(p => p.Items.Count > 0).ToList();
        var cover = focus is null && r.Cover is { } cs && (sub is null || cs.Item.Category.Raw() == sub) ? new CoverView(View(cs.Item, now), cs.Cluster, built.size) : null;
        // M-12: 표지가 없으면 빈 지면 안내(첫 호를 엮는 중이면 그 안내)
        EmptyView? empty = null;
        if ((focus ?? sectionPage) is { } one && (focus is not null || cover is null))
        {
            if (pages.Count == 0)
                empty = new EmptyView(false, live ? $"이번 호에는 아직 {Sections.Name(one)} 소식이 없습니다" : $"이 호에는 {Sections.Name(one)} 소식이 없습니다",
                    "새 소식이 들어오는 대로 지면이 채워집니다.");
        }
        else if (cover is null)
            empty = preparing && live
                ? new EmptyView(true, "첫 호를 엮는 중…", "구독한 출처에서 최근 일주일 소식을 모으고 번역하고 있어요. 잠시면 됩니다.")
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
            if (sectionPage is null && p.Section.Kind is null && p.Section.SectionId is { } sid && Sections.ById(sid) is not null)
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
        var brief = (source == "today" ? focus : sectionPage) is { } bsec ? BriefData(bsec) : null;

        var all = (r.Cover is { } c0 && cover is not null ? new[] { c0.Item } : []).Concat(pages.SelectMany(p => p.Items)).ToList();
        // 해외·국내가 섞인 스토리의 카드에 두 줄(출처 이름 3곳까지)
        var regions = new Dictionary<string, RegionLines>();
        foreach (var it in pages.SelectMany(p => p.Items))
            if (r.Clusters.TryGetValue(it.Key, out var cid) && r.Regions?.GetValueOrDefault(cid) is { } story)
            {
                var (intl, kr) = Magazine.SplitByRegion(story);
                if (intl.Count > 0 && kr.Count > 0) regions[it.Key] = new RegionLines(Names(intl, 3), Names(kr, 3));
            }
        // 머리: 왼쪽 목록에서 고른 것과 같은 이름, 숫자는 지면에 실린 것 기준(맥 IssueView.headTitle·kicker·subtitle)
        var shownCount = (cover is null ? 0 : 1) + pages.Sum(p => p.Items.Count);
        var head = sectionPage is { } sp
            ? Magazine.Subtitle(r.Issue.Count, shownCount, 0, Sections.Name(sp) + " 소식") + $" · 출처 {all.Select(i => i.SourceId).Distinct().Count()}곳"
            : Magazine.Subtitle(r.Issue.Count, shownCount, pages.Count(p => p.Section.Kind is null));
        var title = sectionPage is { } sp2 ? Sections.Name(sp2) : source == "week" ? r.Issue.Title.Replace("주간 · ", "이번 주 · ") : r.Issue.Title;
        var kicker = sectionPage is not null ? "오늘 호의 분야 지면 · " + r.Issue.Title.Replace(" 호", "")
            : source switch { "today" => "오늘", "week" => "이번 주", _ => r.Issue.IsThin ? "지난 호 · 기록 적음" : "지난 호" };
        return new IssueView(r.Issue.Id, title, live, r.Issue.Count, r.Issue.Sections.Count, order, cover, empty, sections, r.Clusters,
            built.rev, built.img, built.lay, preparing, focus, sub, chips, subChips, Topics(all), regions,
            today, source == "today" && TodayIssue.IsMarkedDone(now), brief,
            head, kicker, sectionPage, source == "today" && focus is null);
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

    // MARK: 지면 넘기기(H-04): 옆 목록 순서 — 오늘·이번 주·분야들·스토리·저장·스크랩북·검색·지난 호·보관함
    public static List<string> PageOrder(IEnumerable<string> chosen, IEnumerable<string> archive) =>
        ["today", "week", .. chosen.Select(id => "section:" + id), "stories", "saved", "scrapbook", "search", .. archive.Select(id => "issue:" + id), "archive"];

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
        // 상태(본 보도 수·팔로우·출처)는 여기서 떠 두고 뒤 스레드는 사본만 읽는다(상태 사전을 뒤 스레드에서 읽으면 동시에 고쳐질 때 깨질 수 있다)
        var snap = new StorySnapshot(model.SourceFilter, new Dictionary<string, int>(model.State.StorySeen), model.State.FollowedStories.ToHashSet(),
            model.AllSources.GroupBy(s => s.Id).ToDictionary(g => g.Key, g => (string?)g.First().Color));
        var (live, past) = await Task.Run(() =>
        {
            // 스토리·출처별 수·보도 견본을 문장 세 번으로 한꺼번에, 카드에 보도를 넘긴다(스토리마다 DB 를 다시 묻지 않게)
            var g = Magazine.StoryCardGroups(mag.StoryCards(snap.Filter, now), now);
            List<StoryCard> Cards(List<Magazine.StoryCard> list) => list.Select(c => Card(c.Cluster, c.Items, now, snap)).ToList();
            return (Cards(g.Live), Cards(g.Past));
        });
        return new StoriesView(live, past);
    }

    private sealed record StorySnapshot(SourceFilter Filter, Dictionary<string, int> Seen, HashSet<string> Followed, Dictionary<string, string?> Colors);

    private static StoryCard Card(Database.Cluster c, List<NewsItem> items, DateTimeOffset now, StorySnapshot snap)
    {
        var photo = items.Select(i => i.Image).FirstOrDefault(i => i is not null && !ImageKey.IsJunk(i));
        var sources = items.GroupBy(i => i.SourceName).Take(6)
            .Select(g => new SourceChip(g.Key, g.First().Initial, ItemView.SafeColor(Color(g.First().SourceId)))).ToList();
        var fresh = Math.Max(0, c.Size - (snap.Seen.TryGetValue(c.Id, out var s) ? s : c.Size));   // AppModel.UnseenReports 와 같은 셈
        return new StoryCard(c.Id, c.Title, c.Size, fresh, snap.Followed.Contains(c.Id), photo, StoryTopicView(items), sources,
            $"첫 보도 {RelativeTime.Format(c.First, now)} · 최근 {RelativeTime.Format(c.Last, now)}");

        string? Color(string id) => snap.Colors.TryGetValue(id, out var col) ? col : Resources.Config.Sources.FirstOrDefault(x => x.Id == id)?.Color;
    }

    // 스토리의 분야 표시(M-26): 묶인 보도들의 다수결(대표 기사 하나의 AI 하위 분류를 그대로 쓰면 IT 소식이 'AI·모델'이 됐다 — 맥과 같음)
    public static TopicView? StoryTopicView(IReadOnlyList<NewsItem> items)
    {
        if (Magazine.StoryTopic(items, it => Sections.Primary(it)) is not { } t) return null;   // 대표 분야만(칩까지 가리지 않게 — 목록을 뒤 스레드에서 만들 때)
        var ns = Sections.ById(t.Section);
        var (l, d) = Tint(t.Category is { } c ? c.Color() : ns is null ? DualColor.Gray : DualColor.Fixed(ns.Color));
        return new TopicView(t.Category is { } c2 ? "AI·" + c2.Label() : Sections.Name(t.Section), t.Category?.Glyph() ?? ns?.Icon ?? "cat.other", l, d);
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

    private static readonly Regex Spaces = new(@"\s+");

    // 요약의 첫 문장(HTML 꼬리표 제거, 제목과 같으면 생략)
    public static string? Lede(NewsItem it)
    {
        var t = Spaces.Replace(Plain.StripTags(it.Summary ?? ""), " ").Trim();
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
        return new SavedView(items.Select(i => View(i, now)).ToList(), archived, Topics(items), items.Count);
    }

    // 검색(M-16): 입력 중에는 2글자부터, Enter 면 1글자도. 비우면 결과도 비움.
    // '오래된 기사 포함'(archive — 주면 기억)이 켜져 있으면 보관 표에서도 찾는다: 최근 결과와 같은 링크는 빼고 최신순 200건
    public async Task<SearchView> SearchData(string q, bool submit, bool? archive = null)
    {
        q = Archive.TrimQuery(q);
        if (archive is { } on) Prefs.Set(SearchArchiveKey, on);
        var include = IncludeArchive;
        if (q.Length == 0) return new SearchView(q, new(), null, model.State.Settings.WatchKeywords.ToList(), RecentSearches, include);
        if (q.Length < 2 && !submit) return new SearchView(q, null, Archive: include);
        var filter = model.SourceFilter;   // 숨긴·꺼진 출처는 보관 기사에서도 뺀다(상태는 여기서 떠 둔다)
        var (list, older) = await Task.Run(() => (mag.Search(q), include ? mag.SearchArchive(q, 0, OlderPage, filter) : new List<ArchivedItem>()));
        if (submit) Prefs.Set(RecentKey, Magazine.RememberSearch(q, RecentSearches));   // Enter 로 찾은 낱말만 최근 검색에(입력 중 앞부분은 남기지 않음)
        var now = model.Now();
        var links = list.Select(i => i.Link).ToHashSet();
        var shownOlder = older.Where(a => !links.Contains(a.Link)).ToList();
        var more = older.Count >= OlderPage;
        return new SearchView(q, list.Select(i => View(i, now)).ToList(), Topics(list), Archive: include,
            Older: shownOlder.Select(a => Row(a, true)).ToList(), OlderMore: more, OlderNext: older.Count, Found: Found(list.Count, shownOlder.Count, more));
    }

    // 오래된 기사 '200건 더 보기': offset 부터 다음 200건(화면이 이미 보인 줄은 Id 로 건너뜀)
    public async Task<object> SearchMore(string q, int offset, int recent, int shownOlder)
    {
        q = Archive.TrimQuery(q);
        var filter = model.SourceFilter;
        var older = await Task.Run(() => mag.SearchArchive(q, Math.Max(0, offset), OlderPage, filter));
        var more = older.Count >= OlderPage;
        return new { older = older.Select(a => Row(a, true)).ToList(), olderMore = more, olderNext = offset + older.Count, found = Found(recent, shownOlder + older.Count, more) };
    }

    public const int OlderPage = 200;
    public const string SearchArchiveKey = "magSearchArchive";   // 맥과 같은 키(화면 설정이라 prefs.json)
    public static bool IncludeArchive => Prefs.Get(SearchArchiveKey, true);

    // 'N건' 줄: 오래된 기사가 없으면 최근 건수만
    public static string Found(int recent, int older, bool more) =>
        older == 0 ? $"{recent}건" : $"최근 {recent}건 · 오래된 기사 {older}{(more ? "건 넘음" : "건")}";

    // MARK: 보관함(지난 기사)
    public const int ArchivePageSize = 100;
    public const string ArchivePeriodKey = "archivePeriod";   // 맥과 같은 키 — 마지막으로 고른 기간(처음엔 월)

    // 보관 기사 한 줄(누르면 읽기 창 — 화면에 보낸 것으로 기억해 다시 찾는다)
    private ArchivedRowView Row(ArchivedItem a, bool showDay)
    {
        var it = a.ToNewsItem();
        lock (shown)
        {
            if (archShown.Count >= ArchiveShownCap) { archPrev = archShown; archShown = new(); }
            archShown[it.Key] = it;
        }
        var s = Sections.ById(a.Section);
        var (l, d) = Tint(s is null ? DualColor.Gray : DualColor.Fixed(s.Color));
        return new ArchivedRowView(it.Key, a.Id, a.DisplayTitle, a.TitleKo is null ? null : a.Title, a.Source, a.Section, Sections.Name(a.Section), l, d, When(a.Date, showDay));
    }

    // 줄의 때: 일 보기는 시각만, 그 밖은 '월/일 시각'
    public static string When(DateTimeOffset date, bool showDay)
    {
        var t = date.LocalDateTime;
        var time = t.ToString("HH:mm", CultureInfo.InvariantCulture);
        return showDay ? $"{t.Month}/{t.Day} {time}" : time;
    }

    // 보관함 한 기간. period·anchor('yyyy-MM-dd')가 없으면 마지막 기간·오늘. 거르기 값이 메뉴에 없는 것이어도 그대로 거른다(건수 0)
    public async Task<ArchivePageView> ArchiveData(string? period, string? anchor, string? section, string? source, int limit, DateTime? nowOverride = null)
    {
        var p = Archive.ParsePeriod(period ?? Prefs.Get<string?>(ArchivePeriodKey, null));
        if (period is not null) Prefs.Set(ArchivePeriodKey, p.Raw());
        var nowLocal = nowOverride ?? DateTime.Now;
        var day = ClampDay(Archive.ParseDay(anchor) ?? nowLocal.Date);
        var (from, to) = Archive.Range(p, day);
        limit = Math.Clamp(limit <= 0 ? ArchivePageSize : limit, 1, ArchiveLimitMax);
        if (section is { Length: 0 }) section = null;
        if (source is { Length: 0 }) source = null;
        var filter = model.SourceFilter;   // 숨긴·꺼진 출처는 목록·건수·거르기 메뉴에서 뺀다(상태는 여기서 떠 둔다)
        var (page, earliest) = await Task.Run(() => (mag.ArchivePeriod(new DateTimeOffset(from), new DateTimeOffset(to), section, source, limit, filter), mag.EarliestRecord()));

        List<DayBarView>? bars = null;
        var peak = 1;
        if (p.ShowsBars() && page.Total > 0)
        {
            peak = Math.Max(1, page.DayCounts.Values.DefaultIfEmpty(0).Max());
            bars = Archive.Days(from, to).Select(d => new DayBarView(Archive.DayKey(d), Archive.Title(Archive.Period.Day, d), page.DayCounts.GetValueOrDefault(Archive.DayKey(d)))).ToList();
        }
        // 건수 많은 순(분야는 같은 건수면 분야 순서, 출처는 이름 순)
        var secs = page.Sections.OrderByDescending(kv => kv.Value).ThenBy(kv => Sections.Order(kv.Key))
            .Select(kv => new FacetView(kv.Key, Sections.Name(kv.Key), kv.Value)).ToList();
        var srcs = page.Sources.Where(kv => kv.Key.Length > 0).OrderByDescending(kv => kv.Value).ThenBy(kv => kv.Key, StringComparer.Ordinal)
            .Select(kv => new FacetView(kv.Key, kv.Key, kv.Value)).ToList();
        var dayIssue = p == Archive.Period.Day && mag.Archive.FirstOrDefault(i => i.Id == "daily-" + Magazine.DayId(from)) is { } di
            ? new DayIssueView(di.Id, di.Title) : null;
        var showDay = p != Archive.Period.Day;
        return new ArchivePageView(p.Raw(), Archive.Periods.Select(x => new PeriodView(x.Raw(), x.Label())).ToList(), Archive.DayKey(from), Archive.Title(p, from),
            $"기사 {page.Total}건" + (page.More ? $" · 최신순 {page.Items.Count}건 보는 중" : ""),
            earliest is { } e && new DateTimeOffset(from) > e, to <= nowLocal, Archive.Range(p, nowLocal).From == from,
            page.Items.Select(a => Row(a, showDay)).ToList(), page.More, page.Total, limit,
            bars, peak, bars is null ? null : Archive.DayKey(from).Replace("-", ". "), bars is null ? null : Archive.DayKey(to.AddDays(-1)).Replace("-", ". "),
            section, section is null ? "모든 분야" : Sections.Name(section), source, source ?? "모든 출처", secs, srcs, dayIssue,
            page.Items.Count > 0 ? null : section is null && source is null ? "이 기간에는 모인 기사가 없습니다." : "거른 조건에 맞는 기사가 없습니다.");
    }

    // ◀ ▶: 한 기간 앞뒤의 기준 날('yyyy-MM-dd')
    public static string ShiftAnchor(string? period, string? anchor, int n) =>
        Archive.DayKey(ClampDay(Archive.Shift(Archive.ParsePeriod(period), ClampDay(Archive.ParseDay(anchor) ?? DateTime.Now.Date), n)));

    // 기준 날은 1971~9998년 안으로(0001-01-01 의 ◀ · 9999년 연 보기 끝처럼 DateTime 범위를 넘는 계산을 막는다)
    public static DateTime ClampDay(DateTime d) =>
        d < new DateTime(1971, 1, 1) ? new DateTime(1971, 1, 1) : d > new DateTime(9998, 12, 31) ? new DateTime(9998, 12, 31) : d;

    // 최근 검색어(맥 magRecentSearches 와 같은 키 — 화면 설정이라 prefs.json)
    public const string RecentKey = "magRecentSearches";
    public static List<string> RecentSearches => Prefs.Get(RecentKey, new List<string>());

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
        return new ScrapbookView(f, book.Collections.Select(c => new FolderView(c, scraps.Count(s => s.Collection == c))).ToList(), scraps.Count, groups, Weekly(scraps, now));
    }

    // 이번 주 모은 문장(M-27 — 맥 WeeklyQuotes): 일요일 저녁이 아니거나 고를 문장이 없으면 null
    public WeeklyView? Weekly(IReadOnlyList<Scrap> scraps, DateTimeOffset now)
    {
        if (!WeeklyQuotes.IsSundayEvening(now)) return null;
        var list = WeeklyQuotes.Pick(scraps, now);
        if (list.Count == 0) return null;
        return new WeeklyView($"{list.Count}개 · 지난 7일", list.Select(s =>
        {
            var v = View(s.Item, now);   // 두 번 누르면 읽기 창(화면에 보낸 기사로 기억)
            return new WeeklyQuote(v.Key, s.Quote ?? "", v.Source, v.Title, v.Color);
        }).ToList());
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
        lock (shown) if (shown.TryGetValue(key, out var it) || archShown.TryGetValue(key, out it) || archPrev.TryGetValue(key, out it)) return it;
        // 두 묶음에서 밀려난 보관 줄(아주 긴 '더 보기')은 key 의 링크로 연다(본문은 링크에서 다시 받는다)
        var prefix = ArchivedItem.ReaderSource + "|";
        if (key.StartsWith(prefix, StringComparison.Ordinal) && key[prefix.Length..] is { Length: > 0 } link)
            return new NewsItem { Id = link, Title = link, Link = link, SourceId = ArchivedItem.ReaderSource, Summary = "", Tier = "" };
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
                if (n is JsonValue v && v.TryGetValue<string>(out var k) && (shown.TryGetValue(k, out var it) || archShown.TryGetValue(k, out it) || archPrev.TryGetValue(k, out it))
                    && o.All(x => x.Key != k)) o.Add(it);
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
            // 저장 목록 위 '주소로 추가…'(I-05): 피드에 없는 기사 주소를 나중에 읽기로
            case "addUrl":
            {
                var r = await SaveLink.SaveAsync(model, a.Str("url"));
                return new { ok = r.Ok, message = r.Item is { } it ? "저장함 · " + it.DisplayTitle : SaveLink.Message(r.Error ?? SaveLink.Failure.NotUrl) };
            }
            case "search": return await SearchData(a.Str("q"), a.Bool("submit"), a["archive"] is JsonValue ? a.Bool("archive") : null);
            case "searchMore": return await SearchMore(a.Str("q"), a.Int("offset"), a.Int("recent"), a.Int("shown"));
            // 보관함: 기간 보기 · ◀ ▶
            case "archive": return await ArchiveData(a.StrOrNull("period"), a.StrOrNull("anchor"), a.StrOrNull("section"), a.StrOrNull("source"), a.Int("limit", ArchivePageSize));
            case "archiveShift": return ShiftAnchor(a.StrOrNull("period"), a.StrOrNull("anchor"), Math.Sign(a.Int("by")));
            case "clearRecentSearches": Prefs.Set(RecentKey, new List<string>()); return await SearchData("", false);
            case "scrapbook": return ScrapbookData(a.StrOrNull("folder"), a.Bool("repick"));
            case "marks": return Marks((a["keys"] as JsonArray ?? new()).Select(n => n?.GetValue<string>() ?? ""));

            // 기사 열기: 기사·논문 등은 읽기 창, 영상·팟캐스트는 원래 앱·브라우저로
            case "open":
            {
                var it = await Find(a.Str("key"));
                // 보관 기사는 읽기 창만(관심사·읽음 기록에 넣지 않음 — 맥 ArchiveRow 와 같음)
                if (it.SourceId != ArchivedItem.ReaderSource) model.MarkOpened(it);
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
                // 보관 기사는 읽음 기록에 넣지 않는다(open 과 같음)
                if (a.Bool("read") && it.SourceId != ArchivedItem.ReaderSource) model.SetRead(it, true);
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
            case "check": await model.CheckAllAsync(manual: true); return null; // 새로 고침 단추·Ctrl+R 같은 길

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
            case "settings": platform.OpenSettings(); return null; // 옆 목록 맨 아래 '설정' 줄 · Ctrl+,
            case "close": platform.CloseWindow(Name); return null;
            default: throw new InvalidOperationException("모르는 명령 " + cmd);
        }
    }
}
