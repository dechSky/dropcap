import AppKit
import Foundation

// 읽기 창 표지 사진 고르기(READSWEEP 에서 찾은 것):
// - 피드 사진이 작은 미리보기(가디언 280px)거나 못 받는 사진(8MB 넘는 원본 — Politico·NPR)이면 기사 머리 대표 사진으로 바꾼다
// - 기사 머리 대표 사진을 찾을 때 og:image:type("image/jpeg")을 사진 주소로 잡던 문제를 막는다(DW)
enum CoverPick {
    static let minWidth: CGFloat = 400

    static func bigEnough(_ img: NSImage) -> Bool { img.size.width >= minWidth }

    // 페이지 머리에서 대표 사진 주소: og:image(:url) → og:image:secure_url → twitter:image, 속성 순서는 어느 쪽이든.
    // <meta …> 를 한 번 훑어 하나씩 떼어 본다(닫히지 않은 꼬리표가 많은 페이지에서 정규식이 되풀이해 훑지 않게)
    static func ogImage(html: String, base: URL?) -> String? {
        var found: [String: String] = [:]
        for tag in metaTags(String(html.prefix(200_000))) {
            guard let key = attr(tag, "property") ?? attr(tag, "name"), let content = attr(tag, "content") else { continue }
            let k = key.lowercased()
            if found[k] == nil { found[k] = content }
        }
        for k in ["og:image", "og:image:url", "og:image:secure_url", "twitter:image", "twitter:image:src"] {
            guard let raw = found[k]?.replacingOccurrences(of: "&amp;", with: "&").trimmingCharacters(in: .whitespaces),
                  let u = URL(string: raw, relativeTo: base)?.absoluteURL, u.scheme == "https" || u.scheme == "http" else { continue }
            return u.absoluteString
        }
        return nil
    }

    static func metaTags(_ head: String) -> [String] {
        var out: [String] = []
        var rest = head[...]
        while let r = rest.range(of: "<meta", options: .caseInsensitive) {
            let after = rest[r.upperBound...]
            let end = after.prefix(2000).firstIndex(of: ">") // 꼬리표 하나는 길어야 2000자
            out.append(String(after[..<(end ?? after.prefix(2000).endIndex)]))
            rest = after
        }
        return out
    }

    // 꼬리표 안 속성 값(따옴표 " ' 또는 없음)
    private static let attrRes: [String: NSRegularExpression] = Dictionary(uniqueKeysWithValues: ["property", "name", "content"].map {
        ($0, try! NSRegularExpression(pattern: #"(?:^|\s)"# + $0 + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#, options: .caseInsensitive))
    })

    static func attr(_ tag: String, _ name: String) -> String? {
        guard let re = attrRes[name],
              let m = re.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for g in 1...3 { if let r = Range(m.range(at: g), in: tag) { return String(tag[r]) } }
        return nil
    }

    static func ogImage(_ link: String) async -> String? {
        guard let data = try? await FeedService.shared.fetch(link, limit: .page) else { return nil }
        return ogImage(html: String(decoding: data.prefix(200_000), as: UTF8.self), base: URL(string: link))
    }
}
