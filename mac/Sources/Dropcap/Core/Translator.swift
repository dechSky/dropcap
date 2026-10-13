import Foundation
import NaturalLanguage
import Translation

// 한국어 번역. macOS 26 이상에서 언어 자료가 기기에 받아져 있으면 애플 기기 내 번역(무료·비공개)을 쓰고,
// 아니면 구글 번역 공개 엔드포인트를 쓴다. 둘 다 실패하면 원문을 그대로 돌려준다.
actor Translator {
    static let shared = Translator()
    private let target = Locale.Language(identifier: "ko")
    private var cache: [String: String] = [:]

    enum Engine: String { case apple = "기기 내 번역(Apple)", google = "Google 번역", none = "번역 안 함" }
    private(set) var lastEngine: Engine = .none

    static func looksForeign(_ text: String) -> Bool {
        let s = text.filter { !$0.isWhitespace }
        guard !s.isEmpty else { return false }
        let hangul = s.unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) }.count
        return Double(hangul) / Double(s.count) < 0.2
    }

    // 한국어 제목을 영어로(같은 소식 비교용). 실패하면 nil.
    func toEnglish(_ texts: [String]) async -> [String?] {
        await withTaskGroup(of: (Int, String?).self) { g in
            for (i, t) in texts.enumerated() { g.addTask { (i, await Self.google(t, target: "en")) } }
            var out = [String?](repeating: nil, count: texts.count)
            for await (i, r) in g { out[i] = r }
            return out
        }
    }

    func translate(_ text: String) async -> String {
        let src = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.looksForeign(src) else { return text }
        if let c = cache[src] { return c }
        if cache.count > 4000 { cache.removeAll(keepingCapacity: true) } // 오래 켜 둬도 무한히 커지지 않게
        let out = await translateMany([src]).first ?? src
        return out
    }

    // 여러 문단을 한 번에. 순서를 지킨다.
    func translateMany(_ texts: [String]) async -> [String] {
        var result = texts
        let todo = texts.indices.filter { Self.looksForeign(texts[$0]) && cache[texts[$0]] == nil }
        for i in texts.indices where cache[texts[i]] != nil { result[i] = cache[texts[i]]! }
        guard !todo.isEmpty else { return result }

        let sample = todo.prefix(5).map { texts[$0] }.joined(separator: " ")
        if let apple = await appleTranslate(todo.map { texts[$0] }, sample: sample) {
            for (k, i) in todo.enumerated() { result[i] = apple[k]; cache[texts[i]] = apple[k] }
            lastEngine = .apple
            return result
        }
        // 구글: 문단 여러 개를 빈 줄로 이어 한 번에 보내고(요청 수를 줄여 빠르게), 묶음들은 동시에 보낸다.
        // 돌아온 문단 수가 안 맞으면 그 묶음만 문단별로 다시 보낸다.
        var batches: [[Int]] = [[]]
        var size = 0
        for i in todo {
            let n = texts[i].count
            if size + n > 3800, !batches[batches.count - 1].isEmpty { batches.append([]); size = 0 }
            batches[batches.count - 1].append(i); size += n + 2
        }
        await withTaskGroup(of: [(Int, String)].self) { group in
            for batch in batches where !batch.isEmpty {
                group.addTask {
                    let joined = batch.map { texts[$0].replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n\n")
                    if let out = await Self.google(joined) {
                        let parts = out.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                        if parts.count == batch.count { return Array(zip(batch, parts)) }
                    }
                    var one: [(Int, String)] = []
                    for i in batch { if let t = await Self.google(texts[i]) { one.append((i, t)) } }
                    return one
                }
            }
            for await pairs in group {
                for (i, t) in pairs { result[i] = t; cache[texts[i]] = t }
            }
        }
        lastEngine = .google
        return result
    }

    private func appleTranslate(_ texts: [String], sample: String) async -> [String]? {
        guard #available(macOS 26.0, *) else { return nil }
        let rec = NLLanguageRecognizer()
        rec.processString(sample)
        guard let lang = rec.dominantLanguage, lang != .korean else { return nil }
        let source = Locale.Language(identifier: lang.rawValue)
        guard await LanguageAvailability().status(from: source, to: target) == .installed else { return nil }
        do {
            let session = TranslationSession(installedSource: source, target: target)
            let reqs = texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
            let resps = try await session.translations(from: reqs)
            var out = texts
            for r in resps { if let id = r.clientIdentifier, let i = Int(id) { out[i] = r.targetText } }
            return out
        } catch {
            return nil
        }
    }

    // 영어→한국어 기기 내 번역 자료가 받아져 있는지
    static func appleReady() async -> Bool {
        guard #available(macOS 26.0, *) else { return false }
        return await LanguageAvailability().status(from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: "ko")) == .installed
    }

    private static func google(_ text: String, target: String = "ko") async -> String? {
        var c = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        c.queryItems = [.init(name: "client", value: "gtx"), .init(name: "sl", value: "auto"), .init(name: "tl", value: target),
                        .init(name: "dt", value: "t"), .init(name: "q", value: String(text.prefix(4500)))]
        guard let url = c.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(FeedService.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let segs = json.first as? [Any] else { return nil }
        let out = segs.compactMap { ($0 as? [Any])?.first as? String }.joined()
        return out.isEmpty ? nil : out
    }
}
