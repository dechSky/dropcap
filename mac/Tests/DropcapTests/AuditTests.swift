import Foundation
import Testing
@testable import Dropcap

// 코드 점검에서 고친 버그들의 시험. 모두 바깥 서버·실제 사용자 기록 없이 돈다.

@Suite struct EntityDecodeTests {
    @Test func decodesCommonAndNumericEntities() {
        #expect(Plain.clean("Sam&rsquo;s &ldquo;agent&rdquo; &#x2019; &#8217; &hellip; &mdash;") == "Sam’s “agent” ’ ’ … —")
    }
    @Test func decodesOnlyOnce() { // &amp;lt; 는 '&lt;' 글자 그대로여야 한다(예전엔 사전 순서에 따라 '<' 가 되기도 했다)
        #expect(Plain.clean("a &amp;lt;b&amp;gt; c") == "a &lt;b&gt; c")
        #expect(Plain.clean("AT&amp;T") == "AT&T")
    }
    @Test func leavesUnknownAndBareAmpersands() {
        #expect(Plain.clean("R&D &unknownthing; &#0; x & y") == "R&D &unknownthing; &#0; x & y")
    }
}

@Suite struct TranslatorCacheTests {
    @Test func cacheStaysUnderLimit() async { // 기사 본문 번역(translateMany)도 상한을 지켜야 한다
        let t = Translator()
        for i in 0...(Translator.cacheLimit + 10) { await t.remember("text \(i)", "번역 \(i)") }
        #expect(await t.cacheCount <= Translator.cacheLimit)
        #expect(await t.cacheCount > 0)
    }
}

@Suite struct SiteLocalIPv6Tests {
    @Test func blocksSiteLocal() {
        #expect(!URLSafety.isPublicHTTP(URL(string: "http://[fec0::1]/")))
        #expect(!URLSafety.isPublicHTTP(URL(string: "http://[feff::1]/")))
        #expect(URLSafety.isPublicHTTP(URL(string: "https://[2606:4700::1111]/")))
    }
}

@Suite struct StateRecoveryTests {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("dropcap-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func corruptFileFallsBackToBackup() throws {
        let d = try tempDir()
        defer { try? FileManager.default.removeItem(at: d) }
        let main = d.appendingPathComponent("native-state.json"), bak = d.appendingPathComponent("native-state.bak.json")
        try Data("{\"seen\": {\"a|1\": 1".utf8).write(to: main) // 중간에 잘린 파일
        try Data(#"{"seen":{"a|1":1},"unread":3,"seeded":["a"]}"#.utf8).write(to: bak)
        let (s, fromBackup) = Store.read(main, backup: bak)
        #expect(fromBackup)
        #expect(s.unread == 3 && s.seeded == ["a"])
        #expect(FileManager.default.fileExists(atPath: d.appendingPathComponent("native-state.broken.json").path))
    }

    @Test func corruptWithoutBackupStartsFresh() throws {
        let d = try tempDir()
        defer { try? FileManager.default.removeItem(at: d) }
        let main = d.appendingPathComponent("native-state.json")
        try Data("not json".utf8).write(to: main)
        let (s, fromBackup) = Store.read(main, backup: d.appendingPathComponent("native-state.bak.json"))
        #expect(fromBackup) // .bak 을 덮어쓰지 않게 표시
        #expect(s.seen.isEmpty)
    }

    @Test func healthyFileReadsNormally() throws {
        let d = try tempDir()
        defer { try? FileManager.default.removeItem(at: d) }
        let main = d.appendingPathComponent("native-state.json")
        try Data(#"{"unread":5}"#.utf8).write(to: main)
        let (s, fromBackup) = Store.read(main, backup: d.appendingPathComponent("x.json"))
        #expect(!fromBackup && s.unread == 5)
        let (_, missing) = Store.read(d.appendingPathComponent("none.json"), backup: d.appendingPathComponent("x.json"))
        #expect(!missing) // 처음 실행은 복구가 아니다
    }

    @Test func seenIsPrunedOldestFirst() {
        var seen: [String: Double] = [:]
        for i in 0..<10 { seen["k\(i)"] = Double(i) }
        let p = Store.pruned(seen, limit: 6)
        #expect(p.count == 6)
        #expect(p["k0"] == nil && p["k3"] == nil && p["k4"] != nil && p["k9"] != nil)
        #expect(Store.pruned(seen, limit: 20).count == 10)
    }
}

@Suite struct DatabaseRecoveryTests {
    @Test func garbageFileIsMovedAsideAndRecreated() throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("dropcap-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("magazine.sqlite")
        try Data(repeating: 0x41, count: 4096).write(to: f) // SQLite 파일이 아님
        let db = Database(file: f)
        let it = NewsItem(id: "1", title: "OpenAI ships a model", titleKo: nil, link: "https://openai.com/a", date: Date(),
                          summary: "", sourceId: "openai", sourceName: "OpenAI", tier: "lab")
        db.upsert(it, cluster: nil)
        #expect(db.itemCount == 1) // 예전에는 모든 쓰기가 조용히 실패했다
        #expect(FileManager.default.fileExists(atPath: d.appendingPathComponent("magazine.broken.sqlite").path))
    }

    @Test func healthyFileIsKept() throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("dropcap-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("magazine.sqlite")
        let it = NewsItem(id: "1", title: "t", titleKo: nil, link: "https://a.com/1", date: Date(), summary: "", sourceId: "s", sourceName: "S", tier: "press")
        Database(file: f).upsert(it, cluster: nil)
        #expect(Database(file: f).itemCount == 1)
        #expect(!FileManager.default.fileExists(atPath: d.appendingPathComponent("magazine.broken.sqlite").path))
    }
}

@Suite struct EnrichPickTests {
    private func stored(_ id: String, image: String? = nil) -> Database.StoredItem {
        .init(item: NewsItem(id: id, title: id, titleKo: nil, link: "https://a.com/\(id)", date: Date(), summary: "",
                             sourceId: "s", sourceName: "S", tier: "press", image: image), firstSeen: Date(), cluster: nil)
    }
    @Test func skipsAlreadyTried() { // 사진을 못 찾은 최신 12건만 계속 다시 받던 문제
        let items = (0..<20).map { stored("\($0)") } + [stored("img", image: "https://a.com/x.jpg")]
        let first = Magazine.toEnrich(items, tried: [])
        #expect(first.count == 12 && first.first?.item.id == "0")
        let next = Magazine.toEnrich(items, tried: Set(first.map(\.item.key)))
        #expect(next.map(\.item.id) == (12..<20).map { "\($0)" })
    }
}

@Suite @MainActor struct TranslatedPageTests {
    @Test func keepsEncodedPath() { // 공백·한글이 든 주소는 예전엔 nil 이 되어 '번역된 웹페이지로 보기'가 사라졌다
        let it = NewsItem(id: "1", title: "t", titleKo: nil, link: "https://www.ai-news.co.kr/news/AI%20%ED%95%9C%EA%B8%80?id=3",
                          date: nil, summary: "", sourceId: "s", sourceName: "S", tier: "kr")
        let u = ReaderModel(item: it).translatedPageURL
        #expect(u?.absoluteString == "https://www-ai--news-co-kr.translate.goog/news/AI%20%ED%95%9C%EA%B8%80?id=3&_x_tr_sl=auto&_x_tr_tl=ko&_x_tr_hl=ko")
    }
}
