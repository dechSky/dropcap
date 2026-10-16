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
    var paywalled: Bool? = nil        // 맛보기만 나오고 구독을 권함(유료벽 뒤)
    var failure: ReaderFailure? = nil // 못 추린 까닭(실패 화면 안내)
    var partial: Bool? = nil
    var savedAt: Date? = nil
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

    // 맛보기·일부만 기사는 6시간 뒤 다시 받는다(사이트가 풀거나 앱이 고쳐지면 다시 열 때 온전히). 그 밖은 그대로 오래 둔다
    nonisolated static let cutCacheLife: TimeInterval = 6 * 3600
    nonisolated static func isStale(_ a: PreparedArticle, now: Date = Date()) -> Bool {
        guard a.paywalled == true || a.partial == true else { return false }
        guard let t = a.savedAt else { return true }
        return now.timeIntervalSince(t) > cutCacheLife || t.timeIntervalSince(now) > 300 // 미래 시각(시계 틀어짐·고친 파일)도 만료로
    }

    // 읽기 창 '다시 받기': 기억·디스크의 것을 지우고 처음부터 다시 추린다
    @discardableResult
    func reload(_ item: NewsItem) async -> PreparedArticle {
        memory[item.link] = nil
        try? FileManager.default.removeItem(at: file(item.link))
        return await prepare(item)
    }

    func cached(_ link: String) -> PreparedArticle? {
        if let m = memory[link], m.stage == .done, !Self.isStale(m) { return m } // 실패한 기사는 다음에 다시 시도
        guard let data = try? Data(contentsOf: file(link)),
              let a = try? JSONDecoder().decode(PreparedArticle.self, from: data), a.stage == .done else { return nil }
        if Self.isStale(a) { memory[link] = nil; try? FileManager.default.removeItem(at: file(link)); return nil }
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

    // 피드 본문은 글 링크가 출처 피드와 같은 사이트일 때만(출처를 모르면 쓰지 않음)
    nonisolated static func usableFeedBody(_ body: String?, link: String, sourceURL: String?) -> String? {
        guard let body, let sourceURL, FeedService.sameSite(link, sourceURL) else { return nil }
        return body
    }

    // 읽기 창이 쓸 피드 본문: 들고 온 사본에 없으면(나중에 읽기·스크랩 — 저장 때 뺌) 피드 기록 DB 에서 다시 찾고,
    // 출처 피드와 다른 사이트 링크의 본문은 쓰지 않는다 — 받을 때도 거르지만(FeedService.sameSite) 그 전에 DB 에 들어간 것까지(보안 점검 M15)
    // sourceURL: 출처 주소 찾기(시험이 바꿔 끼움 — 없으면 앱의 출처 목록)
    static func feedBody(for item: NewsItem, db: Database = .shared, sourceURL: ((String) -> String?)? = nil) -> String? {
        let url = sourceURL.map { $0(item.sourceId) } ?? Resources.source(item.sourceId)?.url
        return usableFeedBody(item.feedBody ?? db.items(keys: [item.key]).first?.item.feedBody, link: item.link, sourceURL: url)
    }

    // 받은 본문이 맛보기인가(피드·출처 값만 보고 — 지난 판정은 빼고) + 그 판정을 남김(미리 받기에서도 — 목록·카드에 열기 전부터 '앞부분만')
    static func judgeTeaser(_ item: NewsItem, _ art: Article, book: PaywallBook = .shared) -> Bool {
        let teaser = Paywall.isTeaser(art.blocks, paid: art.paid, kind: book.sourceKind(item), ldBody: art.ldBody)
        book.recordTeaser(item, teaser)
        return teaser
    }

    private func run(_ item: NewsItem, interactive: Bool) async -> PreparedArticle {
        var a = PreparedArticle(title: item.displayTitle, originalTitle: item.title)
        emit(item.link, a)
        let extractor = ArticleExtractor()
        var got: Article?
        if let url = URL(string: item.link) { got = await extractor.extract(url, allowScripts: interactive) }
        // 피드 전문 우선: 사이트가 앞부분만 줬거나 못 추렸는데 피드에 전문이 있으면 그것을(FeedFullBody)
        let feedBody = Self.feedBody(for: item)
        if let body = feedBody, FeedFullBody.worthTrying(feedHTML: body, extracted: got?.blocks), let base = URL(string: item.link),
           let feed = await ArticleExtractor().extractHTML(FeedFullBody.page(body, title: item.title), base: base),
           FeedFullBody.prefer(feed: feed.blocks, over: got?.blocks ?? []) {
            NSLog("[기사] 피드 전문 사용 %d → %d자", FeedFullBody.textLength(got?.blocks ?? []), FeedFullBody.textLength(feed.blocks))
            got = Article(title: got?.title ?? item.title, byline: got?.byline, siteName: got?.siteName, blocks: feed.blocks, paid: got?.paid, partial: nil)
        }
        guard var art = got else {
            if !interactive { // 미리 받기 실패는 조용히 넘기고, 열 때 다시 시도
                memory.removeValue(forKey: item.link)
                order.removeAll { $0 == item.link } // 다시 준비할 때 LRU 목록에 두 번 들어가지 않게(A-23)
                return PreparedArticle(stage: .failed, title: item.displayTitle, originalTitle: item.title)
            }
            PaywallBook.shared.record(item, failed: true, blocked: false)
            a.fallback = await Translator.shared.translate(item.summary)
            a.failure = URL(string: item.link) == nil ? .gone : extractor.trace.failure
            a.stage = .failed
            emit(item.link, a)
            return a
        }
        NSLog("[기사] 그림 %d개", art.blocks.filter { $0.type == .img }.count)
        let artTitle = ArticleService.stripSiteName(art.title?.nonEmpty ?? item.title, source: item.sourceName, feedTitle: item.title)
        a.originalTitle = artTitle
        if Self.judgeTeaser(item, art) { a.paywalled = true }
        a.partial = art.partial == true ? true : nil
        art.blocks = BodyCleanup.dropJunk(art.blocks) // 맛보기 판정(끝의 구독 권유 문구)을 본 뒤에 군더더기를 뺀다
        a.blocks = art.blocks
        if interactive { PaywallBook.shared.record(item, failed: false, blocked: a.paywalled == true) }
        let texts = art.blocks.compactMap(\.text)
        let foreign = Translator.looksForeign(String(texts.joined(separator: " ").prefix(2000)))

        if foreign {
            // 원문을 먼저 보여 주고, 위에서부터 번역으로 바꿔 끼운다
            a.title = item.titleKo ?? artTitle
            a.stage = .translating
            emit(item.link, a)
            let idx = art.blocks.indices.filter { art.blocks[$0].text != nil && art.blocks[$0].type != .pre }
            let first = Array(idx.prefix(8)), rest = Array(idx.dropFirst(8))
            var done = 0, total = 0 // 실제로 바뀐(번역된) 문단 수 — 번역이 모두 실패하면 원문이 그대로 돌아온다
            for (n, chunk) in [first, rest].enumerated() where !chunk.isEmpty || n == 0 {
                // 표 한 줄은 셀 묶음으로(셀마다 번역해 다시 이음), 나머지는 한 글짜리 묶음
                let inputs = (n == 0 ? [[artTitle]] : []) + chunk.map { art.blocks[$0].cells ?? [art.blocks[$0].text!] }
                let (translatedGroups, usedEngine) = await Translator.shared.translateGroupsReporting(inputs)
                var out = translatedGroups
                if usedEngine != .none { a.engine = usedEngine.rawValue } // 이 기사에 실제로 쓴 엔진(A-24)
                if n == 0 { a.title = out.removeFirst()[0] }
                for (k, i) in chunk.enumerated() where Translator.looksForeign(art.blocks[i].text!) {
                    total += 1
                    let text = art.blocks[i].cells != nil ? out[k].joined(separator: " · ") : out[k][0]
                    guard text != art.blocks[i].text else { continue } // 번역 안 된 문단은 원문 그대로(원문 보기 대상 아님)
                    done += 1
                    a.blocks[i].original = art.blocks[i].text
                    a.blocks[i].text = text
                    if art.blocks[i].cells != nil { a.blocks[i].cells = out[k] }
                }
                a.translated = done > 0
                emit(item.link, a)
            }
            a.engine = Self.engineLabel(done: done, total: total, engine: a.engine)
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
        a.savedAt = Date()
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
    // 읽기 창의 번역 표시: 번역된 문단이 없으면 표시 없음, 일부만 됐으면 '일부 번역'
    nonisolated static func engineLabel(done: Int, total: Int, engine: String) -> String {
        guard done > 0 else { return "" }
        return done < total ? engine + " · 일부 번역" : engine
    }

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
