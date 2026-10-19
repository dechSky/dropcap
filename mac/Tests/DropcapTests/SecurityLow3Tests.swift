import Foundation
import Network
import WebKit
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
        // 공용 호스팅은 하위 도메인 하나가 한 사이트
        #expect(!FeedService.sameSite("https://b.substack.com/p/x", "https://a.substack.com/feed"))
        #expect(FeedService.sameSite("https://a.substack.com/p/x", "https://a.substack.com/feed"))
        #expect(FeedService.sameSite("https://WWW.A.Substack.com/p/x", "https://a.substack.com/feed"))
        #expect(!FeedService.sameSite("https://other.github.io/post", "https://me.github.io/feed.xml"))
        #expect(!FeedService.sameSite("https://x.blogspot.com/2026/10/a.html", "https://y.blogspot.com/feeds/posts/default"))
        #expect(!FeedService.sameSite("https://x.wordpress.com/a", "https://y.wordpress.com/feed/"))
        #expect(!FeedService.sameSite("https://pub.medium.com/a", "https://other.medium.com/feed"))
        #expect(!FeedService.sameSite("https://a.netlify.app/p", "https://b.netlify.app/rss.xml"))
        #expect(!FeedService.sameSite("https://a.tistory.com/1", "https://b.tistory.com/rss"))
        #expect(FeedService.siteKey("substack.com") == "substack.com")
        #expect(FeedService.siteKey("www.a.substack.com") == "a.substack.com")
        #expect(FeedService.siteKey("notsubstack.com") == "notsubstack.com") // 접미사는 마디 단위로만
    }

    // 고치기 전에 피드 기록 DB 에 들어간 다른 사이트 본문도 읽기 창에서 쓰지 않는다
    @Test func storedForeignFeedBodyIgnored() {
        #expect(ArticleService.usableFeedBody("<p>x</p>", link: "https://news.example.com/a", sourceURL: "https://hnrss.org/frontpage") == nil)
        #expect(ArticleService.usableFeedBody("<p>x</p>", link: "https://news.example.com/a", sourceURL: nil) == nil)
        #expect(ArticleService.usableFeedBody("<p>x</p>", link: "https://arstechnica.com/a", sourceURL: "https://feeds.arstechnica.com/x") == "<p>x</p>")
        #expect(ArticleService.usableFeedBody(nil, link: "https://arstechnica.com/a", sourceURL: "https://feeds.arstechnica.com/x") == nil)
    }

    // 읽기 창(ArticleService.run 이 부르는 feedBody(for:))이 피드 기록 DB 에 남은 다른 사이트 본문을 쓰지 않는다
    @Test @MainActor func readerIgnoresStoredForeignFeedBody() throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("dropcap-m15-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: d) }
        let db = Database(file: d.appendingPathComponent("magazine.sqlite"))
        func stored(_ id: String, _ link: String, _ source: String) -> NewsItem {
            var it = NewsItem(id: id, title: "T", titleKo: nil, link: link, date: Date(), summary: "", sourceId: source, sourceName: "S", tier: "press")
            it.feedBody = "<p>피드 본문</p>"
            db.upsert(it, cluster: nil)
            it.feedBody = nil // 나중에 읽기·스크랩에서 연 사본(저장 때 뺌) — DB 에서 다시 찾는다
            return it
        }
        let urls = ["agg": "https://hnrss.org/frontpage", "ars": "https://feeds.arstechnica.com/arstechnica/index"]
        let lookup: (String) -> String? = { urls[$0] }
        let foreign = stored("f", "https://news.example.com/a", "agg")
        let own = stored("o", "https://arstechnica.com/ai/2026/10/x/", "ars")
        #expect(ArticleService.feedBody(for: own, db: db, sourceURL: lookup) == "<p>피드 본문</p>") // DB 에서 찾아 옴(같은 사이트)
        #expect(ArticleService.feedBody(for: foreign, db: db, sourceURL: lookup) == nil)
        #expect(ArticleService.feedBody(for: own, db: db, sourceURL: { _ in nil }) == nil) // 출처를 모르면 쓰지 않음
    }

    // 글자 검사만이 아니라 실제로 — 세 판의 추출 스크립트(맥 script · 윈도우 extract.js · 리눅스 SCRIPT)를
    // 스크립트·그림이 켜진 WebKit 에서 돌려도 여러 덩어리 모으기가 그림 받기·onerror 를 일으키지 않는다. 고치기 전 꼴(document.createElement)은 일으킴(대조)
    @Test @MainActor func gatheringDoesNotLoadImagesInWebKit() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let win = try String(contentsOf: root.appendingPathComponent("windows/Dropcap.Ui/web/extract.js"), encoding: .utf8)
        let rs = try String(contentsOf: root.appendingPathComponent("linux/dropcap-gtk/src/reader_webkit.rs"), encoding: .utf8)
        let start = try #require(rs.range(of: "const SCRIPT: &str = r#\""))
        let end = try #require(rs[start.upperBound...].range(of: "\"#;"))
        let linux = String(rs[start.upperBound..<end.lowerBound])
        let fixed = "const box = fresh.createElement('div');"
        for (name, script) in [("mac", ArticleExtractor.script), ("windows", win), ("linux", linux)] {
            #expect(script.contains(fixed), "\(name)")
            let (requests, onerror) = try await GatherProbe.run(script)
            #expect(requests == 0, "\(name) 요청 \(requests)")
            #expect(onerror == nil, "\(name) onerror")
        }
        let old = ArticleExtractor.script.replacingOccurrences(of: fixed, with: "const box = document.createElement('div');")
        let (requests, onerror) = try await GatherProbe.run(old)
        #expect(requests > 0 && onerror != nil, "대조: 살아 있는 문서에 만들면 받기·onerror 가 일어나야 이 시험이 그것을 잡는다")
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

// 추출 스크립트를 스크립트·그림이 켜진 웹 보기에서 돌리고, 추출하는 동안 나간 그림 요청 수와 onerror 실행을 센다.
// 그림 주소는 probe: 칸(앱 밖으로 나가지 않음)이고 받기는 늘 실패시켜 onerror 를 부른다. 창을 띄우지 않는다
@MainActor private final class GatherProbe: NSObject, WKURLSchemeHandler, WKNavigationDelegate {
    private var requests = 0
    private var loaded: CheckedContinuation<Void, Never>?

    static func run(_ script: String) async throws -> (Int, String?) {
        let probe = GatherProbe()
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.setURLSchemeHandler(probe, forURLScheme: "probe")
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800), configuration: cfg)
        w.navigationDelegate = probe
        let para = { (s: String) in "<p>" + String(repeating: s + " lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor ", count: 2) + "</p>" }
        let html = "<html><head><title>t</title></head><body><article>"
            + "<div class=\"chunk\">\(para("one"))\(para("two"))<img src=\"probe://img/leak.png\" onerror=\"window.__probe=1\"></div>"
            + "<div class=\"ad\">ad</div>"
            + "<div class=\"chunk\">\(para("three"))\(para("four"))<img src=\"probe://img/leak2.png\" onerror=\"window.__probe=2\"></div>"
            + "</article></body></html>"
        await withCheckedContinuation { c in
            probe.loaded = c
            w.loadHTMLString(html, baseURL: URL(string: "probe://site/a"))
        }
        try await Task.sleep(for: .milliseconds(300))
        _ = try await w.evaluateJavaScript("window.__probe = null; true")
        probe.requests = 0
        let readability = try String(contentsOf: Resources.url("Readability.js"), encoding: .utf8)
        _ = try await w.evaluateJavaScript(readability + "\n;\n" + script)
        try await Task.sleep(for: .milliseconds(500))
        let e = try await w.evaluateJavaScript("window.__probe === null ? '' : String(window.__probe)") as? String
        return (probe.requests, e?.isEmpty == false ? e : nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded?.resume(); loaded = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loaded?.resume(); loaded = nil }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        if task.request.url?.host == "img" { requests += 1 }
        task.didFailWithError(URLError(.cannotConnectToHost))
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
