import Foundation
import Testing
@testable import Dropcap

// 읽기 창 3단계: 피드 전문 우선 · 표 · 사진 설명 · 본문 중간 추천 상자.
// 실제 꼴은 mac/scripts/scramble_fixture.py 로 글·주소를 바꾼 것(표지 낱말만 원래 자리에), 나머지는 지어낸 HTML.
private func para(_ n: Int, _ topic: String = "harbor") -> String {
    "Paragraph \(n) explains how the \(topic) authority weighed the proposal, listened to residents and set out a schedule for the work."
}
private let base = URL(string: "https://example.com/2026/10/story")!
private func fixture(_ name: String) -> String {
    let u = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/reader-cut/\(name).html")
    return (try? String(contentsOf: u, encoding: .utf8)) ?? ""
}
private actor SentLog { var all: [String] = []; func add(_ s: String) { all.append(s) } }
private func blocks(_ html: String) async -> [Block] { await ArticleExtractor().extractHTML(html, base: base)?.blocks ?? [] }

@MainActor @Suite(.serialized) struct ReaderTableTests {
    // 실제 꼴: AWS(첫 행 셀이 모두 굵은 글 = 머리행, th 없음) · Hugging Face(thead/th)
    @Test(arguments: [("table-rows", 4), ("table-thead", 5)])
    func realTables(_ name: String, _ columns: Int) async {
        let b = await blocks(fixture(name))
        let rows = b.filter { $0.type == .row }
        let marked = rows.first { $0.cells?.contains { $0.contains("TABLEROW") } == true }
        #expect(marked != nil, "\(name): 표 행")
        #expect(marked?.cells?.count == columns, "\(name): 셀 수")
        #expect(rows.contains { $0.head == true }, "\(name): 머리행")
        #expect(marked?.text == marked?.cells?.joined(separator: " · "))
        #expect(!b.contains { $0.type == .p && $0.text?.contains("TABLEROW") == true }, "\(name): 셀이 문단으로 흩어짐")
    }

    @Test func layoutTableWalksInside() async {
        // 칸 하나짜리·사진이 든 표는 자리 잡기용 — 안의 글을 문단으로
        let html = """
        <html><body><article><h1>T</h1>\((1...4).map { "<p>\(para($0))</p>" }.joined())
        <table><tr><td><img src="https://img.example.com/1.jpg"></td></tr><tr><td>Photo description under the picture</td></tr></table>
        <table><tr><td><p>\(para(5))</p></td></tr><tr><td><p>\(para(6))</p></td></tr></table></article></body></html>
        """
        let b = await blocks(html)
        #expect(!b.contains { $0.type == .row })
        #expect(b.contains { $0.text == para(6) })
    }

    @Test func groupedTranslationKeepsShape() async {
        // 번역 묶음: 셀마다 번역하고 숫자 셀은 보내지 않으며 같은 모양으로 돌아온다(가짜 엔진 — 네트워크 없음)
        let sent = SentLog()
        let t = Translator(mode: .google, google: { s in
            await sent.add(s)
            return s.components(separatedBy: "\n\n").map { "번역 " + $0 }.joined(separator: "\n\n")
        })
        let (out, _) = await t.translateGroupsReporting([["Benchmark", "20.3%", "Legal work"], ["A paragraph."]])
        #expect(out.map(\.count) == [3, 1])
        #expect(out[0][1] == "20.3%")
        #expect(out[0][0].hasPrefix("번역") && out[0][2].hasPrefix("번역") && out[1][0].hasPrefix("번역"))
        #expect(await !sent.all.contains { $0.contains("20.3%") })
    }

    @Test func rowBlockRoundTrips() throws {
        // 저장한 기사(PreparedArticle)에 셀·머리행이 남고, 셀이 없는 예전 블록도 읽힌다
        let b = Block(type: .row, text: "a · b", cells: ["a", "b"], head: true)
        let back = try JSONDecoder().decode(Block.self, from: JSONEncoder().encode(b))
        #expect(back.cells == ["a", "b"] && back.head == true)
        let old = try JSONDecoder().decode(Block.self, from: Data(#"{"type":"p","text":"x"}"#.utf8))
        #expect(old.cells == nil && old.head == nil)
    }
}

@MainActor @Suite(.serialized) struct ReaderCaptionTests {
    // 실제 꼴: 경향 p.caption · 노컷 span.fr-inner · CNBC 설명+출처 div · NPR .credit-caption
    @Test(arguments: [("caption-p", "CAPMARK"), ("caption-span", "CAPMARK"), ("caption-credit", "CAPMARK"), ("caption-credit", "CREDITMARK"), ("credit-caption", "CREDITMARK")])
    func realCaptions(_ name: String, _ mark: String) async {
        let b = await blocks(fixture(name))
        #expect(b.contains { $0.type == .cap && $0.text?.contains(mark) == true }, "\(name): \(mark) 가 설명으로")
        #expect(!b.contains { $0.type == .p && $0.text?.contains(mark) == true }, "\(name): \(mark) 가 문단으로")
    }

    @Test func creditLinesBecomeCaptions() async {
        // class 없이 문단으로 온 출처 줄: 사진 뒤면 설명으로(이어진 설명은 하나로), 사진 앞이면 사진 뒤로 옮겨 설명으로
        let html = """
        <html><body><article><h1>T</h1><p>\(para(1))</p>
        <p><img src="https://img.example.com/a.jpg"></p><p>A crane lifts a container at the port.</p><p>Jane Roe/Getty Images</p>
        <p>\(para(2))</p><p>\(para(3))</p>
        <p>항만 크레인이 컨테이너를 옮기고 있다. 항만공사 제공</p><p><img src="https://img.example.com/b.jpg"></p>
        <p>\(para(4))</p><p>\(para(5))</p></article></body></html>
        """
        let b = await blocks(html)
        let i = b.firstIndex { $0.src?.hasSuffix("a.jpg") == true }
        #expect(i.map { b[$0 + 1].type == .cap && b[$0 + 1].text?.contains("Getty") == true } == true)
        #expect(!b.contains { $0.type == .p && $0.text?.contains("Getty") == true })
        let j = b.firstIndex { $0.src?.hasSuffix("b.jpg") == true }
        #expect(j.map { b[$0 + 1].type == .cap && b[$0 + 1].text?.hasSuffix("제공") == true } == true)
        #expect(b.contains { $0.text == para(5) })
    }

    @Test func ordinarySentenceStaysParagraph() async {
        // 사진과 떨어진 문단·긴 문단은 그대로(끝말이 '제공'이어도)
        let html = """
        <html><body><article><h1>T</h1>\((1...3).map { "<p>\(para($0))</p>" }.joined())<p>시는 주민 모두에게 같은 안내문을 제공</p>\((4...6).map { "<p>\(para($0))</p>" }.joined())</article></body></html>
        """
        let b = await blocks(html)
        #expect(!b.contains { $0.type == .cap })
    }
}

@MainActor @Suite(.serialized) struct ReaderRecommendBoxTests {
    // 실제 꼴: ZDNet 본문 가운데 h2 '관련기사' + div.news_box 링크 목록 — 상자는 빠지고 뒤 문단은 남아야
    @Test func realInlineRelated() async {
        let b = await blocks(fixture("inline-related"))
        #expect(!b.contains { $0.text?.contains("RELMARK") == true }, "관련 기사 목록")
        #expect(b.contains { $0.text?.contains("AFTERBOX") == true }, "상자 뒤 본문")
    }

    @Test func recommendedStoriesBox() async {
        // Al Jazeera 꼴: 본문 셋째 문단 뒤 'Recommended Stories' + 링크 li 목록(class 없음)
        let html = """
        <html><body><main><article><h1>T</h1><div class="wysiwyg">\((1...3).map { "<p>\(para($0))</p>" }.joined())
        <div><h2>Recommended Stories</h2><ul><li><a href="/a">Another headline about a different event</a></li><li><a href="/b">Second headline about something else</a></li><li><a href="/c">Third headline far away</a></li></ul></div>
        \((4...8).map { "<p>\(para($0))</p>" }.joined())</div></article></main></body></html>
        """
        let b = await blocks(html)
        #expect(!b.contains { $0.text?.contains("Recommended") == true || $0.text?.contains("headline") == true })
        #expect(b.contains { $0.text == para(8) })
    }

    @Test func listWithoutLinksStays() async {
        // 안전장치: 제목이 같아도 링크 목록이 아니면(기사 속 정리 목록) 그대로
        let html = """
        <html><body><article><h1>T</h1>\((1...3).map { "<p>\(para($0))</p>" }.joined())
        <h3>Related</h3><ul><li>The council will vote on the budget in November after two hearings.</li><li>Residents can send comments by mail until the end of the month.</li></ul>
        \((4...6).map { "<p>\(para($0))</p>" }.joined())</article></body></html>
        """
        let b = await blocks(html)
        #expect(b.contains { $0.type == .li && $0.text?.contains("council will vote") == true })
    }
}

@MainActor @Suite(.serialized) struct FeedFullBodyTests {
    private let feedParas = (1...12).map { para($0, "river") }
    private var feedXML: String {
        let body = feedParas.map { "<p>\($0)</p>" }.joined() + "<script>track()</script>"
        return """
        <?xml version="1.0"?><rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><title>F</title>
        <item><title>River</title><link>https://example.com/2026/10/river</link><guid>r1</guid><description>Short teaser.</description>
        <content:encoded><![CDATA[\(body)]]></content:encoded></item>
        <item><title>Short</title><link>https://example.com/2026/10/short</link><guid>s1</guid><description>Short.</description>
        <content:encoded><![CDATA[<p>Only a teaser paragraph here.</p>]]></content:encoded></item></channel></rss>
        """
    }

    @Test func parserKeepsFullBodyOnly() throws {
        let e = try FeedParser.parseFeed(Data(feedXML.utf8))
        #expect(e[0].body?.contains(feedParas[11]) == true)
        #expect(e[0].body?.contains("track()") == false)
        #expect(e[1].body == nil) // 요약뿐인 content:encoded 는 두지 않음
        let long = "<p>" + String(repeating: "word ", count: 30_000) + "</p>"
        #expect(FeedParser.compactBody(long + long).count <= FeedParser.bodyMaxHTML)
    }

    @Test func newsItemWithoutFeedBodyStillDecodes() throws {
        // 예전 기록(DB json·다른 기기)에는 feedBody 가 없다
        let old = #"{"id":"a","title":"t","link":"https://example.com","summary":"","sourceId":"s","sourceName":"S","tier":"intl"}"#
        let item = try JSONDecoder().decode(NewsItem.self, from: Data(old.utf8))
        #expect(item.feedBody == nil)
    }

    @Test func siteShowsOnlyLeadSoFeedWins() async throws {
        // Politico 꼴: 사이트는 앞 4문단에서 끝나고 피드에는 12문단 — 피드 쪽을 써야
        let site = "<html><head><title>River</title></head><body><article><h1>River</h1>" + feedParas.prefix(4).map { "<p>\($0)</p>" }.joined()
            + "<div class=\"newsletter\">Sign up for the newsletter</div></article></body></html>"
        let siteBlocks = await blocks(site)
        let body = try #require(try FeedParser.parseFeed(Data(feedXML.utf8))[0].body)
        #expect(FeedFullBody.worthTrying(feedHTML: body, extracted: siteBlocks))
        let feed = await blocks(FeedFullBody.page(body, title: "River"))
        #expect(feed.contains { $0.text == feedParas[11] })
        #expect(FeedFullBody.prefer(feed: feed, over: siteBlocks))
    }

    @Test func otherStoryOrSimilarLengthKeepsSite() async {
        let site = feedParas.map { Block(type: .p, text: $0) }
        let feed = site + [Block(type: .p, text: para(13, "river"))]
        #expect(!FeedFullBody.prefer(feed: feed, over: site))                    // 비슷한 길이
        let other = (1...30).map { Block(type: .p, text: para($0, "airport")) }
        #expect(!FeedFullBody.prefer(feed: other, over: Array(site.prefix(4))))  // 다른 기사
        #expect(FeedFullBody.prefer(feed: feed, over: []))                       // 사이트에서 못 추림
        #expect(!FeedFullBody.worthTrying(feedHTML: nil, extracted: site))
    }
}

@MainActor @Suite(.serialized) struct VergeShortArticleTests {
    // 사용자 사례(Verge 짧은 기사): 사이트가 늘 isAccessibleForFree=false 라고 적지만 4문단 약 900자가 전문 — ld+json articleBody 도 같은 글
    private let paras = (1...4).map { "Paragraph \($0) of a short news story explains what the consulting firm told clients about the new tool this week." + String(repeating: " More detail follows here.", count: 3) }
    private func page(ld: String) -> String {
        let ldJSON = #"{"@context":"https://schema.org","@type":"NewsArticle","isAccessibleForFree":false,"articleBody":"\#(ld)"}"#
        // 실제 꼴처럼 앞에 기자 이름·소개, 끝에 'Follow topics…' 가 붙는다(군더더기 — 읽기 창에서 빠짐)
        return "<html><head><title>Short</title><script type=\"application/ld+json\">\(ldJSON)</script></head><body><article><h1>Short</h1>"
            + "<p>Pat Example</p><p>is a senior reporter covering technology, gaming, and more. Pat joined the site in 2019 after years elsewhere.</p>"
            + paras.map { "<p>\($0)</p>" }.joined()
            + "<p>Follow topics and authors from this story to see more like this in your personalized homepage feed.</p></article></body></html>"
    }

    @Test func shortFullStoryIsNotTeaser() async throws {
        let a = try #require(await ArticleExtractor().extractHTML(page(ld: paras.joined(separator: " ")), base: base))
        #expect(a.paid == true)
        #expect(a.ldBody != nil)
        #expect(!Paywall.isTeaser(a.blocks, paid: a.paid, kind: .metered, ldBody: a.ldBody))
    }

    @Test func siteBodyMuchLongerStillTeaser() async throws {
        // ld 본문이 훨씬 길면(사이트가 전문을 적었는데 우리는 앞부분만) 그대로 맛보기
        let long = (paras + paras + paras + paras + paras).joined(separator: " ")
        let a = try #require(await ArticleExtractor().extractHTML(page(ld: long), base: base))
        #expect(Paywall.isTeaser(a.blocks, paid: a.paid, kind: .metered, ldBody: a.ldBody))
        #expect(Paywall.isTeaser(a.blocks, paid: a.paid, kind: .metered, ldBody: nil)) // ld 가 없으면 예전 규칙
        #expect(Paywall.isTeaser(a.blocks, paid: nil, kind: .hard, ldBody: a.ldBody)) // 하드 유료 규칙은 그대로
    }

    @Test func ldBodyLengthReadsNestedGraph() {
        let html = #"<script type="application/ld+json">{"@graph":[{"@type":"WebPage"},{"@type":"NewsArticle","articleBody":"One  two\n three <b>four</b>"}]}</script>"#
        #expect(ArticleExtractor.ldBodyLength(Data(html.utf8)) == "One two three four".count)
        #expect(ArticleExtractor.ldBodyLength(Data("<p>none</p>".utf8)) == nil)
    }
}
