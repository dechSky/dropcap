using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;
using Dropcap.Core;

namespace Dropcap.Core.Tests;

// 맥 mac/Tests/DropcapTests/CoreTests.swift 의 사례를 그대로 옮긴 것(Q-01)

public class StoryMatchTests
{
    [Fact]
    public void SameStoryDifferentOutlets()
    {
        var a = StoryMatch.Tokens("OpenAI launches GPT-6 with new reasoning features");
        var b = StoryMatch.Tokens("GPT-6 launches: OpenAI reveals reasoning features");
        Assert.True(StoryMatch.Similar(a, b));
    }

    [Fact]
    public void DifferentStories()
    {
        var a = StoryMatch.Tokens("Microsoft announces Maia 300 AI chip");
        var b = StoryMatch.Tokens("Meta releases its first frontier model, Muse Wonder");
        Assert.False(StoryMatch.Similar(a, b));
    }

    [Fact]
    public void ShortTitlesNeverMatch() =>
        Assert.False(StoryMatch.Similar(StoryMatch.Tokens("AI news"), StoryMatch.Tokens("AI news")));

    [Fact]
    public void KoreanTitles()
    {
        var a = StoryMatch.Tokens("마이크로소프트, 자체 AI 칩 마이아 300 공개");
        var b = StoryMatch.Tokens("마이크로소프트 마이아 300 공개…자체 AI 칩 확대");
        Assert.True(StoryMatch.Similar(a, b));
    }
}

public class QuietHoursTests
{
    [Fact]
    public void Overnight()
    {
        Assert.True(AppModel.InQuiet(23, 23, 7));
        Assert.True(AppModel.InQuiet(3, 23, 7));
        Assert.False(AppModel.InQuiet(7, 23, 7));
        Assert.False(AppModel.InQuiet(12, 23, 7));
    }

    [Fact]
    public void SameDay()
    {
        Assert.True(AppModel.InQuiet(13, 12, 14));
        Assert.False(AppModel.InQuiet(14, 12, 14));
    }

    [Fact]
    public void EmptyRange() => Assert.False(AppModel.InQuiet(5, 5, 5));
}

public class FeedParserTests
{
    private static byte[] B(string s) => Encoding.UTF8.GetBytes(s);

    [Fact]
    public void Rss()
    {
        var xml = """
            <?xml version="1.0"?><rss version="2.0"><channel><title>x</title>
            <item><title><![CDATA[Hello &amp; <b>world</b>]]></title><link>https://a.com/1</link><guid>g1</guid>
            <pubDate>Mon, 12 Oct 2026 10:00:00 +0000</pubDate><description>&lt;p&gt;Sum&lt;/p&gt;</description></item>
            </channel></rss>
            """;
        var e = FeedParser.ParseFeed(B(xml));
        Assert.Single(e);
        Assert.Equal("g1", e[0].Id);
        Assert.Equal("Hello & world", e[0].Title);
        Assert.NotNull(e[0].Date);
        Assert.Equal("Sum", e[0].Summary);
    }

    [Fact]
    public void AtomPrefersAlternateLink()
    {
        var xml = """
            <feed xmlns="http://www.w3.org/2005/Atom"><entry><id>tag:1</id><title>T</title>
            <link rel="self" href="https://a.com/self"/><link rel="alternate" href="https://a.com/post"/>
            <updated>2026-10-12T10:00:00Z</updated></entry></feed>
            """;
        Assert.Equal("https://a.com/post", FeedParser.ParseFeed(B(xml)).First().Link);
    }

    [Fact]
    public void SitemapFiltersByPattern()
    {
        var xml = """
            <urlset><url><loc>https://www.anthropic.com/news/claude-x</loc><lastmod>2026-10-01T00:00:00Z</lastmod></url>
            <url><loc>https://www.anthropic.com/careers</loc></url></urlset>
            """;
        var re = new Regex("^https:\\/\\/www\\.anthropic\\.com\\/news\\/[^/]+$");
        Assert.Equal(["https://www.anthropic.com/news/claude-x"], FeedParser.ParseSitemap(B(xml), re).Select(e => e.Link));
    }

    // 뉴스 사이트맵: 발행 시각(news:publication_date)을 먼저, 없으면 lastmod(한국일보·문화일보는 발행 시각만)
    [Fact]
    public void SitemapReadsNewsPublicationDate()
    {
        var xml = """
            <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:news="http://www.google.com/schemas/sitemap-news/0.9">
            <url><loc>https://www.hankookilbo.com/News/Read/A1</loc><news:news><news:publication_date>2026-10-15T09:30:00+09:00</news:publication_date></news:news></url>
            <url><loc>https://www.hankookilbo.com/News/Read/A2</loc><lastmod>2026-10-15T01:00:00Z</lastmod><news:news><news:publication_date>2026-10-14T23:00:00Z</news:publication_date></news:news></url>
            <url><loc>https://www.hankookilbo.com/News/Read/A3</loc><lastmod>2026-10-15T02:00:00Z</lastmod></url></urlset>
            """;
        var e = FeedParser.ParseSitemap(B(xml), new Regex("/News/Read/"));
        Assert.Equal([new DateTimeOffset(2026, 10, 15, 0, 30, 0, TimeSpan.Zero), new DateTimeOffset(2026, 10, 14, 23, 0, 0, TimeSpan.Zero),
                      new DateTimeOffset(2026, 10, 15, 2, 0, 0, TimeSpan.Zero)], e.Select(x => x.Date!.Value.ToUniversalTime()));
    }

    [Fact]
    public void GarbageThrows() =>
        Assert.ThrowsAny<Exception>(() => FeedParser.ParseFeed(B("<html><body>nope</body></html>")));

    // 이 판에서 더 본 것: RDF, 대표 사진 순서, 요약 300자
    [Fact]
    public void RdfAndImagesAndSummaryLimit()
    {
        var rdf = """
            <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/">
            <item><title>R</title><link>https://r.com/1</link><dc:date>2026-10-12T10:00:00Z</dc:date><description>d</description></item></rdf:RDF>
            """;
        var r = FeedParser.ParseFeed(B(rdf));
        Assert.Equal("https://r.com/1", r[0].Id);
        Assert.NotNull(r[0].Date);

        var long_ = new string('a', 500);
        var rss = $"""
            <rss xmlns:media="http://search.yahoo.com/mrss/"><channel>
            <item><title>A</title><link>https://a.com/1</link><description>{long_} &lt;img src="https://a.com/body.jpg"&gt;</description>
              <media:content url="https://a.com/video.mp4" medium="video"><media:thumbnail url="https://a.com/thumb.jpg"/></media:content></item>
            <item><title>B</title><link>https://a.com/2</link><enclosure url="https://a.com/enc.png" type="image/png"/></item>
            <item><title>C</title><link>https://a.com/3</link><description>&lt;img src='https://a.com/first.jpg'&gt;</description></item>
            </channel></rss>
            """;
        var e = FeedParser.ParseFeed(B(rss));
        Assert.Equal("https://a.com/thumb.jpg", e[0].Image);
        Assert.Equal(300, e[0].Summary.Length);
        Assert.Equal("https://a.com/enc.png", e[1].Image);
        Assert.Equal("https://a.com/first.jpg", e[2].Image);
    }

    [Fact]
    public void EucKrFeed()
    {
        var enc = CodePagesEncodingProvider.Instance.GetEncoding("euc-kr")!;
        var xml = "<?xml version=\"1.0\" encoding=\"euc-kr\"?><rss><channel><item><title>인공지능 소식</title><link>https://k.co.kr/1</link></item></channel></rss>";
        Assert.Equal("인공지능 소식", FeedParser.ParseFeed(enc.GetBytes(xml))[0].Title);
    }

    [Fact]
    public void TitleFromSlug() => Assert.Equal("Claude new model", Plain.TitleFromSlug("https://www.anthropic.com/news/claude-new_model/"));
}

public class StoreTests
{
    // 예전 파일(새 항목 없음, position "auto")도 그대로 읽혀야 한다 — 업데이트해도 기록이 날아가지 않게
    [Fact]
    public void DecodesOldStateFile()
    {
        var old = """
            {"seen":{"openai|x":1},"seeded":["openai"],"enabled":{"openai":true},"recent":[],"errors":{},"unread":2,
             "settings":{"style":"drop","sound":false,"intervalMinutes":10,"position":"auto"}}
            """;
        var s = AppState.FromJson(old);
        Assert.Equal(1, s.Seen["openai|x"]);
        Assert.Equal(2, s.Unread);
        Assert.False(s.Settings.Sound);
        Assert.Equal(10, s.Settings.IntervalMinutes);
        Assert.Equal(ToastPosition.Center, s.Settings.Position);
        Assert.True(s.Saved.Count == 0 && s.Read.Count == 0 && s.CustomSources.Count == 0);
    }

    [Fact]
    public void DecodesOldReadList()
    {
        var s = AppState.FromJson("""{"read":["x|1","y|2"]}""");
        Assert.Equal(["x|1", "y|2"], s.Read.Keys.Order());
    }

    [Fact]
    public void RoundTrip()
    {
        var s = new AppState();
        s.Settings.MustKeywords = ["GPT"];
        s.Read = new() { ["a|b"] = 1 };
        var back = AppState.FromJson(s.ToJson());
        Assert.Equal(["GPT"], back.Settings.MustKeywords);
        Assert.Equal(1, back.Read["a|b"]);
    }

    // 이 판에서 더 본 것: 한 항목이 깨져도 나머지는 읽힘, 맥이 쓴 파일(날짜·enum 모양) 그대로
    [Fact]
    public void BrokenFieldDoesNotLoseOthers()
    {
        var s = AppState.FromJson("""{"unread":"many","seen":{"a|1":5},"lastCheck":"2026-10-13T01:02:03Z","settings":{"style":"system","digestHour":"x"}}""");
        Assert.Equal(0, s.Unread);
        Assert.Equal(5, s.Seen["a|1"]);
        Assert.Equal(new DateTimeOffset(2026, 10, 13, 1, 2, 3, TimeSpan.Zero), s.LastCheck);
        Assert.Equal(ToastStyle.System, s.Settings.Style);
        Assert.Equal(9, s.Settings.DigestHour);
    }

    [Fact]
    public void WritesMacCompatibleShape()
    {
        var s = new AppState { LastCheck = new DateTimeOffset(2026, 10, 13, 1, 2, 3, TimeSpan.Zero) };
        s.Recent.Add(new NewsItem { Id = "1", Title = "T", Link = "https://a.com", SourceId = "openai", SourceName = "OpenAI", Tier = "lab" });
        var json = s.ToJson();
        Assert.Contains("\"lastCheck\":\"2026-10-13T01:02:03Z\"", json);
        Assert.Contains("\"style\":\"drop\"", json);
        Assert.Contains("\"position\":\"center\"", json);
        Assert.Contains("\"sourceId\":\"openai\"", json);
        Assert.DoesNotContain("titleKo", json); // 없는 값은 쓰지 않음(맥과 같음)
    }

    [Fact]
    public void AtomicSaveBackupAndSeenLimit()
    {
        var dir = Path.Combine(Path.GetTempPath(), "dropcap-test-" + Guid.NewGuid());
        Store.UseDir(dir);
        try
        {
            var s = new AppState();
            Store.Save(s);
            Store.Flush();
            Assert.False(File.Exists(Path.Combine(dir, "native-state.bak.json"))); // 처음엔 이전 파일이 없음
            for (var i = 0; i < Store.SeenLimit + 50; i++) s.Seen[$"s|{i}"] = i;
            Store.UseDir(dir); // 새 실행처럼
            Store.Save(s);
            Assert.False(File.Exists(Path.Combine(dir, "native-state.bak.json"))); // 0.5초 묶는 동안은 아직 쓰지 않음
            Store.Flush();
            Assert.True(File.Exists(Path.Combine(dir, "native-state.bak.json")));
            var back = Store.Load();
            Assert.Equal(Store.SeenLimit, back.Seen.Count);
            Assert.False(back.Seen.ContainsKey("s|0")); // 오래된 것부터 정리
            Assert.True(back.Enabled["openai"]);       // 없는 출처 켜짐 값은 기본값으로
        }
        finally { Directory.Delete(dir, true); }
    }
}

public class MiscTests
{
    [Fact]
    public void GzipInflate()
    {
        using var ms = new MemoryStream();
        using (var gz = new GZipStream(ms, CompressionLevel.Optimal, leaveOpen: true)) gz.Write(Encoding.UTF8.GetBytes("<rss>hello</rss>"));
        Assert.Equal("<rss>hello</rss>", Encoding.UTF8.GetString(Gzip.InflateIfNeeded(ms.ToArray())));
        Assert.Equal(Encoding.UTF8.GetBytes("plain"), Gzip.InflateIfNeeded(Encoding.UTF8.GetBytes("plain")));
    }

    // S-09: 크기 값을 거짓으로 적은 gzip 도 32MB 를 넘겨 풀지 않는다
    [Fact]
    public void GzipCapsOutput()
    {
        using var ms = new MemoryStream();
        using (var gz = new GZipStream(ms, CompressionLevel.SmallestSize, leaveOpen: true)) gz.Write(new byte[40 << 20]);
        var data = ms.ToArray();
        data[^4] = 1; data[^3] = 0; data[^2] = 0; data[^1] = 0; // isize 를 1 로 속임
        Assert.True(Gzip.InflateIfNeeded(data).Length <= 32 << 20);
    }

    [Fact]
    public void LooksForeign()
    {
        Assert.True(Translator.LooksForeign("OpenAI releases a new model"));
        Assert.False(Translator.LooksForeign("오픈AI가 새 모델을 공개했다"));
        Assert.False(Translator.LooksForeign("   "));
    }

    [Fact]
    public void Dates_()
    {
        Assert.NotNull(Dates.Parse("Tue, 13 Oct 2026 01:02:03 GMT"));
        Assert.NotNull(Dates.Parse("2026-10-13T01:02:03.123Z"));
        Assert.Null(Dates.Parse("garbage"));
        Assert.Equal(new DateTimeOffset(2026, 10, 12, 10, 0, 0, TimeSpan.Zero), Dates.Parse("Mon, 12 Oct 2026 10:00:00 +0000"));
        Assert.Equal(new DateTimeOffset(2026, 10, 12, 15, 0, 0, TimeSpan.Zero), Dates.Parse("Mon, 12 Oct 2026 10:00:00 EST"));
    }

    [Fact]
    public void RelativeTimeAndClock()
    {
        var now = new DateTimeOffset(2026, 10, 13, 12, 0, 0, TimeSpan.Zero);
        Assert.Equal("방금", RelativeTime.Format(null, now));
        Assert.Equal("5분 전", RelativeTime.Format(now.AddMinutes(-5), now));
        Assert.Equal("3시간 전", RelativeTime.Format(now.AddHours(-3), now));
        Assert.Equal("2일 전", RelativeTime.Format(now.AddDays(-2), now));
        Assert.Equal("아직 없음", RelativeTime.Clock(null));
    }

    [Fact]
    public void SourcesJsonLoads()
    {
        Assert.True(Resources.Config.Sources.Count >= 100);   // 일반 뉴스 전환 뒤 120곳
        Assert.Equal("공식 발표", Resources.TierLabel("lab"));
        Assert.Matches(Resources.AiRegex, "new LLM benchmark");
        Assert.Matches(Resources.AiRegex, "생성형 서비스");
        Assert.DoesNotMatch(Resources.AiRegex, "weekend cooking recipes");
    }
}

public class CategoryTests
{
    [Fact]
    public void Classifies()
    {
        Assert.Equal(Categories.Parse("model"), Categories.Classify("OpenAI launches GPT-6"));
        Assert.Equal(Categories.Parse("business"), Categories.Classify("Anthropic raises $5B at $200B valuation"));
        Assert.Equal(Categories.Parse("policy"), Categories.Classify("EU AI Act enforcement begins, regulators say"));
        Assert.Equal(Categories.Parse("security"), Categories.Classify("New jailbreak exploit hits chatbots"));
        Assert.Equal(Categories.Parse("research"), Categories.Classify("Researchers publish benchmark for reasoning"));
        Assert.Equal(Categories.Parse("policy"), Categories.Classify("정부, AI 기본법 시행령 발표"));
        Assert.Equal(Categories.Parse("business"), Categories.Classify("업스테이지, 1000억 투자 유치"));
        Assert.Equal(Categories.Parse("other"), Categories.Classify("Weekend reading list"));
    }

    [Fact]
    public void KindOverridesCategory()
    {
        Assert.Equal(Categories.Parse("research"), new NewsItem { Title = "Weekend", Kind = "paper" }.Category);
        Assert.Equal(Categories.Parse("model"), new NewsItem { Title = "Weekend", Kind = "release" }.Category);
    }
}

public class UrlSafetyTests
{
    [Theory]
    [InlineData("https://openai.com/news/x")]
    [InlineData("http://www.aitimes.com/a?b=1")]
    [InlineData("https://8.8.8.8/x")]
    [InlineData("https://[2606:4700::1111]/")]
    public void AllowsPublic(string u) => Assert.True(UrlSafety.IsPublicHttp(u), u);

    [Theory]
    [InlineData("http://localhost:8080/")]
    [InlineData("http://127.0.0.1/")]
    [InlineData("http://192.168.0.1/admin")]
    [InlineData("http://10.1.2.3/")]
    [InlineData("http://172.20.0.5/")]
    [InlineData("http://169.254.169.254/latest/meta-data")]
    [InlineData("http://router.local/")]
    [InlineData("http://intranet/")]
    [InlineData("http://[::1]/")]
    [InlineData("http://[fd00::1]/")]
    [InlineData("http://[::ffff:192.168.1.1]/")]
    [InlineData("file:///etc/passwd")]
    [InlineData("smb://server/share")]
    [InlineData("javascript:alert(1)")]
    [InlineData("http://0.0.0.0/")]
    // 숫자 표기 꼼수
    [InlineData("http://2130706433/")]
    [InlineData("http://0x7f.1/")]
    [InlineData("http://127.1/")]
    [InlineData("http://0177.0.0.1/")]
    [InlineData("http://0x7f000001/")]
    [InlineData("http://[0:0:0:0:0:0:0:1]/")]
    [InlineData("http://[::ffff:7f00:1]/")]
    [InlineData("http://[64:ff9b::7f00:1]/")]
    [InlineData("http://[2002:c0a8:0101::]/")]
    [InlineData("http://localhost./")]
    [InlineData("http://[fe80::1]/")]
    // 이 판에서 더 본 것
    [InlineData("http://user@127.0.0.1/")]
    [InlineData("http://evil.com@10.0.0.1/")]
    [InlineData("http://100.64.0.1/")]
    [InlineData("http://224.0.0.1/")]
    [InlineData("http://printer.lan/")]
    [InlineData("http://x.home.arpa/")]
    [InlineData("http://svc.internal/")]
    [InlineData("")]
    [InlineData(null)]
    public void BlocksPrivateAndOddSchemes(string? u) => Assert.False(UrlSafety.IsPublicHttp(u), u);

    [Fact]
    public void ExternalLinkOnlyOpensPublic()
    {
        var opened = new List<Uri>();
        ExternalLink.Opener = u => { opened.Add(u); return true; };
        try
        {
            Assert.False(ExternalLink.Open("file:///C:/Windows/System32/calc.exe"));
            Assert.False(ExternalLink.Open("http://192.168.0.1/"));
            Assert.False(ExternalLink.Open(null));
            Assert.True(ExternalLink.Open("https://openai.com/news"));
            Assert.Single(opened);
        }
        finally { ExternalLink.Opener = null; }
    }

    // S-03: 연결 콜백이 쓰는 검사 — 이름이 아닌 IP 글자도, 내부망 IP 로 풀리는 것도 거절
    [Fact]
    public async Task ConnectCheckRejectsPrivateLiterals()
    {
        Assert.Null(await SafeHttp.ResolveCheckedAsync("127.0.0.1", default));
        Assert.Null(await SafeHttp.ResolveCheckedAsync("::1", default));
        Assert.Null(await SafeHttp.ResolveCheckedAsync("localhost", default));
        Assert.NotNull(await SafeHttp.ResolveCheckedAsync("8.8.8.8", default));
    }

    // 시험 서버를 이 PC 에 띄워도(127.0.0.1) 받기 모듈은 요청을 보내지 않는다
    [Fact]
    public async Task FetchRefusesLoopback()
    {
        await Assert.ThrowsAsync<BlockedException>(() => FeedService.Shared.FetchAsync("http://127.0.0.1:9/feed"));
        await Assert.ThrowsAsync<BlockedException>(() => FeedService.Shared.FetchAsync("http://localhost:9/feed"));
    }
}

public class SameStoryMeaningTests
{
    private static NewsItem Item(string title, string? en = null, string? source = null) => new()
    {
        Id = title, Title = title, Link = "https://x.com/" + FeedParser.Prefix(title, 8), Summary = "",
        SourceId = source ?? Guid.NewGuid().ToString(), SourceName = "S", Tier = "press", TitleEn = en,
    };

    [Fact]
    public void SameOutletNeverMerges() =>
        Assert.False(StoryMatch.Same(Item("OpenAI launches GPT-6 with new reasoning", source: "a"), Item("OpenAI launches GPT-6 with new reasoning", source: "a")));

    [Fact]
    public void GroupsAcrossLanguages()
    {
        var ko = Item("메타, 자체 최고 모델 ‘뮤즈 원더’ 출시로 프런티어 경쟁 합류", en: "Meta joins frontier competition by launching its own top model 'Muse Wonder'");
        var en = Item("Meta has some Wonder Full new AI models");
        Assert.True(StoryMatch.Same(ko, en));
        var ko2 = Item("\"AI 대신 SI 써라\"...트럼프 압박에 실리콘밸리 굴복", en: "\"Use SI instead of AI\"... Silicon Valley succumbs to Trump pressure");
        Assert.True(StoryMatch.Same(ko2, Item("Silicon Valley is falling in line with Trump’s attempt to rename AI")));
    }

    [Fact]
    public void KeepsDifferentStoriesApart()
    {
        Assert.False(StoryMatch.Same(Item("Microsoft’s new AI chip makes it less reliant on Nvidia’s GPUs"), Item("Meta has some Wonder Full new AI models")));
        Assert.False(StoryMatch.Same(Item("Anthropic is cutting off its internal evaluations from the internet"),
            Item("Anthropic's Claude AI submitted false murder tip to Philadelphia police")));
        Assert.False(StoryMatch.Same(Item("Learning to use local AI is exciting, overwhelming, and frustrating"),
            Item("AI agent makers are promising privacy — will they deliver?")));
    }

    [Fact]
    public void UnrelatedKoreanTranslationsStayApart()
    {
        Assert.False(StoryMatch.Same(Item("Epic Games reportedly pivoting to \"AI first\" game development model"),
            Item("[AI리더의 서가] Physical AI 데이터의 새로운 법칙", en: "[AI Leader's Bookshelf] New Rules of Physical AI Data")));
        Assert.False(StoryMatch.Same(Item("Amazon has over 1 million robot workers. What’s next for human employees?"),
            Item("포스코DX, AI 스타트업 인핸스에 20억 투자", en: "POSCO DX invests 2 billion won in AI startup Enhance")));
    }
}

public class ScrapExportTests
{
    [Fact]
    public void MarkdownGroupsByArticle()
    {
        var it = new NewsItem
        {
            Id = "1", Title = "Meta has new AI models", TitleKo = "메타의 새 AI 모델", Link = "https://example.com/a",
            Date = DateTimeOffset.FromUnixTimeSeconds(1_791_800_000), Summary = "", SourceId = "verge", SourceName = "The Verge", Tier = "press",
        };
        var a = new Scrap { Item = it, Quote = "메타가 새 모델을 공개했다.", QuoteOriginal = "Meta released a new model.", Memo = "보고서 1장", Collection = "조사" };
        var b = new Scrap { Item = it, Collection = "조사" };
        var md = Scrapbook.Render([b, a], "조사");
        Assert.StartsWith("# 조사", md);
        Assert.Equal(2, md.Split("## [메타의 새 AI 모델](https://example.com/a)").Length); // 기사는 한 번만
        Assert.Contains("> 메타가 새 모델을 공개했다.", md);
        Assert.Contains("> _Meta released a new model._", md);
        Assert.Contains("- 메모: 보고서 1장", md);
        Assert.Contains("원제: Meta has new AI models", md);
    }

    // 맥 render 와 글자 하나까지 같은지(날짜 고정)
    [Fact]
    public void MarkdownExactShape()
    {
        var it = new NewsItem { Id = "1", Title = "T", Link = "https://e.com/a", SourceId = "s", SourceName = "Src", Tier = "press" };
        var s = new Scrap { Item = it, Quote = "줄1\n줄2", Memo = "m", Collection = "c" };
        var md = Scrapbook.Render([s], "c", new DateTimeOffset(2026, 10, 13, 12, 0, 0, TimeSpan.Zero));
        Assert.Equal("# c\n\n_Dropcap 스크랩 · 2026-10-13 · 1건_\n\n## [T](https://e.com/a)\n\nSrc\n\n> 줄1\n> 줄2\n\n- 메모: m\n\n", md);
    }
}

// 분야는 자료(categories.json)에서 읽는다 — 다른 정의 파일로 바꾸면 분류·이름·색이 그대로 따라온다
public class CategoryDataTests
{
    [Fact]
    public void LoadsFromDefinitionFile()
    {
        var path = Path.Combine(Path.GetTempPath(), "dropcap-cat-" + Guid.NewGuid() + ".json");
        File.WriteAllText(path, """
            {"fallback":"etc","classifyOrder":["econ","it"],"kindCategory":{"paper":"it"},
             "categories":[{"id":"econ","label":"경제","icon":"cat.business","light":"#111111","dark":"#222222","words":["금리","stock"]},
                           {"id":"it","label":"IT","icon":"cat.model","light":"#333333","dark":"#444444","words":["반도체","ai"]},
                           {"id":"etc","label":"기타","icon":"cat.other","light":"#555555","dark":"#666666","words":[]}]}
            """);
        try
        {
            Categories.Reload(path);
            Assert.Equal(["econ", "it", "etc"], Categories.All.Select(c => c.Raw()));
            Assert.Equal("경제", Categories.Classify("한은, 금리 동결").Label());
            Assert.Equal("it", Categories.Classify("AI 반도체 수출").Raw());
            Assert.True(Categories.Classify("날씨").IsOther());
            Assert.Equal("it", new NewsItem { Title = "x", Kind = "paper" }.Category.Raw());
            Assert.Equal("#222222", Categories.Parse("econ").Color().Dark);
            Assert.Equal("\"econ\"", Json.Encode(Categories.Parse("econ")));
        }
        finally
        {
            Categories.Reload(Resources.PathOf("ai-topics.json"));
            File.Delete(path);
        }
    }
}
