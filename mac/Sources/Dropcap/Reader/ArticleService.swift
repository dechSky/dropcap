import CryptoKit
import Foundation

// 기사 하나를 "읽을 수 있는 상태"로 준비한다: 본문 추리기 → 번역 → 3줄 요약.
// 알림이 뜨는 순간 미리 준비해 두고(미리 받기), 한 번 준비한 기사는 디스크에 남겨 다시 열면 바로 뜬다.
struct PreparedArticle: Codable {
    enum Stage: Int, Codable { case extracting, original, translating, done, failed }
    var stage: Stage = .extracting
    var title: String
    var originalTitle: String
    var blocks: [Block] = []          // 번역됐으면 text=번역, original=원문
    var translated = false
    var engine = ""
    var summary: [String]?
    var summarizing = false
    var fallback = ""                 // 본문을 못 추렸을 때 보여 줄 요약 번역
}

@MainActor
final class ArticleService {
    static let shared = ArticleService()

    private var memory: [String: PreparedArticle] = [:]
    private var inflight: [String: Task<PreparedArticle, Never>] = [:]
    private var listeners: [String: [UUID: (PreparedArticle) -> Void]] = [:]
    private let dir: URL = {
        let d = Store.dir.appendingPathComponent("articles", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private let diskLimit = 150

    // 진행 상황을 받아 보기(읽기 창). 돌려받은 id 로 그만 받기.
    func observe(_ link: String, _ cb: @escaping (PreparedArticle) -> Void) -> UUID {
        let id = UUID()
        listeners[link, default: [:]][id] = cb
        return id
    }
    func stopObserving(_ link: String, _ id: UUID) { listeners[link]?[id] = nil }

    func cached(_ link: String) -> PreparedArticle? {
        if let m = memory[link], m.stage == .done { return m } // 실패한 기사는 다음에 다시 시도
        guard let data = try? Data(contentsOf: file(link)),
              let a = try? JSONDecoder().decode(PreparedArticle.self, from: data), a.stage == .done else { return nil }
        memory[link] = a
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file(link).path) // 최근에 쓴 것을 오래 남김
        return a
    }

    // 이미 준비 중이면 같은 작업을 기다린다
    // interactive: 사용자가 연 기사(스크립트가 필요한 사이트도 띄움). 미리 받기는 false — 스크립트 없이 빠른 길만.
    @discardableResult
    func prepare(_ item: NewsItem, interactive: Bool = true) async -> PreparedArticle {
        if let t = inflight[item.link], let c = cached(item.link), c.summarizing { return await t.value } // 요약까지 기다림
        if let c = cached(item.link) { return c }
        if let t = inflight[item.link] {
            let r = await t.value
            // 미리 받기가 스크립트 없이 실패했으면, 사용자가 열었을 때는 제대로 다시 시도
            if r.stage == .failed, interactive {
                if inflight[item.link] == t { inflight[item.link] = nil } // 끝난 실패 작업을 치우고 한 번만 다시
                return await prepare(item, interactive: true)
            }
            return r
        }
        let t = Task { await self.run(item, interactive: interactive) }
        inflight[item.link] = t
        let r = await t.value
        // 그 사이 실패한 미리 받기를 치우고 다시 시작한 작업이 있으면 그것은 지우지 않는다
        if inflight[item.link] == t { inflight[item.link] = nil }
        return r
    }

    // 알림이 뜬 소식을 뒤에서 하나씩 미리 준비
    func prefetch(_ items: [NewsItem]) {
        Task {
            for it in items where it.id != AppModel.previewID && !it.link.isEmpty {
                await prepare(it, interactive: false)
            }
        }
    }

    private var order: [String] = []

    private func emit(_ link: String, _ a: PreparedArticle) {
        if memory[link] == nil {
            order.append(link)
            if order.count > 40 { memory.removeValue(forKey: order.removeFirst()) } // 메모리에는 최근 40개만
        }
        memory[link] = a
        listeners[link]?.values.forEach { $0(a) }
    }

    private func run(_ item: NewsItem, interactive: Bool) async -> PreparedArticle {
        var a = PreparedArticle(title: item.displayTitle, originalTitle: item.title)
        emit(item.link, a)
        guard let url = URL(string: item.link), let art = await ArticleExtractor().extract(url, allowScripts: interactive) else {
            if !interactive { // 미리 받기 실패는 조용히 넘기고, 열 때 다시 시도
                memory.removeValue(forKey: item.link)
                order.removeAll { $0 == item.link } // 다시 준비할 때 LRU 목록에 두 번 들어가지 않게(A-23)
                return PreparedArticle(stage: .failed, title: item.displayTitle, originalTitle: item.title)
            }
            a.fallback = await Translator.shared.translate(item.summary)
            a.stage = .failed
            emit(item.link, a)
            return a
        }
        NSLog("[기사] 그림 %d개", art.blocks.filter { $0.type == .img }.count)
        let artTitle = ArticleService.stripSiteName(art.title?.nonEmpty ?? item.title, source: item.sourceName, feedTitle: item.title)
        a.originalTitle = artTitle
        a.blocks = art.blocks
        let texts = art.blocks.compactMap(\.text)
        let foreign = Translator.looksForeign(String(texts.joined(separator: " ").prefix(2000)))

        if foreign {
            // 원문을 먼저 보여 주고, 위에서부터 번역으로 바꿔 끼운다
            a.title = item.titleKo ?? artTitle
            a.stage = .translating
            emit(item.link, a)
            let idx = art.blocks.indices.filter { art.blocks[$0].text != nil && art.blocks[$0].type != .pre }
            let first = Array(idx.prefix(8)), rest = Array(idx.dropFirst(8))
            for (n, chunk) in [first, rest].enumerated() where !chunk.isEmpty || n == 0 {
                let inputs = (n == 0 ? [artTitle] : []) + chunk.map { art.blocks[$0].text! }
                var out = await Translator.shared.translateMany(inputs)
                if n == 0 { a.title = out.removeFirst() }
                for (k, i) in chunk.enumerated() {
                    a.blocks[i].original = art.blocks[i].text
                    a.blocks[i].text = out[k]
                }
                a.translated = true
                emit(item.link, a)
            }
            a.engine = await Translator.shared.lastEngine.rawValue
        } else {
            a.title = artTitle
        }
        NSLog("[기사] 번역까지 완료 (%@)", a.engine)
        a.stage = .done
        a.summarizing = Summarizer.available
        emit(item.link, a)

        if a.summarizing {
            a.summary = await Summarizer.summarize(title: artTitle, paragraphs: texts)
            a.summarizing = false
            NSLog("[기사] 요약 %@", a.summary == nil ? "없음" : "완료")
            emit(item.link, a)
        }
        save(item.link, a)
        return a
    }

    // MARK: 디스크
    private func file(_ link: String) -> URL {
        let h = SHA256.hash(data: Data(link.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
        return dir.appendingPathComponent("\(h).json")
    }

    private func save(_ link: String, _ a: PreparedArticle) {
        guard let data = try? JSONEncoder().encode(a) else { return }
        try? data.write(to: file(link), options: .atomic)
        // 오래된 것부터 지워 개수를 지킨다
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > diskLimit else { return }
        let sorted = files.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        // 저장한 기사는 오프라인으로 읽을 수 있게 지우지 않는다
        let pinned = Set(AppModel.shared.state.saved.map { file($0.link).lastPathComponent })
        sorted.filter { !pinned.contains($0.lastPathComponent) }.prefix(files.count - diskLimit).forEach { try? fm.removeItem(at: $0) }
    }
}

extension ArticleService {
    // 웹 문서 제목 끝의 사이트 이름(" - AI타임스", " | The Verge")은 출처가 이미 위에 보이므로 뗀다
    nonisolated static func stripSiteName(_ title: String, source: String, feedTitle: String) -> String {
        let norm: (String) -> String = { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
        for sep in [" - ", " | ", " – ", " — ", " :: ", " · "] {
            guard let r = title.range(of: sep, options: .backwards) else { continue }
            let head = String(title[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            let tail = String(title[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !head.isEmpty else { continue }
            if norm(tail) == norm(source) || norm(head) == norm(feedTitle) || (!norm(source).isEmpty && norm(tail).contains(norm(source))) { return head }
        }
        return title
    }
}
