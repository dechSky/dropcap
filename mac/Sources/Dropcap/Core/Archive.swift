import Foundation

// 지난 기사 보관함: 기사 기록(items)은 최근 2만 건만 남기고, 그보다 오래된 기사는 가벼운 보관 표(archive)로 옮긴다
// (날짜·제목·한국어 제목·링크·출처·분야·스토리 — 사진·요약·본문 없음). 보관 표는 설정의 '보관 기간'이 지난 달부터 지운다.
// 보관함 화면·검색은 아직 items 에 있는 최근 기사와 보관 표를 같은 꼴(ArchivedItem)로 합쳐 보여 준다.
struct ArchivedItem: Hashable, Identifiable, Sendable {
    var date: Date
    var title: String
    var titleKo: String?
    var link: String
    var source: String      // 출처 이름(옮긴 뒤 구독을 끊어도 보이게 이름으로 둔다)
    var section: String     // 분야 id(Sections)
    var story: String?      // 여러 곳이 다룬 스토리 id(한 곳뿐이면 nil)
    var sourceId: String? = nil // 출처 id(숨긴 출처 거르기 — 먼저 만든 판의 줄은 nil)

    var id: String { link + "|" + String(date.timeIntervalSince1970) }
    var displayTitle: String { titleKo ?? title }

    // 읽기 창으로 열 때 쓰는 기사(본문은 링크에서 다시 받는다)
    var newsItem: NewsItem {
        NewsItem(id: link, title: title, titleKo: titleKo, link: link, date: date, summary: "", sourceId: sourceId ?? "archive", sourceName: source, tier: "")
    }
}

enum Archive {
    // 설정 '보관 기간'(년). 0 은 끝없이
    static let defaultYears = 2
    static let choices = [1, 2, 5, 0]
    static func label(_ years: Int) -> String { years == 0 ? "끝없이" : "\(years)년" }
    static func clampYears(_ y: Int) -> Int { choices.contains(y) ? y : defaultYears }
    // 설정 '보관 기간' 아래 안내(세 판 같은 글)
    static func settingsNote(_ years: Int) -> String {
        let head = "최근 기사 2만 건보다 오래된 기사는 날짜·제목·링크·출처만 남겨 매거진 '보관함'에 옮깁니다(1년에 약 120MB)."
        return years == 0 ? head + " 끝없이 두면 해마다 약 120MB씩 늘고(500만 건에서 가장 오래된 것부터 지움) 검색도 조금씩 느려집니다."
            : head + " 보관 기간이 지나면 가장 오래된 달부터 지웁니다."
    }

    // 숨긴·끈·해지한 출처(기존 매거진 검색과 같은 SourceFilter) + 출처 id 가 없는 줄을 거를 숨긴 출처 이름
    struct Hide: Sendable {
        var filter = SourceFilter()
        var hiddenNames: Set<String> = []
    }

    // 검색어 상한(LIKE 패턴 상한·빠르게 고쳐 칠 때 긴 훑기가 줄 서지 않게)
    static let queryLimit = 200
    static func trimQuery(_ q: String) -> String { String(q.prefix(queryLimit)) }

    // 이 때보다 이른 보관 기사는 지운다: years 년 전이 든 달의 첫날(달 단위로 — 오래된 달부터 통째로). 0 이면 nil(지우지 않음)
    static func cutoff(years: Int, now: Date, cal: Calendar = .current) -> Date? {
        guard years > 0, let back = cal.date(byAdding: .year, value: -years, to: now) else { return nil }
        return cal.dateInterval(of: .month, for: back)?.start
    }

    // MARK: 기간
    enum Period: String, CaseIterable, Identifiable, Sendable {
        case day, week, month, year
        var id: String { rawValue }
        var label: String { ["day": "일", "week": "주", "month": "월", "year": "연"][rawValue]! }
        // 날짜별 건수 막대를 목록 앞에 보이는 기간
        var showsBars: Bool { self == .month || self == .year }
    }

    // anchor 가 든 기간 [from, to)
    static func range(_ p: Period, containing anchor: Date, cal: Calendar = .current) -> (from: Date, to: Date) {
        switch p {
        case .day:
            let d = cal.startOfDay(for: anchor)
            return (d, cal.date(byAdding: .day, value: 1, to: d) ?? d.addingTimeInterval(86400))
        case .week:
            return Magazine.weekRange(containing: anchor, cal: cal)
        case .month, .year:
            let i = cal.dateInterval(of: p == .month ? .month : .year, for: anchor) ?? DateInterval(start: cal.startOfDay(for: anchor), duration: 86400)
            return (i.start, i.end)
        }
    }

    // ◀ ▶: 한 기간 앞뒤로
    static func shift(_ p: Period, _ anchor: Date, by n: Int, cal: Calendar = .current) -> Date {
        let unit: Calendar.Component = [.day: .day, .week: .weekOfYear, .month: .month, .year: .year][p]!
        return cal.date(byAdding: unit, value: n, to: range(p, containing: anchor, cal: cal).from) ?? anchor
    }

    // 머리 이름: 2026년 10월 19일(월) · 2026년 10월 13일 주 · 2026년 10월 · 2026년
    static func title(_ p: Period, _ anchor: Date, cal: Calendar = .current) -> String {
        let r = range(p, containing: anchor, cal: cal)
        let c = cal.dateComponents([.year, .month, .day, .weekday], from: r.from)
        let y = c.year ?? 0, m = c.month ?? 0, d = c.day ?? 0
        switch p {
        case .day: return "\(y)년 \(m)월 \(d)일(\(["일", "월", "화", "수", "목", "금", "토"][((c.weekday ?? 1) - 1) % 7]))"
        case .week:
            let last = cal.dateComponents([.month, .day], from: r.to.addingTimeInterval(-1))
            return "\(y)년 \(m)월 \(d)일 – \(last.month ?? 0)월 \(last.day ?? 0)일"
        case .month: return "\(y)년 \(m)월"
        case .year: return "\(y)년"
        }
    }

    // 날 열쇠(이 Mac 의 날 'YYYY-MM-DD' — SQLite date(...,'localtime') 와 같은 꼴)
    static func dayKey(_ d: Date, cal: Calendar = .current) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // 기간의 날들(막대 순서)
    static func days(_ from: Date, _ to: Date, cal: Calendar = .current) -> [Date] {
        var out: [Date] = [], d = cal.startOfDay(for: from)
        while d < to {
            out.append(d)
            guard let n = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = n
        }
        return out
    }

    // 보관함 한 기간의 화면 재료
    struct Page: Sendable {
        var items: [ArchivedItem] = []      // 최신순, 앞 limit 건
        var more = false                    // 더 있음(더 보기)
        var dayCounts: [String: Int] = [:]  // 날 열쇠 → 건수(거른 뒤)
        var sections: [String: Int] = [:]   // 분야 → 건수(거르기 전 — 메뉴)
        var sources: [String: Int] = [:]    // 출처 → 건수(거르기 전 — 메뉴)
        var total = 0                       // 거른 뒤 전체 건수
    }

    // 최근 기사와 보관 기사 합치기: 같은 링크는 한 번(최근 쪽 — 한 출처의 두 피드에 같은 기사가 실린 것도), 최신순
    static func merge(recent: [ArchivedItem], archived: [ArchivedItem]) -> [ArchivedItem] {
        var seen = Set<String>()
        var out: [ArchivedItem] = []
        for a in recent + archived where seen.insert(a.link).inserted { out.append(a) }
        return out.sorted { $0.date > $1.date }
    }

    // 분야·출처로 거르기(nil 이면 모두)
    static func filter(_ items: [ArchivedItem], section: String?, source: String?) -> [ArchivedItem] {
        items.filter { (section == nil || $0.section == section) && (source == nil || $0.source == source) }
    }

    // 날짜별 건수 더하기
    static func dayCounts(_ items: [ArchivedItem], cal: Calendar = .current) -> [String: Int] {
        var out: [String: Int] = [:]
        for i in items { out[dayKey(i.date, cal: cal), default: 0] += 1 }
        return out
    }
}

// 보관함·오래된 기사 검색 읽기. 편집(Editor 액터)이 기사를 받아 넣는 동안에도 줄 서지 않게 따로 둔다(DB 는 자기 줄로 지켜짐)
final class ArchiveReader: @unchecked Sendable {
    static let shared = ArchiveReader()
    private let db: Database
    private let lock = NSLock()
    // 최근 기사의 분야(key → 분야): 기간을 넘길 때마다 수만 건을 다시 가르지 않게 기억해 둔다
    private var sectionMemo: [String: String] = [:]

    init(db: Database = .shared) { self.db = db }

    // 보관 표 검색(최신순 limit 건씩 — 더 보기는 offset)
    func searchArchive(_ q: String, limit: Int = 200, offset: Int = 0, hide: Archive.Hide = .init()) -> [ArchivedItem] {
        db.searchArchive(q, limit: limit, offset: offset, hide: hide)
    }

    // 보관함 한 기간: 아직 items 에 있는 최근 기사(가벼운 꼴) + 보관 표(분야·출처로 거름). limit 은 보관 표에서 꺼낼 수

    func archivePeriod(from: Date, to: Date, section: String?, source: String?, limit: Int, hide: Archive.Hide = .init()) -> Archive.Page {
        lock.lock()
        var memo = sectionMemo.count > 60000 ? [:] : sectionMemo
        lock.unlock()
        let recent = db.recentLight(from: from, to: to, filter: hide.filter) { it in
            if let s = memo[it.key] { return s }
            let s = Sections.primary(it)
            memo[it.key] = s
            return s
        }
        lock.lock(); sectionMemo = memo; lock.unlock()
        var counts = Archive.dayCounts(Archive.filter(recent, section: section, source: source))
        for (d, n) in db.archiveDayCounts(from: from, to: to, section: section, source: source, hide: hide) { counts[d, default: 0] += n }
        let facets = db.archiveFacets(from: from, to: to, hide: hide)
        var sections = facets.sections, sources = facets.sources
        for r in recent { sections[r.section, default: 0] += 1; sources[r.source, default: 0] += 1 }
        let shown = Archive.filter(recent, section: section, source: source)
        // 보관 기사는 최근 기사보다 이르므로 limit+1 건만 꺼내 합쳐도 앞 limit 건이 맞다(+1 은 '더 보기'가 있는지)
        let older = shown.count > limit ? [] : db.archived(from: from, to: to, section: section, source: source, hide: hide, limit: limit - shown.count + 1)
        let items = Archive.merge(recent: shown, archived: older)
        return Archive.Page(items: Array(items.prefix(limit)), more: items.count > limit,
                            dayCounts: counts, sections: sections, sources: sources, total: counts.values.reduce(0, +))
    }
    func earliestRecord() -> Date? { db.earliestRecord() }
}
