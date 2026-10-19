using Dropcap.Core;

namespace Dropcap.Core.Tests;

// 맥 ReaderPhase3Tests.VergeShortArticleTests 를 옮긴 것(teaser-ld-port — ld-body-match):
// 사이트가 늘 isAccessibleForFree=false 라고 적지만 전문을 주는 Verge 짧은 기사가 맛보기('앞부분만')로 잘못 뜨지 않게
public class TeaserLdTests
{
    private static Block P(string s) => new() { Type = BlockKind.P, Text = s };

    private static readonly string[] Paras = Enumerable.Range(1, 4).Select(i =>
        $"Paragraph {i} of a short news story explains what the consulting firm told clients about the new tool this week."
        + string.Concat(Enumerable.Repeat(" More detail follows here.", 3))).ToArray();

    // 실제 꼴처럼 앞에 기자 이름·소개, 끝에 'Follow topics…' 가 붙는다(군더더기 — 읽기 창에서 빠짐)
    private static List<Block> Blocks() =>
        [P("Pat Example"), P("is a senior reporter covering technology, gaming, and more. Pat joined the site in 2019 after years elsewhere."),
         .. Paras.Select(P), P("Follow topics and authors from this story to see more like this in your personalized homepage feed.")];

    private static string Page(string ld) =>
        "<html><head><script type=\"application/ld+json\">{\"@context\":\"https://schema.org\",\"@type\":\"NewsArticle\",\"isAccessibleForFree\":false,\"articleBody\":\""
        + ld + "\"}</script></head><body></body></html>";

    // 사용자 사례 숫자 그대로: ld 902자 ≈ 우리 899자
    [Fact]
    public void UserCaseNumbers()
    {
        List<Block> b = [P(new string('a', 450)), P(new string('b', 449))];
        Assert.False(Paywall.IsTeaser(b, paid: true, kind: null, ldBody: 902));
        Assert.True(Paywall.IsTeaser(b, paid: true, kind: null));                  // ld 가 없으면 예전 규칙
        Assert.True(Paywall.IsTeaser(b, paid: true, kind: null, ldBody: 3000));    // 사이트가 전문을 적었는데 우리는 앞부분만
        Assert.True(Paywall.IsTeaser(b, paid: null, kind: PaywallKind.Hard, ldBody: 902)); // 하드 유료 규칙은 그대로
        Assert.True(Paywall.MatchesSiteBody(899, 902));
        Assert.False(Paywall.MatchesSiteBody(1150, 902));
        Assert.False(Paywall.MatchesSiteBody(900, 0));
        // 경계(±10% 포함 — 리눅스 ld_body_tests 와 같은 값): 900 의 810·990 은 같음, 809·991 은 다름
        Assert.True(Paywall.MatchesSiteBody(810, 900));
        Assert.True(Paywall.MatchesSiteBody(990, 900));
        Assert.False(Paywall.MatchesSiteBody(809, 900));
        Assert.False(Paywall.MatchesSiteBody(991, 900));
        Assert.False(Paywall.MatchesSiteBody(900, null));
    }

    // 군더더기(기자 소개·Follow topics)를 뺀 길이로도 견준다 — 그대로는 ld 와 10% 넘게 다름
    [Fact]
    public void ShortFullStoryWithJunkIsNotTeaser()
    {
        var html = Page(string.Join(" ", Paras));
        var ld = ArticleExtraction.LdBodyLength(html);
        Assert.NotNull(ld);
        Assert.Equal(true, ArticleExtraction.PaidFlag(html));
        var raw = Blocks().Sum(b => b.Text!.Length);
        Assert.False(Paywall.MatchesSiteBody(raw, ld));
        Assert.False(Paywall.IsTeaser(Blocks(), paid: true, kind: PaywallKind.Metered, ldBody: ld));
    }

    [Fact]
    public void SiteBodyMuchLongerStillTeaser()
    {
        var ld = ArticleExtraction.LdBodyLength(Page(string.Join(" ", Enumerable.Repeat(string.Join(" ", Paras), 5))));
        Assert.True(Paywall.IsTeaser(Blocks(), paid: true, kind: PaywallKind.Metered, ldBody: ld));
    }

    [Fact]
    public void LdBodyLengthReadsNestedGraphAndTakesLongest()
    {
        const string html = """<script type="application/ld+json">{"@graph":[{"@type":"WebPage"},{"@type":"NewsArticle","articleBody":"One  two\n three <b>four</b>"}]}</script>"""
            + """<script type="application/ld+json">{"articleBody":"short"}</script>""";
        Assert.Equal("One two three four".Length, ArticleExtraction.LdBodyLength(html));
        Assert.Null(ArticleExtraction.LdBodyLength("<p>none</p>"));
        Assert.Null(ArticleExtraction.LdBodyLength("""<script type="application/ld+json">{broken</script>"""));
    }

    // 미리 받기 단계: Verge 짧은 기사는 목록에 '앞부분만'이 뜨지 않는다
    [Fact]
    public void PrefetchVergeShortStoryNotMarked()
    {
        var dir = Path.Combine(Path.GetTempPath(), "dropcap-teaser-ld-" + Guid.NewGuid());
        Directory.CreateDirectory(dir);
        try
        {
            using var db = new Database(Path.Combine(dir, "magazine.sqlite"));
            var book = new PaywallBook(db);
            var it = new NewsItem { Id = "v", Title = "T", Link = "https://www.theverge.com/news/1/x", SourceId = "verge-all", SourceName = "VERGE", Tier = "press" };
            var ld = ArticleExtraction.LdBodyLength(Page(string.Join(" ", Paras)));
            book.RecordTeaser(it, Paywall.IsTeaser(Blocks(), paid: true, kind: book.SourceKind(it), ldBody: ld));
            Assert.NotEqual(PaywallKind.Teaser, book.Kind(it));
            Assert.Empty(book.Teasers);
        }
        finally { try { Directory.Delete(dir, true); } catch { } }
    }

    // 추출 스크립트(extract.js — WebView2 느린 길·빠른 길 모두)가 ldBody 를 돌려주고, 그 값으로 맛보기가 아니다(맥 shortFullStoryIsNotTeaser)
    [JsFact]
    public async Task ExtractScriptGivesLdBody()
    {
        var body = string.Concat(new[] { "<p>Pat Example</p><p>is a senior reporter covering technology, gaming, and more. Pat joined the site in 2019 after years elsewhere.</p>" }
            .Concat(Paras.Select(x => $"<p>{x}</p>"))
            .Append("<p>Follow topics and authors from this story to see more like this in your personalized homepage feed.</p>"));
        var html = Page(string.Join(" ", Paras)).Replace("<body></body>", $"<body><article><h1>Short</h1>{body}</article></body>");
        var a = await ExtractJs.OneAsync(html);
        Assert.NotNull(a);
        Assert.True(a!.Paid);
        Assert.Equal(ArticleExtraction.LdBodyLength(html), a.LdBody);
        Assert.False(Paywall.IsTeaser(a.Blocks, a.Paid, PaywallKind.Metered, a.LdBody));
    }
}
