import Foundation
import Network
import Testing
@testable import Dropcap

// 보안 점검(2026-10-15) 낮음 X2 · M15
@Suite(.serialized) struct SecurityLow3Tests {
    // X2: 여러 덩어리 모으기의 상자를 살아 있는 문서(document)에 만들면 붙인 <img> 가 받기·onerror 를 돌릴 수 있다.
    // 추출 스크립트는 사본(doc·fresh)·DOMParser 문서에서만 노드를 만든다
    @Test @MainActor func extractScriptBuildsOnlyInInertDocuments() {
        let s = ArticleExtractor.script
        for live in ["document.createElement", "document.importNode", "document.adoptNode", "document.body.append", "document.write"] {
            #expect(!s.contains(live), "\(live)")
        }
        #expect(s.contains("fresh.createElement('div')"))
    }

    // M15: 피드 본문은 글 링크가 출처 피드와 같은 사이트일 때만
    @Test func sameSiteRule() {
        #expect(FeedService.sameSite("https://arstechnica.com/ai/2026/10/x/", "https://feeds.arstechnica.com/arstechnica/index"))
        #expect(FeedService.sameSite("https://www.politico.com/news/a", "https://rss.politico.com/politics-news.xml"))
        #expect(FeedService.sameSite("https://news.sbs.co.kr/news/a", "https://news.sbs.co.kr/news/rss.do"))
        #expect(FeedService.sameSite("https://www.donga.com/news/a", "https://rss.donga.com/total.xml"))
        #expect(FeedService.sameSite("https://WWW.Axios.com/a", "https://api.axios.com/feed/"))
        #expect(!FeedService.sameSite("https://www.theverge.com/a", "https://hnrss.org/frontpage"))
        #expect(!FeedService.sameSite("https://www.chosun.co.kr/a", "https://rss.donga.co.kr/x")) // co.kr 끼리라도 다른 사이트
        #expect(!FeedService.sameSite("https://evil.example/a", "https://feeds.example.org/x"))
        #expect(!FeedService.sameSite("not a url", "https://feeds.example.org/x"))
        #expect(FeedService.siteKey("feeds.bbci.co.uk") == "bbci.co.uk")
        #expect(FeedService.siteKey("10.0.0.1") == "10.0.0.1")
    }

    // 실제 받기: 다른 사이트 링크에 실린 본문은 버리고 제목·요약만 남긴다
    @Test func foreignLinkDropsFeedBody() async throws {
        let body = String(repeating: "<p>본문 문단입니다. 이 글은 피드가 실어 준 전문의 한 부분입니다.</p>", count: 40)
        let rss = """
        <?xml version="1.0"?><rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><title>t</title>
        <item><title>남의 기사</title><link>https://news.example.com/a</link><guid>a</guid><description>요약</description>
        <content:encoded><![CDATA[\(body)]]></content:encoded></item></channel></rss>
        """
        let listener = try NWListener(using: .tcp, on: .any)
        let q = DispatchQueue(label: "m15-http")
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { conn in
            conn.start(queue: q)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                let data = Data(rss.utf8)
                let head = "HTTP/1.1 200 OK\r\nContent-Type: application/rss+xml\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(head.utf8) + data, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        listener.start(queue: q)
        _ = ready.wait(timeout: .now() + 5)
        defer { listener.cancel() }
        let port = listener.port?.rawValue ?? 0
        let src = Source(id: "custom-m15", name: "집계", tier: "press", type: "feed", url: "http://127.0.0.1:\(port)/feed",
                         match: nil, aiOnly: false, defaultOn: false, color: "#888888")
        let items = try #require(try await FeedService(allowLocalForTests: true).items(for: src, conditional: false))
        #expect(items.count == 1)
        #expect(items.first?.title == "남의 기사")
        #expect(items.first?.feedBody == nil)
        #expect(try FeedParser.parseFeed(Data(rss.utf8)).first?.body != nil) // 같은 사이트 링크였다면 남을 만큼 긴 본문
    }
}
