import Foundation
import Testing
@testable import Dropcap

// 지난 기사 보관함: 정리(prune)가 지우는 기사를 보관 표로 옮기기 · 보관 기간 상한 · 보관 검색 · 기간 목록
private func item(_ id: String, title: String? = nil, source: String = "geeknews", date: Date) -> NewsItem {
    NewsItem(id: id, title: title ?? "기사 \(id)", titleKo: nil, link: "https://\(source).example/\(id)", date: date,
             summary: "요약", sourceId: source, sourceName: source + " 이름", tier: "press")
}

@Suite struct ArchiveTests {
    func tempDB() throws -> Database {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("dropcap-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return Database(file: d.appendingPathComponent("magazine.sqlite"))
    }

    // 정리가 지우는 오래된 기사는 보관 표로 옮겨지고(날짜·제목·링크·출처·분야), 최근 keep 건은 items 에 남는다
    @Test func pruneMovesToArchive() throws {
        let db = try tempDB()
        let now = Date()
        for i in 0..<10 { db.upsert(item("a\(i)", date: now.addingTimeInterval(Double(-i) * 3600)), cluster: nil) }
        let moved = db.prune(keep: 6, now: now, section: { _ in "tech" })
        #expect(moved == 4)
        #expect(db.itemCount == 6)
        #expect(db.archiveCount == 4)
        let old = db.archived(from: now.addingTimeInterval(-24 * 3600), to: now.addingTimeInterval(60))
        #expect(old.map(\.link) == (6..<10).map { "https://geeknews.example/a\($0)" })
        #expect(old.first?.source == "geeknews 이름")
        #expect(old.first?.section == "tech")
        #expect(abs(old.first!.date.timeIntervalSince(now.addingTimeInterval(-6 * 3600))) < 1)
        // 다시 정리해도 같은 기사를 두 번 넣지 않는다
        db.upsert(item("a9", date: now.addingTimeInterval(-9 * 3600)), cluster: nil)
        db.prune(keep: 6, now: now, section: { _ in "tech" })
        #expect(db.archiveCount == 4)
    }

    // 여러 곳이 다룬 스토리만 스토리 id 를 남긴다
    @Test func pruneKeepsStoryOnlyForSharedStories() throws {
        let db = try tempDB()
        let now = Date()
        db.saveCluster(.init(id: "big", title: "큰 소식", tokens: [], first: now, last: now, size: 2))
        db.saveCluster(.init(id: "one", title: "혼자", tokens: [], first: now, last: now, size: 1))
        db.upsert(item("s1", date: now.addingTimeInterval(-3 * 3600)), cluster: "big")
        db.upsert(item("s2", date: now.addingTimeInterval(-4 * 3600)), cluster: "one")
        db.upsert(item("new", date: now), cluster: nil)
        db.prune(keep: 1, now: now, section: { _ in "tech" })
        let old = db.archived(from: now.addingTimeInterval(-86400), to: now)
        #expect(old.first { $0.link.hasSuffix("s1") }?.story == "big")
        #expect(old.first { $0.link.hasSuffix("s2") }?.story == nil)
    }

    // 보관 기간: years 년 전이 든 달보다 이른 보관 기사는 지운다(달 단위), 0 이면 지우지 않는다
    @Test func pruneCapsArchiveByMonths() throws {
        let cal = Calendar.current
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 12))!
        #expect(Archive.cutoff(years: 2, now: now) == cal.date(from: DateComponents(year: 2024, month: 10, day: 1)))
        #expect(Archive.cutoff(years: 0, now: now) == nil)
        let db = try tempDB()
        let dates = [(2024, 9, 30), (2024, 10, 1), (2025, 10, 5)].map { cal.date(from: DateComponents(year: $0.0, month: $0.1, day: $0.2, hour: 9))! }
        for (i, d) in dates.enumerated() { db.upsert(item("o\(i)", date: d), cluster: nil) }
        db.upsert(item("keep", date: now), cluster: nil)
        db.prune(keep: 1, archiveYears: 0, now: now, section: { _ in "tech" })
        #expect(db.archiveCount == 3)
        db.prune(keep: 1, archiveYears: 2, now: now, section: { _ in "tech" })
        #expect(db.archiveCount == 2) // 2024년 9월은 지워짐, 10월 1일부터 남음
        db.prune(keep: 1, archiveYears: 1, now: now, section: { _ in "tech" })
        #expect(db.archiveCount == 1)
    }

    // 보관 검색: 제목·출처 LIKE, 최신순, 더 보기(offset), % _ 는 글자 그대로
    @Test func searchArchive() throws {
        let db = try tempDB()
        let now = Date()
        for i in 0..<5 { db.upsert(item("q\(i)", title: "엔비디아 실적 \(i)", date: now.addingTimeInterval(Double(-i - 1) * 86400)), cluster: nil) }
        db.upsert(item("pct", title: "금리 50% 인상", date: now.addingTimeInterval(-10 * 86400)), cluster: nil)
        db.upsert(item("keep", date: now), cluster: nil)
        db.prune(keep: 1, now: now, section: { _ in "economy" })
        let hits = db.searchArchive("엔비디아", limit: 3)
        #expect(hits.map(\.title) == ["엔비디아 실적 0", "엔비디아 실적 1", "엔비디아 실적 2"])
        #expect(db.searchArchive("엔비디아", limit: 3, offset: 3).count == 2)
        #expect(db.searchArchive("50%").map(\.title) == ["금리 50% 인상"])
        #expect(db.searchArchive("5_%").isEmpty)
        #expect(db.searchArchive("geeknews 이름").count == 6)
    }

    // 기간 목록: 최근 기사(items)와 보관 기사를 합쳐 최신순, 분야·출처 거르기, 날짜별 건수, 더 보기
    @Test func archivePeriodMergesRecentAndArchived() throws {
        let db = try tempDB()
        let cal = Calendar.current
        let day = cal.startOfDay(for: cal.date(byAdding: .day, value: -3, to: Date())!)
        for i in 0..<6 {
            db.upsert(item("p\(i)", source: i % 2 == 0 ? "aa" : "bb", date: day.addingTimeInterval(Double(10 + i) * 3600)), cluster: nil)
        }
        db.prune(keep: 3, section: { $0.sourceId == "aa" ? "tech" : "economy" }) // p0~p2 는 보관 표로
        #expect(db.archiveCount == 3)
        let ed = ArchiveReader(db: db)
        let r = Archive.range(.day, containing: day)
        let all = ed.archivePeriod(from: r.from, to: r.to, section: nil, source: nil, limit: 100)
        #expect(all.items.map(\.link) == (0..<6).reversed().map { "https://\($0 % 2 == 0 ? "aa" : "bb").example/p\($0)" })
        #expect(all.total == 6 && !all.more)
        #expect(all.dayCounts == [Archive.dayKey(day): 6])
        #expect(all.sources == ["aa 이름": 3, "bb 이름": 3])
        let some = ed.archivePeriod(from: r.from, to: r.to, section: nil, source: "aa 이름", limit: 2)
        #expect(some.items.map(\.link) == ["https://aa.example/p4", "https://aa.example/p2"])
        #expect(some.more && some.total == 3)
        let week = Archive.range(.month, containing: day)
        #expect(ed.archivePeriod(from: week.from, to: week.to, section: nil, source: nil, limit: 100).total == 6)
    }

    // 읽지 못하는 줄(제목·링크 없음)은 보관하지 못하므로 지우지도 않는다
    @Test func pruneKeepsUnreadableRows() throws {
        let db = try tempDB()
        let now = Date()
        db.upsert(item("ok", date: now.addingTimeInterval(-7200)), cluster: nil)
        db.upsert(item("bad", date: now.addingTimeInterval(-3600)), cluster: nil)
        db.upsert(item("new", date: now), cluster: nil)
        db.execForTests("UPDATE items SET json=json_remove(json,'$.title') WHERE key='geeknews|bad'")
        db.prune(keep: 1, now: now, section: { _ in "tech" })
        #expect(db.archiveCount == 1)
        #expect(db.exists("geeknews|bad"))
        #expect(!db.exists("geeknews|ok"))
    }

    // 숨긴·끈 출처는 보관함(목록·날짜별 건수·분야/출처 메뉴)과 오래된 기사 검색에 다시 나오지 않는다 — 최근 기사도, 보관 기사도
    @Test func hiddenSourcesStayHidden() throws {
        let db = try tempDB()
        let cal = Calendar.current
        let day = cal.startOfDay(for: cal.date(byAdding: .day, value: -3, to: Date())!)
        for i in 0..<6 {
            db.upsert(item("h\(i)", title: "엔비디아 \(i)", source: i % 2 == 0 ? "aa" : "bb", date: day.addingTimeInterval(Double(10 + i) * 3600)), cluster: nil)
        }
        db.prune(keep: 2, section: { _ in "tech" }) // h0~h3 보관, h4·h5 는 최근
        let hide = Archive.Hide(filter: SourceFilter(hidden: ["bb"]), hiddenNames: ["bb 이름"])
        let r = Archive.range(.day, containing: day)
        let page = ArchiveReader(db: db).archivePeriod(from: r.from, to: r.to, section: nil, source: nil, limit: 100, hide: hide)
        #expect(page.items.map(\.source) == ["aa 이름", "aa 이름", "aa 이름"])
        #expect(page.total == 3 && page.sources == ["aa 이름": 3] && page.sections.values.reduce(0, +) == 3)
        #expect(db.searchArchive("엔비디아", hide: hide).allSatisfy { $0.sourceId == "aa" })
        #expect(db.searchArchive("엔비디아", hide: hide).count == 2)
        // 켠 출처만(끈·해지한 출처 빼기)
        let onlyBB = Archive.Hide(filter: SourceFilter(active: ["bb"]))
        #expect(db.searchArchive("엔비디아", hide: onlyBB).map(\.sourceId) == ["bb", "bb"])
        // 출처 id 가 없던 줄(먼저 만든 판)은 숨긴 출처 이름으로 거른다
        db.execForTests("UPDATE archive SET source_id = NULL")
        #expect(db.searchArchive("엔비디아", hide: hide).map(\.source) == ["aa 이름", "aa 이름"])
        #expect(db.archiveDayCounts(from: r.from, to: r.to, hide: hide).values.reduce(0, +) == 2)
    }

    // 줄 수 안전 상한: '끝없이'여도 rowCap 건을 넘으면 가장 오래된 것부터 지운다
    @Test func pruneCapsArchiveRows() throws {
        let db = try tempDB()
        let now = Date()
        for i in 0..<6 { db.upsert(item("c\(i)", date: now.addingTimeInterval(Double(-i - 1) * 86400)), cluster: nil) }
        db.upsert(item("keep", date: now), cluster: nil)
        db.prune(keep: 1, archiveYears: 0, now: now, rowCap: 4, section: { _ in "tech" })
        #expect(db.archiveCount == 4)
        #expect(db.searchArchive("geeknews").map(\.link).last == "https://geeknews.example/c3")
        #expect(Archive.settingsNote(0).contains("500만 건"))
        #expect(Archive.trimQuery(String(repeating: "가", count: 500)).count == Archive.queryLimit)
    }

    // 같은 링크는 한 번(최근 기사끼리 겹친 것도) — 목록 줄 id 가 겹쳐 빈 줄이 생기지 않게
    @Test func mergeDedupesLinks() {
        let d = Date()
        func a(_ link: String, _ s: Double) -> ArchivedItem { ArchivedItem(date: d.addingTimeInterval(s), title: link, link: link, source: "x", section: "tech") }
        let m = Archive.merge(recent: [a("l1", 0), a("l1", 0), a("l2", -10)], archived: [a("l2", -20), a("l3", -30)])
        #expect(m.map(\.link) == ["l1", "l2", "l3"])
        #expect(Set(m.map(\.id)).count == m.count)
    }

    // 기간 계산: ◀ ▶ 로 한 기간씩, 일·주·월·연 경계
    @Test func periods() {
        let cal = Calendar.current
        let d = cal.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 13))!
        let m = Archive.range(.month, containing: d)
        #expect(m.from == cal.date(from: DateComponents(year: 2026, month: 3, day: 1)))
        #expect(m.to == cal.date(from: DateComponents(year: 2026, month: 4, day: 1)))
        #expect(Archive.range(.year, containing: Archive.shift(.year, d, by: -1)).from == cal.date(from: DateComponents(year: 2025, month: 1, day: 1)))
        #expect(Archive.range(.day, containing: Archive.shift(.day, d, by: 1)).from == cal.date(from: DateComponents(year: 2026, month: 3, day: 16)))
        #expect(Archive.title(.month, d) == "2026년 3월")
        #expect(Archive.days(m.from, m.to).count == 31)
        #expect(Archive.dayKey(d) == "2026-03-15")
    }

    // 보관 기간 설정: 예전 상태 파일엔 없음 → 2년, 모르는 값도 2년
    @Test func settingsArchiveYears() throws {
        let old = try JSONDecoder().decode(AppState.Settings.self, from: Data("{}".utf8))
        #expect(old.archiveYears == 2)
        let odd = try JSONDecoder().decode(AppState.Settings.self, from: Data(#"{"archiveYears":3}"#.utf8))
        #expect(odd.archiveYears == 2)
        let never = try JSONDecoder().decode(AppState.Settings.self, from: Data(#"{"archiveYears":0}"#.utf8))
        #expect(never.archiveYears == 0)
    }
}
