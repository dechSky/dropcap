using System.Text.Json;
using System.Text.Json.Nodes;
using Dropcap.Ui;

namespace Dropcap.Core.Tests;

// 첫 실행 관심 분야 고르기 처리기(OnboardingPage, G-03): 카드 데이터, 다시 열 때 지금 고른 것, 고르기 → 분야·기본 정책·창 닫기
public class OnboardingPageTests : IDisposable
{
    private sealed class FakePlatform : IPlatform
    {
        public List<string> Closed { get; } = new();
        public int Onboarding;
        public void OpenMagazine(string? page = null) { }
        public void OpenSettings(string? tab = null) { }
        public void OpenOnboarding() => Onboarding++;
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
    private readonly FakePlatform platform = new();
    private readonly OnboardingPage page;

    public OnboardingPageTests()
    {
        db = new Database(System.IO.Path.Combine(tmp.Path, "magazine.sqlite"));
        model = new AppModel(new FakeUi(), new Magazine(db), new AppState(), persist: false);
        // 기본 출처를 미리 켜 두어 고른 뒤 매거진 채우기(바깥 피드 받기)가 돌지 않게
        foreach (var m in Sections.Meta.Values.Where(m => m.DefaultOn == true)) model.State.Enabled[m.Id] = true;
        page = new OnboardingPage(model, platform);
    }

    public void Dispose() { model.Stop(); db.Dispose(); tmp.Dispose(); }

    private async Task<JsonNode?> Do(string cmd, object? args = null) =>
        JsonNode.Parse(JsonSerializer.Serialize(await page.Handle(cmd, (JsonNode.Parse(JsonSerializer.Serialize(args ?? new { })) as JsonObject)!), Json.Options));

    [Fact]
    public async Task FirstRunView() // 처음: 주요 뉴스 켬, 카드는 흐름(주요 뉴스)을 뺀 분야 전부, 기후·환경은 '더 보기'
    {
        Assert.True(model.NeedsOnboarding);
        var v = (await Do("ready"))!;
        Assert.True((bool)v["first"]!);
        Assert.Equal("top", (string?)v["top"]!["id"]);
        Assert.True((bool)v["top"]!["on"]!);
        Assert.Equal(OnboardingPage.TopHelp, (string?)v["top"]!["help"]);
        var cards = v["cards"]!.AsArray();
        Assert.Equal(Sections.Pickable.Select(s => s.Id), cards.Select(c => (string)c!["id"]!));
        Assert.DoesNotContain("top", cards.Select(c => (string)c!["id"]!));
        Assert.Equal(["climate"], cards.Where(c => (bool)c!["more"]!).Select(c => (string)c!["id"]!));
        var eco = cards.First(c => (string)c!["id"]! == "economy")!;
        Assert.Equal("경제", (string?)eco["label"]);
        Assert.Equal("cat.business", (string?)eco["icon"]);
        Assert.Matches("^#[0-9A-Fa-f]{6}$", (string)eco["color"]!);
        Assert.Equal(OnboardingPage.SourceLine("economy"), (string?)eco["sources"]);
        Assert.Empty(v["picked"]!.AsArray());
        Assert.False((bool)v["showMore"]!);
    }

    [Fact]
    public void SourceLinePrefersDefaultOn() // 대표 출처 2~3곳: 처음 켜질 곳 먼저(이름순보다 앞), 없으면 AI 는 예시·나머지는 '준비 중'
    {
        var meta = PivotFixtures.Meta;
        Assert.Equal("CNBC · 연합 마켓+ · 한국경제 증권", OnboardingPage.SourceLine("economy", meta));   // 서울경제(기본 꺼짐)는 이름순으로 앞이지만 뒤로
        Assert.Equal("BBC World", OnboardingPage.SourceLine("world", meta));
        Assert.Equal("출처 준비 중", OnboardingPage.SourceLine("climate", meta));
        Assert.Equal("OpenAI · Anthropic · AI타임스 등", OnboardingPage.SourceLine("ai", new Dictionary<string, SourceMeta>()));
    }

    [Fact]
    public async Task ChooseSetsSectionsAndDefaultPolicy() // 고르면 주요 뉴스 + 분야, 앞 두 분야만 즉시(주요 뉴스는 즉시), 창이 닫힌다
    {
        await Do("choose", new { ids = new[] { "sports", "economy", "politics", "ai" }, top = true });
        Assert.False(model.NeedsOnboarding);
        Assert.Equal(["top", "politics", "economy", "ai", "sports"], model.ChosenSections);   // 분야 순서대로
        Assert.Equal(NotifyMode.Instant, model.Policy("top").Mode);
        Assert.Equal(NotifyMode.Instant, model.Policy("politics").Mode);
        Assert.Equal(NotifyMode.Instant, model.Policy("economy").Mode);
        Assert.Equal(NotifyMode.Bundle, model.Policy("ai").Mode);
        Assert.Equal(NotifyMode.Bundle, model.Policy("sports").Mode);
        Assert.Equal(["onboarding"], platform.Closed);
        // 고른 분야의 기본 출처는 켜지고, 고르지 않은 분야의 출처는 꺼진다
        Assert.True(model.State.Enabled["yna-market"]);
        Assert.False(model.State.Enabled["bbc-world"]);
    }

    [Fact]
    public async Task ChooseWithoutTopAndJunk() // 주요 뉴스 스위치를 끄면 빠지고, 모르는 id·흐름 id 는 버린다. 카드가 없으면 거절(창도 그대로)
    {
        await Assert.ThrowsAsync<InvalidOperationException>(() => Do("choose", new { ids = new[] { "top", "nope" }, top = true }));
        Assert.True(model.NeedsOnboarding);
        Assert.Empty(platform.Closed);

        await Do("choose", new { ids = new[] { "world", "nope", "top", "world" }, top = false });
        Assert.Equal(["world"], model.ChosenSections);
    }

    [Fact]
    public async Task ReopenShowsCurrentPicks() // 설정에서 다시 열면 지금 고른 것·주요 뉴스 스위치·'더 보기' 펼침이 그대로, 단추는 '저장'
    {
        await Do("choose", new { ids = new[] { "economy", "climate" }, top = false });
        var v = (await Do("ready"))!;
        Assert.False((bool)v["first"]!);
        Assert.False((bool)v["top"]!["on"]!);
        Assert.Equal(["economy", "climate"], v["picked"]!.AsArray().Select(n => (string)n!));
        Assert.True((bool)v["showMore"]!);

        // 다시 고르면 이미 있던 분야 정책은 그대로(덜 받기 등 사용자가 바꾼 것을 덮지 않음)
        model.LessOf("economy");
        var before = model.Policy("economy").Mode;
        await Do("choose", new { ids = new[] { "economy", "ai" }, top = true });
        Assert.Equal(["top", "economy", "ai"], model.ChosenSections);
        Assert.Equal(before, model.Policy("economy").Mode);
        Assert.Equal(2, platform.Closed.Count);
    }
}
