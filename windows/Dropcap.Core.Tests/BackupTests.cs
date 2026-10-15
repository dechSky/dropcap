using System.Text.Json.Nodes;
using Dropcap.Core;

namespace Dropcap.Core.Tests;

// 내 기록 내보내기·가져오기(P-08 · D-14). 맥 Extras2Tests 의 BackupTests 와 같은 경우 + 맥에서 만든 파일과 글자까지 같은지.
public class BackupTests : IDisposable
{
    private readonly TempDir tmp = new();
    private static readonly DateTimeOffset T = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);

    public void Dispose() { Backup.Now = () => DateTimeOffset.Now; tmp.Dispose(); }

    // 맥 JSONEncoder(.iso8601, .prettyPrinted, .sortedKeys)가 아래 home 과 같은 기록(+ 저장 2에 선택 항목 몇 개)을 쓴 모양 그대로
    private const string MacSample = """
        {
          "app" : "mac",
          "customSources" : [
            {
              "aiOnly" : false,
              "color" : "#000",
              "defaultOn" : true,
              "id" : "custom-a",
              "name" : "custom-a",
              "tier" : "press",
              "type" : "feed",
              "url" : "https:\/\/custom-a.example\/feed"
            }
          ],
          "enabled" : {
            "nyt" : false,
            "verge" : true
          },
          "exported" : "2027-01-15T08:00:00Z",
          "followedStories" : [
            "story-1"
          ],
          "format" : "dropcap-backup",
          "hiddenSources" : [
            "spam"
          ],
          "notify" : {
            "verge" : false
          },
          "saved" : [
            {
              "date" : "2027-01-15T08:00:00Z",
              "id" : "1",
              "link" : "https:\/\/a.example\/1",
              "sourceId" : "s",
              "sourceName" : "S",
              "summary" : "",
              "tier" : "press",
              "title" : "T1"
            },
            {
              "date" : "2027-01-15T08:00:00Z",
              "id" : "2",
              "important" : true,
              "kind" : "video",
              "link" : "https:\/\/a.example\/2",
              "related" : [
                "b"
              ],
              "sourceId" : "s",
              "sourceName" : "S",
              "summary" : "",
              "tier" : "press",
              "title" : "T2",
              "titleKo" : "제목 2",
              "watch" : "삼성전자"
            }
          ],
          "scrapFolders" : [
            "스크랩",
            "보고서",
            "빈 폴더"
          ],
          "scraps" : [
            {
              "collection" : "보고서",
              "created" : "2027-01-15T08:00:00Z",
              "id" : "sc1",
              "item" : {
                "date" : "2027-01-15T08:00:00Z",
                "id" : "1",
                "link" : "https:\/\/a.example\/1",
                "sourceId" : "s",
                "sourceName" : "S",
                "summary" : "",
                "tier" : "press",
                "title" : "T1"
              },
              "memo" : "메모",
              "quote" : "문단"
            }
          ],
          "sectionPolicy" : {
            "economy" : {
              "bundleHour" : 17,
              "dailyCap" : 3,
              "less" : false,
              "mode" : "bundle"
            }
          },
          "sectionsChosen" : [
            "ai",
            "economy"
          ],
          "settings" : {
            "autoQuietCalendar" : false,
            "autoQuietFullscreen" : true,
            "autoQuietSharing" : true,
            "bigThreshold" : 8,
            "digestEnabled" : true,
            "digestHour" : 7,
            "intervalMinutes" : 5,
            "intlThreshold" : 2,
            "krThreshold" : 3,
            "mustKeywords" : [
              "GPT-6"
            ],
            "muteKeywords" : [

            ],
            "position" : "center",
            "quietEnabled" : false,
            "quietEnd" : 7,
            "quietStart" : 23,
            "sound" : true,
            "style" : "drop",
            "totalDailyCap" : 10,
            "translateEngine" : "auto",
            "watchKeywords" : [
              "삼성전자"
            ]
          },
          "version" : 1
        }
        """;

    private static NewsItem News(string id) => new()
    {
        Id = id, Title = $"T{id}", Link = $"https://a.example/{id}", Date = T, Summary = "", SourceId = "s", SourceName = "S", Tier = "press",
    };

    private static Source Src(string id, string? url = null) => new()
    {
        Id = id, Name = id, Tier = "press", Type = "feed", Url = url ?? $"https://{id}.example/feed", AiOnly = false, DefaultOn = true, Color = "#000",
    };

    private static (AppState, List<Scrap>) Home()
    {
        var s = new AppState();
        s.Settings.DigestHour = 7;
        s.Settings.MustKeywords = ["GPT-6"];
        s.Settings.WatchKeywords = ["삼성전자"];
        s.SectionsChosen = ["ai", "economy"];
        s.SectionPolicy = new() { ["economy"] = new SectionPolicy { Mode = NotifyMode.Bundle, BundleHour = 17 } };
        s.Enabled = new() { ["verge"] = true, ["nyt"] = false };
        s.Notify = new() { ["verge"] = false };
        s.CustomSources = [Src("custom-a")];
        s.HiddenSources = ["spam"];
        s.FollowedStories = ["story-1"];
        s.Saved = [News("1"), News("2") with { TitleKo = "제목 2", Related = ["b"], Important = true, Watch = "삼성전자", Kind = "video" }];
        var scraps = new List<Scrap> { new() { Id = "sc1", Item = News("1"), Quote = "문단", Memo = "메모", Collection = "보고서", Created = T } };
        return (s, scraps);
    }

    [Fact]
    public void WritesExactlyWhatTheMacWrites()
    {
        var (s, scraps) = Home();
        var b = Backup.Make(s, scraps, ["스크랩", "보고서", "빈 폴더"], T);
        b.App = "mac";
        Assert.Equal(MacSample, Backup.Encode(b));                           // 글자 하나까지 같음
        Assert.Equal(MacSample, Backup.Encode(Backup.Decode(MacSample)));    // 맥 파일을 읽어 다시 써도 그대로
    }

    [Fact]
    public void ReadsMacFile()
    {
        var b = Backup.Decode(MacSample);
        Assert.Equal("mac", b.App);
        Assert.Equal(T, b.Exported);
        Assert.Equal(7, b.Settings.DigestHour);
        Assert.Equal(["삼성전자"], b.Settings.WatchKeywords);
        Assert.Equal(["ai", "economy"], b.SectionsChosen!);
        Assert.Equal(17, b.SectionPolicy["economy"].BundleHour);
        Assert.Equal("https://custom-a.example/feed", b.CustomSources[0].Url);   // "\/" 도 읽힘
        Assert.Equal(T, b.Saved[1].Date);
        Assert.True(b.Saved[1].Important);
        Assert.Equal(ItemKind.Video, b.Saved[1].ItemKind);
        Assert.Equal("문단", b.Scraps[0].Quote);
        Assert.Null(b.Scraps[0].QuoteOriginal);
        Assert.Equal(T, b.Scraps[0].Created);
        Assert.Equal(["스크랩", "보고서", "빈 폴더"], b.ScrapFolders);
    }

    [Fact]
    public void TopLevelShapeMatchesMac()
    {
        var (s, scraps) = Home();
        var json = Backup.Encode(Backup.Make(s, scraps, ["스크랩"], T));
        var o = (JsonObject)JsonNode.Parse(json)!;
        string[] mac = ["app", "customSources", "enabled", "exported", "followedStories", "format", "hiddenSources", "notify",
            "saved", "scrapFolders", "scraps", "sectionPolicy", "sectionsChosen", "settings", "version"];
        Assert.Equal(mac, o.Select(p => p.Key).ToArray());                   // 맥처럼 글자 순
        Assert.Equal("dropcap-backup", (string)o["format"]!);
        Assert.Equal(1, (int)o["version"]!);
        Assert.Equal("windows", (string)o["app"]!);
        Assert.Equal("2027-01-15T08:00:00Z", (string)o["exported"]!);
        Assert.Equal("drop", (string)o["settings"]!["style"]!);
        Assert.Equal("bundle", (string)o["sectionPolicy"]!["economy"]!["mode"]!);
        Assert.DoesNotContain("\"read\"", json);                              // 읽음 기록·본 글 기억은 담지 않음
        Assert.DoesNotContain("\"seen\"", json);
        Assert.DoesNotContain("sectionsChosen", Backup.Encode(Backup.Make(new AppState(), [], [], T))); // 고르지 않았으면 맥처럼 빠짐
    }

    [Fact]
    public void RejectsOtherFilesAndFillsMissing()
    {
        var e = Assert.Throws<BackupException>(() => Backup.Decode("""{"hello":1}"""));
        Assert.Equal("Dropcap 기록 파일이 아닙니다", e.Message);
        Assert.Throws<BackupException>(() => Backup.Decode("not json"));
        Assert.Throws<BackupException>(() => Backup.Decode("[]"));
        var newer = Assert.Throws<BackupException>(() => Backup.Decode("""{"format":"dropcap-backup","version":99}"""));
        Assert.Equal("더 새 판 Dropcap 이 만든 기록입니다(형식 99). 앱을 업데이트한 뒤 가져오세요", newer.Message);
        var partial = Backup.Decode("""{"format":"dropcap-backup","version":1,"saved":[],"futureThing":{"x":1},"settings":{"digestHour":6,"newKnob":true}}""");
        Assert.Empty(partial.Scraps);                                         // 빠진 항목은 기본값, 모르는 키는 건너뜀
        Assert.Null(partial.SectionsChosen);
        Assert.Equal(6, partial.Settings.DigestHour);
        Assert.Equal("?", partial.App);
    }

    [Fact]
    public void MergeIntoFreshDeviceTakesEverything()
    {
        var (s, scraps) = Home();
        var b = Backup.Make(s, scraps, ["스크랩", "보고서", "빈 폴더"]);
        var m = Backup.Merge(b, new AppState(), [], ["스크랩"]);
        Assert.True(Backup.SameSettings(s.Settings, m.State.Settings));
        Assert.Equal(["economy", "ai"], m.State.SectionsChosen!);           // 분야 순서로
        Assert.Equal(17, m.State.SectionPolicy["economy"].BundleHour);
        Assert.True(m.State.Enabled["verge"]);
        Assert.False(m.State.Enabled.ContainsKey("nyt"));
        Assert.Equal(["custom-a"], m.State.CustomSources.Select(x => x.Id));
        Assert.Equal(["1", "2"], m.State.Saved.Select(x => x.Id));
        Assert.Equal(["sc1"], m.NewScraps.Select(x => x.Id));
        Assert.Equal(["스크랩", "보고서", "빈 폴더"], m.Folders);
        Assert.True(m.Summary.SettingsTaken);
        Assert.Equal(2, m.Summary.Saved);
        Assert.Equal(1, m.Summary.Scraps);
    }

    [Fact]
    public void MergeIntoUsedDeviceSkipsSameAndKeepsLocal()
    {
        var (s, scraps) = Home();
        var b = Backup.Make(s, scraps, ["보고서"]);
        var mine = new AppState();
        mine.Settings.DigestHour = 10;                                        // 이 기기에서 바꾼 값은 지킨다
        mine.Settings.MustKeywords = ["gpt-6", "Claude"];
        mine.Enabled = new() { ["verge"] = false, ["nyt"] = true };           // 가져온 쪽이 켠 것은 켜고, 이 기기에서 켠 것은 끄지 않는다
        mine.Notify = new() { ["verge"] = true };
        mine.Saved = [News("2"), News("9")];
        mine.CustomSources = [Src("other", "https://custom-a.example/feed")];
        var sameScrap = new Scrap { Id = "different-id", Item = News("1"), Quote = "문단", Collection = "보고서" };
        var m = Backup.Merge(b, mine, [sameScrap], ["스크랩", "보고서"]);
        Assert.Equal(10, m.State.Settings.DigestHour);
        Assert.False(m.Summary.SettingsTaken);
        Assert.Equal(["gpt-6", "Claude"], m.State.Settings.MustKeywords);    // 대소문자만 다른 같은 낱말은 건너뜀
        Assert.Equal(["삼성전자"], m.State.Settings.WatchKeywords);
        Assert.Equal(new Dictionary<string, bool> { ["verge"] = true, ["nyt"] = true }, m.State.Enabled);
        Assert.True(m.State.Notify["verge"]);
        Assert.Equal(["2", "9", "1"], m.State.Saved.Select(x => x.Id));
        Assert.Single(m.State.CustomSources);                                 // 같은 주소는 건너뜀
        Assert.Empty(m.NewScraps);                                            // 같은 기사·문단·폴더
        Assert.Equal(["spam"], m.State.HiddenSources);
        Assert.Equal(["story-1"], m.State.FollowedStories);
        Assert.Equal(10, mine.Settings.DigestHour);                           // 원래 상태는 건드리지 않음
        Assert.Equal(2, mine.Saved.Count);
        var again = Backup.Merge(b, m.State, [sameScrap], m.Folders);         // 두 번 가져와도 그대로
        Assert.Equal(new Backup.Summary(), again.Summary);
        Assert.Contains("새로 더할 것이 없었습니다", again.Summary.Text);
    }

    [Fact]
    public void RestoreUndoesMerge()
    {
        var (s, scraps) = Home();
        var before = Backup.Make(new AppState(), [], []);
        var merged = Backup.Merge(Backup.Make(s, scraps, []), new AppState(), [], []).State;
        var back = Backup.Restore(before, merged);
        Assert.Empty(back.Saved);
        Assert.Empty(back.CustomSources);
        Assert.True(Backup.SameSettings(new StateSettings(), back.Settings));
        Assert.Null(back.SectionsChosen);
    }

    // 앱 안에서: 가져오기 전 자동 백업 · 같은 파일 두 번 · 되돌리기 · 최근 5개만
    private sealed class Device : IDisposable
    {
        public readonly Database Db;
        public readonly AppModel Model;
        public readonly Scrapbook Book;
        public Device(string dir, AppState? state = null)
        {
            Db = new Database(Path.Combine(dir, $"magazine-{Guid.NewGuid()}.sqlite"));
            Model = new AppModel(new FakeUi(), new Magazine(Db), state ?? new AppState(), persist: false) { ShowAllSourcesForTests = true };
            Book = new Scrapbook(Db);
        }
        public void Dispose() => Db.Dispose();
    }

    [Fact]
    public void ImportUndoAndSameFileTwice()
    {
        var clock = new DateTimeOffset(2026, 10, 14, 9, 0, 0, TimeSpan.Zero);
        Backup.Now = () => clock;
        using var d = new Device(tmp.Path);
        d.Model.State.Saved.Add(News("9"));
        Assert.False(Backup.CanUndo);

        var r = Backup.Import(MacSample, d.Model, d.Book);
        Assert.True(r.Ok, r.Message);
        Assert.Equal("가져왔습니다 — 저장 2 · 스크랩 1 · 폴더 2 · 구독 1 · 분야 2 · 낱말 2 · 숨긴 출처 1 · 팔로우 1 · 알림 설정 더함", r.Message);
        Assert.Equal(["9", "1", "2"], d.Model.State.Saved.Select(x => x.Id));
        Assert.Equal(["sc1"], d.Book.Scraps.Select(x => x.Id));
        Assert.Equal(["스크랩", "보고서", "빈 폴더"], d.Book.Collections);
        Assert.True(Backup.CanUndo);
        Assert.StartsWith(Path.Combine(Store.Dir, "backups", "before-import-"), Backup.LatestBeforeImport());

        clock = clock.AddSeconds(1);
        var again = Backup.Import(MacSample, d.Model, d.Book);
        Assert.Equal("가져왔습니다 — 새로 더할 것이 없었습니다(모두 이미 있음)", again.Message);
        Assert.Single(d.Book.Scraps);

        // 되돌리기 두 번: 두 번째 가져오기 전 → 첫 가져오기 전
        Assert.True(Backup.UndoLastImport(d.Model, d.Book).Ok);
        d.Book.Add(News("5"), collection: "새 폴더");                            // 가져온 뒤 더한 스크랩은 되돌릴 때 빠진다
        var u = Backup.UndoLastImport(d.Model, d.Book);
        Assert.Equal("가져오기 전으로 되돌렸습니다", u.Message);
        Assert.Equal(["9"], d.Model.State.Saved.Select(x => x.Id));
        Assert.Empty(d.Book.Scraps);
        Assert.Equal(["스크랩"], d.Book.Collections);
        Assert.Null(d.Model.State.SectionsChosen);
        Assert.Empty(d.Model.State.Settings.WatchKeywords);
        Assert.False(Backup.CanUndo);
        Assert.False(Backup.UndoLastImport(d.Model, d.Book).Ok);
    }

    [Fact]
    public void BadFileLeavesEverythingAlone()
    {
        using var d = new Device(tmp.Path);
        var r = Backup.Import("""{"format":"dropcap-backup","version":2}""", d.Model, d.Book);
        Assert.False(r.Ok);
        Assert.Equal("가져오지 못했습니다: 더 새 판 Dropcap 이 만든 기록입니다(형식 2). 앱을 업데이트한 뒤 가져오세요", r.Message);
        Assert.Equal("가져오지 못했습니다: Dropcap 기록 파일이 아닙니다", Backup.Import("{}", d.Model, d.Book).Message);
        Assert.False(Backup.CanUndo);                                          // 읽지 못하면 백업도 남기지 않음
    }

    [Fact]
    public void KeepsFiveNewestBeforeImportFiles()
    {
        var clock = new DateTimeOffset(2026, 10, 14, 9, 0, 0, TimeSpan.Zero);
        Backup.Now = () => clock;
        using var d = new Device(tmp.Path);
        for (var i = 0; i < 7; i++) { clock = clock.AddMinutes(1); Assert.True(Backup.Import(MacSample, d.Model, d.Book).Ok); }
        var files = Directory.GetFiles(Backup.Dir, "before-import-*").Select(Path.GetFileName).Order(StringComparer.Ordinal).ToList();
        Assert.Equal(5, files.Count);
        Assert.Equal($"before-import-{Backup.Stamp(clock)}.json", files[^1]);
    }

    [Fact]
    public void ExportThenImportOnAnotherDevice()
    {
        var (s, scraps) = Home();
        using var home = new Device(tmp.Path, s);
        foreach (var sc in scraps) home.Book.Update(sc);
        home.Book.CreateCollection("빈 폴더");
        var file = Path.Combine(tmp.Path, Backup.SuggestedFileName);
        Assert.Equal($"내보냈습니다: {Path.GetFileName(file)}", Backup.ExportTo(file, home.Model, home.Book).Message);
        Assert.StartsWith("Dropcap-기록-", Path.GetFileName(file));

        using var other = new TempDir();                                       // 다른 기기: 폴더·화면 설정(prefs)도 따로
        using var work = new Device(other.Path);
        Assert.True(Backup.ImportFrom(file, work.Model, work.Book).Ok);
        Assert.True(Backup.SameSettings(s.Settings, work.Model.State.Settings));
        Assert.Equal(["1", "2"], work.Model.State.Saved.Select(x => x.Id));
        Assert.Equal(s.Saved[1], work.Model.State.Saved[1]);
        Assert.Equal(scraps[0], work.Book.Scraps[0]);
        Assert.Equal(home.Book.Collections, work.Book.Collections);
        Assert.Equal(["economy", "ai"], work.Model.State.SectionsChosen!);
        // 다시 내보내면 같은 내용(내보낸 시각·분야 순서·꺼 둔 출처만 빼고 — 꺼 둔 것은 옮기지 않는다)
        var a = Backup.Decode(Backup.Export(home.Model, home.Book));
        var c = Backup.Decode(Backup.Export(work.Model, work.Book));
        a.Exported = c.Exported; a.SectionsChosen = c.SectionsChosen; a.Enabled = c.Enabled;
        Assert.Equal(Backup.Encode(a), Backup.Encode(c));
    }
}
