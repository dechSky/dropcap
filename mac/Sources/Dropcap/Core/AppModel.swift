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
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in Store.flush() } // 잠들기 전 바로 저장
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                await AppModel.shared.checkAll()
            }
        }
        let snapshot = state
        Task { await Magazine.shared.migrateIfNeeded(from: snapshot) }
        Task { try? await Task.sleep(for: .seconds(2)); await Magazine.shared.reclusterIfNeeded() }
        if !state.magazineBackfilled { Task { await backfillMagazine() } }
        restartLoop()
        // 1분마다: 아침 브리핑 시각인지, 잠시 끄기가 끝났는지
        let t = Timer(timeInterval: 60, repeats: true) { _ in MainActor.assumeIsolated { AppModel.shared.minuteTick() } }
        RunLoop.main.add(t, forMode: .common)
        minuteTimer = t
        HotKey.register(key: .n) { AppModel.shared.openLatestUnread() } // ⌥⌘N
        HotKey.register(key: .m) { MagazineController.open() }          // ⌥⌘M
        // 시험 폴더로 띄운 시험 실행은 사용자 화면에 환영 알림을 띄우지 않는다(DROPCAP_TEST_WELCOME 으로만 확인)
        let env = ProcessInfo.processInfo.environment
        if firstRun, env["DROPCAP_DATA_DIR"] == nil || env["DROPCAP_TEST_WELCOME"] != nil {
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
                try? await Task.sleep(for: .seconds(Double(min(max(minutes, 1), 24 * 60)) * 60))
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
        found = found.filter { !state.hiddenSources.contains($0.sourceId) } // 숨긴 출처는 스토리 대표로도 다시 나오지 않게 처음부터 뺀다
        await addEnglishTitles(&found)
        await Magazine.shared.ingest(found) // 매거진에는 묶이기 전 전부(여러 시각 비교용)
        notifyGrownStories()
        // 알림을 끈 채널(논문·커뮤니티 등 양 많은 곳)은 매거진에만 싣고, 목록·알림에는 넣지 않는다
        let candidates = found.filter { notifies($0.sourceId) }
        let listed = await groupSameStory(candidates)
        let info = await Magazine.shared.storyInfo(candidates) // 스토리·보도 수를 한 번에(화면 줄기 밖)
        state.recent = Array((listed + state.recent).prefix(recentLimit))
        state.unread += listed.count
        state.unreadKeys = Array((state.unreadKeys + listed.map(\.key)).suffix(recentLimit))
        state.lastCheck = Date()
        state.seen = Store.pruned(state.seen) // 저장 파일만이 아니라 메모리의 기억도 정리(오래 켜 두면 끝없이 커지고 저장마다 정렬하던 문제)
        // 분야 정책: 즉시 알릴 것 · 묶음으로 고일 것 · 매거진에만 둘 것
        let quiet = isHushed && !manual // 방해 금지 시간·잠시 끄기·회의 중: 알리지 않고 안 읽은 소식으로만 쌓는다
        let drops = decide(candidates, listed: listed, info: info, quiet: quiet)
        Store.save(state)
        await Magazine.shared.publishDue() // 확인을 마친 뒤에 지난 호를 엮어 빠지는 기사가 없게
        if quiet { return }
        if manual, drops.isEmpty, !listed.isEmpty {
            ToastCenter.shared.showInfo("새 소식 \(listed.count)건", sub: "알릴 만큼 큰 소식은 없어 목록·매거진에만 실었어요")
            return
        }
        // 중요 표시가 붙은 소식을 먼저
        deliver(drops.sorted { ($0.important == true ? 0 : 1) < ($1.important == true ? 0 : 1) }, manual: manual)
    }

    // MARK: 분야별 알림
    var needsOnboarding: Bool { state.sectionsChosen == nil }
    var chosenSections: [String] { state.sectionsChosen ?? [] }
    func policy(_ section: String) -> SectionPolicy { state.sectionPolicy[section] ?? SectionPolicy() }
    func setPolicy(_ section: String, _ change: (inout SectionPolicy) -> Void) {
        var p = policy(section)
        let wasInstant = p.mode == .instant
        change(&p)
        if p.mode == .instant, !wasInstant { p.less = false } // 설정에서 즉시로 되돌리면 '덜 받기'도 풂
        state.sectionPolicy[section] = p
        Store.save(state)
    }

    // 알림을 정할 때 쓰는 분야: 고른 분야에 걸린 칩이 있으면 그것, 없으면 대표 분야
    func notifySection(_ it: NewsItem) -> String { Self.notifySection(it, chosen: chosenSections) }
    nonisolated static func notifySection(_ it: NewsItem, chosen: [String]) -> String {
        it.sectionChips.first { chosen.contains($0) } ?? it.section
    }

    private func sentToday(_ section: String?, now: Date = Date()) -> Int {
        let cal = Calendar.current
        return state.notifyLog.filter { cal.isDate($0.at, inSameDayAs: now) && (section == nil || $0.section == section) }.count
    }

    // 이번에 들어온 소식마다(같은 이야기는 하나로) 알림·고임·매거진만을 정한다. 떨어뜨릴 소식을 돌려준다.
    private func decide(_ items: [NewsItem], listed: [NewsItem], info: [String: (story: String?, coverage: Coverage)], quiet: Bool) -> [NewsItem] {
        let now = Date()
        let cal = Calendar.current
        state.notifyLog.removeAll { !cal.isDate($0.at, inSameDayAs: now) }
        state.notifiedStories = state.notifiedStories.filter { now.timeIntervalSince1970 - $0.value < 36 * 3600 }
        state.pending.removeAll { now.timeIntervalSince($0.at) > 36 * 3600 }
        guard !items.isEmpty, state.sectionsChosen != nil else { return [] }
        let chosen = Set(chosenSections), limits = state.settings.limits
        let rank = ["lab": 0, "press": 1, "kr": 2]
        // 같은 이야기끼리 모아 대표 하나(공식 발표 > 언론 > 국내, 그다음 최신)
        var order: [String] = [], groups: [String: [NewsItem]] = [:]
        for it in items {
            let story = info[it.key]?.story ?? "item:" + it.key
            if groups[story] == nil { order.append(story) }
            groups[story, default: []].append(it)
        }
        var drops: [NewsItem] = []
        for story in order {
            guard state.notifiedStories[story] == nil, let g = groups[story],
                  let rep = g.min(by: { (rank[$0.tier] ?? 3, $1.date ?? .distantPast) < (rank[$1.tier] ?? 3, $0.date ?? .distantPast) }) else { continue }
            let sec = notifySection(rep)
            let cov = info[rep.key]?.coverage ?? Coverage(kr: rep.tier == "kr" ? 1 : 0, intl: rep.tier == "kr" ? 0 : 1)
            let input = NotifyPolicy.Input(chosen: chosen.contains(sec), policy: policy(sec), coverage: cov,
                                           lab: g.contains { $0.tier == "lab" }, important: g.contains { $0.important == true },
                                           followed: state.followedStories.contains(story), watched: g.contains { $0.watch != nil },
                                           sentInSection: sentToday(sec, now: now), sentTotal: sentToday(nil, now: now))
            let top = chosen.contains(Sections.top)
                ? NotifyPolicy.Input(chosen: true, policy: policy(Sections.top), coverage: cov,
                                     sentInSection: sentToday(Sections.top, now: now), sentTotal: sentToday(nil, now: now)) : nil
            let (decision, viaTop) = NotifyPolicy.decideWithTop(input, top: top, limits: limits)
            switch decision {
            case .drop where !quiet:
                var shown = listed.first { $0.key == rep.key } ?? rep
                if shown.related == nil, g.count > 1 { shown.related = g.filter { $0.key != rep.key }.map(\.sourceName) }
                drops.append(shown)
                state.notifyLog.append(.init(section: viaTop ? Sections.top : sec, at: now))
                state.notifiedStories[story] = now.timeIntervalSince1970
                state.pending.removeAll { $0.story == story }
            case .pool, .drop: // 방해 금지 중에 떨어질 소식도 고였다가 다음 묶음으로
                if !state.pending.contains(where: { $0.story == story }) {
                    state.pending.append(.init(item: rep, section: sec, story: story, at: now))
                }
            case .quiet: break
            }
        }
        return drops
    }

    // 묶음: 분야마다 정한 시각이 지나면 고인 소식을 한 방울로("경제 7건")
    private func deliverBundles(now: Date = Date()) {
        guard !state.pending.isEmpty, !isHushed else { return }
        var changed = false
        for sec in Set(state.pending.map(\.section)).sorted(by: { Sections.order($0) < Sections.order($1) }) {
            guard NotifyPolicy.bundleDue(hour: policy(sec).bundleHour, now: now, last: state.lastBundle[sec]) else { continue }
            let items = state.pending.filter { $0.section == sec }.map(\.item)
            state.pending.removeAll { $0.section == sec }
            state.lastBundle[sec] = now
            changed = true
            switch state.settings.style {
            case .drop: ToastCenter.shared.showBundle(section: sec, items: items)
            case .system: SystemNotifier.postBundle(section: sec, items: items, sound: state.settings.sound)
            }
            if policy(sec).mode == .bundle { makeBrief(sec, items: items, now: now) }
        }
        if changed { Store.save(state) }
    }

    // 분야별 저녁 정리(N-26): '묶음' 분야는 묶음을 보낼 때 기기 안 요약 3줄 + 근거 기사를 매거진 그 분야 지면 위에 둔다.
    // 알림 문구는 그대로 원제목(D-7) — 요약은 지면 안에서만, 근거 링크와 함께.
    func makeBrief(_ sec: String, items: [NewsItem], now: Date = Date()) {
        let evidence = Array(items.prefix(SectionBrief.maxItems))
        state.briefs[sec] = SectionBrief(section: sec, at: now, items: evidence)
        guard Summarizer.available, evidence.count >= 2 else { return }
        Task {
            guard let lines = await Summarizer.briefing(section: Sections.name(sec), items: evidence),
                  state.briefs[sec]?.at == now else { return }
            setBriefLines(sec, lines)
        }
    }
    func setBriefLines(_ sec: String, _ lines: [SectionBrief.Line]) {
        state.briefs[sec]?.lines = lines
        Store.save(state)
    }

    // 오늘 만든 저녁 정리(요약이 있는 것만)
    func brief(_ sec: String, now: Date = Date()) -> SectionBrief? {
        guard let b = state.briefs[sec], b.lines != nil, Calendar.current.isDate(b.at, inSameDayAs: now) else { return nil }
        return b
    }

    // 처음 실행: 관심 분야를 고른다(설정에서 다시 고를 수도 있다). 고른 분야의 기본 출처를 켜고 그 분야 최근 소식으로 매거진을 채운다.
    func chooseSections(_ ids: [String]) {
        let before = Set(state.sectionsChosen ?? [])
        let first = state.sectionsChosen == nil
        let ordered = ids.sorted { Sections.order($0) < Sections.order($1) }
        state.sectionsChosen = ordered
        let defaults = NotifyPolicy.defaults(for: ordered)
        for id in ordered where state.sectionPolicy[id] == nil { state.sectionPolicy[id] = defaults[id] }
        var turnedOn: [String] = []
        for (id, m) in Sections.meta {
            guard let sec = m.section else { continue }
            let now = ordered.contains(sec)
            if now, first || !before.contains(sec), m.defaultOn == true {
                if state.enabled[id] != true { turnedOn.append(id) }
                state.enabled[id] = true
            } else if !now, first || before.contains(sec) {
                state.enabled[id] = false
            }
        }
        state.pending.removeAll { !ordered.contains($0.section) }
        subscriptionsChanged() // 뺀 분야의 출처 글은 바로 안 보이게
        if !turnedOn.isEmpty { Task { await backfillMagazine(only: Set(turnedOn)) } }
    }

    // 출처 수(켜짐/전체)
    func sourceCount(_ section: String) -> (on: Int, all: Int) {
        let ids = Sections.meta.values.filter { $0.section == section }.map(\.id)
        return (ids.filter { state.enabled[$0] == true }.count, ids.count)
    }

    // MARK: 보여 줄 출처(SourceFilter 한 곳)
    var sourceFilter: SourceFilter { SourceFilter.make(state: state, sources: allSources) }
    /// 상단바 목록·안 읽음·위젯·단축어가 쓰는 최근 소식(꺼진·해지한·숨긴 출처 글은 빠짐, 지우지는 않음)
    var visibleRecent: [NewsItem] {
        Self.visible(state.recent, filter: sourceFilter, mute: state.settings.muteKeywords)
    }
    // '알리지 않음' 낱말도 지우지 않고 거르기만(낱말을 지우면 돌아옴)
    nonisolated static func visible(_ items: [NewsItem], filter: SourceFilter, mute: [String]) -> [NewsItem] {
        let m = words(mute)
        return filter.visible(items).filter { it in !m.contains { text(it).contains($0) } }
    }
    // 안 읽음 수: 어떤 소식이 들었는지 알면(unreadKeys) 지금 보이는 것만 세고, 모르면(예전 파일) 줄이기만
    nonisolated static func recountUnread(unread: Int, keys: [String], visibleUnread: [NewsItem]) -> Int {
        guard !keys.isEmpty else { return min(unread, visibleUnread.count) }
        let counted = Set(keys)
        return visibleUnread.filter { counted.contains($0.key) }.count
    }

    // 구독(출처 켜기·끄기·해지·분야)이 바뀐 뒤: 알림 대기열에서 빠진 출처 글을 빼고, 안 읽음 수를 맞추고, 열린 화면을 바로 갱신
    private func subscriptionsChanged() {
        let f = sourceFilter
        state.pending.removeAll { !f.shows($0.item.sourceId) }
        state.unread = Self.recountUnread(unread: state.unread, keys: state.unreadKeys, visibleUnread: visibleRecent.filter { !isRead($0) }) // 끄면 줄고 다시 켜면 돌아옴
        Store.save(state)
        objectWillChange.send()
        Magazine.shared.refresh()
    }

    // MARK: 카드에서 바로 줄이기
    // 지우지 않고 거르기만(SourceFilter): 숨김을 풀면 목록에 그대로 돌아온다
    func hideSource(_ id: String) {
        guard !state.hiddenSources.contains(id) else { return }
        state.hiddenSources.append(id)
        subscriptionsChanged() // 대기열에서 빼고·안 읽음 맞추고·화면 갱신
    }
    func unhideSource(_ id: String) {
        state.hiddenSources.removeAll { $0 == id }
        subscriptionsChanged()
    }
    func lessOf(_ section: String) {
        setPolicy(section) { if $0.mode == .instant { $0.mode = .bundle } else { $0.mode = .magazine }; $0.less = true }
        let p = policy(section)
        ToastCenter.shared.showInfo(p.mode == .bundle ? "이 분야는 저녁 묶음으로 모아 드릴게요" : "이 분야는 매거진에만 실을게요",
                                    sub: "\(Sections.name(section)) · 설정 › 분야에서 되돌리기")
    }
    func muteWord(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return }
        update { if !$0.muteKeywords.contains(w) { $0.muteKeywords.append(w) } }
        state.pending.removeAll { "\($0.item.title) \($0.item.titleKo ?? "")".lowercased().contains(w.lowercased()) }
    }
    // 낱말 고르기 메뉴에 보일 제목 낱말
    static func titleWords(_ it: NewsItem) -> [String] {
        let text = [it.titleKo, it.title].compactMap { $0 }.joined(separator: " ")
        let parts = text.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
        var out: [String] = []
        let stop: Set<String> = ["the", "and", "for", "with", "from", "that", "this", "into", "over", "after", "about", "new", "says", "its", "how", "why", "what"]
        for p in parts where p.count >= 2 && !out.contains(p) && !stop.contains(p.lowercased()) && !p.allSatisfy(\.isNumber) { out.append(p) }
        return Array(out.prefix(12))
    }

    // MARK: 거르기·묶기
    var allSources: [Source] { Resources.config.sources + state.customSources }

    nonisolated static func words(_ list: [String]) -> [String] {
        list.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    // '알리지 않음' 낱말이 든 소식은 빼고, '꼭 알림' 낱말이 든 소식은 중요 표시
    // 이미 받은 목록에 낱말을 다시 적용: ★ 는 다시 매기고, '알리지 않음'은 지우지 않고 visibleRecent 가 거른다(낱말을 지우면 돌아옴)
    func reapplyKeywords() {
        let must = Self.words(state.settings.mustKeywords)
        let watch = WatchWords.normalized(state.settings.watchKeywords)
        state.recent = state.recent.map { var it = $0
            it.important = must.contains { Self.text(it).contains($0) } ? true : nil
            it.watch = watch.isEmpty ? nil : WatchWords.match(it, words: watch)
            return it }
        subscriptionsChanged()
    }
    nonisolated static func text(_ it: NewsItem) -> String { "\(it.title) \(it.titleKo ?? "") \(it.summary)".lowercased() }

    private func applyKeywords(_ items: [NewsItem]) -> [NewsItem] {
        let mute = Self.words(state.settings.muteKeywords), must = Self.words(state.settings.mustKeywords)
        let watch = WatchWords.normalized(state.settings.watchKeywords)
        return items.compactMap { it in
            let text = Self.text(it)
            if mute.contains(where: { text.contains($0) }) { return nil }
            var it = it
            if must.contains(where: { text.contains($0) }) { it.important = true }
            if !watch.isEmpty { it.watch = WatchWords.match(it, words: watch) }
            return it
        }
    }

    // 여러 곳이 같은 소식을 다루면 하나만 알리고 "다른 N곳도 보도"로 묶는다.
    // 공식 발표 > 언론 > 국내 순으로 대표를 고른다.
    func groupForProbe(_ items: [NewsItem]) async -> [NewsItem] { await groupSameStory(items) } // 성능 측정용

    // 같은 소식 묶기(R-4: StoryGrouper 한 곳). 문장 임베딩 비교는 화면 줄기 밖에서 하고, 최근 목록에 붙일 출처만 돌아와 반영
    private func groupSameStory(_ items: [NewsItem]) async -> [NewsItem] {
        guard !items.isEmpty else { return [] }
        let recent = state.recent
        let (kept, adds) = await Task.detached(priority: .userInitiated) { StoryGrouper.groupForList(items, recent: recent) }.value
        for (j, names) in adds where j < state.recent.count && state.recent[j].key == recent[j].key {
            for n in names where !(state.recent[j].related ?? []).contains(n) { state.recent[j].related = (state.recent[j].related ?? []) + [n] }
        }
        return kept
    }

    var isQuietTime: Bool {
        let st = state.settings
        guard st.quietEnabled, st.quietStart != st.quietEnd else { return false }
        return Self.inQuiet(hour: Calendar.current.component(.hour, from: Date()), start: st.quietStart, end: st.quietEnd)
    }

    // 회의·발표 중 자동 조용히(N-25): 지금 그 이유(설정에서 켠 것만)
    var autoQuietReason: FocusReason? { FocusMonitor.shared.reason(state.settings) }
    // 알리지 않을 때: 방해 금지 시간 · 잠시 끄기 · 회의·발표 중
    var isHushed: Bool { isQuietTime || isSnoozed || autoQuietReason != nil }

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
    func open(_ item: NewsItem, sequence: [NewsItem] = []) {
        guard item.id != Self.previewID else { return }
        markRead()
        setRead(item, true)
        noteInterest(item)
        ReaderController.open(item, sequence: sequence)
    }

    // 처음 한 번: 켜진 출처에서 최근 3일 기사를 받아 매거진 첫 호를 채운다(알림 없음)
    private func backfillMagazine(only: Set<String>? = nil) async {
        Magazine.shared.preparing = true
        defer { Magazine.shared.preparing = false }
        let cutoff = Date().addingTimeInterval(-3 * 24 * 3600)
        var all: [NewsItem] = []
        for src in allSources where state.enabled[src.id] == true && (only?.contains(src.id) ?? true) {
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
        await Magazine.shared.ingest(applyKeywords(all).sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) })
        await Magazine.shared.publishDue()
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

    // MARK: 스토리 팔로우
    func isFollowing(_ story: String) -> Bool { state.followedStories.contains(story) }
    func setFollowing(_ story: String, _ on: Bool, size: Int) {
        state.followedStories.removeAll { $0 == story }
        if on { state.followedStories.append(story) }
        state.storySeen[story] = size
        Store.save(state)
    }
    func markStorySeen(_ story: String, size: Int) {
        guard state.storySeen[story] != size else { return }
        state.storySeen[story] = size
        Store.save(state)
    }
    func unseenReports(_ c: Database.Cluster) -> Int { max(0, c.size - (state.storySeen[c.id] ?? c.size)) }

    // 팔로우한 스토리에 새 보도가 붙으면 알림(그 출처의 알림을 꺼 두었어도)
    private func notifyGrownStories() {
        let grown = Magazine.shared.grown
        Magazine.shared.grown = []
        guard !grown.isEmpty, !isHushed else { return }
        for (c, it) in grown.prefix(2) {
            ToastCenter.shared.showInfo("팔로우한 스토리에 새 보도 · \(it.sourceName)", sub: c.title)
        }
    }

    // MARK: 관심사: 연 기사의 분야·출처를 세어 지면 순서와 점수에 반영
    private func noteInterest(_ item: NewsItem) {
        state.interestCategory[item.category.rawValue, default: 0] += 1
        state.interestSource[item.sourceId, default: 0] += 1
        Store.save(state)
    }

    // 0 ~ 1.5 사이. 많이 본 분야·출처일수록 크다
    func interestWeight(category: NewsCategory, source: String?) -> Double {
        Self.interestWeight(category: category, source: source, cats: state.interestCategory, srcs: state.interestSource)
    }
    nonisolated static func interestWeight(category: NewsCategory, source: String?, cats: [String: Double], srcs: [String: Double]) -> Double {
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
        if Calendar.current.component(.minute, from: Date()) % 30 == 0 { Task { await Magazine.shared.publishDue() } } // 지난 호 발행
        deliverBundles()
        deliverWatchDigest()
        let st = state.settings
        guard st.digestEnabled else { return }
        let cal = Calendar.current
        let now = Date()
        guard Self.digestWindow(hour: cal.component(.hour, from: now), digestHour: st.digestHour),
              !(state.lastDigest.map { cal.isDate($0, inSameDayAs: now) } ?? false) else { return }
        guard !isHushed else { return } // 조용한 때가 끝나면 그날 안에 다시 시도
        state.lastDigest = now
        Store.save(state)
        let items = digestItems
        guard !items.isEmpty else { return }
        ToastCenter.shared.showDigest(count: items.count)
    }

    // 지켜볼 낱말 하루 정리: 아침 브리핑 시각(브리핑을 꺼도 그 시각)에 지난 24시간 동안 낱말마다 걸린 소식 수.
    // 조용한 때면 끝난 뒤 그날 안에 다시 시도. 정리 물방울은 세 개까지(낱말 순서)
    private func deliverWatchDigest(now: Date = Date()) {
        let words = WatchWords.normalized(state.settings.watchKeywords)
        let cal = Calendar.current
        guard !words.isEmpty, Self.digestWindow(hour: cal.component(.hour, from: now), digestHour: state.settings.digestHour),
              !(state.lastWatchDigest.map { cal.isDate($0, inSameDayAs: now) } ?? false), !isHushed else { return }
        state.lastWatchDigest = now
        Store.save(state)
        Task {
            let hidden = Set(state.hiddenSources)
            let recent = await Magazine.shared.recentItems(since: now.addingTimeInterval(-24 * 3600)).filter { !hidden.contains($0.sourceId) }
            for d in WatchWords.digest(recent, words: words).prefix(3) {
                switch state.settings.style {
                case .drop: ToastCenter.shared.showWatch(word: d.word, items: d.items)
                case .system: SystemNotifier.postWatch(word: d.word, items: d.items, sound: state.settings.sound)
                }
            }
        }
    }

    // 아침 브리핑을 보낼 수 있는 때: 정한 시각부터 정오 전까지(정오 이후 시각을 골랐으면 그 한 시간). 밤에 처음 켜도 '아침 브리핑'이 뜨지 않게(A-20)
    nonisolated static func digestWindow(hour h: Int, digestHour: Int) -> Bool { h >= digestHour && h < max(12, digestHour + 1) }

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
        state.unreadKeys = []
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
    @Published private(set) var subscribing: Set<String> = []

    private func add(_ src: Source) async -> String? {
        guard !subscribing.contains(src.url) else { return nil }
        subscribing.insert(src.url)
        defer { subscribing.remove(src.url) }
        do {
            // 해지 뒤 다시 구독할 때 남은 ETag 로 304 를 받지 않게 조건 없이 받는다
            guard let items = try await FeedService.shared.items(for: src, conditional: false), !items.isEmpty else { return "글을 찾지 못했습니다" }
            guard !allSources.contains(where: { $0.id == src.id || $0.url == src.url }) else { return "이미 구독 중인 채널입니다" }
            // 지금 있는 글은 이 자리에서 기억해 두고(알리지 않음), 이후에 올라오는 글부터 알린다
            let now = Date().timeIntervalSince1970
            for it in items { state.seen[it.key] = now }
            state.seeded.append(src.id)
            state.customSources.append(src)
            state.enabled[src.id] = true
            subscriptionsChanged() // 같은 주소로 다시 구독하면 남아 있던 글·안 읽음이 그대로 돌아옴
            // 최근 3일 글은 매거진에 바로 싣는다(알림 없이) — 구독하자마자 지면에서 볼 수 있게
            let cutoff = Date().addingTimeInterval(-3 * 24 * 3600)
            var recent = Array(items.filter { ($0.date ?? .distantPast) > cutoff }.prefix(src.notifyDefault == false ? 30 : 15))
            if !recent.isEmpty {
                let titles = await Translator.shared.translateMany(recent.map(\.title))
                for i in recent.indices where titles[i] != recent[i].title { recent[i].titleKo = titles[i] }
                await Magazine.shared.ingest(recent.reversed())
            }
        } catch {
            return "읽지 못했습니다: \(error.localizedDescription)"
        }
        return nil
    }

    func removeCustomSource(_ id: String) {
        state.customSources.removeAll { $0.id == id }
        state.enabled.removeValue(forKey: id)
        state.notify.removeValue(forKey: id)
        state.seeded.removeAll { $0 == id }
        subscriptionsChanged()
    }

    func markRead() {
        guard state.unread != 0 else { return }
        state.unread = 0
        state.unreadKeys = []
        Store.save(state)
    }

    func setEnabled(_ id: String, _ on: Bool) {
        state.enabled[id] = on
        subscriptionsChanged() // 끄면 그 출처 글이 목록·매거진에서 바로 빠지고, 다시 켜면 돌아옴
        if on { Task { await checkAll() } }
    }

    // 기록 가져오기·되돌리기(Backup)에서만: 상태 여러 항목을 한 번에 바꾼다
    func replaceState(_ change: (AppState) -> AppState) {
        let before = state.settings
        state = change(state)
        Store.save(state)
        FocusMonitor.shared.invalidate()
        if state.settings.intervalMinutes != before.intervalMinutes { restartLoop() }
        Magazine.shared.refresh()
        objectWillChange.send()
    }

    func update(_ change: (inout AppState.Settings) -> Void) {
        let before = state.settings
        change(&state.settings)
        Store.save(state)
        if state.settings != before { FocusMonitor.shared.invalidate() }
        if state.settings.style == .system, before.style != .system { SystemNotifier.requestAuthorization() }
        if state.settings.intervalMinutes != before.intervalMinutes { restartLoop() }
    }

    // 견본 카드. 실제 기사를 다시 띄우면 같은 소식이 또 온 것처럼 보이므로 쓰지 않는다
    static let previewID = "preview"

    func preview() {
        let item = NewsItem(
            id: Self.previewID, title: "This is how new stories will drop in", titleKo: "새 소식은 이렇게 떨어집니다",
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

    static func postBundle(section: String, items: [NewsItem], sound: Bool) {
        guard available, !items.isEmpty else { return }
        let c = UNMutableNotificationContent()
        c.title = "\(Sections.name(section)) \(items.count)건"
        c.body = items.prefix(3).map(\.displayTitle).joined(separator: "\n")
        c.userInfo = ["section": section]
        if sound { c.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "bundle-\(section)-\(Int(Date().timeIntervalSince1970))", content: c, trigger: nil))
    }

    static func postWatch(word: String, items: [NewsItem], sound: Bool) {
        guard available, !items.isEmpty else { return }
        let c = UNMutableNotificationContent()
        c.title = "오늘 \(word) 소식 \(items.count)건"
        c.body = items.prefix(2).map(\.displayTitle).joined(separator: "\n")
        c.userInfo = ["search": word]
        if sound { c.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "watch-\(word)-\(Int(Date().timeIntervalSince1970))", content: c, trigger: nil))
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
            c.title = "새 소식 \(items.count - 3)건 더"
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
    static func same(_ a: NewsItem, _ b: NewsItem) -> Bool { StoryGrouper.same(StoryKey(a), StoryKey(b)) }

    // 문장 임베딩은 동시에 부르면 안전하지 않아 자물쇠로 한 번에 하나씩
    nonisolated(unsafe) private static let embedding = NLEmbedding.sentenceEmbedding(for: .english)
    private static let embeddingLock = NSLock()
    // 제목마다 뜻 벡터를 한 번만 계산해 기억한다(쌍마다 다시 계산하면 기사 수의 제곱만큼 느려져 화면이 멈췄다)
    nonisolated(unsafe) private static var vectors: [String: [Double]] = [:]
    static func meaningDistance(_ a: String, _ b: String) -> Double? {
        embeddingLock.lock(); defer { embeddingLock.unlock() }
        guard let va = vector(a), let vb = vector(b), va.count == vb.count else { return nil }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in va.indices { dot += va[i] * vb[i]; na += va[i] * va[i]; nb += vb[i] * vb[i] }
        guard na > 0, nb > 0 else { return nil }
        let d = (2 * max(0, 1 - dot / (na.squareRoot() * nb.squareRoot()))).squareRoot() // NLEmbedding.distance 와 같은 값(단위 벡터 사이 거리)
        return d.isFinite ? d : nil
    }
    private static func vector(_ s: String) -> [Double]? { // 자물쇠 안에서만 부른다
        if let v = vectors[s] { return v }
        guard let v = embedding?.vector(for: s) else { return nil }
        if vectors.count > 5000 { vectors.removeAll(keepingCapacity: true) }
        vectors[s] = v
        return v
    }
    // 시험용: 기억 없이 NLEmbedding 이 직접 잰 거리
    static func rawDistance(_ a: String, _ b: String) -> Double? {
        embeddingLock.lock(); defer { embeddingLock.unlock() }
        return embedding.map { $0.distance(between: a, and: b) }
    }

    // 고유명사: 영어 제목은 낱말마다 첫 글자를 대문자로 쓰는 일이 많아(Title Case) '대문자로 시작'만으로는 'Global' 같은
    // 흔한 말까지 잡혀 다른 소식이 묶였다. 그래서 ① 문장 분석기가 사람·조직·장소로 본 이름 ② NVIDIA·OpenAI·GPT-6 처럼
    // 대문자 약어·대소문자 섞임·숫자가 든 낱말 ③ Title Case 가 아닌 제목에서 문장 중간의 대문자 낱말만 고유명사로 본다.
    nonisolated(unsafe) private static var entityCache: [String: Set<String>] = [:]
    private static let entityLock = NSLock()
    static func entities(_ s: String) -> Set<String> {
        entityLock.lock(); defer { entityLock.unlock() }
        if let e = entityCache[s] { return e }
        let e = findEntities(s)
        if entityCache.count > 5000 { entityCache.removeAll(keepingCapacity: true) }
        entityCache[s] = e
        return e
    }
    private static func findEntities(_ s: String) -> Set<String> {
        let common: Set<String> = ["ai", "si", "the", "a", "an", "new", "how", "why", "what", "its", "it", "this", "that", "in", "on", "for", "with", "and", "is", "are", "to", "of", "by", "use", "ceo", "us", "uk", "eu"]
        var out = Set<String>()
        let tagger = NLTagger(tagSchemes: [.nameType]); tagger.string = s
        tagger.enumerateTags(in: s.startIndex..<s.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, r in
            if let tag, [.personalName, .placeName, .organizationName].contains(tag) {
                for w in s[r].lowercased().split(separator: " ") where w.count >= 2 { out.insert(String(w)) }
            }
            return true
        }
        let words = s.components(separatedBy: CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "-")).inverted).filter { !$0.isEmpty }
        for w in words {
            let letters = w.filter(\.isLetter)
            let caps = letters.filter(\.isUppercase).count
            let acronym = letters.count >= 2 && caps == letters.count
            let mixed = caps >= 2 && caps < letters.count && w.first!.isUppercase || (w.first!.isLowercase && caps >= 1)
            let digits = w.contains(where: \.isNumber) && w.contains(where: \.isLetter)
            if acronym || mixed || digits { out.insert(w.lowercased()) }
        }
        let long = words.filter { $0.count >= 3 && $0.first!.isLetter }
        let titleCase = !long.isEmpty && Double(long.filter { $0.first!.isUppercase }.count) / Double(long.count) > 0.6
        if !titleCase {
            for w in words.dropFirst() where w.count >= 3 && w.first!.isUppercase { out.insert(w.lowercased()) }
        }
        return out.subtracting(common)
    }

    static func similar(_ a: Set<String>, _ b: Set<String>) -> Bool {
        guard a.count >= 3, b.count >= 3 else { return false }
        let inter = a.intersection(b).count
        return Double(inter) / Double(min(a.count, b.count)) >= 0.6 && inter >= 3
    }
}
