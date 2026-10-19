using System.Text;
using Dropcap.Core;

namespace Dropcap.Core.Tests;

// 맥 mac/Tests/DropcapTests/PaywallEarlyTests.swift 를 옮긴 것 — 유료 기사를 목록 단계에서 알리기(paywall-early):
// ① 피드가 기사마다 적은 유료 표시(feed-paid-mark) ② 미리 받기에서 맛보기로 판정된 기사(teaser-mark)
public class FeedPaidMarkTests
{
    private static byte[] B(string s) => Encoding.UTF8.GetBytes(s);

    private static NewsItem Item(string id, string source, string link, bool? paid = null) => new()
    {
        Id = id, Title = $"Title {id}", Link = link, Date = DateTimeOffset.Now, SourceId = source, SourceName = source.ToUpperInvariant(), Tier = "press", Paid = paid,
    };

    // 2026-10-16 실제 피드에서 본 표시 꼴(글·주소는 지어냄)
    private const string FeedXml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/"><channel><title>T</title>
        <item><title>STAT+: Example drug maker posts results</title><link>https://news.example/a</link><category><![CDATA[Biotech]]></category></item>
        <item><title>Plain story</title><link>https://news.example/b</link><category><![CDATA[STAT+]]></category></item>
        <item><title>Another plain story</title><link>https://news.example/c</link><category><![CDATA[Artificial intelligence]]></category><category><![CDATA[Subscriber-Only Stories]]></category></item>
        <item><title>Exempt story</title><link>https://news.example/d</link><category>Research</category><category>internal-paywall-exempt</category></item>
        <item><title>No mark</title><link>https://news.example/e</link><category>Premium cars</category></item>
        <item><title>Mid STAT+: not a prefix</title><link>https://news.example/f</link></item>
        </channel></rss>
        """;

    private const string AtomXml = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom"><title>T</title>
        <entry><title>A</title><id>a</id><link href="https://news.example/a"/><category term="Subscriber-Only Stories"/></entry>
        <entry><title>B</title><id>b</id><link href="https://news.example/b"/></entry>
        </feed>
        """;

    [Fact]
    public void RssMarks() =>
        Assert.Equal(new bool?[] { true, true, true, false, null, null }, FeedParser.ParseFeed(B(FeedXml)).Select(e => e.Paid).ToArray());

    [Fact]
    public void AtomCategoryTerm() =>
        Assert.Equal(new bool?[] { true, null }, FeedParser.ParseFeed(B(AtomXml)).Select(e => e.Paid).ToArray());

    // 기사 단위 값이 출처 값보다 앞선다
    [Fact]
    public void ArticleMarkBeatsSource()
    {
        var meta = new Dictionary<string, SourceMeta> { ["stat"] = new("stat", Paywall: "metered"), ["nyt"] = new("nyt", Paywall: "hard") };
        Assert.Equal(PaywallKind.Hard, Paywall.Kind("stat", "https://www.statnews.com/a", meta, paid: true));
        Assert.Equal(PaywallKind.Metered, Paywall.Kind("stat", "https://www.statnews.com/a", meta));
        Assert.Null(Paywall.Kind("nyt", "https://www.nytimes.com/a", meta, paid: false));
        Assert.Equal(PaywallKind.Hard, Paywall.Kind("x", "https://free.example/a", meta, paid: true));
        // 배운 막힘보다도 앞선다
        var many = new Dictionary<string, Database.ExtractStat> { ["x"] = new(10, 8, 0) };
        Assert.Null(Paywall.Kind("x", "https://free.example/a", meta, many, paid: false));
    }

    // 피드 표시가 무료 보도 고르기에도 쓰인다: 유료 표시 기사는 권하지 않고, 풀린 기사는 권한다
    [Fact]
    public void AlternativesUseArticleMark()
    {
        var meta = new Dictionary<string, SourceMeta> { ["nyt"] = new("nyt", Paywall: "hard"), ["stat"] = new("stat") };
        var me = Item("0", "wsj", "https://wsj.example/0");
        var story = new[] { me, Item("1", "nyt", "https://nyt.example/1", paid: false), Item("2", "stat", "https://stat.example/2", paid: true) };
        Assert.Equal(["nyt"], Paywall.FreeAlternatives(me, story, new HashSet<string>(), meta).Select(i => i.SourceId));
        Assert.Empty(Paywall.FreeAlternatives(me, story, new HashSet<string>(), meta, teasers: new HashSet<string> { "https://nyt.example/1" }));
    }

    [Fact]
    public void OldRecordWithoutPaidDecodes()
    {
        var old = """{"id":"a","title":"T","link":"https://x.example/a","summary":"","sourceId":"s","sourceName":"S","tier":"press"}""";
        Assert.Null(Json.Decode<NewsItem>(old)!.Paid);
        Assert.True(Json.Decode<NewsItem>(Json.Encode(Item("a", "s", "https://x.example/a", paid: true)))!.Paid);
    }
}

public class TeaserMarkTests : IDisposable
{
    private readonly TempDir tmp = new();
    public void Dispose() => tmp.Dispose();

    private static Block P(string s) => new() { Type = BlockKind.P, Text = s };
    private static NewsItem Item(string link) => new() { Id = "t", Title = "T", Link = link, SourceId = "kr-test", SourceName = "KR", Tier = "kr" };

    [Fact]
    public void StoreRoundTripAndExpiry()
    {
        using var db = new Database(Path.Combine(tmp.Path, "magazine.sqlite"));
        var now = DateTimeOffset.Now;
        db.MarkTeaser("https://a.example/2", true, now.AddDays(-40));
        db.MarkTeaser("https://a.example/1", true, now);
        Assert.Equal(["https://a.example/1"], db.TeaserLinks(now));
        db.MarkTeaser("https://a.example/1", false, now);
        Assert.Empty(db.TeaserLinks(now));
        db.MarkTeaser("https://a.example/3", true, now.AddHours(1));   // 미래 시각은 다음 기록 때 버림
        db.MarkTeaser("https://a.example/4", true, now);
        Assert.Equal(["https://a.example/4"], db.TeaserLinks(now));
    }

    // 미리 받기에서 맛보기 → 목록 자물쇠가 '앞부분만'(다른 자물쇠와 구분) · 다시 받아 전문이면 지움 · 다른 앱 실행에서도 남음
    [Fact]
    public void PrefetchTeaserShowsInList()
    {
        using var db = new Database(Path.Combine(tmp.Path, "magazine.sqlite"));
        var book = new PaywallBook(db);
        var it = Item("https://kr.example/article/000000000i");
        Assert.Null(book.Kind(it));
        var teaser = new List<Block> { P(new string('가', 300)), P(new string('나', 250)) };
        var judged = Paywall.IsTeaser(teaser, true, book.SourceKind(it));   // 한경 articlePayment="Y" + 짧은 본문
        Assert.True(judged);
        var fired = 0;
        book.TeasersChanged += () => fired++;
        book.RecordTeaser(it, judged);
        Assert.Equal(1, fired);
        Assert.Equal(PaywallKind.Teaser, book.Kind(it));
        Assert.Equal("앞부분만", book.Kind(it)!.Value.ShortText());
        Assert.Null(PaywallKind.Hard.ShortText());
        Assert.Null(PaywallKind.Metered.ShortText());
        Assert.Contains("앞부분만 공개한", PaywallKind.Teaser.Help());
        Assert.Null(book.SourceKind(it));                                // 판정에 넘기는 값은 지난 판정에 끌려가지 않음
        Assert.Equal(PaywallKind.Teaser, new PaywallBook(db).Kind(it));
        book.RecordTeaser(it, false);
        Assert.Null(book.Kind(it));
        Assert.Null(new PaywallBook(db).Kind(it));
    }

    // 다시 맛보기로 판정되면 시각을 새로 써서, 계속 맛보기인 기사가 처음 판정 30일 뒤에 빠지지 않는다(표시는 그대로라 다시 그리지 않음)
    [Fact]
    public void TeaserAgainRefreshesTime()
    {
        using var db = new Database(Path.Combine(tmp.Path, "magazine.sqlite"));
        const string link = "https://kr.example/article/000000001i";
        db.MarkTeaser(link, true, DateTimeOffset.Now.AddDays(-29));
        var book = new PaywallBook(db);
        var fired = 0;
        book.TeasersChanged += () => fired++;
        book.RecordTeaser(Item(link), true);
        Assert.Equal(0, fired);
        Assert.Contains(link, db.TeaserLinks(DateTimeOffset.Now.AddDays(2)));   // 고치기 전: 29+2일 → 빠짐
    }

    // 알림 미리 받기와 사용자가 연 기사가 함께 남겨도 메모리 표시가 사라지지 않는다
    [Fact]
    public void ConcurrentRecordsAllKept()
    {
        using var db = new Database(Path.Combine(tmp.Path, "magazine.sqlite"));
        for (var round = 0; round < 2; round++)
        {
            var book = new PaywallBook(db) { BeforeSwap = () => Thread.Sleep(1) };   // 사본을 만들고 바꿔 넣기까지의 틈을 넓힘
            var links = Enumerable.Range(0, 40).Select(n => $"https://kr.example/{round}/article/{n}").ToList();
            using var go = new ManualResetEventSlim();
            var workers = Enumerable.Range(0, 8).Select(w => Task.Run(() =>
            {
                go.Wait();
                for (var i = w; i < links.Count; i += 8) book.RecordTeaser(Item(links[i]), true);
            })).ToArray();
            go.Set();
            Task.WaitAll(workers);
            Assert.Equal(40, book.Teasers.Count(l => l.Contains($"/{round}/")));
        }
    }

    private sealed class FakeExtract(Article art) : IArticleExtractor
    {
        public Task<Article?> FromHtmlAsync(string html, Uri baseUri) => Task.FromResult<Article?>(art);
        public Task<Article?> FromLiveAsync(Uri url) => Task.FromResult<Article?>(null);
    }

    // 서비스: 미리 받기(interactive=false)가 맛보기로 판정하면 기사 단위로 남긴다 — 사용자 기록(RecordExtract)은 세지 않음
    [Fact]
    public async Task ServicePrefetchRecordsTeaser()
    {
        using var db = new Database(Path.Combine(tmp.Path, "magazine.sqlite"));
        var book = new PaywallBook(db);
        var art = new Article { Title = "증권", Blocks = Enumerable.Range(1, 6).Select(n => P(ReaderCutText.KPara(n))).ToList() };
        var svc = new ArticleService(new FakeExtract(art), () => [], Path.Combine(tmp.Path, "articles"))
        {
            RecordExtract = (_, _, _) => throw new InvalidOperationException("미리 받기는 세지 않음"),
            Fetch = _ => Task.FromResult<(byte[], string?)?>((Encoding.UTF8.GetBytes("<script>var articlePayment = \"Y\";</script>"), "utf-8")),
            KindOf = book.SourceKind,
            RecordTeaser = book.RecordTeaser,
        };
        var it = Item("https://kr.example/article/1");
        var a = await svc.PrepareAsync(it, interactive: false);
        Assert.True(a.Paywalled);
        Assert.Equal(PaywallKind.Teaser, book.Kind(it));
    }
}
