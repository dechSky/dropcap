import Foundation
import Testing
@testable import Dropcap

// 보안 점검에서 찾은 것: 바깥 HTML 정규식 되풀이 훑기 · 사이트맵 정규식 · 가져오기 정리 · 16진수 IP 표기
@Suite struct SecurityScanTests {
    private func fast(_ limit: TimeInterval = 2, _ body: () throws -> Void) rethrows {
        let t = Date()
        try body()
        #expect(Date().timeIntervalSince(t) < limit)
    }

    @Test func feedImageStillFound() throws {
        let xml = """
        <rss><channel><item><title>T</title><link>https://a.example/1</link>
        <description><![CDATA[<p>x</p><img class="c" data-src="https://a.example/lazy.jpg" src='https://a.example/p.jpg'>]]></description></item>
        <item><title>U</title><link>https://a.example/2</link><description><![CDATA[<IMG data-src="https://a.example/only-lazy.jpg">]]></description></item>
        </channel></rss>
        """
        let e = try FeedParser.parseFeed(Data(xml.utf8))
        #expect(e.map(\.image) == ["https://a.example/p.jpg", "https://a.example/only-lazy.jpg"])
    }

    // 예전 정규식은 "<img " 100KB 에 90초 넘게 걸렸다
    @Test func feedImageOnHostileBodyIsFast() throws {
        let body = String(repeating: "<img ", count: 200_000)
        let xml = "<rss><channel><item><title>T</title><link>https://a.example/1</link><description><![CDATA[\(body)]]></description></item></channel></rss>"
        try fast { _ = try FeedParser.parseFeed(Data(xml.utf8)) }
    }

    @Test func stripTagsMatchesRegexAndIsLinear() {
        for s in ["a<b>c</b>d", "x < y", "<<a>>", "a<b", "<p>한글</p>\n<br/>끝", "", "no tags"] {
            #expect(Plain.stripTags(s) == s.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression), "\(s)")
        }
        let hostile = String(repeating: "<", count: 1_000_000)
        fast { #expect(Plain.clean(hostile).count == 1_000_000) }
    }

    @Test func htmlScanReadsMetaEitherOrder() {
        let html = #"<head><META content="첫 제목" property="og:title"><meta name=description content='설명'><metadata property="og:image" content="x">"#
            + #"<meta property="og:image" content="https://a.example/i.jpg"><title>탭 제목</title></head>"#
        #expect(HTMLScan.meta(html, ["og:title"]) == "첫 제목")
        #expect(HTMLScan.meta(html, ["description"]) == "설명")
        #expect(HTMLScan.meta(html, ["og:image"]) == "https://a.example/i.jpg")   // <metadata> 는 meta 가 아님
        #expect(HTMLScan.title(html) == "탭 제목")
        #expect(HTMLScan.attr(#" data-src="a" src="b""#, "src") == "b")
        #expect(HTMLScan.attr(#" content="닫히지 않음"#, "content") == nil)
    }

    // 예전 정규식은 48KB 에 7초
    @Test func headParsersOnHostilePagesAreFast() {
        let metas = String(repeating: "<meta property='og:title' content=", count: 20_000)
        let links = String(repeating: #"<link rel="alternate" "#, count: 20_000)
        let anchors = String(repeating: "<a x href=", count: 20_000)
        fast(4) {
            _ = HTMLScan.meta(metas, ["og:title", "og:image"])
            _ = SaveLink.parseHead(metas, base: URL(string: "https://a.example/")!)
            _ = IntentLogic.pageTitle(metas)
            _ = SaveLink.firstHref(anchors)
            _ = HTMLScan.tags("link", in: links).map { HTMLScan.attr($0, "href") }
            _ = HTMLScan.title(String(repeating: "<title>", count: 50_000))
        }
    }

    @Test func pageTitleAndHeadStillWork() {
        #expect(IntentLogic.pageTitle(#"<meta content="A &amp; B" property="og:title"><title>t</title>"#) == "A & B")
        #expect(IntentLogic.pageTitle("<html><title> 그냥 제목 </title>") == "그냥 제목")
        let h = SaveLink.parseHead(#"<meta property="og:title" content=""><meta name="twitter:title" content="트윗 제목"><meta property="og:site_name" content="사이트">"#,
                                   base: URL(string: "https://a.example/")!)
        #expect(h.title == "트윗 제목" && h.site == "사이트")
        #expect(SaveLink.firstHref(#"<p><a class=x href="https://a.example/x?a=1&amp;b=2">x</a>"#)?.absoluteString == "https://a.example/x?a=1&b=2")
    }

    @Test func sitemapRegexOnlyFromBundledSources() {
        let bundled = [Source(id: "anthropic", name: "A", tier: "lab", type: "sitemap", url: "https://a.example/sitemap.xml", match: "^https://a\\.example/news/", aiOnly: false, defaultOn: true, color: "#000")]
        let same = bundled[0]
        let evil = Source(id: "custom-x", name: "X", tier: "press", type: "sitemap", url: "https://x.example/s.xml", match: "^(a+)+$", aiOnly: false, defaultOn: true, color: "#000")
        let changed = Source(id: "anthropic", name: "A", tier: "lab", type: "sitemap", url: "https://a.example/sitemap.xml", match: "^(a+)+$", aiOnly: false, defaultOn: true, color: "#000")
        #expect(FeedService.sitemapPattern(same, bundled: bundled) == "^https://a\\.example/news/")
        #expect(FeedService.sitemapPattern(evil, bundled: bundled) == nil)
        #expect(FeedService.sitemapPattern(changed, bundled: bundled) == nil)
    }

    @Test func hexIPHostsAreNotPublic() {
        for u in ["http://0x7f.0.0.0xa/", "http://0xc0.0xa8.0x1.0xa/", "http://0x7f000001/", "http://0x7f.1/"] {
            #expect(!URLSafety.isPublicHTTP(URL(string: u)), "\(u)")
        }
        for u in ["https://cafe.example/", "https://0x.com/", "https://abc.de/", "https://8.8.8.8/"] {
            #expect(URLSafety.isPublicHTTP(URL(string: u)), "\(u)")
        }
    }
}

@Suite struct BackupSanitizeTests {
    private func decode(_ json: String) throws -> BackupFile { try Backup.decode(Data(json.utf8)) }

    @Test func clampsSettingsFromFile() throws {
        let b = try decode(#"""
        {"format":"dropcap-backup","version":1,"settings":{"intervalMinutes":9223372036854775807,"quietStart":99,"digestHour":-4,
         "totalDailyCap":100000,"krThreshold":0,"bigThreshold":1,"mustKeywords":["  a ","A","","\#(String(repeating: "x", count: 41))"]},
         "sectionPolicy":{"economy":{"mode":"bundle","bundleHour":99,"dailyCap":-1},"nope":{"mode":"bundle"}},
         "sectionsChosen":["ai","ai","nope"]}
        """#)
        #expect(b.settings.intervalMinutes == 5)
        #expect(b.settings.quietStart == 23 && b.settings.digestHour == 5)
        #expect(b.settings.totalDailyCap == 30 && b.settings.krThreshold == 1 && b.settings.bigThreshold == 2)
        #expect(b.settings.mustKeywords == ["a"])
        #expect(b.sectionPolicy.keys.sorted() == ["economy"])
        #expect(b.sectionPolicy["economy"]?.bundleHour == 23 && b.sectionPolicy["economy"]?.dailyCap == 1)
        #expect(b.sectionsChosen == ["ai"])
    }

    @Test func stateFileClampsInterval() throws {
        let s = try JSONDecoder().decode(AppState.Settings.self, from: Data(#"{"intervalMinutes":9223372036854775807}"#.utf8))
        #expect(s.intervalMinutes == 24 * 60)
        let z = try JSONDecoder().decode(AppState.Settings.self, from: Data(#"{"intervalMinutes":0}"#.utf8))
        #expect(z.intervalMinutes == 1)
    }

    @Test func customSourcesBecomePublicFeedsOnly() throws {
        let b = try decode(#"""
        {"format":"dropcap-backup","version":1,"customSources":[
          {"id":"openai","name":"가짜 OpenAI","tier":"lab","type":"feed","url":"https://evil.example/feed","aiOnly":false,"defaultOn":true,"color":"#000"},
          {"id":"custom-inside","name":"안쪽","tier":"press","type":"feed","url":"http://192.168.0.1/feed","aiOnly":false,"defaultOn":true,"color":"#000"},
          {"id":"custom-re","name":"정규식","tier":"weird","type":"sitemap","url":"https://x.example/s.xml","match":"^(a+)+$","aiOnly":true,"defaultOn":true,"color":"red;}","home":"file:///etc"}]}
        """#)
        #expect(b.customSources.map(\.id) == ["custom-re"])
        let s = try #require(b.customSources.first)
        #expect(s.type == "feed" && s.match == nil && !s.aiOnly && s.tier == "press" && s.color == "#3B82F6" && s.home == nil)
    }

    @Test func savedAndScrapsNeedPublicLinks() throws {
        func item(_ link: String) -> String {
            #"{"id":"\#(link)","title":"t","link":"\#(link)","summary":"","sourceId":"s","sourceName":"S","tier":"press"}"#
        }
        let b = try decode(#"""
        {"format":"dropcap-backup","version":1,"saved":[\#(item("https://a.example/1")),\#(item("file:///etc/passwd"))],
         "scraps":[{"id":"s1","item":\#(item("https://a.example/1")),"memo":"","collection":"\#(String(repeating: "폴", count: 61))","created":"2026-10-14T00:00:00Z"},
                   {"id":"s2","item":\#(item("javascript:alert(1)")),"memo":"","collection":"보고서","created":"2026-10-14T00:00:00Z"}],
         "scrapFolders":[" 보고서 ","보고서",""]}
        """#)
        #expect(b.saved.map(\.link) == ["https://a.example/1"])
        #expect(b.scraps.map(\.id) == ["s1"] && b.scraps.first?.collection == "스크랩")
        #expect(b.scrapFolders == ["보고서"])
    }
}
