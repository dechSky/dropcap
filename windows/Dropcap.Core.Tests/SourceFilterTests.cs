using Dropcap.Core;
using Dropcap.Ui;

namespace Dropcap.Core.Tests;

// 맥 mac/Tests/DropcapTests/SourceFilterTests.swift 를 옮긴 것 + 화면까지(S-13 끈 출처 글 바로 빼기):
// 끄기·다시 켜기·해지·분야 해제·숨기기가 목록·안 읽음·매거진·스토리·검색에 바로 반영되는지
public class SourceFilterTests
{
    private static readonly List<Source> Srcs = Resources.Config.Sources.Take(3).ToList();
    private static NewsItem Item(string src, string id) => new()
    {
        Id = id, Title = "t-" + id, Link = "https://x.com/" + id, Date = DateTimeOffset.Now, Summary = "", SourceId = src, SourceName = src, Tier = "press",
    };
    private static AppState State(string[] on, string[]? hidden = null)
    {
        var s = new AppState();
        foreach (var id in on) s.Enabled[id] = true;
        s.HiddenSources = (hidden ?? []).ToList();
        return s;
    }

    [Fact]
    public void TurningOffHidesAndTurningOnRestores()
    {
        var (a, b) = (Srcs[0].Id, Srcs[1].Id);
        var items = new[] { Item(a, "1"), Item(b, "2"), Item(a, "3") };
        var st = State([a, b]);
        Assert.Equal(3, SourceFilter.Make(st, Srcs).Visible(items).Count);
        st.Enabled[a] = false;                                       // 구독 끄기
        Assert.Equal(["2"], SourceFilter.Make(st, Srcs).Visible(items).Select(i => i.Id));
        st.Enabled[a] = true;                                        // 다시 켜기 → 지우지 않았으므로 그대로 돌아옴
        Assert.Equal(3, SourceFilter.Make(st, Srcs).Visible(items).Count);
    }

    [Fact]
    public void RemovedCustomSourceIsHidden()
    {
        var a = Srcs[0].Id;
        const string gone = "custom-removed-channel";               // 해지해서 출처 목록에 없는 채널
        var v = SourceFilter.Make(State([a, gone]), Srcs).Visible([Item(a, "1"), Item(gone, "2")]);
        Assert.Equal(["1"], v.Select(i => i.Id));
    }

    [Fact]
    public void SectionDeselectTurnsSourcesOffSoTheyHide()
    {
        var (a, b) = (Srcs[0].Id, Srcs[1].Id);
        var st = State([a, b]);
        st.Enabled[b] = false;                                       // 분야를 빼면 그 분야 출처가 꺼짐(ChooseSections)
        Assert.True(SourceFilter.Make(st, Srcs).Shows(a));
        Assert.False(SourceFilter.Make(st, Srcs).Shows(b));
    }

    [Fact]
    public void HiddenWinsEvenWhenEnabled() => Assert.False(SourceFilter.Make(State([Srcs[0].Id], [Srcs[0].Id]), Srcs).Shows(Srcs[0].Id));

    [Fact]
    public void NeverEnabledSourceIsHidden() => Assert.False(SourceFilter.Make(State([]), Srcs).Shows(Srcs[0].Id));

    [Fact]
    public void NoActiveSetMeansOnlyHiddenApplies() // 시험·옮기기용 기본값
    {
        var f = new SourceFilter { Hidden = new HashSet<string> { "x" } };
        Assert.True(f.Shows("y") && !f.Shows("x"));
    }
}

// 끄기 → 트레이 창 목록·안 읽음 수·매거진(오늘·지난 호·표지)·스토리 목록과 크기·검색·알림 대기열에 바로, 다시 켜면 돌아옴
public class SourceFilterAppTests : IDisposable
{
    private readonly TempDir tmp = new();
    private readonly Database db;
    private readonly AppModel model;
    private readonly MenuPage menu;
    private readonly string a, b, c;
    private readonly DateTimeOffset now = DateTimeOffset.Now;

    public SourceFilterAppTests()
    {
        db = new Database(Path.Combine(tmp.Path, "magazine.sqlite"));
        model = new AppModel(new FakeUi(), new Magazine(db), new AppState(), persist: false);
        menu = new MenuPage(model, new NullPlatform());
        var press = Resources.Config.Sources.Where(s => s.Kind is null or "article").ToList();
        (a, b, c) = (press[0].Id, press[1].Id, press[2].Id);
        foreach (var id in new[] { a, b, c }) model.State.Enabled[id] = true;
    }

    public void Dispose() { db.Dispose(); tmp.Dispose(); }

    private sealed class NullPlatform : IPlatform
    {
        public void OpenMagazine(string? page = null) { }
        public void OpenSettings(string? tab = null) { }
        public void OpenOnboarding() { }
        public void OpenReader(NewsItem item) { }
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

    private NewsItem It(string src, string id, string title, double hoursAgo) => new()
    {
        Id = id, Title = title, Link = "https://x.com/" + id, Date = now.AddHours(-hoursAgo), Summary = "", SourceId = src, SourceName = src, Tier = "press",
    };

    private async Task<int> MenuRows(string tab = "all")
    {
        var v = System.Text.Json.Nodes.JsonNode.Parse(System.Text.Json.JsonSerializer.Serialize(await menu.Handle("view",
            (System.Text.Json.Nodes.JsonNode.Parse($$"""{"tab":"{{tab}}"}""") as System.Text.Json.Nodes.JsonObject)!), Json.Options))!;
        return v["rows"]!.AsArray().Count;
    }

    [Fact]
    public async Task OffHidesEverywhereAndOnRestores()
    {
        // 같은 소식 세 곳(스토리 하나) + a 혼자 쓴 글
        var story = new[] { It(a, "s1", "OpenAI launches GPT-6 reasoning model today", 1), It(b, "s2", "OpenAI launches GPT-6 reasoning model", 2), It(c, "s3", "GPT-6 from OpenAI launches with reasoning", 3) };
        var solo = It(a, "x1", "Quantum chip breakthrough announced in Zurich", 0.5);
        model.Magazine.Ingest(story.Append(solo).ToList(), enrich: false);
        model.State.Recent = story.Append(solo).OrderByDescending(i => i.Date).ToList();
        model.State.Unread = 4;
        model.State.Pending.Add(new AppState.PendingItem(solo, "ai", "story-x", now));
        var issue = model.Magazine.MakeIssue(IssueKind.Daily, now.AddDays(-1), now.AddMinutes(1), "daily-test");   // 끄기 전에 엮은 호(지난 호 흉내)

        Assert.Equal(4, await MenuRows());
        var storyId = model.Magazine.ClusterId(story[0].Key)!;
        Assert.Equal(3, model.Magazine.Stories().Single(s => s.Id == storyId).Size);

        model.SetEnabled(a, false);                                                // 구독 끄기
        Assert.Equal(2, await MenuRows());                                         // 목록
        Assert.Equal(2, model.State.Unread);                                       // 안 읽음 수가 줄어듦
        Assert.Empty(model.State.Pending);                                         // 알림 대기열에서도 빠짐
        Assert.DoesNotContain(model.Magazine.Search("Quantum"), i => i.SourceId == a); // 검색
        Assert.Equal(2, model.Magazine.Stories().Single(s => s.Id == storyId).Size);   // 스토리 크기는 보이는 보도만
        Assert.All(model.Magazine.StoryItems(storyId), i => Assert.NotEqual(a, i.SourceId));
        var past = model.Magazine.Resolve(issue);                                  // 지난 호·표지에서도 빠짐
        Assert.True(past.Cover is null || past.Cover.Item.SourceId != a);
        Assert.All(past.Sections.SelectMany(s => s.Items), i => Assert.NotEqual(a, i.SourceId));
        var live = model.Magazine.Resolve(model.Magazine.LiveDaily());             // 오늘 호
        Assert.All(live.Sections.SelectMany(s => s.Items).Concat(live.Cover is { } lc ? [lc.Item] : []), i => Assert.NotEqual(a, i.SourceId));

        model.SetEnabled(b, false);                                                // 보이는 출처가 한 곳만 남으면 스토리 목록에서 빠짐
        Assert.DoesNotContain(model.Magazine.Stories(), s => s.Id == storyId);

        model.SetEnabled(a, true);                                                 // 다시 켜기 → 지우지 않았으므로 돌아옴
        model.SetEnabled(b, true);
        Assert.Equal(4, await MenuRows());
        Assert.Contains(model.Magazine.Search("Quantum"), i => i.SourceId == a);
        Assert.Equal(3, model.Magazine.Stories().Single(s => s.Id == storyId).Size);
    }

    [Fact]
    public async Task RemovedChannelAndDeselectedSectionDisappear()
    {
        model.State.CustomSources.Add(new Source { Id = "custom-x", Name = "X", Url = "https://x.example/feed", Type = "feed" });
        model.State.Enabled["custom-x"] = true;
        model.State.Recent = [It("custom-x", "1", "Custom channel post", 1), It(a, "2", "Other news", 2)];
        model.State.Saved = [It("custom-x", "1", "Custom channel post", 1)];
        Assert.Equal(2, await MenuRows());
        model.RemoveCustomSource("custom-x");                                      // 해지
        Assert.Equal(1, await MenuRows());
        Assert.Equal(1, await MenuRows("saved"));                                  // 저장한 기사는 사용자가 고른 것이라 그대로

        var sec = Sections.SectionOfSource(a);
        if (sec is null) return;                                                   // 분야가 없는 출처면 분야 해제 단계는 건너뜀
        model.ChooseSections([sec]);
        Assert.Equal(1, await MenuRows());
        model.ChooseSections([Sections.All.First(s => !s.IsFlow && s.Id != sec).Id]); // 그 분야를 빼면 그 출처가 꺼져 빠짐
        Assert.Equal(0, await MenuRows());
    }
}
