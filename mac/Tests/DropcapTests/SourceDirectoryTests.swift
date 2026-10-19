import Foundation
import Testing
@testable import Dropcap

// 설정 › 구독 목록 정리(SourceDirectory): 매체 묶음 키·이름 · 찾기(이름·주소·분야·지역·대소문자·띄어쓰기) · 켠 것 거르기 · 정렬 · 켠 수
@Suite struct SourceDirectoryTests {
    private func src(_ id: String, _ name: String, section: String = "economy", region: String = "kr", url: String? = nil, home: String? = nil) -> Source {
        Source(id: id, name: name, tier: region == "kr" ? "kr" : "press", type: "feed", url: url ?? "https://\(id).example/rss",
               match: nil, aiOnly: false, defaultOn: false, color: "#000000", home: home, section: section, region: region)
    }

    @Test func mediaKeyAndName() {
        let yna = [src("yna-politics", "연합뉴스 정치", section: "politics"), src("yna-market", "연합뉴스 마켓+"), src("yna-latest", "연합뉴스 최신", section: "top")]
        #expect(Set(yna.map(SourceDirectory.mediaKey)) == ["yna"])
        #expect(SourceDirectory.mediaName(yna) == "연합뉴스")
        #expect(SourceDirectory.shortName(yna[1], media: "연합뉴스") == "마켓+")
        // 첫 낱말이 다르면 대표 피드(id == 묶음 키)의 이름, 없으면 가장 짧은 이름
        let nyt = [src("nyt", "The New York Times", region: "intl"), src("nyt-politics", "NYT Politics", region: "intl"), src("nyt-arts", "NYT Arts", region: "intl")]
        #expect(SourceDirectory.mediaName(nyt) == "The New York Times")
        #expect(SourceDirectory.mediaName(Array(nyt.dropFirst())) == "NYT")
        // 실제 sources.json: 대표 피드가 nyt-home(묶음 키 nyt 와 다름)
        let nytHome = [src("nyt-home", "The New York Times", region: "intl"), src("nyt-politics", "NYT Politics", region: "intl"), src("nyt-arts", "NYT Arts", region: "intl")]
        #expect(SourceDirectory.mediaName(nytHome) == "The New York Times")
        #expect(SourceDirectory.mediaName([src("x-a", "Alpha One"), src("x-b", "Beta")]) == "Beta")
        #expect(SourceDirectory.shortName(nyt[1], media: "The New York Times") == "NYT Politics")
        // 같은 이름 둘(Ars Technica 두 피드)은 그 이름 그대로, 짧은 이름도 그대로
        let ars = [src("ars", "Ars Technica", region: "intl"), src("ars-ai", "Ars Technica", region: "intl")]
        #expect(SourceDirectory.mediaName(ars) == "Ars Technica")
        #expect(SourceDirectory.shortName(ars[0], media: "Ars Technica") == "Ars Technica")
        // 기본 출처: 연합뉴스·BBC 피드가 한 묶음
        let groups = SourceDirectory.groups(all: Resources.config.sources, shown: Resources.config.sources, layout: .media, enabled: { _ in false })
        #expect(groups.first { $0.id == "media:yna" }?.title == "연합뉴스")
        #expect((groups.first { $0.id == "media:yna" }?.total ?? 0) >= 10)
        #expect(groups.first { $0.id == "media:bbc" }?.title == "BBC")
        #expect(groups.reduce(0) { $0 + $1.total } == Resources.config.sources.count) // 빠짐·겹침 없음
    }

    @Test func searchMatchesNameURLSectionRegionIgnoringCaseAndSpaces() {
        let list = [src("bbc-world", "BBC World", section: "world", region: "intl", url: "https://feeds.bbci.co.uk/news/world/rss.xml"),
                    src("hk-it", "한국경제 IT", section: "tech", home: "https://www.hankyung.com/it"),
                    src("yna-market", "연합뉴스 마켓+")]
        func q(_ s: String) -> [String] { SourceDirectory.filter(list, query: s, status: .all, enabled: { _ in true }).map(\.id) }
        #expect(q("bbc world") == ["bbc-world"])          // 대소문자·띄어쓰기 무시
        #expect(q("BBCWORLD") == ["bbc-world"])
        #expect(q("bbci.co.uk") == ["bbc-world"])        // 주소
        #expect(q("hankyung") == ["hk-it"])              // 사람이 보는 주소(home)
        #expect(q("국제") == ["bbc-world"])               // 분야 이름
        #expect(q("해외") == ["bbc-world"])               // 지역
        #expect(q("국내") == ["hk-it", "yna-market"])
        #expect(q("  ").count == 3)                      // 빈 찾기는 전부
        #expect(q("없는출처").isEmpty)
    }

    @Test func statusFilter() {
        let list = [src("a", "가"), src("b", "나"), src("c", "다")]
        let on: Set<String> = ["a", "c"]
        #expect(SourceDirectory.filter(list, query: "", status: .on, enabled: on.contains).map(\.id) == ["a", "c"])
        #expect(SourceDirectory.filter(list, query: "", status: .off, enabled: on.contains).map(\.id) == ["b"])
        #expect(SourceDirectory.filter(list, query: "나", status: .on, enabled: on.contains).isEmpty)
    }

    @Test func sortingDomesticFirstThenABC() {
        let list = [src("x", "Zeta", region: "intl"), src("y", "한겨레", region: "kr"), src("z", "alpha", region: "intl"), src("w", "경향신문", region: "kr")]
        #expect(SourceDirectory.sorted(list).map(\.name) == ["경향신문", "한겨레", "alpha", "Zeta"])
    }

    @Test func groupCountsAndBulkTargetsOnlyShown() {
        let all = [src("yna-a", "연합뉴스 경제"), src("yna-b", "연합뉴스 정치", section: "politics"), src("yna-c", "연합뉴스 국제", section: "world"),
                   src("bbc-a", "BBC World", section: "world", region: "intl")]
        let on: Set<String> = ["yna-a", "yna-b"]
        let shown = SourceDirectory.filter(all, query: "국제", status: .all, enabled: on.contains)
        let media = SourceDirectory.groups(all: all, shown: shown, layout: .media, enabled: on.contains)
        // 국내 먼저, 묶음 켠 수는 묶음 전체(2/3), 보이는 것은 거른 것만(묶음 켜기·끄기는 이것에만)
        #expect(media.map(\.id) == ["media:yna", "media:bbc"])
        #expect((media[0].on, media[0].total) == (2, 3))
        #expect(media[0].sources.map(\.id) == ["yna-c"])
        let sections = SourceDirectory.groups(all: all, shown: all, layout: .section, enabled: on.contains)
        #expect(sections.map(\.id) == ["section:politics", "section:economy", "section:world"]) // categories.json 순서
        #expect(sections.last.map { ($0.on, $0.total) } ?? (0, 0) == (0, 2))
        let regions = SourceDirectory.groups(all: all, shown: all, layout: .region, enabled: on.contains)
        #expect(regions.map(\.title) == ["국내", "해외"])
    }

    @Test func summary() {
        let all = [src("a", "가"), src("b", "나", section: "politics"), src("c", "다"), src("d", "라", section: "world")]
        let on: Set<String> = ["a", "b", "c"]
        #expect(SourceDirectory.summaryText(all, enabled: on.contains) == "켠 출처 3곳 · 정치 1 · 경제 2")
        #expect(SourceDirectory.summaryText(all, enabled: { _ in false }) == "켠 출처 없음")
        #expect(SourceDirectory.countText(shown: 12, total: 147) == "147곳 중 12곳")
        #expect(SourceDirectory.countText(shown: 147, total: 147) == "147곳")
    }
}
