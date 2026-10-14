import Foundation

// 오늘 호 완독(M-23 · D-11): 오늘 호의 대표 기사(표지 + 주요 뉴스·고른 분야마다 첫 줄)를 다 읽으면
// '오늘 호를 다 읽었어요'로 끝을 알리고 더 밀어 넣지 않는다.
enum TodayIssue {
    static let perSection = 3 // 지면 첫 줄(카드 세 장)

    // 대표 기사 key: 표지 → 주요 뉴스 지면 첫 줄 → 고른 분야 지면 첫 줄(분야 순서). 구독 채널 지면은 빼고, 겹치면 한 번만
    static func keys(cover: String?, sections: [(section: Issue.Section, items: [NewsItem])], chosen: [String]) -> [String] {
        var out: [String] = cover.map { [$0] } ?? []
        let pages = sections.filter { $0.section.kind == nil }
        let top = pages.filter { $0.section.section == Sections.top }
        let picked = pages.filter { s in s.section.section.map { $0 != Sections.top && chosen.contains($0) } ?? false }
        for p in top + picked {
            for it in p.items.prefix(perSection) where !out.contains(it.key) { out.append(it.key) }
        }
        return out
    }

    // 다음 호 안내: 아침 브리핑을 켰으면 그 시각, 아니면 '내일 아침'
    static func nextIssueText(digestEnabled: Bool, digestHour: Int) -> String {
        guard digestEnabled else { return "다음 호는 내일 아침에 엮여요" }
        let h = digestHour % 12 == 0 ? 12 : digestHour % 12
        return "다음 호는 내일 \(digestHour < 12 ? "오전" : "오후") \(h)시 브리핑으로 알려 드릴게요"
    }

    // 오늘 다 읽었다고 한 번 정해지면(사진·표지가 바뀌어 대표 기사가 달라져도) 그날은 끝난 호로 둔다
    static let doneKey = "todayIssueDone"
    static func isMarkedDone(_ defaults: UserDefaults = .standard, now: Date = Date()) -> Bool {
        defaults.string(forKey: doneKey) == Magazine.dayID(now)
    }
    static func markDone(_ defaults: UserDefaults = .standard, now: Date = Date()) {
        defaults.set(Magazine.dayID(now), forKey: doneKey)
    }
}
