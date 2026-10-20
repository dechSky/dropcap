import SwiftUI

// 소식의 분야. 제목·요약의 낱말로 고른다(가볍고 즉시, 기기 밖으로 나가는 것 없음).
enum NewsCategory: String, Codable, CaseIterable, Identifiable {
    case model, research, policy, business, security, other
    var id: String { rawValue }

    var label: String {
        switch self {
        case .model: return "모델·제품"
        case .research: return "연구"
        case .policy: return "정책·규제"
        case .business: return "투자·기업"
        case .security: return "보안"
        case .other: return "기타"
        }
    }

    var symbol: String {
        switch self {
        case .model: return "cube.transparent"
        case .research: return "flask"
        case .policy: return "building.columns"
        case .business: return "chart.line.uptrend.xyaxis"
        case .security: return "lock.shield"
        case .other: return "circle.grid.2x2"
        }
    }

    var color: Color {
        switch self {
        case .model: return .blue
        case .research: return .purple
        case .policy: return .indigo
        case .business: return .green
        case .security: return .red
        case .other: return .gray
        }
    }

    // 먼저 걸리는 분야로 정한다(보안·정책처럼 성격이 뚜렷한 것부터)
    private static let rules: [(NewsCategory, [String])] = [
        (.security, ["security", "vulnerab", "exploit", "jailbreak", "malware", "phishing", "breach", "cyber", "보안", "해킹", "취약점", "유출", "사이버"]),
        (.policy, ["regulat", "policy", "law", "act ", "congress", "senate", "eu ", "government", "lawsuit", "court", "copyright", "ban ", "규제", "정책", "법안", "정부", "소송", "저작권", "국회", "가이드라인"]),
        (.business, ["funding", "raises", "valuation", "acquire", "acquisition", "ipo", "invest", "revenue", "partnership", "deal", "layoff", "hires", "투자", "인수", "상장", "매출", "협력", "제휴", "유치", "기업가치", "파트너십"]),
        (.research, ["research", "paper", "study", "benchmark", "dataset", "arxiv", "scientists", "researchers", "논문", "연구", "벤치마크", "데이터셋", "학회"]),
        (.model, ["model", "gpt", "claude", "gemini", "llama", "release", "launch", "introducing", "announc", "api", "agent", "app", "feature", "update", "open-source", "open source", "weights", "모델", "출시", "공개", "발표", "업데이트", "에이전트", "오픈소스", "기능"]),
    ]

    // 영어는 낱말 경계로(짧은 말은 온전한 낱말만, 긴 어간은 낱말 앞부분) — 'impact'의 act, 'capital'의 api 에 걸리지 않게.
    // 한국어는 조사가 붙으므로 부분 일치
    private static let compiled: [(NewsCategory, NSRegularExpression?, [String])] = rules.map { cat, words in
        let english = words.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.unicodeScalars.allSatisfy { $0.isASCII } }
        let korean = words.filter { !$0.unicodeScalars.allSatisfy { $0.isASCII } }
        let parts = english.map { w -> String in
            let e = NSRegularExpression.escapedPattern(for: w)
            return w.count <= 4 ? "\\b\(e)\\b" : "\\b\(e)"
        }
        return (cat, try? NSRegularExpression(pattern: parts.joined(separator: "|")), korean)
    }

    static func classify(_ text: String) -> NewsCategory {
        let t = Sections.normalized(text) // 한국어 낱말은 글자 그대로 찾기(.literal — Sections.hits 와 같은 까닭)
        let range = NSRange(t.startIndex..., in: t)
        for (cat, re, korean) in compiled {
            if re?.firstMatch(in: t, range: range) != nil || korean.contains(where: { t.range(of: $0, options: .literal) != nil }) { return cat }
        }
        return .other
    }
}

extension NewsItem {
    var category: NewsCategory {
        switch itemKind {
        case .paper: return .research
        case .release: return .model
        default: return NewsCategory.classify("\(title) \(titleKo ?? "") \(summary)")
        }
    }
}
