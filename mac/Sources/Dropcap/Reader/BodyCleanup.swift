import Foundation

// 본문 다듬기: 기자 이름·이메일 줄은 본문에서 빼서 제목 아래 '바이라인'으로, 사진·영상 없이 남은 짧은 설명 문구는 뺀다.
enum BodyCleanup {
    // "김가람 기자 reporter@example.com", "이나래 기자 desk@example.com Powered by AI", "홍길동 특파원", "By Jane Doe"
    private static let bylineRe = try! NSRegularExpression(pattern:
        #"^\s*(?:\[[^\]]{1,20}\]\s*)?([가-힣]{2,4})\s?(기자|특파원|에디터|선임기자|객원기자|논설위원)(?:\s*[=·,]?\s*[\w.+-]+@[\w-]+(?:\.[\w-]+)+)?(?:\s*Powered by [\w .]{1,40})?\s*$"#)
    private static let englishByline = try! NSRegularExpression(pattern: #"^\s*By\s+[A-Z][a-z]+(?:\s+[A-Z][a-z.]+){0,3}\s*$"#)
    // 사진·영상 설명만 남은 줄: "AI 생성 영상", "사진=연합뉴스", "(사진 제공: ○○)", "그래픽=○○"
    private static let orphanCaptionRe = try! NSRegularExpression(pattern:
        #"^\s*[\(\[]?\s*(?:AI\s?생성\s?(?:영상|이미지|사진)|(?:사진|영상|이미지|그래픽|자료)\s?(?:=|제공|출처|:)[^.。]{0,30})\s*[\)\]]?\s*$"#)

    static func byline(_ text: String) -> String? {
        let r = NSRange(text.startIndex..., in: text)
        if let m = bylineRe.firstMatch(in: text, range: r), let n = Range(m.range(at: 1), in: text), let k = Range(m.range(at: 2), in: text) {
            return "\(text[n]) \(text[k])"
        }
        if englishByline.firstMatch(in: text, range: r) != nil { return text.trimmingCharacters(in: .whitespaces) }
        return nil
    }

    static func isOrphanCaption(_ text: String, nextIsImage: Bool) -> Bool {
        guard !nextIsImage, text.count <= 40 else { return false }
        return orphanCaptionRe.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // 본문에서 뺄 문단 번호와 바이라인(여러 명이면 이어 붙임)
    static func analyze(_ blocks: [Block]) -> (skip: Set<Int>, byline: String?) {
        var skip = Set<Int>(), names: [String] = []
        for (i, b) in blocks.enumerated() where b.type == .p {
            let t = b.original ?? b.text ?? ""
            if let n = byline(t) { skip.insert(i); if !names.contains(n) { names.append(n) }; continue }
            let next = i + 1 < blocks.count && blocks[i + 1].type == .img
            if isOrphanCaption(t, nextIsImage: next) { skip.insert(i) }
        }
        return (skip, names.isEmpty ? nil : names.joined(separator: " · "))
    }
}
