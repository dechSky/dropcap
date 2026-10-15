using Dropcap.Core;
using Dropcap.Ui;
using SkiaSharp;

namespace Dropcap.Core.Tests;

// 맥 mac/Tests/DropcapTests/ExtrasTests.swift 를 옮긴 것(남은 개선 묶음 — mac/EXTRAS.md):
// 유료 기사 표시·무료 보도 안내(G-14·G-15) · 회의 중 조용히(N-25) · 오늘 호 완독(M-23) · 분야별 저녁 정리(N-26) · 분야 대표 사진 점수(M-24)

internal static class Extras
{
    public static NewsItem News(string id, string source, string tier = "press", string? link = null, DateTimeOffset? date = null,
                                string? title = null, string? kind = null, string? image = null) => new()
    {
        Id = id, Title = title ?? $"Title {id}", Link = link ?? $"https://{source}.example/{id}", Date = date ?? DateTimeOffset.Now,
        Summary = $"summary {id}", SourceId = source, SourceName = source.ToUpperInvariant(), Tier = tier, Kind = kind, Image = image,
    };
}

public class PaywallTests
{
    private readonly Dictionary<string, SourceMeta> meta = new()
    {
        ["wsj"] = new SourceMeta("wsj", Paywall: "hard"),
        ["nyt"] = new SourceMeta("nyt", Paywall: "metered"),
        ["verge"] = new SourceMeta("verge"),
        ["yna"] = new SourceMeta("yna"),
    };

    [Fact]
    public void DeclaredBeatsDomainAndLearning()
    {
        Assert.Equal(PaywallKind.Hard, Paywall.Kind("wsj", "https://www.wsj.com/a", meta));
        Assert.Equal(PaywallKind.Metered, Paywall.Kind("nyt", "https://www.nytimes.com/a", meta));
        Assert.Null(Paywall.Kind("verge", "https://www.theverge.com/a", meta));
    }

    [Fact]
    public void CustomSourcesUseKnownDomainsIncludingSubdomains()
    {
        Assert.Equal(PaywallKind.Hard, Paywall.DomainKind("https://www.ft.com/content/1"));
        Assert.Equal(PaywallKind.Hard, Paywall.DomainKind("https://edition.economist.com/x"));
        Assert.Equal(PaywallKind.Metered, Paywall.DomainKind("https://cooking.nytimes.com/r"));
        Assert.Null(Paywall.DomainKind("https://notft.com/x"));
        Assert.Null(Paywall.DomainKind("https://ft.com.evil.example/x"));
        Assert.Null(Paywall.DomainKind("not a url"));
        Assert.Equal(PaywallKind.Hard, Paywall.Kind("custom-1", "https://www.bloomberg.com/news/a", meta));
    }

    [Fact]
    public void LearnsFromFailureRateOnlyAfterEnoughTries()
    {
        var few = new Dictionary<string, Database.ExtractStat> { ["verge"] = new(4, 4, 0) };
        Assert.Null(Paywall.Kind("verge", "https://www.theverge.com/a", meta, few));
        var many = new Dictionary<string, Database.ExtractStat> { ["verge"] = new(10, 4, 3) };
        Assert.Equal(PaywallKind.Learned, Paywall.Kind("verge", "https://www.theverge.com/a", meta, many));
        var ok = new Dictionary<string, Database.ExtractStat> { ["verge"] = new(10, 2, 1) };
        Assert.Null(Paywall.Kind("verge", "https://www.theverge.com/a", meta, ok));
    }

    [Fact]
    public void TeaserWithSubscribePromptLooksBlocked()
    {
        static Block P(string t) => new() { Type = BlockKind.P, Text = t };
        Assert.True(Paywall.LooksBlocked([P("The central bank surprised markets on Tuesday."), P("Subscribe to continue reading this article.")]));
        Assert.True(Paywall.LooksBlocked([P("기사 첫 문단입니다."), P("이 기사는 유료 회원만 볼 수 있습니다.")]));
        // 본문이 충분하면 끝의 구독 권유는 무시
        var full = Enumerable.Repeat(P(string.Concat(Enumerable.Repeat("Full paragraph of the story. ", 10))), 8).Append(P("Subscribe to read more stories like this."));
        Assert.False(Paywall.LooksBlocked(full));
        Assert.False(Paywall.LooksBlocked([P("Short but free note.")]));
    }

    [Fact]
    public void FreeAlternativesSkipPaywalledHiddenSelfAndChannels()
    {
        var me = Extras.News("1", "wsj");
        var story = new[]
        {
            me,
            Extras.News("2", "nyt"),                                         // metered — 열리지 않을 수 있어 권하지 않음
            Extras.News("3", "verge", date: DateTimeOffset.Now.AddSeconds(-60)),
            Extras.News("4", "yna", tier: "kr", date: DateTimeOffset.Now.AddHours(-1)),
            Extras.News("5", "hidden"),
            Extras.News("6", "verge"),                                       // 같은 출처 두 번은 한 번만
            Extras.News("7", "tube", kind: "video"),
        };
        var alts = Paywall.FreeAlternatives(me, story, new HashSet<string> { "hidden" }, meta);
        Assert.Equal(["4", "6"], alts.Select(a => a.Id)); // 국내 먼저, 그다음 언론 최신
    }

    [Fact]
    public void SourcesJsonMarksKnownPaywalls()
    {
        var all = Resources.Config.Sources;
        Assert.All(all.Where(s => s.Paywall is not null), s => Assert.Contains(s.Paywall, new[] { "hard", "metered" }));
        Assert.Equal("hard", all.First(s => s.Id == "wsj-markets").Paywall);
        Assert.All(all.Where(s => s.Id.StartsWith("nyt-")), s => Assert.Equal("hard", s.Paywall)); // 앱은 403 으로 못 읽음(sources-audit)
        Assert.Equal("metered", all.First(s => s.Id == "verge").Paywall); // 구독 문·isAccessibleForFree=false
        Assert.Equal("hard", Sections.Meta["wsj-markets"].Paywall);
    }

    [Fact]
    public void OldCustomSourceWithoutPaywallStillDecodes()
    {
        var old = """{"id":"custom-x","name":"X","tier":"press","type":"feed","url":"https://x.example/feed","aiOnly":false,"defaultOn":true,"color":"#000"}""";
        Assert.Null(System.Text.Json.JsonSerializer.Deserialize<Source>(old, Json.Options)!.Paywall);
    }

    [Fact]
    public void ExtractStatsAccumulateAndDecay()
    {
        using var tmp = new TempDir();
        using var db = new Database(Path.Combine(tmp.Path, "magazine.sqlite"));
        db.RecordExtract("a", failed: true, blocked: false);
        db.RecordExtract("a", failed: false, blocked: true);
        db.RecordExtract("a", failed: false, blocked: false);
        Assert.Equal(new Database.ExtractStat(3, 1, 1), db.ExtractStats()["a"]);
        for (var i = 0; i < 60; i++) db.RecordExtract("b", failed: true, blocked: false);
        var b = db.ExtractStats()["b"];
        Assert.True(b.Tries is <= 50 and > 20 && b.FailRate == 1); // 50번이 넘으면 반으로 줄어 최근 결과가 크게
    }

    [Fact]
    public void BookRecordsAndAlternativesFollowStory()
    {
        using var tmp = new TempDir();
        using var db = new Database(Path.Combine(tmp.Path, "magazine.sqlite"));
        var book = new PaywallBook(db);
        var it = Extras.News("x", "ars", link: "https://arstechnica.com/x"); // 무료 출처
        for (var i = 0; i < 5; i++) book.Record(it, failed: i < 4, blocked: false);
        Assert.Equal(PaywallKind.Learned, book.Kind(it));                         // 5번 중 4번 막힘 → 배움
        book.Record(AppModel.PreviewItem(DateTimeOffset.Now), true, false);       // 견본 카드는 세지 않음
        Assert.False(book.Stats.ContainsKey("openai"));
        Assert.Null(book.Kind(Extras.News("v", "ars", kind: "video")));         // 기사가 아니면 자물쇠 없음
    }

    [Fact]
    public void ItemViewCarriesLock()
    {
        var v = Dropcap.Ui.ItemView.From(Extras.News("1", "custom-ft", link: "https://www.ft.com/content/1"), null);
        Assert.Equal("hard", v.Paywall);
        Assert.Contains("무료 보도", v.PaywallHelp);
        var m = Dropcap.Ui.ItemView.From(Extras.News("2", "custom-nyt", link: "https://www.nytimes.com/2"), null);
        Assert.Equal("metered", m.Paywall);
        Assert.Equal("일부 유료(무료 건수 제한)", m.PaywallHelp);
        Assert.Null(Dropcap.Ui.ItemView.From(Extras.News("3", "ars"), null).Paywall);
    }
}

public class FocusGuardTests
{
    private static readonly FocusGuard.Rect Screen = new(0, 0, 1920, 1080);

    [Fact]
    public void FullscreenWindowOfFrontAppCovers()
    {
        var wins = new[] { new FocusGuard.WindowInfo(10, 0, new(0, 0, 1920, 1080)) };
        Assert.True(FocusGuard.CoversScreen(wins, 10, [Screen], 1));
        Assert.False(FocusGuard.CoversScreen(wins, 11, [Screen], 1));   // 뒤에 있는 앱
        Assert.False(FocusGuard.CoversScreen(wins, 1, [Screen], 1));    // Dropcap 자신(매거진을 크게)
        Assert.False(FocusGuard.CoversScreen(wins, null, [Screen], 1));
        var maximized = new[] { new FocusGuard.WindowInfo(10, 0, new(0, 0, 1920, 1032)) }; // 작업 표시줄 위까지만 키운 창
        Assert.False(FocusGuard.CoversScreen(maximized, 10, [Screen], 1));
        var overlay = new[] { new FocusGuard.WindowInfo(10, 25, new(0, 0, 1920, 1080)) };
        Assert.False(FocusGuard.CoversScreen(overlay, 10, [Screen], 1)); // 보통 창이 아닌 것
        var second = new[] { new FocusGuard.WindowInfo(10, 0, new(1920, 0, 2560, 1440)) };
        Assert.True(FocusGuard.CoversScreen(second, 10, [Screen, new(1920, 0, 2560, 1440)], 1));
    }

    [Fact]
    public void SharingHelpers()
    {
        Assert.True(FocusGuard.Sharing(["explorer", "CptHost"]));
        Assert.True(FocusGuard.Sharing(["CptHost.exe"]));
        Assert.True(FocusGuard.Sharing(["cpthost"]));
        Assert.False(FocusGuard.Sharing(["Zoom", "msedge", "Teams"])); // Zoom 이 켜져 있기만 한 것은 아님
    }

    [Fact]
    public void CalendarEventsCountOnlyBusyTimedOnes()
    {
        var now = DateTimeOffset.Now;
        FocusGuard.EventInfo Ev(double s, double e, bool allDay = false, bool free = false, bool declined = false) =>
            new(now.AddSeconds(s), now.AddSeconds(e), allDay, free, declined);
        Assert.True(FocusGuard.InEvent([Ev(-600, 600)], now));
        Assert.False(FocusGuard.InEvent([Ev(-600, 600, allDay: true)], now));
        Assert.False(FocusGuard.InEvent([Ev(-600, 600, free: true)], now));
        Assert.False(FocusGuard.InEvent([Ev(-600, 600, declined: true)], now));
        Assert.False(FocusGuard.InEvent([Ev(-1200, -60), Ev(60, 1200)], now));
        Assert.False(FocusGuard.InEvent([Ev(-600, 0)], now)); // 끝나는 순간에는 풀림
    }

    [Fact]
    public void SettingsDefaultsForOldFiles()
    {
        var old = AppState.FromJson("""{"settings":{"style":"drop","quietEnabled":true}}""").Settings;
        Assert.True(old.AutoQuietFullscreen && old.AutoQuietSharing && !old.AutoQuietCalendar);
        Assert.True(old.QuietEnabled);
        var s = new AppState();
        s.Settings.AutoQuietCalendar = true;
        s.Settings.AutoQuietSharing = false;
        var back = AppState.FromJson(s.ToJson()).Settings;
        Assert.True(back.AutoQuietCalendar && !back.AutoQuietSharing && back.AutoQuietFullscreen);
    }

    private sealed class Probe : IFocusProbe
    {
        public bool Full;
        public List<string> Names = new();
        public int Calls;
        public bool FullScreen() { Calls++; return Full; }
        public IReadOnlyList<string> ProcessNames() => Names;
    }

    [Fact]
    public void MonitorFollowsSettingsAndCaches15Seconds()
    {
        var p = new Probe { Full = true };
        var m = new FocusMonitor { Probe = p };
        var st = new StateSettings();
        var t = DateTimeOffset.Now;
        Assert.Equal(FocusReason.Fullscreen, m.Reason(st, t));
        p.Full = false;
        Assert.Equal(FocusReason.Fullscreen, m.Reason(st, t.AddSeconds(10)));   // 15초 기억
        Assert.Null(m.Reason(st, t.AddSeconds(16)));
        p.Names = ["CptHost"];
        m.Invalidate();
        Assert.Equal(FocusReason.Sharing, m.Reason(st, t.AddSeconds(17)));
        st.AutoQuietSharing = false;
        m.Invalidate();
        Assert.Null(m.Reason(st, t.AddSeconds(18)));
        st.AutoQuietCalendar = true;                 // 윈도우는 캘린더를 지원하지 않아 켜도 감지하지 않는다
        m.Invalidate();
        Assert.Null(m.Reason(st, t.AddSeconds(19)));
        Assert.False(m.CalendarSupported);
    }

    [Fact]
    public void OverrideAndTestValues()
    {
        var m = new FocusMonitor { Override = FocusMonitor.ParseOverride("calendar") };
        Assert.Equal(FocusReason.Calendar, m.Reason(new StateSettings(), DateTimeOffset.Now));
        m.Override = FocusMonitor.ParseOverride("none");
        Assert.Null(m.Reason(new StateSettings(), DateTimeOffset.Now));
        Assert.Null(FocusMonitor.ParseOverride(null));
        Assert.Equal("화면 공유·기록 중", FocusReason.Sharing.Label());
    }
}

public class HushTests : IDisposable
{
    private readonly TempDir tmp = new();
    private readonly Database db;
    private readonly FakeUi ui = new();
    private readonly AppModel model;
    private DateTimeOffset now = new(DateTime.Today.AddHours(19));

    public HushTests()
    {
        db = new Database(Path.Combine(tmp.Path, "magazine.sqlite"));
        model = new AppModel(ui, new Magazine(db), new AppState(), persist: false) { ShowAllSourcesForTests = true, Now = () => now };
        model.ChooseSections(["economy"]);
        model.SetPolicy("economy", p => p with { Mode = NotifyMode.Bundle, BundleHour = 18 });
    }

    public void Dispose() { db.Dispose(); tmp.Dispose(); }

    private void Pool(int n)
    {
        for (var i = 0; i < n; i++)
            model.State.Pending.Add(new AppState.PendingItem(Extras.News($"e{i}", "yna-economy", tier: "kr"), "economy", $"s{i}", now.AddHours(-1)));
    }

    [Fact]
    public void MeetingHoldsBundlesLikeQuietHours()
    {
        Pool(3);
        model.Focus.Override = new FocusMonitor.Fixed(FocusReason.Fullscreen);
        Assert.True(model.IsHushed);
        Assert.Equal("전체 화면 사용 중", model.AutoQuietReason?.Label());
        model.DeliverBundles();
        Assert.Empty(ui.Bundles);                    // 회의 중에는 고인 채로
        model.Focus.Override = new FocusMonitor.Fixed(null);
        Assert.False(model.IsHushed);
        model.DeliverBundles();
        Assert.Equal([("economy", 3)], ui.Bundles);  // 끝나면 그 분야 묶음으로
    }

    [Fact]
    public void BundleModeMakesEveningBriefWithEvidence()
    {
        Pool(10);
        var asked = new List<(string Section, int Count)>();
        model.Briefer = (sec, items) =>
        {
            asked.Add((sec, items.Count));
            return Task.FromResult<List<SectionBrief.Line>?>([new SectionBrief.Line("금리 동결", [0])]);
        };
        model.Focus.Override = new FocusMonitor.Fixed(null);
        model.DeliverBundles();
        Assert.Equal([("economy", SectionBrief.MaxItems)], asked);   // 근거는 8건까지
        var b = model.Brief("economy");
        Assert.NotNull(b);
        Assert.Equal(SectionBrief.MaxItems, b!.Items.Count);
        Assert.Equal("금리 동결", b.Lines![0].Text);
        now = now.AddDays(1);
        Assert.Null(model.Brief("economy"));                         // 그날만
    }

    [Fact]
    public void NoModelMeansNoBox()
    {
        Pool(3);
        model.Briefer = (_, _) => Task.FromResult<List<SectionBrief.Line>?>(null);
        model.Focus.Override = new FocusMonitor.Fixed(null);
        model.DeliverBundles();
        Assert.Single(ui.Bundles);                                   // 알림은 지금처럼(제목)
        Assert.True(model.State.Briefs.ContainsKey("economy"));      // 근거는 남기고
        Assert.Null(model.Brief("economy"));                         // 상자는 없음
    }

    [Fact]
    public void InstantModeMakesNoBrief()
    {
        model.SetPolicy("economy", p => p with { Mode = NotifyMode.Instant });
        Pool(3);
        model.Focus.Override = new FocusMonitor.Fixed(null);
        model.DeliverBundles();
        Assert.False(model.State.Briefs.ContainsKey("economy"));
    }

    [Fact]
    public void ReapplyKeywordsUpdatesRecentList()
    {
        model.State.Recent = [Extras.News("1", "a", title: "Crypto coin rally"), Extras.News("2", "a", title: "Claude ships") with { Important = true }, Extras.News("3", "a", title: "GPT news")];
        model.Update(s => { s.MuteKeywords = ["crypto"]; s.MustKeywords = ["gpt"]; });
        model.ReapplyKeywords();
        Assert.Equal(["2", "3"], model.State.Recent.Select(i => i.Id));
        Assert.Null(model.State.Recent[0].Important);   // ★ 다시 매김
        Assert.True(model.State.Recent[1].Important);
    }
}

public class TodayIssueTests : IDisposable
{
    private readonly TempDir tmp = new();
    public void Dispose() => tmp.Dispose();

    private static (Issue.Section Section, List<NewsItem> Items) Page(string? section, string[] ids, string? kind = null) =>
        (new Issue.Section { Category = Categories.Other, Keys = ids.ToList(), Kind = kind, SectionId = section }, ids.Select(i => Extras.News(i, "s")).ToList());

    [Fact]
    public void RepresentativeKeys()
    {
        var sections = new[]
        {
            Page("top", ["t1", "t2", "t3", "t4"]),
            Page("economy", ["e1", "t1", "e2", "e3", "e4"]),
            Page("sports", ["s1", "s2"]),           // 고르지 않은 분야
            Page("ai", ["a1"]),
            Page(null, ["o1", "o2"]),               // 그 밖의 소식
            Page(null, ["v1"], kind: "video"),      // 구독 채널
        };
        var keys = TodayIssue.Keys("c", sections, ["top", "economy", "ai"]);
        Assert.Equal(["c", "s|t1", "s|t2", "s|t3", "s|e1", "s|e2", "s|a1"], keys); // 경제 첫 줄의 t1 은 주요 뉴스와 겹쳐 한 번만
        Assert.Empty(TodayIssue.Keys(null, [], ["ai"]));
    }

    [Fact]
    public void NextIssueText()
    {
        Assert.Equal("다음 호는 내일 오전 9시 브리핑으로 알려 드릴게요", TodayIssue.NextIssueText(true, 9));
        Assert.Equal("다음 호는 내일 오후 12시 브리핑으로 알려 드릴게요", TodayIssue.NextIssueText(true, 12));
        Assert.Equal("다음 호는 내일 아침에 엮여요", TodayIssue.NextIssueText(false, 9));
    }

    [Fact]
    public void DoneMarkLastsOnlyThatDay()
    {
        var today = DateTimeOffset.Now;
        Assert.False(TodayIssue.IsMarkedDone(today));
        TodayIssue.MarkDone(today);
        Assert.True(TodayIssue.IsMarkedDone(today));
        Assert.False(TodayIssue.IsMarkedDone(today.AddDays(1)));
    }
}

public class EveningBriefTests
{
    [Fact]
    public void ParsesLinesWithEvidence()
    {
        var text = """
            오늘 경제 소식입니다.
            - 한국은행이 기준금리를 동결했다 [1][3]
            • 코스피가 반도체 강세로 올랐다 [2]
            - 근거 없는 문장은 버린다
            - 범위 밖 번호만 단 줄도 버린다 [9]
            - 환율은 1,380원대에서 움직였다 [4] [4]
            - 네 번째 줄은 잘린다 [1]
            """;
        var lines = Summarizer.ParseBriefing(text, 4)!;
        Assert.Equal(["한국은행이 기준금리를 동결했다", "코스피가 반도체 강세로 올랐다", "환율은 1,380원대에서 움직였다"], lines.Select(l => l.Text));
        Assert.Equal([[0, 2], [1], [3]], lines.Select(l => l.Refs));
        Assert.Null(Summarizer.ParseBriefing("- 근거가 없다\n- 역시 없다", 3));
    }

    [Fact]
    public void PromptCarriesOriginalTitlesAndSources()
    {
        var a = Extras.News("1", "yna", title: "Fed holds rates") with { TitleKo = "연준 금리 동결" };
        var p = Summarizer.BriefingPrompt("경제", [a, Extras.News("2", "cnbc", title: "Stocks rally")]);
        Assert.Contains("[1] Fed holds rates (연준 금리 동결) — YNA", p);
        Assert.Contains("[2] Stocks rally — CNBC", p);
        Assert.StartsWith("분야: 경제", p);
    }

    [Fact]
    public void BriefSurvivesStateRoundTripAndOldStateHasNone()
    {
        var s = new AppState();
        var at = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
        s.Briefs["economy"] = new SectionBrief { Section = "economy", At = at, Items = [Extras.News("1", "yna", date: at)], Lines = [new("금리 동결", [0])] };
        var back = AppState.FromJson(s.ToJson()).Briefs["economy"];
        Assert.Equal(at, back.At);
        Assert.Equal("금리 동결", back.Lines![0].Text);
        Assert.Equal([0], back.Lines[0].Refs);
        Assert.Equal("yna|1", back.Items[0].Key);
        Assert.Empty(AppState.FromJson("{}").Briefs);
    }
}

public class PhotoQualityTests : IDisposable
{
    private readonly TempDir tmp = new();
    public void Dispose() => tmp.Dispose();

    private static byte[] Render(int w, int h, Action<SKCanvas> draw)
    {
        using var bmp = new SKBitmap(w, h);
        using (var c = new SKCanvas(bmp)) draw(c);
        using var img = SKImage.FromBitmap(bmp);
        return img.Encode(SKEncodedImageFormat.Png, 100).ToArray();
    }

    // 사진 같은 그림: 부드러운 색 변화 + 잡음
    private static byte[] Photo => Render(960, 540, c =>
    {
        var rnd = new Random(7);
        using var p = new SKPaint();
        for (var y = 0; y < 540; y += 6)
            for (var x = 0; x < 960; x += 6)
            {
                double n = rnd.NextDouble() * 0.24 - 0.12;
                byte B(double v) => (byte)Math.Clamp(v * 255, 0, 255);
                p.Color = new SKColor(B(0.2 + 0.6 * x / 960 + n), B(0.35 + 0.4 * Math.Sin(y / 80.0) + n), B(0.5 + 0.3 * Math.Cos((x + y) / 120.0) + n));
                c.DrawRect(x, y, 6, 6, p);
            }
    });

    // 웹사이트 화면 캡처: 흰 바탕에 글자 줄(윈도우 글자 인식은 시험에서 못 쓰므로 글자 면적은 따로 넣는다)
    private static byte[] Screenshot => Render(1280, 800, c =>
    {
        c.Clear(SKColors.White);
        using var p = new SKPaint { Color = SKColors.Black };
        for (var i = 0; i < 16; i++) c.DrawRect(40, 30 + i * 48, 560 + (i % 3) * 60, 12, p); // 글자 줄 — 오른쪽은 빈 바탕
    });

    // 로고: 흰 바탕에 색 원 하나
    private static byte[] Logo => Render(600, 600, c =>
    {
        c.Clear(SKColors.White);
        using var p = new SKPaint { Color = new SKColor(230, 25, 50), IsAntialias = true };
        c.DrawCircle(300, 300, 150, p);
    });

    [Fact]
    public void ShapeAndSizeScores()
    {
        Assert.Equal(1, PhotoQuality.AspectScore(1600, 900));
        Assert.True(PhotoQuality.AspectScore(600, 600) < 0.75);
        Assert.Equal(0, PhotoQuality.AspectScore(400, 800));
        Assert.True(PhotoQuality.AspectScore(2000, 300) < 0.2);
        Assert.Equal(1, PhotoQuality.SizeScore(1200, 675));
        Assert.Equal(0, PhotoQuality.SizeScore(120, 80));
        Assert.True(PhotoQuality.TextScore(0.02) == 1 && PhotoQuality.TextScore(0.2) == 0);
    }

    [Fact]
    public void GatesKeepGraphicsAndScreenshotsOut()
    {
        Assert.True(PhotoQuality.Good(PhotoQuality.Combine(1, 1, 0, 1, 0.21).Total));          // 밤하늘 사진
        Assert.False(PhotoQuality.Good(PhotoQuality.Combine(1, 1, 0.24, 1).Total));            // 큰 글자 그림
        Assert.False(PhotoQuality.Good(PhotoQuality.Combine(1, 1, 0, 1, 0.4).Total));          // 그래픽·여백
        Assert.False(PhotoQuality.Good(PhotoQuality.Combine(1, 1, 0.07, 0.63, 0.3).Total));    // 앱 화면 캡처(맥 실측)
        Assert.True(PhotoQuality.Good(null));                                                  // 아직 재지 않은 사진은 막지 않음
    }

    [Fact]
    public void PhotoPassesScreenshotAndLogoFail()
    {
        var p = PhotoScorer.Score(Photo, 0)!;
        var s = PhotoScorer.Score(Screenshot, 0.3)!;   // 글자 면적은 윈도우 글자 인식이 낼 값(맥 실측과 비슷하게)
        var l = PhotoScorer.Score(Logo, 0)!;
        Assert.True(PhotoQuality.Good(p.Total), $"사진 {p}");
        Assert.False(PhotoQuality.Good(s.Total), $"화면 캡처 {s}");
        Assert.True(s.Flatness > 0.25, $"단색 {s.Flatness}");
        Assert.False(PhotoQuality.Good(l.Total), $"로고 {l}");
        Assert.True(p.ColorVariety > l.ColorVariety && p.ColorVariety > s.ColorVariety);
        Assert.True(PhotoScorer.Score(Screenshot, 0)!.Total < PhotoQuality.Threshold); // 글자를 못 읽어도 단색 바탕으로 걸림
        Assert.Null(PhotoScorer.Score([1, 2, 3], 0));
    }

    [Fact]
    public void CoverSkipsBadPhotosButKeepsUnmeasured()
    {
        var a = Extras.News("a", "x", image: "https://img.example/a.jpg");
        var b = Extras.News("b", "x", image: "https://img.example/b.jpg");
        var c = Extras.News("c", "x");
        Assert.Equal(a.Key, PhotoQuality.PickCover([a, b, c], new Dictionary<string, double>()));
        Assert.Equal(b.Key, PhotoQuality.PickCover([a, b, c], new Dictionary<string, double> { [a.Image!] = 0.2 }));
        Assert.Equal(c.Key, PhotoQuality.PickCover([a, b, c], new Dictionary<string, double> { [a.Image!] = 0.2, [b.Image!] = 0.3 }));
        Assert.Null(PhotoQuality.PickCover([a, b], new Dictionary<string, double> { [a.Image!] = 0.2, [b.Image!] = 0.3 }));
        var junk = Extras.News("j", "x", image: "https://img.example/logo-big.png");                // 잡그림은 사진으로 치지 않음
        Assert.Equal(junk.Key, PhotoQuality.PickCover([junk], new Dictionary<string, double>()));
    }

    [Fact]
    public void SectionPhotoPrefersMeasuredGood()
    {
        var a = Extras.News("a", "x", image: "https://img.example/a.jpg");
        var b = Extras.News("b", "x", image: "https://img.example/b.jpg");
        Assert.Equal(b.Key, PhotoQuality.Best([a, b], new Dictionary<string, double> { [a.Image!] = 0.3, [b.Image!] = 0.9 })?.Key);
        Assert.Equal(b.Key, PhotoQuality.Best([a, b], new Dictionary<string, double> { [a.Image!] = 0.3 })?.Key);
        Assert.Equal(a.Key, PhotoQuality.Best([a, b], new Dictionary<string, double>())?.Key);
        Assert.Null(PhotoQuality.Best([a, b], new Dictionary<string, double> { [a.Image!] = 0.1, [b.Image!] = 0.2 }));
    }

    [Fact]
    public void ScoresPersistAndCoverUsesThem()
    {
        using var db = new Database(Path.Combine(tmp.Path, "magazine.sqlite"));
        db.SaveImageScore("https://img.example/a.jpg", PhotoQuality.Combine(1, 1, 0.3, 0.2));
        var got = db.ImageScores(["https://img.example/a.jpg", "https://img.example/none.jpg"]);
        Assert.Single(got);
        Assert.False(PhotoQuality.Good(got["https://img.example/a.jpg"]));

        // 매거진 표지: 화면 캡처로 잰 사진의 기사는 건너뛴다
        var mag = new Magazine(db);
        var now = DateTimeOffset.Now;
        var bad = Extras.News("bad", "openai", tier: "lab", date: now, image: "https://img.example/a.jpg", title: "OpenAI ships a big model today");
        var ok = Extras.News("ok", "verge", date: now.AddHours(-2), image: "https://img.example/ok.jpg", title: "Chip makers report record quarter");
        mag.Ingest([ok, bad], enrich: false);
        var issue = mag.MakeIssue(IssueKind.Daily, now.AddDays(-1), now.AddMinutes(1), "daily-test");
        Assert.Equal(ok.Key, issue.Cover);
    }

    [Fact]
    public async Task ScoreImagesMeasuresRecentOnce()
    {
        using var db = new Database(Path.Combine(tmp.Path, "magazine.sqlite"));
        var mag = new Magazine(db);
        var asked = new List<string>();
        mag.PhotoScorer = u => { asked.Add(u); return Task.FromResult<PhotoQuality.Score?>(PhotoQuality.Combine(1, 1, 0, 1)); };
        mag.Ingest([Extras.News("1", "a", image: "https://img.example/1.jpg"), Extras.News("2", "b", image: "https://img.example/1.jpg"),
                    Extras.News("3", "c", image: "https://img.example/logo.png")], enrich: false);
        await mag.ScoreImagesAsync();
        await mag.ScoreImagesAsync();
        Assert.Equal(["https://img.example/1.jpg"], asked);   // 같은 사진은 한 번, 잡그림은 재지 않음, 다시 불러도 재지 않음
    }
}

// 트레이 창·설정 쪽: 회의 중 표시(N-25), 자물쇠(G-14), 읽기 창 J·K 목록(H-05), 브라우저로 열고 읽음(H-03), 설정(N-25·낱말 즉시 적용·단축키 목록)
public class MenuSettingsExtrasTests : IDisposable
{
    private sealed class Platform : IPlatform
    {
        public List<string> Closed { get; } = new();
        public void OpenMagazine(string? page = null) { }
        public void OpenSettings(string? tab = null) { }
        public void OpenOnboarding() { }
        public void OpenReader(NewsItem item) { }
        public void CloseWindow(string page) => Closed.Add(page);
        public void Quit() { }
        public void CopyText(string text) { }
        public Task<bool> SaveTextFile(string suggestedName, string text) => Task.FromResult(true);
        public void Share(NewsItem item) { }
        public void Speak(string text, string language) { }
        public void StopSpeaking() { }
        public bool Speaking => false;
        public bool LaunchAtLogin { get; set; }
        public bool ReduceMotion => false;
        public void ApplyFont() { }
    }

    private readonly TempDir tmp = new();
    private readonly Database db;
    private readonly AppModel model;
    private readonly MenuPage menu;
    private readonly SettingsPage settings;

    public MenuSettingsExtrasTests()
    {
        db = new Database(Path.Combine(tmp.Path, "magazine.sqlite"));
        model = new AppModel(new FakeUi(), new Magazine(db), new AppState(), persist: false) { ShowAllSourcesForTests = true };
        menu = new MenuPage(model, new Platform());
        settings = new SettingsPage(model, new Platform());
    }

    public void Dispose() { db.Dispose(); tmp.Dispose(); }

    private static System.Text.Json.Nodes.JsonObject A(object o) =>
        (System.Text.Json.Nodes.JsonNode.Parse(System.Text.Json.JsonSerializer.Serialize(o)) as System.Text.Json.Nodes.JsonObject)!;
    private static System.Text.Json.Nodes.JsonNode J(object? o) => System.Text.Json.Nodes.JsonNode.Parse(System.Text.Json.JsonSerializer.Serialize(o, Json.Options))!;

    [Fact]
    public async Task HeaderShowsMeetingReasonAndRowsCarryLocks()
    {
        model.State.Recent = [Extras.News("1", "custom-ft", link: "https://www.ft.com/1"), Extras.News("2", "ars")];
        var v = J(await menu.Handle("view", A(new { })));
        Assert.Null(v["header"]!["autoQuiet"]);
        var rows = v["rows"]!.AsArray();
        Assert.Equal("hard", rows.First(r => r!["item"]!["key"]!.GetValue<string>() == "custom-ft|1")!["item"]!["paywall"]!.GetValue<string>());
        Assert.Null(rows.First(r => r!["item"]!["key"]!.GetValue<string>() == "ars|2")!["item"]!["paywall"]);
        model.Focus.Override = new FocusMonitor.Fixed(FocusReason.Sharing);
        v = J(await menu.Handle("view", A(new { })));
        Assert.Equal("화면 공유·기록 중", v["header"]!["autoQuiet"]!.GetValue<string>());
        Assert.Contains("모아 둡니다", v["header"]!["autoQuietHelp"]!.GetValue<string>());
    }

    [Fact]
    public async Task OpenRemembersVisibleOrderForReaderKeys()
    {
        var t = DateTimeOffset.Now;   // 최신순: 1 → 영상 → 2
        model.State.Recent = [Extras.News("1", "a", date: t), Extras.News("v", "tube", kind: "video", date: t.AddMinutes(-1)), Extras.News("2", "b", date: t.AddMinutes(-2))];
        await menu.Handle("view", A(new { }));
        await menu.Handle("open", A(new { key = "a|1" }));
        Assert.Equal("b|2", ReadingList.Step("a|1", 1)?.Key);   // 영상은 건너뜀
        Assert.Null(ReadingList.Step("b|2", 1));                 // 끝
        Assert.Equal("a|1", ReadingList.Step("b|2", -1)?.Key);
    }

    [Fact]
    public async Task KeyboardBrowserMarksRead()
    {
        ExternalLink.Opener = _ => true;
        model.State.Recent = [Extras.News("1", "a")];
        await menu.Handle("browser", A(new { key = "a|1" }));
        Assert.False(model.IsRead(model.State.Recent[0]));       // 오른쪽 클릭 메뉴는 그대로
        await menu.Handle("browser", A(new { key = "a|1", read = true }));
        Assert.True(model.IsRead(model.State.Recent[0]));        // 키보드 O 는 읽음 처리
    }

    [Fact]
    public async Task SettingsAutoQuietAndCalendarUnsupported()
    {
        var g = J(await settings.Handle("view", A(new { })))["general"]!;
        Assert.True(g["autoQuietFullscreen"]!.GetValue<bool>() && g["autoQuietSharing"]!.GetValue<bool>());
        Assert.False(g["calendarSupported"]!.GetValue<bool>());
        Assert.NotNull(g["calendarNote"]);
        await settings.Handle("set", A(new { key = "autoQuietSharing", value = false }));
        await settings.Handle("set", A(new { key = "autoQuietCalendar", value = true }));
        Assert.False(model.State.Settings.AutoQuietSharing);
        Assert.False(model.State.Settings.AutoQuietCalendar);    // 지원하지 않으면 켜지지 않음
        var f = J(await settings.Handle("view", A(new { })))["filters"]!;
        Assert.Contains(f["navKeys"]!.AsArray(), k => k!["keys"]!.GetValue<string>() == "Ctrl+[ · Ctrl+]");
    }

    [Fact]
    public async Task KeywordsApplyToExistingList()
    {
        model.State.Recent = [Extras.News("1", "a", title: "Crypto coin"), Extras.News("2", "a", title: "GPT launch")];
        await settings.Handle("keywords", A(new { must = "gpt", mute = "crypto" }));
        Assert.Equal(["2"], model.State.Recent.Select(i => i.Id));
        Assert.True(model.State.Recent[0].Important);
    }
}

// 그 사이 바뀐 기준: C-13 저장 묶기(0.5초), C-21 브리핑 시간대(정한 시각~정오 전)
public class ChangedSpecTests
{
    [Fact]
    public void SavesAreBatchedAndFlushed()
    {
        using var tmp = new TempDir();
        var s = new AppState();
        for (var i = 0; i < 5; i++) { s.Unread = i; Store.Save(s); }
        Assert.False(File.Exists(Store.FilePath));          // 0.5초 안의 다섯 번은 아직 쓰지 않음
        Store.Flush();
        Assert.Equal(4, Store.Load().Unread);               // 마지막 것 하나만
        s.Unread = 9;
        Store.Save(s);
        Thread.Sleep(900);
        Assert.Equal(9, AppState.FromJson(File.ReadAllText(Store.FilePath)).Unread); // 뒤 스레드가 0.5초 뒤 씀
    }

    [Theory]
    [InlineData(9, 9, true)]
    [InlineData(11, 9, true)]
    [InlineData(12, 9, false)]   // 정오가 지나면 그날 브리핑은 건너뜀
    [InlineData(8, 9, false)]
    [InlineData(12, 12, true)]   // 낮 12시로 정했으면 그 한 시간
    [InlineData(13, 12, false)]
    public void DigestWindow(int hour, int digestHour, bool on) => Assert.Equal(on, AppModel.DigestWindow(hour, digestHour));
}

public class VisibleTextSafetyTests
{
    [Fact]
    public void CountsTextSkipsScriptsAndStaysLinear()
    {
        Assert.Equal("Hello world ".Length, ArticleExtraction.VisibleTextLength("<p>Hello</p><script>var x = '<p>a</p>';</script> <b>world</b>"));
        Assert.Equal("a b".Length, ArticleExtraction.VisibleTextLength("a  \n\t b<script"));   // 닫히지 않은 꼬리표 뒤는 셈하지 않음
        Assert.Equal(0, ArticleExtraction.VisibleTextLength("<style>p{}</style><svg><path/></svg>"));
        // 닫히지 않은 <script 가 수만 개여도 바로 끝난다(예전 정규식은 제곱으로 느려짐)
        var evil = string.Concat(Enumerable.Repeat("<script>", 90_000));
        var sw = System.Diagnostics.Stopwatch.StartNew();
        ArticleExtraction.VisibleTextLength(evil);
        Assert.True(sw.ElapsedMilliseconds < 1000, $"{sw.ElapsedMilliseconds}ms");
    }
}
