import Foundation
import NaturalLanguage
import Translation

// 한국어 번역. 설정의 번역 방식(translateEngine)을 따른다(mac/TRANSLATE.md).
//  자동: macOS 26 이상에서 언어 자료가 기기에 받아져 있으면 애플 기기 내 번역(무료·비공개), 아니면 구글 번역 공개 엔드포인트
//  기기 내만: 기기 내 번역이 안 되면 원문 그대로(구글로 보내지 않음) · Google: 늘 구글 · 번역 안 함: 원문 그대로
// 어느 길이든 실패하면 원문을 그대로 돌려준다.
actor Translator {
    static let shared = Translator(followSettings: true)
    private var cache: [String: String] = [:]
    private var cacheEngine: [String: Engine] = [:] // 캐시에서 꺼낸 번역도 어느 엔진 것인지 알게(A-24)

    enum Engine: String { case apple = "기기 내 번역(Apple)", google = "Google 번역", none = "번역 안 함" }
    private(set) var lastEngine: Engine = .none

    // 설정 키 translateEngine 의 값. 윈도우·리눅스도 같은 이름·값을 쓴다(그쪽에는 apple 대신 기기 내 엔진이 없어 auto=google)
    enum Mode: String, Codable, CaseIterable { case auto, apple, google, off }

    // 엔진 부르기(시험에서 네트워크 없이 바꿔 끼운다). apple 은 nil 이면 '기기 내 번역을 쓸 수 없음'
    typealias GoogleCall = @Sendable (String) async -> String?
    typealias AppleCall = @Sendable ([String], String) async -> [String]?
    private let modeSource: @Sendable () async -> Mode
    private let googleCall: GoogleCall
    private let appleCall: AppleCall
    private var lastMode: Mode?

    init(mode: Mode = .auto, google: GoogleCall? = nil, apple: AppleCall? = nil) {
        self.init(modeSource: { mode }, google: google, apple: apple)
    }

    init(modeSource: @escaping @Sendable () async -> Mode, google: GoogleCall? = nil, apple: AppleCall? = nil) {
        self.modeSource = modeSource
        googleCall = google ?? { await Translator.google($0) }
        appleCall = apple ?? { await Translator.appleTranslate($0, sample: $1) }
    }

    // 앱 전체에 하나: 번역할 때마다 지금 설정을 읽는다(시험 프로세스에서 AppModel 을 깨우지 않게 shared 만)
    private init(followSettings: Bool) {
        modeSource = { await MainActor.run { AppModel.shared.state.settings.translateEngine } }
        googleCall = { await Translator.google($0) }
        appleCall = { await Translator.appleTranslate($0, sample: $1) }
    }

    // 설정이 바뀌어 엔진이 달라지면 다른 엔진의 번역이 섞여 나오지 않게 캐시를 비운다(케이스 11)
    private func currentMode() async -> Mode {
        let m = await modeSource()
        if let last = lastMode, last != m { cache.removeAll(keepingCapacity: true); cacheEngine.removeAll(keepingCapacity: true) }
        lastMode = m
        return m
    }

    // 외국어로 보이는가: 한글이 20% 미만. 글자가 하나도 없거나(숫자·기호뿐) 주소 하나뿐인 글은 번역할 것이 없다(케이스 8)
    static func looksForeign(_ text: String) -> Bool {
        let s = text.filter { !$0.isWhitespace }
        guard !s.isEmpty, s.contains(where: \.isLetter) else { return false }
        if s.count == text.trimmingCharacters(in: .whitespacesAndNewlines).count,
           s.range(of: #"^(https?://|www\.)\S+$"#, options: [.regularExpression, .caseInsensitive]) != nil { return false }
        let hangul = s.unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) }.count
        return Double(hangul) / Double(s.count) < 0.2
    }

    // 한국어 제목을 영어로(같은 소식 비교용). 실패하면 nil.
    // '기기 내만'·'번역 안 함'이면 밖으로 보내지 않는다(nil)
    func toEnglish(_ texts: [String]) async -> [String?] {
        let mode = await currentMode()
        guard mode == .auto || mode == .google else { return texts.map { _ in nil } }
        return await withTaskGroup(of: (Int, String?).self) { g in
            for (i, t) in texts.enumerated() { g.addTask { (i, await Self.google(t, target: "en")) } }
            var out = [String?](repeating: nil, count: texts.count)
            for await (i, r) in g { out[i] = r }
            return out
        }
    }

    func translate(_ text: String) async -> String {
        let src = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.looksForeign(src) else { return text }
        return await translateMany([src]).first ?? src // 캐시는 translateMany 가 본다(설정이 바뀌었으면 먼저 비우고)
    }

    // 여러 문단을 한 번에. 순서를 지킨다.
    func translateMany(_ texts: [String]) async -> [String] { await translateManyReporting(texts).texts }

    // 번역과 함께 '이번 번역에 쓴 엔진'을 돌려준다(A-24: 앱 전체에 하나인 lastEngine 은 다른 번역이 동시에 돌거나
    // 캐시로 끝나면 틀리게 보였다). 새로 번역한 것이 있으면 그 엔진, 모두 캐시면 캐시에 남긴 엔진, 번역할 것이 없으면 none.
    func translateManyReporting(_ texts: [String]) async -> (texts: [String], engine: Engine) {
        await translateStreaming(texts, onChunk: nil)
    }

    // 흘려 주기(케이스 5): 끝난 문단부터 onChunk 로 알린다(문단 번호 → 번역). 기기 내 번역은 chunk 문단씩 나눠 보내고
    // 구글은 묶음마다. 읽기 창이 다 끝나기를 기다리지 않고 바꿔 끼울 수 있게(ArticleService 연결은 TRANSLATE.md '인계').
    // 끝나면 전체 결과를 돌려준다(translateManyReporting 과 같음).
    typealias ChunkHandler = @Sendable ([Int: String], Engine) async -> Void
    func translateStreaming(_ texts: [String], chunk: Int = 4, onChunk: ChunkHandler?) async -> (texts: [String], engine: Engine) {
        let mode = await currentMode()
        guard mode != .off else { return (texts, .none) }
        let cachedEngines = texts.compactMap { cache[$0] != nil ? cacheEngine[$0] : nil }
        // 흘려 받는 쪽이 없으면 예전처럼 기기 내 번역도 한 번에(세션을 여러 번 만들지 않게)
        let out = await translateManyRaw(texts, mode: mode, chunk: onChunk == nil ? Int.max : max(chunk, 1), onChunk: onChunk)
        if let fresh = out.engine { return (out.texts, fresh) }
        return (out.texts, cachedEngines.contains(.google) ? .google : cachedEngines.first ?? .none)
    }

    private func translateManyRaw(_ texts: [String], mode: Mode, chunk: Int, onChunk: ChunkHandler?) async -> (texts: [String], engine: Engine?) {
        var result = texts
        let todo = texts.indices.filter { Self.looksForeign(texts[$0]) && cache[texts[$0]] == nil }
        var fromCache: [Int: String] = [:]
        for i in texts.indices where cache[texts[i]] != nil { result[i] = cache[texts[i]]!; fromCache[i] = result[i] }
        if !fromCache.isEmpty, let onChunk { await onChunk(fromCache, cachedEngine(fromCache.keys.map { texts[$0] })) }
        guard !todo.isEmpty else { return (result, nil) }

        if mode == .auto || mode == .apple {
            let sample = todo.prefix(5).map { texts[$0] }.joined(separator: " ")
            var done = 0
            for start in stride(from: 0, to: todo.count, by: min(chunk, todo.count)) {
                let part = Array(todo[start..<min(start + min(chunk, todo.count), todo.count)])
                guard let apple = await appleCall(part.map { texts[$0] }, sample), apple.count == part.count else { break }
                var got: [Int: String] = [:]
                for (k, i) in part.enumerated() {
                    let t = Self.polish(source: texts[i], translated: apple[k])
                    result[i] = t; got[i] = t; remember(texts[i], t, engine: .apple)
                }
                done += part.count
                if let onChunk { await onChunk(got, .apple) }
            }
            if done == todo.count { lastEngine = .apple; return (result, .apple) }
            // 기기 내 번역을 아예 못 쓰면(자료 없음 등) 자동은 구글로, 기기 내만은 원문 그대로. 중간에 끊겼으면 남은 문단만 이어서
            if mode == .apple { return (result, done > 0 ? .apple : nil) }
            let rest = Array(todo.dropFirst(done))
            let g = await googleMany(texts, rest, into: &result, onChunk: onChunk)
            lastEngine = done > 0 ? .apple : .google
            return (result, done > 0 ? .apple : (g ? .google : nil))
        }
        let g = await googleMany(texts, todo, into: &result, onChunk: onChunk)
        lastEngine = .google
        return (result, g ? .google : nil)
    }

    private func cachedEngine(_ sources: [String]) -> Engine {
        let e = sources.compactMap { cacheEngine[$0] }
        return e.contains(.google) ? .google : e.first ?? .none
    }

    // 구글: 문단 여러 개를 빈 줄로 이어 한 번에 보내고(요청 수를 줄여 빠르게), 묶음들은 동시에 보낸다.
    // 돌아온 문단 수가 안 맞거나, 수는 맞아도 앞뒤 문단과 엇갈려 보이면(케이스 10) 그 묶음만 문단별로 다시 보낸다.
    // 하나라도 번역했으면 true.
    private func googleMany(_ texts: [String], _ todo: [Int], into result: inout [String], onChunk: ChunkHandler?) async -> Bool {
        var batches: [[Int]] = [[]]
        var size = 0
        for i in todo {
            let n = texts[i].count
            if size + n > 3800, !batches[batches.count - 1].isEmpty { batches.append([]); size = 0 }
            batches[batches.count - 1].append(i); size += n + 2
        }
        let call = googleCall
        var any = false
        await withTaskGroup(of: [(Int, String)].self) { group in
            for batch in batches where !batch.isEmpty {
                group.addTask {
                    let sources = batch.map { texts[$0].replacingOccurrences(of: "\n", with: " ") }
                    if let out = await call(sources.joined(separator: "\n\n")) {
                        let parts = out.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                        if parts.count == batch.count, !Translator.looksShifted(sources, parts) { return Array(zip(batch, parts)) }
                    }
                    var one: [(Int, String)] = []
                    for i in batch { if let t = await call(texts[i]) { one.append((i, t)) } }
                    return one
                }
            }
            for await pairs in group {
                var got: [Int: String] = [:]
                for (i, raw) in pairs {
                    let t = Self.polish(source: texts[i], translated: raw)
                    result[i] = t; got[i] = t; remember(texts[i], t, engine: .google)
                }
                if !got.isEmpty { any = true; if let onChunk { await onChunk(got, .google) } }
            }
        }
        return any
    }

    // MARK: 다듬기(번역 결과 후처리)

    // 번역 결과를 다듬는다: 원문 끝에 마침표가 없으면(제목·소제목·목록) 번역 끝 마침표를 뗀다(케이스 3),
    // 원문에 영문으로 있는 이름을 엔진이 한글로 음역·직역했으면 영문으로 되돌린다(케이스 2)
    static func polish(source: String, translated: String) -> String {
        var t = translated
        let src = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = src.last, !".。!?！？…:;\"”’)".contains(last) {
            let tt = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if tt.hasSuffix("."), !tt.hasSuffix("..") { t = String(tt.dropLast()) }
        }
        return restoreNames(source: source, translated: t)
    }

    // 엔진이 잘 음역·직역하는 이름(AI 뉴스에 자주 나오는 것). 긴 꼴부터 바꾼다. 원문에 그 영문 이름이 낱말로 있을 때만.
    // personClash: 사람 이름 앞부분이 되기도 하는 이름 — 원문에서 그 이름 바로 뒤에 다른 대문자 낱말(제품 이름 아님)이 오면 건드리지 않는다
    struct NameRule { let latin: String; let variants: [String]; var personClash = false }
    static let nameRules: [NameRule] = [
        NameRule(latin: "Claude Code", variants: ["클로드 코드"]),
        NameRule(latin: "Claude Corps", variants: ["클로드 군단", "클로드 코어스", "클로드 코프스", "클로드 코퍼스"]),
        NameRule(latin: "Claude", variants: ["클로드", "클도"], personClash: true),
        NameRule(latin: "Anthropic", variants: ["앤트로픽", "앤스로픽", "안트로픽", "인류학적"]),
        NameRule(latin: "OpenAI", variants: ["오픈AI", "오픈에이아이", "오픈 AI"]),
        NameRule(latin: "ChatGPT", variants: ["챗GPT", "챗지피티"]),
        NameRule(latin: "Gemini", variants: ["제미니", "제미나이", "쌍둥이자리"]),
        NameRule(latin: "DeepMind", variants: ["딥마인드"]),
        NameRule(latin: "Hugging Face", variants: ["포옹하는 얼굴", "허깅 페이스", "허깅페이스"]),
        NameRule(latin: "Copilot", variants: ["부조종사", "코파일럿"]),
        NameRule(latin: "Perplexity", variants: ["당혹감", "퍼플렉시티"]),
    ]
    static let productWords: Set<String> = ["Code", "Corps", "Opus", "Sonnet", "Haiku", "Fable", "Mythos", "Design", "Science",
                                            "Security", "Cowork", "Enterprise", "Pro", "Max", "Team", "Ultra", "Flash", "Nano"]

    static func restoreNames(source: String, translated: String) -> String {
        var t = translated
        for r in nameRules {
            guard r.variants.contains(where: { t.contains($0) }) else { continue }
            guard let re = try? NSRegularExpression(pattern: "(?<![A-Za-z])" + NSRegularExpression.escapedPattern(for: r.latin) + "(?![A-Za-z])"),
                  re.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil else { continue }
            if r.personClash, Self.followedByOtherName(source, r.latin) { continue }
            for v in r.variants.sorted(by: { $0.count > $1.count }) { t = t.replacingOccurrences(of: v, with: r.latin) }
        }
        return t
    }

    // 원문에서 name 바로 뒤에 제품 낱말이 아닌 대문자 낱말이 오는가(예: 사람 이름 'Claude Monet')
    static func followedByOtherName(_ source: String, _ name: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: "(?<![A-Za-z])" + NSRegularExpression.escapedPattern(for: name) + #" ([A-Z][a-z]+)"#) else { return false }
        return re.matches(in: source, range: NSRange(source.startIndex..., in: source)).contains { m in
            guard let r = Range(m.range(at: 1), in: source) else { return false }
            return !productWords.contains(String(source[r]))
        }
    }

    // 묶음 대조(케이스 10): 문단 수는 맞아도 결과가 밀렸는지. 원문 문단에만 있는(앞뒤 원문에는 없는) 영문 낱말·숫자 —
    // 번역에도 그대로 남는 것 — 가 제 짝 번역보다 이웃 짝 번역에 더 많이 보이는 문단이 하나라도 있으면 밀린 것으로 본다.
    // 점검 표본의 실제 묶음 85개(문단 2개 이상)에서 오탐 1, 한 칸 밀림 84/85·가운데부터 밀림 73/83 을 잡았다(TRANSLATE.md).
    // 틀리게 의심하면 그 묶음을 문단별로 다시 받을 뿐이다.
    static func anchors(_ s: String) -> Set<String> {
        var out = Set<String>()
        guard let re = try? NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9]{2,}|\d{2,}"#) else { return out }
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            if let r = Range(m.range, in: s) { out.insert(s[r].lowercased()) }
        }
        return out
    }

    static func looksShifted(_ sources: [String], _ outputs: [String]) -> Bool {
        guard sources.count == outputs.count, sources.count > 1 else { return false }
        let src = sources.map(anchors), out = outputs.map(anchors), n = sources.count
        for k in 0..<n {
            var own = src[k]
            if k > 0 { own.subtract(src[k - 1]) }
            if k + 1 < n { own.subtract(src[k + 1]) }
            guard !own.isEmpty else { continue }
            let mine = own.intersection(out[k]).count
            let next = k + 1 < n ? own.intersection(out[k + 1]).count : 0
            let prev = k > 0 ? own.intersection(out[k - 1]).count : 0
            if max(next, prev) > mine { return true }
        }
        return false
    }

    // 오래 켜 둬도 무한히 커지지 않게 4000개를 넘으면 비운다(기사 본문 번역도 여기로 모이므로 이 한 곳에서 지킨다)
    static let cacheLimit = 4000
    var cacheCount: Int { cache.count }
    func remember(_ source: String, _ translated: String, engine: Engine = .google) {
        if cache.count >= Self.cacheLimit { cache.removeAll(keepingCapacity: true); cacheEngine.removeAll(keepingCapacity: true) }
        cache[source] = translated
        cacheEngine[source] = engine
    }

    private static func appleTranslate(_ texts: [String], sample: String) async -> [String]? {
        guard #available(macOS 26.0, *) else { return nil }
        let rec = NLLanguageRecognizer()
        rec.processString(sample)
        guard let lang = rec.dominantLanguage, lang != .korean else { return nil }
        let source = Locale.Language(identifier: lang.rawValue)
        let target = Locale.Language(identifier: "ko")
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

    // 한 번에 보낼 수 있는 길이(구글 공개 엔드포인트). 이보다 긴 문단은 문장 단위로 나눠 보내고 이어 붙인다(A-25: 예전엔 뒤가 잘렸다)
    static let requestLimit = 4500

    private static func google(_ text: String, target: String = "ko") async -> String? {
        guard text.count > requestLimit else { return await googleOnce(text, target: target) }
        var parts: [String] = []
        for chunk in sentenceChunks(text, max: requestLimit) {
            guard let t = await googleOnce(chunk, target: target) else { return nil }
            parts.append(t)
        }
        return parts.joined(separator: " ")
    }

    // 문장 경계에서 max 글자 이하로 묶는다. 한 문장이 max 보다 길면 그 문장만 max 씩 자른다. 이어 붙이면 원문 그대로
    static func sentenceChunks(_ text: String, max: Int) -> [String] {
        guard text.count > max else { return [text] }
        let tok = NLTokenizer(unit: .sentence)
        tok.string = text
        var sentences: [String] = []
        tok.enumerateTokens(in: text.startIndex..<text.endIndex) { r, _ in sentences.append(String(text[r])); return true }
        // 토크나이저가 놓친 앞뒤 공백 등은 마지막 조각에 붙여 원문 길이를 지킨다
        let covered = sentences.joined()
        if covered.count < text.count, text.hasPrefix(covered) { sentences.append(String(text.dropFirst(covered.count))) }
        var out: [String] = [], cur = ""
        for s in sentences {
            if s.count > max {
                if !cur.isEmpty { out.append(cur); cur = "" }
                var rest = Substring(s)
                while rest.count > max { out.append(String(rest.prefix(max))); rest = rest.dropFirst(max) }
                cur = String(rest)
            } else if cur.count + s.count > max {
                out.append(cur); cur = s
            } else {
                cur += s
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    private static func googleOnce(_ text: String, target: String = "ko") async -> String? {
        var c = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        c.queryItems = [.init(name: "client", value: "gtx"), .init(name: "sl", value: "auto"), .init(name: "tl", value: target),
                        .init(name: "dt", value: "t"), .init(name: "q", value: String(text.prefix(requestLimit)))]
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
