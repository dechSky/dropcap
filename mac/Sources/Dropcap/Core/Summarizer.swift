import Foundation
import FoundationModels

// 기사 3줄 요약. macOS 26 이상에서 Apple Intelligence 가 켜져 있으면 이 Mac 안에서(무료·비공개) 만든다.
// 쓸 수 없으면 nil 을 돌려주고, 읽기 창은 요약 칸을 숨긴다.
enum Summarizer {
    nonisolated(unsafe) private static var loggedUnavailable = false
    static var available: Bool {
        guard #available(macOS 26.0, *) else { return false }
        switch SystemLanguageModel.default.availability {
        case .available: return true
        case .unavailable(let why):
            if !loggedUnavailable { // 기사마다·화면을 그릴 때마다 같은 로그가 쌓이지 않게 한 번만(A-34)
                loggedUnavailable = true
                NSLog("[요약] Apple Intelligence 를 쓸 수 없음: %@", String(describing: why))
            }
            return false
        }
    }

    // 분야별 저녁 정리(N-26 · D-13): 묶음으로 모인 기사들로 "오늘 이 분야에서 무슨 일이 · 왜" 세 줄. 줄마다 근거 기사 번호를 단다.
    static func briefing(section: String, items: [NewsItem]) async -> [SectionBrief.Line]? {
        guard #available(macOS 26.0, *), available, items.count >= 2 else { return nil }
        let session = LanguageModelSession(instructions: """
        당신은 뉴스 편집자입니다. 번호가 붙은 기사 제목과 요약만 읽고, 오늘 이 분야에서 무슨 일이 있었고 왜 중요한지 한국어 세 줄로 정리합니다.
        각 줄은 "- " 로 시작하는 60자 안팎의 한 문장이고, 줄 끝에 근거가 된 기사 번호를 [1] 이나 [1][3] 처럼 붙입니다.
        기사에 없는 내용·추측·평가는 쓰지 않습니다.
        """)
        do {
            let r = try await session.respond(to: briefingPrompt(section: section, items: items))
            return parseBriefing(r.content, count: items.count)
        } catch {
            return nil
        }
    }

    static func briefingPrompt(section: String, items: [NewsItem]) -> String {
        var out = "분야: \(section)\n"
        for (i, it) in items.enumerated() {
            out += "\n[\(i + 1)] \(it.title)" + (it.titleKo.map { $0 != it.title ? " (\($0))" : "" } ?? "") + " — \(it.sourceName)\n"
            let s = it.summary.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).prefix(300)
            if !s.isEmpty { out += s + "\n" }
        }
        return out
    }

    // 모델 답을 줄로: "- 문장 [1][3]" → (문장, [0, 2]). 근거 번호가 없거나 범위를 벗어난 줄은 버린다(근거 없는 요약은 싣지 않음)
    static func parseBriefing(_ text: String, count: Int) -> [SectionBrief.Line]? {
        let re = try! NSRegularExpression(pattern: "\\[(\\d+)\\]")
        var out: [SectionBrief.Line] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("-") || line.hasPrefix("•") else { continue }
            let body = String(line.drop(while: { $0 == "-" || $0 == "•" || $0 == " " }))
            let ns = NSRange(body.startIndex..., in: body)
            var refs: [Int] = []
            for m in re.matches(in: body, range: ns) {
                if let r = Range(m.range(at: 1), in: body), let n = Int(body[r]), (1...count).contains(n), !refs.contains(n - 1) { refs.append(n - 1) }
            }
            let clean = re.stringByReplacingMatches(in: body, range: ns, withTemplate: "").trimmingCharacters(in: .whitespaces)
            guard !refs.isEmpty, !clean.isEmpty else { continue }
            out.append(.init(text: clean, refs: refs))
        }
        return out.isEmpty ? nil : Array(out.prefix(3))
    }

    static func summarize(title: String, paragraphs: [String]) async -> [String]? {
        guard #available(macOS 26.0, *), available else { return nil }
        // 모델이 한 번에 읽을 수 있는 양에 맞춰 앞부분만
        var body = ""
        for p in paragraphs where body.count < 6000 { body += p + "\n" }
        guard body.count > 200 else { return nil }
        let session = LanguageModelSession(instructions: """
        당신은 뉴스 편집자입니다. 기사를 읽고 핵심만 한국어로 세 줄 요약합니다.
        각 줄은 "- " 로 시작하고 60자 안팎의 한 문장입니다. 기사에 없는 내용은 쓰지 않습니다.
        """)
        do {
            let r = try await session.respond(to: "제목: \(title)\n\n본문:\n\(body)")
            let lines = r.content
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("-") || $0.hasPrefix("•") }
                .map { String($0.drop(while: { $0 == "-" || $0 == "•" || $0 == " " })) }
                .filter { !$0.isEmpty }
            return lines.isEmpty ? nil : Array(lines.prefix(3))
        } catch {
            return nil
        }
    }
}

// 분야별 저녁 정리: 묶음을 보낸 때의 기사(근거)와 기기 안 요약(없을 수 있음)
struct SectionBrief: Codable, Equatable {
    struct Line: Codable, Equatable {
        var text: String
        var refs: [Int]        // items 의 번호(0부터)
    }
    var section: String
    var at: Date
    var items: [NewsItem]      // 근거 기사(원제목·링크)
    var lines: [Line]? = nil   // Apple Intelligence 가 없으면 nil — 매거진에는 싣지 않고 알림은 지금처럼 제목 2줄

    static let maxItems = 8
}
