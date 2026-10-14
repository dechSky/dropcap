import AppIntents
import Foundation

// 단축어(App Intents): 최신 소식 가져오기 · 주소를 나중에 읽기로 저장 · 매거진 열기
// 빌드 때 build.sh 가 Metadata.appintents 를 만들어 넣어야 단축어 앱에 보인다.

// 매개변수 해석(시험하기 쉽게 따로)
enum IntentLogic {
    static let maxCount = 20

    // 분야: 비우면 전체. 이름(모델·제품) · 영문 값(model) · 앞부분(모델)으로 찾는다.
    // TODO(작업자 A Section): 분야가 Section 으로 바뀌면 이 목록과 classify 를 그쪽으로 옮긴다
    static var sectionNames: [String] { NewsCategory.allCases.map(\.label) }

    enum SectionChoice: Equatable { case all, only(NewsCategory), unknown }

    static func section(_ text: String?) -> SectionChoice {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !t.isEmpty, t != "전체" else { return .all }
        if let c = NewsCategory.allCases.first(where: { $0.rawValue == t || $0.label.lowercased() == t }) { return .only(c) }
        let partial = NewsCategory.allCases.filter { c in c.label.lowercased().split(separator: "·").contains { $0 == t } || c.label.lowercased().hasPrefix(t) }
        return partial.count == 1 ? .only(partial[0]) : .unknown
    }

    static func count(_ n: Int?) -> Int { min(max(n ?? 5, 1), maxCount) }

    static func latest(_ items: [NewsItem], section: NewsCategory?, count: Int) -> [NewsItem] {
        let sorted = items.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        return Array(sorted.filter { section == nil || $0.category == section }.prefix(count))
    }

    // 저장할 주소: 공개 http(s) 만. 스킴 없이 넣은 'example.com/a' 는 https 로.
    static func savableURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty, !s.contains("://") { s = "https://" + s }
        guard let u = URL(string: s), URLSafety.isPublicHTTP(u) else { return nil }
        return u
    }

    // 주소만으로 나중에 읽기 항목을 만든다(제목은 페이지에서 읽어 오고, 못 읽으면 주소)
    static func savedItem(_ url: URL, title: String?, now: Date = Date()) -> NewsItem {
        let host = (url.host ?? "").replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
        let t = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return NewsItem(id: url.absoluteString, title: (t?.isEmpty == false ? t! : url.absoluteString), titleKo: nil,
                        link: url.absoluteString, date: now, summary: "", sourceId: "saved", sourceName: host.isEmpty ? "저장한 주소" : host, tier: "saved")
    }

    // <title> 또는 og:title
    static func pageTitle(_ html: String) -> String? {
        // 꼬리표를 하나씩 떼어 본다(HTMLScan — 정규식 되풀이 훑기로 큰 페이지에서 멈추지 않게)
        func clean(_ raw: String) -> String? {
            let t = raw.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let t = HTMLScan.meta(html, ["og:title"], accept: clean) { return t }
        if let t = HTMLScan.title(html).flatMap(clean) { return t }
        return nil
    }
}

struct ArticleEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "기사"
    static var defaultQuery = ArticleQuery()

    var id: String
    @Property(title: "제목") var title: String
    @Property(title: "출처") var source: String
    @Property(title: "주소") var link: URL?
    @Property(title: "날짜") var date: Date?

    init(_ it: NewsItem) {
        id = it.key
        title = it.displayTitle
        source = it.sourceName
        link = URL(string: it.link)
        date = it.date
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(source)")
    }
}

struct ArticleQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ArticleEntity] {
        await MainActor.run { identifiers.compactMap { URLRouter.item(forKey: $0).map(ArticleEntity.init) } }
    }
    func suggestedEntities() async throws -> [ArticleEntity] {
        await MainActor.run { AppModel.shared.visibleRecent.prefix(10).map(ArticleEntity.init) }
    }
}

struct SectionOptions: DynamicOptionsProvider {
    func results() async throws -> [String] { ["전체"] + IntentLogic.sectionNames }
}

enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case unknownSection(String)
    case badURL(String)
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .unknownSection(let s): return "'\(s)' 분야를 찾지 못했습니다. \(IntentLogic.sectionNames.joined(separator: ", ")) 중에서 고르세요."
        case .badURL(let s): return "'\(s)' 는 저장할 수 있는 공개 웹 주소가 아닙니다."
        }
    }
}

struct GetLatestNewsIntent: AppIntent {
    static var title: LocalizedStringResource = "최신 소식 가져오기"
    static var description = IntentDescription("Dropcap 이 모은 최신 소식을 가져옵니다. 분야를 고르면 그 분야만.")

    @Parameter(title: "분야", optionsProvider: SectionOptions()) var section: String?
    @Parameter(title: "개수", default: 5, inclusiveRange: (1, 20)) var count: Int

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$section) 최신 소식 \(\.$count)건 가져오기")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[ArticleEntity]> {
        let sec: NewsCategory?
        switch IntentLogic.section(section) {
        case .all: sec = nil
        case .only(let c): sec = c
        case .unknown: throw IntentFailure.unknownSection(section ?? "")
        }
        let n = IntentLogic.count(count)
        let items = await MainActor.run { IntentLogic.latest(AppModel.shared.visibleRecent, section: sec, count: n) }
        return .result(value: items.map(ArticleEntity.init))
    }
}

struct SaveURLIntent: AppIntent {
    static var title: LocalizedStringResource = "주소를 나중에 읽기로 저장"
    static var description = IntentDescription("웹 주소를 Dropcap 의 나중에 읽기에 넣습니다. 본문과 번역도 미리 받아 둡니다.")

    @Parameter(title: "주소") var url: String

    static var parameterSummary: some ParameterSummary { Summary("\(\.$url) 을 나중에 읽기로 저장") }

    func perform() async throws -> some IntentResult & ReturnsValue<ArticleEntity> {
        guard let u = IntentLogic.savableURL(url) else { throw IntentFailure.badURL(url) }
        let html = (try? await FeedService.shared.fetch(u.absoluteString, limit: .page)).flatMap { String(data: $0.prefix(200_000), encoding: .utf8) }
        let item = IntentLogic.savedItem(u, title: html.flatMap(IntentLogic.pageTitle))
        await MainActor.run {
            if !AppModel.shared.state.saved.contains(where: { $0.link == item.link }) { AppModel.shared.toggleSaved(item) }
        }
        return .result(value: ArticleEntity(item))
    }
}

struct OpenMagazineIntent: AppIntent {
    static var title: LocalizedStringResource = "매거진 열기"
    static var description = IntentDescription("오늘의 매거진을 엽니다.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await MainActor.run { MagazineController.open() }
        return .result()
    }
}

struct DropcapShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GetLatestNewsIntent(), phrases: ["\(.applicationName) 최신 소식", "\(.applicationName)에서 최신 소식 가져오기"],
                    shortTitle: "최신 소식", systemImageName: "newspaper")
        AppShortcut(intent: OpenMagazineIntent(), phrases: ["\(.applicationName) 매거진 열기", "\(.applicationName) 매거진"],
                    shortTitle: "매거진 열기", systemImageName: "book.pages")
        AppShortcut(intent: SaveURLIntent(), phrases: ["\(.applicationName)에 나중에 읽기로 저장"],
                    shortTitle: "나중에 읽기로 저장", systemImageName: "bookmark")
    }
}
