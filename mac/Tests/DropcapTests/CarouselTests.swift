import Foundation
import Testing
@testable import Dropcap

// 캐러셀·슬라이드 속 본문 글(mac/READER-CUT.md '5단계 결과', 규칙 carousel-slides).
// 실제 꼴은 Google 블로그 큰 발표 기사(scramble_fixture.py 로 글·주소를 바꿈 — 표지 낱말만 원래 자리에), 나머지는 지어낸 HTML.
private func para(_ n: Int) -> String {
    "Paragraph \(n) explains how the harbor authority weighed the proposal, listened to residents and set out a schedule for the work."
}
private func slideText(_ n: Int) -> String {
    "Slide \(n) shows the new pier at dawn while crews lift the last steel beam into place above the water."
}
private let base = URL(string: "https://example.com/2026/10/story")!
private func fixture(_ name: String) -> String {
    let u = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/reader-cut/\(name).html")
    return (try? String(contentsOf: u, encoding: .utf8)) ?? ""
}
private func blocks(_ html: String) async -> [Block] { await ArticleExtractor().extractHTML(html, base: base)?.blocks ?? [] }
private func at(_ b: [Block], _ s: String) -> Int? { b.firstIndex { ($0.text ?? $0.src ?? "").contains(s) } }
private func count(_ b: [Block], _ s: String) -> Int { b.filter { ($0.text ?? $0.src ?? "").contains(s) }.count }
private func page(_ middle: String, after: String = "") -> String {
    """
    <html><body><main><article><h1>Harbor plan</h1>\((1...4).map { "<p>\(para($0))</p>" }.joined())
    \(middle)
    \((5...8).map { "<p>\(para($0))</p>" }.joined())</article>\(after)</main></body></html>
    """
}

@MainActor @Suite(.serialized) struct CarouselTests {
    @Test func realGoogleCards() async throws {
        // 영상 카드 설명(5칸) · 속성에만 글이 든 인용 카드(12칸) · 영상 카드(5칸)가 본문 사이에, 관련 기사 캐러셀은 본문 밖
        let b = await blocks(fixture("carousel-cards"))
        let before = try #require(at(b, "BEFORECAR")), after = try #require(at(b, "AFTERCAR"))
        let first = try #require(at(b, "CARCAPA"), "첫 캐러셀 첫 칸 설명")
        #expect(before < first && first < after, "본문 순서대로(앞 글 뒤 · 다음 소제목 앞)")
        #expect(b[first].type == .p, "사진 없는 칸 설명은 문단")
        let quote = try #require(at(b, "CARQUOTE"), "속성 quote= 의 인용")
        #expect(b[quote].type == .quote)
        #expect(b[quote + 1].text?.contains("CARWHO") == true, "인용 바로 뒤 말한 사람")
        #expect(at(b, "CARCAPZ") != nil, "마지막 캐러셀 마지막 칸")
        #expect(count(b, "CARCAPA") == 1 && count(b, "CARQUOTE") == 1)
        #expect(at(b, "RELCAR") == nil, "본문 밖 관련 기사 캐러셀")
        #expect(b.filter { $0.type == .quote }.count == 12)
    }

    @Test func swiperOffscreenClonesAndOrder() async {
        // swiper 무한 돌기: 화면 밖 칸(aria-hidden)·복제 칸(swiper-slide-duplicate)·돌려 놓은 차례(data-swiper-slide-index)
        let slide = { (i: Int, extra: String) in
            "<div class=\"swiper-slide\(extra)\" data-swiper-slide-index=\"\(i)\" aria-hidden=\"\(i == 1 ? "false" : "true")\"><img src=\"https://img.example.com/s\(i).jpg\"><div class=\"swiper-caption\"><p>\(slideText(i))</p></div></div>"
        }
        let html = page("""
        <div class="swiper gallery-swiper"><div class="swiper-wrapper">\(slide(2, " swiper-slide-duplicate"))\(slide(1, ""))\(slide(2, ""))\(slide(0, ""))\(slide(1, " swiper-slide-duplicate"))</div>
        <div class="swiper-pagination"><span>1</span><span>2</span><span>3</span></div><button class="swiper-button-next">Next</button></div>
        """)
        let b = await blocks(html)
        let idx = (0...2).map { at(b, slideText($0)) }
        #expect(idx.allSatisfy { $0 != nil }, "화면 밖 칸도")
        if let i0 = idx[0], let i1 = idx[1], let i2 = idx[2] { #expect(i0 < i1 && i1 < i2, "칸 차례") }
        #expect((0...2).allSatisfy { count(b, slideText($0)) == 1 }, "복제 칸 빼기")
        #expect((0...2).allSatisfy { i in b.filter { $0.type == .img && $0.src?.hasSuffix("s\(i).jpg") == true }.count == 1 }, "칸 사진 한 번씩")
        if let i0 = idx[0], let p4 = at(b, para(4)), let p5 = at(b, para(5)) { #expect(p4 < i0 && i0 < p5, "본문 순서") }
        if let img0 = b.firstIndex(where: { $0.src?.hasSuffix("s0.jpg") == true }), let i0 = idx[0] { #expect(img0 < i0, "사진 뒤 설명") }
        #expect(!b.contains { $0.text == "Next" || $0.text == "1 2 3" })
    }

    @Test func slickClonesAndAriaSlides() async {
        // slick(복제 slick-cloned) · aria-roledescription 캐러셀의 li 칸
        let html = page("""
        <div class="slick-slider"><div class="slick-track">
        <div class="slick-slide slick-cloned"><p>\(slideText(4))</p></div>
        <div class="slick-slide"><p>\(slideText(3))</p></div><div class="slick-slide"><p>\(slideText(4))</p></div></div></div>
        <p>\(para(41))</p>
        <section aria-roledescription="carousel"><ul>
        <li aria-roledescription="slide"><figure><img src="https://img.example.com/a1.jpg"></figure><p>\(slideText(5))</p></li>
        <li aria-roledescription="slide" aria-hidden="true"><figure><img src="https://img.example.com/a2.jpg"></figure><p>\(slideText(6))</p></li></ul></section>
        """)
        let b = await blocks(html)
        #expect(count(b, slideText(4)) == 1, "slick 복제 칸")
        #expect(at(b, slideText(3)) != nil)
        if let s3 = at(b, slideText(3)), let s4 = at(b, slideText(4)) { #expect(s3 < s4, "복제 칸이 앞에 와도 차례대로") }
        let s5 = at(b, slideText(5)), s6 = at(b, slideText(6))
        #expect(s5 != nil && s6 != nil, "li 칸이 한 줄로 뭉치지 않고 글로")
        #expect(b.contains { $0.type == .img && $0.src?.hasSuffix("a2.jpg") == true }, "화면 밖 칸 사진")
        if let s5, let s6, let p41 = at(b, para(41)), let p5 = at(b, para(5)) { #expect(p41 < s5 && s5 < s6 && s6 < p5) }
    }

    @Test func recommendCarouselsStayOut() async {
        // 본문 사이에 있어도 칸 글이 거의 링크인 추천 줄 · 본문 뒤(앞뒤 글이 본문에 없음) 캐러셀 · aside 안 캐러셀은 넣지 않는다
        let card = { (i: Int) in "<div class=\"swiper-slide\"><a href=\"/s\(i)\"><img src=\"https://img.example.com/r\(i).jpg\"><span>Recommended headline number \(i) about the city budget</span></a></div>" }
        let html = page(
            "<div class=\"swiper\"><div class=\"swiper-wrapper\">\((1...4).map(card).joined())</div></div>",
            after: """
            <div class="owl-carousel"><div class="owl-item"><p>Gallery card seven</p></div><div class="owl-item"><p>Gallery card eight</p></div></div>
            <aside><div aria-roledescription="carousel"><div aria-roledescription="slide"><p>Sidebar card ten</p></div></div></aside>
            """)
        let b = await blocks(html)
        #expect(!b.contains { $0.text?.contains("Recommended headline") == true })
        #expect(at(b, "Gallery card") == nil, "본문 뒤 캐러셀")
        #expect(at(b, "Sidebar card") == nil, "aside 안 캐러셀")
        #expect(at(b, para(8)) != nil)
    }

    @Test func sameBlockInAllThreeScripts() throws {
        // 윈도우 extract.js · 리눅스 SCRIPT(WebKitGTK 느린 길)의 캐러셀 칸도 맥과 글자째 같다(들여쓰기만 다름)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func block(_ s: String) throws -> [String] {
            let a = try #require(s.range(of: "// 캐러셀·슬라이드")), z = try #require(s[a.lowerBound...].range(of: "const box = prune(parse(content));"))
            return s[a.lowerBound..<z.lowerBound].split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let mac = try block(ArticleExtractor.script)
        let win = try block(String(contentsOf: root.appendingPathComponent("windows/Dropcap.Ui/web/extract.js"), encoding: .utf8))
        let rs = try block(String(contentsOf: root.appendingPathComponent("linux/dropcap-gtk/src/reader_webkit.rs"), encoding: .utf8))
        #expect(mac.count > 40)
        #expect(win == mac, "windows")
        #expect(rs == mac, "linux")
    }

    @Test func noCarouselUnchanged() async {
        // 캐러셀이 없거나 칸이 없는 'carousel' 상자는 그대로
        let html = page("<div class=\"carousel-note\"><p>\(para(40))</p></div>")
        let b = await blocks(html)
        #expect(count(b, para(40)) == 1)
        #expect(b.filter { $0.type == .p }.count == 9)
    }
}
