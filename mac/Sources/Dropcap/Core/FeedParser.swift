import Foundation

// XMLParser 로 간단한 나무를 만든 뒤 RSS·Atom·RDF·사이트맵을 해석한다.
final class XNode {
    let name: String
    var attrs: [String: String]
    var children: [XNode] = []
    var text = ""
    init(name: String, attrs: [String: String]) { self.name = name; self.attrs = attrs }

    func child(_ n: String) -> XNode? { children.first { $0.name == n } }
    func all(_ n: String) -> [XNode] { children.filter { $0.name == n } }
    func value(_ n: String) -> String { child(n)?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
}

private final class TreeBuilder: NSObject, XMLParserDelegate {
    let root = XNode(name: "#root", attrs: [:])
    private var stack: [XNode] = []
    override init() { super.init(); stack = [root] }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        let n = XNode(name: qualifiedName ?? name, attrs: attributes)
        stack.last?.children.append(n)
        stack.append(n)
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { stack.removeLast() }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, foundCDATA data: Data) { stack.last?.text += String(decoding: data, as: UTF8.self) }
}

enum FeedError: LocalizedError {
    case badFormat, http(Int), blocked(String)
    var errorDescription: String? {
        switch self {
        case .blocked(let why): return "안전하지 않은 주소라 막음: \(why)"
        case .badFormat: return "RSS/Atom 형식을 알아볼 수 없음"
        case .http(let c): return "HTTP \(c)"
        }
    }
}

enum FeedParser {
    struct Entry { var id: String; var title: String; var link: String; var date: Date?; var summary: String; var image: String? = nil }

    // 대표 사진: media:content / media:thumbnail / 그림 enclosure / 본문의 첫 <img>
    static func image(_ it: XNode) -> String? {
        for n in it.children {
            switch n.name {
            case "media:thumbnail":
                if let u = n.attrs["url"] { return u }
            case "media:content":
                if let u = n.attrs["url"], isImage(n) { return u }
                if let t = n.child("media:thumbnail")?.attrs["url"] { return t }
            case "media:group":
                if let t = n.child("media:thumbnail")?.attrs["url"] { return t }
                if let u = n.all("media:content").first(where: isImage)?.attrs["url"] { return u }
            case "enclosure":
                if n.attrs["type"]?.hasPrefix("image") == true, let u = n.attrs["url"] { return u }
            default: break
            }
        }
        for field in ["content:encoded", "content", "description", "summary"] {
            let html = it.value(field)
            if let r = html.range(of: #"<img[^>]+src=["']([^"']+)["']"#, options: .regularExpression) {
                let tag = String(html[r])
                if let q = tag.range(of: #"src=["']"#, options: .regularExpression) {
                    let rest = tag[q.upperBound...]
                    if let end = rest.firstIndex(where: { $0 == "\"" || $0 == "'" }) { return String(rest[..<end]) }
                }
            }
        }
        return nil
    }

    private static func isImage(_ n: XNode) -> Bool {
        if n.attrs["medium"] == "image" || n.attrs["type"]?.hasPrefix("image") == true { return true }
        let u = (n.attrs["url"] ?? "").lowercased()
        return n.attrs["medium"] == nil && n.attrs["type"] == nil && [".jpg", ".jpeg", ".png", ".webp", ".gif"].contains { u.contains($0) }
    }

    // 피드 자체의 이름(구독할 때 기본 이름으로)
    static func feedTitle(_ data: Data) -> String? {
        guard let root = try? tree(data) else { return nil }
        let t = root.child("rss")?.child("channel")?.value("title").nonEmpty ?? root.child("feed")?.value("title").nonEmpty
            ?? root.child("rdf:RDF")?.child("channel")?.value("title").nonEmpty
        return t.map(Plain.clean)
    }

    static func tree(_ data: Data) throws -> XNode {
        let b = TreeBuilder()
        let p = XMLParser(data: data)
        p.delegate = b
        p.shouldProcessNamespaces = false
        guard p.parse() || !b.root.children.isEmpty else { throw FeedError.badFormat }
        return b.root
    }

    static func parseFeed(_ data: Data) throws -> [Entry] {
        let root = try tree(data)
        if let channel = root.child("rss")?.child("channel") {
            return channel.all("item").map { it in
                let link = it.value("link")
                return Entry(id: it.value("guid").nonEmpty ?? link, title: Plain.clean(it.value("title")), link: link,
                             date: Dates.parse(it.value("pubDate").nonEmpty ?? it.value("dc:date")),
                             summary: String(Plain.clean(it.value("description")).prefix(300)), image: image(it))
            }
        }
        if let feed = root.child("feed") {
            return feed.all("entry").map { it in
                let links = it.all("link")
                let alt = links.first { ($0.attrs["rel"] ?? "alternate") == "alternate" } ?? links.first
                let link = alt?.attrs["href"] ?? alt?.text ?? ""
                return Entry(id: it.value("id").nonEmpty ?? link, title: Plain.clean(it.value("title")), link: link,
                             date: Dates.parse(it.value("published").nonEmpty ?? it.value("updated")),
                             summary: String(Plain.clean(it.value("summary").nonEmpty ?? it.value("content")).prefix(300)), image: image(it))
            }
        }
        if let rdf = root.child("rdf:RDF") {
            return rdf.all("item").map { it in
                Entry(id: it.value("link"), title: Plain.clean(it.value("title")), link: it.value("link"),
                      date: Dates.parse(it.value("dc:date")), summary: String(Plain.clean(it.value("description")).prefix(300)))
            }
        }
        throw FeedError.badFormat
    }

    static func parseSitemap(_ data: Data, match: NSRegularExpression) throws -> [Entry] {
        let root = try tree(data)
        guard let set = root.child("urlset") else { throw FeedError.badFormat }
        return set.all("url").compactMap { u in
            let loc = u.value("loc")
            guard match.firstMatch(in: loc, range: NSRange(loc.startIndex..., in: loc)) != nil else { return nil }
            return Entry(id: loc, title: "", link: loc, date: Dates.parse(u.value("lastmod")), summary: "")
        }
    }
}

enum Dates {
    private static let rfc822: [DateFormatter] = ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z", "yyyy-MM-dd HH:mm:ss"].map {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = $0
        return f
    }
    private static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()
    private static let isoFrac: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()

    static func parse(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if let d = iso.date(from: t) ?? isoFrac.date(from: t) { return d }
        for f in rfc822 { if let d = f.date(from: t) { return d } }
        return nil
    }
}

enum Plain {
    private static let named: [String: String] = ["nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "rsquo": "’", "lsquo": "‘", "ldquo": "“", "rdquo": "”", "hellip": "…", "ndash": "–", "mdash": "—",
        "middot": "·", "bull": "•", "laquo": "«", "raquo": "»", "copy": "©", "reg": "®", "trade": "™"]
    private static let entity = try! NSRegularExpression(pattern: "&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z]{2,8});")

    static func clean(_ s: String) -> String {
        let out = decodeEntities(s.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression))
        return out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    // 한 번에 훑어 푼다(&amp;lt; 가 '<' 로 두 번 풀리지 않게). 숫자 표기(&#8217; · &#x2019;)는 모두, 이름 표기는 흔한 것만.
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in entity.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let body = ns.substring(with: m.range(at: 1))
            var rep: String?
            if body.hasPrefix("#") {
                let hex = body.dropFirst().first.map { $0 == "x" || $0 == "X" } ?? false
                let digits = hex ? body.dropFirst(2) : body.dropFirst()
                if let v = UInt32(digits, radix: hex ? 16 : 10), v != 0, let u = Unicode.Scalar(v) { rep = String(Character(u)) }
            } else {
                rep = named[body] ?? named[body.lowercased()]
            }
            out += rep ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    static func titleFromSlug(_ url: String) -> String {
        let slug = url.split(separator: "/").last.map(String.init) ?? url
        let t = slug.replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)
        return t.prefix(1).uppercased() + t.dropFirst()
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
