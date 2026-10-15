import Foundation
import Testing
@testable import Dropcap

// 분야 지면을 앱 막 켠 직후 누르면 엮는 동안 빈 화면이던 것(mac-small-bugs 1)
@Suite @MainActor struct MagazineLoadingTests {
    private func resolved(_ id: String) -> Magazine.Resolved {
        let issue = Dropcap.Issue(id: id, kind: .daily, date: Date(), from: Date(), to: Date(), cover: nil, sections: [], count: 0)
        return Magazine.Resolved(issue: issue, cover: nil, sections: [])
    }

    // 한 번 엮은 지면은 다시 열 때 그 결과부터 보인다(지면마다 따로)
    @Test func reopenedPageStartsFromLastResult() {
        IssueCache.clear()
        #expect(IssueCache.get(.section("economy")) == nil) // 처음엔 엮은 것이 없음 → 엮는 중 표시
        IssueCache.put(.section("economy"), resolved("daily-econ"), revision: 7)
        IssueCache.put(.today, resolved("daily-today"), revision: 9)
        #expect(IssueCache.get(.section("economy"))?.data.issue.id == "daily-econ")
        #expect(IssueCache.get(.section("economy"))?.revision == 7)
        #expect(IssueCache.get(.section("world")) == nil)
        #expect(IssueCache.get(.today)?.data.issue.id == "daily-today")
        #expect(IssueCache.get(.week) == nil)
        IssueCache.clear()
    }

    // 엮는 동안은 빈 화면이 아니라 지면 이름과 진행 표시
    @Test func buildingPlaceholderNamesThePage() {
        let econ = Sections.all.first { !$0.isFlow }!
        #expect(IssueBuilding.title(.section(econ.id)) == econ.name)
        #expect(IssueBuilding.title(.today) == "오늘")
        #expect(IssueBuilding.message(preparing: false) == "지면을 엮는 중…")
        #expect(IssueBuilding.message(preparing: true) == "첫 호를 엮는 중…")
    }
}
