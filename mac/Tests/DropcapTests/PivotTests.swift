import Foundation
import Testing
@testable import Dropcap

// 일반 뉴스 전환: 분야 체계·분야 정하기·분야별 알림 정책. 견본 자료는 계약 형식(Fixtures/)으로 둔다.
private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
private let meta = Sections.loadMeta(fixtures.appendingPathComponent("sources-sample.json"))
private let ai = try! NSRegularExpression(pattern: "\\b(AI|LLM|GPT)\\b|인공지능|생성형", options: [.caseInsensitive])

private func item(_ title: String, source: String, tier: String = "kr", summary: String = "") -> NewsItem {
    NewsItem(id: title, title: title, titleKo: nil, link: "https://a.com/\(title.hashValue)", date: Date(), summary: summary,
             sourceId: source, sourceName: source, tier: tier)
}

@Suite struct SectionCatalogTests {
    @Test func loadsContractFile() throws {
        let s = try #require(Sections.load(fixtures.appendingPathComponent("categories.json")))
        #expect(s.map(\.id) == Sections.builtin.map(\.id)) // 기본값과 계약 파일이 같은 id·순서
        #expect(s.first { $0.id == "top" }?.isFlow == true)
        #expect(s.first { $0.id == "climate" }?.isMore == true)
        #expect(Sections.load(fixtures.appendingPathComponent("없음.json")) == nil)
    }

    @Test func contractSourcesStillDecodeAsSourceConfig() throws { // 새 필드가 붙어도 기존 Source 해석이 깨지지 않는다
        let d = try Data(contentsOf: fixtures.appendingPathComponent("sources-sample.json"))
        let c = try JSONDecoder().decode(SourceConfig.self, from: d)
        #expect(c.sources.count == 10)
    }

    @Test func sourceSectionAndRegion() {
        #expect(Sections.section(ofSource: "yna-market", meta: meta) == "economy")
        #expect(Sections.section(ofSource: "cat-yt-openai", meta: meta) == "ai") // 추천 채널은 AI 시절 것
        #expect(Sections.section(ofSource: "custom-x1", meta: meta) == nil)      // 주소로 직접 추가한 출처는 모름
        #expect(Sections.region(ofSource: "cnbc", tier: "press", meta: meta) == "intl")
        #expect(Sections.region(ofSource: "custom-x1", tier: "kr", meta: meta) == "kr")
    }
}

@Suite struct PlacementTests {
    @Test func sourceSectionComesFirst() {
        let p = Sections.place(item("국회 예산안 처리", source: "yna-market"), meta: meta, aiRegex: ai)
        #expect(p.primary == "economy") // 출처의 분야가 1순위(낱말은 정치여도)
        #expect(p.chips.contains("politics")) // 낱말 분야는 칩으로
    }
    @Test func generalFeedUsesKeywords() {
        #expect(Sections.place(item("코스피 2,900 회복…외국인 순매수", source: "yna-latest"), meta: meta, aiRegex: ai).primary == "economy")
        #expect(Sections.place(item("프로야구 한국시리즈 7차전", source: "yna-latest"), meta: meta, aiRegex: ai).primary == "sports")
        #expect(Sections.place(item("오늘의 날씨 이야기", source: "yna-latest"), meta: meta, aiRegex: ai).primary == "life")
        #expect(Sections.place(item("짧은 소식", source: "yna-latest"), meta: meta, aiRegex: ai).primary == "top") // 짐작 못 하면 주요
    }
    @Test func aiIsPulledFromOtherSections() {
        let p = Sections.place(item("은행권, 생성형 AI 상담 도입", source: "yna-market"), meta: meta, aiRegex: ai)
        #expect(p.primary == "economy" && p.chips.contains("ai")) // 대표는 경제, AI 칩도
    }
    @Test func englishKeywordsUseWordBoundaries() {
        #expect(Sections.classify("The marketing team") == nil) // 'market' 이 'marketing' 에 걸리지 않게
        #expect(Sections.classify("Fed holds interest rate") == "economy")
    }
}

@Suite struct NotifyPolicyTests {
    private let l = PolicyLimits()
    private func input(_ mode: NotifyMode, kr: Int = 1, intl: Int = 0, lab: Bool = false, star: Bool = false, followed: Bool = false,
                       sec: Int = 0, total: Int = 0, chosen: Bool = true, cap: Int = 3) -> NotifyPolicy.Input {
        .init(chosen: chosen, policy: SectionPolicy(mode: mode, dailyCap: cap), coverage: Coverage(kr: kr, intl: intl),
              lab: lab, important: star, followed: followed, sentInSection: sec, sentTotal: total)
    }

    // 결정 표: 분야 모드 × 문턱 × 상한 → 알림/고임/매거진만
    @Test(arguments: [
        // (설명, 모드, 국내, 해외, 공식, ★, 팔로우, 오늘 분야, 오늘 전체, 고른 분야, 기대)
        ("고르지 않은 분야", NotifyMode.instant, 9, 0, false, false, false, 0, 0, false, NotifyDecision.quiet),
        ("매거진만", .magazine, 9, 9, true, true, true, 0, 0, true, .quiet),
        ("묶음은 늘 고임", .bundle, 9, 0, true, false, false, 0, 0, true, .pool),
        ("즉시·한 곳뿐", .instant, 1, 0, false, false, false, 0, 0, true, .quiet),
        ("즉시·국내 2곳은 문턱 아래", .instant, 2, 0, false, false, false, 0, 0, true, .quiet),
        ("즉시·국내 3곳", .instant, 3, 0, false, false, false, 0, 0, true, .drop),
        ("즉시·해외 2곳", .instant, 0, 2, false, false, false, 0, 0, true, .drop),
        ("즉시·국내1+해외1 은 문턱 아래", .instant, 1, 1, false, false, false, 0, 0, true, .quiet),
        ("즉시·공식 발표", .instant, 0, 1, true, false, false, 0, 0, true, .drop),
        ("즉시·꼭 알림 낱말", .instant, 1, 0, false, true, false, 0, 0, true, .drop),
        ("즉시·팔로우한 스토리", .instant, 1, 0, false, false, true, 0, 0, true, .drop),
        ("분야 상한에 닿으면 고임", .instant, 3, 0, false, false, false, 3, 3, true, .pool),
        ("전체 상한에 닿으면 고임", .instant, 3, 0, false, false, false, 0, 10, true, .pool),
        ("상한이어도 국내 8곳이면 알림", .instant, 8, 0, false, false, false, 3, 10, true, .drop),
        ("상한·공식 발표는 고임", .instant, 1, 0, true, false, false, 3, 3, true, .pool),
    ])
    func table(_ name: String, _ mode: NotifyMode, _ kr: Int, _ intl: Int, _ lab: Bool, _ star: Bool, _ followed: Bool,
               _ sec: Int, _ total: Int, _ chosen: Bool, _ want: NotifyDecision) {
        let got = NotifyPolicy.decide(input(mode, kr: kr, intl: intl, lab: lab, star: star, followed: followed, sec: sec, total: total, chosen: chosen), limits: l)
        #expect(got == want, "\(name)")
    }

    @Test func topFlowCatchesBigStoriesFromQuietSections() {
        // 스포츠는 매거진만이지만 국내 4곳이 다룬 큰 소식 → 주요 뉴스(즉시)로 알림
        let own = input(.magazine, kr: 4)
        let top = input(.instant, kr: 0)
        let (d, viaTop) = NotifyPolicy.decideWithTop(own, top: top, limits: l)
        #expect(d == .drop && viaTop)
        // 문턱 아래면 주요 뉴스로도 안 감
        #expect(NotifyPolicy.decideWithTop(input(.magazine, kr: 1), top: top, limits: l).0 == .quiet)
        // 주요 뉴스를 안 골랐으면 그대로
        #expect(NotifyPolicy.decideWithTop(own, top: nil, limits: l).0 == .quiet)
        // 주요 뉴스도 상한에 닿았으면 자기 분야 결정(묶음이면 고임)
        #expect(NotifyPolicy.decideWithTop(input(.bundle, kr: 4), top: input(.instant, sec: 3, total: 3), limits: l).0 == .pool)
    }

    @Test func customThresholds() {
        var l2 = PolicyLimits(); l2.krThreshold = 2
        #expect(NotifyPolicy.decide(input(.instant, kr: 2), limits: l2) == .drop)
    }

    @Test func firstRunDefaultsTwoInstant() {
        let d = NotifyPolicy.defaults(for: ["top", "politics", "economy", "sports", "ai"])
        #expect(d["top"]?.mode == .instant)
        #expect(d["politics"]?.mode == .instant && d["economy"]?.mode == .instant)
        #expect(d["sports"]?.mode == .bundle && d["ai"]?.mode == .bundle)
    }

    @Test func bundleTiming() {
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        let at = { (h: Int) in day.addingTimeInterval(Double(h) * 3600 + 60) }
        #expect(!NotifyPolicy.bundleDue(hour: 18, now: at(17), last: nil))
        #expect(NotifyPolicy.bundleDue(hour: 18, now: at(18), last: nil))
        #expect(!NotifyPolicy.bundleDue(hour: 18, now: at(20), last: at(18)))      // 오늘 이미 보냄
        #expect(NotifyPolicy.bundleDue(hour: 18, now: at(20), last: at(9)))        // 오늘 보낸 건 그 시각 전(다른 시각 설정)
        #expect(NotifyPolicy.bundleDue(hour: 18, now: at(19), last: at(18) - 86400)) // 어제 보냄
    }

    @Test func oldPolicyFileStillReads() throws {
        let p = try JSONDecoder().decode(SectionPolicy.self, from: Data(#"{"mode":"instant"}"#.utf8))
        #expect(p.mode == .instant && p.bundleHour == 18 && p.dailyCap == 3)
        let bad = try JSONDecoder().decode(SectionPolicy.self, from: Data(#"{"mode":"weird"}"#.utf8))
        #expect(bad.mode == .bundle)
    }
}

@Suite struct SectionMigrationTests {
    private let sources: [Source] = {
        let d = try! Data(contentsOf: fixtures.appendingPathComponent("sources-sample.json"))
        return try! JSONDecoder().decode(SourceConfig.self, from: d).sources
    }()

    @Test func existingUserBecomesAIOnly() {
        var s = AppState()
        s.enabled["openai"] = true
        let p = Store.prepare(s, existing: true, sources: sources, meta: meta)
        #expect(p.sectionsChosen == ["ai"])
        #expect(p.sectionPolicy["ai"]?.mode == .instant) // 예전처럼 AI 는 즉시
        #expect(p.enabled["aitimes"] == true)            // AI 분야 기본 출처는 켜짐
        #expect(p.enabled["yna-market"] == false)        // 새 국내 언론이 한꺼번에 켜지지 않음
    }

    @Test func newUserWaitsForOnboarding() {
        let p = Store.prepare(AppState(), existing: false, sources: sources, meta: meta)
        #expect(p.sectionsChosen == nil)
        #expect(p.enabled["yna-market"] == false && p.enabled["openai"] == false)
    }

    @Test func oldStateFileWithoutSectionFieldsDecodes() throws {
        let s = try JSONDecoder().decode(AppState.self, from: Data(#"{"unread":2,"settings":{"sound":false}}"#.utf8))
        #expect(s.sectionsChosen == nil && s.pending.isEmpty && s.settings.totalDailyCap == 10)
    }
}

@Suite struct SectionPageTests {
    private func stored(_ title: String, source: String, cluster: String? = nil, tier: String = "kr") -> Database.StoredItem {
        .init(item: item(title, source: source, tier: tier), firstSeen: Date(), cluster: cluster)
    }

    @Test func topThenChosenThenOthers() {
        let big = [stored("금리 동결", source: "yna-market", cluster: "c1"), stored("금리 동결 2", source: "hk-finance", cluster: "c1"),
                   stored("금리 동결 3", source: "yna-politics", cluster: "c1")]
        let articles = [big[0], stored("코스닥 상승", source: "hk-finance"), stored("환율 하락", source: "yna-market"),
                        stored("여야 합의", source: "yna-politics"), stored("야구 결승", source: "yna-sports")]
        let pages = Magazine.sectionPages(articles, stored: articles + big, chosen: ["top", "politics", "economy"],
                                          limits: PolicyLimits(), perSection: 12, meta: meta)
        #expect(pages.first?.section == "top" && pages.first?.keys == [big[0].item.key]) // 국내 3곳 → 주요
        #expect(pages.compactMap(\.section) == ["top", "politics", "economy"])
        #expect(pages.last?.section == nil && pages.last?.keys.count == 1) // 고르지 않은 스포츠 한 건은 '그 밖의 소식'
    }

    @Test func regionSplit() {
        let items = [item("a", source: "cnbc", tier: "press"), item("b", source: "yna-market"), item("c", source: "bbc-world", tier: "press")]
        let s = Magazine.splitByRegion(items, meta: meta)
        #expect(s.intl.count == 2 && s.kr.count == 1)
    }
}

@Suite @MainActor struct ReduceTests {
    @Test func titleWordsSkipNoise() {
        let w = AppModel.titleWords(NewsItem(id: "1", title: "The new GPT-6 model from OpenAI", titleKo: "오픈AI 새 GPT-6 모델 공개",
                                             link: "", date: nil, summary: "", sourceId: "s", sourceName: "S", tier: "press"))
        #expect(w.contains("GPT-6") && w.contains("OpenAI") && w.contains("오픈AI"))
        #expect(!w.contains("The") && !w.contains("new"))
    }
}
