import Foundation
import Network
import Testing
@testable import Dropcap

@Suite struct ReadSweepTests {
    @Test func reasons() {
        var t = ExtractTrace()
        t.path = "fast"
        #expect(ReadSweep.reason(ok: true, trace: t, paywalled: false) == "")
        #expect(ReadSweep.reason(ok: true, trace: t, paywalled: true) == "맛보기만(유료벽)")
        t = ExtractTrace(); t.http = 403
        #expect(ReadSweep.reason(ok: false, trace: t, paywalled: false) == "차단 403")
        t = ExtractTrace(); t.http = 404
        #expect(ReadSweep.reason(ok: false, trace: t, paywalled: false) == "HTTP 404")
        t = ExtractTrace(); t.visible = 900; t.skipped = "richPage"
        #expect(ReadSweep.reason(ok: false, trace: t, paywalled: false) == "글은 있는데 본문을 못 찾음")
        t = ExtractTrace(); t.visible = 40; t.path = "slow"
        #expect(ReadSweep.reason(ok: false, trace: t, paywalled: false) == "JS 전용·느린 길 실패")
        t = ExtractTrace(); t.visible = 300; t.shortText = 62; t.path = "slow"
        #expect(ReadSweep.reason(ok: false, trace: t, paywalled: false) == "글 짧음(62자)")
    }

    @Test func coverNotes() {
        #expect(ReadSweep.coverNote(url: "https://a.com/photo/main.jpg", width: 1200, height: 630, sameAsOther: false) == nil)
        #expect(ReadSweep.coverNote(url: "https://a.com/img/reporter/kim.jpg", width: 1200, height: 630, sameAsOther: false) != nil)
        #expect(ReadSweep.coverNote(url: "https://a.com/og.png", width: 1200, height: 630, sameAsOther: true)?.contains("공용") == true)
        #expect(ReadSweep.coverNote(url: "https://a.com/x.jpg", width: 150, height: 150, sameAsOther: false) == "너무 작음")
        #expect(ReadSweep.coverNote(url: "https://a.com/x.jpg", width: 300, height: 300, sameAsOther: false) == "작은 정사각(얼굴·아이콘)")
        #expect(ReadSweep.coverNote(url: "https://a.com/x.png", width: 1200, height: 200, sameAsOther: false) == "띠 모양(로고·배너)")
        #expect(ReadSweep.coverNote(url: "https://a.com/x.jpg", width: nil, height: nil, sameAsOther: false) == "사진을 못 받음")
    }

    @Test func summaryTable() {
        let t = ReadSweep.Target(sourceId: "a", sourceName: "가|나", region: "kr", title: "제목", link: "https://a.com/1", image: nil)
        var bad = ExtractTrace(); bad.http = 403
        let rows = [
            ReadSweep.Row(target: t, ok: true, seconds: 1.2, trace: ExtractTrace(path: "fast")),
            ReadSweep.Row(target: t, ok: false, seconds: 6.5, trace: bad, reason: "차단 403"),
        ]
        let md = ReadSweep.markdown(rows, label: "before", started: Date(timeIntervalSince1970: 0))
        #expect(md.contains("성공: 1/2 (50%) · 국내 1/2 (50%) · 해외 -"))
        #expect(md.contains("5초 넘음 1건"))
        #expect(md.contains("| 차단 403 | 1 |"))
        #expect(md.contains("| 가/나 |")) // 표를 깨는 | 는 바꾼다
    }

    @Test func sharedCoverMarked() {
        let a = ReadSweep.Target(sourceId: "s", sourceName: "S", region: "kr", title: "1", link: "https://s.com/1", image: nil)
        var b = a; b.link = "https://s.com/2"
        var rows = [ReadSweep.Row(target: a, ok: true, seconds: 1, trace: ExtractTrace(), cover: "https://s.com/og.png"),
                    ReadSweep.Row(target: b, ok: true, seconds: 1, trace: ExtractTrace(), cover: "https://s.com/og.png")]
        ReadSweep.markShared(&rows)
        #expect(rows.allSatisfy { $0.coverNote?.contains("공용") == true })
    }

    @Test func visibleTextOnePass() {
        let html = "<html><head><style>p{color:red}</style><script>var a='<p>숨김</p>'</script></head><body><p>안녕  하세요</p><SCRIPT type=x>x</SCRIPT><svg><text>s</text></svg>끝</body></html>"
        #expect(ArticleExtractor.visibleTextLength(Data(html.utf8)) == "안녕 하세요 끝 ".count) // 꼬리표 자리는 빈칸 하나
        #expect(ArticleExtractor.visibleTextLength(Data("<p>글 <scripted>남음</scripted></p>".utf8)) == "글 남음 ".count)
        // 닫히지 않은 <script 가 수만 개여도 금방 끝난다(정규식은 되풀이해 훑었다)
        let bad = String(repeating: "<script>a", count: 40_000)
        let t0 = Date()
        _ = ArticleExtractor.visibleTextLength(Data(("<p>앞</p>" + bad).utf8))
        #expect(Date().timeIntervalSince(t0) < 2)
    }

    @Test func ogImageParsing() {
        let base = URL(string: "https://www.dw.com/en/a/a-1")
        // DW: og:image:type 이 og:image 보다 앞에 있고 content 가 먼저 — 예전 정규식은 'image/jpeg' 를 주소로 잡았다
        let dw = #"<meta content="image/jpeg" property="og:image:type"><meta content="https://static.dw.com/image/1_6.jpg" property="og:image">"#
        #expect(CoverPick.ogImage(html: dw, base: base) == "https://static.dw.com/image/1_6.jpg")
        #expect(CoverPick.ogImage(html: #"<meta property="og:image" content="/img/a.jpg?x=1&amp;y=2">"#, base: base) == "https://www.dw.com/img/a.jpg?x=1&y=2")
        #expect(CoverPick.ogImage(html: #"<meta name="twitter:image" content="https://t.co/p.png">"#, base: base) == "https://t.co/p.png")
        #expect(CoverPick.ogImage(html: #"<meta property="og:image:type" content="image/png"><meta property="og:image:width" content="1200">"#, base: base) == nil)
        #expect(CoverPick.ogImage(html: #"<meta property="og:image" content="javascript:alert(1)">"#, base: base) == nil)
        #expect(CoverPick.ogImage(html: #"<META NAME='twitter:image' CONTENT=https://t.co/q.jpg>"#, base: base) == "https://t.co/q.jpg")
        #expect(CoverPick.ogImage(html: #"<meta data-content="x" property="og:image" content="https://a.com/1.jpg">"#, base: base) == "https://a.com/1.jpg")
        // 닫히지 않은 <meta 가 수만 개여도 금방 끝난다
        let t0 = Date()
        _ = CoverPick.ogImage(html: String(repeating: "<meta property=og:image content=", count: 6000), base: base)
        #expect(Date().timeIntervalSince(t0) < 2)
    }

    @Test func failureKinds() {
        var t = ExtractTrace(); t.http = 403
        #expect(t.failure == .blocked)
        t = ExtractTrace(); t.http = 404
        #expect(t.failure == .gone)
        t = ExtractTrace(); t.shortText = 68
        #expect(t.failure == .noText)
        t = ExtractTrace(); t.fetchError = "시간 초과"; t.offline = true
        #expect(t.failure == .network && t.failure.retryable)
        t = ExtractTrace(); t.skipped = "blockedHost"
        #expect(t.failure == .blocked && !t.failure.retryable)
        #expect(ExtractTrace().failure == .unknown)
    }
}

@Suite struct EmbeddedArticleTests {
    static let para = String(repeating: "반도체 업계가 새 메모리를 준비한다. ", count: 6)

    @Test func fusion() {
        let html = """
        <html><script>Fusion.globalContent={"headlines":{"basic":"제목 {괄호}"},"credits":{"by":[{"name":"최 기자"}]},
        "content_elements":[{"type":"text","content":"\(Self.para)&amp;끝"},{"type":"text","content":"<b>◇ 소제목 \\"인용\\"</b>"},
        {"type":"image","url":"https://img.example.com/a.jpg","caption":"사진 설명"},{"type":"image","url":"javascript:x"},
        {"type":"list","items":[{"content":"하나"},{"content":"둘"}]},{"type":"raw_html","content":"<div>광고</div>"}]};Fusion.x=1;</script></html>
        """
        let a = EmbeddedArticle.extract(Data(html.utf8))
        #expect(a?.title == "제목 {괄호}")
        #expect(a?.byline == "최 기자")
        #expect(a?.blocks.map(\.type) == [.p, .h, .img, .cap, .li, .li])
        #expect(a?.blocks[0].text?.hasSuffix("&끝") == true)
        #expect(a?.blocks[1].text == "◇ 소제목 \"인용\"")
    }

    @Test func ldJSONGraph() {
        let html = """
        <script type="application/ld+json">{"@type":"Organization","name":"X"}</script>
        <script type="application/ld+json">{"@graph":[{"@type":"WebPage"},{"@type":"NewsArticle","headline":"H","author":[{"name":"A"},{"name":"B"}],
        "articleBody":"\(Self.para)\\n\\n둘째 문단 &#39;따옴표&#39; &#x2014; 끝"}]}</script>
        """
        let a = EmbeddedArticle.extract(Data(html.utf8))
        #expect(a?.title == "H")
        #expect(a?.byline == "A · B")
        #expect(a?.blocks.count == 2)
        #expect(a?.blocks.last?.text == "둘째 문단 '따옴표' — 끝")
    }

    @Test func tooShortOrBroken() {
        #expect(EmbeddedArticle.extract(Data(#"Fusion.globalContent={"content_elements":[{"type":"text","content":"짧다"}]}"#.utf8)) == nil)
        #expect(EmbeddedArticle.extract(Data(#"Fusion.globalContent={"content_elements":[{"type":"text","content":"끝나지 않음"#.utf8)) == nil)
        #expect(EmbeddedArticle.extract(Data("<p>그냥 페이지</p>".utf8)) == nil)
        #expect(EmbeddedArticle.balancedObject(#" {"a":"}{\"","b":{}} tail"#[...]) == #"{"a":"}{\"","b":{}}"#)
    }
}

// FeedService 고침 두 곳(READSWEEP): 응답 코드를 IP 판정보다 먼저, og:image:type 을 사진 주소로 잡지 않기
@Suite struct FeedServiceFixTests {
    final class Calls: @unchecked Sendable { var n = 0 }

    @Test func errorCodesSkipIPCheck() async throws {
        for code in [401, 403, 404, 429, 500] {
            let calls = Calls()
            do {
                _ = try await FeedService.settle(status: code, checkIP: true, isSafe: { calls.n += 1; return false }, remote: { nil })
                Issue.record("\(code) 가 오류로 안 나옴")
            } catch FeedError.http(let c) {
                #expect(c == code)
            }
            #expect(calls.n == 0) // 측정값을 기다리지 않는다(끊은 전송엔 오지 않음)
        }
        #expect(try await FeedService.settle(status: 304, checkIP: true, isSafe: { false }, remote: { nil }) == true)
    }

    @Test func successStillChecksIP() async throws {
        let calls = Calls()
        #expect(try await FeedService.settle(status: 200, checkIP: true, isSafe: { calls.n += 1; return true }, remote: { "1.1.1.1" }) == false)
        #expect(calls.n == 1)
        await #expect(throws: FeedError.self) {
            _ = try await FeedService.settle(status: 200, checkIP: true, isSafe: { false }, remote: { "10.0.0.1" })
        }
    }

    // 로컬 시험 서버가 DW 꼴 머리(content 먼저, og:image:type 이 앞)를 주면 진짜 사진 주소를 돌려준다
    @Test func ogImageSkipsTypeMeta() async throws {
        let html = #"<html><head><meta content="image/jpeg" property="og:image:type"><meta content="https://static.dw.com/image/1_6.jpg" property="og:image"></head></html>"#
        let listener = try NWListener(using: .tcp, on: .any)
        let q = DispatchQueue(label: "og-http")
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { conn in
            conn.start(queue: q)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                let body = Data(html.utf8)
                let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        listener.start(queue: q)
        _ = ready.wait(timeout: .now() + 5)
        defer { listener.cancel() }
        let port = listener.port?.rawValue ?? 0
        let og = await FeedService(allowLocalForTests: true).ogImage("http://127.0.0.1:\(port)/en/a")
        #expect(og == "https://static.dw.com/image/1_6.jpg")
    }
}

@MainActor @Suite(.serialized) struct BlockedHostTests {
    @Test func oneFailureDoesNotBlockWorkingSite() {
        let h = "nyt.example.test"
        ArticleExtractor.slowWorks.remove(h); ArticleExtractor.blockedHosts.remove(h); ArticleExtractor.refusedFails[h] = nil
        #expect(ArticleExtractor.slowWait(refused: true, host: h) == 6)
        ArticleExtractor.noteSlow(host: h, refused: true, ok: true)
        #expect(ArticleExtractor.slowWait(refused: true, host: h) == 10)
        ArticleExtractor.noteSlow(host: h, refused: true, ok: false)
        ArticleExtractor.noteSlow(host: h, refused: true, ok: false)
        #expect(!ArticleExtractor.blockedHosts.contains(h))
        #expect(ArticleExtractor.slowWait(refused: false, host: h) == 15)
    }

    @Test func twoRefusedFailuresBlock() {
        let h = "geeknews.example.test"
        ArticleExtractor.slowWorks.remove(h); ArticleExtractor.blockedHosts.remove(h); ArticleExtractor.refusedFails[h] = nil
        ArticleExtractor.noteSlow(host: h, refused: true, ok: false)
        #expect(!ArticleExtractor.blockedHosts.contains(h))
        ArticleExtractor.noteSlow(host: h, refused: false, ok: false) // 거절 아닌 실패는 세지 않음
        ArticleExtractor.noteSlow(host: h, refused: true, ok: false)
        #expect(ArticleExtractor.blockedHosts.contains(h))
        ArticleExtractor.blockedHosts.remove(h)
    }
}
