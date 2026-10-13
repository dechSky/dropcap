import Foundation
import SwiftUI

// 호(발행본): 표지 기사 하나 + 분야별 지면. 기사 자체는 DB 에 있고 여기엔 순서만 둔다.
struct Issue: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case daily, weekly }
    struct Section: Codable, Hashable {
        var category: NewsCategory
        var keys: [String]
        var kind: String? = nil   // 영상·논문 등 구독 채널 지면이면 그 종류

        var id: String { kind ?? category.rawValue }
        var label: String { kind.flatMap { ItemKind(rawValue: $0)?.label } ?? (category == .other ? "그 밖의 소식" : category.label) }
        var symbol: String { kind.flatMap { ItemKind(rawValue: $0)?.symbol } ?? category.symbol }
        var color: Color {
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
    @Published private(set) var archive: [Issue] = []
    @Published var preparing = false             // 첫 호를 엮는 중
    private var enriching = false

    private init() {
        archive = db.issues()
    }

    // MARK: 받아 넣기
    // 처음 실행: 예전 기록(최근 소식·저장)을 옮겨 온다. 이미 있으면 건너뜀.
    func migrateIfNeeded(from state: AppState) {
        guard db.itemCount == 0 else { return }
        let items = state.recent + state.saved
        guard !items.isEmpty else { return }
        ingest(items.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) })
        backfillIssues()
        NSLog("[매거진] 예전 기록 %d건을 옮겼습니다", items.count)
    }

    // 새로 들어온 기사 전부(같은 소식으로 묶여 알림에서 빠진 것도 포함)
    func ingest(_ items: [NewsItem]) {
        guard !items.isEmpty else { return }
        let since = Date().addingTimeInterval(-7 * 24 * 3600)
        var clusters = db.recentClusters(since: since)
        // 스토리마다 대표 기사 하나(뜻 비교용)
        var representatives: [String: NewsItem] = [:]
        for c in clusters { if let first = db.items(inCluster: c.id).last?.item { representatives[c.id] = first } }
        for it in items {
            let tokens = StoryMatch.tokens(it.title)
            let when = it.date ?? Date()
            var cid: String?
            // 스토리의 대표 기사와만 비교한다(낱말을 계속 보태면 눈덩이처럼 아무 기사나 붙는다)
            // 기사만 스토리로 묶는다(논문·릴리스·커뮤니티 글은 양이 많고 성격이 달라 제외)
            if it.itemKind != .article && it.itemKind != .video {
                db.upsert(it, cluster: nil)
                continue
            }
            if let i = clusters.firstIndex(where: { c in representatives[c.id].map { StoryMatch.same(it, $0) } ?? false }) {
                if !db.exists(it.key) { clusters[i].size += 1 }
                clusters[i].last = max(clusters[i].last, when)
                clusters[i].first = min(clusters[i].first, when)
                // 공식 발표 제목을 스토리 이름으로
                if it.tier == "lab" { clusters[i].title = it.displayTitle }
                cid = clusters[i].id
                db.saveCluster(clusters[i])
            } else {
                let c = Database.Cluster(id: UUID().uuidString, title: it.displayTitle, tokens: tokens, first: when, last: when, size: 1)
                clusters.append(c)
                db.saveCluster(c)
                cid = c.id
                representatives[c.id] = it
            }
            db.upsert(it, cluster: cid)
        }
        revision += 1
        enrichImages()
    }

    // 사진이 없는 최근 기사는 페이지에서 og:image 를 찾아 채운다(한 번에 12개, 공개 주소만)
    func enrichImages() {
        guard !enriching else { return }
        enriching = true
        let todo = db.items(from: Date().addingTimeInterval(-3 * 24 * 3600), limit: 300)
            .filter { $0.item.image == nil && !$0.item.link.isEmpty }
            .prefix(12)
        Task {
            var changed = false
            for s in todo {
                if let img = await FeedService.shared.ogImage(s.item.link) {
                    db.setImage(s.item.key, img)
                    changed = true
                }
            }
            enriching = false
            if changed { imageRevision += 1 }
        }
    }

    // MARK: 점수
    // 공식 발표·여러 곳 보도·중요 낱말·관심 분야는 위로, 오래될수록 아래로
    func score(_ s: Database.StoredItem, clusterSize: Int, now: Date = Date()) -> Double {
        let it = s.item
        let tier: Double = ["lab": 2.2, "press": 1.2, "kr": 1.0][it.tier] ?? 0.8
        let coverage = 1.6 * log(1 + Double(max(clusterSize, 1)))
        let important = it.important == true ? 2.5 : 0
        let interest = AppModel.shared.interestWeight(category: it.category, source: it.sourceId)
        let hours = max(0, now.timeIntervalSince(it.date ?? s.firstSeen) / 3600)
        let fresh = 2.0 * exp(-hours / 18)
        let picture = it.image == nil ? 0 : 0.4
        return tier + coverage + important + interest + fresh + picture
    }

    // MARK: 호 엮기
    func makeIssue(kind: Issue.Kind, from: Date, to: Date, id: String) -> Issue {
        let stored = db.items(from: from, to: to)
        // 같은 스토리는 대표 하나만 지면에(점수 높은 것)
        var sizes: [String: Int] = [:]
        for s in stored { if let c = s.cluster { sizes[c, default: 0] += 1 } }
        var best: [String: (Database.StoredItem, Double)] = [:]
        var loose: [(Database.StoredItem, Double)] = []
        for s in stored {
            let sc = score(s, clusterSize: s.cluster.flatMap { sizes[$0] } ?? 1, now: to)
            if let c = s.cluster {
                if (best[c]?.1 ?? -1) < sc { best[c] = (s, sc) }
            } else {
                loose.append((s, sc))
            }
        }
        let ranked = (Array(best.values) + loose).sorted { $0.1 > $1.1 }
        let limit = kind == .weekly ? 40 : 60
        let picked = ranked.filter { $0.0.item.itemKind == .article }.prefix(limit)
        // 표지: 사진이 있는 기사 중 점수 1등(없으면 그냥 1등)
        let cover = picked.first { $0.0.item.image != nil } ?? picked.first
        var sections: [Issue.Section] = []
        let articles = picked.filter { $0.0.item.itemKind == .article && $0.0.item.key != cover?.0.item.key }
        var leftovers: [String] = []
        for cat in NewsCategory.allCases where cat != .other {
            let keys = articles.filter { $0.0.item.category == cat }.map(\.0.item.key)
            // 한 건뿐인 분야는 지면이 휑하므로 '그 밖의 소식'으로 모은다
            if keys.count >= 2 { sections.append(.init(category: cat, keys: Array(keys.prefix(kind == .weekly ? 8 : 12)))) } else { leftovers += keys }
        }
        leftovers += articles.filter { $0.0.item.category == .other }.map(\.0.item.key)
        if !leftovers.isEmpty { sections.append(.init(category: .other, keys: Array(leftovers.prefix(12)))) }
        // 구독 채널 지면: 종류별, 채널 하나당 4개까지(논문처럼 많은 곳이 지면을 덮지 않게)
        var channelSections: [Issue.Section] = []
        for k in [ItemKind.video, .release, .paper, .podcast, .post] {
            var perSource: [String: Int] = [:]
            let keys = ranked.filter { $0.0.item.itemKind == k }.compactMap { s -> String? in
                perSource[s.0.item.sourceId, default: 0] += 1
                return perSource[s.0.item.sourceId]! <= 4 ? s.0.item.key : nil
            }
            if !keys.isEmpty { channelSections.append(.init(category: .other, keys: Array(keys.prefix(12)), kind: k.rawValue)) }
        }
        // 지면 순서도 관심 분야가 앞으로
        sections.sort {
            AppModel.shared.interestWeight(category: $0.category, source: nil) > AppModel.shared.interestWeight(category: $1.category, source: nil)
                || ($0.category.sortOrder < $1.category.sortOrder
                    && AppModel.shared.interestWeight(category: $0.category, source: nil) == AppModel.shared.interestWeight(category: $1.category, source: nil))
        }
        return Issue(id: id, kind: kind, date: Date(), from: from, to: to, cover: cover?.0.item.key, sections: sections + channelSections, count: stored.count)
    }

    // 지금 진행 중인 오늘 호·이번 주 호(아직 발행 전, 화면에서 바로 계산)
    func liveDaily() -> Issue {
        let start = Calendar.current.startOfDay(for: Date())
        return makeIssue(kind: .daily, from: start.addingTimeInterval(-6 * 3600), to: Date().addingTimeInterval(60), id: "live-daily")
    }

    func liveWeekly() -> Issue {
        makeIssue(kind: .weekly, from: Date().addingTimeInterval(-7 * 24 * 3600), to: Date().addingTimeInterval(60), id: "live-weekly")
    }

    // 하루가 지나면 그날 호를, 일요일이 지나면 그 주 호를 발행해 지난 호에 남긴다
    func publishDue() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        for back in 1...3 {
            guard let day = cal.date(byAdding: .day, value: -back, to: today) else { continue }
            let id = "daily-" + Self.dayID(day)
            if db.hasIssue(id) { continue }
            let issue = makeIssue(kind: .daily, from: day, to: day.addingTimeInterval(24 * 3600), id: id)
            if issue.count > 0 { db.saveIssue(issue) }
        }
        if let weekStart = cal.dateInterval(of: .weekOfYear, for: today)?.start,
           let lastWeekStart = cal.date(byAdding: .day, value: -7, to: weekStart) {
            let id = "weekly-" + Self.weekID(lastWeekStart)
            if !db.hasIssue(id) {
                let issue = makeIssue(kind: .weekly, from: lastWeekStart, to: weekStart, id: id)
                if issue.count > 0 { db.saveIssue(issue) }
            }
        }
        archive = db.issues()
    }

    private func backfillIssues() { publishDue() }

    static func dayID(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }
    static func weekID(_ d: Date) -> String {
        let c = Calendar(identifier: .iso8601)
        return String(format: "%04d-W%02d", c.component(.yearForWeekOfYear, from: d), c.component(.weekOfYear, from: d))
    }

    // MARK: 꺼내 보기
    // 한 호를 화면에 그릴 재료를 한 번에(지면마다 DB 를 다시 읽지 않게)
    struct Resolved {
        var issue: Issue
        var cover: Database.StoredItem?
        var sections: [(section: Issue.Section, items: [NewsItem])]
    }

    func resolve(_ issue: Issue) -> Resolved {
        let all = db.items(from: issue.from.addingTimeInterval(-24 * 3600), to: issue.to.addingTimeInterval(24 * 3600), limit: 5000)
        let map = Dictionary(all.map { ($0.item.key, $0) }, uniquingKeysWith: { a, _ in a })
        return Resolved(issue: issue, cover: issue.cover.flatMap { map[$0] },
                        sections: issue.sections.map { s in (s, s.keys.compactMap { map[$0]?.item }) }.filter { !$0.1.isEmpty })
    }

    func items(_ keys: [String], in issue: Issue) -> [NewsItem] {
        let all = db.items(from: issue.from.addingTimeInterval(-24 * 3600), to: issue.to.addingTimeInterval(24 * 3600), limit: 5000)
        let map = Dictionary(all.map { ($0.item.key, $0.item) }, uniquingKeysWith: { a, _ in a })
        return keys.compactMap { map[$0] }
    }

    func stored(_ key: String, near issue: Issue) -> Database.StoredItem? {
        db.items(from: issue.from.addingTimeInterval(-24 * 3600), to: issue.to.addingTimeInterval(24 * 3600), limit: 5000).first { $0.item.key == key }
    }

    func storyItems(_ cluster: String) -> [NewsItem] { db.items(inCluster: cluster).map(\.item) }
    func cluster(_ id: String) -> Database.Cluster? { db.cluster(id) }
    func clusterID(of key: String, near issue: Issue) -> String? { stored(key, near: issue)?.cluster }

    // 스토리: 최근 2주 동안 두 곳 이상이 다룬 것
    func stories() -> [Database.Cluster] {
        db.recentClusters(since: Date().addingTimeInterval(-14 * 24 * 3600)).filter { $0.size >= 2 }
    }

    func search(_ q: String) -> [NewsItem] { db.search(q) }
}

extension NewsCategory {
    var sortOrder: Int { NewsCategory.allCases.firstIndex(of: self) ?? 99 }
}
