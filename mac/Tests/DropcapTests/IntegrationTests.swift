import AppKit
import DropcapShared
import Foundation
import Testing
@testable import Dropcap

// 위젯 스냅숏 형식 · 단축어 매개변수 해석 · Spotlight 색인 비교 · dropcap:// 주소
struct IntegrationTests {
    private func item(_ id: String, _ title: String, mins: Double, source: String = "openai", image: String? = nil, ko: String? = nil) -> NewsItem {
        var it = NewsItem(id: id, title: title, titleKo: ko, link: "https://example.com/\(id)", date: Date(timeIntervalSince1970: 1_800_000_000 - mins * 60),
                          summary: "", sourceId: source, sourceName: source.uppercased(), tier: "lab")
        it.image = image
        return it
    }

    @Test func snapshotPicksCoverAndLatestWithoutDuplicates() {
        let recent = (0..<8).map { item("a\($0)", "제목 \($0)", mins: Double($0)) }
        let snap = WidgetExporter.makeSnapshot(cover: recent[2], recent: recent, unread: 4,
                                               image: { $0.id == "a2" || $0.id == "a0" ? "https://img/\($0.id).jpg" : nil })
        #expect(snap.cover?.key == recent[2].key)
        #expect(snap.latest.count == WidgetExporter.latestCount)
        #expect(!snap.latest.contains { $0.key == recent[2].key })
        #expect(snap.latest.first?.key == recent[0].key)
        #expect(snap.cover?.image == WidgetExporter.imageFileName(recent[2].key))
        #expect(snap.latest[0].image != nil && snap.latest[1].image == nil)
        #expect(snap.unread == 4)
    }

    @Test func snapshotWithoutCoverUsesNewestAndClampsUnread() {
        let recent = [item("x", "English", mins: 1, ko: "한국어 제목"), item("y", "Y", mins: 2)]
        let snap = WidgetExporter.makeSnapshot(cover: nil, recent: recent, unread: -3)
        #expect(snap.cover?.key == recent[0].key)
        #expect(snap.cover?.title == "한국어 제목")
        #expect(snap.latest.map(\.key) == [recent[1].key])
        #expect(snap.unread == 0)
        #expect(WidgetExporter.makeSnapshot(cover: nil, recent: [], unread: 0).cover == nil)
    }

    @Test func snapshotJSONRoundTripsAndRejectsNewerVersion() throws {
        let snap = WidgetExporter.makeSnapshot(cover: nil, recent: [item("k", "T", mins: 0)], unread: 2, now: Date(timeIntervalSince1970: 1_800_000_000))
        let data = try #require(snap.encoded())
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"version\":1"))
        #expect(json.contains("\"updated\":\"2027-01-15T08:00:00Z\""))
        #expect(WidgetSnapshot.decode(data) == snap)
        let newer = json.replacingOccurrences(of: "\"version\":1", with: "\"version\":99")
        #expect(WidgetSnapshot.decode(Data(newer.utf8)) == nil)
        #expect(WidgetSnapshot.decode(Data("깨진".utf8)) == nil)
    }

    @Test func widgetContentLoadsSnapshotAndIgnoresPathTricks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("widget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(WidgetContent.load(from: dir).snapshot == .empty) // 없으면 빈 사본
        let img = NSImage(size: NSSize(width: 800, height: 400), flipped: false) { r in NSColor.red.setFill(); r.fill(); return true }
        let jpg = try #require(WidgetExporter.shrink(img))
        let shrunk = try #require(NSImage(data: jpg))
        #expect(shrunk.representations.first?.pixelsWide == 480)
        try jpg.write(to: dir.appendingPathComponent("img-a.jpg"))
        let snap = WidgetSnapshot(updated: Date(), unread: 1,
                                  cover: .init(key: "a|1", title: "A", source: "S", date: nil, image: "img-a.jpg"),
                                  latest: [.init(key: "b|1", title: "B", source: "S", date: nil, image: "../../etc/passwd")])
        try #require(snap.encoded()).write(to: dir.appendingPathComponent(WidgetSnapshot.fileName))
        let c = WidgetContent.load(from: dir)
        #expect(c.snapshot.cover?.key == "a|1")
        #expect(c.images.keys.sorted() == ["img-a.jpg"])
    }

    @Test func openLinksRoundTripKeysWithSpecialCharacters() {
        let key = "openai|https://openai.com/news/a?b=1&c=2#x"
        let u = WidgetLink.open(key: key)
        #expect(u.scheme == "dropcap" && u.host == "open")
        #expect(WidgetLink.key(from: u) == key)
        #expect(WidgetLink.key(from: URL(string: "dropcap://open")!) == nil)
        #expect(WidgetLink.key(from: URL(string: "https://open?key=a")!) == nil)
        #expect(WidgetLink.key(from: URL(string: "DROPCAP://OPEN?key=z")!) == "z")
    }

    @Test func sectionParameterResolves() {
        #expect(IntentLogic.section(nil) == .all)
        #expect(IntentLogic.section("  ") == .all)
        #expect(IntentLogic.section("전체") == .all)
        #expect(IntentLogic.section("연구") == .only(.research))
        #expect(IntentLogic.section("Model") == .only(.model))
        #expect(IntentLogic.section("모델·제품") == .only(.model))
        #expect(IntentLogic.section("투자") == .only(.business))   // '투자·기업' 앞부분
        #expect(IntentLogic.section("기업") == .only(.business))   // 가운뎃점 뒤 낱말
        #expect(IntentLogic.section("날씨") == .unknown)
        #expect(IntentLogic.sectionNames.count == NewsCategory.allCases.count)
    }

    @Test func countAndLatestFilter() {
        #expect(IntentLogic.count(nil) == 5)
        #expect(IntentLogic.count(0) == 1)
        #expect(IntentLogic.count(500) == IntentLogic.maxCount)
        let items = [item("p", "New benchmark paper from researchers", mins: 5), item("m", "OpenAI launches new model", mins: 1),
                     item("q", "Another research study", mins: 3)]
        #expect(IntentLogic.latest(items, section: nil, count: 2).map(\.id) == ["m", "q"])
        #expect(IntentLogic.latest(items, section: .research, count: 5).map(\.id) == ["q", "p"])
    }

    @Test func saveURLParameter() {
        #expect(IntentLogic.savableURL("https://example.com/a")?.absoluteString == "https://example.com/a")
        #expect(IntentLogic.savableURL(" example.com/news ")?.absoluteString == "https://example.com/news")
        #expect(IntentLogic.savableURL("http://192.168.0.1/admin") == nil)
        #expect(IntentLogic.savableURL("localhost:8080") == nil)
        #expect(IntentLogic.savableURL("file:///etc/passwd") == nil)
        #expect(IntentLogic.savableURL("") == nil)
        let u = URL(string: "https://www.example.com/x")!
        let it = IntentLogic.savedItem(u, title: "  기사 제목 ")
        #expect(it.title == "기사 제목" && it.sourceName == "example.com" && it.link == u.absoluteString)
        #expect(IntentLogic.savedItem(u, title: nil).title == u.absoluteString)
        #expect(IntentLogic.pageTitle("<html><head><title>Hello &amp; bye</title></head>") == "Hello & bye")
        #expect(IntentLogic.pageTitle(#"<meta property="og:title" content="OG 제목"><title>t</title>"#) == "OG 제목")
        #expect(IntentLogic.pageTitle("<p>none</p>") == nil)
    }

    @Test func spotlightDiffAddsChangesAndRemoves() {
        let a = item("a", "A", mins: 1), b = item("b", "B", mins: 2)
        let scrap = Scrap(item: b, quote: "인용", memo: "메모", collection: "조사")
        let docs = SpotlightIndexer.docs(saved: [a], scraps: [scrap])
        #expect(docs.map(\.id) == ["saved:" + a.key, "scrap:" + scrap.id])
        #expect(docs[1].detail.contains("인용") && docs[1].detail.contains("메모: 메모"))
        #expect(docs[1].keywords.contains("조사"))
        let first = SpotlightIndexer.diff(previous: [:], current: docs)
        #expect(first.upsert.count == 2 && first.remove.isEmpty)
        let prev = Dictionary(uniqueKeysWithValues: docs.map { ($0.id, $0.fingerprint) })
        #expect(SpotlightIndexer.diff(previous: prev, current: docs).upsert.isEmpty)
        var edited = scrap; edited.memo = "바뀜"
        let after = SpotlightIndexer.docs(saved: [], scraps: [edited])
        let d = SpotlightIndexer.diff(previous: prev, current: after)
        #expect(d.upsert.map(\.id) == ["scrap:" + scrap.id])
        #expect(d.remove == ["saved:" + a.key])
    }
}
