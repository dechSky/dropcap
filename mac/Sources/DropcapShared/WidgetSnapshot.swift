import Foundation

// 앱이 확인을 마칠 때마다 위젯에 넘기는 작은 사본.
// 앱: ~/Library/Application Support/Dropcap/Widget/snapshot.json (+ 줄인 사진 파일)
// 위젯(샌드박스): 같은 폴더만 읽기 전용 예외로 읽는다(Widgets.entitlements). 언제든 다시 만들 수 있는 사본이라 지워도 된다.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public static let version = 1
    public static let fileName = "snapshot.json"

    public struct Entry: Codable, Equatable, Hashable, Sendable {
        public var key: String          // NewsItem.key — 누르면 dropcap://open?key=...
        public var title: String
        public var source: String
        public var date: Date?
        public var image: String?       // 같은 폴더 안의 사진 파일 이름(줄인 JPEG)

        public init(key: String, title: String, source: String, date: Date?, image: String? = nil) {
            self.key = key; self.title = title; self.source = source; self.date = date; self.image = image
        }
        public var openURL: URL { WidgetLink.open(key: key) }
    }

    public var version: Int
    public var updated: Date
    public var unread: Int
    public var cover: Entry?            // 오늘의 표지
    public var latest: [Entry]          // 최신 몇 건(표지와 겹치지 않게)

    public init(updated: Date, unread: Int, cover: Entry?, latest: [Entry]) {
        version = Self.version; self.updated = updated; self.unread = unread; self.cover = cover; self.latest = latest
    }

    public static let empty = WidgetSnapshot(updated: .distantPast, unread: 0, cover: nil, latest: [])
    // 위젯 갤러리 미리 보기용
    public static let sample = WidgetSnapshot(
        updated: Date(), unread: 7,
        cover: Entry(key: "sample|1", title: "오늘의 표지 기사가 여기에 실립니다", source: "Dropcap", date: Date()),
        latest: [
            Entry(key: "sample|2", title: "새로 들어온 소식이 위에서부터", source: "출처", date: Date()),
            Entry(key: "sample|3", title: "세 건까지 보입니다", source: "출처", date: Date()),
            Entry(key: "sample|4", title: "누르면 읽기 창으로 열립니다", source: "출처", date: Date()),
        ])

    public static func decode(_ data: Data) -> WidgetSnapshot? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        guard let s = try? d.decode(WidgetSnapshot.self, from: data), s.version <= Self.version else { return nil }
        return s
    }

    public func encoded() -> Data? {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return try? e.encode(self)
    }

    // 실제 사용자 홈(샌드박스 안에서는 NSHomeDirectory 가 컨테이너를 가리키므로 계정 정보에서 읽는다)
    public static var defaultDirectory: URL {
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/Dropcap/Widget", isDirectory: true)
    }
}

// 위젯·Spotlight·단축어가 앱을 부르는 주소
public enum WidgetLink {
    public static let scheme = "dropcap"

    public static func open(key: String) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = "open"
        c.queryItems = [URLQueryItem(name: "key", value: key)]
        return c.url ?? URL(string: "dropcap://open")!
    }

    public static let magazine = URL(string: "dropcap://magazine")!

    // dropcap://open?key=... → key
    public static func key(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "open",
              let k = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "key" })?.value,
              !k.isEmpty else { return nil }
        return k
    }
}
