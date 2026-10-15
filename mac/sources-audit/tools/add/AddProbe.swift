import Foundation
import Testing
@testable import Dropcap

// 출처 추가 점검: 앱과 같은 길(FeedService.items → 사이트맵이면 fillTitle → ArticleExtractor.extract(allowScripts: true))로
// 새 출처마다 최근 기사 3건(가장 최근 · 요약이 가장 긴 것 · 제목이 가장 짧은 것)의 블록을 얻는다.
// 앱 코드를 고치지 않으려고 이 파일은 sources-audit/tools/add 에 두고, 돌릴 때만 Tests/DropcapTests 로 복사한다(run-probe.sh).
//  ADD_IDS=<출처 id,…>  ADD_OUT=<결과 폴더>
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ADD_IDS"] != nil))
struct AddProbe {
    struct FeedInfo: Encodable {
        var sourceId: String
        var ok: Bool
        var error: String?
        var count = 0
        var dated = 0
        var newestHours: Double?
        var withImage = 0
        var summaryMedian = 0
    }
    struct Out: Encodable {
        var link: String
        var title: String
        var summaryLen: Int
        var image: String?
        var hasDate: Bool
        var ok: Bool
        var seconds: Double
        var trace: ExtractTrace
        var byline: String?
        var hidden: [Int] = []
        var paywalled = false
        var chars = 0        // 보이는 블록(숨김 뺀 p·h·li·quote·cap) 글자 수
        var blocks: [Block] = []
    }
    struct Report: Encodable { var feed: FeedInfo; var articles: [Out] }

    @MainActor @Test func probe() async throws {
        let env = ProcessInfo.processInfo.environment
        let ids = env["ADD_IDS"]!.split(separator: ",").map(String.init)
        let out = env["ADD_OUT"]!
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        for id in ids {
            guard let src = Resources.config.sources.first(where: { $0.id == id }) else { NSLog("[ADD] 출처 없음 %@", id); continue }
            var info = FeedInfo(sourceId: id, ok: false)
            var items: [NewsItem] = []
            do {
                items = try await FeedService.shared.items(for: src, conditional: false) ?? []
                info.ok = true
            } catch { info.error = String(describing: error) }
            info.count = items.count
            info.dated = items.filter { $0.date != nil }.count
            info.newestHours = items.compactMap(\.date).max().map { Date().timeIntervalSince($0) / 3600 }
            info.withImage = items.filter { $0.image != nil }.count
            let sums = items.map(\.summary.count).sorted()
            info.summaryMedian = sums.isEmpty ? 0 : sums[sums.count / 2]

            var pool = Array(items.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(15))
            if src.type == "sitemap" {
                pool = Array(pool.prefix(6))
                for i in pool.indices { await FeedService.shared.fillTitle(&pool[i]); try? await Task.sleep(for: .seconds(1)) }
            }
            var picked: [NewsItem] = []
            for c in [pool.first, pool.max { $0.summary.count < $1.summary.count }, pool.min { $0.title.count < $1.title.count }] {
                if let c, !picked.contains(where: { $0.link == c.link }) { picked.append(c) }
            }
            for c in pool where picked.count < 3 && !picked.contains(where: { $0.link == c.link }) { picked.append(c) }

            var rows: [Out] = []
            for it in picked {
                guard let u = URL(string: it.link) else { continue }
                let x = ArticleExtractor()
                let t0 = Date()
                let art = await x.extract(u, allowScripts: true)
                var row = Out(link: it.link, title: it.title, summaryLen: it.summary.count, image: it.image, hasDate: it.date != nil,
                              ok: art != nil, seconds: Date().timeIntervalSince(t0), trace: x.trace)
                if let art {
                    row.byline = art.byline; row.blocks = art.blocks
                    let a = BodyCleanup.analyze(art.blocks)
                    var hide = a.skip
                    if let c = it.image, let dup = art.blocks.firstIndex(where: { $0.type == .img && ImageKey.same($0.src, c) }) { hide.insert(dup) }
                    for (i, b) in art.blocks.enumerated() where b.type == .img && ImageKey.isJunk(b.src) { hide.insert(i) }
                    for i in hide where i + 1 < art.blocks.count && art.blocks[i].type == .img && art.blocks[i + 1].type == .cap { hide.insert(i + 1) }
                    row.hidden = hide.sorted()
                    row.paywalled = Paywall.looksBlocked(art.blocks)
                    row.chars = art.blocks.enumerated().filter { !hide.contains($0.offset) && $0.element.type != .img }
                        .map { ($0.element.text ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ").count }.reduce(0, +)
                }
                NSLog("[ADD] %@ %@ %.1f초 %@ 블록 %d 글자 %d", id, row.ok ? "ok" : "no", row.seconds, row.trace.path, row.blocks.count, row.chars)
                rows.append(row)
                try? await Task.sleep(for: .seconds(1.5))
            }
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try enc.encode(Report(feed: info, articles: rows)).write(to: URL(fileURLWithPath: "\(out)/app-\(id).json"))
        }
    }
}
