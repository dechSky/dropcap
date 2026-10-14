import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// 시나리오 시험(DROPCAP_TEST_E2E)용 견본 피드. 실제 네트워크 없이 같은 결과를 재현한다.
// - 기본 출처(sources.json)의 피드 주소로 요청이 오면 그 출처의 견본 피드(국내는 RSS, 해외는 Atom)를 돌려준다.
//   처음 받을 때 출처마다 '이미 있던 글' 3건을 만들고, 그 뒤로는 시나리오가 post() 로 올린 글이 맨 위에 붙는다.
// - *.e2e.example: feeds.(직접 추가용 피드) · news.(기사 본문 HTML) · img.(견본 사진 PNG)
// - 그 밖의 주소는 막는다(시험 중 바깥으로 나가는 요청 없음). URLSession.shared(번역 등)도 같은 이유로 막는다.
// 시험 모드가 아니면 serve() 가 nil 을 돌려 일반 실행에는 아무 영향이 없다.
enum E2EFeeds {
    static let active = ProcessInfo.processInfo.environment["DROPCAP_TEST_E2E"] != nil
    static let host = "e2e.example"

    struct Post: Equatable {
        var sourceId: String
        var id: String
        var title: String
        var summary: String
        var date: Date
        var image: String?
        var link: String { "https://news.\(E2EFeeds.host)/\(sourceId)/\(id)" }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var posts: [String: [Post]] = [:]      // 출처 → 글(최신 먼저)
    nonisolated(unsafe) private static var images: [String: Data] = [:]
    nonisolated(unsafe) private static var custom: [String: (title: String, posts: [Post])] = [:] // feeds.e2e.example/<name>.xml
    nonisolated(unsafe) private static var served: [String: Int] = [:]        // 출처 → 받아 간 횟수(로그용)

    // 안전 검사(URLSafety.resolvesPublic)가 시험 모드에서만 견본 호스트를 통과시킨다
    static func allows(_ url: URL?) -> Bool {
        guard active, let h = url?.host?.lowercased() else { return false }
        return h == host || h.hasSuffix("." + host)
    }

    // FeedService.fetchOnce 맨 앞에서 부른다. nil = 시험 모드 아님(평소처럼 받기)
    static func serve(_ url: String) throws -> (data: Data, encoding: String?)? {
        guard active else { return nil }
        installOffline()
        guard let u = URL(string: url), let h = u.host?.lowercased() else { throw FeedError.blocked("시험 모드: 주소 아님") }
        if h == "img.\(host)" { return (image(u.lastPathComponent), nil) }
        if h == "news.\(host)" { return (Data(article(u).utf8), "utf-8") }
        if h == "feeds.\(host)" {
            let name = u.deletingPathExtension().lastPathComponent
            lock.lock(); let c = custom[name]; lock.unlock()
            guard let c else { throw FeedError.http(404) }
            return (Data(rss(title: c.title, posts: c.posts).utf8), "utf-8")
        }
        if let src = Resources.config.sources.first(where: { $0.url == url }) {
            return (Data(feed(for: src).utf8), "utf-8")
        }
        throw FeedError.blocked("시험 모드: 바깥 주소 막음")
    }

    // MARK: 시나리오가 쓰는 것

    // 출처에 새 글을 올린다(다음 확인 때 보임)
    static func post(_ p: Post) {
        lock.lock(); defer { lock.unlock() }
        ensureFiller(p.sourceId, now: p.date)
        posts[p.sourceId, default: []].insert(p, at: 0)
    }

    static func addCustomFeed(_ name: String, title: String, now: Date) {
        lock.lock(); defer { lock.unlock() }
        custom[name] = (title, (1...3).map { i in
            Post(sourceId: "feed-\(name)", id: "\(name)-\(i)", title: "\(title) 견본 글 \(i)", summary: "직접 추가한 피드의 견본 글입니다.",
                 date: now.addingTimeInterval(Double(-i) * 3600), image: "https://img.\(host)/\(name)-\(i).png")
        })
    }
    static func postCustom(_ name: String, _ p: Post) {
        lock.lock(); defer { lock.unlock() }
        custom[name]?.posts.insert(p, at: 0)
    }
    static func customURL(_ name: String) -> String { "https://feeds.\(host)/\(name).xml" }

    static func allPosts() -> [String: [Post]] { lock.lock(); defer { lock.unlock() }; return posts }
    static func servedCounts() -> [String: Int] { lock.lock(); defer { lock.unlock() }; return served }

    // 지금 견본 피드를 파일로 남긴다(재현·검토용)
    static func dump(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ids = allPosts().keys.sorted()
        for id in ids {
            guard let src = Resources.config.sources.first(where: { $0.id == id }) else { continue }
            try? feed(for: src).write(to: dir.appendingPathComponent("\(id).xml"), atomically: true, encoding: .utf8)
        }
    }

    // MARK: 피드 만들기

    // 출처마다 '이미 있던 글' 3건(처음 받을 때 한 번 정해 두고 그대로)
    private static func ensureFiller(_ id: String, now: Date) {
        guard posts[id] == nil else { return }
        let kr = Sections.region(ofSource: id, tier: Resources.config.sources.first { $0.id == id }?.tier ?? "press") == "kr"
        let pool = kr ? fillerKo : fillerEn
        let seed = abs(id.unicodeScalars.reduce(7) { ($0 &* 31) &+ Int($1.value) })
        posts[id] = (0..<3).map { i in
            Post(sourceId: id, id: "old-\(i)", title: pool[(seed + i * 5) % pool.count], summary: kr ? "이미 피드에 있던 글입니다." : "An item that was already in the feed.",
                 date: now.addingTimeInterval(-Double(2 + i * 3) * 3600), image: "https://img.\(host)/\(id)-old-\(i).png")
        }
    }

    private static func feed(for src: Source) -> String {
        lock.lock()
        ensureFiller(src.id, now: Date())
        let list = Array((posts[src.id] ?? []).prefix(30))
        served[src.id, default: 0] += 1
        lock.unlock()
        if src.type == "sitemap" { // 사이트맵 출처(Anthropic 등)는 빈 목록 — 시나리오에 쓰지 않는다
            return #"<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"></urlset>"#
        }
        return src.isDomestic ? rss(title: src.name, posts: list) : atom(title: src.name, posts: list)
    }

    private static let rfc822: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    static func rss(title: String, posts: [Post]) -> String {
        var s = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel><title>\(OPML.escape(title))</title><link>https://news.\(host)/</link><description>E2E 견본</description>

        """
        for p in posts {
            s += "<item><title>\(OPML.escape(p.title))</title><link>\(p.link)</link><guid>\(p.id)</guid>"
            s += "<pubDate>\(rfc822.string(from: p.date))</pubDate><description>\(OPML.escape(p.summary))</description>"
            if let i = p.image { s += "<enclosure url=\"\(i)\" type=\"image/png\" length=\"0\"/>" }
            s += "</item>\n"
        }
        return s + "</channel></rss>\n"
    }

    static func atom(title: String, posts: [Post]) -> String {
        let iso = ISO8601DateFormatter()
        var s = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:media="http://search.yahoo.com/mrss/"><title>\(OPML.escape(title))</title>

        """
        for p in posts {
            s += "<entry><id>\(p.id)</id><title>\(OPML.escape(p.title))</title><link rel=\"alternate\" href=\"\(p.link)\"/>"
            s += "<published>\(iso.string(from: p.date))</published><summary>\(OPML.escape(p.summary))</summary>"
            if let i = p.image { s += "<media:thumbnail url=\"\(i)\"/>" }
            s += "</entry>\n"
        }
        return s + "</feed>\n"
    }

    // 기사 본문: 제목·바이라인·사진·문단(읽기 창 추출용)
    private static func article(_ u: URL) -> String {
        lock.lock()
        let p = posts.values.joined().first { $0.link == u.absoluteString }
        lock.unlock()
        let title = p?.title ?? "견본 기사"
        let foreign = Translator.looksForeign(title)
        let img = p?.image ?? "https://img.\(host)/article.png"
        let paras = foreign ? [
            "This is a sample article served by the Dropcap end-to-end test. It exists so the reader can extract a body without touching the network.",
            "The second paragraph adds enough text for the readability pass to treat this page as an article rather than a short notice.",
            "A third paragraph closes the piece. Nothing here refers to real events or people.",
        ] : [
            "이 글은 Dropcap 시나리오 시험이 내보내는 견본 기사입니다. 네트워크 없이 읽기 창이 본문을 뽑아낼 수 있게 만들었습니다.",
            "두 번째 문단은 본문 추출기가 이 쪽을 짧은 공지가 아니라 기사로 보도록 글의 양을 채웁니다.",
            "세 번째 문단으로 마칩니다. 실제 사건이나 인물과는 관계가 없습니다.",
        ]
        let byline = foreign ? "By E2E Desk" : "E2E 견본 기자"
        return """
        <!doctype html><html lang="\(foreign ? "en" : "ko")"><head><meta charset="utf-8"><title>\(OPML.escape(title))</title>
        <meta property="og:title" content="\(OPML.escape(title))"><meta property="og:image" content="\(img)">
        <meta name="description" content="\(OPML.escape(p?.summary ?? title))"><meta name="author" content="\(byline)"></head>
        <body><article><h1>\(OPML.escape(title))</h1><p class="byline">\(byline)</p>
        <figure><img src="\(img)" width="1200" height="675"><figcaption>견본 사진</figcaption></figure>
        \(paras.map { "<p>\($0)</p>" }.joined(separator: "\n"))
        </article></body></html>
        """
    }

    // 견본 사진: 이름마다 색이 다른 그라데이션 PNG(1200×675)
    private static func image(_ name: String) -> Data {
        lock.lock()
        if let d = images[name] { lock.unlock(); return d }
        lock.unlock()
        let w = 1200, h = 675
        let hue = Double(abs(name.unicodeScalars.reduce(3) { ($0 &* 33) &+ Int($1.value) }) % 360) / 360
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
        let a = NSColor(hue: hue, saturation: 0.55, brightness: 0.9, alpha: 1).cgColor
        let b = NSColor(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.45, alpha: 1).cgColor
        if let g = CGGradient(colorsSpace: space, colors: [a, b] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
        }
        ctx.setFillColor(NSColor(white: 1, alpha: 0.18).cgColor)
        for i in 0..<5 {
            let r = CGFloat(80 + i * 40)
            ctx.fillEllipse(in: CGRect(x: CGFloat(150 + i * 190), y: CGFloat(120 + (i % 2) * 220), width: r, height: r))
        }
        let out = NSMutableData()
        guard let cg = ctx.makeImage(), let dst = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(dst, cg, nil)
        CGImageDestinationFinalize(dst)
        lock.lock(); images[name] = out as Data; lock.unlock()
        return out as Data
    }

    // MARK: 바깥 요청 막기(번역 등 URLSession.shared)
    nonisolated(unsafe) private static var offlineInstalled = false
    static func installOffline() {
        lock.lock(); defer { lock.unlock() }
        guard active, !offlineInstalled else { return }
        offlineInstalled = true
        URLProtocol.registerClass(Offline.self)
    }

    final class Offline: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { E2EFeeds.active }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
        override func stopLoading() {}
    }

    // 이미 있던 글 제목(서로 다른 주제 — 시나리오 소식과 낱말이 겹치지 않게)
    static let fillerKo = [
        "동네 도서관 야간 개방 시범 운영", "제주 감귤 첫 수확 시작", "지하철 2호선 신형 열차 투입", "가을 단풍 절정 시기 예보",
        "전통시장 상품권 할인 판매", "국립공원 탐방로 일부 통제", "초등학교 돌봄교실 확대", "수도권 광역버스 노선 개편",
        "한강 공원 야외 공연 일정", "도심 자전거 도로 정비 공사", "농촌 일손 돕기 봉사단 출범", "문화재 야간 관람 연장",
    ]
    static let fillerEn = [
        "City museum reopens after long renovation", "Botanists catalogue rare alpine flowers", "Ferry timetable changes for the winter season",
        "Marathon organisers announce new route", "Library launches late-night reading room", "Orchestra plans free concerts in parks",
        "Bakery chain expands into coastal towns", "Volunteers restore historic lighthouse", "Zoo welcomes twin red panda cubs",
        "Rail operator adds quiet carriages", "Chess club hosts junior tournament", "Gardeners share tips for autumn bulbs",
    ]
}
