using System.Text.Json;
using System.Text.Json.Nodes;
using Dropcap.Ui;

namespace Dropcap.Core.Tests;

// 매거진 창 처리기(MagazinePage): 보기 데이터 모양·정렬·검색 규칙·스크랩북 명령·내보내기(맥 MagazineView 와 같은 동작)
public class MagazinePageTests : IDisposable
{
    private sealed class FakePlatform : IPlatform
    {
        public List<NewsItem> Readers { get; } = new();
        public List<string> Copied { get; } = new();
        public List<(string Name, string Text)> SavedFiles { get; } = new();
        public List<string> Closed { get; } = new();
        public int SettingsOpened { get; private set; }
        public void OpenMagazine(string? page = null) { }
        public void OpenSettings(string? tab = null) => SettingsOpened++;
        public void OpenOnboarding() { }
        public void OpenReader(NewsItem item) => Readers.Add(item);
        public void CloseWindow(string page) => Closed.Add(page);
        public void Quit() { }
        public void CopyText(string text) => Copied.Add(text);
        public Task<bool> SaveTextFile(string suggestedName, string text) { SavedFiles.Add((suggestedName, text)); return Task.FromResult(true); }
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
    private readonly Scrapbook book;
    private readonly AppModel model;
    private readonly FakePlatform platform = new();
    private readonly Bridge bridge = new();
    private readonly MagazinePage page;
    private readonly DateTimeOffset now = DateTimeOffset.Now;

    public MagazinePageTests()
    {
        db = new Database(System.IO.Path.Combine(tmp.Path, "magazine.sqlite"));
        mag = new Magazine(db);
        book = new Scrapbook(db);
        model = new AppModel(new FakeUi(), mag, new AppState(), persist: false) { ShowAllSourcesForTests = true };
        // 분야 사진은 바깥 피드를 받지 않게 비워 둔다(유리 띠 사진은 MagazineCatchupTests)
        page = new MagazinePage(model, mag, book, platform, bridge) { LoadPhotos = _ => { }, PhotoUrl = _ => null };
        bridge.Register(page);
    }

    public void Dispose() { db.Dispose(); tmp.Dispose(); }

    private NewsItem It(string id, string title, string src, double minutesAgo, string tier = "press", string? image = null, string? kind = null,
        int related = 0, string? titleKo = null) => new()
    {
        Id = id, Title = title, TitleKo = titleKo, Link = "https://x.com/" + id, Date = now.AddMinutes(-minutesAgo), SourceId = src, SourceName = src.ToUpperInvariant(),
        Tier = tier, Image = image, Kind = kind, Related = related > 0 ? Enumerable.Range(0, related).Select(i => "r" + i).ToList() : null,
    };

    // 오늘 호에 실릴 기사(분야가 제목 낱말로 정해짐: 모델 2·투자 2·영상 1)
    private void Seed() => mag.Ingest([
        It("1", "OpenAI launches GPT-6 model with new reasoning", "openai", 30, "lab", "https://x.com/a.jpg"),
        It("2", "Google releases Gemini 3 model for developers", "verge", 20, related: 2),
        It("3", "Meta open sources Llama 5 model weights", "tc", 40, image: "https://x.com/c.jpg"),
        It("4", "Anthropic raises $5B funding at $200B valuation", "tc", 50),
        It("5", "AI startup raises Series B funding round", "vb", 10, related: 1),
        It("6", "Live demo video of agents", "yt", 15, kind: "video"),
    ], enrich: false);

    private Task<object?> Run(string cmd, object? args = null) =>
        page.Handle(cmd, args is null ? new JsonObject() : (JsonNode.Parse(JsonSerializer.Serialize(args)) as JsonObject)!);

    // 옆 목록 맨 아래 '설정' 줄 · Ctrl+, → 설정 창(맥 MagazineView 의 '설정' 줄·⌘,)
    [Fact]
    public async Task SettingsOpensSettingsWindow()
    {
        Assert.Null(await Run("settings"));
        Assert.Equal(1, platform.SettingsOpened);
        Assert.Empty(platform.Closed); // 매거진 창은 그대로
    }

    [Fact]
    public async Task TodayIssueShape()
    {
        Seed();
        var v = (await page.IssueData("today"))!;
        Assert.True(v.Live);
        Assert.EndsWith(" 호", v.Title);
        Assert.Equal("openai|1", v.Cover!.Item.Key);          // 사진 있는 1등이 표지
        Assert.Null(v.Empty);
        Assert.Equal(mag.Revision, v.Revision);
        Assert.Equal("recommended", v.Sort);
        var video = v.Sections.Single(s => s.Id == "video");
        Assert.Equal(("kind.video", "kind-video"), (video.Icon, video.Tone));
        Assert.True(video.Items.Single().External);
        var keys = v.Sections.SelectMany(s => s.Items).Select(i => i.Key).ToList();
        Assert.DoesNotContain("openai|1", keys);                // 표지는 지면에 다시 싣지 않음
        Assert.Equal(keys.Count, keys.Distinct().Count());
        Assert.All(v.Sections.Where(s => s.Id != "video"), s => Assert.StartsWith("cat-", s.Tone));

        // 화면에 가는 JSON 은 camelCase(웹 쪽 이름과 맞음)
        var json = JsonNode.Parse(JsonSerializer.Serialize(await Run("issue", new { source = "today" }), Json.Options))!;
        Assert.NotNull(json["cover"]!["item"]!["title"]);
        Assert.NotNull(json["sectionCount"]);
        Assert.NotNull(json["sections"]![0]!["items"]![0]!["kindLabel"]);
    }

    [Fact]
    public async Task EmptyAndPreparingAndMissingIssue()
    {
        var v = (await page.IssueData("today"))!;
        Assert.Null(v.Cover);
        Assert.Equal("아직 이번 호에 실을 소식이 없습니다", v.Empty!.Title);
        mag.Preparing = true;
        v = (await page.IssueData("week"))!;
        Assert.True(v.Empty!.Preparing);
        Assert.Equal("첫 호를 엮는 중…", v.Empty.Title);
        Assert.Null(await page.IssueData("daily-1999-01-01")); // 정리돼 없어진 지난 호
    }

    [Fact]
    public void SortsMatchMac()
    {
        var a = It("a", "a", "zeta", 30, related: 1);
        var b = It("b", "b", "alpha", 10);
        var c = It("c", "c", "alpha", 5, related: 3);
        var d = It("d", "d", "mid", 20, related: 1);
        List<NewsItem> list = [a, b, c, d];
        Assert.Equal("abcd", Keys(MagazinePage.Sort(list, "recommended")));   // 편집 순서 그대로
        Assert.Equal("cbda", Keys(MagazinePage.Sort(list, "newest")));
        Assert.Equal("cadb", Keys(MagazinePage.Sort(list, "coverage")));      // 같은 수면 원래 순서
        Assert.Equal("cbda", Keys(MagazinePage.Sort(list, "source")));        // 출처 이름순, 같은 출처는 최신 먼저
        static string Keys(List<NewsItem> l) => string.Concat(l.Select(i => i.Id));
    }

    [Fact]
    public async Task SortIsRemembered()
    {
        Seed();
        Assert.Equal("recommended", MagazinePage.CurrentSort());
        var v = (await page.IssueData("today", "newest"))!;
        Assert.Equal("newest", v.Sort);
        Assert.Equal("newest", Prefs.Get("magSort", ""));
        var model2 = v.Sections.Where(s => s.Items.Count > 1).OrderByDescending(s => s.Items.Count).First().Items;   // 기사가 가장 많은 지면
        Assert.Equal(model2.OrderByDescending(i => i.Date).Select(i => i.Key), model2.Select(i => i.Key));
        Assert.Equal("newest", (await page.IssueData("today", "bogus"))!.Sort); // 모르는 값은 무시
        Assert.Equal("newest", page.Sidebar().Sort);
    }

    [Fact]
    public async Task SearchFromTwoLetters()
    {
        mag.Ingest([It("1", "Quantum model", "a", 5), It("2", "Other", "b", 5)], enrich: false);
        Assert.Empty((await page.SearchData("", false)).Items!);
        Assert.Null((await page.SearchData("Q", false)).Items);        // 한 글자는 입력 중엔 찾지 않음(앞 결과 그대로)
        Assert.Single((await page.SearchData("Q", true)).Items!);      // Enter 면 한 글자도
        Assert.Single((await page.SearchData("Qu", false)).Items!);
        Assert.Equal(2, (await page.SearchData("o", true)).Items!.Count); // 대소문자 없이 제목 어디서나
    }

    [Fact]
    public async Task ScrapbookCommands()
    {
        var a = It("1", "Meta", "verge", 5);
        var b = It("2", "Google", "tc", 5);
        // 스크랩 시각을 정해 넣는다(같은 밀리초에 들어가 순서가 흔들리지 않게)
        db.SaveScrap(new Scrap { Item = a, Quote = "첫 문단", QuoteOriginal = "First", Created = now.AddMinutes(-3) });
        db.SaveScrap(new Scrap { Item = b, Created = now.AddMinutes(-2) });
        db.SaveScrap(new Scrap { Item = a, Quote = "둘째 문단", Created = now.AddMinutes(-1) });
        book.Reload();
        var v = page.ScrapbookData(null);
        Assert.Equal("스크랩", v.Folder);
        Assert.Equal(3, v.Total);
        Assert.Equal(["verge|1", "tc|2"], v.Groups.Select(g => g.Item.Key)); // 최근 스크랩한 기사부터
        Assert.Equal(["첫 문단", "둘째 문단"], v.Groups[0].Scraps.Select(s => s.Quote)); // 기사 안에서는 스크랩한 순서
        Assert.Equal("First", v.Groups[0].Scraps[0].Original);

        Assert.Equal(true, Prop(await Run("newFolder", new { name = " 조사 " }), "ok"));
        Assert.Equal(false, Prop(await Run("newFolder", new { name = "조사" }), "ok")); // 같은 이름은 다시 못 만듦
        Assert.Contains("조사", book.Collections);

        var id = v.Groups[1].Scraps[0].Id;
        await Run("memo", new { id, memo = "나중에 보기" });
        Assert.Equal("나중에 보기", book.Scraps.Single(s => s.Id == id).Memo);
        await Run("moveScrap", new { id, to = "조사", memo = "옮기며 고침" });
        var moved = book.Scraps.Single(s => s.Id == id);
        Assert.Equal(("조사", "옮기며 고침"), (moved.Collection, moved.Memo));
        await Assert.ThrowsAsync<InvalidOperationException>(() => Run("moveScrap", new { id, to = "없는 폴더" }));

        var r = await Run("renameFolder", new { from = "조사", to = "보고서" });
        Assert.Equal((true, "보고서"), ((bool)Prop(r, "ok")!, (string)Prop(r, "folder")!));
        Assert.Equal("보고서", book.Scraps.Single(s => s.Id == id).Collection);
        Assert.Equal(false, Prop(await Run("renameFolder", new { from = "보고서", to = "스크랩" }), "ok"));

        // 보던 폴더가 비면 내용 있는 폴더로 다시 고름
        await Run("deleteScrap", new { id });
        Assert.Equal(2, book.Scraps.Count);
        Assert.Equal("스크랩", page.ScrapbookData("보고서", repick: true).Folder);
        Assert.Equal("보고서", page.ScrapbookData("보고서").Folder);
        Assert.Equal([("스크랩", 2), ("보고서", 0)], page.ScrapbookData(null).Folders.Select(f => (f.Name, f.Count)));
    }

    [Fact]
    public async Task MarkdownExportMatchesRender()
    {
        var a = It("1", "Meta ships", "verge", 5, titleKo: "메타 출시");
        book.Add(a, quote: "문단\n둘째 줄", original: "para", memo: "메모", collection: "조사");
        book.Add(It("2", "Other", "tc", 5), collection: "조사");
        book.Add(It("3", "Elsewhere", "tc", 5), collection: "스크랩");
        var expected = Scrapbook.Render(book.Scraps.Where(s => s.Collection == "조사").ToList(), "조사");
        await Run("copyMarkdown", new { folder = "조사" });
        Assert.Equal(expected, platform.Copied.Single());
        Assert.Contains("> 문단\n> 둘째 줄", expected);
        Assert.DoesNotContain("Elsewhere", expected);
        Assert.Equal(true, await Run("saveMarkdown", new { folder = "조사" }));
        Assert.Equal(("조사.md", expected), platform.SavedFiles.Single());
    }

    [Fact]
    public async Task OpenArticleInReaderAndVideoOutside()
    {
        Seed();
        await page.IssueData("today");
        var opened = new List<Uri>();
        var before = ExternalLink.Opener;
        ExternalLink.Opener = u => { opened.Add(u); return true; };
        try
        {
            await Run("open", new { key = "tc|3" });
            Assert.Equal("tc|3", platform.Readers.Single().Key);
            Assert.True(model.State.Read.ContainsKey("tc|3"));
            await Run("open", new { key = "yt|6" });
            Assert.Single(platform.Readers);                    // 영상은 읽기 창이 아니라 바깥으로
            Assert.Equal("https://x.com/6", opened.Single().ToString());
            await Run("toggleSaved", new { key = "vb|5" });
            Assert.True(model.IsSaved(model.State.Saved[0]));
            Assert.Equal(1, page.Sidebar().Saved);
            var marks = JsonNode.Parse(JsonSerializer.Serialize(page.Marks(["tc|3", "vb|5", "verge|2"]), Json.Options))!;
            Assert.Equal("tc|3", marks["read"]![0]!.GetValue<string>());
            Assert.Equal("vb|5", marks["saved"]![0]!.GetValue<string>());
            await Assert.ThrowsAsync<KeyNotFoundException>(() => Run("open", new { key = "nope|0" }));
        }
        finally { ExternalLink.Opener = before; }
    }

    [Fact]
    public async Task StoriesAndTimeline()
    {
        Seed();
        mag.Ingest([It("9", "GPT-6 model launches: OpenAI reveals new reasoning", "verge", 25)], enrich: false);
        var stories = await page.StoriesData();
        var s = Assert.Single(stories.Live);                     // 최근 24시간 안에 보도가 붙음 → 지금 커지는 스토리
        Assert.Empty(stories.Past);
        Assert.Equal(2, s.Size);
        Assert.StartsWith("첫 보도 ", s.Times);
        Assert.Contains(" · 최근 ", s.Times);
        Assert.Equal("https://x.com/a.jpg", s.Photo);
        Assert.Equal(["OPENAI", "VERGE"], s.Sources.Select(x => x.Name));
        Assert.Equal((0, false), (s.Fresh, s.Following));         // 처음 보는 스토리는 '새 보도' 없음
        var t = await page.StoryData(s.Id);
        Assert.StartsWith("2곳 보도 · ", t.Sub);
        Assert.Equal(["openai|1", "verge|9"], t.Items.Select(r => r.Item.Key)); // 먼저 보도한 곳부터
        Assert.True(t.Items[0].First);
        Assert.False(t.Items[1].First);
        Assert.Matches(@"^오[전후] \d+:\d\d$", t.Items[0].When);
        Assert.Null(t.Items[0].Gap);
        Assert.Null(t.Intl);                                       // 해외만 다룬 스토리는 두 칸 없음
        // 표지 기사가 스토리에 묶여 있으면 '여러 시각 N곳'
        var v = (await page.IssueData("today"))!;
        Assert.Equal((s.Id, 2), (v.Cover!.Cluster, v.Cover.Size));
    }

    [Fact]
    public async Task FollowAndNewReports()
    {
        Seed();
        mag.Ingest([It("9", "GPT-6 model launches: OpenAI reveals new reasoning", "verge", 25)], enrich: false);
        var id = (await page.StoriesData()).Live.Single().Id;
        // 팔로우하면 지금 보도 수까지는 본 것으로, 그 뒤 붙은 보도가 '새 보도 N'
        Assert.Equal(true, Prop(await Run("follow", new { id, on = true }), "following"));
        Assert.True(model.IsFollowing(id));
        mag.Ingest([It("10", "OpenAI reveals GPT-6 model with new reasoning", "wired", 5)], enrich: false);
        var c = (await page.StoriesData()).Live.Single();
        Assert.Equal((3, 1, true), (c.Size, c.Fresh, c.Following));
        Assert.True((await page.StoryData(id)).Following);
        Assert.Equal(0, (await page.StoriesData()).Live.Single().Fresh);   // 스토리를 열면 본 것으로
        Assert.Equal(false, Prop(await Run("follow", new { id, on = false }), "following"));
        Assert.False(model.IsFollowing(id));
        await Assert.ThrowsAsync<KeyNotFoundException>(() => Run("follow", new { id = "nope", on = true }));
    }

    [Fact]
    public void StoryGapsSpansAndLede()
    {
        var at = new DateTimeOffset(new DateTime(2026, 10, 13, 9, 0, 0, DateTimeKind.Local));
        NewsItem A(string id, DateTimeOffset? d) => It(id, "First report", "x", 0) with { Date = d };
        var a = A("a", at);
        var b = A("b", at.AddMinutes(20));
        var c = A("c", at.AddMinutes(80));
        var d = A("d", at.AddHours(4));
        Assert.Null(MagazinePage.Gap([a, b], 1));                           // 30분 안이면 표시 안 함
        Assert.Null(MagazinePage.Gap([a], 0));
        Assert.Equal("60분 뒤", MagazinePage.Gap([b, c], 1));
        Assert.Equal("3시간 뒤", MagazinePage.Gap([a, A("e", at.AddHours(3))], 1));
        Assert.Matches(@"^10월 14일 \([일월화수목금토]\)$", MagazinePage.Gap([d, A("f", at.AddDays(1))], 1)!);   // 날이 바뀌면 날짜
        Assert.Equal("한 시간 안에 이어진 보도", MagazinePage.Span([a, b]));
        Assert.Equal("4시간에 걸친 보도", MagazinePage.Span([a, b, c, d]));
        Assert.Equal("3일에 걸친 보도", MagazinePage.Span([a, A("g", at.AddHours(70))]));
        Assert.Equal("", MagazinePage.Span([A("h", null)]));
        Assert.Null(MagazinePage.Lede(a with { Summary = "짧은 요약" }));
        Assert.Null(MagazinePage.Lede(a with { Summary = "First report: and more words that go on and on" }));   // 제목으로 시작하면 생략
        Assert.Equal("본문 첫 문장이 여기 있습니다. 둘째 문장도 이어집니다.", MagazinePage.Lede(a with { Summary = "<p>본문 첫 문장이   여기 있습니다.</p> 둘째 문장도 이어집니다." }));
        Assert.Equal(220, MagazinePage.Lede(a with { Summary = new string('가', 400) })!.Length);
    }

    // 분야가 낱말로 정해지는 기사(출처를 모르면 제목 낱말로 — Sections.Classify): 경제 3·스포츠 2·AI 2
    private void SeedSections() => mag.Ingest([
        It("e1", "코스피 사상 최고치 경신", "src-e1", 10, image: "https://x.com/e1.jpg"),
        It("e2", "환율 1,380원대로 내려와", "src-e2", 20),
        It("e3", "기준금리 동결 결정", "src-e3", 30),
        It("s1", "프로야구 끝내기 홈런", "src-s1", 15),
        It("s2", "축구 대표팀 2-1 승리", "src-s2", 25),
        It("a1", "Anthropic raises $5B funding at $200B valuation", "cat-a1", 35),
        It("a2", "New jailbreak attack bypasses model safety", "cat-a2", 45),
    ], enrich: false);

    [Fact]
    public async Task SidebarListsChosenSections()
    {
        Assert.Empty(page.Sidebar().Sections);
        model.State.SectionsChosen = ["top", "economy", "sports"];   // ChooseSections 는 출처를 켜고 받아 오므로 상태만
        var side = page.Sidebar();
        Assert.Equal(["top", "economy", "sports"], side.Sections.Select(s => s.Id));
        var eco = side.Sections[1];
        Assert.Equal(("경제", "cat.business"), (eco.Name, eco.Icon));
        Assert.Matches("^#[0-9A-Fa-f]{6}$", eco.Light);
        // 지면 이름 section:<id> 으로 연다(묶음 알림)
        Assert.Equal("magazine.html?page=section%3Aeconomy", MagazinePage.Url("section:economy"));
        var json = JsonNode.Parse(JsonSerializer.Serialize(await Run("sidebar"), Json.Options))!;
        Assert.Equal("economy", json["sections"]![1]!["id"]!.GetValue<string>());
    }

    [Fact]
    public async Task SectionPageAndChips()
    {
        SeedSections();
        var all = (await page.IssueData("today"))!;
        Assert.NotNull(all.Cover);
        Assert.Null(all.Focus);
        // 칩 줄: 지면이 있는 분야 + 건수(표지는 지면에 없으므로 빠짐)
        var chips = all.Chips.ToDictionary(c => c.Id, c => c.Count);
        Assert.Equal(2, chips["economy"]);
        Assert.Equal(2, chips["sports"]);
        Assert.Equal(2, chips["ai"]);
        Assert.Empty(all.SubChips);
        Assert.Equal(all.Sections.Where(s => s.Section is not null).Sum(s => s.Items.Count), all.Chips.Sum(c => c.Count));
        // 표지·카드의 분야 표시
        Assert.Equal("경제", all.Topics[all.Cover!.Item.Key].Label);

        // section:economy 지면: 표지 없이 그 분야만
        var eco = (await page.IssueData("today", focus: "economy"))!;
        Assert.Equal("economy", eco.Focus);
        Assert.Null(eco.Cover);
        Assert.Null(eco.Empty);
        var sec = Assert.Single(eco.Sections);
        Assert.Equal(("economy", "경제", "cat.business", false), (sec.Section, sec.Label, sec.Icon, sec.ShowTopic));
        Assert.Equal(2, sec.Items.Count);
        Assert.Equal(all.Chips.Select(c => c.Id), eco.Chips.Select(c => c.Id));   // 칩 줄은 그대로(한 분야를 골라도)

        // AI 를 고르면 하위 칩(모델·연구·정책·투자·보안), 하위 칩으로 더 거름
        var ai = (await page.IssueData("today", focus: "ai"))!;
        Assert.Equal(["model", "research", "policy", "business", "security"], ai.SubChips.Select(c => c.Id));
        var cat = ai.Sections.Single().Items[0].Category;
        var narrowed = (await page.IssueData("today", focus: "ai", sub: cat))!;
        Assert.Equal(cat, narrowed.Sub);
        Assert.All(narrowed.Sections.SelectMany(s => s.Items), i => Assert.Equal(cat, i.Category));
        Assert.Null((await page.IssueData("today", focus: "economy", sub: cat))!.Sub);   // 하위 칩은 AI 에서만

        // 고른 분야에 오늘 소식이 없으면 안내
        var empty = (await page.IssueData("today", focus: "culture"))!;
        Assert.Empty(empty.Sections);
        Assert.Contains("문화·연예", empty.Empty!.Title);
        Assert.Contains(empty.Chips, c => c.Id == "culture" && c.Count == 0);

        // 화면 명령으로도
        var json = JsonNode.Parse(JsonSerializer.Serialize(await Run("issue", new { source = "today", focus = "sports" }), Json.Options))!;
        Assert.Equal("sports", json["focus"]!.GetValue<string>());
        Assert.Equal("sports", json["sections"]![0]!["section"]!.GetValue<string>());
        Assert.NotNull(json["chips"]![0]!["count"]);
    }

    [Fact]
    public async Task MixedSectionsShowTopic()
    {
        mag.Ingest([It("x1", "가을 단풍 소식", "src-x1", 10, image: "https://x.com/x.jpg"), It("x2", "날씨 이야기", "src-x2", 20)], enrich: false);
        model.State.SectionsChosen = ["economy"];
        var v = (await page.IssueData("today"))!;
        // 고르지 않은 분야에 한 건뿐이면 '그 밖의 소식'으로, 여러 분야가 섞인 지면이라 카드에 분야 표시
        var other = v.Sections.Single(s => s.Section is null && s.Tone != "kind-video");
        Assert.Equal("그 밖의 소식", other.Label);
        Assert.True(other.ShowTopic);
        Assert.All(other.Items, i => Assert.True(v.Topics.ContainsKey(i.Key)));
    }

    [Fact]
    public async Task RegionLinesAndColumns()
    {
        mag.Ingest([
            It("c", "City council approves new park budget", "src-c", 5, "lab", "https://x.com/c.jpg"),
            It("i", "OpenAI launches GPT-6 model with new reasoning", "src-intl", 30),
            It("k", "GPT-6 model launches: OpenAI reveals new reasoning", "src-kr", 20, "kr"),
        ], enrich: false);
        var v = (await page.IssueData("today"))!;
        Assert.Equal("src-c|c", v.Cover!.Item.Key);
        // 해외·국내가 섞인 스토리의 카드에 두 줄(출처 이름 3곳까지)
        var (key, lines) = Assert.Single(v.Regions);
        Assert.Equal("src-intl|i", key);
        Assert.Equal(["SRC-INTL"], lines.Intl);
        Assert.Equal(["SRC-KR"], lines.Kr);
        // 스토리 상세: '해외에서는 N곳 / 국내에서는 N곳' 두 칸
        var s = await page.StoryData(v.Clusters[key]);
        Assert.Equal(("해외에서는", "globe", 1), (s.Intl!.Title, s.Intl.Icon, s.Intl.Count));
        Assert.Equal(("국내에서는", "house", 1), (s.Kr!.Title, s.Kr.Icon, s.Kr.Count));
        Assert.Equal("src-kr|k", s.Kr.Items.Single().Key);
        var json = JsonNode.Parse(JsonSerializer.Serialize(await Run("issue", new { source = "today" }), Json.Options))!;
        Assert.Equal("SRC-KR", json["regions"]!["src-intl|i"]!["kr"]![0]!.GetValue<string>());   // 기사 key 는 camelCase 로 바뀌지 않음
    }

    [Fact]
    public async Task ReduceFromCard()
    {
        SeedSections();
        model.State.SectionsChosen = ["economy"];
        model.State.SectionPolicy["economy"] = new SectionPolicy { Mode = NotifyMode.Instant };
        var got = new List<string>();
        using var _ = bridge.Attach("magazine", got.Add);
        page.Attach();
        await page.IssueData("today");
        var it = Lookup.Find(model, "src-e2|e2", mag)!;
        var r = page.Reduce(it);
        Assert.Equal("이 출처 숨기기 — SRC-E2", r.Hide);
        Assert.Equal("경제 덜 받기 — 묶음으로", r.Less);
        Assert.Contains("환율", r.Words);
        Assert.Null(page.Reduce(Lookup.Find(model, "src-s1|s1", mag)!).Less);   // 고르지 않은 분야는 '덜 받기' 없음

        await Run("lessOf", new { key = "src-e2|e2" });
        Assert.Equal(NotifyMode.Bundle, model.Policy("economy").Mode);
        Assert.Equal("경제 덜 받기 — 매거진에만", page.Reduce(it).Less);
        await Run("lessOf", new { key = "src-e2|e2" });
        Assert.Null(page.Reduce(it).Less);                                     // 매거진만이면 더 줄일 것 없음

        await Run("muteWord", new { key = "src-e2|e2", word = "환율" });
        Assert.Contains("환율", model.State.Settings.MuteKeywords);
        await Assert.ThrowsAsync<InvalidOperationException>(() => Run("muteWord", new { key = "src-e2|e2", word = "아무말" }));

        // 출처 숨기기: 지면에서 바로 빠지고, 화면에는 layoutRevision 이 바뀐 changed(띠 없이 다시 엮음)
        got.Clear();
        var before = mag.LayoutRevision;
        await Run("hideSource", new { key = "src-e2|e2" });
        Assert.Contains("src-e2", model.State.HiddenSources);
        Assert.Contains(got.Select(g => JsonNode.Parse(g)!), e => e["event"]!.GetValue<string>() == "changed" && e["data"]!["layoutRevision"]!.GetValue<int>() == before + 1);
        var v = (await page.IssueData("today"))!;
        Assert.Equal(before + 1, v.LayoutRevision);
        Assert.DoesNotContain(v.Sections.SelectMany(s => s.Items), i => i.SourceId == "src-e2");
    }

    [Fact]
    public void BalancedGridColumns()
    {
        // 맥 BalancedGridTests 그대로: 마지막 줄에 카드 한 장만 남지 않게
        for (var fit = 2; fit <= 4; fit++)
            for (var n = 1; n <= 12; n++)
            {
                var c = MagazinePage.Columns(fit, n);
                Assert.InRange(c, 1, 4);
                Assert.False(n > c && n % c == 1 && fit >= 3, $"fit {fit} count {n} → {c} 칸에 한 장 남음");
            }
        Assert.Contains(MagazinePage.Columns(3, 4), new[] { 4, 2 });
        Assert.Equal(1, MagazinePage.Columns(0, 0));
        Assert.Equal(3, MagazinePage.Columns(3, 6));
    }

    [Fact]
    public void AttachForwardsChanges()
    {
        var got = new List<string>();
        using var _ = bridge.Attach("magazine", got.Add);
        page.Attach();
        page.Attach(); // 두 번 불러도 한 번만
        mag.Ingest([It("1", "Hello", "a", 1)], enrich: false);
        var ev = JsonNode.Parse(got.Single())!;
        Assert.Equal("changed", ev["event"]!.GetValue<string>());
        Assert.Equal(mag.Revision, ev["data"]!["revision"]!.GetValue<int>());
        got.Clear();
        page.Go("saved");
        Assert.Equal("saved", JsonNode.Parse(got.Single())!["data"]!.GetValue<string>());
        Assert.Equal("magazine.html?page=issue%3Adaily-2026-10-12", MagazinePage.Url("issue:daily-2026-10-12"));
    }

    private static object? Prop(object? o, string name) => o!.GetType().GetProperty(name)!.GetValue(o);
}
