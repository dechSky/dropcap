using System.Text.RegularExpressions;
using Dropcap.Core;

namespace Dropcap.Core.Tests;

// 맥 시나리오 시험에서 찾은 버그를 고친 것(e2e-fix, 맥 E2EScenarioTests.swift 의 E2EFixTests·lessOf 시험을 옮김)
// G-02 강한 낱말 칩 · G-05/G-08 덜 받기 · M-17 스크랩 사본·건지기 · N-05 칩 안 줄어듦(그림이라 여기선 안 봄)
public class E2EFixTests : IDisposable
{
    private readonly TempDir tmp = new();
    public void Dispose() => tmp.Dispose();

    private static readonly PolicyLimits L = new();
    private static readonly Regex Ai = new(@"\b(AI|LLM|GPT)\b|인공지능|생성형", RegexOptions.IgnoreCase);
    private static readonly Dictionary<string, SourceMeta> Meta = new()
    {
        ["yna-politics"] = new("yna-politics", Section: "politics", Region: "kr"),
    };

    private static Scrap S(string id, string c = "모음") => new()
    {
        Id = id, Collection = c, Memo = "메모",
        Item = new NewsItem { Id = id, Title = "제목 " + id, Link = "https://a.example/" + id, Date = DateTimeOffset.Now, SourceId = "s", SourceName = "s", Tier = "kr" },
    };

    private static NotifyPolicy.Input In(NotifyMode mode, int kr = 0, int intl = 0, bool less = false) => new()
    {
        Chosen = true, Policy = new SectionPolicy { Mode = mode, Less = less }, Coverage = new Coverage(kr, intl),
    };

    // 11단계: '이 분야 덜 받기'를 누른 분야는 주요 뉴스 흐름으로도 떨어지지 않고 묶음으로 고인다(결정됨)
    [Fact]
    public void LessOfStaysOutOfTopFlow()
    {
        var top = In(NotifyMode.Instant);
        Assert.Equal((NotifyDecision.Pool, false), NotifyPolicy.DecideWithTop(In(NotifyMode.Bundle, intl: 2, less: true), top, L));
        // 국내 8곳짜리 큰 소식도 덜 받기 분야면 묶음으로
        Assert.Equal(NotifyDecision.Pool, NotifyPolicy.DecideWithTop(In(NotifyMode.Bundle, kr: 8, intl: 2, less: true), top, L).Decision);
        // 그냥 묶음 분야(덜 받기 아님)는 예전처럼 주요 뉴스 흐름이 받는다
        Assert.Equal((NotifyDecision.Drop, true), NotifyPolicy.DecideWithTop(In(NotifyMode.Bundle, intl: 2), top, L));
    }

    [Fact]
    public void LessFlagSurvivesOldAndNewFiles()
    {
        var old = SectionPolicy.FromJson(System.Text.Json.Nodes.JsonNode.Parse("""{"mode":"bundle","bundleHour":18,"dailyCap":3}"""));
        Assert.False(old.Less);
        var s = new AppState();
        s.SectionPolicy["world"] = new SectionPolicy { Mode = NotifyMode.Bundle, Less = true };
        Assert.True(AppState.FromJson(s.ToJson()).SectionPolicy["world"].Less);
    }

    [Fact]
    public void LessOfSetsFlagAndInstantClearsIt()
    {
        using var db = new Database(Path.Combine(tmp.Path, "magazine.sqlite"));
        var ui = new FakeUi();
        var model = new AppModel(ui, new Magazine(db), new AppState(), persist: false);
        model.SetPolicy("world", p => p with { Mode = NotifyMode.Instant });
        model.LessOf("world");
        Assert.Equal(NotifyMode.Bundle, model.Policy("world").Mode);
        Assert.True(model.Policy("world").Less);
        Assert.Equal("이 분야는 저녁 묶음으로 모아 드릴게요", ui.Infos.Last());
        model.LessOf("world");                                   // 묶음에서 한 번 더 → 매거진만
        Assert.Equal(NotifyMode.Magazine, model.Policy("world").Mode);
        Assert.Equal("이 분야는 매거진에만 실을게요", ui.Infos.Last());
        model.SetPolicy("world", p => p with { BundleHour = 17 }); // 다른 값을 바꿔도 그대로
        Assert.True(model.Policy("world").Less);
        model.SetPolicy("world", p => p with { Mode = NotifyMode.Instant }); // 설정에서 즉시로 되돌리면 풀림
        Assert.False(model.Policy("world").Less);
    }

    // 1) 스크랩 사본: 원자적으로 쓰고 그대로 읽힘, DB 에 없는 것만 되살림
    [Fact]
    public void ScrapCopyRoundTripAndRestoreList()
    {
        var f = Path.Combine(tmp.Path, "scraps.json");
        var list = new List<Scrap> { S("a"), S("b", "다른 모음") };
        Scrapbook.WriteCopy(list, f);
        var back = Scrapbook.ReadCopy(f)!;
        Assert.Equal(["a", "b"], back.Select(s => s.Id));
        Assert.Equal(["모음", "다른 모음"], back.Select(s => s.Collection));
        Assert.Equal(["b"], Scrapbook.RestoreList([S("a")], list).Select(s => s.Id));
        Assert.Null(Scrapbook.ReadCopy(Path.Combine(tmp.Path, "none.json")));
    }

    // 1) 깨져서 새로 만든 DB 는 치운 파일의 스크랩을 읽히는 만큼 옮겨 온다
    [Fact]
    public void SalvageScrapsFromOtherFile()
    {
        using (var old = new Database(Path.Combine(tmp.Path, "old.sqlite"))) { old.SaveScrap(S("x")); old.SaveScrap(S("y", "폴더")); }
        using var fresh = new Database(Path.Combine(tmp.Path, "new.sqlite"));
        Assert.Equal(2, fresh.ImportScraps(Path.Combine(tmp.Path, "old.sqlite")));
        Assert.Equal(new HashSet<string> { "x", "y" }, fresh.Scraps().Select(s => s.Id).ToHashSet());
        Assert.Equal(0, fresh.ImportScraps(Path.Combine(tmp.Path, "missing.sqlite")));
    }

    // 1) 통째로 깨진 파일: 새로 만들었다고 표시(사본에서 되살릴 조건)
    [Fact]
    public void CorruptDBIsMarkedRecreated()
    {
        var f = Path.Combine(tmp.Path, "magazine.sqlite");
        File.WriteAllBytes(f, Enumerable.Repeat((byte)0x5A, 8192).ToArray());
        using (var db = new Database(f))
        {
            Assert.True(db.Recreated);
            Assert.Equal(0, db.SalvagedScraps);
        }
        using var ok = new Database(Path.Combine(tmp.Path, "ok.sqlite"));
        Assert.False(ok.Recreated);
    }

    // 12-다: DB 가 깨져도 스크랩은 사본에서 돌아오고, 평소에 다 지운 것은 되살리지 않는다
    [Fact]
    public void ScrapsComeBackAfterCorruptDB()
    {
        var f = Path.Combine(tmp.Path, "magazine.sqlite");
        using (var db = new Database(f))
        {
            var book = new Scrapbook(db);
            book.Add(S("a").Item, memo: "하나");
            book.Add(S("b").Item, quote: "문단");
            Assert.Equal(2, Scrapbook.ReadCopy(Scrapbook.CopyFile(tmp.Path))!.Count);
        }
        Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools();
        foreach (var ext in new[] { "-wal", "-shm" }) File.Delete(f + ext);
        File.WriteAllBytes(f, Enumerable.Repeat((byte)0x5A, 8192).ToArray());
        using (var db = new Database(f))
        {
            Assert.True(db.Recreated);
            var book = new Scrapbook(db);
            Assert.Equal(2, book.Scraps.Count);
        }
        // 다음 실행: 사용자가 다 지우면 사본도 비고, 다시 열어도 되살리지 않는다
        using (var db = new Database(f))
        {
            Assert.False(db.Recreated);
            var book = new Scrapbook(db);
            Assert.Equal(2, book.Scraps.Count);
            foreach (var s in book.Scraps.ToList()) book.Remove(s);
            Assert.Empty(Scrapbook.ReadCopy(Scrapbook.CopyFile(tmp.Path))!);
            Assert.Empty(new Scrapbook(db).Scraps);
        }
    }

    [Fact]
    public void CopyOffSkipsCopy()
    {
        Prefs.Set("scrapsCopyOff", true);
        using var db = new Database(Path.Combine(tmp.Path, "magazine.sqlite"));
        new Scrapbook(db).Add(S("a").Item);
        Assert.False(File.Exists(Scrapbook.CopyFile(tmp.Path)));
    }

    // 4) 출처 분야(정치)와 달리 경제 낱말이 강하게 걸리면 경제 칩을 더하고, 알림 분야는 고른 분야 칩을 먼저 쓴다
    [Fact]
    public void StrongKeywordChip()
    {
        var it = new NewsItem { Id = "p1", Title = "한국은행 기준금리 인하 결정 가계대출 부담 사흘째", Link = "https://a.example/p1", Date = DateTimeOffset.Now,
                                SourceId = "yna-politics", SourceName = "연합뉴스 정치", Tier = "kr" };
        var p = Sections.Place(it, Meta, Ai);
        Assert.Equal("politics", p.Primary);
        Assert.Equal("economy", p.Strong);
        Assert.Contains("economy", p.Chips);
        // 낱말 하나만 걸리면 강한 칩 아님
        var weak = it with { Id = "p2", Title = "국회 본회의 일정 합의 금리" };
        Assert.Null(Sections.Place(weak, Meta, Ai).Strong);
    }

    [Fact]
    public void NotifySectionPrefersChosenChip()
    {
        Sections.Use(null, Meta);
        try
        {
            var it = new NewsItem { Id = "p1", Title = "한국은행 기준금리 인하 결정 가계대출 부담 사흘째", Link = "https://a.example/p1", Date = DateTimeOffset.Now,
                                    SourceId = "yna-politics", SourceName = "연합뉴스 정치", Tier = "kr" };
            Assert.Equal("economy", it.ExtraTopic());
            Assert.Equal("economy", AppModel.NotifySection(it, ["top", "economy", "world", "ai"]));
            Assert.Equal("politics", AppModel.NotifySection(it, ["politics", "economy"])); // 둘 다 고르면 대표 분야
        }
        finally { Sections.Use(null, null); }
    }
}
