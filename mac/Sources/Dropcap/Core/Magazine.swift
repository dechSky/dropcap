import Foundation
import SwiftUI

// 호(발행본): 표지 기사 하나 + 분야별 지면. 기사 자체는 DB 에 있고 여기엔 순서만 둔다.
struct Issue: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case daily, weekly }
    struct Section: Codable, Hashable {
        var category: NewsCategory
        var keys: [String]
        var kind: String? = nil   // 영상·논문 등 구독 채널 지면이면 그 종류
        var section: String? = nil // 일반 뉴스 분야 지면이면 그 분야 id(예전에 엮은 호에는 없음)

        var id: String { kind ?? section.map { "s-" + $0 } ?? category.rawValue }
        var label: String {
            if let k = kind.flatMap({ ItemKind(rawValue: $0) }) { return k.label }
            if let s = Sections.byID(section) { return s.name }
            return category == .other ? "그 밖의 소식" : category.label
        }
        var symbol: String { kind.flatMap { ItemKind(rawValue: $0)?.symbol } ?? Sections.byID(section)?.symbol ?? category.symbol }
        var color: Color {
            if kind == nil, let s = Sections.byID(section) { return s.tint }
            switch kind {
            case "video": return .red
            case "paper": return Color(hex: "#B31B1B")
            case "release": return .gray
            case "post": return .orange
            case "podcast": return .purple
            default: return category.color
            }
        }
    }
    var id: String          // daily-2026-10-13 · weekly-2026-W41
    var kind: Kind
    var date: Date          // 발행 시각
    var from: Date
    var to: Date
    var cover: String?      // 표지 기사 key
    var sections: [Section]
    var count: Int

    // 기사가 너무 적은 호(앱을 막 쓰기 시작한 주 등) — 목록에 '기록 적음'으로 표시
    var isThin: Bool { count < Magazine.thinIssue }

    var title: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        switch kind {
        case .daily:
            f.dateFormat = "M월 d일 EEEE"
            return "\(f.string(from: to.addingTimeInterval(-60))) 호"
        case .weekly:
            f.dateFormat = "M월 d일"
            return "주간 · \(f.string(from: from))–\(f.string(from: to.addingTimeInterval(-1)))"
        }
    }
}

// 매거진 편집국: 기사를 모으고(DB), 스토리로 묶고, 점수를 매겨 호를 엮는다.
@MainActor
final class Magazine: ObservableObject {
    static let shared = Magazine()
    private let db = Database.shared

    @Published private(set) var revision = 0   // 새 기사가 들어올 때마다 바뀜(화면 갱신용)
    @Published private(set) var imageRevision = 0 // 사진만 채워졌을 때(조용히 다시 그림)
    @Published private(set) var layoutRevision = 0 // 숨긴 출처·고른 분야가 바뀜(알림 띠 없이 바로 다시 엮음)
    @Published private(set) var archive: [Issue] = []
    @Published var preparing = false             // 첫 호를 엮는 중
    var grown: [(Database.Cluster, NewsItem)] = [] // 이번에 팔로우한 스토리에 붙은 새 보도(알림 뒤 비움)
    private var enriching = false
    private var enrichTried: Set<String> = [] // 이번 실행에서 이미 찾아본 기사(사진이 없던 곳을 확인마다 다시 받지 않게)

    private init() {
        archive = Self.archiveOrder(db.issues())
    }

    // MARK: 받아 넣기 — 무거운 일은 Editor(화면 줄기 밖)가 하고 여기선 결과만 반영한다
    private let editor = Editor.shared

    // 편집에 쓰는 앱 상태 사본
    var context: EditContext {
        let st = AppModel.shared.state
        return EditContext(hidden: Set(st.hiddenSources), filter: AppModel.shared.sourceFilter, chosen: st.sectionsChosen, limits: st.settings.limits,
                           interestCategory: st.interestCategory, interestSource: st.interestSource, followed: Set(st.followedStories))
    }

    // 처음 실행: 예전 기록(최근 소식·저장)을 옮겨 온다. 이미 있으면 건너뜀.
    func migrateIfNeeded(from state: AppState) async {
        guard db.itemCount == 0 else { return }
        let items = state.recent + state.saved
        guard !items.isEmpty else { return }
        await ingest(items.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) })
        await publishDue()
        NSLog("[매거진] 예전 기록 %d건을 옮겼습니다", items.count)
    }

    // 같은 소식 판정 기준이 바뀌면 최근 2주 스토리를 새 기준으로 다시 묶는다(한 번만)
    static let storyRuleVersion = 2
    func reclusterIfNeeded() async {
        let key = "storyRuleVersion"
        guard UserDefaults.standard.integer(forKey: key) < Self.storyRuleVersion else { return }
        UserDefaults.standard.set(Self.storyRuleVersion, forKey: key)
        let (n, multi) = await editor.recluster()
        NSLog("[스토리] 새 기준으로 %d건을 다시 묶음 → 여러 곳 스토리 %d개", n, multi)
        revision += 1
    }

    // 새로 들어온 기사 전부(같은 소식으로 묶여 알림에서 빠진 것도 포함)
    func ingest(_ items: [NewsItem]) async {
        guard !items.isEmpty else { return }
        grown += await editor.ingest(items, followed: context.followed)
        revision += 1
        enrichImages()
    }

    // 사진이 없는 최근 기사는 페이지에서 og:image 를 찾아 채운다(한 번에 12개, 공개 주소만)
    func enrichImages() {
        guard !enriching else { return }
        enriching = true
        if enrichTried.count > 5000 { enrichTried.removeAll() } // 오래 켜 둬도 끝없이 커지지 않게
        let tried = enrichTried
        Task {
            // 최근 기사 300건을 읽어 고르는 일도 화면 줄기 밖에서
            let todo = Self.toEnrich(await editor.recentItems(since: Date().addingTimeInterval(-3 * 24 * 3600), limit: 300), tried: tried)
            var changed = false
            for s in todo {
                enrichTried.insert(s.item.key)
                if let img = await FeedService.shared.ogImage(s.item.link) {
                    await editor.setImage(s.item.key, img)
                    changed = true
                }
            }
            enriching = false
            if changed { imageRevision += 1 }
            await scoreImages()
        }
    }

    // 최근 기사 사진의 점수를 미리 잰다(표지·분야 대표 사진 고르기). 한 번에 16장, 이미 잰 것은 건너뜀
    private var scoring = false
    func scoreImages() async {
        guard !scoring else { return }
        scoring = true
        defer { scoring = false }
        let recent = await editor.recentItems(since: Date().addingTimeInterval(-36 * 3600), limit: 400)
            .map(\.item).filter { $0.itemKind == .article && $0.image != nil && !ImageKey.isJunk($0.image) }
        let known = await editor.imageScores(recent.map { $0.image! })
        var changed = false
        for it in recent.filter({ known[$0.image!] == nil }).prefix(16) {
            guard let img = await ImageLoader.shared.image(it.image!), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let s = await PhotoQuality.scoreAsync(cg)
            await editor.saveImageScore(it.image!, s)
            if !PhotoQuality.good(s.total) { changed = true; NSLog("[사진 점수] 대표 사진에서 뺌 %.2f(글자 %.2f·색 %.2f·단색 %.2f) %@", s.total, s.textRatio, s.colorVariety, s.flatness, it.sourceName) }
        }
        if changed { imageRevision += 1 }
    }

    // 사진 없는 기사 중 아직 찾아보지 않은 것 12개. 이미 찾아본 것을 빼지 않으면 사진이 없는 최신 12건만
    // 확인마다(5분) 다시 받고, 그 뒤의 기사는 영영 사진을 찾지 못했다.
    nonisolated static func toEnrich(_ items: [Database.StoredItem], tried: Set<String>) -> [Database.StoredItem] {
        Array(items.filter { $0.item.image == nil && !$0.item.link.isEmpty && !tried.contains($0.item.key) }.prefix(12))
    }

    // 분야 지면: 주요 뉴스(국내 n곳·해외 n곳 넘게 보도된 소식) → 고른 분야 → 나머지 분야 → 그 밖의 소식.
    // 기사는 한 지면에만(고른 분야에 걸린 칩이 있으면 그 분야, 없으면 대표 분야).
    nonisolated static func sectionPages(_ articles: [Database.StoredItem], stored: [Database.StoredItem], chosen: [String]?,
                                         limits: PolicyLimits, perSection: Int,
                                         meta: [String: SourceMeta] = Sections.meta) -> [Issue.Section] {
        let picks = chosen ?? Sections.all.map(\.id)
        // 스토리마다 국내·해외 출처 수(이 호의 기간 안에서)
        var outlets: [String: [String: String]] = [:] // 스토리 → 출처 → 지역
        for s in stored { if let c = s.cluster { outlets[c, default: [:]][s.item.sourceId] = Sections.region(ofSource: s.item.sourceId, tier: s.item.tier, meta: meta) } }
        func coverage(_ s: Database.StoredItem) -> Coverage {
            let m = s.cluster.flatMap { outlets[$0] } ?? [s.item.sourceId: Sections.region(ofSource: s.item.sourceId, tier: s.item.tier, meta: meta)]
            return Coverage(kr: m.values.filter { $0 == "kr" }.count, intl: m.values.filter { $0 != "kr" }.count)
        }
        var used = Set<String>()
        var pages: [Issue.Section] = []
        if picks.contains(Sections.top) {
            let keys = articles.filter { NotifyPolicy.crosses(coverage($0), limits) }.map(\.item.key).prefix(8)
            if !keys.isEmpty { pages.append(.init(category: .other, keys: Array(keys), section: Sections.top)); used.formUnion(keys) }
        }
        var bySection: [String: [String]] = [:]
        for s in articles where !used.contains(s.item.key) {
            let p = Sections.place(s.item, meta: meta)
            let home = p.chips.first { picks.contains($0) } ?? p.primary
            bySection[home, default: []].append(s.item.key)
        }
        var leftovers: [String] = []
        let order = Sections.all.map(\.id).filter { $0 != Sections.top }
        for id in order.filter({ picks.contains($0) }) + order.filter({ !picks.contains($0) }) {
            guard let keys = bySection.removeValue(forKey: id) else { continue }
            // 고르지 않은 분야에서 한 건뿐이면 지면이 휑하므로 '그 밖의 소식'으로
            if keys.count >= 2 || picks.contains(id) { pages.append(.init(category: .other, keys: Array(keys.prefix(perSection)), section: id)) } else { leftovers += keys }
        }
        leftovers += bySection.values.flatMap { $0 }
        if !leftovers.isEmpty { pages.append(.init(category: .other, keys: Array(leftovers.prefix(perSection)))) }
        return pages
    }

    // 지금 진행 중인 오늘 호·이번 주 호(아직 발행 전) — 엮기·꺼내기는 화면 줄기 밖에서
    func today() async -> Resolved { let c = context; return await editor.resolve(await editor.liveDaily(c), filter: c.filter) }
    func week() async -> Resolved { let c = context; return await editor.resolve(await editor.liveWeekly(c), filter: c.filter) }
    // 분야 지면(왼쪽 목록의 분야): 오늘 호 기간의 그 분야 기사만으로 엮은 지면(표지·건수도 그 분야 기준)
    func section(_ id: String) async -> Resolved { let c = context; return await editor.resolve(await editor.liveSection(c, id), filter: c.filter) }
    func resolve(_ issue: Issue) async -> Resolved { await editor.resolve(issue, filter: context.filter) }

    // 지난 호 발행(확인마다·30분마다). 같은 목록이면 화면을 다시 그리지 않게 바뀔 때만 넣는다
    func publishDue() async {
        let list = Self.archiveOrder(await editor.publishDue(context))
        if list != archive { archive = list }
    }

    // MARK: 지면 규칙(왼쪽 목록과 오른쪽 화면이 같은 기준을 쓰게 — 시험 SidebarRuleTests)

    nonisolated static let thinIssue = 5

    // 지난 호 목록: 최신부터 호의 끝 시각 순(주간은 그 주 끝 — 토요일 호 바로 위). 예전에 저장한 호는 정렬 값이 발행 시각이라 뒤섞였다
    nonisolated static func archiveOrder(_ issues: [Issue]) -> [Issue] {
        issues.sorted { a, b in a.to != b.to ? a.to > b.to : (a.kind == .weekly) && b.kind != .weekly }
    }

    // 주간 범위: 달력 한 주(이번 주 진행 중 호와 지난 주간이 겹치지 않고 이어짐, 각 7일)
    nonisolated static func weekRange(containing d: Date, cal: Calendar = .current) -> (from: Date, to: Date) {
        let i = cal.dateInterval(of: .weekOfYear, for: d) ?? DateInterval(start: cal.startOfDay(for: d), duration: 7 * 24 * 3600)
        return (i.start, i.end)
    }

    // 머리 아래 숫자: 모은 소식 중 지면에 실은 수(표지 포함). 다 실었으면 한 숫자만
    nonisolated static func subtitle(total: Int, shown: Int, sections: Int, noun: String = "소식") -> String {
        let head = shown >= total ? "\(noun) \(total)건" : "\(noun) \(total)건 중 \(shown)건 실음"
        return sections > 0 ? head + " · 분야 \(sections)개" : head
    }

    // 분야 개편(유리 띠 분야 지면) 전에 엮은 호: 기사 지면에 분야 id 가 없고 예전 AI 분류(모델·제품…)로 나뉨 → 지금 규칙으로 다시 엮는다
    nonisolated static func needsRebuild(_ issue: Issue) -> Bool {
        issue.sections.contains { $0.kind == nil && $0.section == nil && $0.category != .other }
    }

    // 스토리의 분야: 묶인 보도들의 대표 분야 다수결(같으면 분야 순서 앞). AI 면 AI 안 하위 분류도 다수결
    nonisolated static func storyTopic(_ items: [NewsItem], place: (NewsItem) -> String = { Sections.place($0).primary }) -> (section: String, category: NewsCategory?)? {
        guard !items.isEmpty else { return nil }
        let secs = items.map(place)
        var votes: [String: Int] = [:]
        for s in secs { votes[s, default: 0] += 1 }
        let sec = votes.max { a, b in a.value != b.value ? a.value < b.value : Sections.order(a.key) > Sections.order(b.key) }!.key
        guard sec == Sections.ai else { return (sec, nil) }
        var cats: [NewsCategory: Int] = [:]
        for (it, s) in zip(items, secs) where s == Sections.ai { cats[it.category, default: 0] += 1 }
        let cat = cats.max { a, b in a.value != b.value ? a.value < b.value : a.key.sortOrder > b.key.sortOrder }?.key
        return (sec, cat)
    }

    // 최근 검색어: 맨 앞에 넣고 같은 것(대소문자 무시)은 하나로, 두 글자 이상, 8개까지
    nonisolated static func rememberSearch(_ q: String, in list: [String], max: Int = 8) -> [String] {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2 else { return list }
        return Array(([t] + list.filter { $0.lowercased() != t.lowercased() }).prefix(max))
    }

    nonisolated static func dayID(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }
    nonisolated static func weekID(_ d: Date) -> String {
        let c = Calendar(identifier: .iso8601)
        return String(format: "%04d-W%02d", c.component(.yearForWeekOfYear, from: d), c.component(.weekOfYear, from: d))
    }

    // MARK: 꺼내 보기
    // 한 호를 화면에 그릴 재료를 한 번에(지면마다 DB 를 다시 읽지 않게)
    struct Resolved {
        var issue: Issue
        var cover: Database.StoredItem?
        var sections: [(section: Issue.Section, items: [NewsItem])]
        var clusters: [String: String] = [:]   // key → 스토리(카드 메뉴에서 DB 를 다시 읽지 않게)
        var regions: [String: [NewsItem]] = [:] // 스토리 → 보도들(해외·국내가 섞인 스토리만, 카드의 '해외에서는·국내에서는' 줄)
    }

    func items(_ keys: [String], in issue: Issue) -> [NewsItem] {
        let all = db.items(from: issue.from.addingTimeInterval(-24 * 3600), to: issue.to.addingTimeInterval(24 * 3600), limit: 5000)
        let map = Dictionary(all.map { ($0.item.key, $0.item) }, uniquingKeysWith: { a, _ in a })
        return keys.compactMap { map[$0] }
    }

    func stored(_ key: String, near issue: Issue) -> Database.StoredItem? { db.items(keys: [key]).first }

    // 스토리의 보도들(꺼진·해지한·숨긴 출처 글은 빠짐)
    func storyItems(_ cluster: String) -> [NewsItem] { AppModel.shared.sourceFilter.visible(db.items(inCluster: cluster).map(\.item)) }
    // 스토리 목록: 최근 24시간 안에 보도가 붙은 것(지금 커지는 스토리)과 나머지. 큰 것·최근 것이 앞
    func storyGroups() -> (live: [Database.Cluster], past: [Database.Cluster]) {
        let g = Self.storyGroups(Self.stories(db: db, filter: AppModel.shared.sourceFilter, now: Date()), now: Date())
        return (g.live.map(\.cluster), g.past.map(\.cluster))
    }
    // 스토리 한눈에 요약(기기 안 모델) — 보도 수가 같으면 다시 만들지 않음
    private var digestCache: [String: (size: Int, lines: [String])] = [:]
    func storyDigest(_ c: Database.Cluster) async -> [String]? {
        if let d = digestCache[c.id], d.size == c.size { return d.lines }
        let items = storyItems(c.id)
        guard items.count >= 2 else { return nil }
        let paras = items.map { "[\($0.sourceName)] \($0.displayTitle). \($0.summary.prefix(400))" }
        guard let lines = await Summarizer.summarize(title: c.title, paragraphs: paras) else { return nil }
        digestCache[c.id] = (c.size, lines)
        return lines
    }
    func cluster(_ id: String) -> Database.Cluster? { db.cluster(id) }
    func clusterID(of key: String, near issue: Issue) -> String? { db.clusterOf(key) }
    func clusterID(of key: String) -> String? { db.clusterOf(key) }

    // 알림 판단용: 기사마다 스토리 id·국내/해외 보도 수(한 번에, 화면 줄기 밖에서)
    func storyInfo(_ items: [NewsItem]) async -> [String: (story: String?, coverage: Coverage)] {
        await editor.storyInfo(items, filter: context.filter)
    }

    // 스토리 보도를 해외·국내로 나눔(나란히 보기)
    nonisolated static func splitByRegion(_ items: [NewsItem], meta: [String: SourceMeta] = Sections.meta) -> (intl: [NewsItem], kr: [NewsItem]) {
        let kr = items.filter { Sections.region(ofSource: $0.sourceId, tier: $0.tier, meta: meta) == "kr" }
        return (items.filter { Sections.region(ofSource: $0.sourceId, tier: $0.tier, meta: meta) != "kr" }, kr)
    }

    // 숨긴 출처·고른 분야가 바뀌면 지면을 다시 그리게
    func refresh() { layoutRevision += 1 }

    // 스토리: 최근 2주 동안 두 곳 이상이 다룬 것
    func stories() -> [Database.Cluster] { Self.stories(db: db, filter: AppModel.shared.sourceFilter, now: Date()).map(\.cluster) }

    // 스토리 카드 하나: 스토리와 보이는 보도들(카드가 DB 를 다시 묻지 않게)
    struct StoryCard: Identifiable, Sendable {
        var cluster: Database.Cluster
        var items: [NewsItem]
        var topic: (section: String, category: NewsCategory?)? = nil // 보도들의 분야 다수결(만들 때 미리 — 카드가 그릴 때마다 낱말 분류를 하지 않게)
        var id: String { cluster.id }
    }

    // 지금 보이는 출처로만 두 곳 이상이 다룬 스토리(출처를 끄면 그 스토리의 보도 수도 줄어 목록에서 빠질 수 있음)
    // 스토리 목록 전체를 문장 두 번(스토리 · 보도)으로 — 예전엔 스토리마다 두 번씩 물어 기록이 쌓일수록 화면이 멈췄다(STABILITY.md S5)
    nonisolated static func stories(db: Database, filter: SourceFilter, now: Date) -> [StoryCard] {
        let since = now.addingTimeInterval(-14 * 24 * 3600)
        let members = db.storyMembers(since: since)
        return db.recentClusters(since: since).filter { $0.size >= 2 }.compactMap { c in
            let items = filter.visible((members[c.id] ?? []).map(\.item))
            guard Set(items.map(\.sourceId)).count >= 2 else { return nil }
            var v = c; v.size = items.count
            return StoryCard(cluster: v, items: items, topic: storyTopic(items, place: \.section))
        }
    }

    // 스토리 화면: 지금 커지는 것(최근 24시간)과 나머지. 큰 것·최근 것이 앞. 만들기는 화면 줄기 밖에서
    nonisolated static func storyGroups(_ cards: [StoryCard], now: Date) -> (live: [StoryCard], past: [StoryCard]) {
        func score(_ c: Database.Cluster) -> Double { Double(c.size) + max(0, 24 - now.timeIntervalSince(c.last) / 3600) / 6 }
        let all = cards.sorted { a, b in
            let sa = score(a.cluster), sb = score(b.cluster)
            return sa != sb ? sa > sb : a.cluster.last > b.cluster.last
        }
        let cut = now.addingTimeInterval(-24 * 3600)
        return (all.filter { $0.cluster.last >= cut }, all.filter { $0.cluster.last < cut })
    }
    private(set) var lastStoryCards: (live: [StoryCard], past: [StoryCard]) = ([], []) // 다시 열 때 지난 결과부터 보이게
    private(set) var storyCardsLoaded = false
    func storyCards() async -> (live: [StoryCard], past: [StoryCard]) {
        let filter = AppModel.shared.sourceFilter, db = db, now = Date()
        let groups = await Task.detached(priority: .userInitiated) { Self.storyGroups(Self.stories(db: db, filter: filter, now: now), now: now) }.value
        lastStoryCards = groups
        storyCardsLoaded = true
        return groups
    }

    func search(_ q: String) async -> [NewsItem] { let f = context.filter; return await editor.search(q, filter: f) }
    func recentItems(since: Date) async -> [NewsItem] { await editor.recentItems(since: since, limit: 3000).map(\.item) }
    func storedImage(_ key: String) -> String? { db.image(key) }
    func coverage(_ items: [NewsItem]) -> [String: Int] { db.coverage(items.map(\.key)) }
}

extension NewsCategory {
    var sortOrder: Int { NewsCategory.allCases.firstIndex(of: self) ?? 99 }
}
