import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

// 나중에 읽기로 저장한 기사와 스크랩을 Spotlight 에 색인한다. 지우면 색인에서도 지운다.
// 색인한 목록은 Store.dir/spotlight-index.json 에 둬서, 앱이 꺼진 사이 바뀐 것도 다음 실행 때 맞춘다.
@MainActor
final class SpotlightIndexer {
    static let shared = SpotlightIndexer()
    static let enabledKey = "indexSpotlight"
    nonisolated static let savedPrefix = "saved:"
    nonisolated static let scrapPrefix = "scrap:"

    struct Doc: Equatable {
        var id: String
        var domain: String
        var title: String
        var detail: String
        var keywords: [String]
        var date: Date?

        // 바뀐 것만 다시 색인하려고 내용으로 만든 지문
        var fingerprint: String { [title, detail, keywords.joined(separator: ","), date.map { "\($0.timeIntervalSince1970)" } ?? ""].joined(separator: "\u{1F}") }
    }

    // 테스트 실행(DROPCAP_DATA_DIR)은 실제 Spotlight 를 건드리지 않는다(DROPCAP_TEST_SPOTLIGHT 로만 켠다)
    var enabled: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["DROPCAP_DATA_DIR"] != nil, env["DROPCAP_TEST_SPOTLIGHT"] == nil { return false }
        return UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }
    private var file: URL { Store.dir.appendingPathComponent("spotlight-index.json") }
    private var running: Task<Void, Never>?

    nonisolated static func docs(saved: [NewsItem], scraps: [Scrap]) -> [Doc] {
        let a = saved.map { it in
            Doc(id: savedPrefix + it.key, domain: "saved", title: it.displayTitle,
                detail: [it.sourceName, it.summary].filter { !$0.isEmpty }.joined(separator: " — "),
                keywords: ["Dropcap", "나중에 읽기", it.sourceName] + (it.titleKo != nil && it.titleKo != it.title ? [it.title] : []),
                date: it.date)
        }
        let b = scraps.map { s in
            Doc(id: scrapPrefix + s.id, domain: "scrap", title: s.item.displayTitle,
                detail: [s.quote, s.memo.isEmpty ? nil : "메모: \(s.memo)", s.item.sourceName].compactMap { $0 }.joined(separator: " — "),
                keywords: ["Dropcap", "스크랩", s.collection, s.item.sourceName],
                date: s.created)
        }
        return a + b
    }

    // 앞의 색인과 비교해 다시 넣을 것·지울 것
    nonisolated static func diff(previous: [String: String], current: [Doc]) -> (upsert: [Doc], remove: [String]) {
        let ids = Set(current.map(\.id))
        return (current.filter { previous[$0.id] != $0.fingerprint }, previous.keys.filter { !ids.contains($0) }.sorted())
    }

    func scheduleSync() {
        guard enabled else { return }
        running?.cancel()
        running = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await sync()
        }
    }

    func sync() async {
        guard enabled, CSSearchableIndex.isIndexingAvailable() else { return }
        let docs = Self.docs(saved: AppModel.shared.state.saved, scraps: Scrapbook.shared.scraps)
        let previous = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))) ?? [:]
        let (upsert, remove) = Self.diff(previous: previous, current: docs)
        guard !upsert.isEmpty || !remove.isEmpty else { return }
        let index = CSSearchableIndex.default()
        do {
            if !remove.isEmpty { try await index.deleteSearchableItems(withIdentifiers: remove) }
            if !upsert.isEmpty { try await index.indexSearchableItems(upsert.map(Self.item)) }
            let map = Dictionary(docs.map { ($0.id, $0.fingerprint) }, uniquingKeysWith: { a, _ in a })
            try? JSONEncoder().encode(map).write(to: file, options: .atomic)
        } catch {
            NSLog("[Spotlight] 색인 실패: %@", String(describing: error))
        }
    }

    private static func item(_ d: Doc) -> CSSearchableItem {
        let a = CSSearchableItemAttributeSet(contentType: .text)
        a.title = d.title
        a.displayName = d.title
        a.contentDescription = d.detail
        a.keywords = d.keywords
        a.contentCreationDate = d.date
        return CSSearchableItem(uniqueIdentifier: d.id, domainIdentifier: d.domain, attributeSet: a)
    }

    // 끄기: 이 앱이 넣은 색인을 모두 지운다
    func clear() async {
        running?.cancel()
        try? await CSSearchableIndex.default().deleteAllSearchableItems()
        try? FileManager.default.removeItem(at: file)
    }

    // Spotlight 결과를 눌렀을 때: 그 기사를 읽기 창으로
    static func open(_ id: String) -> Bool {
        let item: NewsItem?
        if id.hasPrefix(savedPrefix) {
            let key = String(id.dropFirst(savedPrefix.count))
            item = AppModel.shared.state.saved.first { $0.key == key } ?? URLRouter.item(forKey: key)
        } else if id.hasPrefix(scrapPrefix) {
            let sid = String(id.dropFirst(scrapPrefix.count))
            item = Scrapbook.shared.scraps.first { $0.id == sid }?.item
        } else { item = nil }
        guard let item else { return false }
        AppModel.shared.open(item)
        return true
    }
}
