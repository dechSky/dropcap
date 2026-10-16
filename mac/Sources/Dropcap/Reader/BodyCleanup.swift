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

    // 군더더기 줄(sources-audit _KR1·_KR2·_INTL1·_INTL2 '섞여 들어온 것'): 짧은 줄만, 글자째 맞을 때만
    private static let junkLine = try! NSRegularExpression(pattern: #"""
    (?xi)^\s*(?:
      [\w.+-]+@[\w-]+(?:\.[\w-]+)+ | \S{1,20}\s+[\w.+-]+@[\w-]+(?:\.[\w-]+)+                # 메일만 · 매체명+메일
    | (?:좋아요|슬퍼요|화나요|추천해요|최고예요|후속\s?기사\s?원해요)\s*\d                      # 반응 단추
    | (?:입력|수정|발행일?|승인|업데이트|등록|기사\s?입력)\s*:?\s*\d{4}[.\-/]                  # 입력·수정일 줄
    | (?:Copyright\s*(?:©|\(c\)|\d{4})|ⓒ|©) | .*(?:All\ rights\ reserved|무단\s?전재|재배포\s?금지)  # 저작권 줄
    | Follow\ topics\ and\ authors | Email\ \(required\) | View\ Bio$ | Most\ read | Recommended\ Stories$
    | \d[\d,]*\s+Comments?$ | 댓글\s*\d*$ | 많이\ 본\ (?:뉴스|기사) | 에디터\ 픽
    | Listen\ to\ (?:this\ )?article | 기사\s?듣기 | Your\ browser\ does\ not\ support\ the\ (?:audio|video)
    | To\ view\ this\ video\ please\ enable\ JavaScript | Video\ Player\ is\ loading | \[\[duration\]\]
    | When\ you\ purchase\ through\ links | Sign\ up\ for\ (?:our|the) | Get\ the\ latest\ updates\ from | Already\ have\ an\ account
    | Skip\ to\ (?:main\ )?content | This\ content\ is\ generated\ by | Embed\ <iframe | .*\[email\ protected\]
    | 제보는\ 카카오톡 | URL이\ 복사되었습니다 | 공유(?:하기)?$ | 글자\s?크기 | 이\ 기사를\ 추천합니다 | 채널\s?구독
    | 기사\s?스크랩$ | 프린트$ | 인쇄(?:하기)?$ | AI\s?기사\s?요약$ | 기사\s?저장$ | 북마크$
    )
    """#)
    // 여기서부터 끝까지는 본문이 아님(관련 글·저작권)
    private static let tailMark = try! NSRegularExpression(pattern: #"(?i)^\s*(?:Related content|More on this story|Explore more on these topics|관련\s?기사|많이 본 (?:뉴스|기사)|에디터 픽|Most read|(?:Copyright\s*(?:©|\(c\)|\d{4})|ⓒ|©)|.*(?:All rights reserved|무단\s?전재|재배포\s?금지))"#)
    // 기자 소개(머리 세 블록·끝 4분의 1에서만): "… is a senior writer at …", "is a news writer who covers …", "…를 취재합니다"
    private static let bioLine = try! NSRegularExpression(pattern: #"(?i)^(?:(?:[A-Z][\w.'’-]+\s){1,4})?is an?\s(?:[\w-]+\s){0,3}(?:reporter|writer|editor|correspondent|journalist|columnist|producer|contributor)\b|^You can contact or verify outreach|(?:기자입니다|취재합니다|취재하고 있습니다)\.?\s*$"#, options: [])
    private static let nameOnly = try! NSRegularExpression(pattern: #"^\s*[A-Z][\w.'’-]+(?:\s[A-Z][\w.'’-]+){1,3}\s*$"#)

    private static func hit(_ re: NSRegularExpression, _ t: String) -> Bool { re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil }

    // 본문에서 뺄 군더더기 블록. 안전장치: 줄 규칙은 160자 이하 줄만, 끝 자르기는 지울 글이 본문의 20%(저작권 줄이면 50%) 이하일 때만,
    // 줄 규칙이 본문 한가운데서 글의 20% 넘게 지우게 되면 가운데 것은 두고 머리·꼬리 것만 뺀다
    static func junk(_ blocks: [Block]) -> Set<Int> {
        let text = blocks.map { $0.original ?? $0.text ?? "" }
        let total = max(1, text.reduce(0) { $0 + $1.count })
        let n = blocks.count
        let tailFrom = Int(Double(n) * 0.75)
        let edge: (Int) -> Bool = { $0 < 3 || $0 >= tailFrom }
        var out = Set<Int>()
        for (i, t) in text.enumerated() where blocks[i].type != .img && !t.isEmpty {
            if t.count <= 160, hit(junkLine, t) { out.insert(i); continue }
            if edge(i), t.count <= 400, hit(bioLine, t) {
                out.insert(i)
                if i > 0, text[i - 1].count <= 40, hit(nameOnly, text[i - 1]) { out.insert(i - 1) } // 바로 앞 이름 줄
                continue
            }
            if i > 0, t.count >= 20, t == text[i - 1] { out.insert(i) } // 같은 글이 잇달아 두 번(부제·사진 설명)
        }
        let middle = out.filter { !edge($0) }
        if middle.reduce(0, { $0 + text[$1].count }) > total / 5 { out.subtract(middle) }
        // 끝 자르기: 뒤쪽 절반에서 처음 나오는 표지부터
        if let m = (n / 2..<n).first(where: { text[$0].count <= 160 && hit(tailMark, text[$0]) }) {
            let cut = text[m...].reduce(0) { $0 + $1.count }
            let copyright = text[m].range(of: #"(?i)^\s*(?:Copyright|ⓒ|©)|All rights reserved|무단\s?전재|재배포\s?금지"#, options: .regularExpression) != nil
            if cut <= total / 5 || (copyright && cut <= total / 2) { out.formUnion(m..<n) }
        }
        // 이름만 있는 끝 줄(기자 이름 li)이 앞에서 뺀 이름과 같으면
        if let last = text.indices.last, text[last].count <= 40, out.contains(where: { text[$0] == text[last] && $0 != last }) { out.insert(last) }
        return out
    }

    // 번역 전에 군더더기를 아예 뺀다(번역 시간·비용, 번역문에 기사처럼 섞이는 것)
    static func dropJunk(_ blocks: [Block]) -> [Block] {
        let j = junk(blocks)
        return blocks.enumerated().filter { !j.contains($0.offset) }.map(\.element)
    }


    static func isOrphanCaption(_ text: String, nextIsImage: Bool) -> Bool {
        guard !nextIsImage, text.count <= 40 else { return false }
        return orphanCaptionRe.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // 본문에서 뺄 문단 번호와 바이라인(여러 명이면 이어 붙임)
    static func analyze(_ blocks: [Block]) -> (skip: Set<Int>, byline: String?) {
        var skip = junk(blocks), names: [String] = [] // 예전에 저장한 기사에도 군더더기 규칙
        for (i, b) in blocks.enumerated() where b.type == .p {
            let t = b.original ?? b.text ?? ""
            if let n = byline(t) { skip.insert(i); if !names.contains(n) { names.append(n) }; continue }
            let next = i + 1 < blocks.count && blocks[i + 1].type == .img
            if isOrphanCaption(t, nextIsImage: next) { skip.insert(i) }
        }
        return (skip, names.isEmpty ? nil : names.joined(separator: " · "))
    }
}
