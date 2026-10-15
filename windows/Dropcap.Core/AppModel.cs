namespace Dropcap.Core;

// 화면 쪽이 해 줄 일(알림 창·시스템 알림·읽기 창). 윈도우 앱이 구현하고, 시험은 가짜로 바꿔 끼운다.
public interface IAppUi
{
    void ShowToasts(IReadOnlyList<NewsItem> items, bool sound);
    void ShowInfo(string title, string sub);
    void ShowDigest(int count);
    void ShowWelcome();
    void PostSystem(IReadOnlyList<NewsItem> items, bool sound);
    void ShowBundle(string section, IReadOnlyList<NewsItem> items, bool sound);     // 묶음 한 방울("경제 7건", G-07)
    void PostBundle(string section, IReadOnlyList<NewsItem> items, bool sound);     // 시스템 알림 방식의 묶음
    void OpenReader(NewsItem item);
    // 지켜볼 낱말 하루 정리("오늘 ○○ 소식 3건", N-27) — 누르면 매거진 검색
    void ShowWatch(string word, IReadOnlyList<NewsItem> items, bool sound) { }
    void PostWatch(string word, IReadOnlyList<NewsItem> items, bool sound) { }
}

// 앱의 두뇌: 확인 → 거르기 → 번역 → 묶기 → 알리기. 맥 AppModel 과 같은 순서·수치.
// 화면 스레드에서 Start 를 부르면, await 뒤 이어지는 일도 화면 스레드로 돌아온다(맥 @MainActor 와 같음).
// 네트워크·번역은 비동기, DB 는 Task.Run 으로 화면 밖에서(Q-07).
public sealed class AppModel
{
    public static AppModel? Shared { get; private set; }

    public AppState State { get; private set; }
    public bool Checking { get; private set; }
    public bool FirstRun { get; }
    public Magazine Magazine { get; }
    public IAppUi Ui { get; set; }
    public event Action? Changed;

    public static readonly TimeSpan MaxAge = TimeSpan.FromDays(3); // 날짜가 3일보다 오래된 글은 새 글로 치지 않음(C-09)
    public const int RecentLimit = 300; // 검색해서 다시 찾을 수 있게 넉넉히(C-22)
    public const string PreviewId = "preview";

    public Func<DateTimeOffset> Now { get; set; } = () => DateTimeOffset.Now;
    public FocusMonitor Focus { get; } = new() { Override = FocusMonitor.ParseOverride(Environment.GetEnvironmentVariable("DROPCAP_TEST_FOCUS")) };
    internal FeedService Feeds { get; set; } = FeedService.Shared;

    private CancellationTokenSource? loop;
    private Timer? minuteTimer;
    private readonly bool persist;

    public AppModel(IAppUi ui, Magazine magazine, AppState? state = null, bool persist = true)
    {
        Ui = ui;
        Magazine = magazine;
        this.persist = persist;
        FirstRun = state is null && !Store.Exists;
        State = state ?? Store.Load();
        Magazine.Interest = InterestWeight;
        Magazine.Filter = () => SourceFilter;
        Magazine.Chosen = () => State.SectionsChosen;
        Magazine.Limits = () => State.Settings.Limits;
        Magazine.IsFollowed = id => State.FollowedStories.Contains(id);
        Translator.Shared.ModeSource = () => State.Settings.TranslateEngine;   // 번역 방식(W4)
        Shared = this;
    }

    private void Save() { if (persist) Store.Save(State); Changed?.Invoke(); }

    // MARK: 시작
    public void Start(SynchronizationContext? ui = null)
    {
        Magazine.MigrateIfNeeded(State);
        if (!State.MagazineBackfilled) _ = BackfillMagazineAsync();
        RestartLoop();
        // 1분마다: 아침 브리핑 시각인지, 잠시 끄기가 끝났는지
        var ctx = ui ?? SynchronizationContext.Current;
        minuteTimer = new Timer(_ =>
        {
            if (ctx is not null) ctx.Post(_ => MinuteTick(), null); else MinuteTick();
        }, null, TimeSpan.FromSeconds(60), TimeSpan.FromSeconds(60));
        // 시험 폴더로 띄운 시험 실행은 사용자 화면에 환영 알림을 띄우지 않는다(DROPCAP_TEST_WELCOME 으로만 확인)
        if (FirstRun && (Environment.GetEnvironmentVariable("DROPCAP_DATA_DIR") is null || Environment.GetEnvironmentVariable("DROPCAP_TEST_WELCOME") is not null))
            Ui.ShowWelcome();
    }

    // 잠자기에서 깨면 10초 뒤 확인(C-11)
    public async void OnWake()
    {
        await Task.Delay(TimeSpan.FromSeconds(10));
        await CheckAllAsync();
    }

    private void RestartLoop()
    {
        loop?.Cancel();
        var cts = loop = new CancellationTokenSource();
        RunLoop(cts.Token);
    }

    private async void RunLoop(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            // 간격을 바꿔 이 반복이 취소돼도 진행 중인 확인은 끝까지 간다(취소 토큰을 넘기지 않음)
            try { await CheckAllAsync(); } catch { }
            try { await Task.Delay(TimeSpan.FromMinutes(Math.Clamp(State.Settings.IntervalMinutes, 1, 24 * 60)), ct); } catch (TaskCanceledException) { return; }
        }
    }

    // MARK: 확인
    public async Task CheckAllAsync(bool manual = false)
    {
        if (Checking) return;
        Checking = true;
        Changed?.Invoke();
        try
        {
            var active = AllSources.Where(s => State.Enabled.GetValueOrDefault(s.Id)).ToList();
            var results = await Task.WhenAll(active.Select(async src =>
            {
                try { return (src, Items: await Feeds.ItemsAsync(src), Error: (string?)null); }
                catch (Exception e) { return (src, Items: (List<NewsItem>?)null, Error: e.Message); }
            }));
            var found = new List<NewsItem>();
            foreach (var (src, items, error) in results)
            {
                if (error is not null) { State.Errors[src.Id] = error; continue; }
                State.Errors.Remove(src.Id);
                if (items is not null) found.AddRange(await FreshAsync(items, src));
            }

            found = found.OrderByDescending(i => i.Date ?? DateTimeOffset.MinValue).ToList();
            if (found.Count > 0) found = await TranslateTitlesAsync(found);
            found = ApplyKeywords(found); // 번역 뒤에: 한국어 낱말도 영어 기사에 걸리게(C-14)
            found = await AddEnglishTitlesAsync(found);
            found = found.Where(i => !State.HiddenSources.Contains(i.SourceId)).ToList(); // 숨긴 출처는 스토리 대표로도 다시 나오지 않게 처음부터 뺀다(G-11)
            var forMagazine = found.ToList();
            await Task.Run(() => Magazine.Ingest(forMagazine)); // 매거진에는 묶이기 전 전부(여러 시각 비교용)
            NotifyGrownStories();
            // 출처 단위로 알림을 끈 곳(논문·커뮤니티)은 매거진에만 싣고, 목록·알림에는 넣지 않는다(C-25)
            var candidates = found.Where(i => Notifies(i.SourceId)).ToList();
            var listed = GroupSameStory(candidates);
            State.Recent = listed.Concat(State.Recent).Take(RecentLimit).ToList();
            State.Unread += listed.Count;
            State.LastCheck = Now();
            State.Seen = Store.Pruned(State.Seen); // 저장 파일만이 아니라 메모리의 기억도 정리(오래 켜 두면 끝없이 커지던 문제)
            // 분야 정책(G-04~G-08): 즉시 알릴 것 · 묶음으로 고일 것 · 매거진에만 둘 것
            var quiet = IsHushed && !manual; // 방해 금지 시간·잠시 끄기·회의 중: 알리지 않고 안 읽은 소식으로만 쌓는다
            var drops = await Task.Run(() => Decide(candidates, listed, quiet));
            Save();
            await Task.Run(() => Magazine.PublishDue()); // 확인을 마친 뒤에 지난 호를 엮어 빠지는 기사가 없게
            if (quiet) return;
            if (manual && drops.Count == 0 && listed.Count > 0)
            {
                Ui.ShowInfo($"새 소식 {listed.Count}건", "알릴 만큼 큰 소식은 없어 목록·매거진에만 실었어요"); // N-16
                return;
            }
            // 중요 표시가 붙은 소식을 먼저
            Deliver(drops.OrderBy(i => i.Important == true ? 0 : 1).ToList(), manual);
        }
        finally
        {
            Checking = false;
            Changed?.Invoke();
        }
    }

    private static async Task<List<NewsItem>> TranslateTitlesAsync(List<NewsItem> items)
    {
        var titles = await Translator.Shared.TranslateManyAsync(items.Select(i => i.Title).ToList());
        return items.Select((it, i) => titles[i] != it.Title ? it with { TitleKo = titles[i] } : it).ToList();
    }

    // MARK: 분야별 알림(G 절)
    public bool NeedsOnboarding => State.SectionsChosen is null;
    public List<string> ChosenSections => State.SectionsChosen ?? new();
    public SectionPolicy Policy(string section) => State.SectionPolicy.GetValueOrDefault(section) ?? new SectionPolicy();
    public void SetPolicy(string section, Func<SectionPolicy, SectionPolicy> change)
    {
        var old = Policy(section);
        var p = change(old);
        if (p.Mode == NotifyMode.Instant && old.Mode != NotifyMode.Instant) p = p with { Less = false }; // 설정에서 즉시로 되돌리면 '덜 받기'도 풂
        State.SectionPolicy[section] = p;
        Save();
    }

    // 알림을 정할 때 쓰는 분야: 고른 분야에 걸린 칩이 있으면 그것, 없으면 대표 분야
    public string NotifySection(NewsItem it) => NotifySection(it, ChosenSections);
    public static string NotifySection(NewsItem it, IReadOnlyCollection<string> chosen) =>
        it.SectionChips().FirstOrDefault(chosen.Contains) ?? it.Section();

    private int SentToday(string? section, DateTimeOffset now) =>
        State.NotifyLog.Count(m => m.At.ToLocalTime().Date == now.ToLocalTime().Date && (section is null || m.Section == section));

    // 이번에 들어온 소식마다(같은 이야기는 하나로) 알림·고임·매거진만을 정한다. 떨어뜨릴 소식을 돌려준다.
    internal List<NewsItem> Decide(List<NewsItem> items, List<NewsItem> listed, bool quiet)
    {
        var now = Now();
        State.NotifyLog.RemoveAll(m => m.At.ToLocalTime().Date != now.ToLocalTime().Date);
        var nowSec = now.ToUnixTimeMilliseconds() / 1000.0;
        State.NotifiedStories = State.NotifiedStories.Where(p => nowSec - p.Value < 36 * 3600).ToDictionary(p => p.Key, p => p.Value);
        State.Pending.RemoveAll(p => now - p.At > TimeSpan.FromHours(36));   // 고인 지 36시간 지난 것은 버림
        if (items.Count == 0 || State.SectionsChosen is null) return new();
        var chosen = ChosenSections.ToHashSet();
        var limits = State.Settings.Limits;
        var filter = SourceFilter;
        var rank = new Dictionary<string, int> { ["lab"] = 0, ["press"] = 1, ["kr"] = 2 };
        // 같은 이야기끼리 모아 대표 하나(공식 발표 > 언론 > 국내, 그다음 최신)
        var order = new List<string>();
        var groups = new Dictionary<string, List<NewsItem>>();
        foreach (var it in items)
        {
            var story = Magazine.ClusterId(it.Key) ?? "item:" + it.Key;
            if (!groups.ContainsKey(story)) { order.Add(story); groups[story] = new(); }
            groups[story].Add(it);
        }
        var drops = new List<NewsItem>();
        foreach (var story in order)
        {
            if (State.NotifiedStories.ContainsKey(story)) continue;
            var g = groups[story];
            var rep = g.OrderBy(i => rank.GetValueOrDefault(i.Tier, 3)).ThenByDescending(i => i.Date ?? DateTimeOffset.MinValue).First();
            var sec = NotifySection(rep);
            var cov = Magazine.RegionCoverage(rep, filter);
            var input = new NotifyPolicy.Input
            {
                Chosen = chosen.Contains(sec), Policy = Policy(sec), Coverage = cov,
                Lab = g.Any(i => i.Tier == "lab"), Important = g.Any(i => i.Important == true), Followed = State.FollowedStories.Contains(story),
                Watched = g.Any(i => i.Watch is not null),
                SentInSection = SentToday(sec, now), SentTotal = SentToday(null, now),
            };
            var top = chosen.Contains(Sections.Top)
                ? new NotifyPolicy.Input { Chosen = true, Policy = Policy(Sections.Top), Coverage = cov, SentInSection = SentToday(Sections.Top, now), SentTotal = SentToday(null, now) }
                : null;
            var (decision, viaTop) = NotifyPolicy.DecideWithTop(input, top, limits);
            if (decision == NotifyDecision.Drop && !quiet)
            {
                var shown = listed.FirstOrDefault(i => i.Key == rep.Key) ?? rep;
                if (shown.Related is null && g.Count > 1) shown = shown with { Related = g.Where(i => i.Key != rep.Key).Select(i => i.SourceName).ToList() };
                drops.Add(shown);
                State.NotifyLog.Add(new AppState.NotifyMark(viaTop ? Sections.Top : sec, now));
                State.NotifiedStories[story] = nowSec;
                State.Pending.RemoveAll(p => p.Story == story);
            }
            else if (decision != NotifyDecision.Quiet)
            {
                // 방해 금지 중에 떨어질 소식도 고였다가 다음 묶음으로
                if (!State.Pending.Any(p => p.Story == story)) State.Pending.Add(new AppState.PendingItem(rep, sec, story, now));
            }
        }
        return drops;
    }

    // 묶음(G-07): 분야마다 정한 시각이 지나면 고인 소식을 한 방울로("경제 7건"). 분야마다 하루 한 번.
    public void DeliverBundles()
    {
        if (State.Pending.Count == 0 || IsHushed) return;   // 방해 금지·잠시 끄기·회의 중이면 끝난 뒤로
        var now = Now();
        var changed = false;
        foreach (var sec in State.Pending.Select(p => p.Section).Distinct().OrderBy(Sections.Order).ToList())
        {
            if (!NotifyPolicy.BundleDue(Policy(sec).BundleHour, now, State.LastBundle.TryGetValue(sec, out var l) ? l : null)) continue;
            var list = State.Pending.Where(p => p.Section == sec).Select(p => p.Item).ToList();
            State.Pending.RemoveAll(p => p.Section == sec);
            State.LastBundle[sec] = now;
            changed = true;
            if (State.Settings.Style == ToastStyle.Drop) Ui.ShowBundle(sec, list, State.Settings.Sound);
            else Ui.PostBundle(sec, list, State.Settings.Sound);
            if (Policy(sec).Mode == NotifyMode.Bundle) MakeBrief(sec, list, now);
        }
        if (changed) Save();
    }

    // 분야별 저녁 정리(N-26): '묶음' 분야는 묶음을 보낼 때 기기 안 요약 3줄 + 근거 기사를 매거진 그 분야 지면 위에 둔다.
    // 알림 문구는 그대로 원제목(D-7) — 요약은 지면 안에서만, 근거 링크와 함께.
    public Func<string, IReadOnlyList<NewsItem>, Task<List<SectionBrief.Line>?>> Briefer { get; set; } =
        (sec, items) => Summarizer.BriefingAsync(Sections.Name(sec), items);

    public void MakeBrief(string sec, IReadOnlyList<NewsItem> items, DateTimeOffset now)
    {
        var evidence = items.Take(SectionBrief.MaxItems).ToList();
        State.Briefs[sec] = new SectionBrief { Section = sec, At = now, Items = evidence };
        if (evidence.Count < 2) return;
        _ = MakeBriefLinesAsync(sec, evidence, now);
    }

    private async Task MakeBriefLinesAsync(string sec, List<NewsItem> evidence, DateTimeOffset at)
    {
        List<SectionBrief.Line>? lines;
        try { lines = await Briefer(sec, evidence); } catch { lines = null; }
        if (lines is null || !State.Briefs.TryGetValue(sec, out var b) || b.At != at) return;
        State.Briefs[sec] = b with { Lines = lines };
        Save();
    }

    // 오늘 만든 저녁 정리(요약이 있는 것만)
    public SectionBrief? Brief(string sec)
    {
        if (!State.Briefs.TryGetValue(sec, out var b) || b.Lines is null) return null;
        return b.At.ToLocalTime().Date == Now().ToLocalTime().Date ? b : null;
    }

    // 관심 분야 고르기(G-03). 처음이면 고른 분야의 기본 출처를 켜고 그 분야 최근 소식으로 매거진을 채운다(알림 없음).
    public void ChooseSections(IEnumerable<string> ids)
    {
        var before = (State.SectionsChosen ?? new()).ToHashSet();
        var first = State.SectionsChosen is null;
        var ordered = ids.Distinct().OrderBy(Sections.Order).ToList();
        State.SectionsChosen = ordered;
        var defaults = NotifyPolicy.Defaults(ordered);
        foreach (var id in ordered) if (!State.SectionPolicy.ContainsKey(id)) State.SectionPolicy[id] = defaults[id];
        var turnedOn = new HashSet<string>();
        foreach (var (id, m) in Sections.Meta)
        {
            if (m.Section is not { } sec) continue;
            var on = ordered.Contains(sec);
            if (on && (first || !before.Contains(sec)) && m.DefaultOn == true)
            {
                if (State.Enabled.GetValueOrDefault(id) != true) turnedOn.Add(id);
                State.Enabled[id] = true;
            }
            else if (!on && (first || before.Contains(sec)))
            {
                State.Enabled[id] = false;
            }
        }
        State.Pending.RemoveAll(p => !ordered.Contains(p.Section));
        SubscriptionsChanged();   // 뺀 분야의 출처 글은 바로 안 보이게(S-13)
        if (turnedOn.Count > 0) _ = BackfillMagazineAsync(turnedOn);
    }

    // 출처 수(켜짐/전체)
    public (int On, int All) SourceCount(string section)
    {
        var ids = Sections.Meta.Values.Where(m => m.Section == section).Select(m => m.Id).ToList();
        return (ids.Count(id => State.Enabled.GetValueOrDefault(id)), ids.Count);
    }

    // MARK: 보여 줄 출처(S-13 — SourceFilter 한 곳)
    public SourceFilter SourceFilter => ShowAllSourcesForTests ? new SourceFilter { Hidden = State.HiddenSources.ToHashSet() } : SourceFilter.Make(State, AllSources);
    // 시험용: 출처 목록에 없는 가짜 출처 id 를 쓰는 예전 시험은 켜짐 여부를 따지지 않고 숨긴 출처만 뺀다(맥 SourceFilter.active = nil 과 같음)
    internal bool ShowAllSourcesForTests { get; set; }
    // 트레이 창 목록·안 읽음 수가 쓰는 최근 소식(꺼진·해지한·숨긴 출처 글은 빠짐, 지우지는 않음)
    public List<NewsItem> VisibleRecent => SourceFilter.Visible(State.Recent);

    // 구독(출처 켜기·끄기·해지·분야·숨기기)이 바뀐 뒤: 알림 대기열에서 빠진 출처 글을 빼고, 안 읽음 수를 맞추고, 열린 화면을 바로 갱신
    private void SubscriptionsChanged()
    {
        var f = SourceFilter;
        State.Pending.RemoveAll(p => !f.Shows(p.Item.SourceId));
        State.Unread = Math.Min(State.Unread, f.Visible(State.Recent).Count(i => !IsRead(i)));
        Save();
        Magazine.Refresh();
    }

    // MARK: 바로 줄이기(G-11)
    public void HideSource(string id)
    {
        if (State.HiddenSources.Contains(id)) return;
        State.HiddenSources.Add(id);
        State.Recent.RemoveAll(i => i.SourceId == id);
        SubscriptionsChanged();
    }

    public void UnhideSource(string id)
    {
        State.HiddenSources.Remove(id);
        SubscriptionsChanged();
    }

    public void LessOf(string section)
    {
        SetPolicy(section, p => p with { Mode = p.Mode == NotifyMode.Instant ? NotifyMode.Bundle : NotifyMode.Magazine, Less = true });
        Ui.ShowInfo(Policy(section).Mode == NotifyMode.Bundle ? "이 분야는 저녁 묶음으로 모아 드릴게요" : "이 분야는 매거진에만 실을게요",
                    $"{Sections.Name(section)} · 설정 › 분야에서 되돌리기");
    }

    public void MuteWord(string word)
    {
        var w = word.Trim();
        if (w.Length == 0) return;
        Update(s => { if (!s.MuteKeywords.Contains(w)) s.MuteKeywords.Add(w); });
        State.Pending.RemoveAll(p => $"{p.Item.Title} {p.Item.TitleKo ?? ""}".ToLowerInvariant().Contains(w.ToLowerInvariant()));
        Save();
    }

    // 낱말 고르기 메뉴에 보일 제목 낱말
    public static List<string> TitleWords(NewsItem it)
    {
        var text = string.Join(" ", new[] { it.TitleKo, it.Title }.OfType<string>());
        HashSet<string> stop = ["the", "and", "for", "with", "from", "that", "this", "into", "over", "after", "about", "new", "says", "its", "how", "why", "what"];
        var o = new List<string>();
        var cur = new System.Text.StringBuilder();
        void Flush()
        {
            var p = cur.ToString();
            cur.Clear();
            if (p.Length >= 2 && !o.Contains(p) && !stop.Contains(p.ToLowerInvariant()) && !p.All(char.IsDigit)) o.Add(p);
        }
        foreach (var c in text) { if (char.IsLetterOrDigit(c) || c == '-') cur.Append(c); else Flush(); }
        Flush();
        return o.Take(12).ToList();
    }

    // MARK: 스토리 팔로우
    public bool IsFollowing(string story) => State.FollowedStories.Contains(story);
    public void SetFollowing(string story, bool on, int size)
    {
        State.FollowedStories.Remove(story);
        if (on) State.FollowedStories.Add(story);
        State.StorySeen[story] = size;
        Save();
    }
    public void MarkStorySeen(string story, int size)
    {
        if (State.StorySeen.TryGetValue(story, out var s) && s == size) return;
        State.StorySeen[story] = size;
        Save();
    }
    public int UnseenReports(Database.Cluster c) => Math.Max(0, c.Size - (State.StorySeen.TryGetValue(c.Id, out var s) ? s : c.Size));

    // 팔로우한 스토리에 새 보도가 붙으면 알림(그 출처의 알림을 꺼 두었어도)
    private void NotifyGrownStories()
    {
        var grown = Magazine.TakeGrown();
        if (grown.Count == 0 || IsHushed) return;
        foreach (var (c, it) in grown.Take(2)) Ui.ShowInfo($"팔로우한 스토리에 새 보도 · {it.SourceName}", c.Title);
    }

    // MARK: 거르기·묶기
    public List<Source> AllSources => Resources.Config.Sources.Concat(State.CustomSources).ToList();

    public Source? SourceById(string id) => AllSources.FirstOrDefault(s => s.Id == id) ?? Resources.Config.Sources.FirstOrDefault(s => s.Id == id);

    private static List<string> Words(IEnumerable<string> list) => list.Select(w => w.Trim().ToLowerInvariant()).Where(w => w.Length > 0).ToList();

    // '알리지 않음' 낱말이 든 소식은 빼고, '꼭 알림' 낱말이 든 소식은 중요 표시(C-14)
    public List<NewsItem> ApplyKeywords(IEnumerable<NewsItem> items)
    {
        var mute = Words(State.Settings.MuteKeywords);
        var must = Words(State.Settings.MustKeywords);
        var watch = WatchWords.Normalized(State.Settings.WatchKeywords);
        var o = new List<NewsItem>();
        foreach (var it in items)
        {
            var text = $"{it.Title} {it.TitleKo ?? ""} {it.Summary}".ToLowerInvariant();
            if (mute.Any(text.Contains)) continue;
            var x = must.Any(text.Contains) ? it with { Important = true } : it;
            if (watch.Count > 0) x = x with { Watch = WatchWords.Match(x, watch) };
            o.Add(x);
        }
        return o;
    }

    // 낱말 설정이 바뀌면 이미 받은 최근 목록에도 바로: ★ 다시 매기고, '알리지 않음' 낱말이 든 기사는 목록에서 뺌
    public void ReapplyKeywords()
    {
        State.Recent = ApplyKeywords(State.Recent.Select(i => i with { Important = null, Watch = null }));
        Save();
    }

    // 여러 곳이 같은 소식을 다루면 하나만 알리고 "다른 N곳도 보도"로 묶는다(C-15).
    // 공식 발표 > 언론 > 국내 순으로 대표를 고른다.
    public List<NewsItem> GroupSameStory(IEnumerable<NewsItem> items)
    {
        var rank = new Dictionary<string, int> { ["lab"] = 0, ["press"] = 1, ["kr"] = 2 };
        var sorted = items.OrderBy(i => rank.GetValueOrDefault(i.Tier, 3)).ThenByDescending(i => i.Date ?? DateTimeOffset.MinValue).ToList();
        var kept = new List<NewsItem>();
        var cutoff = Now().AddHours(-36);
        foreach (var it in sorted)
        {
            var i = kept.FindIndex(k => StoryMatch.Same(it, k));
            if (i >= 0)
            {
                kept[i] = kept[i] with { Related = (kept[i].Related ?? new()).Append(it.SourceName).ToList() };
                continue;
            }
            // 하루 반 안에 이미 알린 소식과 같으면 알리지 않고 그 소식에 출처만 더한다
            var j = State.Recent.FindIndex(r => (r.Date ?? DateTimeOffset.MinValue) > cutoff && StoryMatch.Same(it, r));
            if (j >= 0)
            {
                var r = State.Recent[j];
                if (!(r.Related ?? new()).Contains(it.SourceName) && r.SourceName != it.SourceName)
                    State.Recent[j] = r with { Related = (r.Related ?? new()).Append(it.SourceName).ToList() };
                continue;
            }
            kept.Add(it);
        }
        return kept.OrderByDescending(i => i.Date ?? DateTimeOffset.MinValue).ToList();
    }

    public bool IsQuietTime
    {
        get
        {
            var st = State.Settings;
            if (!st.QuietEnabled || st.QuietStart == st.QuietEnd) return false;
            return InQuiet(Now().ToLocalTime().Hour, st.QuietStart, st.QuietEnd);
        }
    }

    // 회의·발표 중 자동 조용히(N-25): 지금 그 이유(설정에서 켠 것만)
    public FocusReason? AutoQuietReason => Focus.Reason(State.Settings, Now());
    // 알리지 않을 때: 방해 금지 시간 · 잠시 끄기 · 회의·발표 중
    public bool IsHushed => IsQuietTime || IsSnoozed || AutoQuietReason is not null;

    // 자정을 넘는 구간(예: 23시~7시)도 처리(C-19)
    public static bool InQuiet(int hour, int start, int end)
    {
        if (start == end) return false;
        return start < end ? hour >= start && hour < end : hour >= start || hour < end;
    }

    // 본 글 기억(C-08): 처음 켠 출처는 기존 글을 알리지 않고 기억만, 피드에 다시 보이면 시각 갱신
    private async Task<List<NewsItem>> FreshAsync(List<NewsItem> items, Source src)
    {
        var firstTime = !State.Seeded.Contains(src.Id);
        var now = Now();
        var o = new List<NewsItem>();
        foreach (var it in items)
        {
            var known = State.Seen.ContainsKey(it.Key);
            State.Seen[it.Key] = now.ToUnixTimeMilliseconds() / 1000.0; // 피드에 남아 있는 동안은 지워지지 않게 시각 갱신
            if (known || firstTime) continue;
            if (it.Date is { } d && now - d > MaxAge) continue;
            o.Add(it);
        }
        if (firstTime) State.Seeded.Add(src.Id);

        var kept = new List<NewsItem>();
        foreach (var it0 in o)
        {
            var it = it0;
            if (src.Type == "sitemap") it = await Feeds.FillTitleAsync(it);
            if (src.AiOnly && !Resources.AiRegex.IsMatch($"{it.Title} {it.Summary}")) continue; // C-10
            kept.Add(it);
        }
        return kept;
    }

    private void Deliver(List<NewsItem> items, bool manual)
    {
        if (items.Count == 0)
        {
            if (manual) Ui.ShowInfo("새 소식이 없습니다", $"마지막 확인 {RelativeTime.Clock(State.LastCheck)}");
            return;
        }
        if (State.Settings.Style == ToastStyle.Drop) Ui.ShowToasts(items, State.Settings.Sound);
        else Ui.PostSystem(items, State.Settings.Sound);
        ArticleService.Shared?.Prefetch(items.Take(3)); // 누르기 전에 미리 본문·번역·요약 준비(R-16)
    }

    // MARK: 동작
    public void Open(NewsItem item)
    {
        if (item.Id == PreviewId) return;
        MarkRead();
        SetRead(item, true);
        NoteInterest(item);
        Ui.OpenReader(item);
    }

    // 처음 한 번: 켜진 출처에서 최근 3일 기사를 받아 매거진 첫 호를 채운다(알림 없음)(M-12)
    private async Task BackfillMagazineAsync(IReadOnlySet<string>? only = null)
    {
        Magazine.Preparing = true;
        Magazine.NotifyChanged();
        try
        {
            var cutoff = Now().AddDays(-3);
            var all = new List<NewsItem>();
            foreach (var src in AllSources.Where(s => State.Enabled.GetValueOrDefault(s.Id) && (only?.Contains(s.Id) ?? true)))
            {
                List<NewsItem>? items;
                try { items = await Feeds.ItemsAsync(src, conditional: false); } catch { continue; }
                if (items is null) continue;
                items = items.Where(i => (i.Date ?? DateTimeOffset.MinValue) > cutoff).ToList();
                if (src.Type == "sitemap")
                {
                    items = items.Take(10).ToList();
                    for (var i = 0; i < items.Count; i++) items[i] = await Feeds.FillTitleAsync(items[i]);
                }
                if (src.AiOnly) items = items.Where(i => Resources.AiRegex.IsMatch($"{i.Title} {i.Summary}")).ToList();
                all.AddRange(items.Take(25));
            }
            all = await TranslateTitlesAsync(all);
            all = await AddEnglishTitlesAsync(all);
            var ordered = ApplyKeywords(all).OrderBy(i => i.Date ?? DateTimeOffset.MinValue).ToList();
            await Task.Run(() => { Magazine.Ingest(ordered); Magazine.PublishDue(); });
            State.MagazineBackfilled = true;
            Save();
        }
        finally
        {
            Magazine.Preparing = false;
            Magazine.NotifyChanged();
        }
    }

    // 한국어 제목 기사에 영어 제목을 붙인다(외국 기사와 같은 소식인지 비교하려고)(T-04)
    private static async Task<List<NewsItem>> AddEnglishTitlesAsync(List<NewsItem> items)
    {
        var idx = Enumerable.Range(0, items.Count).Where(i => !Translator.LooksForeign(items[i].Title) && items[i].TitleEn is null).ToList();
        if (idx.Count == 0) return items;
        var en = await Translator.Shared.ToEnglishAsync(idx.Select(i => items[i].Title).ToList());
        var o = items.ToList();
        for (var k = 0; k < idx.Count; k++) o[idx[k]] = o[idx[k]] with { TitleEn = en[k] };
        return o;
    }

    // 매거진에서 연 기사(읽기 창은 부르는 쪽이 연다)
    public void MarkOpened(NewsItem item)
    {
        if (item.Id == PreviewId) return;
        SetRead(item, true);
        NoteInterest(item);
    }

    // MARK: 관심사(C-18): 연 기사의 분야·출처를 세어 지면 순서와 점수에 반영
    private void NoteInterest(NewsItem item)
    {
        var c = item.Category.Raw();
        State.InterestCategory[c] = State.InterestCategory.GetValueOrDefault(c) + 1;
        State.InterestSource[item.SourceId] = State.InterestSource.GetValueOrDefault(item.SourceId) + 1;
        Save();
    }

    // 0 ~ 1.5 사이. 많이 본 분야·출처일수록 크다
    public double InterestWeight(NewsCategory category, string? source)
    {
        var cats = State.InterestCategory;
        var srcs = State.InterestSource;
        var cmax = Math.Max(cats.Values.DefaultIfEmpty(0).Max(), 1);
        var smax = Math.Max(srcs.Values.DefaultIfEmpty(0).Max(), 1);
        var c = Math.Log(1 + cats.GetValueOrDefault(category.Raw())) / Math.Log(1 + cmax);
        var s = source is null ? 0 : Math.Log(1 + srcs.GetValueOrDefault(source)) / Math.Log(1 + smax);
        return 1.0 * c + 0.5 * s;
    }

    // MARK: 잠시 끄기·브리핑·단축키
    public bool IsSnoozed => (State.SnoozeUntil ?? DateTimeOffset.MinValue) > Now();

    public void Snooze(DateTimeOffset? until)
    {
        State.SnoozeUntil = until;
        Save();
    }

    // C-20: 1시간·3시간·내일 아침 8시까지
    public static DateTimeOffset TomorrowMorning(DateTimeOffset now, int hour = 8)
    {
        var t = now.ToLocalTime().Date.AddDays(1).AddHours(hour);
        return new DateTimeOffset(t);
    }

    public void MinuteTick()
    {
        var now = Now();
        if (State.SnoozeUntil is { } s && s <= now) { State.SnoozeUntil = null; Save(); }
        if (now.ToLocalTime().Minute % 30 == 0) _ = Task.Run(() => Magazine.PublishDue()); // 지난 호 발행(M-05)
        DeliverBundles();   // 분야 묶음 시각이 지났으면 고인 소식을 한 방울로(G-07)
        DeliverWatchDigest();   // 지켜볼 낱말 하루 정리(N-27)
        var st = State.Settings;
        if (!st.DigestEnabled) return;
        var local = now.ToLocalTime();
        if (!DigestWindow(local.Hour, st.DigestHour) || (State.LastDigest is { } ld && ld.ToLocalTime().Date == local.Date)) return;
        if (IsHushed) return; // 조용한 때가 끝나면 그날 안에 다시 시도
        State.LastDigest = now;
        Save();
        var items = DigestItems;
        if (items.Count == 0) return;
        Ui.ShowDigest(items.Count); // C-21
    }

    // 지켜볼 낱말 하루 정리(N-27): 아침 브리핑 시각(브리핑을 꺼도 그 시각)에 지난 24시간 동안 낱말마다 걸린 소식 수.
    // 조용한 때면 끝난 뒤 그날 안에 다시 시도. 정리 물방울은 세 개까지(낱말 순서), 숨긴 출처 제외
    public void DeliverWatchDigest()
    {
        var words = WatchWords.Normalized(State.Settings.WatchKeywords);
        var now = Now();
        var local = now.ToLocalTime();
        if (words.Count == 0 || !DigestWindow(local.Hour, State.Settings.DigestHour)
            || (State.LastWatchDigest is { } lw && lw.ToLocalTime().Date == local.Date) || IsHushed) return;
        State.LastWatchDigest = now;
        Save();
        var recent = Magazine.RecentItems(now.AddHours(-24));   // 보이는 출처만(S-13)
        foreach (var (word, items) in WatchWords.Digest(recent, words).Take(3))
        {
            if (State.Settings.Style == ToastStyle.Drop) Ui.ShowWatch(word, items, State.Settings.Sound);
            else Ui.PostWatch(word, items, State.Settings.Sound);
        }
    }

    // 브리핑 시간대(C-21): 정한 시각부터 정오 전까지(정오 이후 시각이면 그 한 시간). 늦게 켜도 저녁에 아침 브리핑이 뜨지 않게
    public static bool DigestWindow(int hour, int digestHour) => hour >= digestHour && hour < Math.Max(12, digestHour + 1);

    // 지난 24시간 소식
    public List<NewsItem> DigestItems
    {
        get
        {
            var cutoff = Now().AddHours(-24);
            return VisibleRecent.Where(i => (i.Date ?? DateTimeOffset.MinValue) > cutoff).ToList();   // 보이는 출처만(S-13)
        }
    }

    // H-01
    public void OpenLatestUnread()
    {
        var list = VisibleRecent;   // 꺼진 출처 글은 열지 않음(S-13)
        if ((list.FirstOrDefault(i => !IsRead(i)) ?? list.FirstOrDefault()) is { } it) Open(it);
    }

    // MARK: 읽음·저장(C-23·C-24)
    public bool IsRead(NewsItem item) => State.Read.ContainsKey(item.Key);
    public bool IsSaved(NewsItem item) => State.Saved.Any(s => s.Key == item.Key);

    public void SetRead(NewsItem item, bool on)
    {
        if (on) State.Read[item.Key] = Now().ToUnixTimeMilliseconds() / 1000.0; else State.Read.Remove(item.Key);
        if (State.Read.Count > 3000)
            foreach (var (k, _) in State.Read.OrderBy(p => p.Value).Take(State.Read.Count - 2000).ToList()) State.Read.Remove(k);
        Save();
    }

    public void MarkAllRead()
    {
        var now = Now().ToUnixTimeMilliseconds() / 1000.0;
        foreach (var it in State.Recent) State.Read.TryAdd(it.Key, now);
        State.Unread = 0;
        Save();
    }

    public void ToggleSaved(NewsItem item)
    {
        if (IsSaved(item)) State.Saved.RemoveAll(s => s.Key == item.Key);
        else
        {
            State.Saved.Insert(0, item);
            if (ArticleService.Shared is { } svc) _ = Task.Run(() => svc.PrepareAsync(item)); // 오프라인으로 읽을 수 있게 번역까지 보관
        }
        Save();
    }

    // MARK: 구독 채널
    public bool Notifies(string sourceId) =>
        State.Notify.TryGetValue(sourceId, out var on) ? on : AllSources.FirstOrDefault(s => s.Id == sourceId)?.NotifyDefault ?? true;

    public void SetNotify(string sourceId, bool on)
    {
        State.Notify[sourceId] = on;
        Save();
    }

    public bool IsSubscribed(Source src) => State.CustomSources.Any(s => s.Id == src.Id || s.Url == src.Url);

    // 추천 목록에서 구독
    public async Task<string?> SubscribeAsync(Source src) => IsSubscribed(src) ? null : await AddAsync(src);

    // 아무 주소나: 알맞은 피드를 찾아 구독(K-02)
    public async Task<string?> AddChannelAsync(string input, string name = "")
    {
        try
        {
            var f = await ChannelResolver.ResolveAsync(input);
            if (AllSources.Any(s => s.Url == f.FeedUrl)) return "이미 구독 중인 채널입니다";
            string[] palette = ["#6E56CF", "#0090FF", "#E5484D", "#30A46C", "#F76B15", "#D6409F", "#12A594"];
            var src = new Source
            {
                Id = "custom-" + HashId(f.FeedUrl), Name = FeedParser.NonEmpty(name.Trim()) ?? f.Name, Tier = "press", Type = "feed",
                Url = f.FeedUrl, AiOnly = false, DefaultOn = true,
                Color = f.Kind == ItemKind.Video ? "#FF0033" : palette[State.CustomSources.Count % palette.Length],
                Kind = f.Kind.Raw(), NotifyDefault = f.NotifyDefault, Group = "직접 추가", Home = f.Home,
            };
            return await AddAsync(src);
        }
        catch (Exception e) { return e.Message; }
    }

    // 맥과 같은 id: djb2(유니코드 스칼라) & 0x7fffffff 를 36진수로
    public static string HashId(string s)
    {
        long h = 5381;
        foreach (var r in s.EnumerateRunes()) h = unchecked(h * 33 + r.Value);
        var v = h & 0x7fffffff;
        const string digits = "0123456789abcdefghijklmnopqrstuvwxyz";
        if (v == 0) return "0";
        var sb = new System.Text.StringBuilder();
        while (v > 0) { sb.Insert(0, digits[(int)(v % 36)]); v /= 36; }
        return sb.ToString();
    }

    // 구독 중인 주소(단추를 두 번 눌러도 한 번만)
    public HashSet<string> Subscribing { get; } = new();

    // 실제로 받아 읽어 보고, 되면 추가한다. 실패하면 이유를 돌려준다(K-04).
    private async Task<string?> AddAsync(Source src)
    {
        if (!Subscribing.Add(src.Url)) return null;
        Changed?.Invoke();
        try
        {
            // 해지 뒤 다시 구독할 때 남은 ETag 로 304 를 받지 않게 조건 없이 받는다
            var items = await Feeds.ItemsAsync(src, conditional: false);
            if (items is null || items.Count == 0) return "글을 찾지 못했습니다";
            if (AllSources.Any(s => s.Id == src.Id || s.Url == src.Url)) return "이미 구독 중인 채널입니다";
            // 지금 있는 글은 이 자리에서 기억해 두고(알리지 않음), 이후에 올라오는 글부터 알린다
            var now = Now().ToUnixTimeMilliseconds() / 1000.0;
            foreach (var it in items) State.Seen[it.Key] = now;
            State.Seeded.Add(src.Id);
            State.CustomSources.Add(src);
            State.Enabled[src.Id] = true;
            Save();
            // 최근 3일 글은 매거진에 바로 싣는다(알림 없이) — 구독하자마자 지면에서 볼 수 있게
            var cutoff = Now().AddDays(-3);
            var recent = items.Where(i => (i.Date ?? DateTimeOffset.MinValue) > cutoff).Take(src.NotifyDefault == false ? 30 : 15).ToList();
            if (recent.Count > 0)
            {
                recent = await TranslateTitlesAsync(recent);
                recent.Reverse();
                await Task.Run(() => Magazine.Ingest(recent));
            }
        }
        catch (Exception e) { return $"읽지 못했습니다: {e.Message}"; }
        finally { Subscribing.Remove(src.Url); Changed?.Invoke(); }
        return null;
    }

    public void RemoveCustomSource(string id)
    {
        State.CustomSources.RemoveAll(s => s.Id == id);
        State.Enabled.Remove(id);
        State.Notify.Remove(id);
        State.Seeded.RemoveAll(s => s == id);
        SubscriptionsChanged();   // 해지한 채널 글은 바로 빠짐(S-13)
    }

    // U-08: 창을 열면 안 읽음 수 초기화
    public void MarkRead()
    {
        if (State.Unread == 0) return;
        State.Unread = 0;
        Save();
    }

    public void SetEnabled(string id, bool on)
    {
        State.Enabled[id] = on;
        SubscriptionsChanged();   // 끄면 그 출처 글이 목록·매거진에서 바로 빠지고, 다시 켜면 돌아옴(S-13)
        if (on) _ = CheckAllAsync();
    }

    public void Update(Action<StateSettings> change)
    {
        var before = State.Settings.Copy();
        change(State.Settings);
        Focus.Invalidate();
        Save();
        if (State.Settings.IntervalMinutes != before.IntervalMinutes) RestartLoop();
    }

    // 상태를 통째로 바꾼다(내 기록 가져오기·되돌리기, P-08 — 맥 replaceState)
    public void ReplaceState(Func<AppState, AppState> change)
    {
        var interval = State.Settings.IntervalMinutes;
        State = change(State);
        Focus.Invalidate();
        Save();
        if (State.Settings.IntervalMinutes != interval && loop is not null) RestartLoop();
        Magazine.Refresh();
    }

    // 견본 카드(N-15). 실제 기사를 다시 띄우면 같은 소식이 또 온 것처럼 보이므로 쓰지 않는다
    public static NewsItem PreviewItem(DateTimeOffset now) => new()
    {
        Id = PreviewId, Title = Strings.PreviewTitle, TitleKo = Strings.PreviewTitleKo,
        Link = "", Date = now, Summary = "", SourceId = "openai", SourceName = "미리 보기", Tier = "lab",
    };

    public void Preview() => Deliver([PreviewItem(Now())], manual: false);

    public void Stop()
    {
        Store.Flush();   // 묶어 둔 저장을 바로(C-13)
        loop?.Cancel();
        minuteTimer?.Dispose();
    }
}
