import Foundation
import Testing
@testable import Dropcap

// 매거진 왼쪽 목록 ↔ 오른쪽 화면이 같은 기준을 쓰는지(순서·범위·숫자·분야)
private func item(_ id: String, source: String, title: String, date: Date = Date(), image: String? = nil) -> NewsItem {
    var it = NewsItem(id: id, title: title, titleKo: nil, link: "https://\(source).example/\(id)", date: date,
                      summary: "", sourceId: source, sourceName: source, tier: "press")
    it.image = image
    return it
}

private func issue(_ id: String, _ kind: Dropcap.Issue.Kind, from: Date, to: Date, count: Int = 10, sections: [Dropcap.Issue.Section] = []) -> Dropcap.Issue {
    Dropcap.Issue(id: id, kind: kind, date: Date(), from: from, to: to, cover: nil, sections: sections, count: count)
}

@Suite struct SidebarRuleTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Seoul")!
        c.firstWeekday = 1 // 일요일 시작(한국 달력)
        return c
    }()
    func day(_ d: Int, _ h: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h))! }

    @Test func archiveIsNewestFirstWeeklyAtWeekEnd() {
        // 예전에 저장한 호는 DB 정렬 값이 모두 같아 13일 → 주간 → 10일 → 11일 → 12일로 섞였다
        let list = [
            issue("daily-13", .daily, from: day(12, 18), to: day(13, 18)),
            issue("weekly-W40", .weekly, from: day(4), to: day(11)),
            issue("daily-10", .daily, from: day(9, 18), to: day(10, 18)),
            issue("daily-11", .daily, from: day(10, 18), to: day(11, 18)),
            issue("daily-12", .daily, from: day(11, 18), to: day(12, 18)),
        ]
        #expect(Magazine.archiveOrder(list).map(\.id) == ["daily-13", "daily-12", "daily-11", "weekly-W40", "daily-10"])
    }

    @Test func weeksAreContiguousSevenDays() {
        let this = Magazine.weekRange(containing: day(14, 15), cal: cal)  // 수요일
        #expect(this.from == day(11))   // 일요일
        #expect(this.to == day(18))
        let last = Magazine.weekRange(containing: this.from.addingTimeInterval(-3600), cal: cal)
        #expect(last.from == day(4) && last.to == this.from) // 지난 주간과 겹치지 않고 이어짐
        #expect(last.to.timeIntervalSince(last.from) == 7 * 24 * 3600)
        // 지난 주간 이름: 끝 날짜는 토요일
        #expect(issue("w", .weekly, from: last.from, to: last.to).title.hasSuffix("10월 10일"))
    }

    @Test func subtitleMatchesWhatIsShown() {
        #expect(Magazine.subtitle(total: 192, shown: 17, sections: 2) == "소식 192건 중 17건 실음 · 분야 2개")
        #expect(Magazine.subtitle(total: 12, shown: 12, sections: 1) == "소식 12건 · 분야 1개")
        #expect(Magazine.subtitle(total: 40, shown: 13, sections: 0, noun: "IT 소식") == "IT 소식 40건 중 13건 실음")
    }

    @Test func oldLayoutIssuesAreRebuilt() {
        let old = issue("weekly-W40", .weekly, from: day(4), to: day(11), count: 2, sections: [.init(category: .model, keys: ["a"])])
        #expect(Magazine.needsRebuild(old))
        #expect(old.isThin)
        let now = issue("daily-13", .daily, from: day(12, 18), to: day(13, 18), sections: [
            .init(category: .other, keys: ["a"], section: "tech"), .init(category: .other, keys: ["b"]), .init(category: .other, keys: ["c"], kind: "video"),
        ])
        #expect(!Magazine.needsRebuild(now))
        #expect(!now.isThin)
    }

    @Test func storyTopicIsMajority() {
        // Apple HomeView: 대표 기사 하나가 AI 낱말에 걸려도 묶인 보도 다수가 IT 면 IT
        let items = [item("1", source: "a", title: "Apple HomeView ad"), item("2", source: "b", title: "Apple HomeView"), item("3", source: "c", title: "AI model in HomeView")]
        let place: (NewsItem) -> String = { $0.id == "3" ? Sections.ai : "tech" }
        let t = Magazine.storyTopic(items, place: place)
        #expect(t?.section == "tech" && t?.category == nil)
        // AI 다수면 그 안의 하위 분류도 다수결
        let ai = [item("1", source: "a", title: "Startup raises funding"), item("2", source: "b", title: "Investors back startup in funding round"),
                  item("3", source: "c", title: "New model launch")]
        let t2 = Magazine.storyTopic(ai, place: { _ in Sections.ai })
        #expect(t2?.section == Sections.ai && t2?.category == .business)
        #expect(Magazine.storyTopic([]) == nil)
    }

    @Test func recentSearches() {
        var l: [String] = []
        l = Magazine.rememberSearch("엔비디아", in: l)
        l = Magazine.rememberSearch("Apple", in: l)
        l = Magazine.rememberSearch(" apple ", in: l)
        l = Magazine.rememberSearch("a", in: l) // 한 글자는 남기지 않음
        #expect(l == ["apple", "엔비디아"])
        #expect(Magazine.rememberSearch("x9", in: (0..<8).map { "w\($0)" }).count == 8)
    }
}

// 편집(Editor): 분야 지면·주간 표지·예전 호 다시 엮기
@Suite(.serialized) struct SidebarEditorTests {
    func tempEditor() throws -> (Editor, Database) {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("dropcap-sidebar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let db = Database(file: d.appendingPathComponent("magazine.sqlite"))
        return (Editor(db: db), db)
    }

    @Test func sectionPageHasOnlyThatSection() async throws {
        let (ed, db) = try tempEditor()
        let now = Date()
        for i in 0..<5 { db.upsert(item("sb-t\(i)", source: "geeknews", title: "새 스마트폰 \(i)", date: now.addingTimeInterval(-Double(i) * 600)), cluster: nil) }
        for i in 0..<4 { db.upsert(item("sb-p\(i)", source: "yna-politics", title: "국회 \(i)", date: now.addingTimeInterval(-Double(i) * 600)), cluster: nil) }
        let page = await ed.makeIssue(kind: .daily, from: now.addingTimeInterval(-3600 * 5), to: now.addingTimeInterval(60), id: "s", ctx: EditContext(), only: "tech")
        #expect(page.count == 5)                     // 머리 숫자도 그 분야 기준
        #expect(page.sections.allSatisfy { $0.section == "tech" })
        #expect((page.cover.map { [$0] } ?? []).allSatisfy { $0.hasPrefix("geeknews|") })
        #expect(page.sections.flatMap(\.keys).count + (page.cover == nil ? 0 : 1) == 5)
    }

    @Test func weeklyCoverIsBiggestStory() async throws {
        let (ed, db) = try tempEditor()
        let now = Date()
        // 점수 높은 공식 발표 하나(혼자) vs 세 곳이 다룬 이야기
        var lab = item("sb-lab", source: "openai", title: "Introducing a new model", date: now.addingTimeInterval(-600))
        lab.tier = "lab"
        db.upsert(lab, cluster: nil)
        let c = Database.Cluster(id: "big", title: "big", tokens: [], first: now, last: now, size: 3)
        db.saveCluster(c)
        for (i, s) in ["geeknews", "bloter-all", "verge-all"].enumerated() {
            db.upsert(item("sb-b\(i)", source: s, title: "같은 이야기 \(i)", date: now.addingTimeInterval(-Double(i + 2) * 3600)), cluster: "big")
        }
        let w = await ed.makeIssue(kind: .weekly, from: now.addingTimeInterval(-86400), to: now.addingTimeInterval(60), id: "w", ctx: EditContext())
        #expect(w.cover?.contains("|sb-b") == true)
        let d = await ed.makeIssue(kind: .daily, from: now.addingTimeInterval(-86400), to: now.addingTimeInterval(60), id: "d", ctx: EditContext())
        #expect(d.cover == "openai|sb-lab")             // 오늘 호는 점수 순 그대로
    }

    @Test func publishDueRebuildsOldLayout() async throws {
        let (ed, db) = try tempEditor()
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: -20, to: cal.startOfDay(for: Date()))!
        for i in 0..<3 { db.upsert(item("sb-o\(i)", source: "geeknews", title: "스마트폰 \(i)", date: day.addingTimeInterval(Double(i + 1) * 3600)), cluster: nil) }
        let old = Dropcap.Issue(id: "daily-old", kind: .daily, date: day, from: day.addingTimeInterval(-6 * 3600), to: day.addingTimeInterval(18 * 3600),
                        cover: nil, sections: [.init(category: .model, keys: ["geeknews|sb-o0"])], count: 1)
        db.saveIssue(old)
        let list = await ed.publishDue(EditContext())
        let again = try #require(list.first { $0.id == "daily-old" })
        #expect(!Magazine.needsRebuild(again))
        #expect(again.count == 3)
    }
}
