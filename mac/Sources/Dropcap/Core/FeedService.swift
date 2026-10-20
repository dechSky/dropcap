import Foundation
import Compression

// 받는 크기 상한(S-12): 받는 도중 넘으면 바로 끊는다(다 받은 뒤 버리지 않음). gzip 을 푼 뒤에는 Gzip 의 32MB 상한
enum FetchLimit: Int, Sendable {
    case feed = 10_485_760   // 피드·사이트맵·채널 찾기 10MB
    case page = 2_097_152    // 기사 페이지 2MB
    case image = 8_388_608   // 사진 8MB
}

// 출처 하나를 받아 와서 NewsItem 목록으로 바꾼다. ETag·Last-Modified 로 바뀐 것이 없으면 nil.
actor FeedService {
    static let shared = FeedService()
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Dropcap/1.0"

    private var validators: [String: (etag: String?, modified: String?)] = [:]
    private var pending: [String: (etag: String?, modified: String?)] = [:] // 해석이 성공해야 확정
    private let session: URLSession
    private let allowLocal: Bool // 시험에서만: 내 Mac 안의 시험 서버(127.0.0.1)를 받게

    static func makeSession(resourceTimeout: TimeInterval) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20 // 바이트 사이 대기
        // 요청 하나의 전체 시간 상한(기본값은 7일). 아주 천천히 흘러나오는 서버 하나가 확인 전체를 묶어
        // '확인 중'이 풀리지 않고 그 뒤 확인이 모두 건너뛰어지던 문제
        c.timeoutIntervalForResource = resourceTimeout
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }

    #if DEBUG
    init(allowLocalForTests: Bool = false, resourceTimeout: TimeInterval = 60) {
        allowLocal = allowLocalForTests
        session = Self.makeSession(resourceTimeout: resourceTimeout)
    }
    #else
    init() { allowLocal = false; session = Self.makeSession(resourceTimeout: 60) } // 배포 빌드에는 시험 서버 허용 스위치가 없다
    #endif

    func fetch(_ url: String, conditional: Bool = false, limit: FetchLimit = .feed) async throws -> Data? {
        try await fetchWithEncoding(url, conditional: conditional, limit: limit)?.data
    }

    // 본문과 함께 문자 인코딩 이름(헤더 기준)을 돌려준다
    // 잠깐의 서버 오류(5xx·429, YouTube 피드의 간헐적 404)는 한 번 더 시도한다
    func fetchWithEncoding(_ url: String, conditional: Bool = false, limit: FetchLimit = .feed) async throws -> (data: Data, encoding: String?)? {
        let youtube = url.contains("youtube.com/feeds")
        var attempt = 0
        while true {
            do {
                return try await fetchOnce(url, conditional: conditional, limit: limit.rawValue)
            } catch FeedError.http(let code) where code == 429 || (500...504).contains(code) || (code == 404 && youtube) {
                attempt += 1
                guard attempt <= (youtube ? 2 : 1) else { throw FeedError.http(code) }
                try await Task.sleep(for: .milliseconds(code == 429 ? 3000 : 1500 * attempt))
            }
        }
    }

    private func fetchOnce(_ url: String, conditional: Bool, limit: Int) async throws -> (data: Data, encoding: String?)? {
        if let fixture = try await E2EFeeds.serve(url) { return fixture } // 시나리오 시험(DROPCAP_TEST_E2E)에서만: 견본 피드, 바깥 요청 없음
        guard let u = URL(string: url) else { throw FeedError.blocked("주소 확인") }
        if !allowLocal, !(await URLSafety.resolvesPublic(u)) { throw FeedError.blocked("주소 확인") }
        var req = URLRequest(url: u)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/rss+xml, application/atom+xml, application/xml, text/xml, text/html;q=0.8", forHTTPHeaderField: "Accept")
        if conditional, let v = validators[url] {
            if let e = v.etag { req.setValue(e, forHTTPHeaderField: "If-None-Match") }
            if let m = v.modified { req.setValue(m, forHTTPHeaderField: "If-Modified-Since") }
        }
        let guardian = RequestGuard()
        let (bytes, resp) = try await session.bytes(for: req, delegate: guardian)
        let http = resp as? HTTPURLResponse
        var data = Data()
        if let code = http?.statusCode, (200..<300).contains(code) {
            do { data = try await Self.collect(bytes, expected: resp.expectedContentLength, limit: limit) } catch {
                bytes.task.cancel()
                throw error
            }
        } else {
            bytes.task.cancel() // 304·오류 응답의 본문은 받지 않는다
        }
        if try await Self.settle(status: http?.statusCode, checkIP: !allowLocal, isSafe: { await guardian.isSafe() }, remote: { guardian.lastRemote }) { return nil }
        if conditional {
            pending[url] = (http?.value(forHTTPHeaderField: "ETag"), http?.value(forHTTPHeaderField: "Last-Modified"))
        }
        return (Gzip.inflateIfNeeded(data), resp.textEncodingName)
    }

    // 응답 코드와 접속 IP 판정 순서. 304 면 true(바뀐 것 없음).
    // 2xx 가 아닌 응답은 본문을 받지 않고 쓰지도 않으므로 IP 판정 없이 바로 코드로 알린다 — 끊은 전송은 측정값이 오지 않아
    // 예전엔 2초 기다린 뒤 403·401·404 가 '접속 IP 확인 안 됨'으로 바뀌었다(READSWEEP).
    // 2xx 는 실제로 접속한 IP 가 내부망이면(확인 뒤 DNS 응답을 바꾸는 공격) 받은 내용을 버린다.
    static func settle(status: Int?, checkIP: Bool, isSafe: () async -> Bool, remote: () -> String?) async throws -> Bool {
        if status == 304 { return true }
        if let code = status, !(200..<300).contains(code) { throw FeedError.http(code) }
        if checkIP { guard await isSafe() else { throw FeedError.blocked("접속 IP \(remote() ?? "확인 안 됨")") } }
        return false
    }

    // 받는 대로 모으다가 상한을 넘으면 그 자리에서 멈춘다. 헤더의 길이가 이미 상한을 넘으면 한 바이트도 받지 않는다
    static func collect<S: AsyncSequence>(_ bytes: S, expected: Int64, limit: Int) async throws -> Data where S.Element == UInt8 {
        if expected > Int64(limit) { throw FeedError.tooLarge(limit) }
        var buf: [UInt8] = []
        buf.reserveCapacity(expected > 0 ? Int(expected) : 64 << 10)
        for try await b in bytes {
            buf.append(b)
            if buf.count > limit { throw FeedError.tooLarge(limit) }
        }
        return Data(buf)
    }

    private var firstSeen: [String: Date] = [:] // 날짜 없는 글을 처음 본 시각(FeedDates.repair)

    func items(for source: Source, conditional: Bool = true) async throws -> [NewsItem]? {
        let now = Date()
        var entries: [FeedParser.Entry]
        do {
            guard let data = try await fetch(source.url, conditional: conditional) else {
                await SourceHealthBook.shared.recordUnchanged(source.id, at: now)
                return nil
            }
            if source.type == "sitemap", let m = Self.sitemapPattern(source), let re = try? NSRegularExpression(pattern: m) {
                entries = try FeedParser.parseSitemap(data, match: re)
            } else {
                entries = try FeedParser.parseFeed(data)
            }
        } catch {
            await SourceHealthBook.shared.recordFailure(source.id, error: error.localizedDescription, at: now)
            throw error
        }
        let dated = entries.contains { $0.date != nil } // 날짜 없는 피드는 맨 위 글이 바뀌었는지로 새 글을 판단
        FeedDates.repair(&entries, sourceID: source.id, now: now, firstSeen: &firstSeen)
        await SourceHealthBook.shared.recordSuccess(source.id, newest: dated ? entries.compactMap(\.date).max() : nil, topID: entries.first?.id,
                                                    count: entries.count, at: now)
        // 해석에 성공했을 때만 "바뀐 것 없음" 표시를 확정한다(실패한 피드가 304 로 가려지지 않게)
        if let v = pending.removeValue(forKey: source.url) { validators[source.url] = v }
        // http(s) 링크만: file:// · smb:// 같은 주소는 열지 않는다
        return entries.filter { e in
            URLSafety.isPublicHTTP(URL(string: e.link))
        }.map {
            NewsItem(id: $0.id, title: $0.title, titleKo: nil, link: $0.link, date: $0.date, summary: $0.summary,
                     sourceId: source.id, sourceName: source.name, tier: source.tier,
                     image: { e in e.image.flatMap { URL(string: $0, relativeTo: URL(string: e.link)) }.map(\.absoluteString) }($0),
                     kind: source.kind, paid: $0.paid, feedBody: Self.sameSite($0.link, source.url) ? $0.body : nil)
        }
    }

    // 사이트맵 거르기 정규식은 앱에 든 기본 출처의 것만 쓴다. 바깥(가져온 기록·고친 상태 파일)에서 온 정규식은
    // 시간 제한 없이 돌아 받기 전체를 멈출 수 있다(보안 점검: ^(a+)+$ 한 줄로 actor 가 멈춤)
    nonisolated static func sitemapPattern(_ source: Source, bundled: [Source] = Resources.config.sources) -> String? {
        guard let m = source.match, bundled.contains(where: { $0.id == source.id && $0.match == m }) else { return nil }
        return m
    }

    // 피드 본문 전문은 글 링크가 출처 피드와 같은 사이트(같은 등록 도메인)일 때만 받는다. 남의 링크에 본문을 실은
    // 집계 피드면 사이트 추출이 실패했을 때 그 글이 링크한 기사처럼 읽기 창에 보일 수 있다
    nonisolated static func sameSite(_ link: String, _ feed: String) -> Bool {
        guard let a = URL(string: link)?.host, let b = URL(string: feed)?.host else { return false }
        return siteKey(a) == siteKey(b)
    }

    // 여러 사람이 하위 도메인을 하나씩 나눠 쓰는 공용 호스팅(공용 접미사 목록 PSL 의 짧은 발췌 + 국내 블로그). 여기서는 하위 도메인 하나가 한 사이트다 —
    // 'a.substack.com' 집계 피드가 'b.substack.com' 글에 실은 본문을 그 글로 보이지 않게
    nonisolated static let sharedHosts: [String] = [
        "substack.com", "medium.com", "github.io", "gitlab.io", "blogspot.com", "wordpress.com", "tumblr.com", "ghost.io", "beehiiv.com",
        "netlify.app", "pages.dev", "vercel.app", "herokuapp.com", "neocities.org", "bearblog.dev", "micro.blog", "wixsite.com", "tistory.com",
    ]

    // 등록 도메인 근사: 마지막 두 마디, 나라 도메인의 2단계(co.kr·co.uk·or.kr 등)면 세 마디, 공용 호스팅이면 그 하위 도메인까지. IP 는 그대로
    nonisolated static func siteKey(_ host: String) -> String {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if h.contains(":") || h.split(separator: ".").allSatisfy({ $0.allSatisfy(\.isNumber) }) { return h }
        if let shared = sharedHosts.first(where: { h.hasSuffix("." + $0) }) {
            let sub = h.dropLast(shared.count + 1).split(separator: ".").last.map(String.init) ?? ""
            return sub + "." + shared
        }
        let parts = h.split(separator: ".")
        guard parts.count > 2 else { return h }
        let second: Set<Substring> = ["co", "com", "net", "org", "or", "ne", "go", "ac", "re", "gov", "edu", "ed", "mil", "ltd", "plc", "gen", "pe", "kg", "es", "hs", "ms", "sc"]
        let n = parts.last!.count == 2 && second.contains(parts[parts.count - 2]) ? 3 : 2
        return parts.suffix(n).joined(separator: ".")
    }

    // 사이트맵에서 찾은 새 글은 본문을 받아 제목·설명을 채운다
    func fillTitle(_ item: inout NewsItem) async {
        guard let data = try? await fetch(item.link, limit: .page) else { item.title = Plain.titleFromSlug(item.link); return }
        let html = String(decoding: data, as: UTF8.self)
        // 꼬리표를 하나씩 떼어 본다(HTMLScan — 정규식 되풀이 훑기로 큰 페이지에서 멈추지 않게)
        let title = HTMLScan.meta(html, ["og:title"]) ?? HTMLScan.title(html)
        item.title = title.map { Plain.clean($0).replacingOccurrences(of: "\\s*[|\\\\-]\\s*Anthropic\\s*$", with: "", options: .regularExpression) }?.nonEmpty
            ?? Plain.titleFromSlug(item.link)
        if let d = HTMLScan.meta(html, ["description"]) { item.summary = String(Plain.clean(d).prefix(300)) }
        if item.image == nil, let img = HTMLScan.meta(html, ["og:image"]) { item.image = img }
    }
}

// Content-Encoding 없이 gzip 본문을 보내는 서버(DeepMind 등) 대비
enum Gzip {
    static func inflateIfNeeded(_ data: Data) -> Data {
        guard data.count > 18, data[0] == 0x1F, data[1] == 0x8B else { return data }
        let flags = data[3]
        var i = 10
        if flags & 0x04 != 0 { i += 2 + Int(data[i]) + Int(data[i + 1]) << 8 }
        if flags & 0x08 != 0 { while i < data.count, data[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x10 != 0 { while i < data.count, data[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x02 != 0 { i += 2 }
        guard i < data.count - 8 else { return data }
        let deflated = data.subdata(in: i..<(data.count - 8))
        let isize = data.suffix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        // 크기 값은 믿지 않고 32MB 로 상한(깨지거나 악의적인 응답 대비)
        let capacity = min(max(Int(UInt32(littleEndian: isize)), deflated.count * 8) + 1024, 32 << 20)
        var out = Data(count: capacity)
        let n = out.withUnsafeMutableBytes { dst in
            deflated.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, deflated.count, nil, COMPRESSION_ZLIB)
            }
        }
        return n > 0 ? out.prefix(n) : data
    }
}

// 요청 하나를 지킨다: 내부망으로 넘기는 리다이렉트는 따라가지 않고, 실제 접속한 IP 를 확인한다.
// 확인할 수 없으면 막는다(fail closed). 프록시를 거친 연결은 IP 가 프록시 것이라 연결 전 이름 확인에만 맡긴다(judge).
final class RequestGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var verdict: Bool?            // nil = 아직 측정값 없음, true = 안전, false = 막음
    private var lastIP: String?
    private var waiter: CheckedContinuation<Void, Never>?
    private var gaveUp = false             // 기다리기를 끝냈다(시간 초과) — 늦게 온 기다림은 바로 깨운다

    var lastRemote: String? { lock.lock(); defer { lock.unlock() }; return lastIP }

    static var systemProxyConfigured: Bool {
        guard let p = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return false }
        let on = { (k: String) in (p[k] as? Int ?? 0) != 0 }
        return on("HTTPEnable") || on("HTTPSEnable") || on("ProxyAutoConfigEnable") || on("SOCKSEnable")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        await URLSafety.resolvesPublic(request.url) ? request : nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let hops = metrics.transactionMetrics.filter { $0.resourceFetchType == .networkLoad }
            .map { Hop(proxied: $0.isProxyConnection, remote: $0.remoteAddress) }
        let (safe, seen) = Self.judge(hops, systemProxy: hops.contains(where: \.proxied) && Self.systemProxyConfigured)
        lock.lock()
        verdict = safe
        lastIP = seen
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume()
    }

    // 연결 하나(리다이렉트마다 하나씩)
    struct Hop: Equatable { var proxied: Bool; var remote: String? }

    // 판정(시험 대상). 직접 연결은 실제 접속 IP 가 공개 주소여야 하고, 확인한 연결이 하나라도 있어야 통과.
    // 프록시를 거친 연결은 IP 가 프록시 것이라 볼 수 없어, 시스템에 프록시가 실제로 설정된 경우에만 연결 전 이름 확인
    // (resolvesPublic · 리다이렉트마다)에 맡긴다. 프록시가 이름을 다시 풀어 내부망으로 갈 위험은 받아들임.
    static func judge(_ hops: [Hop], systemProxy: Bool) -> (safe: Bool, seen: String?) {
        var safe = true
        var verified = false
        var seen: String?
        for t in hops {
            if t.proxied {
                if systemProxy { verified = true } else { safe = false }
                continue
            }
            verified = true
            guard let ip = t.remote else { safe = false; continue } // 모르면 막음
            seen = ip
            let bare = ip.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            if let v4 = URLSafety.parseV4(bare) {
                if !URLSafety.isPublic(v4: v4) { safe = false }
            } else if let v6 = URLSafety.parseV6(bare.split(separator: "%").first.map(String.init) ?? bare) {
                if !URLSafety.isPublic(v6: v6) { safe = false }
            } else {
                safe = false // 알아볼 수 없는 주소도 막음
            }
        }
        return (safe && verified, seen)
    }

    // 잠금은 동기 함수 안에서만(비동기 문맥에서 직접 잠그지 않는다)
    private func currentVerdict() -> Bool? { lock.lock(); defer { lock.unlock() }; return verdict }
    private func park(_ c: CheckedContinuation<Void, Never>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if verdict != nil || gaveUp { return false }
        waiter = c
        return true
    }
    private func takeWaiter() -> CheckedContinuation<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        gaveUp = true
        let w = waiter
        waiter = nil
        return w
    }

    // 응답을 쓰기 전에 측정값을 기다린다(최대 2초). 끝내 안 오면 막는다.
    func isSafe() async -> Bool {
        if let v = currentVerdict() { return v }
        await withTaskGroup(of: Void.self) { g in
            g.addTask {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    if !self.park(c) { c.resume() }
                }
            }
            g.addTask { try? await Task.sleep(for: .seconds(2)) }
            await g.next()
            g.cancelAll()
            self.takeWaiter()?.resume()
        }
        return currentVerdict() ?? false
    }
}

extension FeedService {
    // 대표 사진이 없는 기사는 페이지 머리의 og:image 를 찾아 채운다(공개 주소만, 앞 64KB 만 읽음)
    func ogImage(_ link: String) async -> String? {
        guard let data = try? await fetch(link, limit: .page) else { return nil }
        // <meta> 를 하나씩 떼어 읽는다(예전 정규식은 content 를 먼저 쓴 og:image:type 을 사진 주소로 잡았다 — DW)
        return CoverPick.ogImage(html: String(decoding: data.prefix(65536), as: UTF8.self), base: URL(string: link))
    }

}

// 출처 건강: 마지막 성공 시각·마지막 새 글 시각·연속 실패 수. 설정의 출처 줄에 '조용함·멈춤·오류'로 보인다.
// 상태 파일과 따로 source-health.json 에 둔다(없거나 깨지면 빈 기록으로 시작 — 다음 확인부터 다시 쌓임).
struct SourceHealth: Codable, Equatable {
    var lastSuccess: Date?
    var lastNew: Date?        // 피드에서 가장 새 글의 시각(날짜 없는 피드는 맨 위 글이 바뀐 시각)
    var failures = 0          // 연속 실패 수(성공하면 0)
    var lastError: String?
    var topID: String?        // 맨 위 글 id(날짜 없는 피드용)
    var count: Int?           // 마지막으로 받은 글 수

    enum Status: Equatable {
        case unknown              // 아직 확인 전
        case ok
        case quiet(days: Int)     // n일째 새 글 없음(드물게 쓰는 곳일 수 있음)
        case stalled(days: Int)   // 오래 새 글이 없음 — 주소가 바뀌었거나 피드를 닫았을 수 있음
        case empty                // 받았는데 글이 하나도 없음
        case failing(count: Int, message: String)
    }

    static let quietDays = 3
    static let stalledDays = 30
    static let failingAfter = 3

    func status(now: Date = Date()) -> Status {
        if failures >= Self.failingAfter { return .failing(count: failures, message: lastError ?? "") }
        guard lastSuccess != nil else { return failures > 0 ? .failing(count: failures, message: lastError ?? "") : .unknown }
        if count == 0 { return .empty }
        guard let lastNew else { return .ok }
        let days = Int(now.timeIntervalSince(lastNew) / 86400)
        if days >= Self.stalledDays { return .stalled(days: days) }
        if days >= Self.quietDays { return .quiet(days: days) }
        return .ok
    }

    mutating func success(newest: Date?, topID: String?, count: Int, at now: Date) {
        lastSuccess = now
        failures = 0
        lastError = nil
        self.count = count
        if let newest, newest > (lastNew ?? .distantPast) { lastNew = newest }
        if newest == nil, let topID, topID != self.topID { lastNew = now } // 날짜 없는 피드: 맨 위 글이 바뀌면 새 글
        if let topID { self.topID = topID }
    }

    mutating func failure(_ message: String) {
        failures += 1
        lastError = message
    }
}

@MainActor
final class SourceHealthBook: ObservableObject {
    static let shared = SourceHealthBook()
    @Published private(set) var records: [String: SourceHealth] = [:]
    private let file: URL
    private var saveTask: Task<Void, Never>?

    init(file: URL = Store.dir.appendingPathComponent("source-health.json")) {
        self.file = file
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: file), let r = try? dec.decode([String: SourceHealth].self, from: data) { records = r }
    }

    func status(_ id: String, now: Date = Date()) -> SourceHealth.Status { records[id]?.status(now: now) ?? .unknown }

    func recordSuccess(_ id: String, newest: Date?, topID: String?, count: Int, at now: Date) {
        records[id, default: SourceHealth()].success(newest: newest, topID: topID, count: count, at: now)
        scheduleSave()
    }

    // 304(바뀐 것 없음)도 성공이다. 새 글 시각은 그대로.
    func recordUnchanged(_ id: String, at now: Date) {
        records[id, default: SourceHealth()].lastSuccess = now
        records[id]?.failures = 0
        records[id]?.lastError = nil
        scheduleSave()
    }

    func recordFailure(_ id: String, error: String, at now: Date) {
        records[id, default: SourceHealth()].failure(error)
        scheduleSave()
    }

    // 한 번 확인에 출처 수십 곳이 기록하므로 모아서 쓴다
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(records) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
