using System.Text.Json;
using System.Text.Json.Nodes;
using Dropcap.Ui;

namespace Dropcap.Core.Tests;

// 지난 기사 보관함: 정리(Prune)가 지우는 기사를 보관 표로 옮기기 · 보관 기간 상한 · 보관 검색 · 기간 목록(맥 ArchiveTests 와 같은 사례)
public class ArchiveTests : IDisposable
{
    private readonly TempDir tmp = new();
    private readonly Database db;

    public ArchiveTests() { db = new Database(System.IO.Path.Combine(tmp.Path, "magazine.sqlite")); }
    public void Dispose() { db.Dispose(); tmp.Dispose(); }

    private static NewsItem Item(string id, DateTimeOffset date, string? title = null, string source = "geeknews") => new()
    {
        Id = id, Title = title ?? $"기사 {id}", Link = $"https://{source}.example/{id}", Date = date, Summary = "요약",
        SourceId = source, SourceName = source + " 이름", Tier = "press",
    };

    private static DateTimeOffset Local(int y, int m, int d, int h = 0) => new(new DateTime(y, m, d, h, 0, 0, DateTimeKind.Local));

    // 정리가 지우는 오래된 기사는 보관 표로 옮겨지고(날짜·제목·링크·출처·분야), 최근 keep 건은 items 에 남는다
    [Fact]
    public void PruneMovesToArchive()
    {
        var now = DateTimeOffset.Now;
        for (var i = 0; i < 10; i++) db.Upsert(Item($"a{i}", now.AddHours(-i)), null);
        var moved = db.Prune(keep: 6, now: now, section: _ => "tech");
        Assert.Equal(4, moved);
        Assert.Equal(6, db.ItemCount);
        Assert.Equal(4, db.ArchiveCount);
        var old = db.Archived(now.AddDays(-1), now.AddMinutes(1));
        Assert.Equal(Enumerable.Range(6, 4).Select(i => $"https://geeknews.example/a{i}"), old.Select(a => a.Link));
        Assert.Equal("geeknews 이름", old[0].Source);
        Assert.Equal("tech", old[0].Section);
        Assert.True(Math.Abs((old[0].Date - now.AddHours(-6)).TotalSeconds) < 1);
        // 다시 정리해도 같은 기사를 두 번 넣지 않는다
        db.Upsert(Item("a9", now.AddHours(-9)), null);
        db.Prune(keep: 6, now: now, section: _ => "tech");
        Assert.Equal(4, db.ArchiveCount);
    }

    // 여러 곳이 다룬 스토리만 스토리 id 를 남긴다
    [Fact]
    public void PruneKeepsStoryOnlyForSharedStories()
    {
        var now = DateTimeOffset.Now;
        db.SaveCluster(new Database.Cluster("big", "큰 소식", new(), now, now, 2));
        db.SaveCluster(new Database.Cluster("one", "혼자", new(), now, now, 1));
        db.Upsert(Item("s1", now.AddHours(-3)), "big");
        db.Upsert(Item("s2", now.AddHours(-4)), "one");
        db.Upsert(Item("new", now), null);
        db.Prune(keep: 1, now: now, section: _ => "tech");
        var old = db.Archived(now.AddDays(-1), now);
        Assert.Equal("big", old.First(a => a.Link.EndsWith("s1")).Story);
        Assert.Null(old.First(a => a.Link.EndsWith("s2")).Story);
    }

    // 보관 기간: years 년 전이 든 달보다 이른 보관 기사는 지운다(달 단위), 0 이면 지우지 않는다
    [Fact]
    public void PruneCapsArchiveByMonths()
    {
        var now = Local(2026, 10, 19, 12);
        Assert.Equal(Local(2024, 10, 1), Archive.Cutoff(2, now));
        Assert.Null(Archive.Cutoff(0, now));
        db.Upsert(Item("o0", Local(2024, 9, 30, 9)), null);
        db.Upsert(Item("o1", Local(2024, 10, 1, 9)), null);
        db.Upsert(Item("o2", Local(2025, 10, 5, 9)), null);
        db.Upsert(Item("keep", now), null);
        db.Prune(keep: 1, archiveYears: 0, now: now, section: _ => "tech");
        Assert.Equal(3, db.ArchiveCount);
        db.Prune(keep: 1, archiveYears: 2, now: now, section: _ => "tech");
        Assert.Equal(2, db.ArchiveCount); // 2024년 9월은 지워짐, 10월 1일부터 남음
        Assert.DoesNotContain(db.SearchArchive("기사"), a => a.Link.EndsWith("o0"));
        db.Prune(keep: 1, archiveYears: 1, now: now, section: _ => "tech");
        Assert.Equal(1, db.ArchiveCount);
    }

    // 숨긴·꺼진 출처는 보관함 목록·날짜별 건수·거르기 메뉴·검색·최근 기사 어디에도 다시 나오지 않는다.
    // 출처 id 가 없는 예전 줄은 숨긴 출처의 이름으로 거른다
    [Fact]
    public void HiddenSourcesStayHidden()
    {
        var day = DateTime.Now.Date.AddDays(-3);
        for (var i = 0; i < 6; i++) db.Upsert(Item($"h{i}", new DateTimeOffset(day.AddHours(10 + i)), $"반도체 {i}", i % 2 == 0 ? "aa" : "bb"), null);
        db.Prune(keep: 2, section: _ => "tech");   // h0~h3 보관(aa 2 · bb 2), h4(aa)·h5(bb) 는 최근
        Assert.Equal(["aa", "bb"], db.Archived(new DateTimeOffset(day), new DateTimeOffset(day.AddDays(1))).Select(a => a.SourceId ?? "").Distinct().Order());
        LegacyRow(new DateTimeOffset(day.AddHours(9)), "반도체 예전", "bb 이름");

        var hide = new SourceFilter { Hidden = new HashSet<string> { "bb" }, HiddenNames = new HashSet<string> { "bb 이름" } };
        var reader = new ArchiveReader(db);
        DateTimeOffset from = new(day), to = new(day.AddDays(1));
        var all = reader.Period(from, to, null, null, 100);
        Assert.Equal(7, all.Total);
        var p = reader.Period(from, to, null, null, 100, hide);
        Assert.All(p.Items, a => Assert.Equal("aa 이름", a.Source));
        Assert.Equal(3, p.Total);
        Assert.Equal(3, p.DayCounts.Values.Sum());
        Assert.Equal(new Dictionary<string, int> { ["aa 이름"] = 3 }, p.Sources);
        Assert.Equal(3, p.Sections.Values.Sum());
        Assert.Equal(5, db.SearchArchive("반도체").Count);   // 보관 5건(예전 줄 포함)
        Assert.All(db.SearchArchive("반도체", filter: hide), a => Assert.Equal("aa", a.SourceId));
        Assert.Equal(2, db.SearchArchive("반도체", filter: hide).Count);
        // 켜진 출처 목록이 있으면 그 안만(예전 줄은 숨긴 이름이 아니면 남음)
        var onlyAa = new SourceFilter { Active = new HashSet<string> { "aa" } };
        Assert.Equal(["aa 이름", "aa 이름", "bb 이름"], db.SearchArchive("반도체", filter: onlyAa).Select(a => a.Source).Order());
        Assert.Equal(4, reader.Period(from, to, null, null, 100, onlyAa).Total);
    }

    // 예전 줄(출처 id 없음)을 바로 넣는다
    private void LegacyRow(DateTimeOffset when, string title, string source)
    {
        using var c = new Microsoft.Data.Sqlite.SqliteConnection($"Data Source={db.FilePath};Pooling=False");
        c.Open();
        using var cmd = c.CreateCommand();
        cmd.CommandText = "INSERT INTO archive(date,title,link,source,section) VALUES($d,$t,$l,$s,'tech')";
        cmd.Parameters.AddWithValue("$d", when.ToUnixTimeMilliseconds() / 1000.0);
        cmd.Parameters.AddWithValue("$t", title);
        cmd.Parameters.AddWithValue("$l", "https://legacy.example/" + Guid.NewGuid());
        cmd.Parameters.AddWithValue("$s", source);
        cmd.ExecuteNonQuery();
    }

    // 제목이 없는 줄은 옮기지 않고 남긴다(다른 줄은 그대로 옮김) — 30일이 지났거나 BrokenKeep 건을 넘으면 지운다
    [Fact]
    public void BadRowIsKept()
    {
        var now = DateTimeOffset.Now;
        db.Upsert(Item("bad", now.AddHours(-5), ""), null);
        db.Upsert(Item("stale", now.AddDays(-40), ""), null);
        for (var i = 0; i < 4; i++) db.Upsert(Item($"g{i}", now.AddHours(-i)), null);
        Assert.Equal(2, db.Prune(keep: 2, now: now, section: _ => "tech"));
        Assert.Equal(3, db.ItemCount);   // 최근 2 + 옮기지 못한 줄
        Assert.Equal(2, db.ArchiveCount);
        Assert.True(db.Exists("geeknews|bad"));
        Assert.False(db.Exists("geeknews|stale"));   // 30일 지남
    }

    [Fact]
    public void BadRowsAreCapped()
    {
        var now = DateTimeOffset.Now;
        for (var i = 0; i < Database.BrokenKeep + 2; i++) db.Upsert(Item($"b{i}", now.AddMinutes(-i - 1), ""), null);
        db.Upsert(Item("keep", now), null);
        db.Prune(keep: 1, now: now, section: _ => "tech");
        Assert.Equal(Database.BrokenKeep + 1, db.ItemCount);
        Assert.True(db.Exists("geeknews|b0"));
        Assert.False(db.Exists($"geeknews|b{Database.BrokenKeep + 1}"));   // 오래된 것부터
    }

    // 보관 기간과 관계없는 상한: 넘으면 가장 오래된 것부터 지워 꼭 상한만큼 남긴다
    [Fact]
    public void ArchiveCapsRows()
    {
        var now = DateTimeOffset.Now;
        for (var i = 0; i < 6; i++) db.Upsert(Item($"c{i}", now.AddDays(-i)), null);
        db.Prune(keep: 1, archiveYears: 0, now: now, section: _ => "tech", maxArchive: 10);
        Assert.Equal(5, db.ArchiveCount);
        // 옮긴 것이 없으면 상한 질의를 건너뛴다(줄 수가 늘지 않았다)
        db.Prune(keep: 1, archiveYears: 0, now: now, section: _ => "tech", maxArchive: 3);
        Assert.Equal(5, db.ArchiveCount);
        db.Upsert(Item("next", now.AddMinutes(1)), null);
        db.Prune(keep: 1, archiveYears: 0, now: now, section: _ => "tech", maxArchive: 3);
        Assert.Equal(3, db.ArchiveCount);
        Assert.Equal(["c0", "c1", "c2"], db.Archived(now.AddDays(-30), now.AddDays(1)).Select(a => a.Link[(a.Link.LastIndexOf('/') + 1)..]));
    }

    // 먼저 만든 판의 보관 표(출처 id 칸 없음)는 칸만 더하고 줄은 그대로
    [Fact]
    public void OldArchiveTableGetsSourceId()
    {
        var file = System.IO.Path.Combine(tmp.Path, "old.sqlite");
        using (var c = new Microsoft.Data.Sqlite.SqliteConnection($"Data Source={file};Pooling=False"))
        {
            c.Open();
            using var cmd = c.CreateCommand();
            cmd.CommandText = """
                CREATE TABLE archive(date REAL NOT NULL, title TEXT NOT NULL, title_ko TEXT, link TEXT NOT NULL, source TEXT, section TEXT, story TEXT);
                CREATE INDEX archive_date ON archive(date, section, source);
                INSERT INTO archive(date,title,link,source,section) VALUES(1000,'예전','https://x.example/1','X','tech');
                """;
            cmd.ExecuteNonQuery();
        }
        using var old = new Database(file);
        var a = Assert.Single(old.SearchArchive("예전"));
        Assert.Null(a.SourceId);
        Assert.Equal("X", a.Source);
        using var again = new Database(file);   // 두 번 열어도 그대로
        Assert.Single(again.SearchArchive("예전"));
    }

    // 옮기다 실패하면 아무것도 지우지 않는다(한 트랜잭션)
    [Fact]
    public void PruneRollsBackOnFailure()
    {
        var now = DateTimeOffset.Now;
        for (var i = 0; i < 5; i++) db.Upsert(Item($"f{i}", now.AddHours(-i)), null);
        var n = 0;
        Assert.Equal(0, db.Prune(keep: 2, now: now, section: _ => ++n == 2 ? throw new InvalidOperationException("시험") : "tech"));
        Assert.Equal(5, db.ItemCount);
        Assert.Equal(0, db.ArchiveCount);
        // 그 뒤 정리는 그대로 된다(트랜잭션이 남아 있지 않음)
        Assert.Equal(3, db.Prune(keep: 2, now: now, section: _ => "tech"));
        Assert.Equal(2, db.ItemCount);
    }

    // 보관 검색: 제목·출처 LIKE, 최신순, 더 보기(offset), % _ 는 글자 그대로
    [Fact]
    public void SearchArchive()
    {
        var now = DateTimeOffset.Now;
        for (var i = 0; i < 5; i++) db.Upsert(Item($"q{i}", now.AddDays(-i - 1), $"엔비디아 실적 {i}"), null);
        db.Upsert(Item("pct", now.AddDays(-10), "금리 50% 인상"), null);
        db.Upsert(Item("keep", now), null);
        db.Prune(keep: 1, now: now, section: _ => "economy");
        Assert.Equal(["엔비디아 실적 0", "엔비디아 실적 1", "엔비디아 실적 2"], db.SearchArchive("엔비디아", 3).Select(a => a.Title));
        Assert.Equal(2, db.SearchArchive("엔비디아", 3, 3).Count);
        Assert.Equal(["금리 50% 인상"], db.SearchArchive("50%").Select(a => a.Title));
        Assert.Empty(db.SearchArchive("5_%"));
        Assert.Equal(6, db.SearchArchive("geeknews 이름").Count);
    }

    // 기간 목록: 최근 기사(items)와 보관 기사를 합쳐 최신순, 분야·출처 거르기, 날짜별 건수, 더 보기
    [Fact]
    public void ArchivePeriodMergesRecentAndArchived()
    {
        var day = DateTime.Now.Date.AddDays(-3);
        for (var i = 0; i < 6; i++) db.Upsert(Item($"p{i}", new DateTimeOffset(day.AddHours(10 + i)), source: i % 2 == 0 ? "aa" : "bb"), null);
        db.Prune(keep: 3, section: it => it.SourceId == "aa" ? "tech" : "economy"); // p0~p2 는 보관 표로
        Assert.Equal(3, db.ArchiveCount);
        var reader = new ArchiveReader(db);
        var (from, to) = Archive.Range(Archive.Period.Day, day);
        var all = reader.Period(new DateTimeOffset(from), new DateTimeOffset(to), null, null, 100);
        Assert.Equal(Enumerable.Range(0, 6).Reverse().Select(i => $"https://{(i % 2 == 0 ? "aa" : "bb")}.example/p{i}"), all.Items.Select(a => a.Link));
        Assert.Equal(6, all.Total);
        Assert.False(all.More);
        Assert.Equal(new Dictionary<string, int> { [Archive.DayKey(day)] = 6 }, all.DayCounts);
        Assert.Equal(new Dictionary<string, int> { ["aa 이름"] = 3, ["bb 이름"] = 3 }, all.Sources);
        var some = reader.Period(new DateTimeOffset(from), new DateTimeOffset(to), null, "aa 이름", 2);
        Assert.Equal(["https://aa.example/p4", "https://aa.example/p2"], some.Items.Select(a => a.Link));
        Assert.True(some.More);
        Assert.Equal(3, some.Total);
        var month = Archive.Range(Archive.Period.Month, day);
        Assert.Equal(6, reader.Period(new DateTimeOffset(month.From), new DateTimeOffset(month.To), null, null, 100).Total);
        // 보관된 기사의 분야로 거름(보관 표의 분야 칸)
        Assert.Equal(["https://aa.example/p2", "https://aa.example/p0"],
            reader.Period(new DateTimeOffset(from), new DateTimeOffset(to), "tech", null, 100).Items.Select(a => a.Link));
        Assert.Equal((DateTimeOffset?)db.Archived(new DateTimeOffset(from), new DateTimeOffset(to)).Min(a => a.Date), db.EarliestRecord());
    }

    // 같은 링크는 한 번(최근 기사끼리 겹친 것도) — 목록 줄 id 가 겹쳐 빈 줄이 생기지 않게
    [Fact]
    public void MergeDedupesLinks()
    {
        var d = DateTimeOffset.Now;
        ArchivedItem A(string link, double s) => new(d.AddSeconds(s), link, null, link, "x", "tech");
        var m = Archive.Merge([A("l1", 0), A("l1", 0), A("l2", -10)], [A("l2", -20), A("l3", -30)]);
        Assert.Equal(["l1", "l2", "l3"], m.Select(a => a.Link));
        Assert.Equal(m.Count, m.Select(a => a.Id).Distinct().Count());
    }

    // 기간 계산: ◀ ▶ 로 한 기간씩, 일·주·월·연 경계
    [Fact]
    public void Periods()
    {
        var d = new DateTime(2026, 3, 15, 13, 0, 0);
        var m = Archive.Range(Archive.Period.Month, d);
        Assert.Equal(new DateTime(2026, 3, 1), m.From);
        Assert.Equal(new DateTime(2026, 4, 1), m.To);
        Assert.Equal(new DateTime(2025, 1, 1), Archive.Range(Archive.Period.Year, Archive.Shift(Archive.Period.Year, d, -1)).From);
        Assert.Equal(new DateTime(2026, 3, 16), Archive.Range(Archive.Period.Day, Archive.Shift(Archive.Period.Day, d, 1)).From);
        Assert.Equal(new DateTime(2026, 3, 22), Archive.Range(Archive.Period.Week, Archive.Shift(Archive.Period.Week, d, 1)).From); // 일요일부터
        Assert.Equal("2026년 3월", Archive.Title(Archive.Period.Month, d));
        Assert.Equal("2026년 3월 15일(일)", Archive.Title(Archive.Period.Day, d));
        Assert.Equal("2026년 3월 15일 – 3월 21일", Archive.Title(Archive.Period.Week, d));
        Assert.Equal("2026년", Archive.Title(Archive.Period.Year, d));
        Assert.Equal(31, Archive.Days(m.From, m.To).Count);
        Assert.Equal("2026-03-15", Archive.DayKey(d));
        Assert.Equal(Archive.Period.Month, Archive.ParsePeriod("모름"));
        Assert.Equal("day", Archive.ParsePeriod("day").Raw());
    }

    // 보관 기간 설정: 예전 상태 파일엔 없음 → 2년, 모르는 값도 2년, 저장 키는 맥·리눅스와 같은 archiveYears
    [Fact]
    public void SettingsArchiveYears()
    {
        Assert.Equal(2, StateSettings.FromJson(new JsonObject()).ArchiveYears);
        Assert.Equal(2, StateSettings.FromJson(new JsonObject { ["archiveYears"] = 3 }).ArchiveYears);
        Assert.Equal(0, StateSettings.FromJson(new JsonObject { ["archiveYears"] = 0 }).ArchiveYears);
        var st = new AppState();
        st.Settings.ArchiveYears = 5;
        Assert.Equal(5, (int)JsonNode.Parse(st.ToJson())!["settings"]!["archiveYears"]!);
        Assert.Equal(5, AppState.FromJson(st.ToJson()).Settings.ArchiveYears);
    }

    // 대표 분야만 고르는 빠른 길은 Place 의 대표와 같다
    [Fact]
    public void PrimaryMatchesPlace()
    {
        foreach (var it in new[]
        {
            Item("x1", DateTimeOffset.Now, "코스피 급등, 금리 동결"), Item("x2", DateTimeOffset.Now, "OpenAI releases new model", "openai"),
            Item("x3", DateTimeOffset.Now, "아무 낱말 없는 글"),
        })
            Assert.Equal(Sections.Place(it).Primary, Sections.Primary(it));
    }
}

// 매거진 창의 보관함 지면·오래된 기사 검색(MagazinePage)
public class ArchivePageTests : IDisposable
{
    private sealed class ReaderPlatform : IPlatform
    {
        public List<NewsItem> Readers { get; } = new();
        public void OpenMagazine(string? page = null) { }
        public void OpenSettings(string? tab = null) { }
        public void OpenOnboarding() { }
        public void OpenReader(NewsItem item) => Readers.Add(item);
        public void CloseWindow(string page) { }
        public void Quit() { }
        public void CopyText(string text) { }
        public Task<bool> SaveTextFile(string suggestedName, string text) => Task.FromResult(false);
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
    private readonly ReaderPlatform platform = new();
    private readonly MagazinePage page;

    public ArchivePageTests()
    {
        db = new Database(System.IO.Path.Combine(tmp.Path, "magazine.sqlite"));
        mag = new Magazine(db);
        model = new AppModel(new FakeUi(), mag, new AppState(), persist: false) { ShowAllSourcesForTests = true };
        page = new MagazinePage(model, mag, new Scrapbook(db), platform, new Bridge()) { LoadPhotos = _ => { }, PhotoUrl = _ => null };
    }

    public void Dispose() { model.Stop(); db.Dispose(); tmp.Dispose(); }

    private static JsonNode J(object? o) => JsonSerializer.SerializeToNode(o, Json.Options)!;
    private async Task<JsonNode> Run(string cmd, object args) => J(await page.Handle(cmd, (JsonObject)J(args)));

    private static NewsItem Item(string id, DateTimeOffset date, string title) => new()
    {
        Id = id, Title = title, Link = "https://old.example/" + id, Date = date, Summary = "", SourceId = "yna", SourceName = "연합뉴스", Tier = "kr",
    };

    // 월 보기: 막대(그달 날 수) · 최신순 목록 · 거르기 메뉴, 일 보기: 그날 호가 있으면 '이 날의 호 보기'. 줄을 누르면 읽기 창
    [Fact]
    public async Task ArchiveMonthAndDay()
    {
        var day = DateTime.Now.Date.AddDays(-40);
        for (var i = 0; i < 3; i++) db.Upsert(Item($"m{i}", new DateTimeOffset(day.AddHours(9 + i)), $"금리 동결 {i}"), null);
        db.Upsert(Item("now", DateTimeOffset.Now, "오늘 기사"), null);
        db.Prune(keep: 1, section: _ => "economy");

        var v = await Run("archive", new { period = "month", anchor = Archive.DayKey(day) });
        Assert.Equal("month", (string)v["period"]!);
        Assert.Equal(DateTime.DaysInMonth(day.Year, day.Month), v["bars"]!.AsArray().Count);
        Assert.Equal(3, v["bars"]!.AsArray().First(b => (string)b!["key"]! == Archive.DayKey(day))!["count"]!.GetValue<int>());
        Assert.Equal(["금리 동결 2", "금리 동결 1", "금리 동결 0"], v["items"]!.AsArray().Select(r => (string)r!["title"]!));
        Assert.Equal("기사 3건", (string)v["head"]!);
        Assert.Equal("경제", (string)v["sections"]![0]!["label"]!);
        Assert.True((bool)v["canNext"]!);
        Assert.False((bool)v["atToday"]!);
        Assert.Equal("month", Prefs.Get<string?>(MagazinePage.ArchivePeriodKey, null));

        // 일 보기에는 막대 없이 시각만, 그날 호가 있으면 그 호로 가는 단추
        db.SaveIssue(new Issue { Id = "daily-" + Magazine.DayId(day), Kind = IssueKind.Daily, From = new DateTimeOffset(day.AddHours(-6)), To = new DateTimeOffset(day.AddHours(18)), Count = 3 });
        mag.PublishDue();
        var d = await Run("archive", new { period = "day", anchor = Archive.DayKey(day) });
        Assert.Null(d["bars"]);
        Assert.Equal("daily-" + Magazine.DayId(day), (string)d["dayIssue"]!["id"]!);
        Assert.Matches(@"^\d\d:\d\d$", (string)d["items"]![0]!["when"]!);

        // 줄을 누르면 읽기 창(본문은 링크에서 다시)
        await Run("open", new { key = (string)d["items"]![0]!["key"]! });
        Assert.Equal("https://old.example/m2", Assert.Single(platform.Readers).Link);

        // 거른 조건에 맞는 것이 없으면 안내
        var none = await Run("archive", new { period = "day", anchor = Archive.DayKey(day), source = "없는 출처" });
        Assert.Equal("거른 조건에 맞는 기사가 없습니다.", (string)none["empty"]!);
        Assert.Equal(Archive.DayKey(day.AddDays(1)), (string)(await Run("archiveShift", new { period = "day", anchor = Archive.DayKey(day), by = 1 }))!);
    }

    // 날짜 끝값(0001년 ◀ · 9999년 연 보기)은 범위 안으로 묶고, 보관 기사는 '브라우저에서 열기'로도 읽음 기록에 넣지 않는다.
    // 화면에 보낸 줄 묶음에서 밀려난 key 도 링크로 연다
    [Fact]
    public async Task ArchiveEdgesAndRead()
    {
        Assert.Equal("1971-01-01", (string)(await Run("archiveShift", new { period = "year", anchor = "0001-01-01", by = -1 }))!);
        Assert.Equal("9998", ((string)(await Run("archive", new { period = "year", anchor = "9999-12-31" }))["anchor"]!)[..4]);
        var key = ArchivedItem.ReaderSource + "|https://old.example/gone";
        await Run("browser", new { key, read = true });
        Assert.False(model.IsRead(new NewsItem { Id = "https://old.example/gone", Title = "", Link = "https://old.example/gone", SourceId = ArchivedItem.ReaderSource, SourceName = "", Summary = "", Tier = "" }));
        await Run("open", new { key });
        Assert.Equal("https://old.example/gone", Assert.Single(platform.Readers).Link);
    }

    // 검색: '오래된 기사 포함'(기본 켜짐)이면 보관 표에서도 찾고, 최근 결과와 같은 링크는 뺀다. 끄면 기억하고 찾지 않는다
    [Fact]
    public async Task SearchIncludesOlder()
    {
        var now = DateTimeOffset.Now;
        db.Upsert(Item("o1", now.AddDays(-30), "엔비디아 실적"), null);
        db.Upsert(Item("o2", now.AddDays(-31), "엔비디아 신제품"), null);
        db.Upsert(Item("r1", now, "엔비디아 오늘"), null);
        db.Prune(keep: 1, section: _ => "tech");
        var r = await Run("search", new { q = "엔비디아", submit = false });
        Assert.True((bool)r["archive"]!);
        Assert.Single(r["items"]!.AsArray());
        Assert.Equal(["엔비디아 실적", "엔비디아 신제품"], r["older"]!.AsArray().Select(x => (string)x!["title"]!));
        Assert.Equal("최근 1건 · 오래된 기사 2건", (string)r["found"]!);
        Assert.False((bool)r["olderMore"]!);

        var off = await Run("search", new { q = "엔비디아", submit = false, archive = false });
        Assert.False((bool)off["archive"]!);
        Assert.Empty(off["older"]!.AsArray());
        Assert.Equal("1건", (string)off["found"]!);
        Assert.False(MagazinePage.IncludeArchive);
    }

    // 지면 넘기기: 보관함은 지난 호 다음(맨 끝)
    [Fact]
    public void ArchiveIsLastPage()
    {
        var order = MagazinePage.PageOrder(["economy"], ["daily-2026-10-12"]);
        Assert.Equal("archive", order[^1]);
        Assert.Equal("archive", MagazinePage.Flip("issue:daily-2026-10-12", 1, order));
    }
}
