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
    var progress: Int? = nil          // 번역 중: 받은 문단 수 / 번역할 문단 수(읽기 창 '기기 내 번역 중 n/m')
    var progressTotal: Int? = nil
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
    private let dir: URL
    init(dir: URL = Store.dir.appendingPathComponent("articles", isDirectory: true)) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.dir = dir
    }
    private let diskLimit = 150

    // 진행 상황을 받아 보기(읽기 창). 돌려받은 id 로 그만 받기.
    func observe(_ link: String, _ cb: @escaping (PreparedArticle) -> Void) -> UUID {
        let id = UUID()
        listeners[link, default: [:]][id] = cb
        return id
    }
    func stopObserving(_ link: String, _ id: UUID) {
        listeners[link]?[id] = nil
        if listeners[link]?.isEmpty == true { listeners[link] = nil } // 빈 사전이 기사마다 남지 않게
    }
    var listenedLinks: Int { listeners.count }

    // 읽기 창이 닫히거나 J/K 로 다른 기사로 갔다: 그만 받고, 번역 중인데 보는 창이 없으면 번역을 멈춘다.
    // 받은 문단은 Translator 캐시에 남아 다시 열면 그 자리부터 빠르게 이어진다
    func release(_ link: String, _ id: UUID) {
        stopObserving(link, id)
        guard Self.shouldStop(stage: memory[link]?.stage, watchers: listeners[link]?.count ?? 0), let t = inflight[link] else { return }
        NSLog("[기사] 읽기 창이 떠나 번역을 멈춤")
        t.cancel()
    }

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
        remember(link, a) // 디스크에서 읽은 것도 순서 목록에 넣어 40개 상한 안에(예전엔 빠져 천천히 늘었음)
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
            // 미리 받기가 스크립트 없이 실패했으면, 사용자가 열었을 때는 제대로 다시 시도.
            // 앞 창이 떠나 번역을 멈춘 작업이면(release) 지금 보는 창이 있을 때만 다시
            let stopped = r.stage == .translating && listeners[item.link]?.isEmpty == false
            if r.stage == .failed || stopped, interactive {
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

    private func remember(_ link: String, _ a: PreparedArticle) {
        if memory[link] == nil {
            order.append(link)
            if order.count > 40 { memory.removeValue(forKey: order.removeFirst()) } // 메모리에는 최근 40개만
        }
        memory[link] = a
    }
    var memoryCount: Int { memory.count }

    private func emit(_ link: String, _ a: PreparedArticle) {
        remember(link, a)
        listeners[link]?.values.forEach { $0(a) }
    }

    // 피드 본문은 글 링크가 출처 피드와 같은 사이트일 때만(출처를 모르면 쓰지 않음)
    nonisolated static func usableFeedBody(_ body: String?, link: String, sourceURL: String?) -> String? {
        guard let body, let sourceURL, FeedService.sameSite(link, sourceURL) else { return nil }
        return body
    }

    // 읽기 창이 쓸 피드 본문: 들고 온 사본에 없으면(나중에 읽기·스크랩 — 저장 때 뺌) 피드 기록 DB 에서 다시 찾고,
    // 출처 피드와 다른 사이트 링크의 본문은 쓰지 않는다 — 받을 때도 거르지만(FeedService.sameSite) 그 전에 DB 에 들어간 것까지
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
            guard await Self.translateBody(&a, blocks: art.blocks, title: artTitle, translator: .shared, emit: { self.emit(item.link, $0) }) else {
                memory.removeValue(forKey: item.link) // 다 못 한 것은 남기지 않는다(다시 열면 처음부터 — 받은 문단은 번역 캐시에서)
                order.removeAll { $0 == item.link }
                return a
            }
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
    func file(_ link: String) -> URL {
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
    // 본문 번역: 제목+첫 8문단 → 나머지 순서로 보내고, 끝난 묶음(기기 내는 chunk 문단씩)마다 바꿔 끼워 emit 한다.
    // 바뀐 문단은 원문을 original 에 남긴다(문단별 원문 펼치기). 중간에 작업이 취소되면(release) 받은 데까지 두고 false
    @discardableResult
    static func translateBody(_ a: inout PreparedArticle, blocks: [Block], title artTitle: String, translator: Translator,
                              chunk: Int = 4, emit: (PreparedArticle) -> Void) async -> Bool {
        let idx = blocks.indices.filter { blocks[$0].text != nil && blocks[$0].type != .pre }
        let first = Array(idx.prefix(8)), rest = Array(idx.dropFirst(8))
        var received = Set<Int>()
        a.progress = 0
        a.progressTotal = idx.filter { Translator.looksForeign(blocks[$0].text!) }.count
        // 받은 묶음 하나를 제자리에: 번역 안 된 문단은 원문 그대로(원문 보기 대상 아님)
        func put(_ out: [String], at i: Int) {
            guard Translator.looksForeign(blocks[i].text!) else { return }
            received.insert(i)
            let text = blocks[i].cells != nil ? out.joined(separator: " · ") : out[0]
            guard text != blocks[i].text else { return }
            a.blocks[i].original = blocks[i].text
            a.blocks[i].text = text
            if blocks[i].cells != nil { a.blocks[i].cells = out }
        }
        for (n, part) in [first, rest].enumerated() where !part.isEmpty || n == 0 {
            // 표 한 줄은 셀 묶음으로(셀마다 번역해 다시 이음), 나머지는 한 글짜리 묶음. 첫 묶음 0번은 제목
            let lead = n == 0 ? 1 : 0
            let inputs = (n == 0 ? [[artTitle]] : []) + part.map { blocks[$0].cells ?? [blocks[$0].text!] }
            func place(_ g: Int, _ out: [String]) { if g < lead { a.title = out[0] } else { put(out, at: part[g - lead]) } }
            // Translator actor 에서 오는 알림을 MainActor 로 넘겨 받는다
            let (stream, cont) = AsyncStream.makeStream(of: ([Int: [String]], Translator.Engine).self)
            func send() async -> (groups: [[String]], engine: Translator.Engine) {
                defer { cont.finish() }
                return await translator.translateGroupsStreaming(inputs, chunk: chunk) { got, engine in cont.yield((got, engine)) }
            }
            async let finished = send()
            var emitted = false
            for await (got, engine) in stream {
                if engine != .none { a.engine = engine.rawValue } // 이 기사에 실제로 쓴 엔진(A-24)
                for (g, out) in got.sorted(by: { $0.key < $1.key }) { place(g, out) }
                a.progress = received.count
                a.translated = a.blocks.contains { $0.original != nil }
                emit(a); emitted = true
            }
            let (groups, usedEngine) = await finished
            if usedEngine != .none { a.engine = usedEngine.rawValue }
            for (g, out) in groups.enumerated() { place(g, out) } // 흘려 받지 못한 것(실패해 원문 그대로 등)까지 맞춘다
            a.progress = received.count
            a.translated = a.blocks.contains { $0.original != nil }
            if Task.isCancelled { return false }
            if !emitted { emit(a) }
        }
        let total = a.progressTotal ?? 0
        let done = idx.filter { a.blocks[$0].original != nil }.count
        a.engine = engineLabel(done: done, total: total, engine: a.engine)
        a.progress = nil; a.progressTotal = nil
        return true
    }
}

extension ArticleService {
    // 읽기 창이 떠날 때 멈출지: 번역 중이고 보는 창이 더는 없을 때만(본문 받는 중에 끊으면 실패로 남는다)
    nonisolated static func shouldStop(stage: PreparedArticle.Stage?, watchers: Int) -> Bool {
        stage == .translating && watchers == 0
    }

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
