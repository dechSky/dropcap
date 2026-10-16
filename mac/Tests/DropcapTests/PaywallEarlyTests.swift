import Combine
import Foundation
import Testing
@testable import Dropcap

// 유료 기사를 목록 단계에서 알리기(paywall-early — mac/READER-CUT.md '4단계'):
// ① 피드가 기사마다 적은 유료 표시(feed-paid-mark) ② 미리 받기에서 맛보기로 판정된 기사(teaser-mark)

private func tempDB() throws -> (Database, URL) {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("dropcap-paywall-early-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return (Database(file: d.appendingPathComponent("magazine.sqlite")), d)
}

private func item(_ id: String, source: String, link: String, paid: Bool? = nil) -> NewsItem {
    var it = NewsItem(id: id, title: "Title \(id)", titleKo: nil, link: link, date: Date(), summary: "",
                      sourceId: source, sourceName: source.uppercased(), tier: "press")
    it.paid = paid
    return it
}

// 2026-10-16 실제 피드에서 본 표시 꼴(글·주소는 지어냄)
private let feedXML = """
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/"><channel><title>T</title>
<item><title>STAT+: Example drug maker posts results</title><link>https://news.example/a</link><category><![CDATA[Biotech]]></category></item>
<item><title>Plain story</title><link>https://news.example/b</link><category><![CDATA[STAT+]]></category></item>
<item><title>Another plain story</title><link>https://news.example/c</link><category><![CDATA[Artificial intelligence]]></category><category><![CDATA[Subscriber-Only Stories]]></category></item>
<item><title>Exempt story</title><link>https://news.example/d</link><category>Research</category><category>internal-paywall-exempt</category></item>
<item><title>No mark</title><link>https://news.example/e</link><category>Premium cars</category></item>
<item><title>Mid STAT+: not a prefix</title><link>https://news.example/f</link></item>
</channel></rss>
"""

private let atomXML = """
<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom"><title>T</title>
<entry><title>A</title><id>a</id><link href="https://news.example/a"/><category term="Subscriber-Only Stories"/></entry>
<entry><title>B</title><id>b</id><link href="https://news.example/b"/></entry>
</feed>
"""

@Suite struct FeedPaidMarkTests {
    @Test func rssMarks() throws {
        let e = try FeedParser.parseFeed(Data(feedXML.utf8))
        #expect(e.map(\.paid) == [true, true, true, false, nil, nil])
    }

    @Test func atomCategoryTerm() throws {
        let e = try FeedParser.parseFeed(Data(atomXML.utf8))
        #expect(e.map(\.paid) == [true, nil])
    }

    // 기사 단위 값이 출처 값보다 앞선다
    @Test func articleMarkBeatsSource() {
        let meta: [String: SourceMeta] = ["stat": SourceMeta(id: "stat", paywall: "metered"), "nyt": SourceMeta(id: "nyt", paywall: "hard")]
        #expect(Paywall.kind(sourceId: "stat", link: "https://www.statnews.com/a", paid: true, meta: meta) == .hard)
        #expect(Paywall.kind(sourceId: "stat", link: "https://www.statnews.com/a", meta: meta) == .metered)
        #expect(Paywall.kind(sourceId: "nyt", link: "https://www.nytimes.com/a", paid: false, meta: meta) == nil)
        #expect(Paywall.kind(sourceId: "x", link: "https://free.example/a", paid: true, meta: meta) == .hard)
        // 배운 막힘보다도 앞선다
        let many = ["x": Database.ExtractStat(tries: 10, fails: 8, blocked: 0)]
        #expect(Paywall.kind(sourceId: "x", link: "https://free.example/a", paid: false, meta: meta, stats: many) == nil)
    }

    // 피드 표시가 무료 보도 고르기에도 쓰인다: 유료 표시 기사는 권하지 않고, 풀린 기사는 권한다
    @Test func alternativesUseArticleMark() {
        let meta: [String: SourceMeta] = ["nyt": SourceMeta(id: "nyt", paywall: "hard"), "stat": SourceMeta(id: "stat")]
        let me = item("0", source: "wsj", link: "https://wsj.example/0")
        let story = [me, item("1", source: "nyt", link: "https://nyt.example/1", paid: false), item("2", source: "stat", link: "https://stat.example/2", paid: true)]
        #expect(Paywall.freeAlternatives(me, story: story, hidden: [], meta: meta).map(\.sourceId) == ["nyt"])
        #expect(Paywall.freeAlternatives(me, story: story, hidden: [], meta: meta, teasers: ["https://nyt.example/1"]).isEmpty)
    }

    @Test func oldRecordWithoutPaidDecodes() throws {
        let old = #"{"id":"a","title":"T","link":"https://x.example/a","summary":"","sourceId":"s","sourceName":"S","tier":"press"}"#
        #expect(try JSONDecoder().decode(NewsItem.self, from: Data(old.utf8)).paid == nil)
        var it = item("a", source: "s", link: "https://x.example/a", paid: true)
        it = try JSONDecoder().decode(NewsItem.self, from: JSONEncoder().encode(it))
        #expect(it.paid == true)
    }
}

@Suite struct TeaserMarkTests {
    private func p(_ s: String) -> Block { Block(type: .p, text: s) }

    @Test func storeRoundTripAndExpiry() throws {
        let (db, dir) = try tempDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        db.markTeaser("https://a.example/2", true, now: now.addingTimeInterval(-40 * 24 * 3600))
        db.markTeaser("https://a.example/1", true, now: now)
        #expect(db.teaserLinks(now: now) == ["https://a.example/1"])
        db.markTeaser("https://a.example/1", false, now: now)
        #expect(db.teaserLinks(now: now).isEmpty)
        db.markTeaser("https://a.example/3", true, now: now.addingTimeInterval(3600)) // 미래 시각은 다음 기록 때 버림
        db.markTeaser("https://a.example/4", true, now: now)
        #expect(db.teaserLinks(now: now) == ["https://a.example/4"])
    }

    // 미리 받기에서 맛보기 → 목록 자물쇠가 '앞부분만'(다른 자물쇠와 구분) · 다시 받아 전문이면 지움 · 다른 앱 실행에서도 남음
    @MainActor @Test func prefetchTeaserShowsInList() throws {
        let (db, dir) = try tempDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        let book = PaywallBook(db: db)
        let it = item("t", source: "kr-test", link: "https://kr.example/article/000000000i")
        #expect(book.kind(it) == nil)
        let teaser = [p(String(repeating: "가", count: 300)), p(String(repeating: "나", count: 250))]
        let judged = Paywall.isTeaser(teaser, paid: true, kind: book.sourceKind(it)) // 한경 articlePayment="Y" + 짧은 본문
        #expect(judged)
        book.recordTeaser(it, judged)
        #expect(book.kind(it) == .teaser)
        #expect(book.kind(it)?.shortText == "앞부분만")
        #expect(book.kind(it)?.symbol == "lock.fill")
        #expect(PaywallKind.hard.shortText == nil && PaywallKind.metered.shortText == nil)
        #expect(book.sourceKind(it) == nil) // 판정에 넘기는 값은 지난 판정에 끌려가지 않음
        #expect(PaywallBook(db: db).kind(it) == .teaser)
        book.recordTeaser(it, false)
        #expect(book.kind(it) == nil)
        #expect(PaywallBook(db: db).kind(it) == nil)
    }

    // Verge 꼴(ld 본문과 같은 길이)은 맛보기가 아니므로 목록에 표시되지 않는다
    @MainActor @Test func vergeShortStoryNotMarked() throws {
        let (db, dir) = try tempDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        let book = PaywallBook(db: db)
        let it = item("v", source: "verge-all", link: "https://www.theverge.com/news/1/x")
        let blocks = [p(String(repeating: "a", count: 450)), p(String(repeating: "b", count: 449))]
        let judged = Paywall.isTeaser(blocks, paid: true, kind: nil, ldBody: 902)
        #expect(!judged)
        book.recordTeaser(it, judged)
        #expect(book.kind(it) != .teaser) // 출처 값(metered 열린 자물쇠)만
        #expect(book.teasers.isEmpty)
    }
}

// 보안·버그 점검 review-3: B3(다시 맛보기면 시각 갱신) · 시험 빈틈 T1(기사 준비가 부르는 판정 함수 그대로) · 화면 갱신(T4)
@Suite(.serialized) struct TeaserReview3Tests {
    private func p(_ s: String) -> Block { Block(type: .p, text: s) }

    // B3: 다시 맛보기로 판정되면 시각을 새로 써서, 계속 맛보기인 기사가 처음 판정 30일 뒤에 빠지지 않는다(표시는 그대로라 다시 그리지 않음)
    @MainActor @Test func teaserAgainRefreshesTime() throws {
        let (db, dir) = try tempDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = "https://kr.example/article/000000001i"
        db.markTeaser(link, true, now: Date().addingTimeInterval(-29 * 86400))
        let book = PaywallBook(db: db)
        var fired = 0
        let sub = book.objectWillChange.sink { fired += 1 }
        defer { sub.cancel() }
        book.recordTeaser(item("t", source: "kr-test", link: link), true)
        #expect(fired == 0)
        #expect(db.teaserLinks(now: Date().addingTimeInterval(2 * 86400)).contains(link)) // 고치기 전: 29+2일 → 빠짐
    }

    // T1: 기사 준비(ArticleService.run 이 부르는 judgeTeaser)가 목록 표시를 바꾸고, 바뀔 때만 화면(PaywallMark)이 다시 그린다
    @MainActor @Test func serviceJudgementMarksListAndRedraws() throws {
        let (db, dir) = try tempDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        let book = PaywallBook(db: db)
        var fired = 0
        let sub = book.objectWillChange.sink { fired += 1 }
        defer { sub.cancel() }
        let it = item("t", source: "kr-test", link: "https://kr.example/article/000000002i")
        let short = Article(title: nil, byline: nil, siteName: nil, blocks: [p(String(repeating: "가", count: 300)), p(String(repeating: "나", count: 250))], paid: true)
        #expect(ArticleService.judgeTeaser(it, short, book: book))
        #expect(book.kind(it) == .teaser)
        #expect(fired == 1)
        #expect(ArticleService.judgeTeaser(it, short, book: book)) // 같은 판정 — 다시 그리지 않음
        #expect(fired == 1)
        let full = Article(title: nil, byline: nil, siteName: nil, blocks: [p(String(repeating: "다", count: 1200)), p(String(repeating: "라", count: 1200))], paid: true)
        #expect(!ArticleService.judgeTeaser(it, full, book: book)) // 표시가 맛보기여도 판정은 받은 본문으로(지난 판정에 끌려가지 않음)
        #expect(book.kind(it) == nil)
        #expect(fired == 2)
    }
}
