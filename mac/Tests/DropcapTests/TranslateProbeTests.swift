import Foundation
import NaturalLanguage
import Testing
import Translation
@testable import Dropcap

// 읽기 창 번역 품질 점검(mac/TRANSLATE.md). 실제 기사를 빠른 길(스크립트 없음)로 추리고, 앱과 같은 방식으로 번역해
// 문단별로 나란히 JSON 으로 남긴다. 기사 본문이 들어가므로 결과는 저장소 밖(관리자·작업자 임시 폴더)에 둔다.
//  DROPCAP_TRANSLATE_PROBE=<결과 폴더>        켜기
//  DROPCAP_TRANSLATE_PROBE_URLS=<주소 목록 파일>  한 줄에 하나(# 는 주석). 줄 끝에 " ref" 를 붙이면 문단별 단독 번역(기준)도,
//                                            " apple" 이면 기기 내 번역(받아져 있을 때)도 받는다
//  번역 서버를 짧은 시간에 너무 많이 치지 않게 요청 사이를 띄운다(gap)
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DROPCAP_TRANSLATE_PROBE"] != nil))
@MainActor
struct TranslateProbeTests {
    struct Para: Codable {
        var type: String
        var src: String
        var batched: String?      // 앱의 구글 길: 묶음으로 보내 돌려받은 것(묶음 문단 수가 맞았을 때)
        var fallback: String?     // 묶음 문단 수가 틀려 문단별로 다시 받은 것
        var single: String?       // 기준: 그 문단만 따로 보낸 것(ref 일 때)
        var apple: String?        // 기기 내 번역(받아져 있으면)
        var batch: Int            // 몇 번째 묶음
    }
    struct Batch: Codable { var sent: Int; var got: Int; var chars: Int; var matched: Bool }
    struct Report: Codable {
        var url: String
        var ok: Bool
        var title: String?
        var paras: [Para] = []
        var batches: [Batch] = []
        var skippedPre = 0
        var appleLang: String?
        var appleStatus: String?
        var requests = 0
        var seconds = 0.0
        var googleSeconds = 0.0   // 앱과 같은 묶음 길만(간격 포함)
        var appleSeconds: Double?
    }

    static let gap: UInt64 = 350_000_000
    static var requests = 0

    static func gtx(_ text: String) async -> String? {
        try? await Task.sleep(nanoseconds: gap)
        requests += 1
        var c = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        c.queryItems = [.init(name: "client", value: "gtx"), .init(name: "sl", value: "auto"), .init(name: "tl", value: "ko"),
                        .init(name: "dt", value: "t"), .init(name: "q", value: String(text.prefix(Translator.requestLimit)))]
        var req = URLRequest(url: c.url!, timeoutInterval: 15)
        req.setValue(FeedService.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let segs = json.first as? [Any] else { return nil }
        let out = segs.compactMap { ($0 as? [Any])?.first as? String }.joined()
        return out.isEmpty ? nil : out
    }

    // Translator.translateManyRaw 의 구글 길을 그대로 옮김(묶음 3800자·빈 줄 잇기·문단 수 맞추기)
    static func googleBatched(_ texts: [String], into paras: inout [Para], idx: [Int], batches: inout [Batch]) async {
        var groups: [[Int]] = [[]]
        var size = 0
        for k in texts.indices {
            let n = texts[k].count
            if size + n > 3800, !groups[groups.count - 1].isEmpty { groups.append([]); size = 0 }
            groups[groups.count - 1].append(k); size += n + 2
        }
        for group in groups where !group.isEmpty {
            let joined = group.map { texts[$0].replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n\n")
            var got = 0, matched = false
            if let out = await gtx(joined) {
                let parts = out.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                got = parts.count
                if parts.count == group.count {
                    matched = true
                    for (k, p) in zip(group, parts) { paras[idx[k]].batched = p; paras[idx[k]].batch = batches.count }
                }
            }
            if !matched {
                for k in group { paras[idx[k]].fallback = await gtx(texts[k]); paras[idx[k]].batch = batches.count }
            }
            batches.append(Batch(sent: group.count, got: got, chars: joined.count, matched: matched))
        }
    }

    static func apple(_ texts: [String], report: inout Report) async -> [String]? {
        guard #available(macOS 26.0, *) else { report.appleStatus = "macOS 26 아님"; return nil }
        let rec = NLLanguageRecognizer()
        rec.processString(texts.prefix(5).joined(separator: " "))
        guard let lang = rec.dominantLanguage else { return nil }
        report.appleLang = lang.rawValue
        let source = Locale.Language(identifier: lang.rawValue), target = Locale.Language(identifier: "ko")
        let st = await LanguageAvailability().status(from: source, to: target)
        report.appleStatus = "\(st)"
        guard st == .installed else { return nil }
        do {
            let session = TranslationSession(installedSource: source, target: target)
            let reqs = texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
            var out = [String](repeating: "", count: texts.count)
            for r in try await session.translations(from: reqs) { if let id = r.clientIdentifier, let i = Int(id) { out[i] = r.targetText } }
            return out
        } catch {
            report.appleStatus = "오류: \(error)"
            return nil
        }
    }

    @Test func probe() async throws {
        let env = ProcessInfo.processInfo.environment
        let outDir = URL(fileURLWithPath: env["DROPCAP_TRANSLATE_PROBE"]!)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let lines = try String(contentsOfFile: env["DROPCAP_TRANSLATE_PROBE_URLS"]!, encoding: .utf8)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        for (n, line) in lines.enumerated() {
            let parts = line.split(separator: " ")
            let link = String(parts[0]), wantRef = parts.contains("ref"), wantApple = parts.contains("apple")
            let t0 = Date(), r0 = Self.requests
            var rep = Report(url: link, ok: false)
            let ex = ArticleExtractor()
            guard let url = URL(string: link), let art = await ex.extract(url, allowScripts: false) else {
                try JSONEncoder().encode(rep).write(to: outDir.appendingPathComponent(String(format: "%02d.json", n)))
                continue
            }
            rep.ok = true
            rep.title = art.title
            // ArticleService.run 과 같이: 글 있는 블록 중 pre 는 빼고, 제목 + 첫 8문단 → 나머지
            let idx = art.blocks.indices.filter { art.blocks[$0].text != nil && art.blocks[$0].type != .pre }
            rep.skippedPre = art.blocks.filter { $0.type == .pre }.count
            var paras = [Para(type: "title", src: art.title ?? "", batch: -1)]
            paras += idx.map { Para(type: art.blocks[$0].type.rawValue, src: art.blocks[$0].text!, batch: -1) }
            let pIdx = Array(paras.indices)
            let first = Array(pIdx.prefix(9)), rest = Array(pIdx.dropFirst(9))
            let g0 = Date()
            for chunk in [first, rest] where !chunk.isEmpty {
                // 앱처럼 한글이 적은 것만 보냄
                let todo = chunk.filter { Translator.looksForeign(paras[$0].src) }
                await Self.googleBatched(todo.map { paras[$0].src }, into: &paras, idx: todo, batches: &rep.batches)
            }
            rep.googleSeconds = Date().timeIntervalSince(g0)
            if wantRef {
                for i in paras.indices where Translator.looksForeign(paras[i].src) { paras[i].single = await Self.gtx(paras[i].src) }
            }
            if wantApple {
                let a0 = Date()
                if let a = await Self.apple(paras.map(\.src), report: &rep) { for i in paras.indices { paras[i].apple = a[i] } }
                rep.appleSeconds = Date().timeIntervalSince(a0)
            }
            rep.paras = paras
            rep.requests = Self.requests - r0
            rep.seconds = Date().timeIntervalSince(t0)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try enc.encode(rep).write(to: outDir.appendingPathComponent(String(format: "%02d.json", n)))
            print("[번역점검] \(n) \(link) 문단 \(paras.count) 묶음 \(rep.batches.map { "\($0.sent)/\($0.got)" }) 요청 \(rep.requests) 애플 \(rep.appleStatus ?? "-")")
        }
    }

    // 기기 내 번역 속도(케이스 5): 실제 기사로 '첫 4문단이 바뀌기까지'와 '모두 끝날 때까지'를 잰다. 부하는 bugak load 로 함께 적는다.
    //  DROPCAP_TRANSLATE_SPEED=<주소 목록 파일>
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DROPCAP_TRANSLATE_SPEED"] != nil))
    func appleSpeed() async throws {
        let lines = try String(contentsOfFile: ProcessInfo.processInfo.environment["DROPCAP_TRANSLATE_SPEED"]!, encoding: .utf8)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        for link in lines {
            guard let url = URL(string: link), let art = await ArticleExtractor().extract(url, allowScripts: false) else { continue }
            let texts = art.blocks.filter { $0.type != .pre }.compactMap(\.text)
            // 한 번에(지금 앱)
            let t0 = Date()
            _ = await Translator(mode: .apple).translateManyReporting(texts)
            let whole = Date().timeIntervalSince(t0)
            // 4문단씩 흘려 받기
            final class First: @unchecked Sendable { var at: Double? }
            let first = First(), t1 = Date()
            _ = await Translator(mode: .apple).translateStreaming(texts, chunk: 4) { _, _ in if first.at == nil { first.at = Date().timeIntervalSince(t1) } }
            let streamed = Date().timeIntervalSince(t1)
            print(String(format: "[기기내속도] %@ 문단 %d · 한 번에 %.1f초 · 4문단씩 첫 바뀜 %.1f초 / 모두 %.1f초", link, texts.count, whole, first.at ?? -1, streamed))
        }
    }
}
