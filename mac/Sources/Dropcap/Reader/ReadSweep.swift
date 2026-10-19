import AppKit
import Foundation

// 시험 장치: 디버그 빌드(swift build·swift test·e2e·clicksweep)에만 들어간다. 배포 빌드(build.sh, -c release)에는 없음.
#if DEBUG

// 읽기 창 본문 성공률 전수 점검. 실제 기록을 건드리지 않게 DROPCAP_DATA_DIR 와 함께 쓴다.
//  DROPCAP_TEST_READSWEEP=<결과 폴더>       기본 출처 전부의 최신 기사를 받아 본문을 추리고 표로 남긴 뒤 앱을 닫는다
//  DROPCAP_TEST_READSWEEP_LABEL=before|after  결과 파일 이름(sweep-<이름>.md · .json)
//  DROPCAP_TEST_READSWEEP_N=2                 출처마다 몇 건
//  DROPCAP_TEST_READSWEEP_REPLAY=<json>       앞 점검과 같은 기사로 다시(전·후 비교)
//  DROPCAP_TEST_READSWEEP_ONLY=<출처 id,…>    그 출처만
enum ReadSweep {
    struct Target: Codable {
        var sourceId: String
        var sourceName: String
        var region: String
        var title: String
        var link: String
        var image: String?
    }

    struct Replay: Codable { var target: Target }

    struct Row: Codable {
        var target: Target
        var ok: Bool
        var seconds: Double
        var trace: ExtractTrace
        var chars = 0
        var blocks = 0
        var images = 0
        var paywalled = false
        var partial = false         // 본문 일부만 가져왔을 수 있음
        var reason = ""
        var cover: String?          // 읽기 창이 쓸 표지 주소
        var coverFrom = ""          // feed · og · none
        var coverSize: String?      // 가로×세로(픽셀)
        var coverNote: String?      // 기자 사진·로고로 보이는 까닭
        var full: FullCheck?        // 본문 완전성(DROPCAP_TEST_READSWEEP_FULL · ReadFull.swift)
    }

    @MainActor static var fullMode = false
    @MainActor static var dumpDir: String?

    // 실패(또는 느림) 까닭을 사람이 읽는 말로
    static func reason(ok: Bool, trace t: ExtractTrace, paywalled: Bool) -> String {
        if ok { return paywalled ? "맛보기만(유료벽)" : (t.path == "slow" ? "느린 길로 성공" : "") }
        if t.skipped == "unsafe" { return "주소 안전 검사 실패" }
        if let c = t.http { return [401, 403, 429].contains(c) ? "차단 \(c)" : "HTTP \(c)" }
        if let e = t.fetchError, t.visible == 0 { return "받기 실패: \(e)" }
        if let n = t.shortText { return "글 짧음(\(n)자)" }
        if t.skipped == "richPage" { return "글은 있는데 본문을 못 찾음" }
        if t.skipped == "blockedHost" { return "앞서 막힌 사이트" }
        if t.path == "slow" { return t.visible < 600 ? "JS 전용·느린 길 실패" : "느린 길 실패" }
        return "알 수 없음"
    }

    // 표지 사진이 기자 사진·로고·자리표시로 보이는지: 주소 낱말, 크기, 같은 출처의 다른 기사와 같은 사진(사이트 공용 그림)
    static func coverNote(url: String?, width: Int?, height: Int?, sameAsOther: Bool) -> String? {
        guard let url else { return nil }
        if ImageKey.isJunk(url) { return "주소가 기자 사진·로고 꼴" }
        if sameAsOther { return "같은 출처 다른 기사와 같은 사진(사이트 공용)" }
        guard let w = width, let h = height, w > 0, h > 0 else { return "사진을 못 받음" }
        let ratio = Double(w) / Double(h)
        if w < 200 || h < 120 { return "너무 작음" }
        if ratio > 3 { return "띠 모양(로고·배너)" }
        if w <= 400, ratio > 0.7, ratio < 1.3 { return "작은 정사각(얼굴·아이콘)" }
        return nil
    }

    static func markdown(_ rows: [Row], label: String, started: Date) -> String {
        let n = rows.count, ok = rows.filter(\.ok).count
        let kr = rows.filter { $0.target.region == "kr" }, intl = rows.filter { $0.target.region != "kr" }
        let slow = rows.filter { $0.seconds > 5 }
        let pct: ([Row]) -> String = { r in r.isEmpty ? "-" : String(format: "%d/%d (%.0f%%)", r.filter(\.ok).count, r.count, Double(r.filter(\.ok).count) * 100 / Double(r.count)) }
        let df = ISO8601DateFormatter()
        var s = "# 읽기 점검 \(label)\n\n"
        s += "- 때: \(df.string(from: started)) · 출처 \(Set(rows.map(\.target.sourceId)).count)곳 · 기사 \(n)건\n"
        s += "- 성공: \(pct(rows)) · 국내 \(pct(kr)) · 해외 \(pct(intl))\n"
        s += "- 빠른 길 성공 \(rows.filter { $0.ok && $0.trace.path == "fast" }.count) · 실린 본문 자료 \(rows.filter { $0.ok && $0.trace.path == "embedded" }.count) · 느린 길 성공 \(rows.filter { $0.ok && $0.trace.path == "slow" }.count) · 맛보기만 \(rows.filter(\.paywalled).count)\n"
        s += "- 5초 넘음 \(slow.count)건 · 실패 \(n - ok)건 · 표지 의심 \(rows.filter { $0.coverNote != nil }.count)건\n\n"
        var why: [String: Int] = [:]
        for r in rows where !r.ok { why[r.reason, default: 0] += 1 }
        if !why.isEmpty {
            s += "## 실패 까닭\n\n| 까닭 | 건 |\n|---|---|\n"
            for (k, v) in why.sorted(by: { $0.value > $1.value }) { s += "| \(k) | \(v) |\n" }
            s += "\n"
        }
        s += "## 기사별\n\n| 출처 | 결과 | 초 | 길 | 글자 | 문단 | 그림 | 까닭 | 표지 | 기사 |\n|---|---|---|---|---|---|---|---|---|---|\n"
        let esc: (String) -> String = { $0.replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ") }
        for r in rows {
            let cover = r.cover == nil ? "없음" : "\(r.coverFrom) \(r.coverSize ?? "?")" + (r.coverNote.map { " ⚠︎\($0)" } ?? "")
            s += "| \(esc(r.target.sourceName)) | \(r.ok ? "✓" : "✗") | \(String(format: "%.1f", r.seconds)) | \(r.trace.path) | \(r.chars) | \(r.blocks) | \(r.images) | \(esc(r.reason)) | \(esc(cover)) | [\(esc(String(r.target.title.prefix(40))))](\(r.target.link)) |\n"
        }
        return s
    }

    @MainActor
    static func run(_ env: [String: String]) {
        guard let dir = env["DROPCAP_TEST_READSWEEP"] else { return }
        let label = env["DROPCAP_TEST_READSWEEP_LABEL"] ?? "before"
        let per = Int(env["DROPCAP_TEST_READSWEEP_N"] ?? "2") ?? 2
        fullMode = env["DROPCAP_TEST_READSWEEP_FULL"] != nil
        dumpDir = env["DROPCAP_TEST_READSWEEP_DUMP"]
        let only = env["DROPCAP_TEST_READSWEEP_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let started = Date()
            var targets: [Target]
            if let replay = env["DROPCAP_TEST_READSWEEP_REPLAY"], let d = try? Data(contentsOf: URL(fileURLWithPath: replay)),
               let old = try? JSONDecoder().decode([Replay].self, from: d) { // 기사 목록만 읽는다(기록 꼴이 바뀌어도 되게)
                targets = old.map(\.target)
            } else {
                targets = await collect(per: per)
            }
            if let only { targets = targets.filter { only.contains($0.sourceId) } }
            NSLog("[읽기 점검] 기사 %d건 시작%@", targets.count, env["DROPCAP_TEST_READSWEEP_REPLAY"] == nil ? "" : " (앞 점검과 같은 기사)")
            var rows: [Row] = []
            var lastHit: [String: Date] = [:]
            if fullMode { // 원문을 한 번 더 띄우므로 같은 사이트를 잇달아 치지 않게: 출처마다 첫 기사들을 먼저, 그다음 둘째 기사들
                var nth: [String: Int] = [:]
                let ranked = targets.enumerated().map { e -> (Int, Int, Target) in
                    let k = nth[e.element.sourceId, default: 0]; nth[e.element.sourceId] = k + 1
                    return (k, e.offset, e.element)
                }
                targets = ranked.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
            }
            for (i, t) in targets.enumerated() {
                let host = URL(string: t.link)?.host ?? ""
                if fullMode, let last = lastHit[host] { // 같은 사이트는 20초 띄움(NYT 확인 문제)
                    let wait = 20 - Date().timeIntervalSince(last)
                    if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                }
                let row = await check(t)
                lastHit[host] = Date()
                rows.append(row)
                markShared(&rows)
                NSLog("[읽기 점검] %d/%d %@ %@ %.1f초 %@ %@", i + 1, targets.count, row.ok ? "ok" : "no", t.sourceName, row.seconds, row.trace.path, row.reason)
                write(rows, dir: dir, label: label, started: started) // 도중에 멈춰도 그때까지는 남게
            }
            NSLog("[읽기 점검] 끝")
            NSApp.terminate(nil)
        }
    }

    // 같은 출처의 다른 기사와 표지가 같으면 사이트 공용 그림(로고·기본 사진)
    static func markShared(_ rows: inout [Row]) {
        for i in rows.indices {
            guard let c = rows[i].cover else { continue }
            if rows.contains(where: { $0.target.sourceId == rows[i].target.sourceId && $0.target.link != rows[i].target.link && $0.cover == c }) {
                rows[i].coverNote = coverNote(url: c, width: nil, height: nil, sameAsOther: true)
            }
        }
    }

    static func write(_ rows: [Row], dir: String, label: String, started: Date) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(rows).write(to: URL(fileURLWithPath: "\(dir)/sweep-\(label).json"))
        try? markdown(rows, label: label, started: started).write(toFile: "\(dir)/sweep-\(label).md", atomically: true, encoding: .utf8)
    }

    // 기본 출처마다 최신 기사 몇 건(동시에 8곳씩 받는다)
    static func collect(per: Int) async -> [Target] {
        let sources = Resources.config.sources
        var out: [String: [Target]] = [:]
        for chunk in stride(from: 0, to: sources.count, by: 8).map({ Array(sources[$0..<min($0 + 8, sources.count)]) }) {
            await withTaskGroup(of: (String, [Target]).self) { g in
                for src in chunk {
                    g.addTask {
                        let items = ((try? await FeedService.shared.items(for: src, conditional: false)) ?? nil) ?? []
                        let latest = items.filter { !$0.link.isEmpty }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(per)
                        if latest.isEmpty { NSLog("[읽기 점검] %@ 피드에서 기사를 못 받음", src.id) }
                        let region = src.region ?? (src.tier == "kr" ? "kr" : "intl")
                        return (src.id, latest.map { Target(sourceId: src.id, sourceName: src.name, region: region, title: $0.title, link: $0.link, image: $0.image) })
                    }
                }
                for await (id, t) in g { out[id] = t }
            }
        }
        return sources.flatMap { out[$0.id] ?? [] }
    }

    @MainActor
    static func check(_ t: Target) async -> Row {
        let x = ArticleExtractor()
        let t0 = Date()
        var art: Article?
        if let u = URL(string: t.link) { art = await x.extract(u, allowScripts: true) }
        var row = Row(target: t, ok: art != nil, seconds: Date().timeIntervalSince(t0), trace: x.trace)
        if let art {
            row.chars = art.blocks.compactMap(\.text).joined().count
            row.blocks = art.blocks.filter { $0.text != nil }.count
            row.images = art.blocks.filter { $0.type == .img }.count
            row.paywalled = Paywall.isTeaser(art.blocks, paid: art.paid, kind: Paywall.kind(sourceId: t.sourceId, link: t.link), ldBody: art.ldBody) // 읽기 창과 같은 판정
            row.partial = art.partial == true
        }
        if fullMode, let u = URL(string: t.link) { row.full = await ReadFull().measure(u, ours: art?.blocks ?? []) }
        // [로컬 진단] 추린 블록을 결과 폴더에 그대로 남김(기사 글이 들어가므로 저장소에 넣지 않는다)
        if let dir = dumpDir, let art, let d = try? JSONEncoder().encode(art.blocks) {
            try? d.write(to: URL(fileURLWithPath: dir).appendingPathComponent("blocks-\(abs(t.link.hashValue % 100000)).json"))
            NSLog("[읽기 점검] 블록 %@ → blocks-%d.json", t.link, abs(t.link.hashValue % 100000))
        }
        row.reason = reason(ok: row.ok, trace: row.trace, paywalled: row.paywalled)
        // 읽기 창의 표지 찾기와 같은 순서(ReaderModel.findCover): 피드 사진 → 작거나 못 받으면 기사 머리 대표 사진(og:image)
        var feedLoads = false
        if let i = t.image, !ImageKey.isJunk(i) {
            row.cover = i; row.coverFrom = "feed"
            let img = await ImageLoader.shared.image(i)
            feedLoads = img != nil
            NSLog("[읽기 점검] 피드 사진 %@ %@", img.map { "\(Int($0.size.width))×\(Int($0.size.height))" } ?? "못 받음", i)
            if let img, CoverPick.bigEnough(img) { return await measure(row) }
        }
        if let og = await CoverPick.ogImage(t.link), og != row.cover {
            if ImageKey.isJunk(og) { if row.cover == nil { row.coverNote = "og 사진이 기자 사진·로고 꼴이라 뺌" } }
            else if let img = await ImageLoader.shared.image(og), !feedLoads || CoverPick.bigEnough(img) { row.cover = og; row.coverFrom = row.cover == t.image ? "feed" : (t.image == nil || ImageKey.isJunk(t.image) ? "og" : "feed→og") }
        }
        if row.cover == nil { row.coverFrom = "none" }
        else if row.cover == t.image, !feedLoads { row.cover = nil; row.coverFrom = "none"; row.coverNote = "피드 사진을 못 받고 대신할 사진도 없음" }
        return await measure(row)
    }

    @MainActor
    static func measure(_ r: Row) async -> Row {
        var row = r
        if let c = row.cover {
            var w: Int?, h: Int?
            if let img = await ImageLoader.shared.image(c) {
                w = Int(img.size.width); h = Int(img.size.height)
                row.coverSize = "\(w!)×\(h!)"
            }
            row.coverNote = coverNote(url: c, width: w, height: h, sameAsOther: false)
        }
        return row
    }
}

#endif
