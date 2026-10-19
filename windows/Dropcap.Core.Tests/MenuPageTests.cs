using System.Text.Json;
using System.Text.Json.Nodes;
using Dropcap.Ui;

namespace Dropcap.Core.Tests;

// 트레이 창 처리기(MenuPage): 중요순 점수(맥 ImportanceSortTests), 시간 묶음 이름표, 줄 사진 고르기, 출처별 이름표,
// 분야 칩 줄·AI 하위 칩 거르기(G-09), 줄의 분야 표시(U-05), 바로 줄이기(G-11)
public class MenuPageTests : IDisposable
{
    private sealed class FakePlatform : IPlatform
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
    private readonly Magazine mag;
    private readonly AppModel model;
    private readonly MenuPage page;
    private readonly DateTimeOffset now = new(DateTime.Today.AddHours(15)); // 오늘 오후 3시(로컬)

    public MenuPageTests()
    {
        db = new Database(System.IO.Path.Combine(tmp.Path, "magazine.sqlite"));
        mag = new Magazine(db);
        model = new AppModel(new FakeUi(), mag, new AppState(), persist: false) { ShowAllSourcesForTests = true, Now = () => now };
        page = new MenuPage(model, new FakePlatform());
    }

    public void Dispose() { db.Dispose(); tmp.Dispose(); }

    private NewsItem It(string id, double hoursAgo, string tier = "press", string src = "s", string? image = null) => new()
    {
        Id = id, Title = id, Link = "https://x.com/" + id, Date = now.AddHours(-hoursAgo), Summary = "",
        SourceId = src, SourceName = src.ToUpperInvariant(), Tier = tier, Image = image,
    };

    private async Task<JsonNode> View(object args) =>
        JsonNode.Parse(JsonSerializer.Serialize(await page.Handle("view", (JsonNode.Parse(JsonSerializer.Serialize(args)) as JsonObject)!), Json.Options))!;

    [Fact]
    public void CoverageBeatsRecency() // 여러 곳이 다룬 기사가 방금 나온 단독 기사보다 앞
    {
        NewsItem fresh = It("fresh", 0.1), big = It("big", 20), lab = It("lab", 5, tier: "lab");
        var o = MenuPage.ByImportance([fresh, big, lab], new Dictionary<string, int> { [big.Key] = 4 }, now);
        Assert.Equal(["big", "lab", "fresh"], o.Select(i => i.Id));
    }

    [Fact]
    public void DiffersFromNewestWithoutStars() // ★·외 N곳이 없어도 최신순과 다르게 정렬
    {
        NewsItem a = It("a", 1), b = It("b", 30, tier: "lab");
        Assert.Equal("b", MenuPage.ByImportance([a, b], new Dictionary<string, int>(), now)[0].Id);
    }

    [Fact]
    public void TimeSectionLabels() // 방금(1시간 안)·오늘·어제·이전 — 앞 기사와 묶음이 바뀔 때만
    {
        NewsItem just = It("j", 0.2), today = It("t", 3), today2 = It("t2", 5), yday = It("y", 20), old = It("o", 80);
        var none = new NewsItem { Id = "n", Title = "n", Link = "https://x.com/n", SourceId = "s", SourceName = "S" };
        Assert.Equal("방금", MenuPage.TimeSection(just, null, now));
        Assert.Equal("오늘", MenuPage.TimeSection(today, just, now));
        Assert.Null(MenuPage.TimeSection(today2, today, now));
        Assert.Equal("어제", MenuPage.TimeSection(yday, today2, now));
        Assert.Equal("이전", MenuPage.TimeSection(old, yday, now));
        Assert.Null(MenuPage.TimeSection(none, old, now));       // 날짜 없는 기사는 '이전'
    }

    [Fact]
    public async Task HeroAndTimeSectionsInView() // 첫 소식은 크게(이름표 없이), 그다음부터 시간 묶음 이름표
    {
        model.State.Recent = [It("j", 0.2), It("t", 3), It("t2", 5), It("y", 20)];
        var v = await View(new { tab = "all", sort = "newest" });
        Assert.Equal("Dropcap", (string?)v["header"]!["title"]);
        Assert.Null(v["header"]!["vessel"]);
        var rows = v["rows"]!.AsArray();
        Assert.Equal(4, rows.Count);
        Assert.True((bool)rows[0]!["hero"]!);
        Assert.Null((string?)rows[0]!["section"]);
        Assert.False((bool)rows[1]!["hero"]!);
        Assert.Equal("오늘", (string?)rows[1]!["section"]);
        Assert.True((bool)rows[1]!["sectionFirst"]!);
        Assert.Null((string?)rows[2]!["section"]);
        Assert.Equal("어제", (string?)rows[3]!["section"]);
        Assert.False((bool)rows[3]!["sectionFirst"]!);
        Assert.Null((string?)v["sortLabel"]);
    }

    [Fact]
    public void ThumbSkipsJunk() // 피드 사진 → 매거진이 찾아 둔 사진, 잡그림(프로필·로고)은 빼고 없으면 null
    {
        string? Stored(string key) => key == "s|b" ? "https://x.com/photo.jpg" : key == "s|c" ? "https://x.com/static/logo.png" : null;
        Assert.Equal("https://x.com/a.jpg", MenuPage.Thumb(It("a", 1, image: "https://x.com/a.jpg"), Stored));
        Assert.Equal("https://x.com/photo.jpg", MenuPage.Thumb(It("b", 1, image: "https://x.com/u/avatar-12.png"), Stored));
        Assert.Null(MenuPage.Thumb(It("c", 1, image: "https://x.com/byline/kim.jpg"), Stored));
        Assert.Null(MenuPage.Thumb(It("d", 1), Stored));
    }

    [Fact]
    public async Task ThumbFromMagazineInView() // 피드에 사진이 없으면 매거진 DB 의 대표 사진
    {
        var a = It("a", 1);
        mag.Ingest([a], enrich: false);
        db.SetImage(a.Key, "https://x.com/hero.jpg");
        model.State.Recent = [a, It("b", 2, image: "https://x.com/favicon.ico")];
        var rows = (await View(new { tab = "all" }))["rows"]!.AsArray();
        Assert.Equal("https://x.com/hero.jpg", (string?)rows[0]!["thumb"]);
        Assert.Null((string?)rows[1]!["thumb"]);
    }

    [Fact]
    public async Task SourceHeads() // 출처별: 출처가 바뀌는 곳에만 이름표(출처명 + 개수), 시간 이름표는 없음
    {
        model.State.Recent = [It("1", 1, src: "b"), It("2", 2, src: "a"), It("3", 30, src: "b"), It("4", 3, src: "a"), It("5", 0.1, src: "c")];
        var v = await View(new { tab = "all", sort = "source" });
        Assert.Equal("출처별", (string?)v["sortLabel"]);
        var rows = v["rows"]!.AsArray();
        Assert.Equal(["2", "4", "1", "3", "5"], rows.Select(r => ((string)r!["item"]!["key"]!).Split('|')[1]));
        Assert.Equal(["A", null, "B", null, "C"], rows.Select(r => (string?)r!["sourceHead"]));
        Assert.Equal([2, 0, 2, 0, 1], rows.Select(r => (int)r!["sourceCount"]!));
        Assert.True((bool)rows[0]!["sourceFirst"]!);
        Assert.All(rows, r => Assert.Null((string?)r!["section"]));
        // 정렬은 기억된다(다음에 열 때 그대로)
        Assert.Equal("source", (string?)(await View(new { tab = "all" }))["sort"]);
    }

    [Fact]
    public async Task ImportantSortUsesCoverage() // 중요순은 매거진 스토리 크기(외 N곳)를 본다
    {
        var lone = It("lone", 0.1);
        var told = It("told", 10, src: "x") with { Related = ["y", "z"] };
        model.State.Recent = [lone, told];
        var v = await View(new { tab = "all", sort = "important" });
        Assert.Equal("중요순", (string?)v["sortLabel"]);
        Assert.Equal("x|told", (string?)v["rows"]![0]!["item"]!["key"]);
    }

    // 분야가 정해진 실제 출처(shared/sources.json)의 기사
    private NewsItem In(string id, string src, string title, double hoursAgo = 1, string tier = "press", List<string>? related = null) => new()
    {
        Id = id, Title = title, Link = "https://x.com/" + id, Date = now.AddHours(-hoursAgo), Summary = "",
        SourceId = src, SourceName = src.ToUpperInvariant(), Tier = tier, Related = related,
    };

    private Task<object?> Do(string cmd, object args) => page.Handle(cmd, (JsonNode.Parse(JsonSerializer.Serialize(args)) as JsonObject)!);
    private static List<string> Ids(JsonNode v) => v["rows"]!.AsArray().Select(r => ((string)r!["item"]!["key"]!).Split('|')[1]).ToList();

    private void Sample()
    {
        model.State.SectionsChosen = ["top", "economy", "ai"];
        model.State.Recent =
        [
            In("eco", "yna-market", "코스피 2,900 회복", 1, "kr"),
            In("chip", "hk-finance", "AI 반도체 수출 급증", 2, "kr"),               // 경제 글이지만 AI 칩도 붙음
            In("gpt", "openai", "Introducing GPT-6", 3),
            In("jail", "anthropic", "New jailbreak exploit found", 4),
            In("big", "sbs-top", "국회 본회의 예산안 처리", 5, "kr", ["KBS", "MBC"]),  // 여러 곳이 다룸 → 주요 뉴스
            In("goal", "yna-sports", "프로야구 결승 홈런", 6, "kr"),                 // 고르지 않은 분야
        ];
    }

    [Fact]
    public async Task SectionChipsAreChosenSections() // G-09: '전체'(화면) + 고른 분야, AI 하위 칩은 AI 를 골랐을 때만('기타' 빼고)
    {
        Sample();
        var v = await View(new { tab = "all" });
        Assert.Equal(["top", "economy", "ai"], v["chips"]!.AsArray().Select(c => (string)c!["id"]!));
        Assert.Equal("경제", (string?)v["chips"]![1]!["label"]);
        Assert.Equal("cat.business", (string?)v["chips"]![1]!["icon"]);
        Assert.Matches("^#[0-9A-Fa-f]{6}$", (string)v["chips"]![1]!["light"]!);
        Assert.Empty(v["topics"]!.AsArray());
        Assert.Null((string?)v["section"]);
        Assert.Equal(6, v["rows"]!.AsArray().Count);

        var ai = await View(new { tab = "all", section = "ai" });
        Assert.Equal("ai", (string?)ai["section"]);
        Assert.Equal(["model", "research", "policy", "business", "security"], ai["topics"]!.AsArray().Select(c => (string)c!["id"]!));
    }

    [Fact]
    public async Task SectionChipFiltersList() // 분야 칩으로 거르기 — AI 는 다른 분야 글에서도 끌어오고, 주요 뉴스는 여러 곳·공식 발표·★
    {
        Sample();
        Assert.Equal(["eco", "chip"], Ids(await View(new { tab = "all", section = "economy" })));
        Assert.Equal(["chip", "gpt", "jail"], Ids(await View(new { tab = "all", section = "ai" })));
        Assert.Equal(["big"], Ids(await View(new { tab = "all", section = "top" })));
        // 고르지 않은 분야는 칩이 없으니 '전체'로(화면은 돌려받은 section 을 따른다)
        var other = await View(new { tab = "all", section = "sports" });
        Assert.Null((string?)other["section"]);
        Assert.Equal(6, other["rows"]!.AsArray().Count);
        // 거른 결과가 비면 '맞는 소식이 없습니다'
        model.State.Recent.RemoveAll(i => i.Id is "eco" or "chip");
        Assert.Equal("맞는 소식이 없습니다", (string?)(await View(new { tab = "all", section = "economy" }))["empty"]!["title"]);
    }

    [Fact]
    public async Task AiTopicChipFilters() // AI 하위 칩(모델·보안…)은 AI 칩 아래에서만 걸린다
    {
        Sample();
        var model1 = await View(new { tab = "all", section = "ai", topic = "model" });
        Assert.Equal("model", (string?)model1["topic"]);
        Assert.Contains("gpt", Ids(model1));
        Assert.DoesNotContain("jail", Ids(model1));
        Assert.Equal(["jail"], Ids(await View(new { tab = "all", section = "ai", topic = "security" })));
        // AI 가 아닌 분야에서는 하위 칩을 무시
        var eco = await View(new { tab = "all", section = "economy", topic = "security" });
        Assert.Null((string?)eco["topic"]);
        Assert.Equal(["eco", "chip"], Ids(eco));
    }

    [Fact]
    public async Task RowTopicLabel() // U-05·N-05: 줄의 분야 표시 — AI 글은 'AI·모델', 나머지는 분야 이름
    {
        Sample();
        var rows = (await View(new { tab = "all" }))["rows"]!.AsArray();
        JsonNode Row(string id) => rows.First(r => ((string)r!["item"]!["key"]!).EndsWith("|" + id))!;
        Assert.Equal("AI·모델·제품", (string?)Row("gpt")["topicLabel"]);
        Assert.Equal("cat.model", (string?)Row("gpt")["topicIcon"]);
        Assert.Equal("#007AFF", (string?)Row("gpt")["topicLight"]);
        Assert.Equal("#0A84FF", (string?)Row("gpt")["topicDark"]);
        Assert.Equal("경제", (string?)Row("eco")["topicLabel"]);
        Assert.Equal("cat.business", (string?)Row("eco")["topicIcon"]);
        Assert.Equal("정치", (string?)Row("big")["topicLabel"]);   // '주요' 출처 글은 낱말로 분야를 정함
    }

    [Fact]
    public async Task ReduceInfoForMenu() // G-11: 오른쪽 클릭 메뉴 문구 — 출처명, 분야 덜 받기(즉시→묶음→매거진만), 제목 낱말
    {
        Sample();
        model.State.SectionPolicy["economy"] = new SectionPolicy { Mode = NotifyMode.Instant };
        var r = JsonNode.Parse(JsonSerializer.Serialize(await Do("reduceInfo", new { key = "yna-market|eco" }), Json.Options))!;
        Assert.Equal("이 출처 숨기기 — YNA-MARKET", (string?)r["hideLabel"]);
        Assert.Equal("economy", (string?)r["section"]);
        Assert.True((bool)r["canLess"]!);
        Assert.Equal("bundle", (string?)r["next"]);
        Assert.Equal("경제 덜 받기 — 묶음으로", (string?)r["lessLabel"]);
        Assert.Equal(["코스피", "회복"], r["words"]!.AsArray().Select(w => (string)w!));

        // 매거진만이면 더 줄일 것이 없고, 고르지 않은 분야도 덜 받기가 없다
        model.State.SectionPolicy["economy"] = new SectionPolicy { Mode = NotifyMode.Magazine };
        Assert.False((bool)JsonNode.Parse(JsonSerializer.Serialize(await Do("reduceInfo", new { key = "yna-market|eco" }), Json.Options))!["canLess"]!);
        var sports = JsonNode.Parse(JsonSerializer.Serialize(await Do("reduceInfo", new { key = "yna-sports|goal" }), Json.Options))!;
        Assert.False((bool)sports["canLess"]!);
        Assert.Null((string?)sports["lessLabel"]);
    }

    [Fact]
    public async Task ReduceActionsChangeState() // G-11: 세 가지 바로 줄이기가 상태에 남는다
    {
        Sample();
        model.State.SectionPolicy["economy"] = new SectionPolicy { Mode = NotifyMode.Instant };
        // 이 분야 덜 받기: 즉시 → 묶음 → 매거진만 (AI 칩이 붙은 경제 글도 고른 분야 순서대로 경제)
        await Do("lessOf", new { key = "yna-market|eco" });
        Assert.Equal(NotifyMode.Bundle, model.Policy("economy").Mode);
        await Do("lessOf", new { key = "hk-finance|chip" });
        Assert.Equal(NotifyMode.Magazine, model.Policy("economy").Mode);
        await Assert.ThrowsAsync<InvalidOperationException>(() => Do("lessOf", new { key = "yna-sports|goal" }));   // 고르지 않은 분야

        // 이 낱말 알리지 않기
        await Do("muteWord", new { word = " 코스피 " });
        Assert.Contains("코스피", model.State.Settings.MuteKeywords);
        await Assert.ThrowsAsync<ArgumentException>(() => Do("muteWord", new { word = "  " }));

        // 이 출처 숨기기: 목록에서 빠지고 숨긴 출처에 남는다
        await Do("hideSource", new { key = "openai|gpt" });
        Assert.Contains("openai", model.State.HiddenSources);
        Assert.DoesNotContain("gpt", Ids(await View(new { tab = "all" })));
        await Do("hideSource", new { key = "openai|gpt" });                  // 지우지 않으므로 다시 숨겨도 그대로
        Assert.Equal(1, model.State.HiddenSources.Count(s => s == "openai"));
        model.UnhideSource("openai");                                        // 풀면 목록에 돌아옴
        Assert.Contains("gpt", Ids(await View(new { tab = "all" })));
    }
}
