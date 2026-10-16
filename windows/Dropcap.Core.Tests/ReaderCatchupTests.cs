using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Dropcap.Ui;

namespace Dropcap.Core.Tests;

// 맥 따라잡기(읽기 창): 유료 기사 기록(G-14)·같은 소식을 무료로 읽기(G-15)·짧은 글 추리기·J/K/Esc(H-05)
public class ReaderCatchupTests : IDisposable
{
    private readonly TempDir tmp = new();
    private readonly Database db;
    private readonly AppModel model;
    private readonly Scrapbook book;
    private readonly PaywallBook paywall;
    private readonly ArticleService svc;
    private readonly FakePlatform platform = new();
    private readonly Bridge bridge = new();
    private readonly ReaderPage page;
    private readonly List<(NewsItem Item, bool Failed, bool Blocked)> recorded = new();

    // FT(hard) 기사와 같은 스토리의 무료 보도들
    private static readonly NewsItem Ft = It("ft", "1", "FT", "https://www.ft.com/content/abc", "press", 5);
    private static readonly NewsItem LabAlt = It("labx", "2", "Lab X", "https://labx.example/news/gpt", "lab", 1);
    private static readonly NewsItem PressAlt = It("pressy", "3", "Press Y", "https://pressy.example/a", "press", 3);
    private static readonly NewsItem PressAlt2 = It("pressy", "4", "Press Y", "https://pressy.example/b", "press", 4);  // 같은 출처는 하나만
    private static readonly NewsItem Wsj = It("wsj", "5", "WSJ", "https://www.wsj.com/a", "press", 2);                  // 유료는 빼고
    private static readonly NewsItem Nyt = It("nyt", "6", "NYT", "https://www.nytimes.com/a", "press", 6);              // metered

    private static NewsItem It(string src, string id, string name, string link, string tier, int hoursAgo) => new()
    {
        Id = id, Title = "GPT-6 launches " + id, Link = link, SourceId = src, SourceName = name, Tier = tier,
        Date = DateTimeOffset.UtcNow.AddHours(-hoursAgo),
    };

    public ReaderCatchupTests()
    {
        db = new Database(Path.Combine(tmp.Path, "magazine.sqlite"));
        model = new AppModel(new FakeUi(), new Magazine(db), new AppState { Recent = [Ft, LabAlt, PressAlt, Nyt] }, persist: false) { ShowAllSourcesForTests = true };
        book = new Scrapbook(db);
        paywall = new PaywallBook(db);
        svc = new ArticleService(new NoExtract(), () => [], Path.Combine(tmp.Path, "articles"))
        {
            RecordExtract = (i, f, b) => { lock (recorded) recorded.Add((i, f, b)); },
            Fetch = Serve("<div id=app></div>"),   // 창을 열어도 바깥에 요청하지 않게
        };
        page = new ReaderPage(model, svc, book, platform, bridge, paywall);
        bridge.Register(page);
        foreach (var x in new[] { Ft, LabAlt, PressAlt, PressAlt2, Wsj, Nyt }) db.Upsert(x, "c1");
    }

    public void Dispose() { ExternalLink.Opener = null; db.Dispose(); tmp.Dispose(); }

    private sealed class NoExtract : IArticleExtractor
    {
        public Task<Article?> FromHtmlAsync(string html, Uri baseUri) => Task.FromResult<Article?>(null);
        public Task<Article?> FromLiveAsync(Uri url) => Task.FromResult<Article?>(null);
    }

    // 빠른 길은 정해 둔 결과, 느린 길은 부른 횟수·기다림만 기록
    private sealed class FakeExtract(Article? fast, Article? live = null) : IArticleExtractor
    {
        public List<TimeSpan> LiveWaits { get; } = new();
        public Task<Article?> FromHtmlAsync(string html, Uri baseUri) => Task.FromResult(fast);
        public Task<Article?> FromLiveAsync(Uri url) => FromLiveAsync(url, TimeSpan.FromSeconds(15));
        public Task<Article?> FromLiveAsync(Uri url, TimeSpan maxWait) { LiveWaits.Add(maxWait); return Task.FromResult(live); }
    }

    private sealed class FakePlatform : IPlatform
    {
        public List<string> Closed { get; } = new();
        public List<NewsItem> Opened { get; } = new();
        public List<(string From, NewsItem Next)> Replaced { get; } = new();
        public int Beeps { get; private set; }
        public void OpenReader(NewsItem item) => Opened.Add(item);
        public void ReplaceReader(string fromKey, NewsItem next) => Replaced.Add((fromKey, next));
        public void Beep() => Beeps++;
        public void CloseWindow(string page) => Closed.Add(page);
        public bool Speaking => false;
        public void Speak(string text, string language) { }
        public void StopSpeaking() { }
        public void Share(NewsItem item) { }
        public void CopyText(string text) { }
        public void OpenMagazine(string? page = null) { }
        public int SettingsOpened { get; private set; }
        public void OpenSettings(string? tab = null) => SettingsOpened++;
        public void OpenOnboarding() { }
        public void Quit() { }
        public Task<bool> SaveTextFile(string suggestedName, string text) => Task.FromResult(true);
        public bool LaunchAtLogin { get; set; }
        public bool ReduceMotion => false;
        public void ApplyFont() { }
    }

    private static JsonObject Node(object o) => (JsonObject)JsonSerializer.SerializeToNode(o, Json.Options)!;

    private async Task<JsonObject?> Run(string cmd, string key, object? args = null)
    {
        var a = args is null ? new JsonObject() : Node(args);
        a["key"] = key;
        var r = await page.Handle(cmd, a);
        return r is null ? null : Node(r);
    }

    private static Article Art(params string[] paras) => new() { Title = "t", Blocks = paras.Select(p => new Block { Type = BlockKind.P, Text = p }).ToList() };

    // MARK: G-15 무료 보도

    [Fact]
    public void FreeReasonRulesLikeMac()
    {
        Assert.Null(ReaderPage.FreeReason(0, "failed", true, PaywallKind.Hard));                     // 권할 보도가 없으면 상자도 없음
        Assert.Equal("본문을 열지 못했습니다", ReaderPage.FreeReason(2, "failed", true, PaywallKind.Hard));
        Assert.Equal("다른 곳 보도로 전체를 읽을 수 있어요", ReaderPage.FreeReason(1, "done", true, null));
        Assert.Equal("유료 기사입니다", ReaderPage.FreeReason(1, "loading", false, PaywallKind.Hard));
        Assert.Equal("이곳 기사는 자주 막힙니다", ReaderPage.FreeReason(1, "done", false, PaywallKind.Learned));
        Assert.Null(ReaderPage.FreeReason(1, "done", false, PaywallKind.Metered));                    // metered 는 먼저 권하지 않음
        Assert.Null(ReaderPage.FreeReason(1, "done", false, null));
    }

    [Fact]
    public void ViewCarriesFreeAlternatives()
    {
        var v = Node(ReaderPage.View(Ft, null, model, book, paywall));
        Assert.Equal("hard", v["paywall"]!.GetValue<string>());
        Assert.Equal("유료 기사입니다", v["freeReason"]!.GetValue<string>());
        var alts = v["alternatives"]!.AsArray();
        // 공식 발표 > 언론, 출처마다 하나, 유료(WSJ·NYT) 빼고
        Assert.Equal([LabAlt.Key, PressAlt.Key], alts.Select(x => x!["key"]!.GetValue<string>()));
        Assert.Equal("Lab X", alts[0]!["source"]!.GetValue<string>());
        Assert.Equal(LabAlt.Title, alts[0]!["title"]!.GetValue<string>());
        Assert.Matches("^#[0-9A-Fa-f]{6}$", alts[0]!["color"]!.GetValue<string>());

        // 숨긴 출처는 권하지 않는다
        model.HideSource(LabAlt.SourceId);
        var hidden = Node(ReaderPage.View(Ft, null, model, book, paywall));
        Assert.Equal([PressAlt.Key], hidden["alternatives"]!.AsArray().Select(x => x!["key"]!.GetValue<string>()));

        // metered 기사는 열어 보기 전에는 권하지 않지만, 못 열었으면 권한다
        Assert.True(Node(ReaderPage.View(Nyt, null, model, book, paywall))["freeReason"] is null);
        var failed = Node(ReaderPage.View(Nyt, new PreparedArticle { Stage = Stage.Failed }, model, book, paywall));
        Assert.Equal("본문을 열지 못했습니다", failed["freeReason"]!.GetValue<string>());
        var walled = Node(ReaderPage.View(Nyt, new PreparedArticle { Stage = Stage.Done, Paywalled = true }, model, book, paywall));
        Assert.Equal("다른 곳 보도로 전체를 읽을 수 있어요", walled["freeReason"]!.GetValue<string>());
        Assert.True(walled["paywalled"]!.GetValue<bool>());

        // 시험·미리 보기처럼 유료 기록이 없으면 상자 없음
        Assert.Empty(Node(ReaderPage.View(Ft, null, model, book))["alternatives"]!.AsArray());
    }

    [Fact]
    public async Task OpenAlternativeMarksAndOpensReader()
    {
        page.Opening(Ft);
        await Run("openAlternative", Ft.Key, new { alt = PressAlt.Key });
        Assert.Equal([PressAlt.Key], platform.Opened.Select(i => i.Key));
        Assert.True(model.IsRead(PressAlt));
        await Run("openAlternative", Ft.Key, new { alt = Wsj.Key });   // 권한 목록에 없는 기사는 열지 않음
        Assert.Single(platform.Opened);
        page.Closed(Ft.Key);
    }

    // MARK: 실패 화면·불러오는 동안

    [Fact]
    public void FeedSummaryAndFailedScreen()
    {
        Assert.Null(ReaderPage.FeedSummary(Ft with { Summary = "<p>짧음</p>" }));
        Assert.Null(ReaderPage.FeedSummary(Ft with { Title = "OpenAI launches GPT-6 with reasoning today", Summary = "OpenAI launches GPT-6 with reasoning today and more" }));
        Assert.Equal("새 모델이 나왔다. 수학과 코딩이 크게 나아졌고 가격은 그대로다.",
            ReaderPage.FeedSummary(Ft with { Summary = "<p>새 모델이 나왔다.</p>\n  <p>수학과 코딩이 크게 나아졌고 가격은 그대로다.</p>" }));

        // 번역된 웹페이지 단추는 외국어 기사만
        var ko = Ft with { Title = "오픈AI, 새 모델 공개" };
        Assert.False(Node(ReaderPage.View(ko, new PreparedArticle { Stage = Stage.Failed }, model, book))["translatedPage"]!.GetValue<bool>());
        Assert.True(Node(ReaderPage.View(Ft, new PreparedArticle { Stage = Stage.Failed }, model, book))["translatedPage"]!.GetValue<bool>());
        Assert.False(Node(ReaderPage.View(Ft, null, model, book))["blockedHost"]!.GetValue<bool>());
    }

    // MARK: 짧은 글 추리기(맥 8e9fde9)

    [Fact]
    public void LooksLikeArticleAcceptsShortPosts()
    {
        Assert.True(Art(new string('가', 100)).LooksLikeArticle);              // 한 문단 100자면 본문
        Assert.False(Art(new string('가', 99)).LooksLikeArticle);
        Assert.True(Art(new string('가', 60), new string('나', 40)).LooksLikeArticle);
        Assert.False(new Article { Blocks = [new Block { Type = BlockKind.Img, Src = "https://x/a.jpg" }] }.LooksLikeArticle);
    }

    [Fact]
    public void VisibleTextIgnoresScriptsAndTags()
    {
        var shell = "<html><head><script>" + new string('x', 5000) + "</script><style>p{}</style></head><body><div id=app></div><noscript>enable js</noscript></body></html>";
        Assert.True(ArticleExtraction.VisibleTextLength(shell) < 20);
        var rich = "<html><body><p>" + string.Join("</p><p>", Enumerable.Repeat("글이 들어 있는 문단입니다.", 60)) + "</p><svg><text>" + new string('y', 3000) + "</text></svg></body></html>";
        Assert.InRange(ArticleExtraction.VisibleTextLength(rich), 601, 2000);
    }

    private static Func<string, Task<(byte[] Data, string? Encoding)?>> Serve(string html) =>
        _ => Task.FromResult<(byte[] Data, string? Encoding)?>((Encoding.UTF8.GetBytes(html), "utf-8"));

    [Fact]
    public async Task RichPageSkipsSlowPath()
    {
        var x = new FakeExtract(null);
        var rich = "<p>" + string.Join(" ", Enumerable.Repeat("문단 글자가 많은 페이지", 80)) + "</p>";
        Assert.Null(await ArticleExtraction.ExtractAsync(x, "https://rich.example/a", true, Serve(rich), checkUrl: false));
        Assert.Empty(x.LiveWaits);                                            // 글이 있는 페이지는 스크립트를 돌려도 같음
        Assert.Null(await ArticleExtraction.ExtractAsync(x, "https://shell.example/a", true, Serve("<div id=app></div>"), checkUrl: false));
        Assert.Equal([TimeSpan.FromSeconds(15)], x.LiveWaits);                // 빈 껍데기는 느린 길(최대 15초)
        Assert.Null(await ArticleExtraction.ExtractAsync(x, "https://shell.example/b", false, Serve("<div id=app></div>"), checkUrl: false));
        Assert.Single(x.LiveWaits);                                           // 미리 받기는 느린 길 없음
    }

    [Fact]
    public async Task RefusedHostTriesBrieflyThenRemembers()
    {
        var host = $"refused-{Guid.NewGuid():N}.example";
        var x = new FakeExtract(null);
        Func<string, Task<(byte[] Data, string? Encoding)?>> refuse = _ => throw new HttpStatusException(403);
        Assert.False(ArticleExtraction.IsBlockedHost(host));
        Assert.Null(await ArticleExtraction.ExtractAsync(x, $"https://{host}/a", true, refuse, checkUrl: false));
        Assert.Equal([TimeSpan.FromSeconds(6)], x.LiveWaits);                 // 거부한 곳은 짧게만
        Assert.True(ArticleExtraction.IsBlockedLink($"https://{host.ToUpperInvariant()}/b"));
        Assert.Null(await ArticleExtraction.ExtractAsync(x, $"https://{host}/b", true, refuse, checkUrl: false));
        Assert.Single(x.LiveWaits);                                           // 이번 실행 동안은 느린 길을 건너뜀

        // 느린 길로 열리면 기억하지 않는다
        var ok = new FakeExtract(null, Art(new string('가', 150)));
        var host2 = $"refused-{Guid.NewGuid():N}.example";
        Assert.NotNull(await ArticleExtraction.ExtractAsync(ok, $"https://{host2}/a", true, refuse, checkUrl: false));
        Assert.False(ArticleExtraction.IsBlockedHost(host2));
    }

    // MARK: G-14 기록

    private async Task<(NewsItem Item, bool Failed, bool Blocked)> NextRecord(int count)
    {
        for (var i = 0; i < 300; i++)
        {
            lock (recorded) if (recorded.Count >= count) return recorded[count - 1];
            await Task.Delay(10);
        }
        throw new TimeoutException("기록 없음");
    }

    [Fact]
    public async Task PaywalledArticleIsRecordedOnlyWhenUserOpens()
    {
        // 맛보기(1500자 미만)에 구독 권유 문구 — 한국어라 번역 없이 바로 끝난다
        var teaser = Art("오픈AI가 새 모델을 공개했다. 이 기사는 구독자 전용 기사입니다. 전체 기사를 보려면 구독하세요. 이미 구독하셨다면 로그인 후 이용해 주세요. 감사합니다. 구독 문의는 고객센터로 연락해 주시기 바랍니다.");
        Assert.True(Paywall.LooksBlocked(teaser.Blocks));
        var walled = new ArticleService(new FakeExtract(teaser), () => [], Path.Combine(tmp.Path, "a2"))
        {
            Fetch = Serve("<div></div>"),
            RecordExtract = (i, f, b) => { lock (recorded) recorded.Add((i, f, b)); },
        };
        var seen = new List<PreparedArticle>();
        walled.Observe(Ft.Link, a => { lock (seen) seen.Add(a); });

        // 미리 받기는 세지 않는다
        var pre = Ft with { Id = "pre", Link = "https://www.ft.com/content/pre" };
        _ = walled.PrepareAsync(pre, interactive: false);
        // 사용자가 연 기사: 막힘으로 기록, 준비된 기사에도 표시
        _ = walled.PrepareAsync(Ft, interactive: true);
        var r = await NextRecord(1);
        Assert.Equal((Ft.Key, false, true), (r.Item.Key, r.Failed, r.Blocked));
        // 맛보기 표시는 다음 진행 알림(끝)에 실려 온다
        bool Walled() { lock (seen) return seen.Any(a => a.Paywalled == true); }
        for (var i = 0; i < 400 && !Walled(); i++) await Task.Delay(10);
        lock (seen) Assert.Contains(seen, a => a.Paywalled == true && a.Blocks.Count == 1);
        await Task.Delay(50);
        lock (recorded) Assert.DoesNotContain(recorded, x => x.Item.Key == pre.Key);

        // 미리 보기 기사는 열어도 세지 않는다
        var preview = Ft with { Id = AppModel.PreviewId, Link = "https://www.ft.com/content/preview" };
        _ = walled.PrepareAsync(preview, interactive: true);
        await Task.Delay(100);
        lock (recorded) Assert.DoesNotContain(recorded, x => x.Item.Id == AppModel.PreviewId);
    }

    [Fact]
    public async Task FailedOpenIsRecordedAsFailure()
    {
        var failing = new ArticleService(new FakeExtract(null), () => [], Path.Combine(tmp.Path, "a3"))
        {
            Fetch = Serve("<div id=app></div>"),
            RecordExtract = (i, f, b) => { lock (recorded) recorded.Add((i, f, b)); },
        };
        var item = LabAlt with { Summary = "" };
        var a = await failing.PrepareAsync(item, interactive: true);
        Assert.Equal(Stage.Failed, a.Stage);
        var r = Assert.Single(recorded);
        Assert.Equal((item.Key, true, false), (r.Item.Key, r.Failed, r.Blocked));
        Assert.Equal(Stage.Failed, (await failing.PrepareAsync(item with { Id = "9" }, interactive: false)).Stage);
        Assert.Single(recorded);                                              // 미리 받기 실패는 세지 않음
    }

    // MARK: H-05 J·K·Esc

    [Fact]
    public async Task StepFollowsReadingList()
    {
        var video = It("yt", "v", "YouTube", "https://youtube.com/watch?v=1", "press", 1) with { Kind = "video" };
        ReadingList.Remember(Ft, [LabAlt, Ft, video, PressAlt]);
        page.Opening(Ft);

        var r = await Run("step", Ft.Key, new { dir = 1 });
        Assert.True(r!["moved"]!.GetValue<bool>());
        var (from, next) = Assert.Single(platform.Replaced);
        Assert.Equal((Ft.Key, PressAlt.Key), (from, next.Key));             // 영상은 건너뜀
        Assert.True(model.IsRead(PressAlt));

        // 끝이면 경고음만
        Assert.False((await Run("step", PressAlt.Key, new { dir = 1 }))!["moved"]!.GetValue<bool>());
        Assert.Equal(1, platform.Beeps);
        // 거꾸로(K)
        await Run("step", PressAlt.Key, new { dir = -1 });
        Assert.Equal(Ft.Key, platform.Replaced[^1].Next.Key);
        // 목록을 모르는 기사도 경고음
        await Run("step", Nyt.Key, new { dir = 1 });
        Assert.Equal(2, platform.Beeps);

        await Run("settings", Ft.Key);                                        // Ctrl+, → 설정 창
        Assert.Equal(1, platform.SettingsOpened);
        await Run("close", Ft.Key);                                           // Esc → 창 닫기
        Assert.Equal(["reader:" + Ft.Key], platform.Closed);
        page.Closed(Ft.Key);
    }
}
