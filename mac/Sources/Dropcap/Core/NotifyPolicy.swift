import Foundation

// 분야별 알림 정책.
// 매거진에는 전부 싣고, 물방울은 분야 모드·중요도 문턱·하루 상한을 모두 지날 때만 떨어뜨린다.
enum NotifyMode: String, Codable, CaseIterable, Identifiable {
    case instant, bundle, magazine
    var id: String { rawValue }
    var label: String {
        switch self {
        case .instant: return "즉시"
        case .bundle: return "묶음"
        case .magazine: return "매거진만"
        }
    }
    var help: String {
        switch self {
        case .instant: return "중요한 소식(여러 곳 보도·공식 발표·꼭 알림 낱말·팔로우한 스토리)만 바로 물방울로"
        case .bundle: return "정한 시각에 한 방울로 모아서(예: 경제 7건)"
        case .magazine: return "알리지 않고 매거진에만"
        }
    }
}

struct SectionPolicy: Codable, Equatable {
    var mode: NotifyMode = .bundle
    var bundleHour = 18      // 묶음을 보내는 시각(시)
    var dailyCap = 3         // 이 분야에서 하루에 떨어뜨리는 물방울 수
    var less = false         // 카드에서 '이 분야 덜 받기'를 누름 → 주요 뉴스 흐름으로도 바로 떨어뜨리지 않음(즉시로 되돌리면 풀림)

    init(mode: NotifyMode = .bundle, bundleHour: Int = 18, dailyCap: Int = 3, less: Bool = false) {
        self.mode = mode; self.bundleHour = bundleHour; self.dailyCap = dailyCap; self.less = less
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? c.decodeIfPresent(NotifyMode.self, forKey: .mode)) ?? .bundle
        bundleHour = (try? c.decodeIfPresent(Int.self, forKey: .bundleHour)) ?? 18
        dailyCap = (try? c.decodeIfPresent(Int.self, forKey: .dailyCap)) ?? 3
        less = (try? c.decodeIfPresent(Bool.self, forKey: .less)) ?? false // 예전 파일엔 없음 · 예전 판은 이 값을 무시
    }
}

// 같은 소식을 다룬 출처 수(국내·해외)
struct Coverage: Equatable {
    var kr = 0
    var intl = 0
    var total: Int { kr + intl }
}

struct PolicyLimits: Equatable {
    var totalCap = 10        // 모든 분야를 합친 하루 물방울 수
    var krThreshold = 3      // 국내 n곳 이상이 다루면 중요한 소식
    var intlThreshold = 2    // 해외 n곳 이상
    var bigThreshold = 8     // 국내 n곳 이상이면 상한도 넘어 알림
}

enum NotifyDecision: Equatable {
    case drop        // 지금 물방울
    case pool        // 고였다가 그 분야 묶음 시각에 한 방울
    case quiet       // 매거진에만
}

enum NotifyPolicy {
    struct Input: Equatable {
        var chosen: Bool                // 사용자가 고른 분야인가
        var policy: SectionPolicy
        var coverage: Coverage
        var lab = false                 // 공식 발표 등급(tier lab)
        var important = false           // ★ 꼭 알림 낱말
        var followed = false            // 팔로우한 스토리
        var watched = false             // 지켜볼 낱말에 걸림
        var sentInSection = 0           // 오늘 이 분야에서 이미 떨어뜨린 수
        var sentTotal = 0               // 오늘 전체
    }

    static func crosses(_ c: Coverage, _ l: PolicyLimits) -> Bool { c.kr >= l.krThreshold || c.intl >= l.intlThreshold }
    static func isBig(_ c: Coverage, _ l: PolicyLimits) -> Bool { c.kr >= l.bigThreshold }

    static func decide(_ i: Input, limits l: PolicyLimits) -> NotifyDecision {
        // 지켜볼 낱말: 고른 분야·모드와 상관없이 알린다(같은 이야기는 한 번 — 부르는 쪽이 스토리로 기억). 전체 상한이 차면 고임
        if i.watched { return i.sentTotal >= l.totalCap && !isBig(i.coverage, l) ? .pool : .drop }
        guard i.chosen else { return .quiet }
        switch i.policy.mode {
        case .magazine: return .quiet
        case .bundle: return .pool
        case .instant:
            let worth = crosses(i.coverage, l) || i.lab || i.important || i.followed
            guard worth else { return .quiet }
            let full = i.sentInSection >= i.policy.dailyCap || i.sentTotal >= l.totalCap
            if full { return isBig(i.coverage, l) ? .drop : .pool }
            return .drop
        }
    }

    // '주요 뉴스' 흐름: 자기 분야에서 떨어지지 않은 소식이라도 문턱을 넘었으면 주요 뉴스 정책으로 한 번 더 본다
    static func decideWithTop(_ i: Input, top: Input?, limits l: PolicyLimits) -> (NotifyDecision, viaTop: Bool) {
        let own = decide(i, limits: l)
        // '덜 받기'한 분야는 주요 뉴스 흐름으로도 떨어뜨리지 않고 자기 정책(묶음·매거진만)대로 둔다
        guard own != .drop, !i.policy.less, let top, crosses(i.coverage, l) else { return (own, false) }
        var t = top
        t.coverage = i.coverage
        return decide(t, limits: l) == .drop ? (.drop, true) : (own, false)
    }

    // 첫 실행 기본값: 고른 분야 중 앞의 두 개만 즉시, 나머지는 묶음(주요 뉴스 흐름은 즉시)
    static func defaults(for chosen: [String]) -> [String: SectionPolicy] {
        var out: [String: SectionPolicy] = [:]
        var instant = 0
        for id in chosen {
            if id == Sections.top { out[id] = SectionPolicy(mode: .instant); continue }
            out[id] = SectionPolicy(mode: instant < 2 ? .instant : .bundle)
            if instant < 2 { instant += 1 }
        }
        return out
    }

    // 묶음을 보낼 때인가: 그 분야 묶음 시각이 지났고 오늘 아직 안 보냈으면
    static func bundleDue(hour: Int, now: Date, last: Date?, calendar cal: Calendar = .current) -> Bool {
        guard cal.component(.hour, from: now) >= hour else { return false }
        if let last, cal.isDate(last, inSameDayAs: now), cal.component(.hour, from: last) >= hour { return false }
        return true
    }
}
