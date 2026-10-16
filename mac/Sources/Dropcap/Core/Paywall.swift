import Foundation

// 유료 기사 표시(G-14)와 같은 소식의 무료 보도 안내(D-9).
// ① sources.json 의 paywall(hard·metered) ② 직접 추가한 출처는 주소의 도메인(알려진 곳) ③ 사용자가 연 기사의 본문 추리기 결과를
// 출처별로 쌓아 실패율이 높으면 '막힌 곳'으로 배운다. 원문 링크는 언제나 남긴다.
enum PaywallKind: String, Equatable, Sendable {
    case hard      // 구독해야만 읽힘
    case metered   // 한 달 몇 건까지 무료
    case learned   // 표시는 없지만 여기서 열어 보면 자주 막힘
    case teaser    // 이 기사를 미리 받아 보니 맛보기(앞부분만)였음(Paywall.isTeaser) — 출처·피드 표시보다 앞선다

    var label: String {
        switch self {
        case .hard: return "유료 기사"
        case .metered: return "일부 유료(무료 건수 제한)"
        case .learned: return "자주 막히는 곳"
        case .teaser: return "앞부분만 공개된 기사"
        }
    }
    // 목록·카드에서 자물쇠 옆에 붙는 짧은 글(맛보기만 — 다른 자물쇠와 구분)
    var shortText: String? { self == .teaser ? "앞부분만" : nil }
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

    // paid: 피드가 이 기사에 적은 표시(NewsItem.paid) — 출처 값보다 앞선다. true 면 구독해야만(hard), false 면 무료로 풀린 기사
    // teaser: 이 기사를 받아 보니 맛보기였음(PaywallBook.teasers) — 무엇보다 앞선다
    static func kind(sourceId: String, link: String, paid: Bool? = nil, teaser: Bool = false, meta: [String: SourceMeta] = Sections.meta,
                     stats: [String: Database.ExtractStat] = [:]) -> PaywallKind? {
        if teaser { return .teaser }
        if let paid { return paid ? .hard : nil }
        if let p = meta[sourceId]?.paywall { return PaywallKind(rawValue: p) }
        if let k = domainKind(link) { return k }
        if let s = stats[sourceId], s.tries >= learnMinTries, s.failRate >= learnFailRate { return .learned }
        return nil
    }

    // 본문은 추렸지만 맛보기만 나오고 구독을 권하는 글(유료벽 뒤)인가
    static let wallPhrases = ["subscribe to continue", "subscribe to read", "subscribers only", "subscriber-only", "to continue reading",
                              "sign in to continue", "already a subscriber", "create a free account to continue", "this article is for subscribers",
                              "unlock this article", "become a member to read", "유료 회원", "구독자 전용", "로그인 후 이용", "유료 기사", "프리미엄 회원"]
    // 길이와 상관없이 맛보기로 보는 강한 문구(STAT+ 맛보기는 구독 권유 줄까지 1,500자를 넘는다)
    static let strongWall = #"(?i)exclusive (?:to|for) [^.]{0,30}subscribers|read the rest of this (?:story|article)|this article is for (?:paid )?subscribers|unlock this article|구독자 전용|유료 회원 전용|한경 프리미엄9?의 모든 콘텐츠"#

    // 맛보기(유료벽 뒤 앞부분만)인가 — READER-CUT.md C. 지금의 문구 판정에 더해
    // 사이트가 유료라고 적었고(isAccessibleForFree=false · 한경 articlePayment) 본문이 1,500자 미만, 하드 유료 출처인데 2,500자 미만, 끝쪽에 강한 문구
    // ldBody: 사이트가 ld+json articleBody 로 적은 본문 글자 수. 우리 본문과 거의 같으면(±10%) 그 길이가 기사 전부다 —
    // 늘 isAccessibleForFree=false 라고 적지만 전문을 주는 사이트(Verge)의 짧은 기사를 맛보기로 잘못 보지 않게 '유료+1,500자' 규칙을 쓰지 않는다
    // (하드 유료 2,500자·강한 문구·구독 권유 문구 판정은 그대로)
    static let ldBodySlack = 0.1
    static func matchesSiteBody(_ length: Int, ldBody: Int?) -> Bool {
        guard let ldBody, ldBody > 0 else { return false }
        return abs(Double(length - ldBody)) <= Double(ldBody) * ldBodySlack
    }

    static func isTeaser(_ blocks: [Block], paid: Bool?, kind: PaywallKind?, ldBody: Int? = nil) -> Bool {
        if looksBlocked(blocks) { return true }
        let texts = blocks.compactMap { $0.original ?? $0.text }
        let length = texts.reduce(0) { $0 + $1.count }
        if texts.suffix(4).joined(separator: " ").range(of: strongWall, options: .regularExpression) != nil { return true }
        // ld 본문과는 군더더기(기자 소개·'Follow topics…')를 뺀 길이로도 견준다(Verge: 뺀 뒤 899자 = ld 902자)
        let cleaned = BodyCleanup.dropJunk(blocks).compactMap { $0.original ?? $0.text }.reduce(0) { $0 + $1.count }
        if paid == true, length < 1500, !matchesSiteBody(length, ldBody: ldBody), !matchesSiteBody(cleaned, ldBody: ldBody) { return true }
        if kind == .hard, length < 2500 { return true }
        return false
    }

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
                                 teasers: Set<String> = [], limit: Int = 3) -> [NewsItem] {
        let rank = ["lab": 0, "kr": 1, "press": 2]
        var seenSources: Set<String> = [item.sourceId]
        return story
            .filter { $0.key != item.key && !hidden.contains($0.sourceId) && !$0.link.isEmpty && $0.itemKind == .article
                && kind(sourceId: $0.sourceId, link: $0.link, paid: $0.paid, teaser: teasers.contains($0.link), meta: meta, stats: stats) == nil }
            .sorted { (rank[$0.tier] ?? 3, -($0.date?.timeIntervalSince1970 ?? 0)) < (rank[$1.tier] ?? 3, -($1.date?.timeIntervalSince1970 ?? 0)) }
            .filter { seenSources.insert($0.sourceId).inserted }
            .prefix(limit).map { $0 }
    }
}

// 앱 안에서 쓰는 쪽: 출처별 기록을 기억해 두고 화면(자물쇠)·읽기 창(무료 보도 권하기)에 알려 준다
// 맛보기로 판정된 기사(teasers)는 DB 에 남겨 목록·카드·물방울이 열기 전부터 '앞부분만'을 보이게 한다(바뀌면 화면이 다시 그림)
@MainActor
final class PaywallBook: ObservableObject {
    static let shared = PaywallBook()
    private let db: Database
    private(set) var stats: [String: Database.ExtractStat]
    @Published private(set) var teasers: Set<String>

    init(db: Database = .shared) {
        self.db = db
        stats = db.extractStats()
        teasers = db.teaserLinks()
    }

    // 화면 표시용: 맛보기 판정 > 피드의 기사 표시 > 출처 값 > 배운 막힘
    func kind(_ item: NewsItem) -> PaywallKind? {
        guard item.itemKind == .article, !item.link.isEmpty else { return nil }
        return Paywall.kind(sourceId: item.sourceId, link: item.link, paid: item.paid, teaser: teasers.contains(item.link), stats: stats)
    }

    // 맛보기 판정(Paywall.isTeaser)에 넘기는 값: 지난 판정은 빼고 피드·출처만 본다(다시 받을 때 지난 판정에 끌려가지 않게)
    func sourceKind(_ item: NewsItem) -> PaywallKind? {
        guard item.itemKind == .article, !item.link.isEmpty else { return nil }
        return Paywall.kind(sourceId: item.sourceId, link: item.link, paid: item.paid, stats: stats)
    }

    // 본문을 받은 기사(미리 받기 포함)의 맛보기 판정을 남긴다 — 맛보기가 아니면 지난 기록을 지운다.
    // 다시 맛보기로 판정되면 시각만 새로 써서 30일·2,000건 정리에서 계속 맛보기인 기사가 빠지지 않게 한다(review-3 B3). 표시가 바뀔 때만 화면이 다시 그림
    func recordTeaser(_ item: NewsItem, _ teaser: Bool) {
        guard item.id != AppModel.previewID, !item.link.isEmpty else { return }
        let had = teasers.contains(item.link)
        guard teaser || had else { return }
        db.markTeaser(item.link, teaser)
        guard teaser != had else { return }
        if teaser { teasers.insert(item.link) } else { teasers.remove(item.link) }
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
        return Paywall.freeAlternatives(item, story: Magazine.shared.storyItems(c), hidden: Set(AppModel.shared.state.hiddenSources), stats: stats, teasers: teasers) // storyItems 가 꺼진 출처를 이미 뺌
    }
}
