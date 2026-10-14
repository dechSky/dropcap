import Foundation

// 바깥 HTML(피드 본문·기사 머리)에서 꼬리표 찾기. '<meta[^>]+…[^>]+content=' 같은 정규식은 닫히지 않은 꼬리표가 많은 글에서
// 시작 자리마다 끝까지 되풀이해 훑어 시간이 크기의 제곱으로 는다(보안 점검: 피드 하나·페이지 하나로 받기 전체가 멈춤).
// 그래서 "<이름" 을 한 번 훑어 꼬리표를 하나씩(길어야 2000자) 떼어 보고, 속성은 그 조각 안에서만 읽는다.
enum HTMLScan {
    static let maxTag = 2000
    static let maxTags = 2000

    // "<name" 으로 시작하는 꼬리표들의 속성 부분(이름 뒤 ~ '>' 앞). 이름이 더 긴 꼬리표(<metadata · <linkx)는 건너뛴다
    static func tags(_ name: String, in html: String) -> [String] {
        var out: [String] = []
        var rest = html[...]
        let open = "<" + name
        while out.count < maxTags, let r = rest.range(of: open, options: .caseInsensitive) {
            let after = rest[r.upperBound...]
            rest = after
            if let c = after.first, c.isLetter || c.isNumber || c == "-" || c == "_" || c == ":" { continue }
            let window = after.prefix(maxTag)
            // '>' 까지. 그 전에 '<' 가 나오면 닫히지 않은 꼬리표라 거기서 끊는다(조각이 겹쳐 같은 글을 되풀이해 읽지 않게)
            out.append(String(window[..<(window.firstIndex { $0 == ">" || $0 == "<" } ?? window.endIndex)]))
        }
        return out
    }

    // 꼬리표 안 속성 값(따옴표 " ' 또는 없음). data-src 같은 긴 이름은 src 로 보지 않는다. 한 번 훑는다(닫히지 않은 따옴표면 거기서 끝)
    static func attr(_ tag: String, _ name: String) -> String? {
        let s = Array(tag.unicodeScalars), n = Array(name.lowercased().unicodeScalars)
        guard !n.isEmpty else { return nil }
        func lower(_ c: Unicode.Scalar) -> Unicode.Scalar { (65...90).contains(c.value) ? Unicode.Scalar(c.value + 32)! : c }
        func space(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{0C}" }
        func text(_ a: Int, _ b: Int) -> String { var v = String.UnicodeScalarView(); v.append(contentsOf: s[a..<b]); return String(v) }
        var i = 0
        while i + n.count <= s.count {
            defer { i += 1 }
            guard i == 0 || space(s[i - 1]), (0..<n.count).allSatisfy({ lower(s[i + $0]) == n[$0] }) else { continue }
            var j = i + n.count
            while j < s.count, space(s[j]) { j += 1 }
            guard j < s.count, s[j] == "=" else { continue }
            j += 1
            while j < s.count, space(s[j]) { j += 1 }
            guard j < s.count else { return nil }
            if s[j] == "\"" || s[j] == "'" {
                let q = s[j]
                var k = j + 1
                while k < s.count, s[k] != q { k += 1 }
                return k < s.count ? text(j + 1, k) : nil
            }
            var k = j
            while k < s.count, !space(s[k]), s[k] != "\"", s[k] != "'", s[k] != ">" { k += 1 }
            if k > j { return text(j, k) }
        }
        return nil
    }

    // <meta property|name="키" content="…"> 의 값(속성 순서는 어느 쪽이든). 키마다 처음 나온 것, 키 목록 순서대로 값이 있는 첫 것
    static func meta(_ html: String, _ keys: [String], accept: (String) -> String? = { $0.isEmpty ? nil : $0 }) -> String? {
        var found: [String: [String]] = [:]
        for tag in tags("meta", in: html) {
            guard let key = attr(tag, "property") ?? attr(tag, "name"), let content = attr(tag, "content") else { continue }
            found[key.lowercased(), default: []].append(content)
        }
        for k in keys { for v in found[k.lowercased()] ?? [] { if let a = accept(v) { return a } } }
        return nil
    }

    // <title>…</title> 안 글(길어야 2000자)
    static func title(_ html: String) -> String? {
        var rest = html[...]
        while let r = rest.range(of: "<title", options: .caseInsensitive) {
            rest = rest[r.upperBound...]
            guard let c = rest.first, c == ">" || c.isWhitespace else { continue }
            guard let gt = rest.prefix(maxTag).firstIndex(of: ">") else { return nil }
            let body = rest[rest.index(after: gt)...].prefix(maxTag)
            guard let end = body.range(of: "</title", options: .caseInsensitive) else { return nil }
            let t = String(body[..<end.lowerBound])
            return t.contains("<") ? nil : t
        }
        return nil
    }
}
