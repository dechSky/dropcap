import Foundation

// 스크립트로 본문을 그리는 사이트도 HTML 안에 본문 자료(JSON)를 실어 보내는 경우가 많다.
// 빠른 길에서 Readability 가 못 찾으면 이것을 먼저 읽는다 — 웹 보기를 띄우지 않으므로 빠르고, 미리 받기(스크립트 없음)에서도 된다(READSWEEP).
//  1) Arc Publishing(조선일보 등): Fusion.globalContent = {content_elements: [...]}
//  2) schema.org NewsArticle 의 articleBody(ld+json)
enum EmbeddedArticle {
    static func extract(_ data: Data) -> Article? {
        let html = String(decoding: data.prefix(3_000_000), as: UTF8.self)
        return fusion(html) ?? ldJSON(html)
    }

    static func fusion(_ html: String) -> Article? {
        guard let r = html.range(of: "Fusion.globalContent="),
              let json = balancedObject(html[r.upperBound...]),
              let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let elements = obj["content_elements"] as? [[String: Any]] else { return nil }
        var blocks: [Block] = []
        for e in elements {
            switch e["type"] as? String {
            case "text":
                let raw = e["content"] as? String ?? ""
                let t = plain(raw)
                guard !t.isEmpty else { continue }
                // 굵은 글씨만으로 된 줄(◇ 소제목)은 소제목으로
                let boldOnly = raw.trimmingCharacters(in: .whitespaces).range(of: #"^<(b|strong)>[\s\S]*</(b|strong)>$"#, options: .regularExpression) != nil
                blocks.append(Block(type: boldOnly ? .h : .p, text: t))
            case "header":
                let t = plain(e["content"] as? String ?? "")
                if !t.isEmpty { blocks.append(Block(type: .h, text: t)) }
            case "quote", "blockquote":
                let inner = (e["content_elements"] as? [[String: Any]] ?? []).compactMap { $0["content"] as? String }.map(plain).joined(separator: " ")
                if !inner.isEmpty { blocks.append(Block(type: .quote, text: inner)) }
            case "list":
                for item in e["items"] as? [[String: Any]] ?? [] {
                    let t = plain(item["content"] as? String ?? "")
                    if !t.isEmpty { blocks.append(Block(type: .li, text: t)) }
                }
            case "image":
                guard let u = e["url"] as? String, u.hasPrefix("https://") || u.hasPrefix("http://") else { continue }
                blocks.append(Block(type: .img, src: u))
                let cap = plain(e["caption"] as? String ?? "")
                if !cap.isEmpty { blocks.append(Block(type: .cap, text: cap)) }
            default: continue
            }
        }
        guard textLength(blocks) >= 100 else { return nil }
        let title = (obj["headlines"] as? [String: Any])?["basic"] as? String
        let by = ((obj["credits"] as? [String: Any])?["by"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: " · ")
        return Article(title: title, byline: by.isEmpty ? nil : by, siteName: nil, blocks: blocks)
    }

    static func ldJSON(_ html: String) -> Article? {
        var rest = html[...]
        while let open = rest.range(of: "application/ld+json", options: .caseInsensitive) {
            guard let gt = rest[open.upperBound...].firstIndex(of: ">"),
                  let close = rest[gt...].range(of: "</script>", options: .caseInsensitive) else { break }
            let body = String(rest[rest.index(after: gt)..<close.lowerBound])
            rest = rest[close.upperBound...]
            guard let any = try? JSONSerialization.jsonObject(with: Data(body.utf8)) else { continue }
            for obj in flatten(any) {
                guard let text = obj["articleBody"] as? String else { continue }
                let paras = text.components(separatedBy: .newlines).map(plain).filter { !$0.isEmpty }
                let blocks = paras.map { Block(type: .p, text: $0) }
                guard textLength(blocks) >= 100 else { continue }
                let author = (obj["author"] as? [String: Any])?["name"] as? String
                    ?? (obj["author"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.joined(separator: " · ")
                return Article(title: obj["headline"] as? String, byline: author?.isEmpty == false ? author : nil, siteName: nil, blocks: blocks)
            }
        }
        return nil
    }

    // ld+json 은 객체 하나·배열·@graph 어느 꼴로도 온다
    static func flatten(_ any: Any) -> [[String: Any]] {
        if let a = any as? [Any] { return a.flatMap(flatten) }
        guard let o = any as? [String: Any] else { return [] }
        return [o] + ((o["@graph"] as? [Any]).map { $0.flatMap(flatten) } ?? [])
    }

    // 앞에서부터 { … } 하나를 떼어 낸다(문자열·이스케이프를 따라가며 한 번 훑기)
    static func balancedObject(_ s: Substring) -> String? {
        guard let start = s.firstIndex(where: { !$0.isWhitespace }), s[start] == "{" else { return nil }
        var depth = 0, inString = false, escaped = false
        var i = start
        while i < s.endIndex {
            let c = s[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" { inString = true }
            else if c == "{" { depth += 1 }
            else if c == "}" { depth -= 1; if depth == 0 { return String(s[start...i]) } }
            i = s.index(after: i)
        }
        return nil
    }

    // 꼬리표를 걷고 흔한 문자 참조를 푼다
    static func plain(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<br\\s*/?>", with: " ", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "<[^>]{0,500}>", with: "", options: .regularExpression)
        for (k, v) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&middot;", "·"), ("&amp;", "&")] { // &amp; 는 맨 끝
            t = t.replacingOccurrences(of: k, with: v)
        }
        if t.contains("&#") {
            let re = try! NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]{1,6});")
            for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)).reversed() {
                guard let whole = Range(m.range, in: t), let hexR = Range(m.range(at: 1), in: t), let numR = Range(m.range(at: 2), in: t),
                      let v = UInt32(t[numR], radix: t[hexR].isEmpty ? 10 : 16), let u = Unicode.Scalar(v) else { continue }
                t.replaceSubrange(whole, with: String(Character(u)))
            }
        }
        return t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    static func textLength(_ blocks: [Block]) -> Int { blocks.compactMap(\.text).joined().count }
}
