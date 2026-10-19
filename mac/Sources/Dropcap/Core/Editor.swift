import Foundation

// 매거진 편집 작업(R-1): 기사 받아 넣기·스토리 배정·호 엮기·지난 호 발행·검색을 화면 줄기 밖에서 한다.
// 화면(Magazine, @MainActor)은 결과만 받아 @Published 값을 바꾼다. DB 는 자기 줄(queue)로 지켜지므로 여기서 바로 부른다.

// 편집에 필요한 앱 상태의 사본(메인에서 만들어 넘김)
struct EditContext: Sendable {
    var hidden: Set<String> = []
    var filter = SourceFilter()   // 숨긴 출처 + 꺼진·해지한 출처를 뺀다(SourceFilter)
    var chosen: [String]? = nil
    var limits = PolicyLimits()
    var interestCategory: [String: Double] = [:]
    var interestSource: [String: Double] = [:]
    var followed: Set<String> = []
}

actor Editor {
    static let shared = Editor(retryFile: Store.dir.appendingPathComponent("ingest-retry.json"))
    private let db: Database
    private let retryFile: URL?

    // retryFile: 못 넣은 기사를 앱을 껐다 켜도 남게 적어 두는 파일(nil 이면 메모리에만 — 시험용)
    init(db: Database = .shared, retryFile: URL? = nil) {
        self.db = db
        self.retryFile = retryFile
        if let retryFile, let d = try? Data(contentsOf: retryFile), let items = try? JSONDecoder().decode([NewsItem].self, from: d) {
            retry = Array(items.suffix(Self.retryLimit))
        }
    }

    // MARK: 받아 넣기
    // DB 에 넣지 못한 기사(디스크 가득·오래 잠김). 앱 상태에는 '본 글'로 남아 피드에서 다시 오지 않으므로 여기 두었다가
    // 다음 받아 넣기 때 먼저 다시 넣는다. 끝없이 쌓이지 않게 retryLimit 건까지(오래된 것부터 버림)
    // 앱을 끄면 사라지지 않게 retryFile 에도 적는다 — 비면 파일을 지운다. 파일이 깨졌거나 없으면 빈 것으로
    private(set) var retry: [NewsItem] = []
    static let retryLimit = 3000

    private func keepRetry(_ items: [NewsItem]) {
        let had = !retry.isEmpty
        retry = Array(items.suffix(Self.retryLimit))
        guard let retryFile else { return }
        if retry.isEmpty {
            if had || FileManager.default.fileExists(atPath: retryFile.path) { try? FileManager.default.removeItem(at: retryFile) }
        } else if let d = try? JSONEncoder().encode(retry) {
            try? d.write(to: retryFile, options: .atomic) // 디스크가 가득이면 못 적을 수 있다(그때는 메모리에만)
        }
    }

    // 새 기사들을 DB 에 넣고 스토리에 배정한다. 팔로우한 스토리에 붙은 새 보도를 돌려준다.
    func ingest(_ fresh: [NewsItem], followed: Set<String>) -> [(Database.Cluster, NewsItem)] {
        let items = retry + fresh
        guard !items.isEmpty else { return [] }
        var failed: [NewsItem] = []
        defer { keepRetry(failed) }
        let since = Date().addingTimeInterval(-7 * 24 * 3600)
        var clusters = db.recentClusters(since: since)   // 최근에 커진 스토리 먼저
        let reps = db.representatives(since: since)       // 스토리마다 대표 기사(가장 최근 보도) — SQL 한 번
        // 스토리의 대표 기사와만 비교한다(낱말을 계속 보태면 눈덩이처럼 아무 기사나 붙는다)
        var repKeys: [(id: String, key: StoryKey)] = clusters.compactMap { c in reps[c.id].map { (c.id, StoryKey($0.item)) } }
        var index = Dictionary(clusters.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var grown: [(Database.Cluster, NewsItem)] = []
        for it in items {
            // 한 번 못 넣었으면 나머지도 못 넣는다(잠김·가득) — 하나마다 잠금을 기다리지 않고 바로 다음으로 미룬다
            if !failed.isEmpty { failed.append(it); continue }
            // 이미 있는 기사는 스토리를 다시 정하지 않는다(대표가 자기 자신이면 '같은 출처'로 보여 새 스토리가 생기던 문제)
            if db.exists(it.key) { if !db.upsert(it, cluster: nil) { failed.append(it) }; continue }
            // 기사만 스토리로 묶는다(논문·릴리스·커뮤니티 글은 양이 많고 성격이 달라 제외)
            if it.itemKind != .article && it.itemKind != .video { if !db.upsert(it, cluster: nil) { failed.append(it) }; continue }
            let k = StoryKey(it)
            let when = it.date ?? Date()
            if let id = StoryGrouper.storyFor(k, representatives: repKeys), let i = index[id] {
                // 기사를 먼저 넣고, 넣었을 때만 스토리를 키운다(못 넣은 기사를 다시 넣을 때 두 번 세지 않게)
                guard db.upsert(it, cluster: id) else { failed.append(it); continue }
                clusters[i].size += 1
                clusters[i].last = max(clusters[i].last, when)
                clusters[i].first = min(clusters[i].first, when)
                if it.tier == "lab" { clusters[i].title = it.displayTitle } // 공식 발표 제목을 스토리 이름으로
                db.saveCluster(clusters[i])
                if followed.contains(id) { grown.append((clusters[i], it)) }
            } else {
                let c = Database.Cluster(id: UUID().uuidString, title: it.displayTitle, tokens: k.tokens, first: when, last: when, size: 1)
                guard db.upsert(it, cluster: c.id) else { failed.append(it); continue }
                index[c.id] = clusters.count
                clusters.append(c)
                repKeys.append((c.id, k))
                db.saveCluster(c)
            }
        }
        return grown
    }

    // 같은 소식 기준이 바뀌었을 때: 최근 2주를 새 기준으로 다시 묶는다. (기사 수, 여러 곳 스토리 수)
    func recluster() -> (Int, Int) {
        let since = Date().addingTimeInterval(-14 * 24 * 3600)
        var items = db.items(from: since, limit: 5000).map(\.item).filter { $0.itemKind == .article || $0.itemKind == .video }
        items.sort { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        db.resetClusters(since: since)
        var clusters: [Database.Cluster] = [], repKeys: [(id: String, key: StoryKey)] = []
        var index: [String: Int] = [:]
        for it in items {
            let k = StoryKey(it), when = it.date ?? Date()
            if let id = StoryGrouper.storyFor(k, representatives: repKeys), let i = index[id] {
                clusters[i].size += 1
                clusters[i].last = max(clusters[i].last, when)
                clusters[i].first = min(clusters[i].first, when)
                if it.tier == "lab" { clusters[i].title = it.displayTitle }
                db.saveCluster(clusters[i])
                db.setCluster(it.key, id)
            } else {
                let c = Database.Cluster(id: UUID().uuidString, title: it.displayTitle, tokens: k.tokens, first: when, last: when, size: 1)
                index[c.id] = clusters.count
                clusters.append(c)
                repKeys.append((c.id, k))
                db.saveCluster(c)
                db.setCluster(it.key, c.id)
            }
        }
        return (items.count, clusters.filter { $0.size >= 2 }.count)
    }

    // MARK: 점수
    // 공식 발표·여러 곳 보도·중요 낱말·관심 분야는 위로, 오래될수록 아래로
    static func score(_ s: Database.StoredItem, clusterSize: Int, now: Date, ctx: EditContext) -> Double {
        let it = s.item
        let tier: Double = ["lab": 2.2, "press": 1.2, "kr": 1.0][it.tier] ?? 0.8
        let coverage = 1.6 * log(1 + Double(max(clusterSize, 1)))
        let important = it.important == true ? 2.5 : 0
        let interest = AppModel.interestWeight(category: it.category, source: it.sourceId, cats: ctx.interestCategory, srcs: ctx.interestSource)
        let hours = max(0, now.timeIntervalSince(it.date ?? s.firstSeen) / 3600)
        let fresh = 2.0 * exp(-hours / 18)
        let picture = it.image == nil ? 0 : 0.4
        return tier + coverage + important + interest + fresh + picture
    }

    // 표지 기사: 사진이 좋은(또는 아직 재지 않은) 것 중 앞, 없으면 사진 없는 것 중 앞(좋지 않은 사진을 표지에 크게 띄우지 않게)
    static func pickCover(_ ranked: [NewsItem], scores: [String: Double]) -> String? {
        let photo = { (it: NewsItem) in it.image != nil && !ImageKey.isJunk(it.image) }
        return (ranked.first { photo($0) && PhotoQuality.good(scores[$0.image!]) } ?? ranked.first { !photo($0) })?.key
    }

    // MARK: 호 엮기
    // only: 분야 지면(그 분야 칩이 달린 기사만, 구독 채널 지면 없이)
    func makeIssue(kind: Issue.Kind, from: Date, to: Date, id: String, ctx: EditContext, only: String? = nil) -> Issue {
        // 기사와 구독 채널 글을 따로(논문이 많아도 기사가 잘리지 않게). 숨긴 출처는 스토리 대표를 고르기 전에 뺀다
        let stored = (db.items(from: from, to: to, limit: 4000, articlesOnly: true) + (only == nil ? db.items(from: from, to: to, limit: 800, channelsOnly: true) : []))
            .filter { ctx.filter.shows($0.item.sourceId) && !ctx.hidden.contains($0.item.sourceId) }
            .filter { s in only.map { Sections.cachedPlace(s.item).chips.contains($0) } ?? true }
        // 같은 스토리는 대표 하나만 지면에(점수 높은 것)
        var sizes: [String: Int] = [:]
        for s in stored { if let c = s.cluster { sizes[c, default: 0] += 1 } }
        var best: [String: (Database.StoredItem, Double)] = [:]
        var loose: [(Database.StoredItem, Double)] = []
        for s in stored {
            let sc = Self.score(s, clusterSize: s.cluster.flatMap { sizes[$0] } ?? 1, now: to, ctx: ctx)
            if let c = s.cluster {
                if (best[c]?.1 ?? -1) < sc { best[c] = (s, sc) }
            } else {
                loose.append((s, sc))
            }
        }
        let ranked = (Array(best.values) + loose).sorted { $0.1 > $1.1 }
        let limit = kind == .weekly ? 60 : 90
        let picked = ranked.filter { $0.0.item.itemKind == .article }.prefix(limit)
        // 표지: 사진이 있는 기사 중 점수 1등(없으면 그냥 1등). 화면 캡처·글자 그림·로고로 잰 사진은 건너뛴다(M-24)
        // 주간 표지는 그 주 가장 많이 다룬 이야기(스토리 보도 수 → 점수 순) — 오늘 표지와 같아지지 않게
        let coverOrder = kind == .weekly
            ? Array(picked).sorted { a, b in
                let sa = a.0.cluster.flatMap { sizes[$0] } ?? 1, sb = b.0.cluster.flatMap { sizes[$0] } ?? 1
                return sa != sb ? sa > sb : a.1 > b.1
            }
            : Array(picked)
        let photoScores = db.imageScores(coverOrder.prefix(30).compactMap(\.0.item.image))
        let cover = Self.pickCover(coverOrder.map(\.0.item), scores: photoScores).flatMap { k in picked.first { $0.0.item.key == k } } ?? coverOrder.first
        let articles = picked.filter { $0.0.item.itemKind == .article && $0.0.item.key != cover?.0.item.key }.map(\.0)
        let sections = Magazine.sectionPages(articles, stored: stored, chosen: only.map { [$0] } ?? ctx.chosen, limits: ctx.limits,
                                             perSection: only != nil ? 40 : (kind == .weekly ? 8 : 12))
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
        let articleCount = stored.filter { $0.item.itemKind == .article }.count
        return Issue(id: id, kind: kind, date: Date(), from: from, to: to, cover: cover?.0.item.key, sections: sections + channelSections, count: articleCount)
    }

    // 지금 진행 중인 오늘 호(전날 18시~지금)·이번 주 호(7일)
    func liveDaily(_ ctx: EditContext) -> Issue {
        let start = Calendar.current.startOfDay(for: Date())
        return makeIssue(kind: .daily, from: start.addingTimeInterval(-6 * 3600), to: Date().addingTimeInterval(60), id: "live-daily", ctx: ctx)
    }
    // 이번 주: 달력 한 주의 시작부터 지금까지(지난 주간과 이어짐 — 예전엔 '지금부터 7일 전'이라 지난 주간과 날이 겹쳤다)
    func liveWeekly(_ ctx: EditContext) -> Issue {
        makeIssue(kind: .weekly, from: Magazine.weekRange(containing: Date()).from, to: Date().addingTimeInterval(60), id: "live-weekly", ctx: ctx)
    }
    func liveSection(_ ctx: EditContext, _ id: String) -> Issue {
        let start = Calendar.current.startOfDay(for: Date())
        return makeIssue(kind: .daily, from: start.addingTimeInterval(-6 * 3600), to: Date().addingTimeInterval(60), id: "live-section-" + id, ctx: ctx, only: id)
    }

    // 하루가 지나면 그날 호를, 일요일이 지나면 그 주 호를 발행해 지난 호에 남긴다. 지난 호 목록을 돌려준다.
    // 어제 호는 정오까지 새 기사가 오면 다시 엮되, 실린 기사가 같으면 다시 저장하지 않는다(A-21).
    // 빈 날은 최근 dueDays 일까지 메운다(매거진 채우기로 넣은 지난 기사도 그날 호가 생기게 — 예전엔 1~3일 전만이라 4일 넘은 날은 호가 없었다).
    // 이미 있는 호는 건너뛰고, 4일 넘은 날은 기사 수만 먼저 세어 없으면 엮지 않는다(확인마다 14일을 다시 엮지 않게)
    static let dueDays = 14
    func publishDue(_ ctx: EditContext) -> [Issue] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        for back in stride(from: Self.dueDays, through: 1, by: -1) {
            guard let day = cal.date(byAdding: .day, value: -back, to: today) else { continue }
            let id = "daily-" + Magazine.dayID(day)
            let refresh = back == 1 && cal.component(.hour, from: Date()) < 12
            let existing = db.issue(id)
            if existing != nil && !refresh { continue }
            let from = day.addingTimeInterval(-6 * 3600), to = day.addingTimeInterval(18 * 3600)
            if back > 3, db.articleCount(from: from, to: to) == 0 { continue }
            let issue = makeIssue(kind: .daily, from: from, to: to, id: id, ctx: ctx)
            if issue.count > 0, !Self.sameContent(issue, existing) { db.saveIssue(issue) }
        }
        // 주간: 지난주와 지지난주(채운 기사가 지지난주에 걸칠 수 있음)
        var weekStart = Magazine.weekRange(containing: today, cal: cal).from
        for n in 0..<2 {
            let last = Magazine.weekRange(containing: weekStart.addingTimeInterval(-3600), cal: cal)
            weekStart = last.from
            let weekID = "weekly-" + Magazine.weekID(last.from)
            if db.hasIssue(weekID) || (n > 0 && db.articleCount(from: last.from, to: last.to) == 0) { continue }
            let issue = makeIssue(kind: .weekly, from: last.from, to: last.to, id: weekID, ctx: ctx)
            if issue.count > 0 { db.saveIssue(issue) }
        }
        // 분야 개편 전에 엮은 호는 그 기간 기사로 지금 규칙(분야 지면)에 맞춰 다시 엮는다(기사가 지워졌으면 그대로 둠)
        for old in db.issues() where Magazine.needsRebuild(old) {
            let again = makeIssue(kind: old.kind, from: old.from, to: old.to, id: old.id, ctx: ctx)
            if again.count > 0 { db.saveIssue(again) }
        }
        db.prune()
        return db.issues()
    }

    // 실린 기사(표지·지면 순서)가 같으면 같은 호
    static func sameContent(_ a: Issue, _ b: Issue?) -> Bool {
        guard let b else { return false }
        return a.cover == b.cover && a.sections == b.sections && a.count == b.count
    }

    // MARK: 꺼내 보기
    // 한 호를 화면에 그릴 재료를 한 번에(지면마다 DB 를 다시 읽지 않게)
    func resolve(_ issue: Issue, filter: SourceFilter) -> Magazine.Resolved {
        let keys = (issue.cover.map { [$0] } ?? []) + issue.sections.flatMap(\.keys)
        let map = Dictionary(db.items(keys: keys).map { ($0.item.key, $0) }, uniquingKeysWith: { a, _ in a })
        var clusters: [String: String] = [:]
        for (k, v) in map { if let c = v.cluster { clusters[k] = c } }
        // 여러 곳이 다룬 스토리만 보도를 꺼내 해외·국내가 섞였는지 본다
        var regions: [String: [NewsItem]] = [:]
        let sizes = db.coverage(Array(clusters.keys))
        for (k, c) in clusters where (sizes[k] ?? 1) >= 2 && regions[c] == nil {
            let items = db.items(inCluster: c).map(\.item).filter { filter.shows($0.sourceId) }
            let split = Magazine.splitByRegion(items)
            if !split.intl.isEmpty, !split.kr.isEmpty { regions[c] = items }
        }
        return Magazine.Resolved(issue: issue, cover: issue.cover.flatMap { map[$0] }.flatMap { filter.shows($0.item.sourceId) ? $0 : nil },
                                 sections: issue.sections.map { s in (s, s.keys.compactMap { map[$0]?.item }.filter { filter.shows($0.sourceId) }) }.filter { !$0.1.isEmpty },
                                 clusters: clusters, regions: regions)
    }

    // 사진 주소·점수 쓰기도 화면 줄기 밖에서(DB 가 잠겼을 때 메인이 기다리지 않게 — S7)
    func setImage(_ key: String, _ url: String) { db.setImage(key, url) }
    func imageScores(_ urls: [String]) -> [String: Double] { db.imageScores(urls) }
    func saveImageScore(_ url: String, _ s: PhotoQuality.Score) { db.saveImageScore(url, s) }

    func search(_ q: String, filter: SourceFilter = SourceFilter()) -> [NewsItem] { filter.visible(db.search(q)) }
    func missing(_ keys: [String]) -> Set<String> { Set(keys).subtracting(db.existing(keys)) }
    func recentItems(since: Date, limit: Int) -> [Database.StoredItem] { db.items(from: since, limit: limit) }
    func existingStories(_ ids: [String]) -> Set<String> { db.existingClusters(ids) }

    // 알림 판단용: 기사마다 스토리 id 와 같은 소식을 다룬 국내·해외 출처 수(숨긴 출처 제외)
    func storyInfo(_ items: [NewsItem], filter: SourceFilter) -> [String: (story: String?, coverage: Coverage)] {
        let ids = db.clusters(of: items.map(\.key))
        var members: [String: [NewsItem]] = [:]
        for c in Set(ids.values) { members[c] = db.items(inCluster: c).map(\.item) }
        var out: [String: (String?, Coverage)] = [:]
        for it in items {
            var regions: [String: String] = [it.sourceId: Sections.region(ofSource: it.sourceId, tier: it.tier)]
            if let c = ids[it.key] {
                for m in members[c] ?? [] where filter.shows(m.sourceId) { regions[m.sourceId] = Sections.region(ofSource: m.sourceId, tier: m.tier) }
            }
            out[it.key] = (ids[it.key], Coverage(kr: regions.values.filter { $0 == "kr" }.count, intl: regions.values.filter { $0 != "kr" }.count))
        }
        return out
    }
}
