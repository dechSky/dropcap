import Foundation
import Testing
@testable import Dropcap

// 피드 본문 전문(NewsItem.feedBody)은 피드 기록 DB 의 items 줄에만 남고, 앱 상태(최근·나중에 읽기·고인 소식)·스크랩·백업에는 빠진다
@Suite struct FeedBodyTrimTests {
    private let body = "<p>" + String(repeating: "Long feed paragraph text. ", count: 2_300) + "</p>" // 약 60KB
    private func item(_ n: Int, body: String? = nil) -> NewsItem {
        NewsItem(id: "\(n)", title: "Story \(n)", titleKo: nil, link: "https://example.com/\(n)", date: Date(timeIntervalSince1970: 1_790_000_000),
                 summary: "s", sourceId: "src", sourceName: "Src", tier: "press", feedBody: body)
    }

    @Test func plainEncodingDropsFeedBody() throws {
        let data = try JSONEncoder().encode(item(1, body: body))
        #expect(data.count < 1_000)
        #expect(try JSONDecoder().decode(NewsItem.self, from: data).feedBody == nil)
    }

    @Test func databaseItemRowKeepsFeedBody() throws {
        let data = try Database.itemEncoder.encode(item(1, body: body))
        #expect(try Database.decoder.decode(NewsItem.self, from: data).feedBody == body)
    }

    @Test func savedStateAndScrapsDropFeedBody() throws {
        var s = AppState()
        s.saved = (1...20).map { item($0, body: body) }
        s.recent = (21...40).map { item($0, body: body) }
        s.pending = [AppState.PendingItem(item: item(41, body: body), section: "tech", story: "x", at: Date())]
        let data = try JSONEncoder().encode(s)
        #expect(data.count < 30_000, "상태 파일 \(data.count)바이트 — 41건 × 60KB 가 들어가면 2.4MB")
        let back = try JSONDecoder().decode(AppState.self, from: data)
        #expect(back.saved.count == 20 && back.saved.allSatisfy { $0.feedBody == nil })
        #expect(back.recent.allSatisfy { $0.feedBody == nil } && back.pending.allSatisfy { $0.item.feedBody == nil })

        let scrap = Scrap(item: item(1, body: body), quote: "q", collection: "스크랩")
        let sd = try Database.encoder.encode(scrap)
        #expect(sd.count < 1_000)
        #expect(try Database.decoder.decode(Scrap.self, from: sd).item.feedBody == nil)
    }

    @Test func olderFilesStillRead() throws {
        // 칸이 없는 예전 기록 · 3단계 첫 판(9a3a87b)이 글을 그대로 적은 기록 · null
        let base = #""id":"a","title":"t","link":"https://example.com","summary":"","sourceId":"s","sourceName":"S","tier":"intl""#
        #expect(try JSONDecoder().decode(NewsItem.self, from: Data("{\(base)}".utf8)).feedBody == nil)
        // 백업·상태 파일 같은 기본 디코더는 글이 있어도 버리고, 피드 기록 DB 디코더만 받는다
        #expect(try JSONDecoder().decode(NewsItem.self, from: Data("{\(base),\"feedBody\":\"<p>x</p>\"}".utf8)).feedBody == nil)
        #expect(try Database.decoder.decode(NewsItem.self, from: Data("{\(base),\"feedBody\":\"<p>x</p>\"}".utf8)).feedBody == "<p>x</p>")
        #expect(try JSONDecoder().decode(NewsItem.self, from: Data("{\(base),\"feedBody\":null}".utf8)).feedBody == nil)
    }

    @Test func reupsertOfTrimmedCopyKeepsDatabaseBody() throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("dropcap-feedbody-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: d) }
        let db = Database(file: d.appendingPathComponent("magazine.sqlite"))
        db.upsert(item(1, body: body), cluster: nil)
        db.upsert(item(1), cluster: nil) // 나중에 읽기에서 온 사본(본문 없음)으로 다시
        #expect(db.items(keys: [item(1).key]).first?.item.feedBody == body)
        db.upsert(item(1, body: "<p>new</p>"), cluster: nil) // 피드가 새 본문을 주면 바뀜
        #expect(db.items(keys: [item(1).key]).first?.item.feedBody == "<p>new</p>")
    }

    @Test func equalityDoesNotNeedWholeBody() {
        #expect(item(1, body: body) == item(1, body: body))
        #expect(item(1, body: body) != item(1))
    }
}
