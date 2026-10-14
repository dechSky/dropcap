using System.Text.Json;
using System.Text.Json.Nodes;
using Dropcap.Ui;

namespace Dropcap.Core.Tests;

// 읽기 창(R 절) 처리기: 읽는 시간, 번역 웹페이지 주소, 보기 데이터 모양, 명령(스크랩·글자 크기·소리)
public class ReaderPageTests : IDisposable
{
    private readonly TempDir tmp = new();
    private readonly Database db;
    private readonly AppModel model;
    private readonly Scrapbook book;
    private readonly ArticleService svc;
    private readonly FakePlatform platform = new();
    private readonly Bridge bridge = new();
    private readonly ReaderPage page;
    private readonly List<string> sent = new();

    private static readonly NewsItem Item = new()
    {
        Id = "1", Title = "OpenAI launches GPT-6", TitleKo = "OpenAI, GPT-6 공개", Link = "https://www.the-verge.com/ai/gpt-6?id=3",
        SourceId = "verge", SourceName = "The Verge", Tier = "press", Date = new DateTimeOffset(new DateTime(2026, 10, 13, 15, 5, 0, DateTimeKind.Local)),
    };

    // 번역을 마친 기사: 첫 사진이 표지가 되고, 문단 둘은 번역문+원문
    private static readonly PreparedArticle Done = new()
    {
        Stage = Stage.Done, Title = "OpenAI, GPT-6 공개", OriginalTitle = "OpenAI launches GPT-6", Translated = true, Engine = Translator.EngineGoogle,
        Summary = ["하나", "둘", "셋"],
        Blocks =
        [
            new Block { Type = BlockKind.Img, Src = "https://img.example.com/a.jpg" },
            new Block { Type = BlockKind.P, Text = "새 모델이 나왔다.", Original = "A new model is out." },
            new Block { Type = BlockKind.Pre, Text = "code" },
            new Block { Type = BlockKind.Li, Text = "빠르다", Original = "It is fast" },
        ],
    };

    public ReaderPageTests()
    {
        db = new Database(Path.Combine(tmp.Path, "magazine.sqlite"));
        model = new AppModel(new FakeUi(), new Magazine(db), new AppState { Recent = [Item] }, persist: false) { ShowAllSourcesForTests = true };
        book = new Scrapbook(db);
        // 본문 추리기 기록(G-14)은 시험 DB 의 유료 기록으로만 — 사용자 데이터를 건드리지 않게
        svc = new ArticleService(new NoExtract(), () => [], Path.Combine(tmp.Path, "articles")) { RecordExtract = (_, _, _) => { } };
        page = new ReaderPage(model, svc, book, platform, bridge, new PaywallBook(db));
        bridge.Register(page);
        bridge.Attach("reader", sent.Add);
    }

    public void Dispose() { ExternalLink.Opener = null; db.Dispose(); tmp.Dispose(); }

    private sealed class NoExtract : IArticleExtractor
    {
        public Task<Article?> FromHtmlAsync(string html, Uri baseUri) => Task.FromResult<Article?>(null);
        public Task<Article?> FromLiveAsync(Uri url) => Task.FromResult<Article?>(null);
    }

    private sealed class FakePlatform : IPlatform
    {
        public List<(string Text, string Lang)> Spoken { get; } = new();
        public List<string> Closed { get; } = new();
        public List<NewsItem> Shared { get; } = new();
        public string? Copied { get; private set; }
        public bool Speaking { get; private set; }
        public void Speak(string text, string language) { Spoken.Add((text, language)); Speaking = true; }
        public void StopSpeaking() => Speaking = false;
        public void Share(NewsItem item) => Shared.Add(item);
        public void CopyText(string text) => Copied = text;
        public void CloseWindow(string page) => Closed.Add(page);
        public void OpenMagazine(string? page = null) { }
        public void OpenSettings(string? tab = null) { }
        public void OpenOnboarding() { }
        public void OpenReader(NewsItem item) { }
        public void Quit() { }
        public Task<bool> SaveTextFile(string suggestedName, string text) => Task.FromResult(true);
        public bool LaunchAtLogin { get; set; }
        public bool ReduceMotion => false;
        public void ApplyFont() { }
    }

    // 디스크에 준비된 기사를 두면 PrepareAsync 가 네트워크 없이 바로 돌려준다
    private void Cache(PreparedArticle a) => File.WriteAllText(svc.FileFor(Item.Link), Json.Encode(a));

    private static JsonObject Node(object o) => (JsonObject)JsonSerializer.SerializeToNode(o, Json.Options)!;

    private async Task<JsonObject?> Run(string cmd, object? args = null)
    {
        var a = args is null ? new JsonObject() : Node(args);
        a["key"] ??= Item.Key;
        var r = await page.Handle(cmd, a);
        return r is null ? null : Node(r);
    }

    [Fact]
    public void ReadingMinutesByLanguage()
    {
        Assert.Null(ReaderPage.ReadingMinutes([]));
        Assert.Equal(1, ReaderPage.ReadingMinutes(["짧은 글"]));
        Assert.Equal(2, ReaderPage.ReadingMinutes([new string('가', 600), new string('나', 400)]));      // 1000자 / 500
        Assert.Equal(3, ReaderPage.ReadingMinutes([new string('가', 1250)]));                            // 2.5 → 3(반올림)
        Assert.Equal(2, ReaderPage.ReadingMinutes([string.Join(" ", Enumerable.Repeat("word", 460))]));  // 460낱말 / 230
        Assert.Equal(1, ReaderPage.ReadingMinutes(["one two three"]));
    }

    [Fact]
    public void TranslatedPageUrlLikeMac()
    {
        Assert.Equal("https://www-the--verge-com.translate.goog/ai/gpt-6?id=3&_x_tr_sl=auto&_x_tr_tl=ko&_x_tr_hl=ko",
            ReaderPage.TranslatedPageUrl(Item.Link));
        Assert.Equal("https://example-com.translate.goog/?_x_tr_sl=auto&_x_tr_tl=ko&_x_tr_hl=ko", ReaderPage.TranslatedPageUrl("https://example.com"));
        Assert.Null(ReaderPage.TranslatedPageUrl("not a url"));
        Assert.Null(ReaderPage.TranslatedPageUrl("file:///c:/a.txt"));
    }

    [Fact]
    public void ViewOfTranslatedArticle()
    {
        var v = Node(ReaderPage.View(Item, Done, model, book));
        Assert.Equal("done", v["phase"]!.GetValue<string>());
        Assert.True(v["translated"]!.GetValue<bool>());
        Assert.Equal("OpenAI launches GPT-6", v["originalTitle"]!.GetValue<string>());
        Assert.Equal(Translator.EngineGoogle, v["engine"]!.GetValue<string>());
        Assert.Equal(3, v["summary"]!.AsArray().Count);
        Assert.Equal("https://img.example.com/a.jpg", v["cover"]!.GetValue<string>()); // 본문 첫 사진이 표지
        Assert.Equal("10월 13일 오후 3:05", v["date"]!.GetValue<string>());
        var blocks = v["blocks"]!.AsArray();
        Assert.Equal(3, blocks.Count);                                                   // 표지가 된 사진은 본문에서 뺌
        Assert.Equal(1, blocks[0]!["i"]!.GetValue<int>());                               // 번호는 원래 자리
        Assert.Equal("A new model is out.", blocks[0]!["original"]!.GetValue<string>());
        Assert.True(blocks[0]!["scrap"]!.GetValue<bool>());
        Assert.False(blocks[1]!["scrap"]!.GetValue<bool>());                             // 코드는 스크랩 안 함
        Assert.Equal("li", blocks[2]!["type"]!.GetValue<string>());
        Assert.Equal(1, v["minutes"]!["shown"]!.GetValue<int>());
        Assert.Equal(17, v["fontSize"]!.GetValue<int>());
        Assert.False(v["marks"]!["saved"]!.GetValue<bool>());
        Assert.Equal(["스크랩"], v["marks"]!["collections"]!.AsArray().Select(n => n!.GetValue<string>()));
    }

    [Fact]
    public void ViewBeforeAndAfterWork()
    {
        var loading = Node(ReaderPage.View(Item, null, model, book));
        Assert.Equal("loading", loading["phase"]!.GetValue<string>());
        Assert.Equal("OpenAI, GPT-6 공개", loading["title"]!.GetValue<string>());
        Assert.Empty(loading["blocks"]!.AsArray());
        Assert.Null(loading["summary"]);                       // 요약이 없으면 상자도 없음(T-06)

        // 피드 사진이 있으면 그게 표지이고, 본문 사진은 그대로 실림
        var withImage = Item with { Image = "https://img.example.com/feed.jpg" };
        var v = Node(ReaderPage.View(withImage, Done, model, book));
        Assert.Equal("https://img.example.com/feed.jpg", v["cover"]!.GetValue<string>());
        Assert.Equal(4, v["blocks"]!.AsArray().Count);

        var failed = Node(ReaderPage.View(Item, new PreparedArticle { Stage = Stage.Failed, Fallback = "요약 번역" }, model, book));
        Assert.Equal("failed", failed["phase"]!.GetValue<string>());
        Assert.Equal("요약 번역", failed["fallback"]!.GetValue<string>());
        Assert.True(failed["translatedPage"]!.GetValue<bool>());

        Assert.Equal("translating", ReaderPage.Phase(new PreparedArticle { Stage = Stage.Translating }));
    }

    [Fact]
    public void SpeechUsesVisibleLanguage()
    {
        var ko = ReaderPage.SpeechFor(Item, Done, showOriginal: false);
        Assert.Equal("ko-KR", ko.Language);
        Assert.Equal("OpenAI, GPT-6 공개\n\n새 모델이 나왔다.\n\n빠르다", ko.Text); // 코드·사진은 읽지 않음
        var en = ReaderPage.SpeechFor(Item, Done, showOriginal: true);
        Assert.Equal("en-US", en.Language);
        Assert.StartsWith("OpenAI launches GPT-6\n\nA new model is out.", en.Text);
    }

    [Fact]
    public async Task OpeningSendsArticleAndClosedStops()
    {
        Cache(Done);
        page.Opening(Item);
        var v = await Run("ready");
        Assert.Equal("done", v!["phase"]!.GetValue<string>());
        for (var i = 0; i < 50 && sent.Count == 0; i++) await Task.Delay(10);
        Assert.Contains(sent, m => m.Contains("\"event\":\"article\"") && m.Contains(Item.Key));

        Assert.True((await Run("speak"))!["speaking"]!.GetValue<bool>());
        Assert.Equal("ko-KR", platform.Spoken[0].Lang);
        Assert.True((await Run("speaking"))!["speaking"]!.GetValue<bool>());
        page.Closed(Item.Key);
        Assert.False(platform.Speaking);                         // 창을 닫으면 멈춤(R-09)
    }

    [Fact]
    public async Task ReadyFindsArticleWithoutOpening()
    {
        Cache(Done);
        var v = await Run("ready");                              // 앱이 Opening 을 부르지 않았어도 기사 찾기
        Assert.Equal(Item.Key, v!["key"]!.GetValue<string>());
        await Assert.ThrowsAsync<KeyNotFoundException>(() => page.Handle("ready", new JsonObject { ["key"] = "none|x" }));
    }

    [Fact]
    public async Task ScrapCommandsGoToScrapbook()
    {
        Cache(Done);
        page.Opening(Item);
        await Run("ready");

        // 번역문 문단 → 원문도 함께
        var r = await Run("scrapParagraph", new { index = 1, original = false });
        Assert.Equal("새 모델이 나왔다.", r!["quote"]!.GetValue<string>());
        var s = Assert.Single(book.Scraps);
        Assert.Equal("새 모델이 나왔다.", s.Quote);
        Assert.Equal("A new model is out.", s.QuoteOriginal);

        // 원문을 보며 스크랩하면 원문만
        await Run("scrapParagraph", new { index = 3, original = true });
        Assert.Contains(book.Scraps, x => x.Quote == "It is fast" && x.QuoteOriginal is null);

        // 고른 부분: 들어 있는 문단의 원문을 찾아 함께
        await Run("scrapSelection", new { quote = "모델이" });
        Assert.Contains(book.Scraps, x => x.Quote == "모델이" && x.QuoteOriginal == "A new model is out.");

        // 폴더·메모 바꾸기, 되돌리기
        book.CreateCollection("조사");
        await Run("updateScrap", new { quote = "새 모델이 나왔다.", collection = "조사", memo = "중요" });
        Assert.Contains(book.Scraps, x => x.Quote == "새 모델이 나왔다." && x.Collection == "조사" && x.Memo == "중요");
        await Run("removeScrap", new { quote = "모델이" });
        Assert.DoesNotContain(book.Scraps, x => x.Quote == "모델이");

        // 기사 스크랩: 마지막 폴더 / 고른 폴더 / 새 폴더
        var art = await Run("scrapArticle");
        Assert.Equal(book.LastCollection, art!["collection"]!.GetValue<string>());
        await Run("newCollection", new { name = " 읽을거리 " });
        Assert.Contains("읽을거리", book.Collections);
        Assert.Contains(book.Scraps, x => x.Quote is null && x.Collection == "읽을거리");

        var marks = await Run("marks");
        Assert.True(marks!["scrapped"]!.GetValue<bool>());
        Assert.Equal(2, marks["scraps"]!.AsArray().Count);           // 문단 스크랩만
    }

    [Fact]
    public async Task FontSizeClampsAndRemembers()
    {
        Cache(Done);
        Assert.Equal(26, (await Run("fontSize", new { size = 40 }))!["size"]!.GetValue<int>());
        Assert.Equal(26, ReaderPage.FontSize);
        Assert.Equal(13, (await Run("fontSize", new { size = 2 }))!["size"]!.GetValue<int>());
        Assert.Equal(13, ReaderPage.FontSize);
        Assert.Contains(sent, m => m.Contains("\"event\":\"fontSize\""));   // 열린 읽기 창 모두
    }

    [Fact]
    public async Task OutsideLinksAndSave()
    {
        Cache(Done);
        var opened = new List<string>();
        ExternalLink.Opener = u => { opened.Add(u.AbsoluteUri); return true; };
        await Run("translatedPage");
        await Run("openOriginal");
        Assert.Equal(["https://www-the--verge-com.translate.goog/ai/gpt-6?id=3&_x_tr_sl=auto&_x_tr_tl=ko&_x_tr_hl=ko", Item.Link], opened);

        Assert.True((await Run("save"))!["saved"]!.GetValue<bool>());
        Assert.True(model.IsSaved(Item));
        await Run("share");
        Assert.Single(platform.Shared);
        await Run("close");
        Assert.Equal(["reader:" + Item.Key], platform.Closed);
    }
}
