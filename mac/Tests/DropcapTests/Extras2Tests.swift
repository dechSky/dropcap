import Foundation
import Network
import Testing
@testable import Dropcap

// 남은 개선 2차: 받는 크기 상한 · 지켜볼 낱말 · 내 기록 내보내기·가져오기 · 점검 남은 작은 문제

// 내 Mac 안의 시험 서버: 경로마다 보낼 크기와 Content-Length 를 밝힐지 정한다. 보낸 바이트 수를 센다.
final class LocalHTTP: @unchecked Sendable {
    struct Reply { var length: Int; var declare: Bool }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "local-http")
    private let lock = NSLock()
    private var sent: [String: Int] = [:]
    private(set) var port: UInt16 = 0

    init(_ route: @escaping @Sendable (String) -> Reply) throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [unowned self] conn in
            conn.start(queue: self.queue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                let line = data.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\r\n").first ?? ""
                let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let r = route(path)
                var head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n"
                if r.declare { head += "Content-Length: \(r.length)\r\n" }
                conn.send(content: Data((head + "\r\n").utf8), completion: .contentProcessed { _ in self.pump(conn, path: path, left: r.length) })
            }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    private func pump(_ conn: NWConnection, path: String, left: Int) {
        guard left > 0 else { conn.send(content: nil, isComplete: true, completion: .contentProcessed { _ in conn.cancel() }); return }
        let n = min(left, 128 << 10)
        conn.send(content: Data(repeating: 0x61, count: n), completion: .contentProcessed { err in
            guard err == nil else { conn.cancel(); return }
            self.lock.lock(); self.sent[path, default: 0] += n; self.lock.unlock()
            self.pump(conn, path: path, left: left - n)
        })
    }

    func sentBytes(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return sent[path] ?? 0 }
    func url(_ path: String) -> String { "http://127.0.0.1:\(port)\(path)" }
    deinit { listener.cancel() }
}

// MARK: 1. 받는 크기 상한(S-12)
@Suite(.serialized) struct FetchLimitTests {
    static let server = try! LocalHTTP { path in
        switch path {
        case "/small": return .init(length: 1024, declare: true)
        case "/declared-11mb": return .init(length: 11 << 20, declare: true)
        case "/stream-60mb": return .init(length: 60 << 20, declare: false)
        case "/page-3mb": return .init(length: 3 << 20, declare: false)
        case "/image-9mb": return .init(length: 9 << 20, declare: true)
        default: return .init(length: 10, declare: true)
        }
    }
    let svc = FeedService(allowLocalForTests: true)

    @Test func smallResponsePasses() async throws {
        let d = try await svc.fetch(Self.server.url("/small"))
        #expect(d?.count == 1024)
    }

    @Test func declaredTooLargeStopsBeforeBody() async throws {
        await #expect(throws: FeedError.self) { try await svc.fetch(Self.server.url("/declared-11mb")) }
    }

    @Test func undeclaredStreamIsCutAtLimit() async throws {
        let t0 = Date()
        await #expect(throws: FeedError.self) { try await svc.fetch(Self.server.url("/stream-60mb")) }
        try await Task.sleep(for: .milliseconds(500))
        // 60MB 를 다 받지 않고 끊었다(소켓 버퍼만큼은 더 갔을 수 있음)
        #expect(Self.server.sentBytes("/stream-60mb") < 40 << 20, "\(Self.server.sentBytes("/stream-60mb"))")
        #expect(Date().timeIntervalSince(t0) < 15)
    }

    @Test func limitsDependOnKind() async throws {
        await #expect(throws: FeedError.self) { try await svc.fetch(Self.server.url("/page-3mb"), limit: .page) }
        #expect(try await svc.fetch(Self.server.url("/page-3mb"), limit: .feed)?.count == 3 << 20)
        await #expect(throws: FeedError.self) { try await svc.fetch(Self.server.url("/image-9mb"), limit: .image) }
    }

    @Test func collectStopsAtLimit() async throws {
        let stream = AsyncStream<UInt8> { c in for _ in 0..<100 { c.yield(1) }; c.finish() }
        await #expect(throws: FeedError.self) { try await FeedService.collect(stream, expected: -1, limit: 50) }
        let ok = AsyncStream<UInt8> { c in for _ in 0..<50 { c.yield(1) }; c.finish() }
        #expect(try await FeedService.collect(ok, expected: 50, limit: 50).count == 50)
        let empty = AsyncStream<UInt8> { $0.finish() }
        await #expect(throws: FeedError.self) { try await FeedService.collect(empty, expected: 51, limit: 50) } // 헤더만 보고 거절
    }

    @Test func limitValues() {
        #expect(FetchLimit.feed.rawValue == 10 << 20 && FetchLimit.page.rawValue == 2 << 20 && FetchLimit.image.rawValue == 8 << 20)
        #expect(FeedError.tooLarge(10 << 20).localizedDescription.contains("10MB"))
    }
}

// MARK: 2. 지켜볼 낱말(N-27 · D-6)
@Suite struct WatchWordTests {
    private func item(_ title: String, key: String = UUID().uuidString, ko: String? = nil, date: Date = Date()) -> NewsItem {
        NewsItem(id: key, title: title, titleKo: ko, link: "https://a.example/\(key)", date: date, summary: "", sourceId: "s", sourceName: "S", tier: "press")
    }

    @Test func englishWordBoundaryKoreanSubstring() {
        #expect(WatchWords.matches("Apple", in: "Apple unveils new chip"))
        #expect(!WatchWords.matches("Apple", in: "Pineapple prices rise"))
        #expect(WatchWords.matches("apple", in: "APPLE's results"))
        #expect(WatchWords.matches("삼성전자", in: "삼성전자가 신제품을 공개했다"))
        #expect(WatchWords.matches("AI 기본법", in: "국회, AI 기본법 개정안 통과"))
        #expect(WatchWords.matches("GPT-6", in: "OpenAI ships GPT-6 today"))
        #expect(!WatchWords.matches("GPT-6", in: "OpenAI ships GPT-60 today"))
    }

    @Test func matchUsesTranslatedTitleAndOrder() {
        let it = item("Samsung profit jumps", ko: "삼성전자 이익 급증")
        #expect(WatchWords.match(it, words: ["엔비디아", "삼성전자", "Samsung"]) == "삼성전자")
        #expect(WatchWords.match(it, words: ["엔비디아"]) == nil)
        #expect(WatchWords.normalized([" 삼성전자 ", "", "Apple", "apple"]) == ["삼성전자", "Apple"])
    }

    @Test func dailyDigestCountsPerWord() {
        let now = Date()
        let list = [item("Nvidia earnings beat", key: "1", date: now.addingTimeInterval(-60)),
                    item("Nvidia and Apple team up", key: "2", date: now),
                    item("Nvidia earnings beat", key: "1", date: now.addingTimeInterval(-60)), // 같은 기사
                    item("Unrelated", key: "3")]
        let d = WatchWords.digest(list, words: ["Nvidia", "Apple", "Tesla"])
        #expect(d.map(\.word) == ["Nvidia", "Apple"])
        #expect(d[0].items.map(\.id) == ["2", "1"])
    }

    @Test func watchedStoryNotifiesRegardlessOfSectionButRespectsTotalCap() {
        let l = PolicyLimits()
        var i = NotifyPolicy.Input(chosen: false, policy: SectionPolicy(mode: .magazine), coverage: Coverage(kr: 1, intl: 0), watched: true)
        #expect(NotifyPolicy.decide(i, limits: l) == .drop)
        i.sentTotal = l.totalCap
        #expect(NotifyPolicy.decide(i, limits: l) == .pool)
        i.coverage = Coverage(kr: 9, intl: 0)
        #expect(NotifyPolicy.decide(i, limits: l) == .drop) // 크게 보도된 소식은 상한을 넘어도
        i.watched = false; i.coverage = Coverage(kr: 1, intl: 0); i.sentTotal = 0
        #expect(NotifyPolicy.decide(i, limits: l) == .quiet)
    }

    @Test func oldSettingsHaveNoWatchWords() throws {
        let s = try JSONDecoder().decode(AppState.Settings.self, from: Data(#"{"mustKeywords":["x"]}"#.utf8))
        #expect(s.watchKeywords.isEmpty && s.mustKeywords == ["x"])
    }
}

// MARK: 3. 내 기록 내보내기·가져오기(P-08)
@Suite struct BackupTests {
    private func news(_ id: String) -> NewsItem {
        NewsItem(id: id, title: "T\(id)", titleKo: nil, link: "https://a.example/\(id)", date: Date(timeIntervalSince1970: 1_800_000_000),
                 summary: "", sourceId: "s", sourceName: "S", tier: "press")
    }
    private func source(_ id: String) -> Source {
        Source(id: id, name: id, tier: "press", type: "feed", url: "https://\(id).example/feed", match: nil, aiOnly: false, defaultOn: true, color: "#000")
    }

    private var home: (AppState, [Scrap]) {
        var s = AppState()
        s.settings.digestHour = 7
        s.settings.mustKeywords = ["GPT-6"]
        s.settings.watchKeywords = ["삼성전자"]
        s.sectionsChosen = ["ai", "economy"]
        s.sectionPolicy = ["economy": SectionPolicy(mode: .bundle, bundleHour: 17)]
        s.enabled = ["verge": true, "nyt": false]
        s.notify = ["verge": false]
        s.customSources = [source("custom-a")]
        s.hiddenSources = ["spam"]
        s.followedStories = ["story-1"]
        s.saved = [news("1"), news("2")]
        let scraps = [Scrap(id: "sc1", item: news("1"), quote: "문단", memo: "메모", collection: "보고서", created: Date(timeIntervalSince1970: 1_800_000_000))]
        return (s, scraps)
    }

    @Test func roundTripsAndRejectsOtherFiles() throws {
        let (s, scraps) = home
        let b = Backup.make(s, scraps: scraps, folders: ["스크랩", "보고서", "빈 폴더"], now: Date(timeIntervalSince1970: 1_800_000_000))
        let data = try Backup.encode(b)
        #expect(try Backup.decode(data) == b)
        #expect(!String(decoding: data, as: UTF8.self).contains("\"read\"")) // 읽음 기록·본 글 기억은 담지 않음
        #expect(throws: Backup.Failure.self) { try Backup.decode(Data(#"{"hello":1}"#.utf8)) }
        #expect(throws: Backup.Failure.self) { try Backup.decode(Data(#"{"format":"dropcap-backup","version":99}"#.utf8)) }
        let partial = try Backup.decode(Data(#"{"format":"dropcap-backup","version":1,"saved":[]}"#.utf8)) // 빠진 항목은 기본값
        #expect(partial.scraps.isEmpty && partial.settings == AppState.Settings())
    }

    @Test func mergeIntoFreshMacTakesEverything() {
        let (s, scraps) = home
        let b = Backup.make(s, scraps: scraps, folders: ["스크랩", "보고서", "빈 폴더"])
        let m = Backup.merge(b, into: AppState(), scraps: [], folders: ["스크랩"])
        #expect(m.state.settings == s.settings)
        #expect(m.state.sectionsChosen == ["economy", "ai"]) // 분야 순서로
        #expect(m.state.sectionPolicy["economy"]?.bundleHour == 17)
        #expect(m.state.enabled["verge"] == true && m.state.enabled["nyt"] == nil)
        #expect(m.state.customSources.map(\.id) == ["custom-a"])
        #expect(m.state.saved.map(\.id) == ["1", "2"])
        #expect(m.newScraps.map(\.id) == ["sc1"])
        #expect(m.folders == ["스크랩", "보고서", "빈 폴더"])
        #expect(m.summary.settingsTaken && m.summary.saved == 2 && m.summary.scraps == 1)
    }

    @Test func mergeIntoUsedMacSkipsSameAndKeepsLocal() {
        let (s, scraps) = home
        let b = Backup.make(s, scraps: scraps, folders: ["보고서"])
        var mine = AppState()
        mine.settings.digestHour = 10                // 이 Mac 에서 바꾼 값은 지킨다
        mine.settings.mustKeywords = ["gpt-6", "Claude"]
        mine.enabled = ["verge": false, "nyt": true] // 가져온 쪽이 켠 것은 켜고, 이 Mac 에서 켠 것은 끄지 않는다
        mine.notify = ["verge": true]
        mine.saved = [news("2"), news("9")]
        mine.customSources = [Source(id: "other", name: "x", tier: "press", type: "feed", url: "https://custom-a.example/feed", match: nil, aiOnly: false, defaultOn: true, color: "#000")]
        let sameScrap = Scrap(id: "different-id", item: news("1"), quote: "문단", collection: "보고서")
        let m = Backup.merge(b, into: mine, scraps: [sameScrap], folders: ["스크랩", "보고서"])
        #expect(m.state.settings.digestHour == 10 && !m.summary.settingsTaken)
        #expect(m.state.settings.mustKeywords == ["gpt-6", "Claude"])   // 대소문자만 다른 같은 낱말은 건너뜀
        #expect(m.state.settings.watchKeywords == ["삼성전자"])
        #expect(m.state.enabled == ["verge": true, "nyt": true])
        #expect(m.state.notify["verge"] == true)
        #expect(m.state.saved.map(\.id) == ["2", "9", "1"])
        #expect(m.state.customSources.count == 1)                        // 같은 주소는 건너뜀
        #expect(m.newScraps.isEmpty)                                      // 같은 기사·문단·폴더
        #expect(m.state.hiddenSources == ["spam"] && m.state.followedStories == ["story-1"])
        let again = Backup.merge(b, into: m.state, scraps: [sameScrap], folders: m.folders) // 두 번 가져와도 그대로
        #expect(again.summary == Backup.Summary())
        #expect(again.summary.text.contains("새로 더할 것이 없었습니다"))
    }

    @Test func restoreUndoesImport() {
        let (s, scraps) = home
        let before = Backup.make(AppState(), scraps: [], folders: [])
        let merged = Backup.merge(Backup.make(s, scraps: scraps, folders: []), into: AppState(), scraps: [], folders: []).state
        var back = Backup.restore(before, into: merged)
        back.seen = merged.seen
        #expect(back.saved.isEmpty && back.customSources.isEmpty && back.settings == AppState.Settings() && back.sectionsChosen == nil)
    }
}

// MARK: 4. 점검 남은 작은 문제
@Suite struct AuditLeftoverTests {
    @Test func longParagraphSplitsAtSentences() { // 긴 문단은 문장 단위로
        let sentence = "This is a sentence about the economy and markets today. "
        let text = String(repeating: sentence, count: 120) // 약 6800자
        let chunks = Translator.sentenceChunks(text, max: Translator.requestLimit)
        #expect(chunks.count == 2)
        #expect(chunks.allSatisfy { $0.count <= Translator.requestLimit })
        #expect(chunks.joined() == text)                       // 아무것도 잃지 않음
        #expect(chunks[0].hasSuffix(". "))                     // 문장 끝에서 나눔
        let one = String(repeating: "가", count: 10_000)       // 문장 끝이 없는 아주 긴 글
        let parts = Translator.sentenceChunks(one, max: 4500)
        #expect(parts.map(\.count) == [4500, 4500, 1000] && parts.joined() == one)
        #expect(Translator.sentenceChunks("짧은 글", max: 4500) == ["짧은 글"])
    }

    @Test func engineComesFromCacheNotGlobal() async { // 엔진은 기사마다(T-08)
        let t = Translator()
        await t.remember("Cached apple sentence", "캐시된 문장", engine: .apple)
        let r = await t.translateManyReporting(["Cached apple sentence"])
        #expect(r.texts == ["캐시된 문장"] && r.engine == .apple)
        let none = await t.translateManyReporting(["이미 한국어입니다"])
        #expect(none.engine == .none)
    }

    @Test func entriesWithoutGuidOrLinkGetDistinctStableIDs() throws { // guid·link 가 빈 글의 id
        let xml = """
        <rss><channel>
        <item><title>First</title><pubDate>Mon, 12 Oct 2026 09:00:00 GMT</pubDate></item>
        <item><title>Second</title><pubDate>Mon, 12 Oct 2026 10:00:00 GMT</pubDate></item>
        <item><title>Has link</title><link>https://a.example/x</link></item>
        </channel></rss>
        """
        let e = try FeedParser.parseFeed(Data(xml.utf8))
        #expect(e[0].id != e[1].id && !e[0].id.isEmpty && e[0].id.hasPrefix("noid-"))
        #expect(e[2].id == "https://a.example/x")
        #expect(try FeedParser.parseFeed(Data(xml.utf8))[0].id == e[0].id) // 다시 읽어도 같은 값
        #expect(FeedParser.fallbackID("A", "1") != FeedParser.fallbackID("A", "2"))
    }

    @Test func folderMigrationResumesAfterPartialFailure() throws { // 폴더 옮기기 이어 하기
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dropcap-mig-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let old = root.appendingPathComponent("AI News Alert"), new = root.appendingPathComponent("Dropcap")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("old-state".utf8).write(to: old.appendingPathComponent("native-state.json"))
        try Data("old-db".utf8).write(to: old.appendingPathComponent("magazine.sqlite"))
        // 지난번에 state 만 옮기고 멈췄다(표시 남음). 그 사이 새 앱이 state 를 새로 썼다
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        try Data().write(to: new.appendingPathComponent(".migrating"))
        try Data("new-state".utf8).write(to: new.appendingPathComponent("native-state.json"))
        #expect(Store.migrateOldFolder(from: old, to: new))
        #expect(try String(contentsOf: new.appendingPathComponent("magazine.sqlite"), encoding: .utf8) == "old-db") // 빠진 것만 옮김
        #expect(try String(contentsOf: new.appendingPathComponent("native-state.json"), encoding: .utf8) == "new-state") // 덮어쓰지 않음
        #expect(!fm.fileExists(atPath: new.appendingPathComponent(".migrating").path))
        #expect(!Store.migrateOldFolder(from: old, to: new)) // 다 옮겼으면 다시 하지 않음

        let fresh = root.appendingPathComponent("Fresh")
        #expect(Store.migrateOldFolder(from: old, to: fresh))
        #expect(fm.fileExists(atPath: fresh.appendingPathComponent("native-state.json").path))
        #expect(!Store.migrateOldFolder(from: root.appendingPathComponent("none"), to: root.appendingPathComponent("x")))
    }

    @Test func guardWithoutMetricsGivesUpAndLateWaitDoesNotHang() async { // 늦은 기다림도 멈추지 않음
        let g = RequestGuard()
        let t0 = Date()
        #expect(await g.isSafe() == false)  // 측정값이 끝내 안 오면 막음
        #expect(await g.isSafe() == false)  // 두 번째도 끝없이 기다리지 않음
        #expect(Date().timeIntervalSince(t0) < 6)
    }
}
