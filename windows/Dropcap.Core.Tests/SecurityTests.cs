using System.Diagnostics;
using System.Text;
using Dropcap.Core;
using Dropcap.Ui;

namespace Dropcap.Core.Tests;

// 보안 점검(2026-10-14)에서 찾은 것 — 맥 SecurityTests 와 같은 규칙:
// 바깥 HTML 정규식 되풀이 훑기(HtmlScan) · Plain 선형 꼬리표 빼기 · 사이트맵 정규식은 기본 출처만 · 16진수 IP·특수 대역 · 사진 압축 폭탄 · 가져오기 정리
public class SecurityScanTests
{
    private static void Fast(Action body, double seconds = 2)
    {
        var w = Stopwatch.StartNew();
        body();
        Assert.True(w.Elapsed.TotalSeconds < seconds, $"{w.Elapsed.TotalSeconds:0.00}초 걸림");
    }

    [Fact]
    public void FeedImageStillFound()
    {
        var xml = """
            <rss><channel><item><title>T</title><link>https://a.example/1</link>
            <description><![CDATA[<p>x</p><img class="c" data-src="https://a.example/lazy.jpg" src='https://a.example/p.jpg'>]]></description></item>
            <item><title>U</title><link>https://a.example/2</link><description><![CDATA[<IMG data-src="https://a.example/only-lazy.jpg">]]></description></item>
            </channel></rss>
            """;
        var e = FeedParser.ParseFeed(Encoding.UTF8.GetBytes(xml));
        Assert.Equal(new[] { "https://a.example/p.jpg", "https://a.example/only-lazy.jpg" }, e.Select(x => x.Image));
    }

    // 예전 정규식: 맞지 않는 "<img src=x " 1MB 에 15초 넘게
    [Fact]
    public void FeedImageOnHostileBodyIsFast()
    {
        var body = string.Concat(Enumerable.Repeat("<img src=x ", 20_000));
        var xml = $"<rss><channel><item><title>T</title><link>https://a.example/1</link><description><![CDATA[{body}]]></description></item></channel></rss>";
        Fast(() => FeedParser.ParseFeed(Encoding.UTF8.GetBytes(xml)));
    }

    [Fact]
    public void StripTagsMatchesRegexAndIsLinear()
    {
        foreach (var s in new[] { "a<b>c</b>d", "x < y", "<<a>>", "a<b", "<p>한글</p>\n<br/>끝", "", "no tags" })
            Assert.Equal(System.Text.RegularExpressions.Regex.Replace(s, "<[^>]*>", " "), Plain.StripTags(s));
        var hostile = new string('<', 300_000);
        Fast(() => Assert.Equal(300_000, Plain.Clean(hostile).Length));
    }

    [Fact]
    public void HtmlScanReadsMetaEitherOrder()
    {
        var html = """<head><META content="첫 제목" property="og:title"><meta name=description content='설명'><metadata property="og:image" content="x">"""
                   + """<meta property="og:image" content="https://a.example/i.jpg"><title>탭 제목</title></head>""";
        Assert.Equal("첫 제목", HtmlScan.Meta(html, "og:title"));
        Assert.Equal("설명", HtmlScan.Meta(html, "description"));
        Assert.Equal("https://a.example/i.jpg", HtmlScan.Meta(html, "og:image"));   // <metadata> 는 meta 가 아님
        Assert.Equal("탭 제목", HtmlScan.Title(html));
        Assert.Equal("b", HtmlScan.Attr(""" data-src="a" src="b" """, "src"));
        Assert.Null(HtmlScan.Attr(""" content="닫히지 않음""", "content"));
    }

    // 예전 정규식: og:title 20KB 에 20초 넘게 · og:image 8KB 2.3초 · Alternates 80KB 12초
    [Fact]
    public void PageHeadOnHostilePagesIsFast()
    {
        var metas = string.Concat(Enumerable.Repeat("<meta property='og:title' content=", 3_000));
        var images = string.Concat(Enumerable.Repeat("<meta property='og:image' ", 6_000));
        var links = string.Concat(Enumerable.Repeat("""<link rel="alternate" """, 8_000));
        var item = new NewsItem { Id = "1", Title = "", Link = "https://a.example/news/x", Summary = "", SourceId = "s" };
        Fast(() =>
        {
            FeedService.FillFrom(item, metas);
            FeedService.OgImageFrom(images, "https://a.example/");
            _ = ChannelResolver.Alternates(links).ToList();
            HtmlScan.Title(string.Concat(Enumerable.Repeat("<title>", 50_000)));
        });
    }

    [Fact]
    public void PageHeadStillWorks()
    {
        var item = new NewsItem { Id = "1", Title = "", Link = "https://a.example/news/x", Summary = "", SourceId = "s" };
        var it = FeedService.FillFrom(item, """<meta content="새 글 | Anthropic" property="og:title"><meta name="description" content="설명 &amp; 요약"><meta property="og:image" content="https://a.example/c.jpg">""");
        Assert.Equal("새 글", it.Title);
        Assert.Equal("설명 & 요약", it.Summary);
        Assert.Equal("https://a.example/c.jpg", it.Image);
        Assert.Equal("https://a.example/img/a.jpg?x=1&y=2", FeedService.OgImageFrom("""<meta content="/img/a.jpg?x=1&amp;y=2" property="og:image">""", "https://a.example/p"));
        Assert.Equal("https://a.example/t.jpg", FeedService.OgImageFrom("""<meta name="twitter:image" content="https://a.example/t.jpg">""", "https://a.example/p"));
        Assert.Equal(new[] { "https://a.example/feed?a=1&b=2" },
            ChannelResolver.Alternates("""<link rel="alternate" type="application/rss+xml" href="https://a.example/feed?a=1&amp;b=2"><link rel="alternate" type="text/html" href="x">"""));
    }

    [Fact]
    public void SitemapRegexOnlyFromBundledSources()
    {
        var bundled = new List<Source> { new() { Id = "anthropic", Name = "A", Tier = "lab", Type = "sitemap", Url = "https://a.example/sitemap.xml", Match = "^https://a\\.example/news/", Color = "#000" } };
        Assert.Equal("^https://a\\.example/news/", FeedService.SitemapPattern(bundled[0], bundled));
        Assert.Null(FeedService.SitemapPattern(bundled[0] with { Id = "custom-x" }, bundled));
        Assert.Null(FeedService.SitemapPattern(bundled[0] with { Match = "^(a+)+$" }, bundled));
    }

    [Theory]
    [InlineData("http://0x7f.0.0.0xa/")]
    [InlineData("http://0xc0.0xa8.0x1.0xa/")]
    [InlineData("http://0x7f000001/")]
    [InlineData("http://[::ffff:0:7f00:1]/")]      // IPv4-translated
    [InlineData("http://[64:ff9b:1::7f00:1]/")]     // NAT64 지역(/48)
    [InlineData("http://[2001::1]/")]               // Teredo
    [InlineData("http://[2001:db8::1]/")]           // 문서용
    [InlineData("http://[100::1]/")]                // 버림용
    [InlineData("http://192.0.2.1/")]               // 문서용 TEST-NET
    [InlineData("http://198.51.100.1/")]
    [InlineData("http://203.0.113.1/")]
    public void SpecialHostsAreNotPublic(string url) => Assert.False(UrlSafety.IsPublicHttp(url));

    [Theory]
    [InlineData("https://cafe.example/")]
    [InlineData("https://0x.com/")]
    [InlineData("https://abc.de/")]
    [InlineData("https://8.8.8.8/")]
    [InlineData("https://[2606:4700::1111]/")]
    public void OrdinaryHostsStayPublic(string url) => Assert.True(UrlSafety.IsPublicHttp(url));

    // 가로세로만 큰 PNG(머리만): 풀기 전에 거절해 수 GB 를 잡지 않는다
    [Fact]
    public void HugeImageDimensionsAreRejectedBeforeDecode()
    {
        Assert.Null(ImageLoader.Shrink(PngHeader(40_000, 40_000)));
        Assert.Null(PhotoScorer.Score(PngHeader(40_000, 40_000), 0));
    }

    internal static byte[] PngHeader(int w, int h)
    {
        var o = new List<byte> { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
        void Chunk(string type, byte[] data)
        {
            o.AddRange(BitConverter.GetBytes(System.Buffers.Binary.BinaryPrimitives.ReverseEndianness(data.Length)));
            var td = Encoding.ASCII.GetBytes(type).Concat(data).ToArray();
            o.AddRange(td);
            o.AddRange(BitConverter.GetBytes(System.Buffers.Binary.BinaryPrimitives.ReverseEndianness(Crc(td))));
        }
        var ihdr = new byte[13];
        System.Buffers.Binary.BinaryPrimitives.WriteInt32BigEndian(ihdr, w);
        System.Buffers.Binary.BinaryPrimitives.WriteInt32BigEndian(ihdr.AsSpan(4), h);
        ihdr[8] = 8; ihdr[9] = 2;   // 8비트 RGB
        Chunk("IHDR", ihdr);
        Chunk("IDAT", [0x78, 0x9C, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01]);
        Chunk("IEND", []);
        return o.ToArray();
    }

    private static uint Crc(byte[] d)
    {
        uint c = 0xFFFFFFFF;
        foreach (var b in d) { c ^= b; for (var k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1; }
        return ~c;
    }
}

public class SecurityBackupTests : IDisposable
{
    private readonly TempDir tmp = new();
    public void Dispose() => tmp.Dispose();

    private static string Item(string link) => $$"""{"id":"{{link}}","title":"t","link":"{{link}}","summary":"{{new string('s', 5000)}}","sourceId":"s","sourceName":"S","tier":"press"}""";

    [Fact]
    public void SavedAndScrapsNeedPublicLinks()
    {
        var b = Backup.Decode($$"""
            {"format":"dropcap-backup","version":1,"saved":[{{Item("https://a.example/1")}},{{Item("file:///etc/passwd")}}],
             "scraps":[{"id":"s1","item":{{Item("https://a.example/1")}},"memo":"","collection":"{{new string('폴', 61)}}","created":"2026-10-14T00:00:00Z"},
                       {"id":"s2","item":{{Item("javascript:alert(1)")}},"memo":"","collection":"보고서","created":"2026-10-14T00:00:00Z"}],
             "scrapFolders":[" 보고서 ","보고서",""]}
            """);
        Assert.Equal(new[] { "https://a.example/1" }, b.Saved.Select(x => x.Link));
        Assert.True(b.Saved[0].Summary.Length <= 2000);
        Assert.Equal(new[] { "s1" }, b.Scraps.Select(x => x.Id));
        Assert.Equal("스크랩", b.Scraps[0].Collection);
        Assert.Equal(new[] { "보고서" }, b.ScrapFolders);
    }

    [Fact]
    public void StateFileClampsInterval()
    {
        Assert.Equal(24 * 60, StateSettings.FromJson(System.Text.Json.Nodes.JsonNode.Parse("""{"intervalMinutes":2147483647}""")!.AsObject()).IntervalMinutes);
        Assert.Equal(1, StateSettings.FromJson(System.Text.Json.Nodes.JsonNode.Parse("""{"intervalMinutes":0}""")!.AsObject()).IntervalMinutes);
        Assert.Equal(23, StateSettings.FromJson(System.Text.Json.Nodes.JsonNode.Parse("""{"quietStart":99}""")!.AsObject()).QuietStart);
    }

    [Fact]
    public void ImportRejectsHugeFile()
    {
        var f = Path.Combine(tmp.Path, "big.json");
        using (var s = File.Create(f)) s.SetLength(Backup.MaxFileSize + 1);
        using var db = new Database(Path.Combine(tmp.Path, "m.sqlite"));
        var model = new AppModel(new FakeUi(), new Magazine(db), new AppState(), persist: false);
        var r = Backup.ImportFrom(f, model, new Scrapbook(db));
        Assert.False(r.Ok);
        Assert.Contains("너무 큽니다", r.Message);
    }

    [Fact]
    public void MergeOfManySavedIsFast()
    {
        var file = new BackupFile { Saved = Enumerable.Range(0, 5000).Select(i => new NewsItem { Id = $"{i}", Title = "t", Link = $"https://a.example/{i}", Summary = "", SourceId = "s" }).ToList() };
        var state = new AppState { Saved = Enumerable.Range(2500, 5000).Select(i => new NewsItem { Id = $"{i}", Title = "t", Link = $"https://a.example/{i}", Summary = "", SourceId = "s" }).ToList() };
        var w = Stopwatch.StartNew();
        var m = Backup.Merge(file, state, [], []);
        Assert.True(w.Elapsed.TotalSeconds < 1, $"{w.Elapsed.TotalSeconds:0.00}초");
        Assert.Equal(7500, m.State.Saved.Count);
        Assert.Equal(2500, m.Summary.Saved);
    }
}
