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
    // 일반 뉴스 분야
    var sectionsChosen: [String]?       // 고른 관심 분야(nil = 아직 고르지 않음 → 첫 실행 고르기 화면)
    var sectionPolicy: [String: SectionPolicy] = [:] // 분야별 알림 모드·묶음 시각·하루 상한
    var hiddenSources: [String] = []    // '이 출처 숨기기'(목록·매거진·알림 모두에서 뺌)
    var pending: [PendingItem] = []     // 고인 소식(묶음 시각에 한 방울로)
    var notifyLog: [NotifyMark] = []    // 떨어뜨린 물방울 기록(하루 상한 계산)
    var notifiedStories: [String: Double] = [:] // 알린 스토리 → 시각(같은 이야기 한 번만)
    var lastBundle: [String: Date] = [:] // 분야 → 마지막으로 묶음을 보낸 때
    var briefs: [String: SectionBrief] = [:] // 분야 → 마지막 저녁 정리(묶음 시각에 기기 안 요약)
    var settings = Settings()

    struct PendingItem: Codable, Hashable {
        var item: NewsItem
        var section: String
        var story: String       // 같은 이야기를 두 번 고이지 않게
        var at: Date
    }
    struct NotifyMark: Codable, Hashable {
        var section: String
        var at: Date
    }

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
        var totalDailyCap = 10          // 모든 분야를 합친 하루 물방울 수
        var krThreshold = 3             // 국내 n곳 이상 보도면 중요
        var intlThreshold = 2           // 해외 n곳 이상
        var bigThreshold = 8            // 국내 n곳 이상이면 상한 무시
        var autoQuietFullscreen = true  // 전체 화면 앱 사용 중에는 조용히(고임)
        var autoQuietSharing = true     // 화면 공유·기록 중
        var autoQuietCalendar = false   // 캘린더 일정 중(켤 때 권한을 묻는다)

        var limits: PolicyLimits {
            PolicyLimits(totalCap: totalDailyCap, krThreshold: krThreshold, intlThreshold: intlThreshold, bigThreshold: bigThreshold)
        }

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
            totalDailyCap = (try? c.decodeIfPresent(Int.self, forKey: .totalDailyCap)) ?? 10
            krThreshold = (try? c.decodeIfPresent(Int.self, forKey: .krThreshold)) ?? 3
            intlThreshold = (try? c.decodeIfPresent(Int.self, forKey: .intlThreshold)) ?? 2
            bigThreshold = (try? c.decodeIfPresent(Int.self, forKey: .bigThreshold)) ?? 8
            autoQuietFullscreen = (try? c.decodeIfPresent(Bool.self, forKey: .autoQuietFullscreen)) ?? true
            autoQuietSharing = (try? c.decodeIfPresent(Bool.self, forKey: .autoQuietSharing)) ?? true
            autoQuietCalendar = (try? c.decodeIfPresent(Bool.self, forKey: .autoQuietCalendar)) ?? false
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
        sectionsChosen = try? c.decodeIfPresent([String].self, forKey: .sectionsChosen)
        sectionPolicy = (try? c.decodeIfPresent([String: SectionPolicy].self, forKey: .sectionPolicy)) ?? [:]
        hiddenSources = (try? c.decodeIfPresent([String].self, forKey: .hiddenSources)) ?? []
        pending = (try? c.decodeIfPresent([PendingItem].self, forKey: .pending)) ?? []
        notifyLog = (try? c.decodeIfPresent([NotifyMark].self, forKey: .notifyLog)) ?? []
        notifiedStories = (try? c.decodeIfPresent([String: Double].self, forKey: .notifiedStories)) ?? [:]
        lastBundle = (try? c.decodeIfPresent([String: Date].self, forKey: .lastBundle)) ?? [:]
        briefs = (try? c.decodeIfPresent([String: SectionBrief].self, forKey: .briefs)) ?? [:]
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
        if fromBackup { saver.skipBackup() }
        let existed = (try? Data(contentsOf: file)) != nil || fromBackup
        return prepare(state, existing: existed, sources: Resources.config.sources)
    }

    // 읽은 상태를 쓸 수 있게 다듬는다.
    // - 예전(AI 전용) 사용자: 분야를 고른 적이 없으면 'AI' 하나만 고른 것으로 옮기고, AI 는 예전처럼 즉시 알림.
    // - 출처 켜기 기본값: 분야가 있는 출처는 그 분야를 골랐을 때만 기본으로 켠다(새로 생긴 국내 언론이 한꺼번에 켜지지 않게).
    static func prepare(_ state: AppState, existing: Bool, sources: [Source], meta: [String: SourceMeta] = Sections.meta) -> AppState {
        var s = state
        if s.sectionsChosen == nil, existing {
            s.sectionsChosen = [Sections.ai]
            s.sectionPolicy[Sections.ai] = SectionPolicy(mode: .instant)
        }
        for src in sources + s.customSources where s.enabled[src.id] == nil {
            if let sec = Sections.section(ofSource: src.id, meta: meta), meta[src.id]?.section != nil {
                s.enabled[src.id] = src.defaultOn && (s.sectionsChosen?.contains(sec) ?? false)
            } else {
                s.enabled[src.id] = src.defaultOn
            }
        }
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


    // 본 글 기억은 오래된 것부터 정리해 seenLimit 개만 남긴다
    static func pruned(_ seen: [String: Double], limit: Int = seenLimit) -> [String: Double] {
        guard seen.count > limit else { return seen }
        var out = seen
        for (k, _) in seen.sorted(by: { $0.value < $1.value }).prefix(seen.count - limit) { out.removeValue(forKey: k) }
        return out
    }

    // 저장 묶기(R-3): 0.5초 안의 저장 요청은 마지막 것 하나만, 뒤 스레드에서 쓴다. 끝낼 때·잠들기 전에는 flush() 로 바로.
    static let saver = StateSaver(file: file, backup: backupFile)
    static func save(_ state: AppState) { saver.save(state) }
    static func flush() { saver.flush() }

    // 실제 쓰기: 실행마다 첫 쓰기 전에 이전 파일을 .bak 으로 남기고(형식이 바뀌어 일부를 못 읽었을 때 되살릴 수 있게),
    // 본 글 기억을 정리한 뒤 원자적으로 쓴다.
    static func write(_ state: AppState, to file: URL, backup: URL, backedUp: inout Bool) {
        if !backedUp, FileManager.default.fileExists(atPath: file.path) {
            backedUp = true
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: file, to: backup)
        }
        var s = state
        s.seen = pruned(s.seen)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(s) else { return }
        try? data.write(to: file, options: .atomic)
    }
}

// 저장 요청을 모아 한 번에 쓰는 일꾼. 상태는 값이라 사본을 뒤 스레드로 넘겨 인코딩·쓰기를 한다.
final class StateSaver: @unchecked Sendable {
    private let file: URL
    private let backup: URL
    private let delay: TimeInterval
    private let queue = DispatchQueue(label: "dropcap.state-writer", qos: .utility)
    private let lock = NSLock()
    private var pending: AppState?
    private var scheduled = false
    private var backedUp = false      // 쓰기 줄(queue)에서만 바꾼다
    private(set) var writes = 0       // 시험용: 실제로 쓴 횟수

    init(file: URL, backup: URL, delay: TimeInterval = 0.5) {
        self.file = file; self.backup = backup; self.delay = delay
    }

    // 본 파일이 깨져 .bak 에서 읽은 실행: 깨진 파일로 .bak 을 덮어쓰지 않게(A-03)
    func skipBackup() { queue.sync { backedUp = true } }

    func save(_ state: AppState) {
        lock.lock()
        pending = state
        let start = !scheduled
        scheduled = true
        lock.unlock()
        if start { queue.asyncAfter(deadline: .now() + delay) { [self] in writePending() } }
    }

    // 기다리는 저장이 있으면 지금 바로 쓴다(끝낼 때·잠들기 전)
    func flush() { queue.sync { writePending() } }

    private func writePending() {
        lock.lock()
        let s = pending
        pending = nil
        scheduled = false
        lock.unlock()
        guard let s else { return }
        Store.write(s, to: file, backup: backup, backedUp: &backedUp)
        writes += 1
    }
}
