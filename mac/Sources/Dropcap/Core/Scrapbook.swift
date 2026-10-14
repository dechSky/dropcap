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

    private init() {
        restoreFromCopyIfNeeded()
        reload()
    }

    func reload() {
        scraps = db.scraps()
        writeCopy()
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
        ScrapExport.shared.syncSoon()
    }

    func update(_ s: Scrap) { db.saveScrap(s); reload(); ScrapExport.shared.syncSoon() }
    func remove(_ s: Scrap) { db.deleteScrap(s.id); reload(); ScrapExport.shared.syncSoon() }

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
        ScrapExport.shared.syncSoon(renamed: (from, n))
        return true
    }

    // MARK: JSON 사본(scraps.json)
    // 스크랩은 매거진 DB 안에 있어, DB 가 통째로 못 읽히면 함께 사라졌다(E2E 12-다). 바뀔 때마다 전부를 사본으로 원자적으로 쓰고,
    // DB 가 새로 만들어졌거나(깨짐) 비어 있는데 사본에 있으면 사본에서 되살린다.
    // - 예전 판(사본 없음): 첫 실행의 reload 가 DB 내용으로 사본을 만든다.
    // - 되돌리기: 예전 판은 이 파일을 모르고 무시한다. 끄기: UserDefaults scrapsCopyOff = true.
    // - 기기 이동: 데이터 폴더(Store.dir)에 함께 있어 폴더째 옮기면 따라간다.
    struct Copy: Codable { var version = 1; var scraps: [Scrap] }
    nonisolated static func copyFile(_ dir: URL = Store.dir) -> URL { dir.appendingPathComponent("scraps.json") }
    private static var copyOff: Bool { UserDefaults.standard.bool(forKey: "scrapsCopyOff") }

    nonisolated static func readCopy(_ file: URL) -> [Scrap]? {
        guard let d = try? Data(contentsOf: file) else { return nil }
        return (try? Database.decoder.decode(Copy.self, from: d))?.scraps
    }
    nonisolated static func writeCopy(_ list: [Scrap], to file: URL) {
        guard let d = try? Database.encoder.encode(Copy(scraps: list)) else { return }
        try? d.write(to: file, options: .atomic)
    }

    // 사본에 있고 DB 에 없는 스크랩을 DB 로(같은 id 는 DB 쪽을 그대로 둠)
    nonisolated static func restoreList(db: [Scrap], copy: [Scrap]) -> [Scrap] {
        let have = Set(db.map(\.id))
        return copy.filter { !have.contains($0.id) }
    }

    private func restoreFromCopyIfNeeded() {
        guard !Self.copyOff, let copy = Self.readCopy(Self.copyFile()), !copy.isEmpty else { return }
        let inDB = db.scraps()
        // 평소에 사용자가 다 지운 것은 되살리지 않는다: DB 를 새로 만들었거나(깨짐·삭제) 기사도 하나 없는 빈 DB 일 때만
        guard db.recreated || (inDB.isEmpty && db.itemCount == 0) else { return }
        let missing = Self.restoreList(db: inDB, copy: copy)
        for s in missing { db.saveScrap(s) }
        if !missing.isEmpty { NSLog("[스크랩] 사본(scraps.json)에서 %d개를 되살렸습니다", missing.count) }
    }

    private func writeCopy() {
        guard !Self.copyOff else { return }
        // DB 가 깨져 새로 만들었는데 아무것도 못 건졌으면, 그 빈 목록으로 사본을 덮지 않는다
        if scraps.isEmpty, db.recreated { return }
        Self.writeCopy(scraps, to: Self.copyFile())
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
            out += "## [\(escapeLinkText(it.displayTitle))](\(escapeLinkURL(it.link)))\n\n"
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
                if !s.memo.isEmpty { out += "- 메모: \(s.memo.replacingOccurrences(of: "\n", with: "\n  "))\n\n" } // 여러 줄 메모도 목록 한 칸 안에
            }
        }
        return out
    }

    // 링크 글자: [ ] \ 앞에 \ (제목의 ] 로 링크가 끊기지 않게)
    nonisolated static func escapeLinkText(_ s: String) -> String {
        var out = ""
        for ch in s.replacingOccurrences(of: "\n", with: " ") {
            if ch == "[" || ch == "]" || ch == "\\" { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    // 링크 주소: <…> 로 감싸 ( ) 가 든 주소도 끝까지 하나로. 안에 못 들어가는 < > 공백 줄바꿈은 퍼센트 표기로.
    nonisolated static func escapeLinkURL(_ s: String) -> String {
        let enc = s.replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E")
            .replacingOccurrences(of: " ", with: "%20").replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        return "<\(enc)>"
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
