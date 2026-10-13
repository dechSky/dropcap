import NaturalLanguage
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
        Magazine.shared.migrateIfNeeded(from: state)
        Magazine.shared.publishDue()
        if !state.magazineBackfilled { Task { await backfillMagazine() } }
        restartLoop()
        // 1분마다: 아침 브리핑 시각인지, 잠시 끄기가 끝났는지
        let t = Timer(timeInterval: 60, repeats: true) { _ in MainActor.assumeIsolated { AppModel.shared.minuteTick() } }
        RunLoop.main.add(t, forMode: .common)
        minuteTimer = t
        HotKey.register(key: .n) { AppModel.shared.openLatestUnread() } // ⌥⌘N
        HotKey.register(key: .m) { MagazineController.open() }          // ⌥⌘M
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
        await addEnglishTitles(&found)
        Magazine.shared.ingest(found) // 매거진에는 묶이기 전 전부(여러 시각 비교용)
        // 알림을 끈 채널(논문·커뮤니티 등 양 많은 곳)은 매거진에만 싣고, 목록·알림에는 넣지 않는다
        found = found.filter { notifies($0.sourceId) }
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
            if let i = kept.firstIndex(where: { StoryMatch.same(it, $0) }) {
                kept[i].related = (kept[i].related ?? []) + [it.sourceName]
                continue
            }
            // 하루 반 안에 이미 알린 소식과 같으면 알리지 않고 그 소식에 출처만 더한다
            let cutoff = Date().addingTimeInterval(-36 * 3600)
            _ = words
            if let j = state.recent.firstIndex(where: { ($0.date ?? .distantPast) > cutoff && StoryMatch.same(it, $0) }) {
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
        noteInterest(item)
        ReaderController.open(item)
    }

    // 처음 한 번: 켜진 출처에서 최근 3일 기사를 받아 매거진 첫 호를 채운다(알림 없음)
    private func backfillMagazine() async {
        let cutoff = Date().addingTimeInterval(-3 * 24 * 3600)
        var all: [NewsItem] = []
        for src in allSources where state.enabled[src.id] == true {
            guard var items = try? await FeedService.shared.items(for: src, conditional: false) else { continue }
            items = items.filter { ($0.date ?? .distantPast) > cutoff }
            if src.type == "sitemap" {
                for i in items.indices.prefix(10) { await FeedService.shared.fillTitle(&items[i]) }
                items = Array(items.prefix(10))
            }
            if src.aiOnly {
                items = items.filter { let t = "\($0.title) \($0.summary)"; return Resources.aiRegex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil }
            }
            all += items.prefix(25)
        }
        let titles = await Translator.shared.translateMany(all.map(\.title))
        for i in all.indices where titles[i] != all[i].title { all[i].titleKo = titles[i] }
        await addEnglishTitles(&all)
        Magazine.shared.ingest(applyKeywords(all).sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) })
        Magazine.shared.publishDue()
        state.magazineBackfilled = true
        Store.save(state)
        NSLog("[매거진] 첫 호를 %d건으로 채웠습니다", all.count)
    }

    // 한국어 제목 기사에 영어 제목을 붙인다(외국 기사와 같은 소식인지 비교하려고)
    private func addEnglishTitles(_ items: inout [NewsItem]) async {
        let idx = items.indices.filter { !Translator.looksForeign(items[$0].title) && items[$0].titleEn == nil }
        guard !idx.isEmpty else { return }
        let en = await Translator.shared.toEnglish(idx.map { items[$0].title })
        for (k, i) in idx.enumerated() { items[i].titleEn = en[k] }
    }

    // 매거진에서 연 기사(읽기 창은 부르는 쪽이 연다)
    func markOpened(_ item: NewsItem) {
        guard item.id != Self.previewID else { return }
        setRead(item, true)
        noteInterest(item)
    }

    // MARK: 관심사: 연 기사의 분야·출처를 세어 지면 순서와 점수에 반영
    private func noteInterest(_ item: NewsItem) {
        state.interestCategory[item.category.rawValue, default: 0] += 1
        state.interestSource[item.sourceId, default: 0] += 1
        Store.save(state)
    }

    // 0 ~ 1.5 사이. 많이 본 분야·출처일수록 크다
    func interestWeight(category: NewsCategory, source: String?) -> Double {
        let cats = state.interestCategory, srcs = state.interestSource
        let cmax = max(cats.values.max() ?? 0, 1), smax = max(srcs.values.max() ?? 0, 1)
        let c = log(1 + (cats[category.rawValue] ?? 0)) / log(1 + cmax)
        let s = source.map { log(1 + (srcs[$0] ?? 0)) / log(1 + smax) } ?? 0
        return 1.0 * c + 0.5 * s
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
        if Calendar.current.component(.minute, from: Date()) % 30 == 0 { Magazine.shared.publishDue() } // 지난 호 발행
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
        if isSaved(item) { state.saved.removeAll { $0.key == item.key } } else {
            state.saved.insert(item, at: 0)
            Task { await ArticleService.shared.prepare(item) } // 오프라인으로 읽을 수 있게 번역까지 보관
        }
        Store.save(state)
    }

    // MARK: 구독 채널
    func notifies(_ sourceId: String) -> Bool {
        state.notify[sourceId] ?? allSources.first { $0.id == sourceId }?.notifyDefault ?? true
    }

    func setNotify(_ sourceId: String, _ on: Bool) {
        state.notify[sourceId] = on
        Store.save(state)
    }

    func isSubscribed(_ src: Source) -> Bool { state.customSources.contains { $0.id == src.id || $0.url == src.url } }

    // 추천 목록에서 구독
    func subscribe(_ src: Source) async -> String? {
        guard !isSubscribed(src) else { return nil }
        return await add(src)
    }

    // 아무 주소나: 알맞은 피드를 찾아 구독
    func addChannel(_ input: String, name: String = "") async -> String? {
        do {
            let f = try await ChannelResolver.resolve(input)
            guard !allSources.contains(where: { $0.url == f.feedURL }) else { return "이미 구독 중인 채널입니다" }
            let palette = ["#6E56CF", "#0090FF", "#E5484D", "#30A46C", "#F76B15", "#D6409F", "#12A594"]
            let id = "custom-" + String(f.feedURL.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) } & 0x7fffffff, radix: 36)
            let src = Source(id: id, name: name.trimmingCharacters(in: .whitespaces).nonEmpty ?? f.name, tier: "press", type: "feed",
                             url: f.feedURL, match: nil, aiOnly: false, defaultOn: true,
                             color: f.kind == .video ? "#FF0033" : palette[state.customSources.count % palette.count],
                             kind: f.kind.rawValue, notifyDefault: f.notifyDefault, group: "직접 추가", home: f.home)
            return await add(src)
        } catch {
            return error.localizedDescription
        }
    }

    // 실제로 받아 읽어 보고, 되면 추가한다. 실패하면 이유를 돌려준다.
    private func add(_ src: Source) async -> String? {
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
        state.notify.removeValue(forKey: id)
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

    // 같은 소식인가: 낱말이 많이 겹치거나, 영어 제목의 '뜻'이 가깝거나(기기 내 문장 임베딩),
    // 뜻이 꽤 가깝고 고유명사(Meta·Trump 등)를 함께 쓰면 같다고 본다. 한국어 기사는 영어 제목(titleEn)으로 비교.
    static func same(_ a: NewsItem, _ b: NewsItem) -> Bool {
        guard a.sourceId != b.sourceId else { return false } // 한 곳이 같은 소식을 두 번 내는 일은 드물다
        if similar(tokens(a.title), tokens(b.title)) { return true }
        if similar(tokens(a.titleKo ?? a.title), tokens(b.titleKo ?? b.title)) { return true }
        let ea = a.titleEn ?? (Translator.looksForeign(a.title) ? a.title : nil)
        let eb = b.titleEn ?? (Translator.looksForeign(b.title) ? b.title : nil)
        guard let ea, let eb, let d = meaningDistance(ea, eb) else { return false }
        if d < 0.88 { return true } // 뜻만으로 같다고 볼 때는 엄격하게
        return d < 1.07 && !entities(ea).isDisjoint(with: entities(eb))
    }

    // 문장 임베딩은 동시에 부르면 안전하지 않아 자물쇠로 한 번에 하나씩
    nonisolated(unsafe) private static let embedding = NLEmbedding.sentenceEmbedding(for: .english)
    private static let embeddingLock = NSLock()
    static func meaningDistance(_ a: String, _ b: String) -> Double? {
        embeddingLock.lock(); defer { embeddingLock.unlock() }
        guard let e = embedding else { return nil }
        let d = e.distance(between: a, and: b)
        return d.isFinite ? d : nil
    }

    // 대문자로 시작하는 고유명사(문장 첫 낱말·흔한 말 제외)
    static func entities(_ s: String) -> Set<String> {
        let common: Set<String> = ["The", "A", "An", "AI", "New", "How", "Why", "What", "Its", "It", "This", "That", "In", "On", "For", "With", "And", "Is", "Are", "To", "Of", "By", "Use"]
        let words = s.components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted).filter { !$0.isEmpty }
        return Set(words.dropFirst().filter { $0.count >= 3 && $0.first!.isUppercase && !common.contains($0) }.map { $0.lowercased() })
            .union(words.first.map { w in w.count >= 3 && w.first!.isUppercase && !common.contains(w) ? [w.lowercased()] : [] } ?? [])
    }

    static func similar(_ a: Set<String>, _ b: Set<String>) -> Bool {
        guard a.count >= 3, b.count >= 3 else { return false }
        let inter = a.intersection(b).count
        return Double(inter) / Double(min(a.count, b.count)) >= 0.6 && inter >= 3
    }
}
