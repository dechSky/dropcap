using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;
using Dropcap.Ui;

namespace Dropcap.Core.Tests;

// 시스템 연동(I 절)·매거진 따라잡기(M-25~M-27): 아무 주소 저장(SaveLink)·dropcap:// 해석(UrlRouter)·노트 폴더 내보내기(ScrapExport)·
// 이번 주 모은 문장·분야 지면·스토리 분야 다수결. 맥 ReaderSaveTests·IntegrationTests·CoreTests 의 같은 사례. 바깥 서버·레지스트리·창 없이 돈다.
public class SaveLinkTests : IDisposable
{
    private readonly TempDir tmp = new();
    private readonly Database db;
    private readonly AppModel model;
    private readonly Func<string, Task<bool>> resolves = SaveLink.Resolves;
    private readonly Func<string, Task<byte[]?>> fetch = SaveLink.Fetch;

    public SaveLinkTests()
    {
        db = new Database(System.IO.Path.Combine(tmp.Path, "magazine.sqlite"));
        model = new AppModel(new FakeUi(), new Magazine(db), new AppState(), persist: false);
        SaveLink.Resolves = _ => Task.FromResult(true);
        SaveLink.Fetch = _ => Task.FromResult<byte[]?>(null);
    }

    public void Dispose()
    {
        SaveLink.Resolves = resolves;
        SaveLink.Fetch = fetch;
        db.Dispose();
        tmp.Dispose();
    }

    [Fact]
    public void NormalizesPlainAndBareAddresses()
    {
        Assert.Equal("https://example.com/a/b?x=1", SaveLink.Normalize("  https://example.com/a/b?x=1#top \n"));
        Assert.Equal("https://example.com/news/1", SaveLink.Normalize("example.com/news/1"));
        Assert.Equal("https://example.com/a", SaveLink.Normalize("<https://example.com/a>"));
        Assert.Equal("https://example.com:8080/a", SaveLink.Normalize("example.com:8080/a"));
        Assert.Equal("https://example.com/a", SaveLink.Normalize("“https://example.com/a”"));
    }

    [Fact]
    public void RejectsUnsafeOrNonWeb()
    {
        foreach (var bad in new[] { "http://localhost/x", "http://192.168.0.1/admin", "http://127.0.0.1:8080", "http://[::1]/", "file:///etc/passwd",
                     "javascript:alert(1)", "mailto:a@example.com", "ftp://example.com/a", "http://intranet/", "http://router.local/",
                     "https://user:pw@example.com/a", "hello world", "", "smb://example.com/share", "http://0x7f.1/" })
            Assert.True(SaveLink.Normalize(bad) is null, bad);
        Assert.Null(SaveLink.Normalize("https://example.com/" + new string('a', 3000)));   // 너무 긴 주소
        Assert.Null(SaveLink.Normalize(null));
    }

    [Fact]
    public void ReadsArticleHead()
    {
        const string html = """
            <html><head><title>Fallback | Site</title>
            <meta property="og:title" content="Big &amp; New Model">
            <meta content="/img/cover.jpg" property="og:image">
            <meta property="og:site_name" content="Example News">
            <meta name="description" content="A summary.">
            </head></html>
            """;
        var h = SaveLink.ParseHead(html, "https://example.com/a/b");
        Assert.Equal(("Big & New Model", "https://example.com/img/cover.jpg", "Example News", "A summary."), (h.Title, h.Image, h.Site, h.Description));
        var h2 = SaveLink.ParseHead("<title>Only Title</title><meta property=\"og:image\" content=\"http://127.0.0.1/x.png\">", "https://example.com/");
        Assert.Equal("Only Title", h2.Title);
        Assert.Null(h2.Image);   // 내부망 사진 주소는 받지 않음
        // 빈 og:title 이면 다음 후보(twitter:title)
        var h3 = SaveLink.ParseHead("""<meta property="og:title" content=""><meta name="twitter:title" content="트윗 제목"><meta property="og:site_name" content="사이트">""", "https://a.example/");
        Assert.Equal(("트윗 제목", "사이트"), (h3.Title, h3.Site));
    }

    // 닫히지 않은 꼬리표가 많은 페이지에서도 멈추지 않음(HtmlScan — 보안 점검)
    [Fact]
    public void HeadParserOnHostilePageIsFast()
    {
        var metas = string.Concat(Enumerable.Repeat("<meta property='og:title' content=", 20_000));
        var sw = Stopwatch.StartNew();
        _ = SaveLink.ParseHead(metas, "https://a.example/");
        Assert.True(sw.Elapsed < TimeSpan.FromSeconds(4), sw.Elapsed.ToString());
    }

    [Fact]
    public void MakesSavedItem()
    {
        const string u = "https://www.example.com/2026/10/some-story";
        var it = SaveLink.MakeItem(u, new SaveLink.Head(Title: "Some Story - Example"));
        Assert.Equal("example.com", it.SourceName);
        Assert.Equal((u, u), (it.Link, it.Id));
        Assert.Equal(SaveLink.Tier, it.Tier);
        Assert.StartsWith(SaveLink.SourcePrefix, it.SourceId);
        Assert.Equal("Some Story", it.Title);   // 끝의 사이트 이름(주소의 이름)은 뗌
        Assert.Equal("북마클릿 제목", SaveLink.MakeItem(u, new SaveLink.Head(), "북마클릿 제목").Title);
        Assert.False(string.IsNullOrEmpty(SaveLink.MakeItem(u, new SaveLink.Head()).Title));   // 머리를 못 받아도 주소에서 제목
        Assert.Equal("Example News", SaveLink.MakeItem(u, new SaveLink.Head(Site: "Example News")).SourceName);
    }

    [Fact]
    public void StripsSiteSuffixMatchingHost()
    {
        Assert.Equal("Initial", SaveLink.StripHostSuffix("Initial - Wikipedia", "en.wikipedia.org"));
        Assert.Equal("A story", SaveLink.StripHostSuffix("A story | The Verge", "www.theverge.com"));
        Assert.Equal("Rock - Paper", SaveLink.StripHostSuffix("Rock - Paper", "example.com"));   // 사이트 이름이 아니면 그대로
    }

    [Fact]
    public void BookmarkletUsesScheme()
    {
        Assert.StartsWith("javascript:", SaveLink.Bookmarklet);
        Assert.Contains("dropcap://save?url='+encodeURIComponent(location.href)", SaveLink.Bookmarklet);
    }

    [Fact]
    public void OutsideSavesAreRateLimited()
    {
        var recent = new List<DateTimeOffset>();
        var t = DateTimeOffset.Now;
        for (var i = 0; i < 10; i++) Assert.True(SaveLink.AllowOutside(recent, t.AddSeconds(i)));
        Assert.False(SaveLink.AllowOutside(recent, t.AddSeconds(10)));   // 1분에 10번까지
        Assert.True(SaveLink.AllowOutside(recent, t.AddSeconds(75)));    // 1분이 지나면 다시
    }

    [Fact]
    public async Task SavesIntoSavedListOnce()
    {
        SaveLink.Fetch = _ => Task.FromResult<byte[]?>(System.Text.Encoding.UTF8.GetBytes("<meta property=\"og:title\" content=\"주소로 저장한 기사\"><meta property=\"og:site_name\" content=\"예시 신문\">"));
        var r = await SaveLink.SaveAsync(model, "example.com/news/42");
        Assert.True(r.Ok);
        Assert.Equal(("주소로 저장한 기사", "예시 신문", "https://example.com/news/42"), (r.Item!.Title, r.Item.SourceName, r.Item.Link));
        Assert.Single(model.State.Saved);
        Assert.True(model.IsSaved(r.Item));
        // 같은 주소는 다시 넣지 않고 저장한 것을 돌려줌
        var again = await SaveLink.SaveAsync(model, "https://example.com/news/42#frag");
        Assert.Equal(r.Item.Key, again.Item!.Key);
        Assert.Single(model.State.Saved);
        Assert.Equal(("나중에 읽기에 저장했어요", "예시 신문 · 주소로 저장한 기사"), SaveLink.Announcement(r));
    }

    [Fact]
    public async Task RefusesBadOrPrivateAddresses()
    {
        Assert.Equal(SaveLink.Failure.NotUrl, (await SaveLink.SaveAsync(model, "그냥 글")).Error);
        Assert.Equal(SaveLink.Failure.NotUrl, (await SaveLink.SaveAsync(model, "http://10.0.0.1/")).Error);
        // 이름이 내부망 주소로 풀리면(DNS 바꿔치기) 저장하지 않음
        SaveLink.Resolves = _ => Task.FromResult(false);
        Assert.Equal(SaveLink.Failure.Unsafe, (await SaveLink.SaveAsync(model, "https://rebind.example.com/a")).Error);
        Assert.Empty(model.State.Saved);
        Assert.Equal(("저장하지 못했어요", "내부망·특수 주소는 저장하지 않습니다"), SaveLink.Announcement(new SaveLink.Result(null, SaveLink.Failure.Unsafe)));
        // 머리를 받다 실패해도 주소에서 제목을 지어 저장
        SaveLink.Resolves = _ => Task.FromResult(true);
        SaveLink.Fetch = _ => throw new HttpRequestException("boom");
        var r = await SaveLink.SaveAsync(model, "https://example.com/2026/10/quiet-launch");
        Assert.True(r.Ok);
        Assert.Equal("Quiet launch", r.Item!.Title);
    }

    [Fact]
    public void ConfirmTextShowsTitleHostAndAddress()
    {
        Assert.Equal("제목\nexample.com\nhttps://example.com/a", SaveLink.ConfirmBody("https://example.com/a", "제목"));
        Assert.Equal("이 페이지를 나중에 읽기에 저장할까요?", SaveLink.ConfirmTitle);
    }
}

public class UrlRouterTests
{
    [Fact]
    public void OpenLinksRoundTripKeysWithSpecialCharacters()
    {
        const string key = "openai|https://openai.com/news/a?b=1&c=2#x";
        var u = UrlRouter.OpenLink(key);
        Assert.StartsWith("dropcap://open?key=", u);
        Assert.Equal(new Route.Open(key), UrlRouter.Parse(u));
        Assert.Null(UrlRouter.Parse("dropcap://open"));
        Assert.Null(UrlRouter.Parse("https://open?key=a"));
        Assert.Equal(new Route.Open("z"), UrlRouter.Parse("DROPCAP://OPEN?key=z"));
    }

    [Fact]
    public void ParsesSaveAndMagazine()
    {
        const string enc = "https%3A%2F%2Fexample.com%2Fpost%3Fid%3D3%26q%3Da%2Bb";
        var r = Assert.IsType<Route.Save>(UrlRouter.Parse($"dropcap://save?url={enc}&title=%EC%A0%9C%EB%AA%A9"));
        Assert.Equal(("https://example.com/post?id=3&q=a+b", "제목", true), (r.Url, r.Title, r.Confirm));   // 바깥(브라우저)에서 온 저장은 묻는다
        Assert.Equal("https://example.com/a", Assert.IsType<Route.Save>(UrlRouter.Parse("dropcap:save?url=https://example.com/a")).Url);
        Assert.Null(UrlRouter.Parse("dropcap://save?url=http%3A%2F%2F10.0.0.1%2F"));   // 내부망
        Assert.Null(UrlRouter.Parse("dropcap://delete?url=https://example.com/a"));     // 모르는 동작
        Assert.Null(UrlRouter.Parse("https://save?url=https://example.com/a"));         // 다른 스킴
        Assert.Null(UrlRouter.Parse("dropcap://save"));
        Assert.Null(UrlRouter.Parse("dropcap://save?url=" + new string('a', UrlRouter.MaxLength)));
        Assert.IsType<Route.Magazine>(UrlRouter.Parse(UrlRouter.MagazineLink));
        Assert.IsType<Route.Magazine>(UrlRouter.Parse("dropcap://magazine/"));
    }

    [Fact]
    public void CommandLineArguments()
    {
        Assert.IsType<Route.Magazine>(UrlRouter.FromArgs(["--magazine"]));
        var s = Assert.IsType<Route.Save>(UrlRouter.FromArgs(["--save", "example.com/a"]));
        Assert.Equal(("https://example.com/a", false), (s.Url, s.Confirm));   // 사용자가 직접 부른 것이라 묻지 않음(맥 단축어와 같음)
        Assert.Null(UrlRouter.FromArgs(["--save", "http://localhost/"]));
        Assert.Null(UrlRouter.FromArgs(["--save"]));
        Assert.Null(UrlRouter.FromArgs([]));
        Assert.Null(UrlRouter.FromArgs(["--bogus"]));
        Assert.Equal(new Route.Open("a|1"), UrlRouter.FromArgs(["dropcap://open?key=a%7C1"]));   // 주소 연결로 켜짐(\"%1\")
    }
}

public class ScrapExportFileTests : IDisposable
{
    private readonly TempDir tmp = new();
    private readonly Database db;
    private readonly Scrapbook book;
    private readonly ScrapExport export;
    private readonly string notes;
    private readonly List<string> trashed = new();

    public ScrapExportFileTests()
    {
        db = new Database(System.IO.Path.Combine(tmp.Path, "magazine.sqlite"));
        book = new Scrapbook(db);
        export = new ScrapExport(book) { DelayMs = 0 };
        notes = System.IO.Path.Combine(tmp.Path, "notes");
        Directory.CreateDirectory(notes);
        ScrapExport.Trash = trashed.Add;
    }

    public void Dispose()
    {
        ScrapExport.Trash = null;
        db.Dispose();
        tmp.Dispose();
    }

    private static NewsItem It(string id) => new()
    {
        Id = id, Title = "Meta has new AI models " + id, TitleKo = "메타의 새 AI 모델 " + id, Link = "https://example.com/" + id,
        Date = DateTimeOffset.Now, SourceId = "verge", SourceName = "The Verge",
    };

    [Fact]
    public void SafeFileNames()
    {
        Assert.Equal("GPT 조사.md", ScrapExport.FileName("GPT 조사"));
        Assert.Equal("a／b：c.md", ScrapExport.FileName("a/b:c"));
        Assert.Equal("hidden.md", ScrapExport.FileName("..hidden"));
        Assert.Equal("스크랩.md", ScrapExport.FileName("   "));
        // 윈도우 금지 글자·끝 점·예약 이름·제어 문자
        Assert.Equal("왜＊＜＞＂｜？＼.md", ScrapExport.FileName("왜*<>\"|?\\"));
        Assert.Equal("끝.md", ScrapExport.FileName("끝. . "));
        Assert.Equal("_CON.md", ScrapExport.FileName("CON"));
        Assert.Equal("_nul.txt.md", ScrapExport.FileName("nul.txt"));
        Assert.Equal("CONSOLE.md", ScrapExport.FileName("CONSOLE"));
        Assert.Equal("ab.md", ScrapExport.FileName("a\tb\n"));
        Assert.Equal(63, ScrapExport.FileName(new string('가', 300)).Length);   // 스크랩 폴더 이름과 같은 60자
        Assert.Equal("👍" + new string('a', 59) + ".md", ScrapExport.FileName("👍" + new string('a', 100)));   // 글자 중간을 자르지 않음
    }

    [Fact]
    public void IgnoresOnlyDateLine()
    {
        const string a = "# c\n\n_Dropcap 스크랩 · 2026-10-12 · 2건_\n\n## x\n";
        const string b = "# c\n\n_Dropcap 스크랩 · 2026-10-13 · 2건_\n\n## x\n";
        const string c = "# c\n\n_Dropcap 스크랩 · 2026-10-13 · 3건_\n\n## x\n";
        Assert.True(ScrapExport.SameIgnoringDate(a, b));
        Assert.False(ScrapExport.SameIgnoringDate(a, c));
    }

    [Fact]
    public void OffTouchesNothing()
    {
        book.Add(It("1"), collection: "조사");
        export.SyncNow();
        Assert.False(export.Enabled);
        Assert.Empty(Directory.GetFiles(notes));
    }

    [Fact]
    public async Task WritesOneFilePerFolderAndRenames()
    {
        book.Add(It("1"), quote: "메타가 새 모델을 공개했다.", collection: "조사");
        export.SetFolder(notes);   // 폴더를 고르면 켜진다(맥과 같음)
        Assert.True(export.Enabled);
        Assert.Equal(notes, export.Folder);
        export.SyncNow();
        var file = System.IO.Path.Combine(notes, "조사.md");
        Assert.True(File.Exists(file));
        Assert.Equal(Scrapbook.Render(book.Scraps.Where(s => s.Collection == "조사").ToList(), "조사"), File.ReadAllText(file));
        Assert.False(File.Exists(System.IO.Path.Combine(notes, "스크랩.md")));   // 비어 있는 폴더는 새 파일을 만들지 않음
        Assert.Empty(Directory.GetFiles(notes, "*.tmp", SearchOption.AllDirectories).Concat(Directory.GetFiles(notes, ".*")));   // 임시 파일이 남지 않음

        // 바뀐 게 없으면 손대지 않음
        var stamp = new DateTime(2020, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        File.SetLastWriteTimeUtc(file, stamp);
        export.SyncNow();
        Assert.Equal(stamp, File.GetLastWriteTimeUtc(file));

        // 스크랩이 바뀌면(이벤트) 다시 씀
        export.Attach();
        book.Add(It("2"), quote: "두 번째 문단", collection: "조사");
        await Until(() => File.ReadAllText(file).Contains("두 번째 문단"));

        // 폴더 이름을 바꾸면 새 이름의 파일을 쓰고 예전 파일은 휴지통으로
        book.Rename("조사", "GPT 조사");
        await Until(() => File.Exists(System.IO.Path.Combine(notes, "GPT 조사.md")));
        Assert.Equal([file], trashed);

        // 끄면 더 쓰지 않음, 폴더를 잊으면 꺼짐
        export.ForgetFolder();
        Assert.False(export.Enabled);
        Assert.Null(export.Folder);
        Assert.Null(export.SavedPath);
    }

    [Fact]
    public void MissingFolderAsksToChooseAgain()
    {
        var gone = System.IO.Path.Combine(tmp.Path, "gone");
        Directory.CreateDirectory(gone);
        export.SetFolder(gone);
        Directory.Delete(gone);
        Assert.Null(export.Folder);   // 다른 PC 로 옮겼거나 지워짐
        Assert.Equal("폴더를 찾지 못했습니다 — 다시 골라 주세요", export.LastError);
        Assert.Equal(gone, export.SavedPath);
        book.Add(It("1"), collection: "조사");
        export.SyncNow();   // 쓰지 않고 그대로
        Assert.False(Directory.Exists(gone));
    }

    [Fact]
    public async Task SettingsTabShowsAndToggles()
    {
        var platform = new MiniPlatform();
        var model = new AppModel(new FakeUi(), new Magazine(db), new AppState(), persist: false);
        var page = new SettingsPage(model, platform, book, export);
        Task<object?> Run(string cmd, object? args = null) =>
            page.Handle(cmd, args is null ? new JsonObject() : (JsonNode.Parse(JsonSerializer.Serialize(args)) as JsonObject)!);
        JsonNode View() => JsonNode.Parse(JsonSerializer.Serialize(page.View(), Json.Options))!["scrapbook"]!;

        Assert.Equal(("고르지 않음", false, "고르기…", false), (View()["folder"]!.GetValue<string>(), View()["enabled"]!.GetValue<bool>(),
            View()["choose"]!.GetValue<string>(), View()["canSaveNow"]!.GetValue<bool>()));
        // 켜려는데 폴더가 없으면 먼저 고른다
        ScrapExport.PickFolder = () => Task.FromResult<string?>(notes);
        try { await Run("scrapExport", new { on = true }); }
        finally { ScrapExport.PickFolder = null; }
        Assert.True(export.Enabled);
        Assert.Equal((notes, "바꾸기…", true), (View()["folder"]!.GetValue<string>(), View()["choose"]!.GetValue<string>(), View()["hasFolder"]!.GetValue<bool>()));
        Assert.False(View()["canSaveNow"]!.GetValue<bool>());   // 스크랩이 없으면 '지금 저장' 꺼짐
        book.Add(It("1"), collection: "조사");
        Assert.True(View()["canSaveNow"]!.GetValue<bool>());
        await Run("scrapExportNow");
        Assert.True(File.Exists(System.IO.Path.Combine(notes, "조사.md")));
        await Run("scrapExport", new { on = false });
        Assert.False(export.Enabled);
        await Run("copyBookmarklet");
        Assert.Equal([SaveLink.Bookmarklet], platform.Copied);
        await Run("forgetScrapFolder");
        Assert.Null(export.SavedPath);
        Assert.Contains("dropcap://save?url=", View()["bookmarkletNote"]!.GetValue<string>());
    }

    private static async Task Until(Func<bool> ok)
    {
        for (var i = 0; i < 100 && !ok(); i++) await Task.Delay(30);
        Assert.True(ok());
    }
}

internal sealed class MiniPlatform : IPlatform
{
    public List<string> Copied { get; } = new();
    public void OpenMagazine(string? page = null) { }
    public void OpenSettings(string? tab = null) { }
    public void OpenOnboarding() { }
    public void OpenReader(NewsItem item) { }
    public void CloseWindow(string page) { }
    public void Quit() { }
    public void CopyText(string text) => Copied.Add(text);
    public Task<bool> SaveTextFile(string suggestedName, string text) => Task.FromResult(false);
    public void Share(NewsItem item) { }
    public void Speak(string text, string language) { }
    public void StopSpeaking() { }
    public bool Speaking => false;
    public bool LaunchAtLogin { get; set; }
    public bool ReduceMotion => false;
    public void ApplyFont() { }
}

public class WeeklyQuotesTests : IDisposable
{
    private readonly TempDir tmp = new();
    public void Dispose() => tmp.Dispose();

    private static readonly NewsItem Item = new() { Id = "1", Title = "t", Link = "https://example.com", SourceId = "x", SourceName = "X" };

    [Fact]
    public void PicksThisWeeksQuotesOnce()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(1_792_000_000);
        Scrap S(string? q, double daysAgo) => new() { Item = Item, Quote = q, Collection = "c", Created = now.AddDays(-daysAgo) };
        var list = new[] { S("오래된 문장", 9), S("이번 주 문장", 2), S("이번 주 문장", 1), S(null, 1), S("어제 문장", 0.5) };
        Assert.Equal(["어제 문장", "이번 주 문장"], WeeklyQuotes.Pick(list, now).Select(s => s.Quote));
        Assert.Empty(WeeklyQuotes.Pick([S("아직 안 온 문장", -1)], now));   // 앞날짜는 빼기
        Assert.Equal(6, WeeklyQuotes.Pick(Enumerable.Range(0, 9).Select(i => S("문장 " + i, i * 0.1)), now).Count);   // 6개까지
    }

    [Fact]
    public void SundayEveningOnly()
    {
        if (Environment.GetEnvironmentVariable("DROPCAP_TEST_WEEKLY") is not null) return;
        DateTime D(int day, int hour) => new(2026, 10, day, hour, 0, 0, DateTimeKind.Local);   // 2026-10-11 은 일요일
        Assert.True(WeeklyQuotes.IsSundayEvening(D(11, 18)));
        Assert.True(WeeklyQuotes.IsSundayEvening(D(11, 17)));
        Assert.False(WeeklyQuotes.IsSundayEvening(D(11, 10)));
        Assert.False(WeeklyQuotes.IsSundayEvening(D(12, 19)));
    }

    [Fact]
    public void ScrapbookShowsWeeklyBoxOnSundayEvening()
    {
        if (Environment.GetEnvironmentVariable("DROPCAP_TEST_WEEKLY") is not null) return;
        var db = new Database(System.IO.Path.Combine(tmp.Path, "magazine.sqlite"));
        try
        {
            var sunday = new DateTimeOffset(new DateTime(2026, 10, 11, 18, 0, 0, DateTimeKind.Local));
            var book = new Scrapbook(db);
            var model = new AppModel(new FakeUi(), new Magazine(db), new AppState(), persist: false) { Now = () => sunday };
            var page = new MagazinePage(model, new Magazine(db), book, new MiniPlatform(), new Bridge()) { LoadPhotos = _ => { }, PhotoUrl = _ => null };
            db.SaveScrap(new Scrap { Item = Item, Quote = "이번 주에 모은 문장", Collection = "c", Created = sunday.AddDays(-2) });
            db.SaveScrap(new Scrap { Item = Item, Quote = null, Collection = "c", Created = sunday.AddDays(-1) });
            book.Reload();
            var w = page.ScrapbookData(null).Weekly!;
            Assert.Equal("1개 · 지난 7일", w.Count);
            Assert.Equal(("이번 주에 모은 문장", "X", "x|1"), (w.Items[0].Quote, w.Items[0].Source, w.Items[0].Key));
            model.Now = () => sunday.AddHours(-2);   // 일요일 16시는 아직
            Assert.Null(page.ScrapbookData(null).Weekly);
        }
        finally { db.Dispose(); }
    }
}

public class SectionPageIssueTests : IDisposable
{
    private readonly TempDir tmp = new();
    private readonly Database db;
    private readonly Magazine mag;
    private readonly AppModel model;
    private readonly MagazinePage page;
    private readonly DateTimeOffset now = DateTimeOffset.Now;

    public SectionPageIssueTests()
    {
        db = new Database(System.IO.Path.Combine(tmp.Path, "magazine.sqlite"));
        mag = new Magazine(db);
        model = new AppModel(new FakeUi(), mag, new AppState(), persist: false) { ShowAllSourcesForTests = true };
        page = new MagazinePage(model, mag, new Scrapbook(db), new MiniPlatform(), new Bridge()) { LoadPhotos = _ => { }, PhotoUrl = _ => null };
    }

    public void Dispose() { db.Dispose(); tmp.Dispose(); }

    private NewsItem It(string id, string title, string src, double minutesAgo, string? image = null) => new()
    {
        Id = id, Title = title, Link = "https://x.com/" + id, Date = now.AddMinutes(-minutesAgo), SourceId = src, SourceName = src.ToUpperInvariant(), Image = image,
    };

    [Fact]
    public void SubtitleLikeMac()
    {
        Assert.Equal("소식 12건", Magazine.Subtitle(12, 12, 0));
        Assert.Equal("소식 30건 중 12건 실음 · 분야 4개", Magazine.Subtitle(30, 12, 4));
        Assert.Equal("IT 소식 9건 중 5건 실음", Magazine.Subtitle(9, 5, 0, "IT 소식"));
    }

    [Fact]
    public async Task SectionPageIsItsOwnIssue()
    {
        // 경제 3건(출처 셋) · 스포츠 2건 · AI 2건(투자·보안)
        mag.Ingest([
            It("e1", "코스피 사상 최고치 경신", "src-e1", 10, "https://x.com/e1.jpg"),
            It("e2", "환율 1,380원대로 내려와", "src-e2", 20),
            It("e3", "기준금리 동결 결정", "src-e3", 30),
            It("s1", "프로야구 끝내기 홈런", "src-s1", 15),
            It("s2", "축구 대표팀 2-1 승리", "src-s2", 25),
            It("a1", "Anthropic raises $5B funding at $200B valuation", "cat-a1", 35),
            It("a2", "New jailbreak attack bypasses model safety", "cat-a2", 45),
        ], enrich: false);
        var issue = mag.LiveSection("economy");
        Assert.Equal(("live-section-economy", 3), (issue.Id, issue.Count));   // 건수도 그 분야
        Assert.Equal("src-e1|e1", issue.Cover);   // 표지도 그 분야(사진 있는 1등)

        var v = (await page.IssueData("section:economy"))!;
        Assert.Equal(("경제", "economy", true), (v.Title, v.SectionPage, v.Live));
        Assert.StartsWith("오늘 호의 분야 지면 · ", v.Kicker);
        Assert.DoesNotContain(" 호", v.Kicker!["오늘 호의 분야 지면 · ".Length..]);
        Assert.Equal("src-e1|e1", v.Cover!.Item.Key);
        Assert.Empty(v.Chips);                          // '전체'·다른 분야 칩 없음
        Assert.Empty(v.SubChips);
        Assert.Null(v.Today);
        Assert.Equal(["src-e2|e2", "src-e3|e3"], v.Sections.SelectMany(s => s.Items).Select(i => i.Key).Order());
        Assert.All(v.Sections, s => Assert.Null(s.Glass));   // 머리가 이미 분야 이름이므로 유리 띠를 다시 달지 않음
        Assert.Equal("경제 소식 3건 · 출처 3곳", v.Head);
        Assert.False(v.ChipsGo);

        // AI 분야 지면: 하위 칩만, 건수 합 = 실린 수(기타 포함), 하위 칩으로 표지째 거름
        var ai = (await page.IssueData("section:ai"))!;
        var shown = (ai.Cover is null ? 0 : 1) + ai.Sections.Sum(s => s.Items.Count);
        Assert.Equal(shown, ai.SubChips.Sum(c => c.Count));
        Assert.All(ai.SubChips, c => Assert.True(c.Count > 0));
        var cat = ai.SubChips[0].Id;
        var narrowed = (await page.IssueData("section:ai", sub: cat))!;
        Assert.Equal(cat, narrowed.Sub);
        Assert.All((narrowed.Cover is { } c ? [c.Item] : new List<ItemView>()).Concat(narrowed.Sections.SelectMany(s => s.Items)), i => Assert.Equal(cat, i.Category));
        Assert.Contains("건 실음", narrowed.Head);

        // 없는 분야 소식이면 안내
        var empty = (await page.IssueData("section:culture"))!;
        Assert.Null(empty.Cover);
        Assert.Contains("문화·연예", empty.Empty!.Title);

        // 오늘 호: 머리 숫자는 실린 것 기준, 칩은 분야 지면으로 가는 길
        var today = (await page.IssueData("today"))!;
        var n = (today.Cover is null ? 0 : 1) + today.Sections.Sum(s => s.Items.Count);
        Assert.Equal(Magazine.Subtitle(today.Count, n, today.Sections.Count(s => !s.Tone.StartsWith("kind-"))), today.Head);
        Assert.True(today.ChipsGo);
        Assert.Equal("오늘", today.Kicker);
        Assert.Null(await page.IssueData("section:"));
    }

    [Fact]
    public void SectionPageHoldsFortyAndDropsChannels()
    {
        // 같은 출처끼리는 스토리로 묶지 않으므로 한 출처의 경제 기사 50건
        var items = Enumerable.Range(0, 50).Select(i => It("e" + i, $"코스피 {i} 사상 최고치 경신", "src-econ", i)).ToList();
        items.Add(It("v1", "코스피 영상 해설", "yt", 5) with { Kind = "video" });
        mag.Ingest(items, enrich: false);
        var issue = mag.LiveSection("economy");
        Assert.Equal(Magazine.SectionPageLimit, issue.Sections.Sum(s => s.Keys.Count));   // 표지 + 지면 40건
        Assert.All(issue.Sections, s => Assert.Null(s.Kind));                           // 구독 채널(영상) 지면 없음
        Assert.Equal(50, issue.Count);
    }

    [Fact]
    public void StoryTopicIsMajority()
    {
        NewsItem T(string id, string title) => It(id, title, "s" + id, 1);
        // 경제 2 · IT 1 → 경제(대표 기사 하나의 분류가 아니라 다수결)
        var eco = new[] { T("1", "코스피 사상 최고치"), T("2", "기준금리 동결 결정"), T("3", "Anthropic raises $5B funding at $200B valuation") };
        var t = Magazine.StoryTopic(eco, i => i.Id == "3" ? "tech" : "economy")!.Value;
        Assert.Equal(("economy", (NewsCategory?)null), (t.Section, t.Category));
        // 같으면 분야 순서 앞
        Assert.Equal(Sections.Order("economy") < Sections.Order("sports") ? "economy" : "sports",
            Magazine.StoryTopic(eco.Take(2).ToList(), i => i.Id == "1" ? "economy" : "sports")!.Value.Section);
        // AI 면 AI 안 하위 분류도 다수결
        var ai = new[] { T("a", "New jailbreak attack bypasses model safety"), T("b", "Hackers exploit vulnerability in AI agent"), T("c", "OpenAI raises funding") };
        var ta = Magazine.StoryTopic(ai, _ => Sections.Ai)!.Value;
        Assert.Equal(Sections.Ai, ta.Section);
        Assert.Equal(ai.GroupBy(i => i.Category).OrderByDescending(g => g.Count()).ThenBy(g => g.Key.SortOrder()).First().Key, ta.Category);
        Assert.Null(Magazine.StoryTopic([]));
        // 화면 표시: AI 면 'AI·하위', 아니면 분야 이름
        var eco2 = MagazinePage.StoryTopicView(eco.Take(2).ToList())!;
        Assert.Equal(("경제", "cat.business"), (eco2.Label, eco2.Icon));
        Assert.Null(MagazinePage.StoryTopicView([]));
    }

    [Fact]
    public async Task AddUrlCommandSavesForLater()
    {
        var resolves = SaveLink.Resolves;
        var fetch = SaveLink.Fetch;
        SaveLink.Resolves = _ => Task.FromResult(true);
        SaveLink.Fetch = _ => Task.FromResult<byte[]?>(System.Text.Encoding.UTF8.GetBytes("<title>붙여 넣은 기사</title>"));
        try
        {
            var ok = JsonNode.Parse(JsonSerializer.Serialize(await page.Handle("addUrl", new JsonObject { ["url"] = "https://example.com/a" }), Json.Options))!;
            Assert.Equal((true, "저장함 · 붙여 넣은 기사"), (ok["ok"]!.GetValue<bool>(), ok["message"]!.GetValue<string>()));
            Assert.Single((await page.SavedData()).Items);
            var bad = JsonNode.Parse(JsonSerializer.Serialize(await page.Handle("addUrl", new JsonObject { ["url"] = "http://192.168.0.1/" }), Json.Options))!;
            Assert.Equal((false, "http(s) 기사 주소가 아닙니다"), (bad["ok"]!.GetValue<bool>(), bad["message"]!.GetValue<string>()));
        }
        finally { SaveLink.Resolves = resolves; SaveLink.Fetch = fetch; }
    }
}
