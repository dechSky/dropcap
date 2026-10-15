import Foundation
import Testing
@testable import Dropcap

// 일반 뉴스 출처의 실제 피드 모양(2026-10-13 받은 피드에서 날짜·구조만 옮김, 제목은 바꿈)
@Suite struct FeedDateTests {
    private func utc(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        if s.contains(".") { f.formatOptions = [.withInternetDateTime, .withFractionalSeconds] }
        return f.date(from: s)!
    }

    @Test func colonOffsetInRFC822() { // 매일경제·코리아헤럴드: 'Tue, 13 Oct 2026 16:29:45 +09:00'
        #expect(Dates.parse("Tue, 13 Oct 2026 16:29:45 +09:00") == utc("2026-10-13T07:29:45Z"))
    }

    @Test func numericMonth() { // 노컷뉴스: 월을 숫자로
        #expect(Dates.parse("Tue, 13 10 2026 16:00:47 +0900") == utc("2026-10-13T07:00:47Z"))
    }

    @Test func zoneNames() { // Politico 'EDT', ESPN 'EST', OpenAI 'GMT', 국내 'KST'
        #expect(Dates.parse("Mon, 12 Oct 2026 06:55:00 EDT") == utc("2026-10-12T10:55:00Z"))
        #expect(Dates.parse("Tue, 13 Oct 2026 02:35:35 EST") == utc("2026-10-13T07:35:35Z"))
        #expect(Dates.parse("Fri, 09 Oct 2026 07:00:00 GMT") == utc("2026-10-09T07:00:00Z"))
        #expect(Dates.parse("Tue, 13 Oct 2026 16:00:00 KST") == utc("2026-10-13T07:00:00Z"))
    }

    @Test func wrongWeekdayStillParses() {
        #expect(Dates.parse("Mon, 13 Oct 2026 16:00:00 +0900") == utc("2026-10-13T07:00:00Z"))
    }

    @Test func standardFormatsUnchanged() {
        #expect(Dates.parse("Wed, 30 Sep 2026 20:01:45 +0000") == utc("2026-09-30T20:01:45Z"))
        #expect(Dates.parse("Mon, 12 Oct 2026 18:17:43 -0400") == utc("2026-10-12T22:17:43Z"))
        #expect(Dates.parse("2026-10-13T16:41:00+09:00") == utc("2026-10-13T07:41:00Z"))   // 경향 dc:date
        #expect(Dates.parse("2026-10-13T07:37:22Z") == utc("2026-10-13T07:37:22Z"))        // Guardian
        #expect(Dates.parse("2026-10-12T07:13:10.123-04:00") == utc("2026-10-12T11:13:10.123Z"))
    }

    @Test func zonelessIsSeoulTime() { // AI타임스 'yyyy-MM-dd HH:mm:ss', 점 구분, 날짜만(Nature dc:date)
        #expect(Dates.parse("2026-10-13 16:15:42") == utc("2026-10-13T07:15:42Z"))
        #expect(Dates.parse("2026.10.13 16:15") == utc("2026-10-13T07:15:00Z"))
        #expect(Dates.parse("2026-10-12") == utc("2026-10-11T15:00:00Z"))
        #expect(Dates.parse("2026-10-13T16:15:42+0900") == utc("2026-10-13T07:15:42Z"))
    }

    @Test func koreanWords() { // JTBC 옛 피드: '2024년 10월 29일 화요일 오후 11:30:00'
        #expect(Dates.parse("2024년 10월 29일 화요일 오후 11:30:00") == utc("2024-10-29T14:30:00Z"))
        #expect(Dates.parse("2024년 10월 29일 오전 12:05") == utc("2024-10-28T15:05:00Z"))
    }

    @Test func garbageIsNil() {
        #expect(Dates.parse("") == nil)
        #expect(Dates.parse("어제") == nil)
        #expect(Dates.parse("not a date") == nil)
    }
}

@Suite struct FeedRepairTests {
    // 한겨레 RSS 모양: 글마다 pubDate 가 없다
    let hani = """
    <?xml version="1.0" encoding="UTF-8"?><rss xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0"><channel>
    <title><![CDATA[전체기사 : 뉴스 : 한겨레]]></title><lastBuildDate>Tue, 13 Oct 2026 07:04:00 GMT</lastBuildDate>
    <item><title><![CDATA[첫 기사]]></title><link>https://www.hani.co.kr/arti/society/1.html</link><guid isPermaLink="false">1</guid><dc:category>사회</dc:category></item>
    <item><title><![CDATA[둘째 기사]]></title><link>https://www.hani.co.kr/arti/society/2.html</link><guid isPermaLink="false">2</guid></item>
    </channel></rss>
    """

    @Test func undatedGetFirstSeenAndKeepIt() throws {
        var entries = try FeedParser.parseFeed(Data(hani.utf8))
        #expect(entries.allSatisfy { $0.date == nil })
        var memory: [String: Date] = [:]
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        FeedDates.repair(&entries, sourceID: "hani-society", now: t0, firstSeen: &memory)
        #expect(entries.allSatisfy { $0.date == t0 })
        // 다음 확인: 같은 글은 처음 본 시각 그대로, 새 글만 새 시각
        var again = try FeedParser.parseFeed(Data(hani.utf8))
        again.insert(FeedParser.Entry(id: "3", title: "셋째", link: "https://www.hani.co.kr/arti/3.html", date: nil, summary: ""), at: 0)
        let t1 = t0.addingTimeInterval(300)
        FeedDates.repair(&again, sourceID: "hani-society", now: t1, firstSeen: &memory)
        #expect(again[0].date == t1)
        #expect(again[1].date == t0 && again[2].date == t0)
    }

    @Test func futureIsClampedToFetchTime() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var e = [FeedParser.Entry(id: "a", title: "", link: "", date: now.addingTimeInterval(3600), summary: ""),   // ESPN: EDT 를 EST 로
                 FeedParser.Entry(id: "b", title: "", link: "", date: now.addingTimeInterval(5 * 60), summary: ""),  // 10분 안은 둔다
                 FeedParser.Entry(id: "c", title: "", link: "", date: now.addingTimeInterval(-3600), summary: "")]
        var memory: [String: Date] = [:]
        FeedDates.repair(&e, sourceID: "espn", now: now, firstSeen: &memory)
        #expect(e[0].date == now)
        #expect(e[1].date == now.addingTimeInterval(300))
        #expect(e[2].date == now.addingTimeInterval(-3600))
        #expect(memory.isEmpty)
    }

    @Test func nocutFeedParses() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel><title>노컷뉴스</title>
        <item><title>기사</title><link>https://www.nocutnews.co.kr/news/1</link><pubDate>Tue, 13 10 2026 15:48:32 +0900</pubDate></item>
        </channel></rss>
        """
        let e = try FeedParser.parseFeed(Data(xml.utf8))
        #expect(e.first?.date == ISO8601DateFormatter().date(from: "2026-10-13T06:48:32Z"))
    }

    @Test func memoryIsBounded() {
        var memory: [String: Date] = [:]
        for i in 0..<(FeedDates.memoryLimit + 1) { memory["s|\(i)"] = Date(timeIntervalSince1970: Double(i)) }
        var e: [FeedParser.Entry] = []
        FeedDates.repair(&e, sourceID: "s", now: Date(), firstSeen: &memory)
        #expect(memory.count == FeedDates.memoryLimit / 2)
        #expect(memory["s|\(FeedDates.memoryLimit)"] != nil) // 최근 것은 남김
    }
}

@Suite struct SourceHealthTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func days(_ n: Double) -> Date { now.addingTimeInterval(-n * 86400) }

    @Test func statuses() {
        var h = SourceHealth()
        #expect(h.status(now: now) == .unknown)
        h.success(newest: days(1), topID: "a", count: 10, at: now)
        #expect(h.status(now: now) == .ok)
        h.success(newest: days(4), topID: "a", count: 10, at: now) // 더 오래된 값은 무시
        #expect(h.lastNew == days(1))
        #expect(SourceHealth(lastSuccess: now, lastNew: days(5), count: 3).status(now: now) == .quiet(days: 5))
        #expect(SourceHealth(lastSuccess: now, lastNew: days(40), count: 3).status(now: now) == .stalled(days: 40))
        #expect(SourceHealth(lastSuccess: now, count: 0).status(now: now) == .empty)
    }

    @Test func failuresCountUntilSuccess() {
        var h = SourceHealth()
        h.failure("HTTP 404")
        #expect(h.status(now: now) == .failing(count: 1, message: "HTTP 404")) // 한 번도 성공 못 했으면 바로 오류
        h.success(newest: days(0), topID: "x", count: 5, at: now)
        h.failure("HTTP 500"); h.failure("HTTP 500")
        #expect(h.status(now: now) == .ok) // 성공한 적 있으면 3번 연속부터
        h.failure("HTTP 500")
        #expect(h.status(now: now) == .failing(count: 3, message: "HTTP 500"))
        h.success(newest: nil, topID: "x", count: 5, at: now)
        #expect(h.failures == 0)
    }

    @Test func undatedFeedUsesTopItemChange() {
        var h = SourceHealth()
        h.success(newest: nil, topID: "1", count: 30, at: days(10))
        #expect(h.lastNew == days(10))
        h.success(newest: nil, topID: "1", count: 30, at: days(2))
        #expect(h.lastNew == days(10)) // 맨 위 글이 그대로면 새 글 아님
        h.success(newest: nil, topID: "2", count: 30, at: now)
        #expect(h.lastNew == now)
    }

    @MainActor @Test func bookPersists() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("health-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("source-health.json")
        let a = SourceHealthBook(file: file)
        a.recordSuccess("yna-politics", newest: days(1), topID: "t", count: 120, at: now)
        a.recordFailure("dead", error: "HTTP 404", at: now)
        a.saveNow()
        let b = SourceHealthBook(file: file)
        #expect(b.records["yna-politics"]?.count == 120)
        #expect(b.records["dead"]?.failures == 1)
        try? Data("깨짐".utf8).write(to: file)
        #expect(SourceHealthBook(file: file).records.isEmpty) // 깨진 파일은 빈 기록으로
    }
}

@Suite struct OPMLTests {
    @Test func roundTrip() throws {
        let src = [
            Source(id: "a", name: "연합뉴스 정치", tier: "kr", type: "feed", url: "https://www.yna.co.kr/rss/politics.xml", match: nil, aiOnly: false, defaultOn: true, color: "#000", section: "politics"),
            Source(id: "b", name: "SBS \"사회\" & 생활", tier: "kr", type: "feed", url: "https://news.sbs.co.kr/news/SectionRssFeed.do?plink=RSSREADER&sectionId=03", match: nil, aiOnly: false, defaultOn: true, color: "#000", home: "https://news.sbs.co.kr", section: "society"),
            Source(id: "c", name: "OpenAI", tier: "lab", type: "feed", url: "https://openai.com/news/rss.xml", match: nil, aiOnly: false, defaultOn: true, color: "#000"),
        ]
        let xml = OPML.export(src, sectionName: { ["politics": "정치", "society": "사회", "ai": "AI"][$0] ?? $0 })
        #expect(xml.contains("<outline text=\"정치\""))
        let back = try OPML.parse(Data(xml.utf8))
        #expect(back.map(\.url) == src.map(\.url))
        #expect(back[1].title == "SBS \"사회\" & 생활")
        #expect(back[1].home == "https://news.sbs.co.kr")
    }

    @Test func parsesOtherReadersOPML() throws { // Feedly·Inoreader 모양: 폴더 안의 outline, 중복 주소, 폴더만 있는 outline
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="1.0"><head><title>Feeds</title></head><body>
          <outline text="Tech" title="Tech">
            <outline type="rss" text="The Verge" title="The Verge" xmlUrl="https://www.theverge.com/rss/index.xml" htmlUrl="https://www.theverge.com"/>
            <outline type="rss" text="Ars" xmlUrl="https://feeds.arstechnica.com/arstechnica/index"/>
          </outline>
          <outline text="Empty folder"/>
          <outline type="rss" text="Verge again" xmlUrl="https://www.theverge.com/rss/index.xml"/>
          <outline type="rss" text="HN" xmlUrl="https://hnrss.org/frontpage?a=1&amp;b=2"/>
        </body></opml>
        """
        let e = try OPML.parse(Data(xml.utf8))
        #expect(e.map(\.url) == ["https://www.theverge.com/rss/index.xml", "https://feeds.arstechnica.com/arstechnica/index", "https://hnrss.org/frontpage?a=1&b=2"])
        #expect(e[1].title == "Ars")
    }

    @Test func rejectsNonOPML() {
        #expect(throws: (any Error).self) { try OPML.parse(Data("<rss><channel/></rss>".utf8)) }
    }
}

// shared/categories.json · shared/sources.json 의 계약(두 작업자가 함께 쓰는 형식)
@Suite struct SourceDataTests {
    struct Cats: Decodable {
        struct S: Decodable { let id: String; let name: String; let symbol: String; let color: String; let flow: Bool?; let more: Bool? }
        let version: Int
        let sections: [S]
    }
    var cats: Cats { try! JSONDecoder().decode(Cats.self, from: Data(contentsOf: Resources.url("categories.json"))) }

    @Test func categoriesContract() {
        let ids = cats.sections.map(\.id)
        #expect(ids == ["top", "politics", "economy", "society", "world", "tech", "ai", "science", "life", "culture", "sports", "climate"])
        #expect(cats.sections.first { $0.id == "top" }?.flow == true)
        #expect(cats.sections.first { $0.id == "climate" }?.more == true)
    }

    @Test func everySourceHasValidFields() {
        let ids = Set(cats.sections.map(\.id))
        let all = Resources.config.sources
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(Set(all.map(\.url)).count == all.count)
        for s in all {
            #expect(s.section != nil && ids.contains(s.sectionID), "\(s.id) 분야")
            #expect(s.lang != nil, "\(s.id) 언어")
            #expect(s.region == "kr" || s.region == "intl", "\(s.id) 지역")
            #expect(URLSafety.isPublicHTTP(URL(string: s.url)), "\(s.id) 주소")
            #expect(s.tier == "kr" ? s.region == "kr" : true, "\(s.id) 국내 등급")
        }
    }

    @Test func everySectionHasDefaultSources() {
        for sec in cats.sections {
            let on = Resources.config.sources.filter { $0.sectionID == sec.id && $0.defaultOn }
            #expect(!on.isEmpty, "\(sec.id) 에 기본 출처가 없음")
            if !["society", "climate"].contains(sec.id) { // 사회는 국내만, 기후는 국내 피드를 못 찾음
                #expect(on.contains { $0.isDomestic } && on.contains { !$0.isDomestic }, "\(sec.id) 국내·해외 기본 출처")
            }
        }
    }

    @Test func oldAISourcesKeepIdsAndSection() {
        for id in ["openai", "anthropic", "deepmind", "google-ai", "nvidia", "mit-tr", "ars", "verge", "aitimes", "etnews"] {
            let s = Resources.config.sources.first { $0.id == id }
            #expect(s?.sectionID == "ai", "\(id)")
        }
    }

    @Test func defaultsWhenFieldsMissing() throws { // 예전 직접 추가 출처(새 필드 없음)
        let old = ##"{"id":"custom-x","name":"X","tier":"press","type":"feed","url":"https://x.example/feed","aiOnly":false,"defaultOn":true,"color":"#000"}"##
        let s = try JSONDecoder().decode(Source.self, from: Data(old.utf8))
        #expect(s.sectionID == "ai" && s.language == "en" && s.regionCode == "intl")
        let kr = try JSONDecoder().decode(Source.self, from: Data(old.replacingOccurrences(of: "\"press\"", with: "\"kr\"").utf8))
        #expect(kr.regionCode == "kr")
    }
}

// 실제 네트워크: 모든 기본·추천 출처를 받아 날짜까지 읽히는지(DROPCAP_LIVE_TESTS=1 일 때만)
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DROPCAP_LIVE_TESTS"] == "1"))
struct LiveSourceDatesTests {
    @Test func everyFeedParsesWithDates() async throws {
        let undated: Set<String> = ["hani-society", "hani-world", "hani-science", "hani-culture", "hani-sports", "hani-politics", "hani-economy"] // 한겨레는 글 날짜가 없음
        var failures: [String] = []
        for src in Resources.config.sources where src.type == "feed" {
            do {
                guard let data = try await FeedService.shared.fetch(src.url) else { continue }
                let entries = try FeedParser.parseFeed(data)
                if entries.isEmpty { failures.append("\(src.id): 0건"); continue }
                let missing = entries.filter { $0.date == nil }.count
                if !undated.contains(src.id), missing > 0 { failures.append("\(src.id): 날짜 못 읽음 \(missing)/\(entries.count)") }
            } catch {
                failures.append("\(src.id): \(error.localizedDescription)")
            }
        }
        #expect(failures.isEmpty, "\(failures)")
    }
}
