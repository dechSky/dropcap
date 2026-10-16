import Foundation

// 피드 전문 우선(READER-CUT.md 'feed-full-body' — 윈도우·리눅스도 같은 이름·같은 기준):
// 사이트 HTML 은 앞부분만 주는데 피드 content:encoded 에는 전문이 있는 출처(Politico 일반 기사 — 사이트 4문단, 피드 4,000자 넘음).
// 추린 본문보다 피드 본문이 확실히 길고(1.3배 이상) 같은 기사일 때(추린 본문의 긴 문단 앞머리가 피드 글에 들어 있음) 피드 본문을 쓴다.
// 사이트에서 아예 못 추렸으면(막힘·실패) 피드 본문이 있으면 그것을 쓴다.
enum FeedFullBody {
    static let longer = 1.3
    static let overlap = 0.6

    private static func squash(_ s: String) -> String { s.filter { !$0.isWhitespace } }
    static func textLength(_ blocks: [Block]) -> Int { blocks.compactMap(\.text).reduce(0) { $0 + $1.count } }

    // 피드 본문을 블록으로 추리기 전에 대 보기(웹 보기를 한 번 더 띄울지): 피드 글이 추린 글보다 확실히 길 때만
    static func worthTrying(feedHTML: String?, extracted: [Block]?) -> Bool {
        guard let feedHTML, !feedHTML.isEmpty else { return false }
        guard let extracted, !extracted.isEmpty else { return true }
        return Double(Plain.clean(feedHTML).count) >= Double(textLength(extracted)) * longer
    }

    static func prefer(feed: [Block], over extracted: [Block]) -> Bool {
        let feedLen = textLength(feed)
        guard feedLen > 0 else { return false }
        let ours = textLength(extracted)
        if ours == 0 { return feedLen >= 300 }
        guard Double(feedLen) >= Double(ours) * longer else { return false }
        let feedText = squash(feed.compactMap(\.text).joined())
        let anchors = extracted.filter { $0.type == .p }.compactMap(\.text).map(squash).filter { $0.count >= 40 }.prefix(6).map { String($0.prefix(30)) }
        guard !anchors.isEmpty else { return ours < 400 } // 견줄 문단이 없으면 아주 짧은 본문일 때만
        let hits = anchors.filter { feedText.contains($0) }.count
        return Double(hits) >= Double(anchors.count) * overlap
    }

    // 피드 본문 HTML 을 추출기가 읽는 한 장짜리 문서로
    static func page(_ body: String, title: String) -> String {
        let t = title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        return "<html><head><meta charset=\"utf-8\"><title>\(t)</title></head><body><article>\(body)</article></body></html>"
    }
}
