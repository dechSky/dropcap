import Foundation

// 같은 소식 판단을 한 곳에(R-4). 알림 목록 묶기('외 N곳')와 매거진 스토리 배정이 모두 여기를 쓴다.
// 기준은 StoryMatch 그대로: 다른 출처이고, 원제목 또는 한국어 제목 낱말이 많이 겹치거나,
// 영어 제목의 뜻 거리가 0.88 미만이거나, 1.07 미만이면서 고유명사를 함께 쓰면 같은 소식.

// 기사 하나에서 비교에 쓰는 것을 미리 계산해 둔다(쌍마다 낱말을 다시 나누지 않게 — 스토리 수천 개와 비교할 때 이것이 대부분이었다)
struct StoryKey: Sendable {
    let sourceId: String
    let tokens: Set<String>       // 원제목 낱말
    let tokensKo: Set<String>     // 한국어 제목(없으면 원제목) 낱말
    let english: String?          // 뜻 비교용 영어 제목

    init(_ it: NewsItem) {
        sourceId = it.sourceId
        tokens = StoryMatch.tokens(it.title)
        tokensKo = it.titleKo.map(StoryMatch.tokens) ?? tokens
        english = it.titleEn ?? (Translator.looksForeign(it.title) ? it.title : nil)
    }
}

enum StoryGrouper {
    static func same(_ a: StoryKey, _ b: StoryKey) -> Bool {
        guard a.sourceId != b.sourceId else { return false } // 한 곳이 같은 소식을 두 번 내는 일은 드물다
        if StoryMatch.similar(a.tokens, b.tokens) { return true }
        if StoryMatch.similar(a.tokensKo, b.tokensKo) { return true }
        guard let ea = a.english, let eb = b.english, let d = StoryMatch.meaningDistance(ea, eb) else { return false }
        if d < 0.88 { return true } // 뜻만으로 같다고 볼 때는 엄격하게
        return d < 1.07 && !StoryMatch.entities(ea).isDisjoint(with: StoryMatch.entities(eb))
    }

    static func firstMatch(_ k: StoryKey, in keys: [StoryKey]) -> Int? { keys.firstIndex { same(k, $0) } }

    // 알림 목록용: 이번에 들어온 소식을 공식 발표 > 언론 > 국내, 그다음 최신 순으로 보며
    // ① 이번 묶음 안에 같은 소식이 있으면 그 대표에 '외 N곳'으로 붙이고
    // ② 36시간 안의 최근 목록에 같은 소식이 있으면 알리지 않고 그 소식에 출처만 더한다(이미 있는 이름·같은 출처는 빼고).
    // 돌려주는 것: 남길 소식(최신 순)과 최근 목록의 칸 → 더할 출처 이름
    static func groupForList(_ items: [NewsItem], recent: [NewsItem], now: Date = Date()) -> (kept: [NewsItem], recentAdds: [Int: [String]]) {
        let rank = ["lab": 0, "press": 1, "kr": 2]
        let sorted = items.sorted { (rank[$0.tier] ?? 3, $1.date ?? .distantPast) < (rank[$1.tier] ?? 3, $0.date ?? .distantPast) }
        let cutoff = now.addingTimeInterval(-36 * 3600)
        let recentKeys = recent.map { ($0.date ?? .distantPast) > cutoff ? StoryKey($0) : nil }
        var kept: [NewsItem] = [], keptKeys: [StoryKey] = []
        var adds: [Int: [String]] = [:]
        for it in sorted {
            let k = StoryKey(it)
            if let i = firstMatch(k, in: keptKeys) {
                kept[i].related = (kept[i].related ?? []) + [it.sourceName]
                continue
            }
            if let j = recentKeys.firstIndex(where: { $0.map { same(k, $0) } ?? false }) {
                let already = (recent[j].related ?? []) + (adds[j] ?? [])
                if !already.contains(it.sourceName), recent[j].sourceName != it.sourceName { adds[j, default: []].append(it.sourceName) }
                continue
            }
            kept.append(it)
            keptKeys.append(k)
        }
        return (kept.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }, adds)
    }

    // 매거진 스토리 배정: 스토리의 대표 기사들(최근 것 먼저) 가운데 처음으로 같은 소식인 스토리
    static func storyFor(_ k: StoryKey, representatives: [(id: String, key: StoryKey)]) -> String? {
        representatives.first { same(k, $0.key) }?.id
    }
}
