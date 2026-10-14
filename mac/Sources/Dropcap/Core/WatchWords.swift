import Foundation

// 관심 낱말 지켜보기(N-27 · D-6): 회사·인물·법안 이름을 적어 두면 그 낱말이 든 소식은 스토리마다 한 번 알리고,
// 하루 한 번(아침 브리핑 시각) "오늘 ○○ 소식 3건" 정리 물방울을 띄운다. 누르면 매거진 검색 결과.
// 영어 낱말은 낱말 경계로(Apple 이 pineapple 에 걸리지 않게), 한국어는 조사가 붙으므로 부분 일치.
enum WatchWords {
    static func normalized(_ list: [String]) -> [String] {
        var out: [String] = []
        for w in list.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !w.isEmpty && !out.contains(where: { $0.lowercased() == w.lowercased() }) {
            out.append(w)
        }
        return out
    }

    static func matches(_ word: String, in text: String) -> Bool {
        let w = word.lowercased(), t = text.lowercased()
        guard w.range(of: "[가-힣ぁ-んァ-ン一-龥]", options: .regularExpression) == nil else { return t.contains(w) }
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: w) + "(?![\\p{L}\\p{N}])"
        return t.range(of: pattern, options: .regularExpression) != nil
    }

    // 걸린 첫 낱말(적은 순서)
    static func match(_ it: NewsItem, words: [String]) -> String? {
        let text = "\(it.title) \(it.titleKo ?? "") \(it.summary)"
        return words.first { matches($0, in: text) }
    }

    // 하루 정리: 낱말마다 걸린 기사(같은 기사는 한 번, 최신 순). 걸린 것이 없는 낱말은 뺀다
    static func digest(_ items: [NewsItem], words: [String]) -> [(word: String, items: [NewsItem])] {
        let sorted = items.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        return words.compactMap { w in
            var seen = Set<String>()
            let hit = sorted.filter { matches(w, in: "\($0.title) \($0.titleKo ?? "") \($0.summary)") && seen.insert($0.key).inserted }
            return hit.isEmpty ? nil : (w, hit)
        }
    }
}
