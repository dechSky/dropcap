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
    case badFormat, http(Int), blocked(String), tooLarge(Int)
    var errorDescription: String? {
        switch self {
        case .tooLarge(let limit): return "응답이 너무 커서 받다가 멈춤(\(limit >> 20)MB 넘음)"
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

    // guid·link 가 모두 빈 글의 id: 제목+날짜로 만든 고정 값(A-31: 빈 id 로 key 가 `출처|` 로 겹쳐 하나만 남던 문제). 실행마다 같다
    static func fallbackID(_ title: String, _ date: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325 // FNV-1a
        for b in (title.trimmingCharacters(in: .whitespacesAndNewlines) + "|" + date.trimmingCharacters(in: .whitespacesAndNewlines)).utf8 {
            h = (h ^ UInt64(b)) &* 0x100000001b3
        }
        return "noid-" + String(h, radix: 36)
    }

    static func parseFeed(_ data: Data) throws -> [Entry] {
        let root = try tree(data)
        if let channel = root.child("rss")?.child("channel") {
            return channel.all("item").map { it in
                let link = it.value("link")
                return Entry(id: it.value("guid").nonEmpty ?? link.nonEmpty ?? fallbackID(it.value("title"), it.value("pubDate")), title: Plain.clean(it.value("title")), link: link,
                             date: Dates.parse(it.value("pubDate").nonEmpty ?? it.value("dc:date")),
                             summary: String(Plain.clean(it.value("description")).prefix(300)), image: image(it))
            }
        }
        if let feed = root.child("feed") {
            return feed.all("entry").map { it in
                let links = it.all("link")
                let alt = links.first { ($0.attrs["rel"] ?? "alternate") == "alternate" } ?? links.first
                let link = alt?.attrs["href"] ?? alt?.text ?? ""
                return Entry(id: it.value("id").nonEmpty ?? link.nonEmpty ?? fallbackID(it.value("title"), it.value("updated")), title: Plain.clean(it.value("title")), link: link,
                             date: Dates.parse(it.value("published").nonEmpty ?? it.value("updated")),
                             summary: String(Plain.clean(it.value("summary").nonEmpty ?? it.value("content")).prefix(300)), image: image(it))
            }
        }
        if let rdf = root.child("rdf:RDF") {
            return rdf.all("item").map { it in
                Entry(id: it.value("link").nonEmpty ?? fallbackID(it.value("title"), it.value("dc:date")), title: Plain.clean(it.value("title")), link: it.value("link"),
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
    private static func formatter(_ format: String, zone: TimeZone? = nil) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        if let zone { f.timeZone = zone }
        return f
    }
    private static let rfc822: [DateFormatter] = ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z"].map { formatter($0) }
    // 요일을 뗀 뒤 다시 시도하는 모양(요일이 틀렸거나 월을 숫자로 쓴 피드: 'Tue, 13 10 2026 16:00:47 +0900')
    private static let loose: [DateFormatter] = ["dd MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm Z", "dd MM yyyy HH:mm:ss Z", "dd MM yyyy HH:mm Z",
                                                 "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd HH:mm:ssZ"].map { formatter($0) }
    // 시간대가 없는 국내 표기는 한국 시각으로 읽는다(AI타임스 'yyyy-MM-dd HH:mm:ss', 점·빗금 구분, 날짜만)
    static let seoul = TimeZone(identifier: "Asia/Seoul")!
    private static let local: [DateFormatter] = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy.MM.dd HH:mm:ss", "yyyy.MM.dd HH:mm",
                                                 "yyyy/MM/dd HH:mm:ss", "yyyy/MM/dd HH:mm", "yyyy-MM-dd", "yyyy.MM.dd", "yyyy/MM/dd"].map { formatter($0, zone: seoul) }
    private static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()
    private static let isoFrac: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    // 숫자로 바꿔 읽을 시간대 이름(DateFormatter 가 모르거나 지역마다 뜻이 다른 것)
    private static let zoneNames = ["KST": "+0900", "JST": "+0900", "UT": "+0000", "UTC": "+0000", "GMT": "+0000", "Z": "+0000",
                                    "EST": "-0500", "EDT": "-0400", "CST": "-0600", "CDT": "-0500", "MST": "-0700", "MDT": "-0600", "PST": "-0800", "PDT": "-0700"]

    static func parse(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if let d = iso.date(from: t) ?? isoFrac.date(from: t) { return d }
        for f in rfc822 { if let d = f.date(from: t) { return d } }
        return parseLoose(t)
    }

    // 흔한 비표준 표기: '+09:00'(RFC 822 에 콜론), 시간대 이름, 틀린 요일, 숫자 월, 한국어 표기, 시간대 없는 표기
    private static func parseLoose(_ t: String) -> Date? {
        if let d = korean(t) { return d }
        var n = t.replacingOccurrences(of: #"^[A-Za-z]{2,9}\.?,?\s+"#, with: "", options: .regularExpression)   // 요일 떼기
        n = n.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if let r = n.range(of: #"\s?([A-Z]{1,4})$"#, options: .regularExpression) {
            let name = n[r].trimmingCharacters(in: .whitespaces)
            if let off = zoneNames[name] { n = n[..<r.lowerBound] + " " + off }
        }
        n = n.replacingOccurrences(of: #"([+-]\d\d):(\d\d)$"#, with: "$1$2", options: .regularExpression)       // +09:00 → +0900
        for f in loose { if let d = f.date(from: n) { return d } }
        for f in local { if let d = f.date(from: n) { return d } }
        return nil
    }

    // '2024년 10월 29일 화요일 오후 11:30:00' 같은 한국어 표기(한국 시각)
    private static func korean(_ t: String) -> Date? {
        guard t.contains("년"), let re = try? NSRegularExpression(pattern: #"(\d{4})년\s*(\d{1,2})월\s*(\d{1,2})일(?:\s*\S+요일)?(?:\s*(오전|오후))?(?:\s*(\d{1,2}):(\d{2})(?::(\d{2}))?)?"#),
              let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) else { return nil }
        func g(_ i: Int) -> String? { Range(m.range(at: i), in: t).map { String(t[$0]) } }
        var c = DateComponents()
        c.timeZone = seoul
        c.year = Int(g(1)!); c.month = Int(g(2)!); c.day = Int(g(3)!)
        var hour = g(5).flatMap(Int.init) ?? 0
        if g(4) == "오후", hour < 12 { hour += 12 }
        if g(4) == "오전", hour == 12 { hour = 0 }
        c.hour = hour; c.minute = g(6).flatMap(Int.init) ?? 0; c.second = g(7).flatMap(Int.init) ?? 0
        return Calendar(identifier: .gregorian).date(from: c)
    }
}

// 피드 날짜 다듬기: 받은 뒤 한 번에 적용한다.
// - 날짜가 없는 글(한겨레 RSS 등)은 처음 본 시각을 날짜로(같은 실행 동안 바뀌지 않게 기억)
// - 지금보다 10분 넘게 앞선 시각(시간대를 잘못 찍은 피드, 예약 글)은 받은 시각으로 자른다
enum FeedDates {
    static let futureSlack: TimeInterval = 10 * 60
    static let memoryLimit = 20000

    static func repair(_ entries: inout [FeedParser.Entry], sourceID: String, now: Date, firstSeen: inout [String: Date]) {
        for i in entries.indices {
            if let d = entries[i].date {
                if d.timeIntervalSince(now) > futureSlack { entries[i].date = now }
            } else {
                let key = "\(sourceID)|\(entries[i].id)"
                if let seen = firstSeen[key] {
                    entries[i].date = seen
                } else {
                    firstSeen[key] = now
                    entries[i].date = now
                }
            }
        }
        if firstSeen.count > memoryLimit {
            for (k, _) in firstSeen.sorted(by: { $0.value < $1.value }).prefix(firstSeen.count - memoryLimit / 2) { firstSeen.removeValue(forKey: k) }
        }
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
