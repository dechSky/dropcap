import Foundation
import Compression

// 출처 하나를 받아 와서 NewsItem 목록으로 바꾼다. ETag·Last-Modified 로 바뀐 것이 없으면 nil.
actor FeedService {
    static let shared = FeedService()
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Dropcap/1.0"

    private var validators: [String: (etag: String?, modified: String?)] = [:]
    private var pending: [String: (etag: String?, modified: String?)] = [:] // 해석이 성공해야 확정
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    func fetch(_ url: String, conditional: Bool = false) async throws -> Data? {
        try await fetchWithEncoding(url, conditional: conditional)?.data
    }

    // 본문과 함께 문자 인코딩 이름(헤더 기준)을 돌려준다
    // 잠깐의 서버 오류(5xx·429, YouTube 피드의 간헐적 404)는 한 번 더 시도한다
    func fetchWithEncoding(_ url: String, conditional: Bool = false) async throws -> (data: Data, encoding: String?)? {
        let youtube = url.contains("youtube.com/feeds")
        var attempt = 0
        while true {
            do {
                return try await fetchOnce(url, conditional: conditional)
            } catch FeedError.http(let code) where code == 429 || (500...504).contains(code) || (code == 404 && youtube) {
                attempt += 1
                guard attempt <= (youtube ? 2 : 1) else { throw FeedError.http(code) }
                try await Task.sleep(for: .milliseconds(code == 429 ? 3000 : 1500 * attempt))
            }
        }
    }

    private func fetchOnce(_ url: String, conditional: Bool) async throws -> (data: Data, encoding: String?)? {
        guard let u = URL(string: url), await URLSafety.resolvesPublic(u) else { throw FeedError.blocked("주소 확인") }
        var req = URLRequest(url: u)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/rss+xml, application/atom+xml, application/xml, text/xml, text/html;q=0.8", forHTTPHeaderField: "Accept")
        if conditional, let v = validators[url] {
            if let e = v.etag { req.setValue(e, forHTTPHeaderField: "If-None-Match") }
            if let m = v.modified { req.setValue(m, forHTTPHeaderField: "If-Modified-Since") }
        }
        let guardian = RequestGuard()
        let (data, resp) = try await session.data(for: req, delegate: guardian)
        // 실제로 접속한 IP 가 내부망이면(확인 뒤 DNS 응답을 바꾸는 공격) 받은 내용을 버린다
        guard await guardian.isSafe() else { throw FeedError.blocked("접속 IP \(guardian.lastRemote ?? "확인 안 됨")") }
        let http = resp as? HTTPURLResponse
        if http?.statusCode == 304 { return nil }
        if let code = http?.statusCode, !(200..<300).contains(code) { throw FeedError.http(code) }
        if conditional {
            pending[url] = (http?.value(forHTTPHeaderField: "ETag"), http?.value(forHTTPHeaderField: "Last-Modified"))
        }
        return (Gzip.inflateIfNeeded(data), resp.textEncodingName)
    }

    func items(for source: Source, conditional: Bool = true) async throws -> [NewsItem]? {
        guard let data = try await fetch(source.url, conditional: conditional) else { return nil }
        let entries: [FeedParser.Entry]
        if source.type == "sitemap", let m = source.match, let re = try? NSRegularExpression(pattern: m) {
            entries = try FeedParser.parseSitemap(data, match: re)
        } else {
            entries = try FeedParser.parseFeed(data)
        }
        // 해석에 성공했을 때만 "바뀐 것 없음" 표시를 확정한다(실패한 피드가 304 로 가려지지 않게)
        if let v = pending.removeValue(forKey: source.url) { validators[source.url] = v }
        // http(s) 링크만: file:// · smb:// 같은 주소는 열지 않는다
        return entries.filter { e in
            URLSafety.isPublicHTTP(URL(string: e.link))
        }.map {
            NewsItem(id: $0.id, title: $0.title, titleKo: nil, link: $0.link, date: $0.date, summary: $0.summary,
                     sourceId: source.id, sourceName: source.name, tier: source.tier,
                     image: $0.image.flatMap { URL(string: $0, relativeTo: URL(string: $0)) }.map(\.absoluteString),
                     kind: source.kind)
        }
    }

    // 사이트맵에서 찾은 새 글은 본문을 받아 제목·설명을 채운다
    func fillTitle(_ item: inout NewsItem) async {
        guard let data = try? await fetch(item.link) else { item.title = Plain.titleFromSlug(item.link); return }
        let html = String(decoding: data, as: UTF8.self)
        func meta(_ pattern: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let r = Range(m.range(at: 1), in: html) else { return nil }
            return String(html[r])
        }
        let title = meta("<meta[^>]+property=[\"']og:title[\"'][^>]+content=[\"']([^\"']+)") ?? meta("<title[^>]*>([^<]+)</title>")
        item.title = title.map { Plain.clean($0).replacingOccurrences(of: "\\s*[|\\\\-]\\s*Anthropic\\s*$", with: "", options: .regularExpression) }?.nonEmpty
            ?? Plain.titleFromSlug(item.link)
        if let d = meta("<meta[^>]+name=[\"']description[\"'][^>]+content=[\"']([^\"']+)") { item.summary = String(Plain.clean(d).prefix(300)) }
        if item.image == nil, let img = meta("<meta[^>]+property=[\"']og:image[\"'][^>]+content=[\"']([^\"']+)") { item.image = img }
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
// 확인할 수 없으면 막는다(fail closed). 프록시를 거친 연결은 IP 가 프록시 것이라 이름 확인에만 맡긴다.
final class RequestGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var verdict: Bool?            // nil = 아직 측정값 없음, true = 안전, false = 막음
    private var lastIP: String?
    private var waiter: CheckedContinuation<Void, Never>?

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
        var safe = true
        var verified = false   // 실제로 IP 를 확인한 연결이 하나라도 있어야 통과
        var proxied = false
        var seen: String?
        for t in metrics.transactionMetrics where t.resourceFetchType == .networkLoad {
            if t.isProxyConnection {
                // 프록시를 거친 연결: 시스템에 프록시가 실제로 설정된 경우에만 이름 확인 단계에 맡긴다
                if Self.systemProxyConfigured { proxied = true } else { safe = false }
                continue
            }
            verified = true
            guard let ip = t.remoteAddress else { safe = false; continue } // 모르면 막음
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
        lock.lock()
        verdict = safe && (verified || proxied)
        lastIP = seen
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume()
    }

    // 잠금은 동기 함수 안에서만(비동기 문맥에서 직접 잠그지 않는다)
    private func currentVerdict() -> Bool? { lock.lock(); defer { lock.unlock() }; return verdict }
    private func park(_ c: CheckedContinuation<Void, Never>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if verdict != nil { return false }
        waiter = c
        return true
    }
    private func takeWaiter() -> CheckedContinuation<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
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
        guard let data = try? await fetch(link) else { return nil }
        let head = String(decoding: data.prefix(65536), as: UTF8.self)
        for pattern in [#"<meta[^>]+property=["']og:image(?::url)?["'][^>]+content=["']([^"']+)"#,
                        #"<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image"#,
                        #"<meta[^>]+name=["']twitter:image["'][^>]+content=["']([^"']+)"#] {
            if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let m = re.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)),
               let r = Range(m.range(at: 1), in: head) {
                let raw = String(head[r]).replacingOccurrences(of: "&amp;", with: "&")
                return URL(string: raw, relativeTo: URL(string: link))?.absoluteString
            }
        }
        return nil
    }
}
