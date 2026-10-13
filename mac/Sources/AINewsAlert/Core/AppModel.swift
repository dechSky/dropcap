import AppKit
import Foundation
import ServiceManagement
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var state: AppState
    @Published private(set) var checking = false
    let firstRun: Bool

    private let maxAge: TimeInterval = 3 * 24 * 3600 // 날짜가 3일보다 오래된 글은 새 글로 치지 않음
    private let recentLimit = 300 // 검색해서 다시 찾을 수 있게 넉넉히
    private var minuteTimer: Timer?
    private var loop: Task<Void, Never>?

    private init() {
        firstRun = !Store.exists
        state = Store.load()
    }

    // MARK: 시작
    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                await AppModel.shared.checkAll()
            }
        }
        restartLoop()
        // 1분마다: 아침 브리핑 시각인지, 잠시 끄기가 끝났는지
        let t = Timer(timeInterval: 60, repeats: true) { _ in MainActor.assumeIsolated { AppModel.shared.minuteTick() } }
        RunLoop.main.add(t, forMode: .common)
        minuteTimer = t
        HotKey.register { AppModel.shared.openLatestUnread() } // ⌥⌘N
        if firstRun {
            ToastCenter.shared.showWelcome()
        }
        if state.settings.style == .system { SystemNotifier.requestAuthorization() }
    }

    private func restartLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                // 별도 작업으로 돌려, 간격을 바꿔 이 반복이 취소돼도 진행 중인 확인은 끝까지 간다
                await Task { await self?.checkAll() }.value
                let minutes = await MainActor.run { self?.state.settings.intervalMinutes ?? 5 }
                try? await Task.sleep(for: .seconds(Double(minutes) * 60))
            }
        }
    }

    // MARK: 확인
    func checkAll(manual: Bool = false) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }

        let active = allSources.filter { state.enabled[$0.id] == true }
        var found: [NewsItem] = []
        await withTaskGroup(of: (Source, Result<[NewsItem]?, Error>).self) { group in
            for src in active {
                group.addTask {
                    do { return (src, .success(try await FeedService.shared.items(for: src))) } catch { return (src, .failure(error)) }
                }
            }
            for await (src, res) in group {
                switch res {
                case .success(let items):
                    state.errors.removeValue(forKey: src.id)
                    if let items { found += await fresh(items, from: src) }
                case .failure(let e):
                    state.errors[src.id] = e.localizedDescription
                }
            }
        }

        found.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        if !found.isEmpty {
            let titles = await Translator.shared.translateMany(found.map(\.title))
            for i in found.indices where titles[i] != found[i].title { found[i].titleKo = titles[i] }
        }
        found = applyKeywords(found) // 번역 뒤에: 한국어 낱말도 영어 기사에 걸리게
        found = groupSameStory(found)
        state.recent = Array((found + state.recent).prefix(recentLimit))
        state.unread += found.count
        state.lastCheck = Date()
        Store.save(state)
        if (isQuietTime || isSnoozed), !manual {
            return // 방해 금지 시간·잠시 끄기: 알리지 않고 안 읽은 소식으로만 쌓는다
        }
        // 중요 표시가 붙은 소식을 먼저
        deliver(found.sorted { ($0.important == true ? 0 : 1) < ($1.important == true ? 0 : 1) }, manual: manual)
    }

    // MARK: 거르기·묶기
    var allSources: [Source] { Resources.config.sources + state.customSources }

    private static func words(_ list: [String]) -> [String] {
        list.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    // '알리지 않음' 낱말이 든 소식은 빼고, '꼭 알림' 낱말이 든 소식은 중요 표시
    private func applyKeywords(_ items: [NewsItem]) -> [NewsItem] {
        let mute = Self.words(state.settings.muteKeywords), must = Self.words(state.settings.mustKeywords)
        return items.compactMap { it in
            let text = "\(it.title) \(it.titleKo ?? "") \(it.summary)".lowercased()
            if mute.contains(where: { text.contains($0) }) { return nil }
            var it = it
            if must.contains(where: { text.contains($0) }) { it.important = true }
            return it
        }
    }

    // 여러 곳이 같은 소식을 다루면 하나만 알리고 "다른 N곳도 보도"로 묶는다.
    // 공식 발표 > 언론 > 국내 순으로 대표를 고른다.
    private func groupSameStory(_ items: [NewsItem]) -> [NewsItem] {
        let rank = ["lab": 0, "press": 1, "kr": 2]
        let sorted = items.sorted { (rank[$0.tier] ?? 3, $1.date ?? .distantPast) < (rank[$1.tier] ?? 3, $0.date ?? .distantPast) }
        var kept: [NewsItem] = []
        for it in sorted {
            let words = StoryMatch.tokens(it.title)
            if let i = kept.firstIndex(where: { StoryMatch.similar(words, StoryMatch.tokens($0.title)) }) {
                kept[i].related = (kept[i].related ?? []) + [it.sourceName]
                continue
            }
            // 하루 반 안에 이미 알린 소식과 같으면 알리지 않고 그 소식에 출처만 더한다
            let cutoff = Date().addingTimeInterval(-36 * 3600)
            if let j = state.recent.firstIndex(where: { ($0.date ?? .distantPast) > cutoff && StoryMatch.similar(words, StoryMatch.tokens($0.title)) }) {
                if !(state.recent[j].related ?? []).contains(it.sourceName), state.recent[j].sourceName != it.sourceName {
                    state.recent[j].related = (state.recent[j].related ?? []) + [it.sourceName]
                }
                continue
            }
            kept.append(it)
        }
        return kept.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    var isQuietTime: Bool {
        let st = state.settings
        guard st.quietEnabled, st.quietStart != st.quietEnd else { return false }
        return Self.inQuiet(hour: Calendar.current.component(.hour, from: Date()), start: st.quietStart, end: st.quietEnd)
    }

    // 자정을 넘는 구간(예: 23시~7시)도 처리
    nonisolated static func inQuiet(hour h: Int, start: Int, end: Int) -> Bool {
        guard start != end else { return false }
        return start < end ? (h >= start && h < end) : (h >= start || h < end)
    }

    private func fresh(_ items: [NewsItem], from src: Source) async -> [NewsItem] {
        let firstTime = !state.seeded.contains(src.id)
        let now = Date()
        var out: [NewsItem] = []
        for it in items {
            let known = state.seen[it.key] != nil
            state.seen[it.key] = now.timeIntervalSince1970 // 피드에 남아 있는 동안은 지워지지 않게 시각 갱신
            guard !known else { continue }
            if firstTime { continue } // 처음 켠 출처는 기존 글을 조용히 기억만 한다
            if let d = it.date, now.timeIntervalSince(d) > maxAge { continue }
            out.append(it)
        }
        if firstTime { state.seeded.append(src.id) }

        var kept: [NewsItem] = []
        for var it in out {
            if src.type == "sitemap" { await FeedService.shared.fillTitle(&it) }
            if src.aiOnly {
                let text = "\(it.title) \(it.summary)"
                if Resources.aiRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil { continue }
            }
            kept.append(it)
        }
        return kept
    }

    private func deliver(_ items: [NewsItem], manual: Bool) {
        if items.isEmpty {
            if manual { ToastCenter.shared.showInfo("새 소식이 없습니다", sub: "마지막 확인 \(Self.clock(state.lastCheck))") }
            return
        }
        switch state.settings.style {
        case .drop: ToastCenter.shared.show(items, sound: state.settings.sound)
        case .system: SystemNotifier.post(items, sound: state.settings.sound)
        }
        ArticleService.shared.prefetch(Array(items.prefix(3))) // 누르기 전에 미리 본문·번역·요약 준비
    }

    // MARK: 동작
    func open(_ item: NewsItem) {
        guard item.id != Self.previewID else { return }
        markRead()
        setRead(item, true)
        ReaderController.open(item)
    }

    // MARK: 잠시 끄기·브리핑·단축키
    var isSnoozed: Bool { (state.snoozeUntil ?? .distantPast) > Date() }

    func snooze(_ until: Date?) {
        state.snoozeUntil = until
        Store.save(state)
    }

    static func tomorrowMorning(hour: Int = 8) -> Date {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date())!
        return cal.date(bySettingHour: hour, minute: 0, second: 0, of: tomorrow)!
    }

    private func minuteTick() {
        if let s = state.snoozeUntil, s <= Date() { state.snoozeUntil = nil; Store.save(state) }
        let st = state.settings
        guard st.digestEnabled else { return }
        let cal = Calendar.current
        let now = Date()
        guard cal.component(.hour, from: now) >= st.digestHour,
              !(state.lastDigest.map { cal.isDate($0, inSameDayAs: now) } ?? false) else { return }
        state.lastDigest = now
        Store.save(state)
        let items = digestItems
        guard !items.isEmpty, !isQuietTime else { return }
        ToastCenter.shared.showDigest(count: items.count)
    }

    // 지난 24시간 소식
    var digestItems: [NewsItem] {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        return state.recent.filter { ($0.date ?? .distantPast) > cutoff }
    }

    func openLatestUnread() {
        if let it = state.recent.first(where: { !isRead($0) }) ?? state.recent.first { open(it) }
    }

    // MARK: 읽음·저장
    func isRead(_ item: NewsItem) -> Bool { state.read[item.key] != nil }
    func isSaved(_ item: NewsItem) -> Bool { state.saved.contains { $0.key == item.key } }

    func setRead(_ item: NewsItem, _ on: Bool) {
        if on { state.read[item.key] = Date().timeIntervalSince1970 } else { state.read.removeValue(forKey: item.key) }
        if state.read.count > 3000 {
            for (k, _) in state.read.sorted(by: { $0.value < $1.value }).prefix(state.read.count - 2000) { state.read.removeValue(forKey: k) }
        }
        Store.save(state)
    }

    func markAllRead() {
        let now = Date().timeIntervalSince1970
        for it in state.recent where state.read[it.key] == nil { state.read[it.key] = now }
        state.unread = 0
        Store.save(state)
    }

    func toggleSaved(_ item: NewsItem) {
        if isSaved(item) { state.saved.removeAll { $0.key == item.key } } else { state.saved.insert(item, at: 0) }
        Store.save(state)
    }

    // MARK: 직접 추가한 출처
    // 주소를 실제로 받아 읽어 보고, 되면 추가한다. 실패하면 이유를 돌려준다.
    func addCustomSource(name: String, url: String) async -> String? {
        let u = url.trimmingCharacters(in: .whitespaces)
        guard let parsed = URL(string: u), parsed.scheme?.hasPrefix("http") == true else { return "http(s) 주소를 넣어 주세요" }
        let palette = ["#6E56CF", "#0090FF", "#E5484D", "#30A46C", "#F76B15", "#D6409F", "#12A594"]
        let src = Source(id: "custom-\(abs(u.hashValue))", name: name.trimmingCharacters(in: .whitespaces).nonEmpty ?? (parsed.host ?? u),
                         tier: "press", type: "feed", url: u, match: nil, aiOnly: false, defaultOn: true,
                         color: palette[state.customSources.count % palette.count])
        guard !allSources.contains(where: { $0.url == u }) else { return "이미 있는 출처입니다" }
        do {
            guard let items = try await FeedService.shared.items(for: src), !items.isEmpty else { return "글을 찾지 못했습니다" }
            // 지금 있는 글은 이 자리에서 기억해 두고(알리지 않음), 이후에 올라오는 글부터 알린다
            let now = Date().timeIntervalSince1970
            for it in items { state.seen[it.key] = now }
            state.seeded.append(src.id)
        } catch {
            return "읽지 못했습니다: \(error.localizedDescription)"
        }
        state.customSources.append(src)
        state.enabled[src.id] = true
        Store.save(state)
        return nil
    }

    func removeCustomSource(_ id: String) {
        state.customSources.removeAll { $0.id == id }
        state.enabled.removeValue(forKey: id)
        state.seeded.removeAll { $0 == id }
        Store.save(state)
    }

    func markRead() {
        guard state.unread != 0 else { return }
        state.unread = 0
        Store.save(state)
    }

    func setEnabled(_ id: String, _ on: Bool) {
        state.enabled[id] = on
        Store.save(state)
        if on { Task { await checkAll() } }
    }

    func update(_ change: (inout AppState.Settings) -> Void) {
        let before = state.settings
        change(&state.settings)
        Store.save(state)
        if state.settings.style == .system, before.style != .system { SystemNotifier.requestAuthorization() }
        if state.settings.intervalMinutes != before.intervalMinutes { restartLoop() }
    }

    // 견본 카드. 실제 기사를 다시 띄우면 같은 소식이 또 온 것처럼 보이므로 쓰지 않는다
    static let previewID = "preview"

    func preview() {
        let item = NewsItem(
            id: Self.previewID, title: "This is how new AI news will drop in", titleKo: "새 AI 소식은 이렇게 떨어집니다",
            link: "", date: Date(), summary: "", sourceId: "openai", sourceName: "미리 보기", tier: "lab")
        deliver([item], manual: false)
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("로그인 항목 설정 실패: \(error)")
            }
            objectWillChange.send()
        }
    }

    static func clock(_ d: Date?) -> String {
        guard let d else { return "아직 없음" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "a h:mm"
        return f.string(from: d)
    }
}

// 시스템 알림(알림 센터) 방식을 고른 사람을 위해
enum SystemNotifier {
    // 알림 센터는 .app 묶음 안에서만 쓸 수 있다(개발 중 `swift run` 에서는 꺼 둠)
    static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ items: [NewsItem], sound: Bool) {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        for it in items.prefix(3) {
            let c = UNMutableNotificationContent()
            c.title = "\(it.sourceName) · \(Resources.tierLabel(it.tier))"
            c.body = it.titleKo.map { "\($0)\n\(it.title)" } ?? it.title
            c.userInfo = ["key": it.key]
            if sound { c.sound = .default }
            center.add(UNNotificationRequest(identifier: it.key, content: c, trigger: nil))
        }
        if items.count > 3 {
            let c = UNMutableNotificationContent()
            c.title = "AI 소식 \(items.count - 3)건 더"
            c.body = "상단바 아이콘에서 볼 수 있습니다."
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
    }
}

// 제목 낱말이 많이 겹치면 같은 소식으로 본다(영어 원제목 기준)
enum StoryMatch {
    private static let stop: Set<String> = ["the", "and", "for", "with", "its", "new", "into", "from", "that", "this", "are", "has", "how", "what", "why", "will", "your", "you", "our", "says", "after", "over", "more", "than", "about", "now"]

    static func tokens(_ title: String) -> Set<String> {
        let lowered = title.lowercased()
        let parts = lowered.components(separatedBy: CharacterSet.alphanumerics.inverted)
        return Set(parts.filter { $0.count >= 3 && !stop.contains($0) || ($0.count >= 2 && $0.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }) })
    }

    static func similar(_ a: Set<String>, _ b: Set<String>) -> Bool {
        guard a.count >= 3, b.count >= 3 else { return false }
        let inter = a.intersection(b).count
        return Double(inter) / Double(min(a.count, b.count)) >= 0.6 && inter >= 3
    }
}
