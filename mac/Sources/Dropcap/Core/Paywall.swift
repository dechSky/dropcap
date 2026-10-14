import Foundation

// 유료 기사 표시(G-14)와 같은 소식의 무료 보도 안내(D-9).
// ① sources.json 의 paywall(hard·metered) ② 직접 추가한 출처는 주소의 도메인(알려진 곳) ③ 사용자가 연 기사의 본문 추리기 결과를
// 출처별로 쌓아 실패율이 높으면 '막힌 곳'으로 배운다. 원문 링크는 언제나 남긴다.
enum PaywallKind: String, Equatable, Sendable {
    case hard      // 구독해야만 읽힘
    case metered   // 한 달 몇 건까지 무료
    case learned   // 표시는 없지만 여기서 열어 보면 자주 막힘

    var label: String {
        switch self {
        case .hard: return "유료 기사"
        case .metered: return "일부 유료(무료 건수 제한)"
        case .learned: return "자주 막히는 곳"
        }
    }
    var symbol: String { self == .metered ? "lock.open" : "lock.fill" }
    // 열기 전에 다른 보도를 먼저 권할 만큼 막히는가
    var blocks: Bool { self != .metered }
}

enum Paywall {
    // sources.json 에 없는(직접 추가한) 출처도 알아보게: 널리 알려진 유료 매체
    static let knownDomains: [String: PaywallKind] = [
        "ft.com": .hard, "economist.com": .hard, "wsj.com": .hard, "bloomberg.com": .hard, "barrons.com": .hard,
        "thetimes.co.uk": .hard, "thetimes.com": .hard, "theinformation.com": .hard, "nikkei.com": .hard, "asia.nikkei.com": .hard,
        "nytimes.com": .metered, "washingtonpost.com": .metered, "theatlantic.com": .metered, "newyorker.com": .metered,
        "wired.com": .metered, "marketwatch.com": .metered, "telegraph.co.uk": .metered, "newscientist.com": .metered,
        "statnews.com": .metered, "businessinsider.com": .metered, "foreignpolicy.com": .metered, "hbr.org": .metered,
    ]

    // 배워서 '막히는 곳'으로 보는 기준: 5번 이상 열었고 60% 넘게 막힘
    static let learnMinTries = 5
    static let learnFailRate = 0.6

    static func domainKind(_ link: String) -> PaywallKind? {
        guard var host = URL(string: link)?.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        // 하위 도메인(edition.ft.com 등)은 뒤에서부터 맞춰 본다
        var parts = host.split(separator: ".")
        while parts.count >= 2 {
            if let k = knownDomains[parts.joined(separator: ".")] { return k }
            parts.removeFirst()
        }
        return nil
    }

    static func kind(sourceId: String, link: String, meta: [String: SourceMeta] = Sections.meta,
                     stats: [String: Database.ExtractStat] = [:]) -> PaywallKind? {
        if let p = meta[sourceId]?.paywall { return PaywallKind(rawValue: p) }
        if let k = domainKind(link) { return k }
        if let s = stats[sourceId], s.tries >= learnMinTries, s.failRate >= learnFailRate { return .learned }
        return nil
    }

    // 본문은 추렸지만 맛보기만 나오고 구독을 권하는 글(유료벽 뒤)인가
    static let wallPhrases = ["subscribe to continue", "subscribe to read", "subscribers only", "subscriber-only", "to continue reading",
                              "sign in to continue", "already a subscriber", "create a free account to continue", "this article is for subscribers",
                              "unlock this article", "become a member to read", "유료 회원", "구독자 전용", "로그인 후 이용", "유료 기사", "프리미엄 회원"]
    static func looksBlocked(_ blocks: [Block]) -> Bool {
        let texts = blocks.compactMap(\.text)
        let length = texts.reduce(0) { $0 + $1.count }
        guard length < 1500 else { return false } // 본문이 충분하면 끝의 구독 안내 문구는 무시
        let lower = texts.joined(separator: " ").lowercased()
        return wallPhrases.contains { lower.contains($0) }
    }

    // 같은 소식 중 열리는 보도: 유료가 아니고(배운 막힘 포함), 숨긴 출처가 아니고, 자기 자신이 아닌 것. 공식 발표 > 국내 > 언론, 최신 순
    static func freeAlternatives(_ item: NewsItem, story: [NewsItem], hidden: Set<String>,
                                 meta: [String: SourceMeta] = Sections.meta, stats: [String: Database.ExtractStat] = [:],
                                 limit: Int = 3) -> [NewsItem] {
        let rank = ["lab": 0, "kr": 1, "press": 2]
        var seenSources: Set<String> = [item.sourceId]
        return story
            .filter { $0.key != item.key && !hidden.contains($0.sourceId) && !$0.link.isEmpty && $0.itemKind == .article
                && kind(sourceId: $0.sourceId, link: $0.link, meta: meta, stats: stats) == nil }
            .sorted { (rank[$0.tier] ?? 3, -($0.date?.timeIntervalSince1970 ?? 0)) < (rank[$1.tier] ?? 3, -($1.date?.timeIntervalSince1970 ?? 0)) }
            .filter { seenSources.insert($0.sourceId).inserted }
            .prefix(limit).map { $0 }
    }
}

// 앱 안에서 쓰는 쪽: 출처별 기록을 기억해 두고 화면(자물쇠)·읽기 창(무료 보도 권하기)에 알려 준다
@MainActor
final class PaywallBook {
    static let shared = PaywallBook()
    private let db: Database
    private(set) var stats: [String: Database.ExtractStat]

    init(db: Database = .shared) {
        self.db = db
        stats = db.extractStats()
    }

    func kind(_ item: NewsItem) -> PaywallKind? {
        guard item.itemKind == .article, !item.link.isEmpty else { return nil }
        return Paywall.kind(sourceId: item.sourceId, link: item.link, stats: stats)
    }

    // 사용자가 연 기사의 결과(미리 받기는 스크립트 없이 해서 실패가 잦으므로 세지 않는다)
    func record(_ item: NewsItem, failed: Bool, blocked: Bool) {
        guard item.id != AppModel.previewID, !item.sourceId.isEmpty else { return }
        db.recordExtract(source: item.sourceId, failed: failed, blocked: blocked)
        stats = db.extractStats()
    }

    // 같은 스토리에서 무료로 읽을 수 있는 보도
    func alternatives(_ item: NewsItem) -> [NewsItem] {
        guard let c = Magazine.shared.clusterID(of: item.key) else { return [] }
        return Paywall.freeAlternatives(item, story: Magazine.shared.storyItems(c), hidden: Set(AppModel.shared.state.hiddenSources), stats: stats) // storyItems 가 꺼진 출처를 이미 뺌
    }
}
