import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Dropcap

// 읽기 창 본문 잘림·군더더기(mac/READER-CUT.md). 고정 HTML 은 실제 사이트의 꼴만 본뜬 것이고 글은 지어낸 것.
private func para(_ n: Int, _ topic: String = "city budget") -> String {
    "Paragraph \(n) explains how the \(topic) committee reviewed the plan, heard from residents and agreed to publish a timeline."
}
private func kpara(_ n: Int) -> String {
    "\(n)번째 문단에서는 시 예산 위원회가 계획을 검토하고 주민 의견을 들은 뒤 일정표를 공개하기로 한 과정을 설명한다."
}
private let base = URL(string: "https://example.com/2026/10/story")!
private func texts(_ a: Article?) -> [String] { a?.blocks.compactMap(\.text) ?? [] }
// 실제 페이지의 꼴만 남기고 글·주소를 바꾼 것(mac/scripts/scramble_fixture.py). 리드·끝 문단 앞에 LEDESTART·BODYEND 표지
private func fixture(_ name: String) -> String {
    let u = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/reader-cut/\(name).html")
    return (try? String(contentsOf: u, encoding: .utf8)) ?? ""
}

@MainActor @Suite(.serialized) struct ReaderCutExtractTests {
    // 보안 점검 2 X1: 형제 상자 안에 본문 상자와 같은 class 가 N겹 — 겹마다 하위 전체를 복사해 N²(Chromium 800겹 80초) → 바깥 상자만
    @Test func nestedCoreClassGatheredOnce() async {
        let body = (1...6).map { "<p>\(para($0))</p>" }.joined()
        let html = "<html><head><title>t</title></head><body><article><div class=\"x\">\(body)</div><section class=\"y\">"
            + (0..<800).map { "<div class=\"x\"><span>w\($0) word word word</span>" }.joined()
            + "<p>\(para(7))</p>" + String(repeating: "</div>", count: 800) + "</section></article></body></html>"
        let t0 = Date()
        let t = texts(await ArticleExtractor().extractHTML(html, base: base))
        #expect(Date().timeIntervalSince(t0) < 6)
        #expect(t.contains(para(1)))
        #expect(t.filter { $0.contains(para(7)) }.count == 1)
    }

    // A: 광고 칸을 사이에 둔 본문 덩어리 두 개(Ars .post-content 꼴) — 둘 다 와야 하고, 기자 소개 상자·댓글 수는 빠져야
    @Test func splitBodyMerged() async {
        let first = (1...3).map { "<p>\(para($0))</p>" }.joined()
        let second = (4...9).map { "<p>\(para($0))</p>" }.joined()
        let html = """
        <html><head><title>Story</title></head><body><header><nav><a href="/">Home</a> <a href="/science">Science</a></nav></header>
        <main><article><h1>Story</h1><div class="grid"><div class="col">
        <div class="post-content post-content-double">\(first)</div>
        <div class="ad-wrapper"><div class="ad ad--mid">Advertisement</div></div>
        <div class="post-content post-content-double">\(second)</div>
        <div class="author-mini-bio"><a href="https://news.example.com/author/pat/"><img src="https://cdn.example.com/uploads/2018/08/pic300.jpg"></a>
        <div>Pat Example <span>Senior Writer</span></div><div itemprop="description">Pat is a senior writer at Example News with a particular focus on science and culture.</div></div>
        <div class="story-tools"><a class="view-comments" href="#comments">42 Comments</a></div>
        </div><div class="rail"><div class="ad-wrapper is-rail"></div></div></div></article></main>
        <footer><p>Example News is part of a media group. All rights reserved worldwide since forever and ever.</p></footer></body></html>
        """
        let t = texts(await ArticleExtractor().extractHTML(html, base: base))
        #expect(t.contains(para(1)))
        #expect(t.contains(para(9)))
        #expect(!t.contains { $0.contains("senior writer at Example") })
        #expect(!t.contains { $0.contains("Comments") })
    }

    // A: data-component 블록이 줄지어 선 꼴(BBC) — 앞 덩어리(리드)와 사진 뒤 덩어리 모두, 관련 링크 블록은 빼고
    @Test func componentBlocksMerged() async {
        func text(_ r: ClosedRange<Int>) -> String { r.map { "<div data-component=\"text-block\" class=\"ssr-tb\"><p class=\"ssr-p\">\(para($0, "river"))</p></div>" }.joined() }
        let html = """
        <html><head><title>River</title></head><body><div id="main-wrapper"><main><article>
        <div data-component="headline-block" class="ssr-h"><h1>River</h1></div>
        <div data-component="byline-block" class="ssr-b"><span>By Sam Example</span></div>
        \(text(1...2))
        <div data-component="image-block" class="ssr-ib"><figure><img src="https://ichef.example.com/news/976/photo-a.jpg"><figcaption>A river at dawn</figcaption></figure></div>
        \(text(3...4))
        <div data-component="image-block" class="ssr-ib"><figure><img src="https://ichef.example.com/news/976/photo-b.jpg"><figcaption>A boat</figcaption></figure></div>
        \(text(5...9))
        <div data-component="links-block" class="ssr-l"><h2>More on this story</h2><ul><li><a href="/a">Another story about something else entirely</a></li></ul></div>
        </article></main></div></body></html>
        """
        let a = await ArticleExtractor().extractHTML(html, base: base)
        let t = texts(a)
        #expect(t.contains(para(1, "river")))
        #expect(t.contains(para(9, "river")))
        #expect(!t.contains { $0.contains("Another story") })
        #expect((a?.blocks.filter { $0.type == .img }.count ?? 0) >= 1)
    }

    // 실제 꼴(글은 바꿈): Ars 본문 두 덩어리 · BBC data-component 줄 · 매경 본문 대 AI 상자 · 동아 맨 글자+<br><br>
    @Test(arguments: [("split-post-content", "BODYEND"), ("component-blocks", "BODYEND"), ("articlebody-vs-widget", "BODYMID"), ("bare-text-br", "BODYEND")])
    func realShapes(_ name: String, _ end: String) async {
        let a = await ArticleExtractor().extractHTML(fixture(name), base: base)
        let t = texts(a)
        #expect(t.contains { $0.contains("LEDESTART") }, "\(name): 리드")
        #expect(t.contains { $0.contains(end) }, "\(name): 끝")
        #expect(!t.contains { $0.contains("LEDESTART") && $0.contains(end) }, "\(name): 한 덩어리로 붙음")
        if name == "component-blocks" { #expect((a?.blocks.filter { $0.type == .img }.count ?? 0) >= 10, "BBC 사진 블록") }
    }

    // B: 본문은 itemprop=articleBody 안 맨 글자(<br>로 나눔), 옆에는 문단이 많은 'AI 요약' 상자(매경 꼴) — 본문을 골라야
    @Test func articleBodyPreferred() async {
        let body = (1...6).map { kpara($0) }.joined(separator: "<br><br>")
        let widget = (1...5).map { "<p class=\"ai-txt\">AI 해설 \($0): 이 종목은 최근 거래량이 늘었고 외국인 매수가 이어졌으며 기관은 관망하는 흐름을 보였다는 분석이 나왔다.</p>" }.joined()
        let html = """
        <html><head><title>증시</title></head><body><div class="news_detail_wrap"><h2 class="news_ttl">증시</h2>
        <div class="news_cnt_detail_wrap" itemprop="articleBody">\(body)</div>
        <div class="ai_box"><h3>기사 속 종목 이야기</h3>\(widget)<p>주의사항 : 본 서비스는 AI의 구조적 한계로 인해 오류가 발생할 수 있습니다.</p></div>
        </div></body></html>
        """
        let t = texts(await ArticleExtractor().extractHTML(html, base: base))
        #expect(t.contains { $0.contains(String(kpara(1).prefix(20))) })
        #expect(t.contains { $0.contains(String(kpara(6).prefix(20))) })
        #expect(!t.contains { $0.hasPrefix("AI 해설") })
    }

    // 동아 꼴: 맨 글자 문단이 <br><br> 와 광고 div 사이에 — 리드를 버리지 않아야
    @Test func bareTextParagraphs() async {
        let html = """
        <html><head><title>사회</title></head><body><section class="news_view"><div class="article_txt">
        \(kpara(1))<br><br>\(kpara(2))
        <div class="adwrap"><div class="ad">광고</div></div>
        \(kpara(3))<br><br><strong>◇ 소제목</strong><br><br>\(kpara(4))<br><br>\(kpara(5))
        <figure><img src="https://image.example.com/photo.jpg"><figcaption>사진 설명</figcaption></figure>
        \(kpara(6))</div></section></body></html>
        """
        let t = texts(await ArticleExtractor().extractHTML(html, base: base))
        for n in 1...6 { #expect(t.contains { $0.contains(String(kpara(n).prefix(15))) }, "문단 \(n)") }
        #expect(!t.contains { $0.contains(kpara(1)) && $0.contains(kpara(2)) }) // 두 문단이 한 덩어리로 붙지 않게
    }

    // C: ld+json isAccessibleForFree=false 와 한경 articlePayment="Y" 를 기사에 표시
    @Test func paidFlags() async {
        let paras = (1...4).map { "<p>\(para($0))</p>" }.joined()
        let ld = """
        <html><head><title>Deal</title><script type="application/ld+json">{"@type":"NewsArticle","isAccessibleForFree":false}</script></head>
        <body><article>\(paras)<p>Subscribe</p></article></body></html>
        """
        #expect(await ArticleExtractor().extractHTML(ld, base: base)?.paid == true)
        let hk = "<html><head><title>증권</title><script>var articlePayment = \"Y\";</script></head><body><div id=\"articletxt\">\((1...4).map { "<p>\(kpara($0))</p>" }.joined())</div></body></html>"
        #expect(await ArticleExtractor().extractHTML(hk, base: base)?.paid == true)
        let free = "<html><head><title>Free</title></head><body><article>\(paras)</article></body></html>"
        #expect(await ArticleExtractor().extractHTML(free, base: base)?.paid != true)
    }

    // 연합 [속보] 꼴: 기사는 사진+설명뿐, 페이지에는 메뉴 목록 — 메뉴를 본문으로 내지 말고 실패(noText)로
    @Test func photoOnlyIsNoText() async {
        let menu = (1...40).map { "<li><a href=\"/c\($0)\">분야 메뉴 \($0)</a></li>" }.joined()
        let html = """
        <html><head><title>[속보] 제목</title></head><body><nav><ul>\(menu)</ul></nav>
        <article class="story-news"><figure><img src="https://img.example.com/flash.jpg"><figcaption>[속보] 사진 설명 한 줄</figcaption></figure></article>
        <footer><ul>\(menu)</ul></footer></body></html>
        """
        #expect(await ArticleExtractor().extractHTML(html, base: base) == nil)
    }

    // 화면 크기별로 기사를 세 벌 싣는 페이지(Politico 꼴) — 모아도 한 벌만
    @Test func layoutCopiesOnce() async {
        let story = "<div class=\"story-text\">" + (1...4).map { "<p>\(para($0, "senate"))</p>" }.joined() + "</div>"
        let html = "<html><head><title>S</title></head><body><main><div class=\"layout\"><section class=\"story-wrap desktop\">\(story)</section><section class=\"story-wrap tablet\">\(story)</section><section class=\"story-wrap mobile\">\(story)</section></div></main></body></html>"
        let t = texts(await ArticleExtractor().extractHTML(html, base: base))
        #expect(t.filter { $0 == para(1, "senate") }.count == 1)
        #expect(t.contains(para(4, "senate")))
    }

    // 번역 인계: 각주 sup 번호는 낱말에 붙지 않고, <br> 은 빈칸, 사진 단추 글은 빠짐
    @Test func footnotesBreaksButtons() async {
        let html = """
        <html><head><title>Notes</title></head><body><article>
        <p>\(para(1))<sup><a href="#fn1">1</a></sup> More text follows here after the footnote marker in this sentence.</p>
        <p>Contact office<br>Room 12<br>Main street, and more words so that this paragraph is long enough to keep.</p>
        <figure><img src="https://img.example.com/a.jpg"><figcaption>A crowd gathers <b class="hide-caption">hide caption</b></figcaption></figure>
        \((2...5).map { "<p>\(para($0))</p>" }.joined())</article></body></html>
        """
        let t = texts(await ArticleExtractor().extractHTML(html, base: base))
        #expect(t.contains { $0.hasPrefix(para(1) + " More text") })
        #expect(t.contains { $0.hasPrefix("Contact office Room 12 Main street") })
        #expect(!t.contains { $0.localizedCaseInsensitiveContains("hide caption") })
    }
}

@Suite struct ReaderCutRuleTests {
    private func p(_ s: String) -> Block { Block(type: .p, text: s) }

    // C: 맛보기 판정 — 지금(문구·1,500자)에 더해 isAccessibleForFree=false + 짧은 본문, 하드 유료 + 짧은 본문, 강한 문구는 길이와 무관
    @Test func teaser() {
        let short = (1...8).map { p(para($0)) }           // 약 1,000자
        let long = (1...30).map { p(para($0)) }           // 약 3,800자
        #expect(!Paywall.isTeaser(short, paid: nil, kind: nil))
        #expect(Paywall.isTeaser(short, paid: true, kind: nil))
        #expect(!Paywall.isTeaser(long, paid: true, kind: nil))      // 무료 건수 제한 사이트가 전문을 준 경우(Verge)
        #expect(Paywall.isTeaser(short, paid: nil, kind: .hard))
        #expect(!Paywall.isTeaser(short, paid: nil, kind: .metered))
        #expect(Paywall.isTeaser(long + [p("This article is exclusive to STAT+ subscribers. Unlock this article by subscribing.")], paid: nil, kind: nil))
        #expect(Paywall.isTeaser(short + [p("한경 프리미엄9의 모든 콘텐츠는 한국경제신문의 저작물로 저작권법의 보호를 받습니다.")], paid: nil, kind: nil))
    }

    // 군더더기: 줄 단위 규칙과 끝부분 자르기, 본문을 지우지 않는 안전장치
    @Test func junkLines() {
        let body = (1...8).map { p(para($0)) }
        let blocks = [p("Pat Example"), p("is a news writer who covers streaming, consumer tech and social media.")] + body + [
            p("reporter@example.co.kr"), p("좋아요 3 슬퍼요 0 화나요 1"), p("입력 2026.10.14 11:42 수정 2026.10.14 11:45"),
            p("Follow topics and authors from this story to see more like this in your personalized homepage feed."),
            p("Email (required)"), p("42 Comments"), p("Your browser does not support the audio element."),
            Block(type: .li, text: "Embed <iframe src=\"https://example.com/embed\" width=\"100%\"></iframe>"),
            p("Copyright © 2026 Example News. All rights reserved."),
            p("Most read: another story headline that is not part of this article"),
            Block(type: .li, text: "기사 스크랩"), Block(type: .li, text: "공유"), Block(type: .li, text: "프린트"),
        ]
        let junk = BodyCleanup.junk(blocks)
        for i in 0..<2 { #expect(junk.contains(i), "머리 기자 소개 \(i)") }
        for i in 2..<10 { #expect(!junk.contains(i), "본문 \(i)") }
        for i in 10..<blocks.count { #expect(junk.contains(i), "꼬리 \(i): \(blocks[i].text ?? "")") }
    }

    @Test func junkSafety() {
        // 저작권 줄 뒤가 본문의 절반을 넘으면(잘못 놓인 줄) 끝 자르기를 하지 않는다
        let blocks = [p(para(1)), p("ⓒ Example News"), ] + (2...10).map { p(para($0)) }
        let junk = BodyCleanup.junk(blocks)
        #expect(junk == [1])
        // 긴 문단은 줄 규칙에 걸리지 않는다
        #expect(BodyCleanup.junk([p("Copyright law " + para(1))] + (2...5).map { p(para($0)) }).isEmpty)
        // 같은 블록이 잇달아 두 번(부제·사진 설명 중복) — 뒤 것을 뺀다
        #expect(BodyCleanup.junk([p(para(1)), p(para(1)), p(para(2))]) == [1])
    }

    // 작은 그림(기자 사진 등)은 본래 크기보다 키우지 않는다
    @Test func smallImagesNotUpscaled() {
        #expect(ImageFit.maxWidth(CGSize(width: 96, height: 96)) == 96)
        #expect(ImageFit.maxWidth(CGSize(width: 300, height: 200)) == 300)
        #expect(ImageFit.maxWidth(CGSize(width: 1200, height: 800)) == nil)
    }

    // M: 맛보기·일부만 기사는 6시간 뒤 다시 받는다(그 밖은 그대로)
    @Test func shortCacheForCut() {
        var a = PreparedArticle(stage: .done, title: "t", originalTitle: "t")
        let now = Date()
        a.savedAt = now.addingTimeInterval(-7 * 3600)
        #expect(!ArticleService.isStale(a, now: now))
        a.paywalled = true
        #expect(ArticleService.isStale(a, now: now))
        a.savedAt = now.addingTimeInterval(-3600)
        #expect(!ArticleService.isStale(a, now: now))
        a.paywalled = nil; a.partial = true; a.savedAt = nil // 예전 기록(저장 시각 없음)도 다시
        #expect(ArticleService.isStale(a, now: now))
        a.savedAt = now.addingTimeInterval(30 * 86400) // 미래 시각도 다시
        #expect(ArticleService.isStale(a, now: now))
    }
}

// 화면 확인(창 없이 그림으로만 — 포커스를 뺏지 않음): READER_CUT_SHOT_DIR 가 있을 때만 PNG 를 남긴다
@MainActor @Suite struct ReaderCutShots {
    @Test func teaserScreens() throws {
        guard let dir = ProcessInfo.processInfo.environment["READER_CUT_SHOT_DIR"] else { return }
        Typography.register()
        let item = NewsItem(id: "a", title: "Deal", titleKo: nil, link: "https://example.com/a", date: Date(), summary: "", sourceId: "stat", sourceName: "STAT", tier: "press")
        let alt = NewsItem(id: "b", title: "같은 소식 다른 보도 제목", titleKo: nil, link: "https://example.com/b", date: Date(), summary: "", sourceId: "yna", sourceName: "연합뉴스", tier: "kr")
        for (name, alts) in [("teaser-no-alternatives", [NewsItem]()), ("teaser-with-alternatives", [alt])] {
            let page = VStack(alignment: .leading, spacing: 0) {
                Text("기사 제목이 여기에 옵니다").font(.app(26, .bold))
                TeaserBanner(link: item.link).padding(.top, 18)
                if !alts.isEmpty { FreeAlternativesBox(item: item, alternatives: alts, reason: "다른 곳 보도로 전체를 읽을 수 있어요").padding(.top, 18) }
                ForEach(1...3, id: \.self) { n in Text("\(n)번째 문단 — 사이트가 공개한 앞부분의 글이 여기에 옵니다. 실제 기사 글은 넣지 않았습니다.").font(.app(16)).padding(.top, 16) }
                CutEndNote(teaser: true, link: item.link) {}.padding(.top, 10)
                CutEndNote(teaser: false, link: item.link) {}.padding(.top, 10)
            }
            .padding(36).frame(width: 720).background(Color.white).environment(\.colorScheme, .light)
            let r = ImageRenderer(content: page); r.scale = 2
            let img = try #require(r.nsImage)
            let rep = try #require(img.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }
}

// 머리 겹침 확인: 화면 밖 창(앞으로 꺼내지 않고 앱도 깨우지 않음)에 읽기 창 보기를 얹어 아래로 내린 뒤 그림으로 — READER_CUT_SHOT_DIR 때만
@MainActor @Suite struct ReaderHeaderShots {
    @Test func scrolledHeader() async throws {
        guard let dir = ProcessInfo.processInfo.environment["READER_CUT_SHOT_DIR"] else { return }
        Typography.register()
        let item = NewsItem(id: "h", title: "머리 겹침 확인용 기사", titleKo: nil, link: "https://example.com/", date: Date(), summary: "", sourceId: "openai", sourceName: "시험", tier: "lab")
        let model = ReaderModel(item: item)
        let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 760, height: 560), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: ReaderView(model: model))
        try? await Task.sleep(for: .seconds(4)) // 보기의 load() 가 끝나기를(실패해도 됨) 기다린 뒤 본문을 직접 채움
        model.blocks = (1...30).map { Block(type: .p, text: "\($0)번째 문단 — 머리 밑으로 들어가는 본문 글. 제목줄 단추와 겹쳐 보이면 안 됩니다. 글은 지어낸 것입니다.") }
        model.failure = nil
        model.phase = .done
        try? await Task.sleep(for: .milliseconds(600))
        func shot(_ name: String) throws {
            let v = try #require(w.contentView?.superview ?? w.contentView)
            let rep = try #require(v.bitmapImageRepForCachingDisplay(in: v.bounds))
            v.cacheDisplay(in: v.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
        try shot("header-top")
        func scrollViews(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? [] + v.subviews.flatMap(scrollViews) }
        let sv = try #require(scrollViews(w.contentView!).first)
        sv.contentView.scroll(to: NSPoint(x: 0, y: 400)); sv.reflectScrolledClipView(sv.contentView)
        try? await Task.sleep(for: .milliseconds(600))
        try shot("header-scrolled")
        w.close()
    }
}
