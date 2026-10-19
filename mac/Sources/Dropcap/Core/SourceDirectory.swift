import Foundation

// 설정 › 구독의 출처 목록 정리: 찾기(이름·주소·분야·국내/해외) · 켠 것/끈 것 거르기 · 매체별/분야별/지역별 묶음 · 켠 출처 요약.
// 화면 없이 시험한다(SourceDirectoryTests). 윈도우(Dropcap.Core/SourceDirectory.cs)·리눅스(dropcap-core/src/source_directory.rs)도 같은 규칙.
enum SourceDirectory {
    static let layoutKey = "sourcesLayout" // 고른 보기(화면 설정, UserDefaults)
    enum Layout: String, CaseIterable, Identifiable {
        case media, section, region
        var id: String { rawValue }
        var label: String {
            switch self {
            case .media: return "매체별"
            case .section: return "분야별"
            case .region: return "지역별"
            }
        }
    }

    enum Status: String, CaseIterable, Identifiable {
        case all, on, off
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "전체"
            case .on: return "켠 것"
            case .off: return "끈 것"
            }
        }
    }

    // 한 묶음: 보이는 출처(거른 뒤)와 묶음 전체의 켠 수/전체 수
    struct Group: Identifiable, Equatable {
        let id: String        // media:yna · section:economy · region:kr
        let title: String
        let sources: [Source] // 거르고 정렬한 것(묶음 동작은 이것에만)
        let on: Int           // 묶음 전체에서 켠 수
        let total: Int        // 묶음 전체 수
    }

    static func regionLabel(_ s: Source) -> String { s.isDomestic ? "국내" : "해외" }

    // 매체 묶음 키: id 의 첫 '-' 앞(yna-market → yna, bbc-world → bbc). 기본 출처 id 가 이 규칙으로 지어져 있다
    static func mediaKey(_ s: Source) -> String {
        String(s.id.split(separator: "-", maxSplits: 1).first ?? Substring(s.id))
    }

    // 매체 이름: 모두 같은 이름이면 그 이름, 모두 같은 첫 낱말로 시작하면 그 낱말(연합뉴스·BBC),
    // 아니면 대표 피드(id 가 묶음 키 또는 '묶음 키-home')의 이름(nyt-home → The New York Times), 그것도 없으면 가장 짧은 이름
    static func mediaName(_ members: [Source]) -> String {
        let names = members.map(\.name)
        guard let first = names.first else { return "" }
        if Set(names).count == 1 { return first }
        let heads = names.map { String($0.split(separator: " ").first ?? "") }
        if let h = heads.first, !h.isEmpty, heads.allSatisfy({ $0 == h }) { return h }
        if let base = members.first(where: { $0.id == mediaKey($0) || $0.id == mediaKey($0) + "-home" }) { return base.name }
        return names.min { ($0.count, $0) < ($1.count, $1) } ?? first
    }

    // 묶음 안에서 보일 짧은 이름: 매체 이름을 떼고(연합뉴스 경제 → 경제), 떼면 비면 원래 이름
    static func shortName(_ s: Source, media: String) -> String {
        guard s.name.hasPrefix(media + " ") else { return s.name }
        let rest = s.name.dropFirst(media.count).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? s.name : rest
    }

    // 비교용: 소문자·띄어쓰기 없앰
    static func fold(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(String.init).joined()
    }

    static func matches(_ s: Source, query: String) -> Bool {
        let q = fold(query)
        if q.isEmpty { return true }
        let hay = [s.name, s.url, s.home ?? "", Sections.name(s.sectionID), regionLabel(s)]
        return hay.contains { fold($0).contains(q) }
    }

    static func filter(_ sources: [Source], query: String, status: Status, enabled: (String) -> Bool) -> [Source] {
        sources.filter { s in
            switch status {
            case .all: break
            case .on: if !enabled(s.id) { return false }
            case .off: if enabled(s.id) { return false }
            }
            return matches(s, query: query)
        }
    }

    // 정렬: 국내 먼저(가나다) 그다음 해외(ABC). 같은 이름은 id 순. 유니코드 순서라 세 판이 같다
    static func sortKey(_ name: String, domestic: Bool) -> (Int, String) { (domestic ? 0 : 1, name.lowercased()) }
    static func sorted(_ sources: [Source]) -> [Source] {
        sources.sorted { a, b in
            let ka = sortKey(a.name, domestic: a.isDomestic), kb = sortKey(b.name, domestic: b.isDomestic)
            return ka != kb ? ka < kb : a.id < b.id
        }
    }

    // all: 묶음 전체(켠 수 계산), shown: 거른 결과. 보이는 것이 없는 묶음은 뺀다
    static func groups(all: [Source], shown: [Source], layout: Layout, enabled: (String) -> Bool) -> [Group] {
        let visible = Set(shown.map(\.id))
        func make(_ id: String, _ title: String, _ members: [Source]) -> Group? {
            let list = sorted(members.filter { visible.contains($0.id) })
            guard !list.isEmpty else { return nil }
            return Group(id: id, title: title, sources: list, on: members.filter { enabled($0.id) }.count, total: members.count)
        }
        switch layout {
        case .media:
            let byKey = Dictionary(grouping: all, by: mediaKey)
            return byKey.compactMap { key, members in make("media:" + key, mediaName(members), members) }
                .sorted { a, b in
                    let da = a.sources[0].isDomestic, db = b.sources[0].isDomestic
                    let ka = sortKey(a.title, domestic: da), kb = sortKey(b.title, domestic: db)
                    return ka != kb ? ka < kb : a.id < b.id
                }
        case .section:
            let ids = Sections.all.map(\.id) + Set(all.map(\.sectionID)).subtracting(Sections.all.map(\.id)).sorted()
            return ids.compactMap { id in make("section:" + id, Sections.name(id), all.filter { $0.sectionID == id }) }
        case .region:
            return [make("region:kr", "국내", all.filter(\.isDomestic)), make("region:intl", "해외", all.filter { !$0.isDomestic })].compactMap { $0 }
        }
    }

    // 맨 위 요약: 켠 출처 수와 분야별 켠 수(분야 순서, 0 인 분야는 뺌)
    static func summary(_ sources: [Source], enabled: (String) -> Bool) -> (count: Int, bySection: [(id: String, name: String, count: Int)]) {
        let on = sources.filter { enabled($0.id) }
        let counts = Dictionary(grouping: on, by: \.sectionID).mapValues(\.count)
        let order = Sections.all.map(\.id) + counts.keys.filter { k in !Sections.all.contains { $0.id == k } }.sorted()
        return (on.count, order.compactMap { id in counts[id].map { (id, Sections.name(id), $0) } })
    }

    static func summaryText(_ sources: [Source], enabled: (String) -> Bool) -> String {
        let s = summary(sources, enabled: enabled)
        guard s.count > 0 else { return "켠 출처 없음" }
        return "켠 출처 \(s.count)곳 · " + s.bySection.map { "\($0.name) \($0.count)" }.joined(separator: " · ")
    }

    static func countText(shown: Int, total: Int) -> String { shown == total ? "\(total)곳" : "\(total)곳 중 \(shown)곳" }
}
