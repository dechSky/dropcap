import Foundation
import Compression

// 출처 하나를 받아 와서 NewsItem 목록으로 바꾼다. ETag·Last-Modified 로 바뀐 것이 없으면 nil.
actor FeedService {
    static let shared = FeedService()
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) AINewsAlert/1.0"

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
    func fetchWithEncoding(_ url: String, conditional: Bool = false) async throws -> (data: Data, encoding: String?)? {
        guard let u = URL(string: url), URLSafety.isPublicHTTP(u) else { throw FeedError.badFormat }
        var req = URLRequest(url: u)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/rss+xml, application/atom+xml, application/xml, text/xml, text/html;q=0.8", forHTTPHeaderField: "Accept")
        if conditional, let v = validators[url] {
            if let e = v.etag { req.setValue(e, forHTTPHeaderField: "If-None-Match") }
            if let m = v.modified { req.setValue(m, forHTTPHeaderField: "If-Modified-Since") }
        }
        let (data, resp) = try await session.data(for: req, delegate: RedirectGuard.shared)
        let http = resp as? HTTPURLResponse
        if http?.statusCode == 304 { return nil }
        if let code = http?.statusCode, !(200..<300).contains(code) { throw FeedError.http(code) }
        if conditional {
            pending[url] = (http?.value(forHTTPHeaderField: "ETag"), http?.value(forHTTPHeaderField: "Last-Modified"))
        }
        return (Gzip.inflateIfNeeded(data), resp.textEncodingName)
    }

    func items(for source: Source) async throws -> [NewsItem]? {
        guard let data = try await fetch(source.url, conditional: true) else { return nil }
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
                     sourceId: source.id, sourceName: source.name, tier: source.tier)
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

// 공개 주소에서 내부망 주소로 넘기는 리다이렉트는 따라가지 않는다
final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    static let shared = RedirectGuard()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        URLSafety.isPublicHTTP(request.url) ? request : nil
    }
}
