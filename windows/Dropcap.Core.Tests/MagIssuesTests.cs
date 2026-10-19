using Dropcap.Core;

namespace Dropcap.Core.Tests;

// 매거진 지난 호(맥 MagIssuesTests): 설치 전 기사 채우기 · 빈 날 호 발행 · 지난 호 목록 날짜 묶음
public class MagIssuesTests : IDisposable
{
    private readonly TempDir tmp = new();
    private readonly Database db;
    private readonly Magazine mag;

    public MagIssuesTests()
    {
        db = new Database(Path.Combine(tmp.Path, "magazine.sqlite"));
        mag = new Magazine(db);
    }

    public void Dispose() { db.Dispose(); tmp.Dispose(); }

    private static NewsItem It(string id, DateTimeOffset? date) => new()
    {
        Id = id, Title = "기사 " + id, Link = "https://geeknews.example/" + id, Date = date, SourceId = "geeknews", SourceName = "geeknews", Tier = "press",
    };

    private static Issue Daily(DateTime day, int count = 10) => new()
    {
        Id = "daily-" + Magazine.DayId(day), Kind = IssueKind.Daily, Date = day, From = new DateTimeOffset(day.AddHours(-6)), To = new DateTimeOffset(day.AddHours(18)), Count = count,
    };

    // 채운 지난 날 기사도 그날 호가 생긴다(예전엔 1~3일 전만 엮어 4일 넘은 날은 영영 호가 없었다). 14일보다 앞은 엮지 않는다
    [Fact]
    public void PublishDueFillsEmptyDays()
    {
        var today = DateTime.Today;
        foreach (var back in new[] { 6, 10, 20 })
            for (var i = 0; i < 3; i++) db.Upsert(It($"d{back}-{i}", new DateTimeOffset(today.AddDays(-back).AddHours(10 + i))), null);
        mag.PublishDue();
        var ids = db.Issues().Select(i => i.Id).ToHashSet();
        Assert.Contains("daily-" + Magazine.DayId(today.AddDays(-6)), ids);
        Assert.Contains("daily-" + Magazine.DayId(today.AddDays(-10)), ids);
        Assert.DoesNotContain("daily-" + Magazine.DayId(today.AddDays(-20)), ids);
    }

    // 지지난주 기사도 주간 호가 생긴다(예전엔 지난주만)
    [Fact]
    public void PublishDueFillsWeekBeforeLast()
    {
        var thisWeek = Magazine.WeekRange(DateTime.Now).From;
        var last = Magazine.WeekRange(thisWeek.AddHours(-1)).From;
        var before = Magazine.WeekRange(last.AddHours(-1)).From;
        for (var i = 0; i < 3; i++) db.Upsert(It($"w{i}", new DateTimeOffset(before.AddHours(30 + i))), null);
        mag.PublishDue();
        Assert.Contains("weekly-" + Magazine.WeekId(before), db.Issues().Select(i => i.Id));
    }

    // 채우기: 7일 안 · 새것부터 상한까지 · 날짜 없는 글·앞날 글 뺌(예전엔 3일·25건)
    [Fact]
    public void MagazineFillWindowAndCap()
    {
        var now = DateTimeOffset.Now;
        var items = Enumerable.Range(0, 200).Select(h => It("f" + h, now.AddHours(-h))).ToList();
        items.Add(It("nodate", null));
        items.Add(It("future", now.AddDays(1)));
        var all = AppModel.MagazineFillItems(items, now, 500);
        Assert.Equal(168, all.Count);
        Assert.DoesNotContain(all, i => i.Id is "nodate" or "future");
        var capped = AppModel.MagazineFillItems(items, now, 120);
        Assert.Equal(120, capped.Count);
        Assert.Equal("f0", capped[0].Id);
    }

    [Fact]
    public void ExistingKeysAndCount()
    {
        db.Upsert(It("e1", DateTimeOffset.Now), null);
        Assert.Equal(["geeknews|e1"], db.Existing(["geeknews|e1", "geeknews|e2"]));
        Assert.Equal(1, db.ArticleCount(DateTimeOffset.Now.AddHours(-1), DateTimeOffset.Now.AddHours(1)));
    }

    // 지난 호 목록: 이번 주 · 지난주 · 그 앞은 달별(접힘). 주간 호는 그 주 묶음 맨 위, 빈 날 수(맥과 같은 예)
    [Fact]
    public void ArchiveGroupsByWeekAndMonth()
    {
        var now = new DateTime(2026, 10, 22, 9, 0, 0);   // 목요일 · 이번 주 10-18(일)~
        var weekly = new Issue { Id = "weekly-x", Kind = IssueKind.Weekly, From = new DateTimeOffset(new DateTime(2026, 10, 11)), To = new DateTimeOffset(new DateTime(2026, 10, 18)), Count = 50 };
        var issues = Magazine.ArchiveOrder([Daily(new(2026, 10, 21)), Daily(new(2026, 10, 19)), weekly, Daily(new(2026, 10, 16)), Daily(new(2026, 10, 12)),
                                            Daily(new(2026, 9, 30), 2), Daily(new(2026, 9, 28))]);
        var g = Magazine.ArchiveGroups(issues, now);
        Assert.Equal(["이번 주", "지난주", "2026년 9월"], g.Select(x => x.Title));
        Assert.Equal(["daily-2026-10-21", "daily-2026-10-19"], g[0].Issues.Select(i => i.Id));
        Assert.Equal(2, g[0].EmptyDays);   // 18·20
        Assert.Equal("weekly-x", g[1].Issues[0].Id);
        Assert.Equal(5, g[1].EmptyDays);   // 11·13·14·15·17
        Assert.True(!g[0].Folded && !g[1].Folded && g[2].Folded);
        Assert.Equal(1, g[2].EmptyDays);   // 9-29
    }

    [Fact]
    public void ThinReasonAndLastCheck()
    {
        Assert.Contains("2건", Magazine.ThinReason(Daily(DateTime.Today, 2)));
        Assert.Null(Magazine.ThinReason(Daily(DateTime.Today, 40)));
        var now = DateTimeOffset.Now;
        Assert.Equal("아직 확인 전", Magazine.LastCheckText(null, now));
        Assert.Equal("마지막 확인 방금", Magazine.LastCheckText(now.AddSeconds(-20), now));
        Assert.Equal("마지막 확인 7분 전", Magazine.LastCheckText(now.AddMinutes(-7), now));
    }
}
