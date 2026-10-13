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
    var notify: [String: Bool] = [:]    // 출처별 알림(없으면 출처 기본값)
    var followedStories: [String] = []  // 팔로우한 스토리(새 보도가 붙으면 알림)
    var storySeen: [String: Int] = [:]  // 스토리를 마지막으로 봤을 때의 보도 수('새 보도 N')
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
        notify = (try? c.decodeIfPresent([String: Bool].self, forKey: .notify)) ?? [:]
        followedStories = (try? c.decodeIfPresent([String].self, forKey: .followedStories)) ?? []
        storySeen = (try? c.decodeIfPresent([String: Int].self, forKey: .storySeen)) ?? [:]
        settings = (try? c.decodeIfPresent(Settings.self, forKey: .settings)) ?? Settings()
    }
}

enum Store {
    static let dir: URL = {
        // 시험용: DROPCAP_DATA_DIR 로 다른 폴더를 쓰면 실제 기록·구독을 건드리지 않는다
        if let custom = ProcessInfo.processInfo.environment["DROPCAP_DATA_DIR"] {
            let d = URL(fileURLWithPath: custom, isDirectory: true)
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            return d
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("Dropcap", isDirectory: true)
        // 이름이 바뀌기 전(AI News Alert) 기록이 있으면 한 번 옮겨 온다. 옛 폴더는 지우지 않고 이름만 표시해 남겨 둠.
        let old = base.appendingPathComponent("AI News Alert", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: d.path), fm.fileExists(atPath: old.appendingPathComponent("native-state.json").path) {
            do {
                // 이 앱이 쓰는 것만 옮긴다(예전 Electron 판의 캐시 등은 두고 온다)
                try fm.createDirectory(at: d, withIntermediateDirectories: true)
                for name in ["native-state.json", "native-state.bak.json", "magazine.sqlite", "magazine.sqlite-wal", "magazine.sqlite-shm", "articles", "images"] {
                    let from = old.appendingPathComponent(name)
                    if fm.fileExists(atPath: from.path) { try fm.copyItem(at: from, to: d.appendingPathComponent(name)) }
                }
                try? "이 폴더의 기록은 Dropcap 폴더로 복사되었습니다. 확인 후 지워도 됩니다.\n"
                    .write(to: old.appendingPathComponent("옮겨짐-Dropcap.txt"), atomically: true, encoding: .utf8)
                NSLog("[이름 변경] 기록을 Dropcap 폴더로 옮겼습니다")
            } catch {
                NSLog("[이름 변경] 기록 옮기기 실패: %@", error.localizedDescription)
            }
        }
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static let file = dir.appendingPathComponent("native-state.json")
    static let seenLimit = 8000

    static var exists: Bool { FileManager.default.fileExists(atPath: file.path) }

    static let backupFile = dir.appendingPathComponent("native-state.bak.json")

    static func load() -> AppState {
        let (state, fromBackup) = read(file, backup: backupFile)
        // 본 파일이 깨져 .bak 에서 읽었으면, 첫 저장 때 깨진 파일로 .bak 을 덮어쓰지 않게 한다
        if fromBackup { backedUp = true }
        var s = state
        for src in Resources.config.sources + s.customSources where s.enabled[src.id] == nil { s.enabled[src.id] = src.defaultOn }
        return s
    }

    // 본 파일을 통째로 못 읽으면(깨짐) .bak 을 읽는다. 깨진 파일은 .broken.json 으로 남겨 둔다.
    static func read(_ file: URL, backup: URL) -> (state: AppState, fromBackup: Bool) {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: file) else { return (AppState(), false) } // 처음 실행
        if let s = try? dec.decode(AppState.self, from: data) { return (s, false) }
        let broken = file.deletingPathExtension().appendingPathExtension("broken.json")
        try? FileManager.default.removeItem(at: broken)
        try? FileManager.default.copyItem(at: file, to: broken)
        if let b = try? Data(contentsOf: backup), let s = try? dec.decode(AppState.self, from: b) {
            NSLog("[상태] native-state.json 이 깨져 .bak 에서 되살렸습니다")
            return (s, true)
        }
        NSLog("[상태] native-state.json 이 깨졌고 .bak 도 읽지 못해 새로 시작합니다")
        return (AppState(), true)
    }

    private static var backedUp = false

    // 본 글 기억은 오래된 것부터 정리해 seenLimit 개만 남긴다
    static func pruned(_ seen: [String: Double], limit: Int = seenLimit) -> [String: Double] {
        guard seen.count > limit else { return seen }
        var out = seen
        for (k, _) in seen.sorted(by: { $0.value < $1.value }).prefix(seen.count - limit) { out.removeValue(forKey: k) }
        return out
    }

    static func save(_ state: AppState) {
        var state = state
        // 실행마다 첫 저장 전에 이전 파일을 .bak 으로 남긴다(형식이 바뀌어 일부를 못 읽었을 때 되살릴 수 있게)
        if !backedUp, exists {
            backedUp = true
            try? FileManager.default.removeItem(at: backupFile)
            try? FileManager.default.copyItem(at: file, to: backupFile)
        }
        var s = state
        s.seen = pruned(s.seen)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(s) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
