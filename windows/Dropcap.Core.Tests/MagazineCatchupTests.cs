using System.Text.Json;
using System.Text.Json.Nodes;
using Dropcap.Ui;

namespace Dropcap.Core.Tests;

// 매거진 남은 개선(맥 508d4bf·24c4323·b804764 이식): 오늘 호 완독(M-23)·저녁 정리(N-26)·카드 자물쇠(G-14)·분야 유리 띠·
// 지면 넘기기(H-04)·키보드 동작 명령(H-03)·읽기 창 J·K 목록(H-05)
public class MagazineCatchupTests : IDisposable
{
    private sealed class FakePlatform : IPlatform
    {
        public List<NewsItem> Readers { get; } = new();
        public int Beeps;
        public void OpenMagazine(string? page = null) { }
        public void OpenSettings(string? tab = null) { }
        public void OpenOnboarding() { }
        public void OpenReader(NewsItem item) => Readers.Add(item);
        public void Beep() => Beeps++;
        public void CloseWindow(string page) { }
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
    private readonly Magazine mag;
    private readonly AppModel model;
    private readonly FakePlatform platform = new();
    private readonly MagazinePage page;
    private readonly List<string> photoLoads = new();
    private readonly Dictionary<string, string> photos = new();
    private readonly DateTimeOffset now = DateTimeOffset.Now;

    public MagazineCatchupTests()
    {
        db = new Database(System.IO.Path.Combine(tmp.Path, "magazine.sqlite"));
        mag = new Magazine(db);
        model = new AppModel(new FakeUi(), mag, new AppState(), persist: false) { ShowAllSourcesForTests = true };
        page = new MagazinePage(model, mag, new Scrapbook(db), platform, new Bridge())
        {
            LoadPhotos = ids => photoLoads.AddRange(ids),
            PhotoUrl = id => photos.GetValueOrDefault(id),
        };
    }

    public void Dispose() { db.Dispose(); tmp.Dispose(); }

    private NewsItem It(string id, string title, string src, double minutesAgo, string? image = null, string? link = null) => new()
    {
        Id = id, Title = title, Link = link ?? "https://x.com/" + id, Date = now.AddMinutes(-minutesAgo), SourceId = src, SourceName = src.ToUpperInvariant(), Tier = "press", Image = image,
    };

    // 경제 3 · 스포츠 2 · AI 2(제목 낱말로 분야가 정해짐)
    private void Seed() => mag.Ingest([
        It("e1", "코스피 사상 최고치 경신", "src-e1", 10, image: "https://x.com/e1.jpg"),
        It("e2", "환율 1,380원대로 내려와", "src-e2", 20),
        It("e3", "기준금리 동결 결정", "src-e3", 30),
        It("s1", "프로야구 끝내기 홈런", "src-s1", 15),
        It("s2", "축구 대표팀 2-1 승리", "src-s2", 25),
        It("a1", "Anthropic raises $5B funding at $200B valuation", "cat-a1", 35),
        It("a2", "New jailbreak attack bypasses model safety", "cat-a2", 45),
    ], enrich: false);

    private async Task<JsonNode?> Run(string cmd, object? args = null) =>
        JsonNode.Parse(JsonSerializer.Serialize(await page.Handle(cmd, (JsonNode.Parse(JsonSerializer.Serialize(args ?? new { })) as JsonObject)!), Json.Options));

    [Fact]
    public async Task TodayProgressCountsReadAndMarksDone() // 대표 기사 = 표지 + 고른 분야 첫 줄, 읽은 수, 다 읽으면 그날은 끝난 호(새 소식 띠도 끔)
    {
        Seed();
        model.State.SectionsChosen = ["economy", "sports"];
        var v = (await page.IssueData("today"))!;
        var t = v.Today!;
        var r = mag.Resolve(mag.LiveDaily());
        Assert.Equal(TodayIssue.Keys(r.Cover?.Item.Key, r.Sections, model.ChosenSections), t.Keys);
        Assert.Equal(v.Cover!.Item.Key, t.Keys[0]);
        Assert.DoesNotContain(t.Keys, k => k.StartsWith("cat-a"));            // 고르지 않은 분야(AI)는 빼고
        Assert.Equal((0, false, false), (t.Read, t.Done, v.TodayDone));
        Assert.Equal("다음 호는 내일 오전 9시 브리핑으로 알려 드릴게요", t.Next);

        // 화면은 읽음이 바뀌면 막대만 다시 묻는다
        model.SetRead(It("e2", "", "src-e2", 0), true);
        var p = (await Run("todayProgress", new { keys = t.Keys }))!;
        Assert.Equal(t.Keys.Contains("src-e2|e2") ? 1 : 0, (int)p["read"]!);
        Assert.False((bool)p["done"]!);
        Assert.False(TodayIssue.IsMarkedDone(now));

        foreach (var k in t.Keys) model.State.Read[k] = 1;
        p = (await Run("todayProgress", new { keys = t.Keys }))!;
        Assert.Equal(t.Keys.Count, (int)p["read"]!);
        Assert.True((bool)p["done"]!);
        Assert.True(TodayIssue.IsMarkedDone(now));

        // 한 번 끝나면 안 읽음으로 돌려도 그날은 끝난 호. 오늘 호 분야 지면도 새 소식 띠를 띄우지 않음, 이번 주 호는 그대로
        model.State.Read.Remove(t.Keys[0]);
        v = (await page.IssueData("today"))!;
        Assert.True(v.Today!.Done);
        Assert.True(v.TodayDone);
        var eco = (await page.IssueData("today", focus: "economy"))!;
        Assert.Null(eco.Today);                                                // 분야를 고르면 막대 없음
        Assert.True(eco.TodayDone);
        Assert.False((await page.IssueData("week"))!.TodayDone);

        // 화면 JSON 이름
        var json = (await Run("issue", new { source = "today" }))!;
        Assert.True((bool)json["todayDone"]!);
        Assert.NotNull(json["today"]!["keys"]);
    }

    [Fact]
    public async Task NextIssueTextFollowsDigest() // 아침 브리핑을 끄면 '내일 아침', 시각을 바꾸면 그 시각
    {
        Seed();
        model.State.Settings.DigestEnabled = false;
        Assert.Equal("다음 호는 내일 아침에 엮여요", (await page.IssueData("today"))!.Today!.Next);
        model.State.Settings.DigestEnabled = true;
        model.State.Settings.DigestHour = 19;
        Assert.Equal("다음 호는 내일 오후 7시 브리핑으로 알려 드릴게요", page.Today([], now).Next);
        Assert.False(page.Today([], now).Done);                                // 대표 기사가 없으면 끝난 것이 아님
    }

    [Fact]
    public async Task EveningBriefOnFocusedTodaySection() // 오늘 호의 그 분야 지면 맨 위: 줄마다 [n](1부터, 범위 밖은 버림), 근거 기사 원제목·출처, 누르면 그 순서로 읽기 창
    {
        Seed();
        var ev = new[] { It("b1", "Fed holds rates", "reuters", 60), It("b2", "코스피 반등", "yna", 70), It("b3", "Won rallies", "bbg", 80) }
            .Select(i => i with { TitleKo = i.Title + " (번역)" }).ToList();
        model.State.Briefs["economy"] = new SectionBrief
        {
            Section = "economy", At = now.AddMinutes(-5), Items = ev,
            Lines = [new("금리를 묶었다.", [0, 2]), new("증시가 올랐다.", [1, 7])],
        };
        var b = (await page.IssueData("today", focus: "economy"))!.Brief!;
        Assert.Equal("저녁 정리 · 경제", b.Title);
        Assert.Equal(RelativeTime.Clock(now.AddMinutes(-5)), b.Time);
        Assert.Equal(MagazinePage.BriefHelp, b.Help);
        Assert.Contains("Ollama", b.Help);
        Assert.Equal([[1, 3], [2]], b.Lines.Select(l => l.Refs));
        Assert.Equal(["Fed holds rates", "코스피 반등", "Won rallies"], b.Items.Select(i => i.Title));   // 원제목 그대로(번역 제목 아님)
        Assert.Equal(("REUTERS", "https://x.com/b1"), (b.Items[0].Source, b.Items[0].Link));
        Assert.Matches("^#[0-9A-Fa-f]{6}$", b.Light);

        // 다른 곳에는 없음: 전체 지면 · 다른 분야 · 지난 호
        Assert.Null((await page.IssueData("today"))!.Brief);
        Assert.Null((await page.IssueData("today", focus: "sports"))!.Brief);
        Assert.Null((await page.IssueData("week", focus: "economy"))!.Brief);

        // 근거 기사를 누르면 읽기 창, J·K 는 근거 기사 순서로
        await Run("open", new { key = ev[1].Key, seq = ev.Select(i => i.Key) });
        Assert.Equal(ev[1].Key, platform.Readers.Single().Key);
        Assert.Equal(ev.Select(i => i.Key), ReadingList.Of(ev[1].Key).Select(i => i.Key));

        // 어제 만든 것 · 요약 줄이 없는 것은 싣지 않음
        model.State.Briefs["economy"] = model.State.Briefs["economy"] with { At = now.AddDays(-1) };
        Assert.Null(page.BriefData("economy"));
        model.State.Briefs["economy"] = model.State.Briefs["economy"] with { At = now, Lines = null };
        Assert.Null(page.BriefData("economy"));
    }

    [Fact]
    public async Task PaywallLocksOnCardsCoverAndTimeline() // 카드·표지·스토리 보도 줄기 데이터에 자물쇠 종류와 이유
    {
        mag.Ingest([
            It("w1", "Markets slide on rate fears", "wsj-x", 10, image: "https://x.com/w.jpg", link: "https://www.wsj.com/articles/markets-1"),
            It("n1", "Senate passes budget bill", "nyt-x", 20, link: "https://www.nytimes.com/2026/10/14/us/budget.html"),
            It("f1", "Free story about budget", "free-x", 30),
        ], enrich: false);
        var v = (await page.IssueData("today"))!;
        var all = v.Sections.SelectMany(s => s.Items).Append(v.Cover!.Item).ToDictionary(i => i.Key);
        Assert.Equal("hard", all["wsj-x|w1"].Paywall);
        Assert.Equal(PaywallKind.Hard.Help(), all["wsj-x|w1"].PaywallHelp);
        Assert.Equal("metered", all["nyt-x|n1"].Paywall);
        Assert.Equal(PaywallKind.Metered.Help(), all["nyt-x|n1"].PaywallHelp);
        Assert.Null(all["free-x|f1"].Paywall);

        var json = (await Run("issue", new { source = "today" }))!;
        Assert.Equal("hard", (string?)json["cover"]!["item"]!["paywall"]);   // 사진 있는 WSJ 가 표지
    }

    [Fact]
    public async Task GlassStripForSectionPages() // 분야 지면 머리: 영문 이름 · 'N건 · 첫 기사 제목' · 오늘의 사진. 구독 채널·그 밖의 소식은 예전 머리
    {
        Seed();
        mag.Ingest([It("v1", "Live demo video", "yt", 5) with { Kind = "video" }], enrich: false);
        model.State.SectionsChosen = ["economy", "sports"];
        photos["economy"] = "https://x.com/eco-face.jpg";
        var v = (await page.IssueData("today"))!;
        var eco = v.Sections.Single(s => s.Section == "economy");
        Assert.Equal("ECONOMY", eco.Glass!.English);
        Assert.Equal($"{eco.Items.Count}건 · {eco.Items[0].Title}", eco.Glass.Sub);
        Assert.Equal("https://x.com/eco-face.jpg", eco.Glass.Photo);
        var sports = v.Sections.Single(s => s.Section == "sports");
        Assert.Null(sports.Glass!.Photo);                                       // 사진을 아직 못 찾았으면 색면
        Assert.Null(v.Sections.Single(s => s.Tone == "kind-video").Glass);
        // 유리 띠가 있는 분야의 사진 찾기를 맡긴다(찾으면 앱이 'photos' 로 알림)
        Assert.Equal(v.Sections.Where(s => s.Glass is not null).Select(s => s.Section!), photoLoads);
        Assert.Contains("economy", photoLoads);
        var map = (await Run("photos", new { ids = new[] { "economy", "sports", "nope" } }))!.AsObject();
        Assert.Equal(["economy"], map.Select(p => p.Key));

        var json = (await Run("issue", new { source = "today", focus = "economy" }))!;
        Assert.Equal("ECONOMY", (string?)json["sections"]![0]!["glass"]!["english"]);
    }

    [Fact]
    public async Task PageFlipFollowsSidebarOrder() // Ctrl+[ · Ctrl+]: 오늘·이번 주·분야들·스토리·저장·스크랩북·검색·지난 호, 끝이면 경고음
    {
        var order = MagazinePage.PageOrder(["top", "economy"], ["daily-2026-10-13", "weekly-2026-W41"]);
        Assert.Equal(["today", "week", "section:top", "section:economy", "stories", "saved", "scrapbook", "search", "issue:daily-2026-10-13", "issue:weekly-2026-W41"], order);
        Assert.Equal("week", MagazinePage.Flip("today", 1, order));
        Assert.Equal("section:economy", MagazinePage.Flip("stories", -1, order));
        Assert.Equal("saved", MagazinePage.Flip("story:abc", 1, order));        // 한 스토리를 보는 중이면 '스토리' 자리에서
        Assert.Null(MagazinePage.Flip("today", -1, order));
        Assert.Null(MagazinePage.Flip("issue:weekly-2026-W41", 1, order));
        Assert.Null(MagazinePage.Flip("section:culture", 1, order));            // 옆 목록에 없는 지면

        model.State.SectionsChosen = ["economy"];
        Assert.Equal("section:economy", (string?)await Run("flip", new { page = "week" }));
        Assert.Equal("today", (string?)await Run("flip", new { page = "week", back = true }));
        Assert.Equal(0, platform.Beeps);
        Assert.Null(await Run("flip", new { page = "today", back = true }));
        Assert.Null(await Run("flip", new { page = "search" }));                 // 지난 호가 없으면 검색이 끝
        Assert.Equal(2, platform.Beeps);
    }

    [Fact]
    public async Task KeyboardActionsAndReadingOrder() // ⏎ 열기(지면 순서로 J·K) · O 브라우저 + 읽음 · M 읽음/안 읽음
    {
        Seed();
        var v = (await page.IssueData("today"))!;
        var seq = new[] { v.Cover!.Item.Key }.Concat(v.Sections.SelectMany(s => s.Items).Select(i => i.Key)).ToList();
        await Run("open", new { key = seq[2], seq = seq.Append("nope|0") });   // 모르는 key 는 버림
        Assert.Equal(seq, ReadingList.Of(seq[2]).Select(i => i.Key));
        Assert.Equal(seq[3], ReadingList.Step(seq[2], 1)?.Key);

        await Run("toggleRead", new { key = seq[4] });
        Assert.True(model.State.Read.ContainsKey(seq[4]));
        await Run("toggleRead", new { key = seq[4] });
        Assert.False(model.State.Read.ContainsKey(seq[4]));

        var opened = new List<Uri>();
        var before = ExternalLink.Opener;
        ExternalLink.Opener = u => { opened.Add(u); return true; };
        try
        {
            await Run("browser", new { key = seq[5] });                          // 오른쪽 클릭 메뉴: 읽음 처리 안 함
            Assert.False(model.State.Read.ContainsKey(seq[5]));
            await Run("browser", new { key = seq[5], read = true });             // 키보드 O: 읽음까지
            Assert.True(model.State.Read.ContainsKey(seq[5]));
            Assert.Equal(2, opened.Count);
        }
        finally { ExternalLink.Opener = before; }
    }
}
