import Foundation

// 앱 상태. ~/Library/Application Support/AI News Alert/native-state.json
// (예전 Electron 판의 state.json 과는 파일을 나눠서 서로 덮어쓰지 않는다)
struct AppState: Codable {
    var seen: [String: Double] = [:]
    var seeded: [String] = []
    var enabled: [String: Bool] = [:]
    var recent: [NewsItem] = []
    var lastCheck: Date?
    var errors: [String: String] = [:]
    var unread: Int = 0
    var read: [String: Double] = [:]    // 읽은 기사 key → 읽은 시각
    var saved: [NewsItem] = []          // 나중에 읽기
    var customSources: [Source] = []    // 직접 추가한 출처
    var snoozeUntil: Date?              // 알림 잠시 끄기
    var lastDigest: Date?               // 마지막 아침 브리핑
    var interestCategory: [String: Double] = [:]  // 분야별로 연 횟수(관심사)
    var interestSource: [String: Double] = [:]
    var magazineBackfilled = false      // 처음 매거진을 채웠는지
    var settings = Settings()

    struct Settings: Codable, Equatable {
        enum Style: String, Codable, CaseIterable { case drop, system }
        enum Position: String, Codable, CaseIterable { case center, right }
        var style: Style = .drop
        var sound = true
        var intervalMinutes = 5
        var position: Position = .center
        var quietEnabled = false        // 방해 금지 시간
        var quietStart = 23             // 시(0~23)
        var quietEnd = 7
        var mustKeywords: [String] = [] // 꼭 알림(중요 표시)
        var muteKeywords: [String] = [] // 알리지 않음
        var digestEnabled = true        // 아침 브리핑
        var digestHour = 9

        init() {}
        // 새 항목이 추가돼도 예전 파일을 그대로 읽는다(없는 값은 기본값)
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            style = (try? c.decodeIfPresent(Style.self, forKey: .style)) ?? .drop
            sound = (try? c.decodeIfPresent(Bool.self, forKey: .sound)) ?? true
            intervalMinutes = (try? c.decodeIfPresent(Int.self, forKey: .intervalMinutes)) ?? 5
            position = (try? c.decodeIfPresent(Position.self, forKey: .position)) ?? .center // 예전 값 "auto" 도 가운데로
            quietEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .quietEnabled)) ?? false
            quietStart = (try? c.decodeIfPresent(Int.self, forKey: .quietStart)) ?? 23
            quietEnd = (try? c.decodeIfPresent(Int.self, forKey: .quietEnd)) ?? 7
            mustKeywords = (try? c.decodeIfPresent([String].self, forKey: .mustKeywords)) ?? []
            muteKeywords = (try? c.decodeIfPresent([String].self, forKey: .muteKeywords)) ?? []
            digestEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .digestEnabled)) ?? true
            digestHour = (try? c.decodeIfPresent(Int.self, forKey: .digestHour)) ?? 9
        }
    }

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seen = (try? c.decodeIfPresent([String: Double].self, forKey: .seen)) ?? [:]
        seeded = (try? c.decodeIfPresent([String].self, forKey: .seeded)) ?? []
        enabled = (try? c.decodeIfPresent([String: Bool].self, forKey: .enabled)) ?? [:]
        recent = (try? c.decodeIfPresent([NewsItem].self, forKey: .recent)) ?? []
        lastCheck = try? c.decodeIfPresent(Date.self, forKey: .lastCheck)
        errors = (try? c.decodeIfPresent([String: String].self, forKey: .errors)) ?? [:]
        unread = (try? c.decodeIfPresent(Int.self, forKey: .unread)) ?? 0
        if let r = try? c.decodeIfPresent([String: Double].self, forKey: .read) {
            read = r
        } else if let old = try? c.decodeIfPresent([String].self, forKey: .read) {
            read = Dictionary(old.map { ($0, 0) }, uniquingKeysWith: { a, _ in a }) // 예전 형식(목록)
        }
        saved = (try? c.decodeIfPresent([NewsItem].self, forKey: .saved)) ?? []
        customSources = (try? c.decodeIfPresent([Source].self, forKey: .customSources)) ?? []
        snoozeUntil = try? c.decodeIfPresent(Date.self, forKey: .snoozeUntil)
        lastDigest = try? c.decodeIfPresent(Date.self, forKey: .lastDigest)
        interestCategory = (try? c.decodeIfPresent([String: Double].self, forKey: .interestCategory)) ?? [:]
        interestSource = (try? c.decodeIfPresent([String: Double].self, forKey: .interestSource)) ?? [:]
        magazineBackfilled = (try? c.decodeIfPresent(Bool.self, forKey: .magazineBackfilled)) ?? false
        settings = (try? c.decodeIfPresent(Settings.self, forKey: .settings)) ?? Settings()
    }
}

enum Store {
    static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("AI News Alert", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static let file = dir.appendingPathComponent("native-state.json")
    static let seenLimit = 8000

    static var exists: Bool { FileManager.default.fileExists(atPath: file.path) }

    static func load() -> AppState {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var s = (try? Data(contentsOf: file)).flatMap { try? dec.decode(AppState.self, from: $0) } ?? AppState()
        for src in Resources.config.sources + s.customSources where s.enabled[src.id] == nil { s.enabled[src.id] = src.defaultOn }
        return s
    }

    private static var backedUp = false

    static func save(_ state: AppState) {
        // 실행마다 첫 저장 전에 이전 파일을 .bak 으로 남긴다(형식이 바뀌어 일부를 못 읽었을 때 되살릴 수 있게)
        if !backedUp, exists {
            backedUp = true
            let bak = dir.appendingPathComponent("native-state.bak.json")
            try? FileManager.default.removeItem(at: bak)
            try? FileManager.default.copyItem(at: file, to: bak)
        }
        var s = state
        if s.seen.count > seenLimit {
            let drop = s.seen.sorted { $0.value < $1.value }.prefix(s.seen.count - seenLimit)
            for (k, _) in drop { s.seen.removeValue(forKey: k) }
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(s) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
