import Foundation
import Testing
@testable import Dropcap

// KR1 출처 점검 2단계: 앱과 같은 길(FeedService.items → ArticleExtractor.extract(allowScripts: true))로 고른 기사의 블록을 얻는다.
// 앱 코드를 고치지 않으려고 이 파일은 sources-audit/tools/kr1 에 두고, 돌릴 때만 Tests/DropcapTests 로 복사한다(run-probe.sh).
//  KR1_FEEDS=<feeds.json>  KR1_OUT=<결과 폴더>  [KR1_ONLY=<출처 id,…>]
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["KR1_FEEDS"] != nil))
struct KR1Probe {
    struct Picked: Decodable { var link: String; var title: String }
    struct Feed: Decodable { var id: String; var picked: [Picked]? }

    struct Out: Encodable {
        var sourceId: String
        var link: String
        var app: AppItem?            // 앱의 피드 읽기가 준 것
        var ok: Bool
        var seconds: Double
        var trace: ExtractTrace
        var title: String?
        var byline: String?          // 추출기가 찾은 바이라인
        var cleanupByline: String?   // BodyCleanup 이 본문에서 빼 바이라인으로 올린 것
        var hidden: [Int] = []       // 읽기 창이 숨기는 블록(기자 줄·짝 잃은 설명·잡그림·표지와 같은 사진)
        var paywalled = false
        var blocks: [Block] = []
    }
    struct AppItem: Encodable { var summaryLen: Int; var image: String?; var hasDate: Bool; var kind: String? }

    @MainActor @Test func probe() async throws {
        let env = ProcessInfo.processInfo.environment
        let feeds = try JSONDecoder().decode([Feed].self, from: Data(contentsOf: URL(fileURLWithPath: env["KR1_FEEDS"]!)))
        let only = env["KR1_ONLY"].flatMap { $0.isEmpty ? nil : Set($0.split(separator: ",").map(String.init)) }
        let out = env["KR1_OUT"]!
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        for f in feeds where only?.contains(f.id) ?? true {
            guard let src = Resources.config.sources.first(where: { $0.id == f.id }) else { NSLog("[KR1] 출처 없음 %@", f.id); continue }
            let items = ((try? await FeedService.shared.items(for: src, conditional: false)) ?? nil) ?? []
            var rows: [Out] = []
            for p in f.picked ?? [] {
                let it = items.first { $0.link == p.link } ?? items.first { $0.title == p.title }
                let x = ArticleExtractor()
                let t0 = Date()
                let art = await x.extract(URL(string: p.link)!, allowScripts: true)
                var row = Out(sourceId: f.id, link: p.link,
                              app: it.map { AppItem(summaryLen: $0.summary.count, image: $0.image, hasDate: $0.date != nil, kind: $0.kind) },
                              ok: art != nil, seconds: Date().timeIntervalSince(t0), trace: x.trace)
                if let art {
                    row.title = art.title; row.byline = art.byline; row.blocks = art.blocks
                    let a = BodyCleanup.analyze(art.blocks)
                    var hide = a.skip
                    if let c = it?.image, let dup = art.blocks.firstIndex(where: { $0.type == .img && ImageKey.same($0.src, c) }) { hide.insert(dup) }
                    for (i, b) in art.blocks.enumerated() where b.type == .img && ImageKey.isJunk(b.src) { hide.insert(i) }
                    for i in hide where i + 1 < art.blocks.count && art.blocks[i].type == .img && art.blocks[i + 1].type == .cap { hide.insert(i + 1) }
                    row.hidden = hide.sorted(); row.cleanupByline = a.byline
                    row.paywalled = Paywall.looksBlocked(art.blocks)
                }
                NSLog("[KR1] %@ %@ %.1f초 %@ 블록 %d", f.id, row.ok ? "ok" : "no", row.seconds, row.trace.path, row.blocks.count)
                rows.append(row)
                try? await Task.sleep(for: .seconds(1.5))
            }
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try enc.encode(rows).write(to: URL(fileURLWithPath: "\(out)/app-\(f.id).json"))
        }
    }
}
