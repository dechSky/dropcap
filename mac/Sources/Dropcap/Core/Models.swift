import Foundation
import SwiftUI

// shared/sources.json 과 같은 모양
struct SourceConfig: Decodable {
    let version: Int
    let tiers: [String: String]
    let aiPattern: String
    let sources: [Source]
}

struct Source: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let tier: String
    let type: String // feed | sitemap
    let url: String
    let match: String?
    let aiOnly: Bool
    let defaultOn: Bool
    let color: String
    var kind: String? = nil          // article(기본) · video · paper · release · post · podcast
    var notifyDefault: Bool? = nil   // 알림 기본값(양 많은 채널은 false)
    var group: String? = nil         // 추천 목록의 묶음 이름
    var home: String? = nil          // 사람이 보는 주소(설정 화면 표시용)
    var section: String? = nil       // 분야 id(shared/categories.json). 없으면 AI(예전 출처·직접 추가)
    var lang: String? = nil          // 글의 언어(ko·en …). 없으면 en
    var region: String? = nil        // kr(국내) · intl(해외). 없으면 tier 로 정함
    var paywall: String? = nil       // hard(구독해야만) · metered(한 달 몇 건 무료). 없으면 무료로 봄

    var itemKind: ItemKind { ItemKind(rawValue: kind ?? "article") ?? .article }
    var sectionID: String { section ?? "ai" }
    var language: String { lang ?? "en" }
    var regionCode: String { region ?? (tier == "kr" ? "kr" : "intl") }
    var isDomestic: Bool { regionCode == "kr" }
}

// 글의 종류: 기사 외의 구독 채널(영상·논문·릴리스·커뮤니티·팟캐스트)
enum ItemKind: String, Codable, CaseIterable {
    case article, video, paper, release, post, podcast
    var label: String {
        switch self {
        case .article: return "기사"
        case .video: return "영상"
        case .paper: return "논문"
        case .release: return "릴리스"
        case .post: return "커뮤니티"
        case .podcast: return "팟캐스트"
        }
    }
    var symbol: String {
        switch self {
        case .article: return "doc.text"
        case .video: return "play.rectangle.fill"
        case .paper: return "doc.richtext"
        case .release: return "shippingbox"
        case .post: return "bubble.left.and.bubble.right"
        case .podcast: return "waveform"
        }
    }
    // 읽기 창 대신 원래 앱·브라우저로 여는 것
    var opensExternally: Bool { self == .video || self == .podcast }
}

struct NewsItem: Codable, Identifiable, Hashable {
    var id: String          // 출처 안에서의 고유 값(guid 또는 주소)
    var title: String
    var titleKo: String?
    var link: String
    var date: Date?
    var summary: String
    var sourceId: String
    var sourceName: String
    var tier: String

    var related: [String]? = nil   // 같은 소식을 다룬 다른 출처
    var image: String? = nil       // 대표 사진 주소
    var titleEn: String? = nil     // 영어 제목(한국어 기사를 다른 기사와 같은 소식인지 비교할 때)
    var kind: String? = nil        // ItemKind
    var itemKind: ItemKind { ItemKind(rawValue: kind ?? "article") ?? .article }
    var important: Bool? = nil      // '꼭 알림' 낱말에 걸림
    var watch: String? = nil        // 걸린 '지켜볼 낱말'(★ 와 겹치면 표시는 ★)
    var paid: Bool? = nil           // 피드가 이 기사에 적은 유료 표시(FeedParser.paidMark): true 유료 · false 무료로 풀림 · nil 표시 없음(출처 값)
    // 피드가 준 본문 전문 HTML(FeedParser.body — 1,000자 이상만, 60,000자 상한). 예전 기록·다른 기기 기록에는 없다(nil).
    // 사이트 HTML 이 앞부분만 줄 때 읽기 창이 대신 쓴다(ArticleService · FeedFullBody).
    // 저장할 때는 기본으로 빠진다(앱 상태의 최근·나중에 읽기·고인 소식, 스크랩, 백업, Spotlight) — 피드 기록 DB 의 items 줄만
    // NewsItem.keepFeedBody 를 켠 인코더로 남긴다(Database.itemEncoder). 읽기 창은 없으면 DB 에서 다시 찾는다
    @FeedBodyText var feedBody: String? = nil
    static let keepFeedBody = CodingUserInfoKey(rawValue: "dropcap.keepFeedBody")!

    var key: String { "\(sourceId)|\(id)" }
    var displayTitle: String { titleKo ?? title }
}

// NewsItem.feedBody 의 저장 규칙: 인코더 userInfo[keepFeedBody] 가 true 일 때만 글을 쓰고, 그 밖에는 null("feedBody":null).
// 읽을 때도 같다: 디코더 userInfo[keepFeedBody] 가 true(피드 기록 DB — Database.decoder)일 때만 받고, 가져온 백업·앱 상태 파일에
// 든 글은 버린다(보안 점검 2 M13: 고친 파일이 실제 기사 링크 아래 가짜 본문을 보여 주지 못하게).
// 같음·해시는 글 전체를 비교하지 않아도 되게 길이와 앞머리로(목록 비교가 60KB 글을 훑지 않게)
@propertyWrapper
struct FeedBodyText: Codable, Hashable {
    var wrappedValue: String?
    init(wrappedValue: String?) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws {
        guard decoder.userInfo[NewsItem.keepFeedBody] as? Bool == true else { wrappedValue = nil; return }
        let c = try decoder.singleValueContainer()
        wrappedValue = c.decodeNil() ? nil : try c.decode(String.self)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if encoder.userInfo[NewsItem.keepFeedBody] as? Bool == true, let v = wrappedValue { try c.encode(v) } else { try c.encodeNil() }
    }
    static func == (a: Self, b: Self) -> Bool {
        a.wrappedValue?.utf8.count == b.wrappedValue?.utf8.count && a.wrappedValue?.prefix(200) == b.wrappedValue?.prefix(200)
    }
    func hash(into h: inout Hasher) { h.combine(wrappedValue?.utf8.count); h.combine(wrappedValue?.prefix(200)) }
}

extension KeyedDecodingContainer {
    // 칸이 없는 예전 기록도 읽히게(nil)
    func decode(_ type: FeedBodyText.Type, forKey key: Key) throws -> FeedBodyText {
        guard contains(key) else { return FeedBodyText(wrappedValue: nil) }
        return try FeedBodyText(from: superDecoder(forKey: key))
    }
}

enum Resources {
    // .app 안에서는 Contents/Resources, `swift run` 개발 중에는 저장소 안 경로
    static func url(_ name: String) -> URL {
        if let u = Bundle.main.resourceURL?.appendingPathComponent(name), FileManager.default.fileExists(atPath: u.path) {
            return u
        }
        let here = URL(fileURLWithPath: #filePath)
        let mac = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [mac.appendingPathComponent("Resources/\(name)"), mac.deletingLastPathComponent().appendingPathComponent("shared/\(name)")]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[0]
    }

    static let config: SourceConfig = {
        let data = (try? Data(contentsOf: url("sources.json"))) ?? Data()
        do {
            return try JSONDecoder().decode(SourceConfig.self, from: data)
        } catch {
            fatalError("sources.json 을 읽지 못함: \(error)")
        }
    }()

    static let aiRegex = try! NSRegularExpression(pattern: config.aiPattern, options: [.caseInsensitive])

    @MainActor static func source(_ id: String) -> Source? { AppModel.shared.allSources.first { $0.id == id } ?? config.sources.first { $0.id == id } }
    static func tierLabel(_ tier: String) -> String { config.tiers[tier] ?? tier }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0x3B82F6
        self.init(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

extension NewsItem {
    @MainActor var accent: Color { Color(hex: Resources.source(sourceId)?.color ?? "#3B82F6") }
    var initial: String {
        let n = sourceName.replacingOccurrences(of: "The ", with: "")
        return String(n.prefix(1)).uppercased()
    }
}

enum RelativeTime {
    static func string(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "방금" }
        let m = Int(now.timeIntervalSince(date) / 60)
        if m < 1 { return "방금" }
        if m < 60 { return "\(m)분 전" }
        if m < 60 * 24 { return "\(m / 60)시간 전" }
        return "\(m / 1440)일 전"
    }
}
