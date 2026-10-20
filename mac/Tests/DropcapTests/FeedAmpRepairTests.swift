import Foundation
import Testing
@testable import Dropcap

// 이스케이프 안 된 & 가 있는 피드(Rest of World 사진 주소 '?width=380&dpr=2&crop=16:9')도 엔티티가 아닌 & 만 고쳐 한 번 더 읽는다
@Suite struct FeedAmpRepairTests {
    static let broken = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/"><channel><title>Rest of World - </title>
    <item><title>A &amp; B</title><link>https://example.com/a?x=1&amp;y=2</link><guid>a</guid>
    <media:content medium="image" url="https://example.com/a.jpg?width=380&dpr=2&crop=16:9" width="760" />
    <description><![CDATA[R&D &amp; more]]></description></item>
    <item><title>Tom & Jerry &#38; &#x26; co</title><link>https://example.com/b</link><guid>b</guid><!-- a & b --></item>
    </channel></rss>
    """

    @Test func brokenAmpersandFeedParsesAllItems() throws {
        let items = try FeedParser.parseFeed(Data(Self.broken.utf8))
        #expect(items.count == 2)
        #expect(items[0].title == "A & B")
        #expect(items[0].link == "https://example.com/a?x=1&y=2")
        #expect(items[0].image == "https://example.com/a.jpg?width=380&dpr=2&crop=16:9")
        #expect(items[1].title == "Tom & Jerry & & co")
    }

    @Test func repairLeavesEntitiesCdataAndCommentsAlone() throws {
        let fixed = try #require(FeedParser.repairAmpersands(Data(Self.broken.utf8)))
        let s = String(decoding: fixed, as: UTF8.self)
        #expect(s.contains("?width=380&amp;dpr=2&amp;crop=16:9"))
        #expect(s.contains("<![CDATA[R&D &amp; more]]>"))
        #expect(s.contains("<!-- a & b -->"))
        #expect(s.contains("Tom &amp; Jerry &#38; &#x26; co"))
        #expect(s.contains("x=1&amp;y=2") && !s.contains("&amp;amp;"))
    }

    @Test func wellFormedFeedNeedsNoRepair() {
        let ok = "<rss><channel><item><title>A &amp; B &lt;3 &#169;</title><description><![CDATA[x & y]]></description></item></channel></rss>"
        #expect(FeedParser.repairAmpersands(Data(ok.utf8)) == nil)
        #expect(FeedParser.repairAmpersands(Data([0xFF, 0xFE, 0x26, 0x00])) == nil) // UTF-16 은 건드리지 않음
    }
}
