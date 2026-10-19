import AppKit
import Foundation
import Network
import Testing
@testable import Dropcap

// 앱 안정화: 오래 켜 두기·멈춤·실패 처리에서 찾은 문제. 고치기 전에는 실패하고 고친 뒤 통과한다.
@Suite struct StabilityTests {
    static func tempDir(_ name: String) -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("dropcap-stability-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // 1200×675 JPEG(견본 사진과 같은 크기 — 풀면 약 3.2MB)
    static func jpeg(_ i: Int) -> Data {
        let w = 1200, h = 675
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor(hue: Double(i % 36) / 36, saturation: 0.6, brightness: 0.8, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .jpeg, properties: [.compressionFactor: 0.8])!
    }

    // S1: 사진 메모리 캐시가 장 수(160장)로만 묶여, 큰 사진이면 풀린 그림만 수백 MB 를 붙들었다(오래 켜 두기 6시간에 952MB).
    // 바이트 상한으로 묶어 오래된 것부터 버린다.
    @Test func imageMemoryCacheIsBoundedInBytes() async throws {
        let dir = Self.tempDir("images")
        defer { try? FileManager.default.removeItem(at: dir) }
        let loader = ImageLoader(dir: dir)
        let urls = (0..<60).map { "https://img.example.com/\($0).jpg" }
        // 디스크에 받아 둔 것처럼 놓아 두고(내려받지 않음) 차례로 연다
        for (i, u) in urls.enumerated() {
            try Self.jpeg(i).write(to: loader.diskFile(u))
            #expect(await loader.image(u) != nil)
        }
        #expect(await !loader.inMemory(urls[0]))     // 오래된 것은 버림
        #expect(await loader.inMemory(urls[59]))     // 최근 것은 남김
        #expect(await loader.memoryBytes <= ImageLoader.memoryLimitBytes)
    }
}

// 머리를 보낸 뒤 본문을 아주 천천히(0.3초마다 1바이트) 끝없이 보내는 서버 — 요청 사이 대기 시간(20초)으로는 끊기지 않는다
final class TrickleHTTP: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "trickle-http")
    private(set) var port: UInt16 = 0
    private var conns: [NWConnection] = []

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [unowned self] conn in
            conns.append(conn)
            conn.start(queue: queue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                let head = "HTTP/1.1 200 OK\r\nContent-Type: application/rss+xml\r\nConnection: close\r\n\r\n<rss><channel>"
                conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in self.drip(conn) })
            }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }
    private func drip(_ conn: NWConnection) {
        queue.asyncAfter(deadline: .now() + 0.3) {
            conn.send(content: Data(" ".utf8), completion: .contentProcessed { err in if err == nil { self.drip(conn) } })
        }
    }
    func url(_ path: String) -> String { "http://127.0.0.1:\(port)\(path)" }
    deinit { listener.cancel(); conns.forEach { $0.cancel() } }
}

// 끝나기를 기다리되 limit 초를 넘으면 nil(그 작업은 취소)
func finishes<T: Sendable>(within limit: Double, _ op: @escaping @Sendable () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { g in
        g.addTask { await op() }
        g.addTask { try? await Task.sleep(for: .seconds(limit)); return nil }
        let first = await g.next() ?? nil
        g.cancelAll()
        return first
    }
}

@Suite struct StallTests {
    // S2: 피드 하나가 아주 천천히 흘러나오면 받기가 끝나지 않아 확인(checkAll)이 영영 '확인 중'에 머물고 그 뒤 확인이 모두 건너뛰어졌다.
    // 요청 전체 시간 상한(timeoutIntervalForResource)으로 끊는다.
    @Test func slowDripFeedIsCutByDeadline() async throws {
        let server = try TrickleHTTP()
        let svc = FeedService(allowLocalForTests: true, resourceTimeout: 2)
        let url = server.url("/feed.xml")
        let result = await finishes(within: 8) { () -> String in
            do { _ = try await svc.fetch(url); return "받음" } catch { return "실패: \(error.localizedDescription)" }
        }
        #expect(result != nil, "8초 안에 끝나지 않음(천천히 흐르는 피드에 묶임)")
        #expect(result?.hasPrefix("실패") == true, "\(result ?? "-")")
    }
}

// 번역 서버가 대답하지 않는 꼴(이 시험이 켤 때만, translate.googleapis.com 만)
final class SilentTranslate: URLProtocol {
    nonisolated(unsafe) static var on = false
    override class func canInit(with request: URLRequest) -> Bool { on && request.url?.host == "translate.googleapis.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {} // 아무것도 보내지 않음
    override func stopLoading() {}
}

@Suite(.serialized) struct TranslateStallTests {
    // S3: 확인(checkAll)은 새 글 제목 번역을 기다린다. 번역 요청이 끝나지 않으면(대답 없는 프록시·천천히 흐르는 응답)
    // 확인이 끝나지 않아 S2 와 같이 그 뒤 확인이 모두 멈췄다. 요청마다 전체 시간 상한을 두고, 넘으면 원문 그대로.
    @Test func silentTranslateServerFallsBackToOriginal() async throws {
        URLProtocol.registerClass(SilentTranslate.self)
        SilentTranslate.on = true
        let saved = Translator.requestDeadline
        Translator.requestDeadline = 1.5
        Translator.resetGoogleBackoff()
        defer { SilentTranslate.on = false; URLProtocol.unregisterClass(SilentTranslate.self); Translator.requestDeadline = saved; Translator.resetGoogleBackoff() }
        let tr = Translator(mode: .google)
        let out = await finishes(within: 8) { await tr.translateMany(["Markets rally after central bank decision", "Storm hits the coast"]) }
        #expect(out == ["Markets rally after central bank decision", "Storm hits the coast"], "\(String(describing: out))")
        let en = await finishes(within: 8) { await tr.toEnglish(["정부 예산안 발표"]) }
        #expect(en != nil, "영어 제목 받기가 끝나지 않음")
    }

    // S3-나: 묶음이 시간 상한에 걸리면 문단마다 다시 보내는데(번역 한 번에 40개까지), 그 하나하나가 또 상한까지 기다려
    // 확인 한 번이 수 분씩 걸렸다. 시간 상한에 걸린 뒤 잠시(1분)는 구글을 부르지 않고 원문 그대로.
    @Test func silentServerDoesNotMultiplyWaits() async throws {
        URLProtocol.registerClass(SilentTranslate.self)
        SilentTranslate.on = true
        let saved = Translator.requestDeadline
        Translator.requestDeadline = 1
        Translator.resetGoogleBackoff()
        defer { SilentTranslate.on = false; URLProtocol.unregisterClass(SilentTranslate.self); Translator.requestDeadline = saved; Translator.resetGoogleBackoff() }
        let tr = Translator(mode: .google)
        let titles = (1...10).map { "Headline number \($0) about the economy" }
        let t0 = ProcessInfo.processInfo.systemUptime
        let out = await finishes(within: 30) { await tr.translateMany(titles) }
        let took = ProcessInfo.processInfo.systemUptime - t0
        #expect(out == titles)
        #expect(took < 4, "\(took)초 — 문단마다 상한까지 기다림")
    }
}

@Suite struct ClockChangeTests {
    // S4: 시계가 앞서 있던 때(잘못 맞춘 시계·고친 상태 파일) 켠 '1시간 잠시 끄기'가, 시계를 바로잡은 뒤에도 그만큼(며칠) 남아
    // 알림이 계속 꺼져 있었다. 잠시 끄기는 길어야 '내일 아침 8시'(32시간 안)이므로 이틀보다 먼 끝은 시계가 바뀐 것으로 보고 푼다.
    @MainActor @Test func snoozeFromFutureClockIsReleased() {
        let now = Date()
        #expect(AppModel.snoozeActive(until: now.addingTimeInterval(3600), now: now))
        #expect(AppModel.snoozeActive(until: AppModel.tomorrowMorning(), now: now))
        #expect(!AppModel.snoozeActive(until: now.addingTimeInterval(-60), now: now))
        #expect(!AppModel.snoozeActive(until: nil, now: now))
        #expect(!AppModel.snoozeActive(until: now.addingTimeInterval(10 * 24 * 3600 + 3600), now: now)) // 열흘 앞선 시계에서 켠 1시간
    }
}

@Suite struct StoryListTests {
    // S5: 스토리 목록이 스토리마다 DB 를 두 번씩 묻고(보도 JSON 을 모두 풀어) 메인 스레드에서 만들어져, 기록이 쌓일수록
    // 스토리 화면을 열거나 앱 상태가 바뀔 때마다 화면이 멈췄다(오래 켜 두기 4일 — 11ms → 940ms). 한 번에 묻는다.
    @Test func storyListAsksDatabaseOnce() throws {
        let file = StabilityTests.tempDir("stories").appendingPathComponent("m.sqlite")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let db = Database(file: file)
        let now = Date()
        for c in 0..<300 {
            let id = "c\(c)"
            db.saveCluster(Database.Cluster(id: id, title: "story \(c)", tokens: [], first: now.addingTimeInterval(-3600), last: now.addingTimeInterval(-Double(c) * 60), size: 3))
            for s in 0..<3 {
                let it = NewsItem(id: "\(c)-\(s)", title: "story \(c) by \(s)", titleKo: nil, link: "https://e.example/\(c)/\(s)", date: now.addingTimeInterval(-Double(c * 60 + s)),
                                  summary: "", sourceId: "src\(s)", sourceName: "S\(s)", tier: "press")
                db.upsert(it, cluster: id)
            }
        }
        let hidden = SourceFilter(hidden: ["src2"], active: nil)
        let before = db.statements
        let all = Magazine.stories(db: db, filter: SourceFilter(), now: now)
        let asked = db.statements - before
        #expect(all.count == 300)
        #expect(all.allSatisfy { $0.cluster.size == 3 && $0.items.count == 3 })
        #expect(asked <= 3, "스토리 300개에 문장 \(asked)번")
        // 숨긴 출처는 빼고 센다(두 곳 미만이면 목록에서 빠짐)
        let two = Magazine.stories(db: db, filter: hidden, now: now)
        #expect(two.count == 300 && two.allSatisfy { $0.cluster.size == 2 && !$0.items.contains { $0.sourceId == "src2" } })
        let one = Magazine.stories(db: db, filter: SourceFilter(hidden: ["src1", "src2"], active: nil), now: now)
        #expect(one.isEmpty)
    }
}

@Suite struct DBWriteFailureTests {
    static func item(_ i: Int) -> NewsItem {
        NewsItem(id: "w\(i)", title: "Write failure test story number \(i) about harbours", titleKo: nil, link: "https://e.example/w\(i)",
                 date: Date(), summary: "", sourceId: "src\(i % 3)", sourceName: "S", tier: "press")
    }

    // S7: DB 가 잠기거나 디스크가 가득 차 기사를 넣지 못하면, 앱 상태에는 '본 글'로 남아 다시 오지 않으므로 매거진에서 영영 빠졌다
    // (실패 처리 시험 F4·F5). 잠깐의 잠금은 기다리고(busy timeout), 그래도 못 넣은 것은 다음 받아 넣기 때 다시 넣는다.
    @Test func failedIngestIsRetried() async throws {
        let dir = StabilityTests.tempDir("dbfail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = Database(file: dir.appendingPathComponent("m.sqlite"), busyTimeoutMs: 100)
        let editor = Editor(db: db)
        let lock = DBLocker(path: db.file.path)
        #expect(lock.lock(seconds: 1.5))
        _ = await editor.ingest([Self.item(1), Self.item(2)], followed: [])
        #expect(!db.exists(Self.item(1).key))           // 잠긴 동안은 못 넣음
        #expect(await editor.retry.count == 2)
        try await Task.sleep(for: .seconds(2))
        _ = await editor.ingest([Self.item(3)], followed: [])
        #expect([1, 2, 3].allSatisfy { db.exists(Self.item($0).key) })
        #expect(await editor.retry.isEmpty)
    }

    // 못 넣은 기사는 메모리에만 있어 앱을 끄면 사라졌다(이미 '본 글'이라 피드에서 다시 오지 않음).
    // 자료 폴더 파일에 적어 두었다가 다시 켠 뒤 넣고, 다 넣으면 파일을 지운다. 깨진 파일은 빈 것으로
    @Test func retryOutlivesRestart() async throws {
        let dir = StabilityTests.tempDir("dbretry")
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = Database(file: dir.appendingPathComponent("m.sqlite"), busyTimeoutMs: 100)
        let file = dir.appendingPathComponent("ingest-retry.json")
        #expect(DBLocker(path: db.file.path).lock(seconds: 1.5))
        _ = await Editor(db: db, retryFile: file).ingest([Self.item(11), Self.item(12)], followed: [])
        #expect(FileManager.default.fileExists(atPath: file.path))
        try await Task.sleep(for: .seconds(2))
        let again = Editor(db: db, retryFile: file) // 앱을 다시 켬
        #expect(await again.retry.map(\.id) == ["w11", "w12"])
        _ = await again.ingest([], followed: [])
        #expect(db.exists(Self.item(11).key) && db.exists(Self.item(12).key))
        #expect(await again.retry.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        try Data("not json".utf8).write(to: file)
        #expect(await Editor(db: db, retryFile: file).retry.isEmpty)
    }

    // S7-나: 잠금을 기다리는 동안 메인 스레드(화면)가 멈추지 않게 — 메인에서 부른 쓰기는 0.1초만 기다리고 포기한다
    // (실패 처리 시험 F4-나: 8초 잠금에 메인이 6.5초 멈춤 — 사진 주소·점수 쓰기)
    @MainActor @Test func mainThreadWriteDoesNotWaitLong() async throws {
        let dir = StabilityTests.tempDir("dbmain")
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = Database(file: dir.appendingPathComponent("m.sqlite"), busyTimeoutMs: 3000)
        #expect(DBLocker(path: db.file.path).lock(seconds: 2))
        let t0 = ProcessInfo.processInfo.systemUptime
        #expect(Thread.isMainThread)
        #expect(!db.upsert(Self.item(7), cluster: nil))
        #expect(ProcessInfo.processInfo.systemUptime - t0 < 0.6)
        try await Task.sleep(for: .seconds(2.2))
    }

    @Test func shortLockIsWaitedOut() async throws {
        let dir = StabilityTests.tempDir("dbwait")
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = Database(file: dir.appendingPathComponent("m.sqlite"), busyTimeoutMs: 3000)
        let lock = DBLocker(path: db.file.path)
        #expect(lock.lock(seconds: 0.5))
        #expect(db.upsert(Self.item(9), cluster: nil)) // 0.5초 잠금은 기다렸다가 넣음
        #expect(db.exists(Self.item(9).key))
    }
}

@Suite struct KeywordSpeedTests {
    // S8: 한국어 낱말 찾기를 글자 그대로(.literal)로 바꿨다. 글을 NFC 로 맞추므로 자모가 풀린(NFD) 글도 같게 나뉜다
    @Test func decomposedHangulStillMatches() {
        let nfc = "한국은행 기준금리 인하 결정에 코스피 급등"
        let nfd = nfc.decomposedStringWithCanonicalMapping
        #expect(nfd.unicodeScalars.count > nfc.unicodeScalars.count) // 문자열 == 은 정규 동치로 비교하므로 스칼라 수로 확인
        #expect(Sections.hits(nfd) == Sections.hits(nfc))
        #expect(Sections.hits(nfc)["economy"] == 4) // 한국은행·기준금리·금리·코스피(겹친 낱말도 따로 셈 — 예전과 같음)
        #expect(Sections.classify(nfd) == "economy")
        #expect(NewsCategory.classify("오픈AI 새 모델 출시".decomposedStringWithCanonicalMapping) == .model)
    }
}

@Suite struct StorySeenPruneTests {
    // 남은 것 4: 본 스토리마다 '본 보도 수'(storySeen)·요약(digestCache)이 남고 지우지 않아, DB 정리로 스토리가 지워진 뒤에도
    // 상태 파일·메모리에 끝없이 쌓였다. DB 에 남은 스토리와 팔로우한 스토리 것만 남긴다(묻는 사이에 새로 본 것은 그대로).
    @MainActor @Test func storySeenDropsDeletedStories() {
        let file = StabilityTests.tempDir("storyseen").appendingPathComponent("m.sqlite")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let db = Database(file: file)
        let now = Date()
        for c in 0..<3 { db.saveCluster(Database.Cluster(id: "c\(c)", title: "s\(c)", tokens: [], first: now, last: now, size: 2)) }
        let ids = (0..<1200).map { "c\($0)" } // 500개씩 나눠 묻는 것도
        let live = db.existingClusters(ids)
        #expect(live == ["c0", "c1", "c2"])
        let seen = Dictionary(uniqueKeysWithValues: ids.map { ($0, 2) })
        var now2 = seen; now2["new"] = 5 // 묻는 사이에 본 스토리
        let kept = AppModel.prunedStorySeen(now2, asked: Set(ids), live: live, followed: ["c900"])
        #expect(Set(kept.keys) == ["c0", "c1", "c2", "c900", "new"])
        let mag = Magazine.shared
        let saved = mag.digestCache
        defer { mag.digestCache = saved }
        mag.digestCache = ["c0": (2, ["a"]), "gone": (3, ["b"])]
        mag.keepDigests(Set(kept.keys))
        #expect(Set(mag.digestCache.keys) == ["c0"])
    }
}

@Suite struct ArticleMemoryTests {
    // 남은 것 4: 디스크에서 읽은 기사를 메모리에 넣을 때 순서 목록에 넣지 않아 40개 상한 밖으로 천천히 늘었고,
    // 읽기 창을 닫아도 기사마다 빈 받아 보기 사전이 남았다.
    @MainActor @Test func diskHitsStayWithinMemoryLimit() throws {
        let dir = StabilityTests.tempDir("articles")
        defer { try? FileManager.default.removeItem(at: dir) }
        let svc = ArticleService(dir: dir)
        for i in 0..<60 {
            let link = "https://e.example/a\(i)"
            let a = PreparedArticle(stage: .done, title: "t\(i)", originalTitle: "t\(i)")
            try JSONEncoder().encode(a).write(to: svc.file(link))
            #expect(svc.cached(link)?.title == "t\(i)")
            let id = svc.observe(link) { _ in }
            svc.stopObserving(link, id)
        }
        #expect(svc.memoryCount <= 40, "메모리 \(svc.memoryCount)개")
        #expect(svc.listenedLinks == 0)
    }
}
