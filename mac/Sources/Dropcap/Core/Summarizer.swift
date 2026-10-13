import Foundation
import FoundationModels

// 기사 3줄 요약. macOS 26 이상에서 Apple Intelligence 가 켜져 있으면 이 Mac 안에서(무료·비공개) 만든다.
// 쓸 수 없으면 nil 을 돌려주고, 읽기 창은 요약 칸을 숨긴다.
enum Summarizer {
    static var available: Bool {
        guard #available(macOS 26.0, *) else { return false }
        switch SystemLanguageModel.default.availability {
        case .available: return true
        case .unavailable(let why):
            NSLog("[요약] Apple Intelligence 를 쓸 수 없음: %@", String(describing: why))
            return false
        }
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
