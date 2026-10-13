import AppKit
import Foundation

// 스크랩: 기사 전체 또는 문단 하나를 메모와 함께 폴더(컬렉션)에 모아 둔다.
struct Scrap: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var item: NewsItem
    var quote: String?          // 문단 스크랩이면 그 문단(보이던 언어)
    var quoteOriginal: String?  // 번역문을 스크랩했으면 원문
    var memo = ""
    var collection: String
    var created = Date()
}

@MainActor
final class Scrapbook: ObservableObject {
    static let shared = Scrapbook()
    static let defaultCollection = "스크랩"
    private let db = Database.shared

    @Published private(set) var scraps: [Scrap] = []
    @Published private(set) var collections: [String] = []

    private init() { reload() }

    func reload() {
        scraps = db.scraps()
        let used = Set(scraps.map(\.collection))
        let extra = (UserDefaults.standard.stringArray(forKey: "scrapCollections") ?? []).filter { !used.contains($0) }
        collections = ([Self.defaultCollection] + used.sorted() + extra).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    func add(_ item: NewsItem, quote: String? = nil, original: String? = nil, memo: String = "", to collection: String? = nil) {
        var c = (collection ?? UserDefaults.standard.string(forKey: "lastScrapCollection") ?? Self.defaultCollection).trimmingCharacters(in: .whitespaces)
        if c.isEmpty { c = Self.defaultCollection } // 이름 없는 폴더는 만들지 않음
        // 같은 문단을 두 번 스크랩하지 않게
        if let q = quote, scraps.contains(where: { $0.item.key == item.key && $0.quote == q && $0.collection == c }) { return }
        if quote == nil, scraps.contains(where: { $0.item.key == item.key && $0.quote == nil && $0.collection == c }) { return }
        db.saveScrap(Scrap(item: item, quote: quote, quoteOriginal: original, memo: memo, collection: c))
        UserDefaults.standard.set(c, forKey: "lastScrapCollection")
        reload()
    }

    func update(_ s: Scrap) { db.saveScrap(s); reload() }
    func remove(_ s: Scrap) { db.deleteScrap(s.id); reload() }

    @discardableResult
    func createCollection(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !collections.contains(n) else { return false }
        UserDefaults.standard.set((UserDefaults.standard.stringArray(forKey: "scrapCollections") ?? []) + [n], forKey: "scrapCollections")
        reload()
        return true
    }

    @discardableResult
    func rename(_ from: String, to: String) -> Bool {
        let n = to.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != from, !collections.contains(n) else { return false }
        if UserDefaults.standard.string(forKey: "lastScrapCollection") == from { UserDefaults.standard.set(n, forKey: "lastScrapCollection") }
        db.renameCollection(from, to: n)
        let extra = (UserDefaults.standard.stringArray(forKey: "scrapCollections") ?? []).map { $0 == from ? n : $0 }
        UserDefaults.standard.set(extra, forKey: "scrapCollections")
        reload()
        return true
    }

    func isScrapped(_ item: NewsItem, quote: String? = nil) -> Bool {
        scraps.contains { $0.item.key == item.key && (quote == nil || $0.quote == quote) }
    }

    // MARK: 내보내기(Markdown)
    func markdown(collection: String) -> String {
        Self.render(scraps.filter { $0.collection == collection }, title: collection)
    }

    // 스크랩 목록(최근 것이 앞)을 Markdown 으로. 기사별로 묶고, 인용·원문·메모를 함께.
    nonisolated static func render(_ list: [Scrap], title collection: String) -> String {
        var out = "# \(collection)\n\n"
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy-MM-dd"
        out += "_Dropcap 스크랩 · \(f.string(from: Date())) · \(list.count)건_\n\n"
        // 기사별로 묶어서
        var order: [String] = []
        var groups: [String: [Scrap]] = [:]
        for s in list.reversed() {
            if groups[s.item.key] == nil { order.append(s.item.key) }
            groups[s.item.key, default: []].append(s)
        }
        for key in order {
            guard let g = groups[key], let it = g.first?.item else { continue }
            out += "## [\(it.displayTitle)](\(it.link))\n\n"
            var meta = "\(it.sourceName)"
            if let d = it.date { meta += " · \(f.string(from: d))" }
            if it.titleKo != nil, it.titleKo != it.title { meta += " · 원제: \(it.title)" }
            out += "\(meta)\n\n"
            for s in g {
                if let q = s.quote {
                    out += "> \(q.replacingOccurrences(of: "\n", with: "\n> "))\n"
                    if let o = s.quoteOriginal, o != q { out += ">\n> _\(o)_\n" }
                    out += "\n"
                }
                if !s.memo.isEmpty { out += "- 메모: \(s.memo)\n\n" }
            }
        }
        return out
    }

    func copyMarkdown(collection: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown(collection: collection), forType: .string)
    }

    func saveMarkdown(collection: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(collection).md"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? markdown(collection: collection).write(to: url, atomically: true, encoding: .utf8)
    }
}
