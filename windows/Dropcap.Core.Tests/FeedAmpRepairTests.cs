using System.Text;
using Dropcap.Core;

namespace Dropcap.Core.Tests;

// 맥 FeedAmpRepairTests 를 옮긴 것: 이스케이프 안 된 & 가 있는 피드(Rest of World 사진 주소 '?width=380&dpr=2&crop=16:9')도
// 엔티티가 아닌 & 만 고쳐 한 번 더 읽는다
public class FeedAmpRepairTests
{
    private const string Broken = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/"><channel><title>Rest of World - </title>
        <item><title>A &amp; B</title><link>https://example.com/a?x=1&amp;y=2</link><guid>a</guid>
        <media:content medium="image" url="https://example.com/a.jpg?width=380&dpr=2&crop=16:9" width="760" />
        <description><![CDATA[R&D &amp; more]]></description></item>
        <item><title>Tom & Jerry &#38; &#x26; co</title><link>https://example.com/b</link><guid>b</guid><!-- a & b --></item>
        </channel></rss>
        """;

    [Fact]
    public void BrokenAmpersandFeedParsesAllItems()
    {
        var items = FeedParser.ParseFeed(Encoding.UTF8.GetBytes(Broken));
        Assert.Equal(2, items.Count);
        Assert.Equal("A & B", items[0].Title);
        Assert.Equal("https://example.com/a?x=1&y=2", items[0].Link);
        Assert.Equal("https://example.com/a.jpg?width=380&dpr=2&crop=16:9", items[0].Image);
        Assert.Equal("Tom & Jerry & & co", items[1].Title);
    }

    [Fact]
    public void RepairLeavesEntitiesCdataAndCommentsAlone()
    {
        var fixedData = FeedParser.RepairAmpersands(Encoding.UTF8.GetBytes(Broken));
        Assert.NotNull(fixedData);
        var s = Encoding.UTF8.GetString(fixedData);
        Assert.Contains("?width=380&amp;dpr=2&amp;crop=16:9", s);
        Assert.Contains("<![CDATA[R&D &amp; more]]>", s);
        Assert.Contains("<!-- a & b -->", s);
        Assert.Contains("Tom &amp; Jerry &#38; &#x26; co", s);
        Assert.Contains("x=1&amp;y=2", s);
        Assert.DoesNotContain("&amp;amp;", s);
    }

    [Fact]
    public void WellFormedFeedNeedsNoRepair()
    {
        const string ok = "<rss><channel><item><title>A &amp; B &lt;3 &#169;</title><description><![CDATA[x & y]]></description></item></channel></rss>";
        Assert.Null(FeedParser.RepairAmpersands(Encoding.UTF8.GetBytes(ok)));
        Assert.Null(FeedParser.RepairAmpersands([0xFF, 0xFE, 0x26, 0x00])); // UTF-16 은 건드리지 않음
    }
}
