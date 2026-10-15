using System.Text.Json;
using System.Text.Json.Nodes;
using Dropcap.Ui;
using SkiaSharp;

namespace Dropcap.Core.Tests;

// 맥 따라잡기(읽기 창 3): 번역 표시(R-08 · 맥 e2e-fix) · 사진 도구(R-20) · 본문 다듬기(R-21) · 표지 사진(R-22)
public class ReaderCatchup3Tests : IDisposable
{
    private readonly TempDir tmp = new();
    private readonly Database db;
    private readonly AppModel model;
    private readonly Scrapbook book;
    private readonly ArticleService svc;
    private readonly ReaderPage page;

    private static readonly NewsItem Item = new()
    {
        Id = "1", Title = "Chip makers report record quarter", Link = "https://news.example.com/chips?id=7",
        SourceId = "ex", SourceName = "Example News", Tier = "press", Date = DateTimeOffset.UtcNow,
    };

    public ReaderCatchup3Tests()
    {
        db = new Database(Path.Combine(tmp.Path, "magazine.sqlite"));
        model = new AppModel(new FakeUi(), new Magazine(db), new AppState { Recent = [Item] }, persist: false) { ShowAllSourcesForTests = true };
        book = new Scrapbook(db);
        svc = new ArticleService(new NoExtract(), () => [], Path.Combine(tmp.Path, "articles"))
        {
            RecordExtract = (_, _, _) => { },
            Fetch = _ => Task.FromResult<(byte[], string?)?>(null),   // 바깥에 요청하지 않게
        };
        page = new ReaderPage(model, svc, book, new FakePlatform(), new Bridge(), new PaywallBook(db))
        {
            // 표지 고르기·사진 받기도 네트워크 없이
            ImageWidth = _ => Task.FromResult<int?>(null),
            OgImage = _ => Task.FromResult<string?>(null),
            ImageBytes = _ => Task.FromResult<byte[]?>(null),
        };
    }

    public void Dispose()
    {
        ImageText.Recognize = null;
        ImageText.Copy = null;
        ImageText.Save = null;
        db.Dispose();
        tmp.Dispose();
    }

    private sealed class NoExtract : IArticleExtractor
    {
        public Task<Article?> FromHtmlAsync(string html, Uri baseUri) => Task.FromResult<Article?>(null);
        public Task<Article?> FromLiveAsync(Uri url) => Task.FromResult<Article?>(null);
    }

    private sealed class FakePlatform : IPlatform
    {
        public bool Speaking => false;
        public void Speak(string text, string language) { }
        public void StopSpeaking() { }
        public void Share(NewsItem item) { }
        public void CopyText(string text) { }
        public void CloseWindow(string page) { }
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

    private static JsonObject Node(object o) => (JsonObject)JsonSerializer.SerializeToNode(o, Json.Options)!;

    private async Task<JsonObject?> Run(string cmd, object args)
    {
        var a = Node(args);
        a["key"] ??= Item.Key;
        var r = await page.Handle(cmd, a);
        return r is null ? null : Node(r);
    }

    private static Block P(string t) => new() { Type = BlockKind.P, Text = t };
    private static Block Img(string src) => new() { Type = BlockKind.Img, Src = src };
    private static Block Cap(string t) => new() { Type = BlockKind.Cap, Text = t };

    // 한 가지 색으로 칠한 사진(위쪽 절반만 다른 색으로 칠할 수 있게)
    private static byte[] Picture(int w, int h, SKColor color, SKColor? top = null)
    {
        using var bmp = new SKBitmap(w, h);
        using (var c = new SKCanvas(bmp))
        {
            c.Clear(color);
            if (top is { } t) using (var paint = new SKPaint { Color = t }) c.DrawRect(0, 0, w, h / 2f, paint);
        }
        using var img = SKImage.FromBitmap(bmp);
        using var enc = img.Encode(SKEncodedImageFormat.Png, 100);
        return enc.ToArray();
    }

    // MARK: R-08 번역 표시

    [Fact]
    public void EngineLabelOnlyWhenParagraphsChanged()
    {
        Assert.Equal("", ArticleService.EngineLabel(0, 5, Translator.EngineGoogle));          // 번역 실패·오프라인: 표시 없음
        Assert.Equal("Google 번역 · 일부 번역", ArticleService.EngineLabel(2, 5, Translator.EngineGoogle));
        Assert.Equal("Google 번역", ArticleService.EngineLabel(5, 5, Translator.EngineGoogle));
    }

    [Fact]
    public void UntranslatedParagraphsStayOriginal()
    {
        var src = new List<Block> { P("The first paragraph."), P("이미 한국어 문단입니다."), P("A paragraph that failed."), P("Third one.") };
        var blocks = src.ToList();
        // 둘째는 한국어(세지 않음), 셋째는 번역이 실패해 원문 그대로 돌아옴
        var (done, total) = ArticleService.MergeTranslated(blocks, src, [0, 1, 2, 3], ["첫 문단.", "이미 한국어 문단입니다.", "A paragraph that failed.", "셋째."]);
        Assert.Equal((2, 3), (done, total));
        Assert.Equal("첫 문단.", blocks[0].Text);
        Assert.Equal("The first paragraph.", blocks[0].Original);
        Assert.Null(blocks[1].Original);
        Assert.Null(blocks[2].Original);                      // 원문 보기 대상이 아님
        Assert.Equal("A paragraph that failed.", blocks[2].Text);
        Assert.Equal("Third one.", blocks[3].Original);
        Assert.Equal("Google 번역 · 일부 번역", ArticleService.EngineLabel(done, total, Translator.EngineGoogle));

        // 모두 실패: 바뀐 문단 없음
        var again = src.ToList();
        Assert.Equal((0, 3), ArticleService.MergeTranslated(again, src, [0, 1, 2, 3], src.Select(b => b.Text!).ToList()));
        Assert.All(again, b => Assert.Null(b.Original));
    }

    // MARK: R-21 본문 다듬기

    [Fact]
    public void HiddenBlocksLikeMac()
    {
        var blocks = new List<Block>
        {
            Img("https://img.example.com/2026/chipfactory-1024x576.jpg"), // 0 표지와 같은 사진(크기 표기만 다름)
            Cap("공장 내부 모습"),                                    // 1 그 설명
            P("홍길동 기자 desk@example.com"),                        // 2 기자 줄 → 바이라인
            P("본문 첫 문단입니다. 반도체 업계가 좋은 실적을 냈다."),   // 3
            Img("https://img.example.com/2026/chipfactory.jpg"),       // 4 같은 사진이 또 나와도 처음 한 번만 뺌(맥과 같음)
            Img("https://img.example.com/reporter/profile.png"),      // 5 잡그림(기자 프로필)
            Cap("기자 사진"),                                          // 6 뺀 잡그림의 설명
            P("사진=연합뉴스"),                                        // 7 사진 없이 남은 설명 줄
            Img("https://img.example.com/2026/graph.jpg"),            // 8 다른 사진
            Cap("분기별 매출"),                                        // 9 그 설명은 남김
        };
        var hidden = BodyCleanup.Hidden(blocks, "https://img.example.com/2026/chipfactory.jpg");
        // 7 은 바로 뒤가 사진이라 그 사진의 설명 — 남김. 4(같은 사진 두 번째)·9(남은 사진의 설명)도 남김
        Assert.Equal(new HashSet<int> { 0, 1, 2, 5, 6 }, hidden);

        // 바로 뒤가 사진이 아닌 짧은 설명 줄은 뺀다
        Assert.Contains(1, BodyCleanup.Hidden([P("본문 문단입니다. 충분히 깁니다."), P("사진=연합뉴스"), P("다음 문단")], null));
        Assert.Equal("홍길동 기자", BodyCleanup.Analyze(blocks).Byline);
    }

    [Fact]
    public void ViewDropsCoverDuplicateAndItsCaption()
    {
        var a = new PreparedArticle
        {
            Stage = Stage.Done, Title = "칩 업계 최고 분기", OriginalTitle = Item.Title,
            Blocks = [Img("https://img.example.com/a/semiconductor-800x450.jpg"), Cap("공장 내부"), P("본문 문단입니다. 반도체 업계가 좋은 실적을 냈다.")],
        };
        var v = Node(ReaderPage.View(Item with { Image = "https://img.example.com/a/semiconductor.jpg" }, a, model, book));
        var types = v["blocks"]!.AsArray().Select(b => b!["type"]!.GetValue<string>()).ToList();
        Assert.Equal(new[] { "p" }, types);
    }

    // MARK: R-22 표지 사진

    private static Func<string, Task<int?>> Widths(Dictionary<string, int> w) => u => Task.FromResult<int?>(w.TryGetValue(u, out var x) ? x : null);
    private static Func<string, Task<string?>> Og(string? og) => _ => Task.FromResult(og);

    [Fact]
    public async Task CoverPickRules()
    {
        const string feed = "https://img.example.com/feed.jpg", og = "https://img.example.com/og.jpg", link = "https://news.example.com/a";
        // 피드 사진이 넉넉하면 그대로(머리를 찾지 않음)
        Assert.Equal(feed, await CoverPick.FindAsync(feed, link, Widths(new() { [feed] = 1200 }), _ => throw new InvalidOperationException()));
        // 작은 미리보기(280px) → 큰 머리 사진으로
        Assert.Equal(og, await CoverPick.FindAsync(feed, link, Widths(new() { [feed] = 280, [og] = 1200 }), Og(og)));
        // 머리 사진도 작으면 피드 사진 그대로
        Assert.Equal(feed, await CoverPick.FindAsync(feed, link, Widths(new() { [feed] = 280, [og] = 300 }), Og(og)));
        // 피드 사진을 못 받으면 머리 사진(작아도)
        Assert.Equal(og, await CoverPick.FindAsync(feed, link, Widths(new() { [og] = 300 }), Og(og)));
        // 대신할 것도 없으면 깨진 자리를 지움
        Assert.Null(await CoverPick.FindAsync(feed, link, Widths(new()), Og(null)));
        Assert.Null(await CoverPick.FindAsync(feed, link, Widths(new()), Og(feed)));                     // 같은 주소는 대신이 아님
        Assert.Null(await CoverPick.FindAsync(feed, link, Widths(new() { ["https://img.example.com/logo.png"] = 900 }), Og("https://img.example.com/logo.png"))); // 잡그림
        // 피드·매거진 사진이 없으면 머리 사진
        Assert.Equal(og, await CoverPick.FindAsync(null, link, Widths(new() { [og] = 500 }), Og(og)));
        Assert.Null(await CoverPick.FindAsync(null, "", Widths(new()), Og(og)));
        // 피드 사진 → 매거진 기록 순, 잡그림은 건너뜀
        Assert.Equal("https://img.example.com/stored.jpg", CoverPick.Known("https://img.example.com/avatar/x.png", "https://img.example.com/stored.jpg"));
        Assert.True(CoverPick.BigEnough(400));
        Assert.False(CoverPick.BigEnough(399));
        Assert.False(CoverPick.BigEnough(null));
    }

    [Fact]
    public void OgImageReadsMetaOneByOne()
    {
        // og:image:type 을 주소로 잡지 않고, 속성 순서는 어느 쪽이든
        var html = """<head><meta property="og:image:type" content="image/jpeg"><meta content="/img/cover.jpg?w=1200&amp;h=630" property="og:image"></head>""";
        Assert.Equal("https://news.example.com/img/cover.jpg?w=1200&h=630", CoverPick.OgImage(html, "https://news.example.com/a"));
        Assert.Equal("https://news.example.com/s.jpg", CoverPick.OgImage("""<meta property="og:image:secure_url" content="https://news.example.com/s.jpg">""", "https://news.example.com/a"));
        Assert.Equal("https://news.example.com/t.jpg", CoverPick.OgImage("""<meta name="twitter:image" content="https://news.example.com/t.jpg">""", "https://news.example.com/a"));
        Assert.Null(CoverPick.OgImage("""<meta property="og:image" content="javascript:alert(1)">""", "https://news.example.com/a"));
        Assert.Null(CoverPick.OgImage("<head></head>", "https://news.example.com/a"));
    }

    [Fact]
    public void ViewUsesPickedCover()
    {
        var a = new PreparedArticle { Stage = Stage.Done, Title = "칩", OriginalTitle = Item.Title, Blocks = [Img("https://img.example.com/body.jpg"), P("본문 문단입니다. 충분히 깁니다.")] };
        var it = Item with { Image = "https://img.example.com/thumb.jpg" };
        // 고르기 전: 피드 사진
        Assert.Equal("https://img.example.com/thumb.jpg", Node(ReaderPage.View(it, a, model, book))["cover"]!.GetValue<string>());
        // 머리 사진으로 바꿈
        Assert.Equal("https://img.example.com/og.jpg", Node(ReaderPage.View(it, a, model, book, null, (true, "https://img.example.com/og.jpg")))["cover"]!.GetValue<string>());
        // 깨진 피드 사진을 지우면 본문 첫 사진이 표지(본문에서는 빠짐)
        var v = Node(ReaderPage.View(it, a, model, book, null, (true, null)));
        Assert.Equal("https://img.example.com/body.jpg", v["cover"]!.GetValue<string>());
        Assert.DoesNotContain(v["blocks"]!.AsArray(), b => b!["type"]!.GetValue<string>() == "img");
    }

    // MARK: R-20 기사 속 사진 도구

    [Fact]
    public void SuggestedNameLikeMac()
    {
        Assert.Equal("chip-photo.png", ImageText.SuggestedName("https://img.example.com/2026/chip-photo.jpg?w=800"));
        Assert.Equal("image.png", ImageText.SuggestedName("https://img.example.com/"));
        Assert.Equal("image.png", ImageText.SuggestedName("https://img.example.com/" + new string('a', 90) + ".jpg"));
        Assert.Equal("공장 사진.png", ImageText.SuggestedName("https://img.example.com/%EA%B3%B5%EC%9E%A5%20%EC%82%AC%EC%A7%84.jpg"));
        Assert.DoesNotContain(':', ImageText.SuggestedName("https://img.example.com/a%3Ab.jpg"));
    }

    [Fact]
    public void EncodeByChosenExtension()
    {
        var png = Picture(20, 10, SKColors.Red);
        var jpg = ImageText.Encode(png, ".jpg")!;
        Assert.Equal(0xFF, jpg[0]);                                  // JPEG
        Assert.Equal(0xD8, jpg[1]);
        Assert.Equal(0x89, ImageText.Encode(jpg, ".png")![0]);       // PNG
        Assert.Null(ImageText.Encode([1, 2, 3], ".png"));
    }

    [Fact]
    public void BackgroundFromBandsAroundText()
    {
        // 위쪽 절반은 흰색, 아래는 남색. 아래쪽 가운데 글자 줄의 바탕은 남색(어두움 → 흰 글자)
        using var bmp = SKBitmap.Decode(Picture(200, 100, new SKColor(20, 30, 90), SKColors.White));
        var (color, light) = ImageText.Background(bmp, new ImageText.Line("TEXT", 0.2, 0.7, 0.5, 0.1));
        Assert.Equal("#141e5a", color);
        Assert.False(light);
        var (c2, l2) = ImageText.Background(bmp, new ImageText.Line("TEXT", 0.2, 0.15, 0.5, 0.1));
        Assert.Equal("#ffffff", c2);
        Assert.True(l2);
    }

    [Fact]
    public async Task TranslatesOnlyForeignLines()
    {
        var sent = new List<string>();
        Task<List<string>> Fake(IReadOnlyList<string> t) { sent.AddRange(t); return Task.FromResult(t.Select(x => "번역:" + x).ToList()); }
        var (o, korean) = await ImageText.TranslateAsync(["SALES UP", "매출 증가", "Q3 2026"], Fake);
        Assert.False(korean);
        Assert.Equal(new string?[] { "번역:SALES UP", null, "번역:Q3 2026" }, o);
        Assert.Equal(new[] { "SALES UP", "Q3 2026" }, sent);
        var (o2, k2) = await ImageText.TranslateAsync(["매출 증가"], Fake);
        Assert.True(k2);                                             // 이미 한국어 글자
        Assert.Equal(new string?[] { null }, o2);
    }

    [Fact]
    public async Task ImageCommandsOnlyForArticleImages()
    {
        const string src = "https://img.example.com/2026/chart.jpg";
        File.WriteAllText(svc.FileFor(Item.Link), Json.Encode(new PreparedArticle
        {
            Stage = Stage.Done, Title = "칩", OriginalTitle = Item.Title, Blocks = [P("본문 문단입니다. 충분히 깁니다."), Img(src)],
        }));
        var pic = Picture(100, 100, SKColors.White);
        var asked = new List<string>();
        page.ImageBytes = u => { asked.Add(u); return Task.FromResult<byte[]?>(pic); };
        ImageText.Recognize = _ => Task.FromResult<IReadOnlyList<ImageText.Line>>([new ImageText.Line("SALES UP", 0.1, 0.4, 0.5, 0.2)]);
        byte[]? copied = null;
        ImageText.Copy = b => copied = b;
        string? named = null;
        ImageText.Save = (name, encode) => { named = name; return Task.FromResult(encode(".png") is not null); };

        var r = await Run("imageText", new { src });
        var line = r!["lines"]!.AsArray().Single()!;
        Assert.Equal("SALES UP", line["text"]!.GetValue<string>());
        Assert.Equal(0.4, line["y"]!.GetValue<double>());
        Assert.Equal("#ffffff", line["bg"]!.GetValue<string>());
        Assert.True(line["light"]!.GetValue<bool>());

        // 이 기사에 없는 사진 주소는 받지 않는다
        var other = await Run("imageText", new { src = "https://elsewhere.example/x.jpg" });
        Assert.Empty(other!["lines"]!.AsArray());
        Assert.DoesNotContain("https://elsewhere.example/x.jpg", asked);

        Assert.True((await Run("imageCopy", new { src }))!["ok"]!.GetValue<bool>());
        Assert.Same(pic, copied);
        Assert.True((await Run("imageSave", new { src }))!["ok"]!.GetValue<bool>());
        Assert.Equal("chart.png", named);

        var t = await Run("imageTranslate", new { texts = new[] { "이미 한국어" } });
        Assert.True(t!["korean"]!.GetValue<bool>());

        // 글자 인식이 없으면(운영체제가 못 함) 글자를 찾지 못한 것으로
        ImageText.Recognize = null;
        Assert.Empty((await Run("imageText", new { src }))!["lines"]!.AsArray());
    }

    [Fact]
    public async Task OpeningPicksCoverAndSendsIt()
    {
        var sent = new List<string>();
        var bridge = new Bridge();
        var p = new ReaderPage(model, svc, book, new FakePlatform(), bridge, new PaywallBook(db))
        {
            ImageWidth = u => Task.FromResult<int?>(u.Contains("thumb") ? 280 : 1200),
            OgImage = _ => Task.FromResult<string?>("https://img.example.com/og-big.jpg"),
        };
        bridge.Register(p);
        bridge.Attach("reader", sent.Add);
        p.Opening(Item with { Image = "https://img.example.com/thumb.jpg" });
        for (var i = 0; i < 100 && !sent.Any(m => m.Contains("og-big.jpg")); i++) await Task.Delay(10);
        Assert.Contains(sent, m => m.Contains("\"cover\":\"https://img.example.com/og-big.jpg\""));
        var v = await p.Handle("view", new JsonObject { ["key"] = Item.Key });
        Assert.Equal("https://img.example.com/og-big.jpg", Node(v!)["cover"]!.GetValue<string>());
        p.Closed(Item.Key);
    }
}
