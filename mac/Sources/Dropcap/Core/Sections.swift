import Foundation
import SwiftUI

// 분야(정치·경제·…·AI). shared/categories.json 을 읽고, 없으면 같은 내용의 기본값을 쓴다.
// 지금의 NewsCategory(모델·연구·정책·투자·보안)는 AI 분야 안의 하위 칩으로 남는다.
struct NewsSection: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let symbol: String
    let color: String
    var flow: Bool? = nil   // 분야가 아니라 흐름(주요 뉴스)
    var more: Bool? = nil   // 처음 고르기 화면의 '더 보기'

    var isFlow: Bool { flow == true }
    var isMore: Bool { more == true }
    var tint: Color { Color(hex: color) }
}

// sources.json 출처 항목의 분야 관련 필드(Source 구조체와 따로 읽어, 출처 자료 쪽 작업과 겹치지 않게)
struct SourceMeta: Decodable, Hashable {
    let id: String
    var section: String? = nil
    var lang: String? = nil
    var region: String? = nil   // kr · intl
    var tier: String? = nil
    var defaultOn: Bool? = nil
    var name: String? = nil
    var paywall: String? = nil  // hard · metered(유료 기사 표시)
}

enum Sections {
    static let top = "top", ai = "ai"

    static let builtin: [NewsSection] = [
        .init(id: "top", name: "주요 뉴스", symbol: "star.fill", color: "#FF9F0A", flow: true),
        .init(id: "politics", name: "정치", symbol: "building.columns", color: "#5E5CE6"),
        .init(id: "economy", name: "경제", symbol: "chart.line.uptrend.xyaxis", color: "#30C759"),
        .init(id: "society", name: "사회", symbol: "person.3", color: "#FF6B35"),
        .init(id: "world", name: "국제", symbol: "globe.asia.australia", color: "#0A84FF"),
        .init(id: "tech", name: "IT", symbol: "desktopcomputer", color: "#64D2FF"),
        .init(id: "ai", name: "AI", symbol: "sparkles", color: "#BF5AF2"),
        .init(id: "science", name: "과학", symbol: "atom", color: "#32ADE6"),
        .init(id: "life", name: "생활·건강", symbol: "heart.text.square", color: "#FF375F"),
        .init(id: "culture", name: "문화·연예", symbol: "theatermasks", color: "#FFD60A"),
        .init(id: "sports", name: "스포츠", symbol: "sportscourt", color: "#34C759"),
        .init(id: "climate", name: "기후·환경", symbol: "leaf", color: "#30D158", more: true),
    ]

    private struct File: Decodable { let sections: [NewsSection] }
    private struct SourcesFile: Decodable { let sources: [SourceMeta] }

    static func load(_ url: URL) -> [NewsSection]? {
        guard let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: d), !f.sections.isEmpty else { return nil }
        return f.sections
    }
    static func loadMeta(_ url: URL) -> [String: SourceMeta] {
        guard let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(SourcesFile.self, from: d) else { return [:] }
        return Dictionary(f.sources.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    static let all: [NewsSection] = load(Resources.url("categories.json")) ?? builtin
    static let meta: [String: SourceMeta] = loadMeta(Resources.url("sources.json"))

    static func byID(_ id: String?) -> NewsSection? { id.flatMap { i in all.first { $0.id == i } } }
    static func name(_ id: String) -> String { byID(id)?.name ?? id }
    static func order(_ id: String) -> Int { all.firstIndex { $0.id == id } ?? 99 }
    /// 처음 고르기 화면에 보이는 분야(흐름 제외)
    static var pickable: [NewsSection] { all.filter { !$0.isFlow } }

    // 출처의 분야: sources.json 의 section → 없으면(예전 판 sources.json·추천 채널) AI 시절 출처이므로 ai.
    // 사용자가 주소로 직접 추가한 출처는 모른다(nil) → 기사 낱말로 정한다.
    static func section(ofSource id: String, meta m: [String: SourceMeta] = meta) -> String? {
        if let s = m[id]?.section { return s }
        if m[id] != nil || id.hasPrefix("cat-") { return ai }
        return nil
    }
    static func region(ofSource id: String, tier: String, meta m: [String: SourceMeta] = meta) -> String {
        m[id]?.region ?? (tier == "kr" ? "kr" : "intl")
    }
    static func sources(in section: String, meta m: [String: SourceMeta] = meta) -> [SourceMeta] {
        m.values.filter { $0.section == section }.sorted { ($0.name ?? $0.id) < ($1.name ?? $1.id) }
    }

    // MARK: 기사의 분야
    // 대표 분야 하나 + 칩 여러 개. 출처의 분야가 1순위, 출처가 '주요'·모름이면 낱말 규칙으로 보충.
    // AI 는 다른 분야 글에서도 끌어온다(aiPattern).
    struct Placement: Hashable {
        var primary: String
        var chips: [String]
        var strong: String? = nil   // 출처 분야와 다른데 낱말이 강하게 걸린 분야(목록에 칩을 하나 더 보임)
    }

    static func place(_ it: NewsItem, meta m: [String: SourceMeta] = meta, aiRegex: NSRegularExpression? = Resources.aiRegex) -> Placement {
        let text = "\(it.title) \(it.titleKo ?? "") \(it.summary)"
        var primary = section(ofSource: it.sourceId, meta: m)
        if primary == nil || primary == top { primary = classify(text) ?? primary ?? top }
        var chips = [primary!]
        if primary != ai, let re = aiRegex, re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { chips.append(ai) }
        if primary != top, let g = classify(text), g != primary, !chips.contains(g), g != ai { chips.append(g) }
        // 출처 분야가 정한 대표와 달리 다른 분야 낱말이 2개 이상(그리고 대표 분야 낱말보다 많이) 걸리면 그 분야를 '강한' 칩으로
        var strong: String?
        if primary != top {
            let h = hits(text)
            if let best = h.filter({ $0.key != primary && $0.key != ai }).max(by: { ($0.value, -order($0.key)) < ($1.value, -order($1.key)) }),
               best.value >= 2, best.value > h[primary!] ?? 0 {
                strong = best.key
                if !chips.contains(best.key) { chips.append(best.key) }
            }
        }
        return Placement(primary: primary!, chips: chips, strong: strong)
    }

    nonisolated(unsafe) private static var cache: [String: Placement] = [:]
    private static let cacheLock = NSLock()
    static func cachedPlace(_ it: NewsItem) -> Placement {
        let k = it.key + "\u{1}" + (it.titleKo ?? "")
        cacheLock.lock()
        if let p = cache[k] { cacheLock.unlock(); return p }
        cacheLock.unlock()
        let p = place(it)
        cacheLock.lock()
        if cache.count > 20000 { cache.removeAll(keepingCapacity: true) }
        cache[k] = p
        cacheLock.unlock()
        return p
    }

    // '전체'·'주요' 피드에서 온 글의 분야를 낱말로 짐작한다. 앞에 있는 규칙이 먼저(성격이 뚜렷한 것부터).
    private static let rules: [(String, [String])] = [
        ("sports", ["야구", "축구", "농구", "배구", "골프", "올림픽", "월드컵", "kbo", "k리그", "프로야구", "홈런", "득점", "premier league", "nba", "nfl", "fifa", "olympic", "tournament", "championship"]),
        ("politics", ["대통령", "국회", "여당", "야당", "국민의힘", "민주당", "의원", "장관", "총리", "선거", "탄핵", "청와대", "대통령실", "북한", "국정", "president", "parliament", "congress", "senate", "election", "minister", "lawmakers", "white house"]),
        ("economy", ["증시", "코스피", "코스닥", "주가", "금리", "환율", "물가", "부동산", "아파트값", "수출", "기준금리", "한국은행", "실적", "매출", "영업이익", "stocks", "inflation", "interest rate", "fed", "earnings", "economy", "gdp", "tariff", "market"]),
        ("world", ["미국", "중국", "일본", "러시아", "우크라이나", "이스라엘", "유럽", "트럼프", "시진핑", "푸틴", "ukraine", "israel", "gaza", "china", "russia", "un "]),
        ("science", ["연구진", "우주", "nasa", "위성", "발사체", "유전자", "세포", "물리학", "천문", "scientists", "researchers", "space", "physics", "genome"]),
        ("life", ["건강", "질환", "병원", "환자", "치료", "백신", "다이어트", "여행", "날씨", "health", "disease", "hospital", "vaccine", "cancer"]),
        ("culture", ["영화", "드라마", "가수", "배우", "아이돌", "공연", "전시", "콘서트", "k팝", "케이팝", "film", "movie", "album", "concert", "actor", "box office"]),
        ("climate", ["기후", "탄소", "온실가스", "폭염", "climate", "carbon", "emissions"]),
        ("tech", ["스마트폰", "반도체", "앱 ", "애플", "삼성전자", "구글", "소프트웨어", "해킹", "iphone", "chip", "software", "apple", "google", "microsoft"]),
        ("society", ["경찰", "검찰", "법원", "재판", "사고", "화재", "사망", "교육", "학교", "노조", "police", "court", "trial"]),
    ]
    private static let compiled: [(String, NSRegularExpression?, [String])] = rules.map { sec, words in
        let english = words.filter { $0.range(of: "[가-힣]", options: .regularExpression) == nil } // 영어는 낱말 경계로, 한국어는 조사가 붙으므로 부분 일치
        let korean = words.filter { !english.contains($0) }
        let pattern = english.map { "\\b" + NSRegularExpression.escapedPattern(for: $0.trimmingCharacters(in: .whitespaces)) + "\\b" }.joined(separator: "|")
        return (sec, english.isEmpty ? nil : try? NSRegularExpression(pattern: pattern), korean)
    }
    // 분야마다 걸린 낱말 수(서로 다른 낱말)
    // 한국어 낱말은 글자 그대로(.literal) 찾는다 — 기본 contains 는 유니코드 동치까지 따져 6배쯤 느려, 기록이 많으면
    // 분야를 나누는 데만 화면이 몇 초씩 멈췄다(STABILITY.md S8). 글은 먼저 NFC 로 맞춰 결과는 같게
    static func normalized(_ text: String) -> String { text.lowercased().precomposedStringWithCanonicalMapping }
    static func hits(_ text: String) -> [String: Int] {
        let t = normalized(text)
        let r = NSRange(t.startIndex..., in: t)
        var out: [String: Int] = [:]
        for (sec, re, korean) in compiled {
            var found = Set<String>()
            re?.enumerateMatches(in: t, range: r) { m, _, _ in if let m, let rr = Range(m.range, in: t) { found.insert(String(t[rr])) } }
            for k in korean where t.range(of: k, options: .literal) != nil { found.insert(k) }
            if !found.isEmpty { out[sec] = found.count }
        }
        return out
    }

    static func classify(_ text: String) -> String? {
        let t = normalized(text)
        let r = NSRange(t.startIndex..., in: t)
        for (sec, re, korean) in compiled {
            if re?.firstMatch(in: t, range: r) != nil || korean.contains(where: { t.range(of: $0, options: .literal) != nil }) { return sec }
        }
        return nil
    }
}

extension NewsItem {
    /// 대표 분야 id
    var section: String { Sections.cachedPlace(self).primary }
    /// 이 기사에 다는 분야 칩(대표 포함)
    var sectionChips: [String] { Sections.cachedPlace(self).chips }
    func inSection(_ id: String) -> Bool { sectionChips.contains(id) }
    /// 대표 분야 말고 낱말로 강하게 걸린 분야(목록에 칩을 하나 더)
    var extraTopic: String? { Sections.cachedPlace(self).strong }
}

// 화면에 보이는 '분야' 표시: AI 분야 글은 그 안의 하위 분류(모델·연구…)까지, 나머지는 분야 이름
extension NewsItem {
    var topicLabel: String { section == Sections.ai ? "AI·" + category.label : Sections.name(section) }
    var topicSymbol: String { section == Sections.ai ? category.symbol : (Sections.byID(section)?.symbol ?? "circle") }
    var topicColor: Color { section == Sections.ai ? category.color : (Sections.byID(section)?.tint ?? .gray) }
}
