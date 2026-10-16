using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Dropcap.Ui;

namespace Dropcap.Core.Tests;

// 읽기 창 본문 잘림·군더더기(mac/READER-CUT.md 2단계를 윈도우에). 맥 ReaderCutTests 와 같은 꼴.
// 고정 HTML 은 실제 사이트의 꼴만 본뜬 것이고 글은 지어낸 것(맥 Fixtures/reader-cut 을 그대로 씀).

// 추출 스크립트(web/extract.js)를 머리 없는 Chromium(WebView2 와 같은 엔진)에서 돌리는 시험은
// DROPCAP_PLAYWRIGHT(playwright-core 폴더)가 있을 때만 — windows/scripts/test-extract.sh 가 마련해 준다
public sealed class JsFactAttribute : FactAttribute
{
    public JsFactAttribute() { if (!ExtractJs.Available) Skip = "DROPCAP_PLAYWRIGHT 가 있을 때만(windows/scripts/test-extract.sh)"; }
}

public sealed class JsTheoryAttribute : TheoryAttribute
{
    public JsTheoryAttribute() { if (!ExtractJs.Available) Skip = "DROPCAP_PLAYWRIGHT 가 있을 때만(windows/scripts/test-extract.sh)"; }
}

public static class ExtractJs
{
    public static bool Available => Environment.GetEnvironmentVariable("DROPCAP_PLAYWRIGHT") is { Length: > 0 } p && Directory.Exists(p);

    // 저장소 뿌리(이 파일 위치에서 올라감)
    public static string Root([System.Runtime.CompilerServices.CallerFilePath] string here = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(here)!, "..", ".."));

    public static async Task<List<Article?>> RunAsync(params (string Html, string Base)[] cases)
    {
        var raw = await RawAsync(probe: false, cases);
        return raw.Select(r => r is null ? null : Json.Decode<Article>(r)).ToList();
    }

    // 격리 칸 CSP 없이 추출하는 동안 나간 바깥 요청 수·onerror 실행(보안 점검 X2 — 스크립트 스스로의 한 겹 방어)
    public static async Task<(int Requests, string? OnError)> ProbeAsync(string html, string @base = ReaderCutText.Base)
    {
        var r = (await RawAsync(probe: true, (html, @base)))[0]!;
        using var d = JsonDocument.Parse(r);
        var e = d.RootElement.GetProperty("onerror");
        return (d.RootElement.GetProperty("requests").GetInt32(), e.ValueKind == JsonValueKind.Null ? null : e.ToString());
    }

    private static async Task<List<string?>> RawAsync(bool probe, params (string Html, string Base)[] cases)
    {
        var root = Root();
        var input = JsonSerializer.Serialize(new
        {
            readability = File.ReadAllText(Path.Combine(root, "mac", "Resources", "Readability.js")),
            extract = File.ReadAllText(Path.Combine(root, "windows", "Dropcap.Ui", "web", "extract.js")),
            cases = cases.Select(c => new { html = c.Html, @base = c.Base }),
            probe,
        });
        var psi = new ProcessStartInfo("node", Path.Combine(root, "windows", "Dropcap.Core.Tests", "js", "extract-runner.mjs"))
        {
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false,
            StandardInputEncoding = new UTF8Encoding(false), StandardOutputEncoding = Encoding.UTF8,
        };
        using var p = Process.Start(psi)!;
        await p.StandardInput.WriteAsync(input);
        p.StandardInput.Close();
        var outTask = p.StandardOutput.ReadToEndAsync();
        var errTask = p.StandardError.ReadToEndAsync();
        await p.WaitForExitAsync();
        var (stdout, stderr) = (await outTask, await errTask);
        if (p.ExitCode != 0) throw new InvalidOperationException("추출 도우미 실패: " + stderr);
        return JsonSerializer.Deserialize<List<string?>>(stdout) ?? new();
    }

    public static async Task<Article?> OneAsync(string html, string @base = ReaderCutText.Base) => (await RunAsync((html, @base)))[0];
}

public static class ReaderCutText
{
    public const string Base = "https://example.com/2026/10/story";
    public static string Para(int n, string topic = "city budget") =>
        $"Paragraph {n} explains how the {topic} committee reviewed the plan, heard from residents and agreed to publish a timeline.";
    public static string KPara(int n) =>
        $"{n}번째 문단에서는 시 예산 위원회가 계획을 검토하고 주민 의견을 들은 뒤 일정표를 공개하기로 한 과정을 설명한다.";
    public static List<string> Texts(Article? a) => a?.Blocks.Select(b => b.Text).OfType<string>().ToList() ?? new();
    // 실제 페이지의 꼴만 남기고 글·주소를 바꾼 것(mac/scripts/scramble_fixture.py). 리드·끝 문단 앞에 LEDESTART·BODYEND 표지
    public static string Fixture(string name) =>
        File.ReadAllText(Path.Combine(ExtractJs.Root(), "mac", "Tests", "DropcapTests", "Fixtures", "reader-cut", name + ".html"));
}

public class ReaderCutExtractTests
{
    private static string Para(int n, string topic = "city budget") => ReaderCutText.Para(n, topic);
    private static string KPara(int n) => ReaderCutText.KPara(n);
    private static List<string> Texts(Article? a) => ReaderCutText.Texts(a);

    // A: 광고 칸을 사이에 둔 본문 덩어리 두 개(Ars .post-content 꼴) — 둘 다 와야 하고, 기자 소개 상자·댓글 수는 빠져야
    [JsFact]
    public async Task SplitBodyMerged()
    {
        var first = string.Concat(Enumerable.Range(1, 3).Select(n => $"<p>{Para(n)}</p>"));
        var second = string.Concat(Enumerable.Range(4, 6).Select(n => $"<p>{Para(n)}</p>"));
        var html = $"""
        <html><head><title>Story</title></head><body><header><nav><a href="/">Home</a> <a href="/science">Science</a></nav></header>
        <main><article><h1>Story</h1><div class="grid"><div class="col">
        <div class="post-content post-content-double">{first}</div>
        <div class="ad-wrapper"><div class="ad ad--mid">Advertisement</div></div>
        <div class="post-content post-content-double">{second}</div>
        <div class="author-mini-bio"><a href="https://news.example.com/author/pat/"><img src="https://cdn.example.com/uploads/2018/08/pic300.jpg"></a>
        <div>Pat Example <span>Senior Writer</span></div><div itemprop="description">Pat is a senior writer at Example News with a particular focus on science and culture.</div></div>
        <div class="story-tools"><a class="view-comments" href="#comments">42 Comments</a></div>
        </div><div class="rail"><div class="ad-wrapper is-rail"></div></div></div></article></main>
        <footer><p>Example News is part of a media group. All rights reserved worldwide since forever and ever.</p></footer></body></html>
        """;
        var t = Texts(await ExtractJs.OneAsync(html));
        Assert.Contains(Para(1), t);
        Assert.Contains(Para(9), t);
        Assert.DoesNotContain(t, x => x.Contains("senior writer at Example"));
        Assert.DoesNotContain(t, x => x.Contains("Comments"));
    }

    // 보안 점검 2 X1: 형제 상자 안에 본문 상자와 같은 class 가 N겹 — 겹마다 하위 전체를 복사해 N²(800겹 80초) → 바깥 상자만
    [JsFact]
    public async Task NestedCoreClassGatheredOnce()
    {
        var body = string.Concat(Enumerable.Range(1, 6).Select(n => $"<p>{Para(n)}</p>"));
        var html = $"<html><head><title>t</title></head><body><article><div class=\"x\">{body}</div><section class=\"y\">"
                   + string.Concat(Enumerable.Range(0, 800).Select(i => $"<div class=\"x\"><span>w{i} word word word</span>"))
                   + $"<p>{Para(7)}</p>" + string.Concat(Enumerable.Repeat("</div>", 800)) + "</section></article></body></html>";
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var t = Texts(await ExtractJs.OneAsync(html));
        Assert.True(sw.Elapsed < TimeSpan.FromSeconds(10), $"{sw.Elapsed}");
        Assert.Contains(Para(1), t);
        Assert.Single(t, x => x.Contains(Para(7)));
    }

    // A: data-component 블록이 줄지어 선 꼴(BBC) — 앞 덩어리(리드)와 사진 뒤 덩어리 모두, 관련 링크 블록은 빼고
    [JsFact]
    public async Task ComponentBlocksMerged()
    {
        string Text(int from, int to) => string.Concat(Enumerable.Range(from, to - from + 1).Select(n =>
            $"<div data-component=\"text-block\" class=\"ssr-tb\"><p class=\"ssr-p\">{Para(n, "river")}</p></div>"));
        var html = $"""
        <html><head><title>River</title></head><body><div id="main-wrapper"><main><article>
        <div data-component="headline-block" class="ssr-h"><h1>River</h1></div>
        <div data-component="byline-block" class="ssr-b"><span>By Sam Example</span></div>
        {Text(1, 2)}
        <div data-component="image-block" class="ssr-ib"><figure><img src="https://ichef.example.com/news/976/photo-a.jpg"><figcaption>A river at dawn</figcaption></figure></div>
        {Text(3, 4)}
        <div data-component="image-block" class="ssr-ib"><figure><img src="https://ichef.example.com/news/976/photo-b.jpg"><figcaption>A boat</figcaption></figure></div>
        {Text(5, 9)}
        <div data-component="links-block" class="ssr-l"><h2>More on this story</h2><ul><li><a href="/a">Another story about something else entirely</a></li></ul></div>
        </article></main></div></body></html>
        """;
        var a = await ExtractJs.OneAsync(html);
        var t = Texts(a);
        Assert.Contains(Para(1, "river"), t);
        Assert.Contains(Para(9, "river"), t);
        Assert.DoesNotContain(t, x => x.Contains("Another story"));
        Assert.True((a?.Blocks.Count(b => b.Type == BlockKind.Img) ?? 0) >= 1);
    }

    // 실제 꼴(글은 바꿈): Ars 본문 두 덩어리 · BBC data-component 줄 · 매경 본문 대 AI 상자 · 동아 맨 글자+<br><br>
    [JsTheory]
    [InlineData("split-post-content", "BODYEND")]
    [InlineData("component-blocks", "BODYEND")]
    [InlineData("articlebody-vs-widget", "BODYMID")]
    [InlineData("bare-text-br", "BODYEND")]
    public async Task RealShapes(string name, string end)
    {
        var a = await ExtractJs.OneAsync(ReaderCutText.Fixture(name));
        var t = Texts(a);
        Assert.True(t.Any(x => x.Contains("LEDESTART")), name + ": 리드");
        Assert.True(t.Any(x => x.Contains(end)), name + ": 끝");
        Assert.False(t.Any(x => x.Contains("LEDESTART") && x.Contains(end)), name + ": 한 덩어리로 붙음");
        if (name == "component-blocks") Assert.True((a?.Blocks.Count(b => b.Type == BlockKind.Img) ?? 0) >= 10, "BBC 사진 블록");
    }

    // B: 본문은 itemprop=articleBody 안 맨 글자(<br>로 나눔), 옆에는 문단이 많은 'AI 요약' 상자(매경 꼴) — 본문을 골라야
    [JsFact]
    public async Task ArticleBodyPreferred()
    {
        var body = string.Join("<br><br>", Enumerable.Range(1, 6).Select(KPara));
        var widget = string.Concat(Enumerable.Range(1, 5).Select(n => $"<p class=\"ai-txt\">AI 해설 {n}: 이 종목은 최근 거래량이 늘었고 외국인 매수가 이어졌으며 기관은 관망하는 흐름을 보였다는 분석이 나왔다.</p>"));
        var html = $"""
        <html><head><title>증시</title></head><body><div class="news_detail_wrap"><h2 class="news_ttl">증시</h2>
        <div class="news_cnt_detail_wrap" itemprop="articleBody">{body}</div>
        <div class="ai_box"><h3>기사 속 종목 이야기</h3>{widget}<p>주의사항 : 본 서비스는 AI의 구조적 한계로 인해 오류가 발생할 수 있습니다.</p></div>
        </div></body></html>
        """;
        var t = Texts(await ExtractJs.OneAsync(html));
        Assert.Contains(t, x => x.Contains(KPara(1)[..20]));
        Assert.Contains(t, x => x.Contains(KPara(6)[..20]));
        Assert.DoesNotContain(t, x => x.StartsWith("AI 해설"));
    }

    // 동아 꼴: 맨 글자 문단이 <br><br> 와 광고 div 사이에 — 리드를 버리지 않아야
    [JsFact]
    public async Task BareTextParagraphs()
    {
        var html = $"""
        <html><head><title>사회</title></head><body><section class="news_view"><div class="article_txt">
        {KPara(1)}<br><br>{KPara(2)}
        <div class="adwrap"><div class="ad">광고</div></div>
        {KPara(3)}<br><br><strong>◇ 소제목</strong><br><br>{KPara(4)}<br><br>{KPara(5)}
        <figure><img src="https://image.example.com/photo.jpg"><figcaption>사진 설명</figcaption></figure>
        {KPara(6)}</div></section></body></html>
        """;
        var t = Texts(await ExtractJs.OneAsync(html));
        for (var n = 1; n <= 6; n++) Assert.True(t.Any(x => x.Contains(KPara(n)[..15])), $"문단 {n}");
        Assert.DoesNotContain(t, x => x.Contains(KPara(1)) && x.Contains(KPara(2)));   // 두 문단이 한 덩어리로 붙지 않게
    }

    // C: ld+json isAccessibleForFree=false 와 한경 articlePayment="Y" 를 기사에 표시
    [JsFact]
    public async Task PaidFlags()
    {
        var paras = string.Concat(Enumerable.Range(1, 4).Select(n => $"<p>{Para(n)}</p>"));
        var ld = $$"""
        <html><head><title>Deal</title><script type="application/ld+json">{"@type":"NewsArticle","isAccessibleForFree":false}</script></head>
        <body><article>{{paras}}<p>Subscribe</p></article></body></html>
        """;
        var hk = $"<html><head><title>증권</title><script>var articlePayment = \"Y\";</script></head><body><div id=\"articletxt\">{string.Concat(Enumerable.Range(1, 4).Select(n => $"<p>{KPara(n)}</p>"))}</div></body></html>";
        var free = $"<html><head><title>Free</title></head><body><article>{paras}</article></body></html>";
        var r = await ExtractJs.RunAsync((ld, ReaderCutText.Base), (hk, ReaderCutText.Base), (free, ReaderCutText.Base));
        Assert.True(r[0]?.Paid);
        Assert.True(r[1]?.Paid);
        Assert.NotEqual(true, r[2]?.Paid);
    }

    // 연합 [속보] 꼴: 기사는 사진+설명뿐, 페이지에는 메뉴 목록 — 메뉴를 본문으로 내지 말고 실패(글 없음)로
    [JsFact]
    public async Task PhotoOnlyIsNoText()
    {
        var menu = string.Concat(Enumerable.Range(1, 40).Select(n => $"<li><a href=\"/c{n}\">분야 메뉴 {n}</a></li>"));
        var html = $"""
        <html><head><title>[속보] 제목</title></head><body><nav><ul>{menu}</ul></nav>
        <article class="story-news"><figure><img src="https://img.example.com/flash.jpg"><figcaption>[속보] 사진 설명 한 줄</figcaption></figure></article>
        <footer><ul>{menu}</ul></footer></body></html>
        """;
        var a = await ExtractJs.OneAsync(html);
        Assert.False(a is { LooksLikeArticle: true });   // ArticleExtraction 은 본문으로 보지 않음 → 실패 화면
        Assert.DoesNotContain(Texts(a), x => x.StartsWith("분야 메뉴"));
    }

    // 화면 크기별로 기사를 세 벌 싣는 페이지(Politico 꼴) — 모아도 한 벌만
    [JsFact]
    public async Task LayoutCopiesOnce()
    {
        var story = "<div class=\"story-text\">" + string.Concat(Enumerable.Range(1, 4).Select(n => $"<p>{Para(n, "senate")}</p>")) + "</div>";
        var html = $"<html><head><title>S</title></head><body><main><div class=\"layout\"><section class=\"story-wrap desktop\">{story}</section><section class=\"story-wrap tablet\">{story}</section><section class=\"story-wrap mobile\">{story}</section></div></main></body></html>";
        var t = Texts(await ExtractJs.OneAsync(html));
        Assert.Single(t, x => x == Para(1, "senate"));
        Assert.Contains(Para(4, "senate"), t);
    }

    // 번역 인계: 각주 sup 번호는 낱말에 붙지 않고, <br> 은 빈칸, 사진 단추 글은 빠짐, 퍼가기 iframe 줄은 군더더기 규칙이 뺌
    [JsFact]
    public async Task FootnotesBreaksButtons()
    {
        var html = $"""
        <html><head><title>Notes</title></head><body><article>
        <p>{Para(1)}<sup><a href="#fn1">1</a></sup> More text follows here after the footnote marker in this sentence.</p>
        <p>Contact office<br>Room 12<br>Main street, and more words so that this paragraph is long enough to keep.</p>
        <figure><img src="https://img.example.com/a.jpg"><figcaption>A crowd gathers <b class="hide-caption">hide caption</b></figcaption></figure>
        {string.Concat(Enumerable.Range(2, 4).Select(n => $"<p>{Para(n)}</p>"))}</article></body></html>
        """;
        var t = Texts(await ExtractJs.OneAsync(html));
        Assert.Contains(t, x => x.StartsWith(Para(1) + " More text"));
        Assert.Contains(t, x => x.StartsWith("Contact office Room 12 Main street"));
        Assert.DoesNotContain(t, x => x.Contains("hide caption", StringComparison.OrdinalIgnoreCase));
    }
}

public class ReaderCutRuleTests : IDisposable
{
    private readonly TempDir tmp = new();
    public void Dispose() => tmp.Dispose();

    private static Block P(string s) => new() { Type = BlockKind.P, Text = s };
    private static Block Li(string s) => new() { Type = BlockKind.Li, Text = s };
    private static string Para(int n) => ReaderCutText.Para(n);

    // C: 맛보기 판정 — 지금(문구·1,500자)에 더해 isAccessibleForFree=false + 짧은 본문, 하드 유료 + 짧은 본문, 강한 문구는 길이와 무관
    [Fact]
    public void Teaser()
    {
        var shortB = Enumerable.Range(1, 8).Select(n => P(Para(n))).ToList();    // 약 1,000자
        var longB = Enumerable.Range(1, 30).Select(n => P(Para(n))).ToList();    // 약 3,800자
        Assert.False(Paywall.IsTeaser(shortB, paid: null, kind: null));
        Assert.True(Paywall.IsTeaser(shortB, paid: true, kind: null));
        Assert.False(Paywall.IsTeaser(longB, paid: true, kind: null));          // 무료 건수 제한 사이트가 전문을 준 경우(Verge)
        Assert.True(Paywall.IsTeaser(shortB, paid: null, kind: PaywallKind.Hard));
        Assert.False(Paywall.IsTeaser(shortB, paid: null, kind: PaywallKind.Metered));
        Assert.True(Paywall.IsTeaser([.. longB, P("This article is exclusive to STAT+ subscribers. Unlock this article by subscribing.")], paid: null, kind: null));
        Assert.True(Paywall.IsTeaser([.. shortB, P("한경 프리미엄9의 모든 콘텐츠는 한국경제신문의 저작물로 저작권법의 보호를 받습니다.")], paid: null, kind: null));
    }

    // 빠른 길(스크립트를 돌리지 않음)에서도 받은 HTML 에서 유료 표시를 읽는다
    [Fact]
    public void PaidFlagFromHtml()
    {
        Assert.True(ArticleExtraction.PaidFlag("""<script type="application/ld+json">{"isAccessibleForFree": "False"}</script>"""));
        Assert.False(ArticleExtraction.PaidFlag("""<script type="application/ld+json">{"isAccessibleForFree":true}</script>"""));
        Assert.True(ArticleExtraction.PaidFlag("<script>var articlePayment = 'Y';</script>"));
        Assert.Null(ArticleExtraction.PaidFlag("<p>free</p>"));
    }

    // 군더더기: 줄 단위 규칙과 끝부분 자르기, 본문을 지우지 않는 안전장치
    [Fact]
    public void JunkLines()
    {
        var body = Enumerable.Range(1, 8).Select(n => P(Para(n)));
        List<Block> blocks = [P("Pat Example"), P("is a news writer who covers streaming, consumer tech and social media."), .. body,
            P("reporter@example.co.kr"), P("좋아요 3 슬퍼요 0 화나요 1"), P("입력 2026.10.14 11:42 수정 2026.10.14 11:45"),
            P("Follow topics and authors from this story to see more like this in your personalized homepage feed."),
            P("Email (required)"), P("42 Comments"), P("Your browser does not support the audio element."),
            Li("Embed <iframe src=\"https://example.com/embed\" width=\"100%\"></iframe>"),
            P("Copyright © 2026 Example News. All rights reserved."),
            P("Most read: another story headline that is not part of this article"),
            Li("기사 스크랩"), Li("공유"), Li("프린트")];
        var junk = BodyCleanup.Junk(blocks);
        for (var i = 0; i < 2; i++) Assert.True(junk.Contains(i), $"머리 기자 소개 {i}");
        for (var i = 2; i < 10; i++) Assert.False(junk.Contains(i), $"본문 {i}");
        for (var i = 10; i < blocks.Count; i++) Assert.True(junk.Contains(i), $"꼬리 {i}: {blocks[i].Text}");
    }

    [Fact]
    public void JunkSafety()
    {
        // 저작권 줄 뒤가 본문의 절반을 넘으면(잘못 놓인 줄) 끝 자르기를 하지 않는다
        List<Block> blocks = [P(Para(1)), P("ⓒ Example News"), .. Enumerable.Range(2, 9).Select(n => P(Para(n)))];
        Assert.Equal([1], BodyCleanup.Junk(blocks).Order());
        // 긴 문단은 줄 규칙에 걸리지 않는다
        Assert.Empty(BodyCleanup.Junk([P("Copyright law " + Para(1)), .. Enumerable.Range(2, 4).Select(n => P(Para(n)))]));
        // 같은 블록이 잇달아 두 번(부제·사진 설명 중복) — 뒤 것을 뺀다
        Assert.Equal([1], BodyCleanup.Junk([P(Para(1)), P(Para(1)), P(Para(2))]).Order());
    }

    // 예전에 저장한 기사(군더더기를 빼기 전)도 읽기 창에서는 숨긴다
    [Fact]
    public void AnalyzeHidesJunkInOldArticles()
    {
        List<Block> blocks = [.. Enumerable.Range(1, 6).Select(n => P(Para(n))), P("Copyright © 2026 Example News. All rights reserved.")];
        Assert.Contains(6, BodyCleanup.Analyze(blocks).Skip);
    }

    // 작은 그림(기자 사진 등)은 본래 크기보다 키우지 않는다 — 읽기 창 사진은 max-width 만(본래 폭까지), 폭을 100% 로 늘리지 않음
    [Fact]
    public void SmallImagesNotUpscaled()
    {
        var css = File.ReadAllText(Path.Combine(ExtractJs.Root(), "windows", "Dropcap.Ui", "web", "reader.css"));
        var rule = css.Split('\n').First(l => l.TrimStart().StartsWith(".figure img"));
        Assert.Contains("max-width: 100%", rule);
        Assert.DoesNotContain(" width: 100%", rule.Replace("max-width", "max"));
    }

    // M: 맛보기·일부만 기사는 6시간 뒤 다시 받는다(그 밖은 그대로)
    [Fact]
    public void ShortCacheForCut()
    {
        var now = DateTimeOffset.UtcNow;
        var a = new PreparedArticle { Stage = Stage.Done, Title = "t", OriginalTitle = "t", SavedAt = now.AddHours(-7) };
        Assert.False(ArticleService.IsStale(a, now));
        a = a with { Paywalled = true };
        Assert.True(ArticleService.IsStale(a, now));
        a = a with { SavedAt = now.AddHours(-1) };
        Assert.False(ArticleService.IsStale(a, now));
        a = a with { Paywalled = null, Partial = true, SavedAt = null };   // 예전 기록(저장 시각 없음)도 다시
        Assert.True(ArticleService.IsStale(a, now));
        a = a with { SavedAt = now.AddDays(30) };   // 미래 시각도 다시
        Assert.True(ArticleService.IsStale(a, now));
    }

    private sealed class FakeExtract(Func<Article?> fast) : IArticleExtractor
    {
        public int Calls;
        public Task<Article?> FromHtmlAsync(string html, Uri baseUri) { Calls++; return Task.FromResult(fast()); }
        public Task<Article?> FromLiveAsync(Uri url) => Task.FromResult<Article?>(null);
    }

    private static NewsItem Item(string link = "https://example.com/a") => new() { Id = "a", Title = "Deal", Link = link, SourceId = "stat", SourceName = "STAT" };

    private ArticleService Svc(IArticleExtractor x, string html, Func<NewsItem, PaywallKind?>? kind = null) =>
        new(x, () => [], Path.Combine(tmp.Path, "articles"))
        {
            RecordExtract = (_, _, _) => { },
            Fetch = _ => Task.FromResult<(byte[], string?)?>((Encoding.UTF8.GetBytes(html), "utf-8")),
            KindOf = kind ?? (_ => null),
        };

    // 서비스: 사이트가 유료라고 적은 짧은 본문 → 맛보기, 군더더기는 번역 전에 빠지고, 저장 시각이 남음
    [Fact]
    public async Task ServiceMarksTeaserDropsJunkAndStamps()
    {
        var korean = Enumerable.Range(1, 6).Select(n => P(ReaderCutText.KPara(n))).ToList();
        var art = new Article { Title = "증권", Blocks = [.. korean, P("ⓒ 한국경제신문, 무단 전재 및 재배포 금지")] };
        var svc = Svc(new FakeExtract(() => art), "<script>var articlePayment = \"Y\";</script>");
        var a = await svc.PrepareAsync(Item(), interactive: false);
        Assert.True(a.Paywalled);
        Assert.DoesNotContain(a.Blocks, b => (b.Text ?? "").Contains("무단 전재"));
        Assert.NotNull(a.SavedAt);
    }

    // 서비스: 하드 유료 출처의 짧은 본문은 맛보기 · 일부만(partial) 표시가 남음
    [Fact]
    public async Task ServiceHardShortAndPartial()
    {
        var korean = Enumerable.Range(1, 6).Select(n => P(ReaderCutText.KPara(n))).ToList();
        var hard = await Svc(new FakeExtract(() => new Article { Title = "t", Blocks = korean }), "<p></p>", _ => PaywallKind.Hard)
            .PrepareAsync(Item("https://example.com/h"), interactive: false);
        Assert.True(hard.Paywalled);
        var part = await Svc(new FakeExtract(() => new Article { Title = "t", Blocks = korean, Partial = true }), "<p></p>")
            .PrepareAsync(Item("https://example.com/p"), interactive: false);
        Assert.True(part.Partial);
        Assert.Null(part.Paywalled);
    }

    // '다시 받기': 저장한 것을 지우고 처음부터 다시 추린다 · 오래된 맛보기는 저절로 다시 받는다
    [Fact]
    public async Task ReloadAndStaleCache()
    {
        var n = 0;
        var x = new FakeExtract(() => new Article { Title = "t" + ++n, Blocks = Enumerable.Range(1, 6).Select(i => P(ReaderCutText.KPara(i))).ToList() });
        var svc = Svc(x, "<p></p>");
        var item = Item();
        await svc.PrepareAsync(item, interactive: false);
        Assert.Equal(1, x.Calls);
        await svc.PrepareAsync(item, interactive: false);
        Assert.Equal(1, x.Calls);                            // 저장한 것을 씀
        var again = await svc.ReloadAsync(item);
        Assert.Equal(2, x.Calls);
        Assert.Equal("t2", again.OriginalTitle);
        // 6시간 넘은 맛보기 기록은 저장소에 있어도 다시 받는다
        var old = svc.Cached(item.Link)! with { Paywalled = true, SavedAt = DateTimeOffset.UtcNow.AddHours(-7) };
        File.WriteAllText(svc.FileFor(item.Link), Json.Encode(old));
        var fresh = Svc(x, "<p></p>");
        Assert.Null(fresh.Cached(item.Link));
        Assert.False(File.Exists(fresh.FileFor(item.Link)));
    }

    // 읽기 창 보기 데이터: 맛보기 띠·끝줄(무료 보도가 없어도), 일부만, 무료 보도 상자의 새 제목
    [Fact]
    public void ViewCarriesTeaserAndPartial()
    {
        var db = new Database(Path.Combine(tmp.Path, "m.sqlite"));
        try
        {
            var book = new Scrapbook(db);
            var item = Item();
            var a = new PreparedArticle { Stage = Stage.Done, Title = "t", OriginalTitle = "t", Blocks = [P(Para(1))], Paywalled = true };
            var v = (JsonObject)JsonSerializer.SerializeToNode(ReaderPage.View(item, a, null, book), Json.Options)!;
            Assert.True(v["teaser"]!.GetValue<bool>());
            Assert.Equal("— 여기까지가 공개된 부분입니다", v["cutNote"]!["text"]!.GetValue<string>());
            var p = (JsonObject)JsonSerializer.SerializeToNode(ReaderPage.View(item, a with { Paywalled = null, Partial = true }, null, book), Json.Options)!;
            Assert.False(p["teaser"]!.GetValue<bool>());
            Assert.Equal("본문 일부만 가져왔을 수 있어요", p["cutNote"]!["text"]!.GetValue<string>());
            var none = (JsonObject)JsonSerializer.SerializeToNode(ReaderPage.View(item, a with { Paywalled = null }, null, book), Json.Options)!;
            Assert.Null(none["cutNote"]);
            // 맛보기 띠는 불러오는 중에는 아직 없음(맥: 번역 중·끝에서만)
            var loading = (JsonObject)JsonSerializer.SerializeToNode(ReaderPage.View(item, a with { Stage = Stage.Extracting }, null, book), Json.Options)!;
            Assert.False(loading["teaser"]!.GetValue<bool>());
            Assert.Equal("다른 곳 보도로 전체를 읽을 수 있어요", ReaderPage.FreeReason(1, "done", true, null));
        }
        finally { db.Dispose(); }
    }
}
