import Foundation
import Testing
@testable import Dropcap

// 매거진 지난 호(mag-issues): 설치 전 기사 채우기 · 빈 날 호 발행 · 지난 호 목록 날짜 묶음
private func item(_ id: String, source: String = "geeknews", date: Date?) -> NewsItem {
    NewsItem(id: id, title: "기사 \(id)", titleKo: nil, link: "https://\(source).example/\(id)", date: date,
             summary: "", sourceId: source, sourceName: source, tier: "press")
}

private func daily(_ day: Date, count: Int = 10) -> Dropcap.Issue {
    Dropcap.Issue(id: "daily-" + Magazine.dayID(day), kind: .daily, date: day, from: day.addingTimeInterval(-6 * 3600),
                  to: day.addingTimeInterval(18 * 3600), cover: nil, sections: [], count: count)
}

@Suite struct MagIssuesTests {
    func tempEditor() throws -> (Editor, Database) {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("dropcap-issues-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let db = Database(file: d.appendingPathComponent("magazine.sqlite"))
        return (Editor(db: db), db)
    }

    // 채운 지난 날 기사도 그날 호가 생긴다(예전엔 1~3일 전만 엮어 4일 넘은 날은 영영 호가 없었다). 14일보다 앞은 엮지 않는다
    @Test func publishDueFillsEmptyDays() async throws {
        let (ed, db) = try tempEditor()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        for back in [6, 10, 20] {
            let day = cal.date(byAdding: .day, value: -back, to: today)!
            for i in 0..<3 { db.upsert(item("d\(back)-\(i)", date: day.addingTimeInterval(Double(10 + i) * 3600)), cluster: nil) }
        }
        let ids = Set(await ed.publishDue(EditContext()).map(\.id))
        for back in [6, 10] { #expect(ids.contains("daily-" + Magazine.dayID(cal.date(byAdding: .day, value: -back, to: today)!))) }
        #expect(!ids.contains("daily-" + Magazine.dayID(cal.date(byAdding: .day, value: -20, to: today)!)))
    }

    // 지지난주 기사도 주간 호가 생긴다(예전엔 지난주만)
    @Test func publishDueFillsWeekBeforeLast() async throws {
        let (ed, db) = try tempEditor()
        let thisWeek = Magazine.weekRange(containing: Date())
        let last = Magazine.weekRange(containing: thisWeek.from.addingTimeInterval(-3600))
        let before = Magazine.weekRange(containing: last.from.addingTimeInterval(-3600))
        for i in 0..<3 { db.upsert(item("w\(i)", date: before.from.addingTimeInterval(Double(30 + i) * 3600)), cluster: nil) }
        let ids = Set(await ed.publishDue(EditContext()).map(\.id))
        #expect(ids.contains("weekly-" + Magazine.weekID(before.from)))
    }

    // 이미 있는 호는 다시 엮지 않는다(확인마다 14일을 다시 엮지 않게 — 기사 수만 세고 건너뜀)
    @Test func publishDueKeepsExistingOldIssue() async throws {
        let (ed, db) = try tempEditor()
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: Date()))!
        for i in 0..<3 { db.upsert(item("k\(i)", date: day.addingTimeInterval(Double(10 + i) * 3600)), cluster: nil) }
        var saved = daily(day, count: 99)
        saved.sections = [.init(category: .other, keys: ["geeknews|k0"], section: "tech")]
        db.saveIssue(saved)
        let list = await ed.publishDue(EditContext())
        #expect(list.first { $0.id == saved.id }?.count == 99)
    }

    // 채우기: 7일 안 · 새것부터 상한까지 · 날짜 없는 글·앞날 글 뺌(예전엔 3일·25건이라 많이 쓰는 출처는 어제 글부터 빠졌다)
    @Test func magazineFillWindowAndCap() {
        let now = Date()
        var items = (0..<200).map { item("f\($0)", date: now.addingTimeInterval(-Double($0) * 3600)) } // 0~199시간 전
        items.append(item("nodate", date: nil))
        items.append(item("future", date: now.addingTimeInterval(86400)))
        let all = AppModel.magazineFill(items, now: now, cap: 500)
        #expect(all.count == 168)                             // 7일 = 168시간(0~167)
        #expect(!all.contains { $0.id == "nodate" || $0.id == "future" })
        let capped = AppModel.magazineFill(items.shuffled(), now: now, cap: 120)
        #expect(capped.count == 120)
        #expect(capped.first?.id == "f0")                     // 새것부터
        // 예전 방식(3일·25건)보다 많이: 하루 24건 내는 출처의 어제·그제 글도 들어감
        let days = Set(capped.compactMap(\.date).map { Calendar.current.startOfDay(for: $0) })
        #expect(days.count >= 5)
    }

    @Test func existingKeys() throws {
        let (_, db) = try tempEditor()
        db.upsert(item("e1", date: Date()), cluster: nil)
        #expect(db.existing(["geeknews|e1", "geeknews|e2"]) == ["geeknews|e1"])
        #expect(db.articleCount(from: Date().addingTimeInterval(-3600), to: Date().addingTimeInterval(3600)) == 1)
    }

    // 지난 호 목록: 이번 주 · 지난주 · 그 앞은 달별(접힘). 주간 호는 그 주 묶음 맨 위, 빈 날 수
    @Test func archiveGroupsByWeekAndMonth() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        cal.firstWeekday = 1
        let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd HH:mm"
        let now = f.date(from: "2026-10-22 09:00")!         // 목요일 · 이번 주 10-18(일)~
        func day(_ s: String) -> Date { f.date(from: s + " 00:00")! }
        let weekly = Dropcap.Issue(id: "weekly-x", kind: .weekly, date: day("2026-10-18"), from: day("2026-10-11"), to: day("2026-10-18"),
                                   cover: nil, sections: [], count: 50)
        let issues = Magazine.archiveOrder([daily(day("2026-10-21")), daily(day("2026-10-19")),          // 이번 주(10-18·20 비어 있음)
                                            weekly, daily(day("2026-10-16")), daily(day("2026-10-12")),  // 지난주(11·13·14·15·17 비어 있음)
                                            daily(day("2026-09-30"), count: 2), daily(day("2026-09-28"))])
        let g = Magazine.archiveGroups(issues, now: now, cal: cal)
        #expect(g.map(\.title) == ["이번 주", "지난주", "2026년 9월"])
        #expect(g[0].issues.map(\.id) == ["daily-2026-10-21", "daily-2026-10-19"])
        #expect(g[0].emptyDays == 2)                           // 18(일)·20(화)
        #expect(g[1].issues.first?.id == "weekly-x")           // 주간은 그 주 묶음 맨 위
        #expect(g[1].emptyDays == 5)                           // 11·13·14·15·17(첫 기록 9-28 뒤라 빈 날로 셈)
        #expect(!g[0].folded && !g[1].folded && g[2].folded)   // 이전 달은 접힘
        #expect(g[2].emptyDays == 1)                           // 9-29 (첫 기록 9-28부터 셈)
    }

    @Test func lastCheckText() {
        let now = Date()
        #expect(Magazine.lastCheckText(nil, now: now) == "아직 확인 전")
        #expect(Magazine.lastCheckText(now.addingTimeInterval(-20), now: now) == "마지막 확인 방금")
        #expect(Magazine.lastCheckText(now.addingTimeInterval(-7 * 60), now: now) == "마지막 확인 7분 전")
        #expect(Magazine.lastCheckText(now.addingTimeInterval(-3 * 3600), now: now) == "마지막 확인 3시간 전")
    }

    @Test func thinReasonExplains() {
        let thin = daily(Date(), count: 2)
        #expect(Magazine.thinReason(thin)?.contains("2건") == true)
        #expect(Magazine.thinReason(daily(Date(), count: 40)) == nil)
    }
}
