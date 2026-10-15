using Dropcap.Core;
using Dropcap.Ui;

namespace Dropcap.Core.Tests;

// 매거진 왼쪽 목록 ↔ 오른쪽 화면 맞추기(맥 4e27109 · SidebarRuleTests·SidebarEditorTests 를 옮김)
public class SidebarEditorTests : IDisposable
{
    private readonly TempDir tmp = new();
    private readonly Database db;
    private readonly Magazine mag;
    private readonly AppModel model;
    private readonly DateTimeOffset now = DateTimeOffset.Now;

    public SidebarEditorTests()
    {
        db = new Database(Path.Combine(tmp.Path, "magazine.sqlite"));
        mag = new Magazine(db);
        model = new AppModel(new FakeUi(), mag, new AppState(), persist: false) { ShowAllSourcesForTests = true };
    }

    public void Dispose() { model.Stop(); db.Dispose(); tmp.Dispose(); }

    private NewsItem It(string id, string tier, double hoursAgo, bool important = false) => new()
    {
        Id = id, Title = "Story " + id, Link = "https://a.example/" + id, Date = now.AddHours(-hoursAgo), SourceId = "src-" + id,
        SourceName = "S" + id, Tier = tier, Important = important ? true : null,
    };

    // 이번 주 = 달력 한 주(일요일)의 시작 ~ 지금 — 지난 주간과 날이 겹치지 않게(예전엔 '지금부터 7일 전')
    [Fact]
    public void LiveWeeklyStartsAtCalendarWeek()
    {
        var w = mag.LiveWeekly();
        var start = DateTime.Today.AddDays(-(int)DateTime.Today.DayOfWeek);
        Assert.Equal(start, w.From.LocalDateTime);
    }

    // 주간 표지는 그 주 가장 많이 다룬 이야기 — 점수 1등(오늘 표지)과 같아지지 않게
    [Fact]
    public void WeeklyCoverIsMostCoveredStory()
    {
        foreach (var id in new[] { "a1", "a2", "a3" }) db.Upsert(It(id, "press", 30), "story-a");
        db.Upsert(It("b", "lab", 1, important: true), null);
        var from = now.AddDays(-3); var to = now.AddMinutes(1);
        var daily = mag.MakeIssue(IssueKind.Daily, from, to, "d");
        var weekly = mag.MakeIssue(IssueKind.Weekly, from, to, "w");
        Assert.Equal("src-b|b", daily.Cover);
        Assert.StartsWith("src-a", weekly.Cover);
    }

    // 예전 AI 분류로 나뉜 지면이 있는가(Magazine.NeedsRebuild 와 같은 규칙 — 고치기 전 코드로도 돌게 여기 둠)
    private static bool OldRules(Issue i) => i.Sections.Any(s => s.Kind is null && s.SectionId is null && !s.Category.IsOther());

    // 분야 개편 전에 엮은 호(예전 AI 분류 지면)는 발행 때 지금 규칙으로 다시 엮는다
    [Fact]
    public void OldIssuesAreRebuilt()
    {
        db.Upsert(It("c", "press", 20), null);
        var old = new Issue
        {
            Id = "daily-old", Kind = IssueKind.Daily, From = now.AddDays(-2), To = now.AddMinutes(1), Count = 1, Cover = null,
            Sections = [new Issue.Section { Category = Categories.All.First(c => !c.IsOther()), Keys = ["src-c|c"] }],
        };
        db.SaveIssue(old);
        Assert.True(OldRules(old));
        mag.PublishDue();
        var again = db.Issues().First(i => i.Id == "daily-old");
        Assert.False(OldRules(again));
        Assert.Equal("src-c|c", again.Cover);              // 기사 하나뿐이라 표지로(지면은 비어도 예전 AI 분류 지면은 없어짐)
    }
}

public class SidebarRuleTests : IDisposable
{
    private readonly TempDir tmp = new();
    public void Dispose() => tmp.Dispose();

    private static Issue I(string id, IssueKind k, DateTime to, int count = 10) =>
        new() { Id = id, Kind = k, From = new DateTimeOffset(to.AddDays(k == IssueKind.Weekly ? -7 : -1)), To = new DateTimeOffset(to), Count = count };

    [Fact]
    public void ArchiveOrderByIssueEnd()
    {
        var sun = new DateTime(2026, 10, 11);           // 일요일 0시 = 지난 주간의 끝
        var list = Magazine.ArchiveOrder([I("sat", IssueKind.Daily, sun.AddHours(-6)), I("w", IssueKind.Weekly, sun), I("sun", IssueKind.Daily, sun.AddHours(18)),
                                          I("tie-d", IssueKind.Daily, sun.AddDays(-7)), I("tie-w", IssueKind.Weekly, sun.AddDays(-7))]);
        Assert.Equal(["sun", "w", "sat", "tie-w", "tie-d"], list.Select(i => i.Id));
    }

    [Fact]
    public void WeekRangeIsCalendarWeek()
    {
        var (from, to) = Magazine.WeekRange(new DateTime(2026, 10, 15, 13, 0, 0)); // 목요일
        Assert.Equal(new DateTime(2026, 10, 11), from);
        Assert.Equal(new DateTime(2026, 10, 18), to);
        Assert.Equal(from, Magazine.WeekRange(from).From);                      // 일요일 0시는 그 주
        Assert.Equal(new DateTime(2026, 10, 4), Magazine.WeekRange(from.AddHours(-1)).From); // 바로 앞 주와 이어짐
    }

    [Fact]
    public void ThinIssue()
    {
        Assert.True(I("a", IssueKind.Daily, DateTime.Today, count: 4).IsThin);
        Assert.False(I("b", IssueKind.Daily, DateTime.Today, count: 5).IsThin);
    }

    [Fact]
    public void RememberSearch()
    {
        var l = Magazine.RememberSearch(" 엔비디아 ", ["금리", "NVIDIA"]);
        Assert.Equal(["엔비디아", "금리", "NVIDIA"], l);
        Assert.Equal(["nvidia", "금리"], Magazine.RememberSearch("nvidia", ["금리", "NVIDIA"]));   // 대소문자만 다르면 하나로
        Assert.Equal(["금리"], Magazine.RememberSearch("a", ["금리"]));                               // 한 글자는 남기지 않음
        Assert.Equal(8, Magazine.RememberSearch("새 낱말", Enumerable.Range(0, 10).Select(i => "w" + i).ToList()).Count);
    }

    [Fact]
    public async Task PageCountsThinAndEmptySearch()
    {
        using var db = new Database(Path.Combine(tmp.Path, "magazine.sqlite"));
        var mag = new Magazine(db);
        var model = new AppModel(new FakeUi(), mag, new AppState(), persist: false) { ShowAllSourcesForTests = true };
        var page = new MagazinePage(model, mag, new Scrapbook(db), new MiniPlatform(), new Bridge()) { LoadPhotos = _ => { }, PhotoUrl = _ => null };
        model.State.Settings.WatchKeywords = ["한국은행"];
        model.State.Saved.Add(new NewsItem { Id = "s1", Title = "Saved", Link = "https://a.example/s1", SourceId = "x", SourceName = "X", Tier = "press" });
        Assert.Equal(1, (await page.SavedData()).Count);                          // 왼쪽 '저장 N' 과 같은 수

        var empty = await page.SearchData("", false);
        Assert.Equal(["한국은행"], empty.Watch!);
        Assert.Empty(empty.Recent!);
        await page.SearchData("기준금리", true);                                  // Enter 로 찾으면 최근 검색에
        await page.SearchData("기준", false);                                     // 입력 중은 남기지 않음
        Assert.Equal(["기준금리"], (await page.SearchData("", false)).Recent!);

        db.SaveIssue(new Issue { Id = "daily-x", Kind = IssueKind.Daily, From = DateTimeOffset.Now.AddDays(-2), To = DateTimeOffset.Now.AddDays(-1), Count = 2 });
        mag.PublishDue();
        var row = page.Sidebar().Archive.First(r => r.Id == "daily-x");
        Assert.True(row.Thin);
        Assert.Equal(2, row.Count);
        model.Stop();
    }
}
