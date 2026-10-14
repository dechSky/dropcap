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

    var key: String { "\(sourceId)|\(id)" }
    var displayTitle: String { titleKo ?? title }
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
