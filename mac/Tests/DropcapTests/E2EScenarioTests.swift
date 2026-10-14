import CoreGraphics
import Foundation
import Testing
@testable import Dropcap

// 사용자 흐름 시나리오(mac/scripts/e2e/run.sh)의 논리 단계를 앱 없이 다시 본다.
// 시나리오가 기대하는 결과(알림·고임·매거진만)가 정책·같은 소식 판단과 어긋나면 여기서 먼저 깨진다.

private func item(_ s: E2EStory, _ i: Int) -> NewsItem {
    let src = s.sources[i]
    let tier = Resources.config.sources.first { $0.id == src }?.tier ?? "press"
    return NewsItem(id: s.id + "-" + src, title: s.title(for: i), titleKo: nil, link: "https://news.e2e.example/\(src)/\(s.id)",
                    date: Date(), summary: s.summary, sourceId: src, sourceName: src, tier: tier)
}

@Suite struct E2EStoryDesignTests {
    typealias S = E2EStories
    static let all: [E2EStory] = [S.s1, S.s2, S.s3, S.s4, S.big, S.q1, S.q2, S.hidden, S.less, S.muted, S.control, S.after] + S.caps

    // 한 이야기를 다룬 출처들은 서로 같은 소식으로 묶여야 보도 수(국내·해외)가 맞게 센다
    @Test func sameStoryAcrossSources() {
        for s in Self.all where s.sources.count > 1 {
            let keys = s.sources.indices.map { StoryKey(item(s, $0)) }
            for k in keys.dropFirst() { #expect(StoryGrouper.same(keys[0], k), "\(s.id) 가 한 스토리로 묶이지 않음") }
        }
    }

    // 다른 이야기끼리는 묶이면 안 된다(낱말 기준: 한국어 제목은 오프라인에서 영어 제목이 없어 낱말로만 비교)
    @Test func differentStoriesStayApart() {
        let firsts = Self.all.map { (id: $0.id, key: StoryKey(item($0, 0))) }
        // 같은 출처끼리는 늘 다르다고 보므로 출처를 바꿔 비교한다
        for a in firsts {
            for b in Self.all where b.id != a.id {
                let other = StoryKey(NewsItem(id: "x", title: b.title(for: 0), titleKo: nil, link: "https://x", date: Date(), summary: "",
                                              sourceId: "other-src", sourceName: "x", tier: "press"))
                #expect(!StoryGrouper.same(a.key, other), "\(a.id) 와 \(b.id) 가 같은 소식으로 묶임")
            }
        }
    }

    // 재보도·팔로우 보도는 원래 이야기와 같은 소식
    @Test func followUpsJoinTheirStory() {
        for (a, b) in [(S.s1, S.s1again), (S.s1, S.s1late), (S.s2, S.s2follow)] {
            #expect(StoryGrouper.same(StoryKey(item(a, 0)), StoryKey(item(b, 0))))
        }
    }

    // 국내 8곳 이야기에 실제로 국내 출처 8곳이 들어 있고, 고르지 않은 분야에서 더 켜는 출처는 기본으로 꺼져 있다
    @Test func bigStoryHasEightDomesticSources() {
        let kr = S.big.sources.filter { Sections.region(ofSource: $0, tier: "press") == "kr" }
        #expect(Set(kr).count >= 8)
        for id in S.extraKr { #expect(!["top", "economy", "world", "ai"].contains(Sections.meta[id]?.section ?? "")) }
    }

    // aiOnly 출처(aitimes)는 AI 낱말이 든 글만 받으므로 b8 제목에 AI 낱말이 있어야 한다
    @Test func aiOnlySourceSeesBigStory() {
        let t = S.big.title(for: S.big.sources.firstIndex(of: "aitimes")!)
        #expect(Resources.aiRegex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil)
    }
}

// 시나리오 4·5단계를 정책만으로 다시: 즉시 분야는 문턱·상한, 주요 뉴스 흐름, 국내 8곳 예외
@Suite struct E2EPolicySequenceTests {
    struct Story { var id: String; var section: String; var cov: Coverage }

    // AppModel.decide 와 같은 순서로 하루치를 판단한다(분야별·전체 수를 세며)
    static func run(_ stories: [Story], policies: [String: SectionPolicy], chosen: Set<String>, limits l: PolicyLimits = PolicyLimits(),
                    sent: [String: Int] = [:]) -> (out: [String: String], sent: [String: Int]) {
        var sent = sent, out: [String: String] = [:]
        for s in stories {
            let total = sent.values.reduce(0, +)
            let input = NotifyPolicy.Input(chosen: chosen.contains(s.section), policy: policies[s.section] ?? SectionPolicy(), coverage: s.cov,
                                           sentInSection: sent[s.section] ?? 0, sentTotal: total)
            let top = chosen.contains(Sections.top) ? NotifyPolicy.Input(chosen: true, policy: policies[Sections.top] ?? SectionPolicy(mode: .instant),
                                                                          coverage: s.cov, sentInSection: sent[Sections.top] ?? 0, sentTotal: total) : nil
            let (d, viaTop) = NotifyPolicy.decideWithTop(input, top: top, limits: l)
            switch d {
            case .drop: out[s.id] = viaTop ? "top" : s.section; sent[viaTop ? Sections.top : s.section, default: 0] += 1
            case .pool: out[s.id] = "pool"
            case .quiet: out[s.id] = "quiet"
            }
        }
        return (out, sent)
    }

    static let chosen = ["top", "economy", "world", "ai"]
    static let policies = NotifyPolicy.defaults(for: chosen)

    @Test func defaultsMatchStep2() {
        #expect(Self.policies.mapValues(\.mode) == ["top": .instant, "economy": .instant, "world": .instant, "ai": .bundle])
    }

    @Test func step4NewArrivals() {
        let (out, _) = Self.run([
            Story(id: "s1", section: "economy", cov: Coverage(kr: 3, intl: 0)),
            Story(id: "s2", section: "economy", cov: Coverage(kr: 2, intl: 0)),
            Story(id: "s3", section: "world", cov: Coverage(kr: 0, intl: 2)),
            Story(id: "s4", section: "ai", cov: Coverage(kr: 0, intl: 1)),
        ], policies: Self.policies, chosen: Set(Self.chosen))
        #expect(out == ["s1": "economy", "s2": "quiet", "s3": "world", "s4": "pool"])
    }

    @Test func step5DailyCaps() {
        // 4단계에서 경제 1·국제 1을 이미 보냄
        let caps = (1...6).map { Story(id: "e\($0)", section: "economy", cov: Coverage(kr: 3, intl: 0)) }
        let (out, sent) = Self.run(caps + [Story(id: "b8", section: "economy", cov: Coverage(kr: 8, intl: 0))],
                                   policies: Self.policies, chosen: Set(Self.chosen), sent: ["economy": 1, "world": 1])
        #expect(out == ["e1": "economy", "e2": "economy", "e3": "top", "e4": "top", "e5": "top", "e6": "pool", "b8": "economy"])
        #expect(sent == ["economy": 4, "world": 1, "top": 3])
    }

    // 11단계: '이 분야 덜 받기'(즉시 → 묶음)를 누른 분야는 주요 뉴스 흐름으로도 떨어지지 않고 묶음으로 고인다(결정됨)
    @Test func lessOfStaysOutOfTopFlow() {
        var p = Self.policies
        p["world"]?.mode = .bundle
        p["world"]?.less = true
        let (out, _) = Self.run([Story(id: "w2", section: "world", cov: Coverage(kr: 0, intl: 2))], policies: p, chosen: Set(Self.chosen))
        #expect(out["w2"] == "pool")
        // 국내 8곳짜리 큰 소식도 덜 받기 분야면 묶음으로
        let (big, _) = Self.run([Story(id: "b", section: "world", cov: Coverage(kr: 8, intl: 2))], policies: p, chosen: Set(Self.chosen))
        #expect(big["b"] == "pool")
        // 그냥 묶음 분야(덜 받기 아님)는 예전처럼 주요 뉴스 흐름이 받는다
        p["world"]?.less = false
        let (plain, _) = Self.run([Story(id: "w3", section: "world", cov: Coverage(kr: 0, intl: 2))], policies: p, chosen: Set(Self.chosen))
        #expect(plain["w3"] == "top")
    }

    @Test func lessFlagSurvivesOldAndNewFiles() throws {
        let old = try JSONDecoder().decode(SectionPolicy.self, from: Data(#"{"mode":"bundle","bundleHour":18,"dailyCap":3}"#.utf8))
        #expect(old.less == false)
        let back = try JSONDecoder().decode(SectionPolicy.self, from: JSONEncoder().encode(SectionPolicy(mode: .bundle, less: true)))
        #expect(back.less)
    }

    @Test func bundleClock() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let d = cal.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 18, minute: 1))!
        #expect(NotifyPolicy.bundleDue(hour: 18, now: d, last: nil, calendar: cal))
        #expect(!NotifyPolicy.bundleDue(hour: 18, now: d.addingTimeInterval(2 * 3600), last: d, calendar: cal)) // 같은 날 두 번 안 보냄
        #expect(NotifyPolicy.bundleDue(hour: 18, now: d.addingTimeInterval(24 * 3600 + 4 * 3600), last: d, calendar: cal)) // 다음 날 22시 = 다시
        #expect(!NotifyPolicy.bundleDue(hour: 18, now: d.addingTimeInterval(-3600), last: nil, calendar: cal))     // 17시는 아직
    }

    @Test func quietHours() {
        #expect(AppModel.inQuiet(hour: 22, start: 22, end: 23))
        #expect(!AppModel.inQuiet(hour: 23, start: 22, end: 23))
        #expect(AppModel.inQuiet(hour: 2, start: 23, end: 7))
    }
}

@Suite struct E2EFeedFixtureTests {
    // 시험 모드가 아니면 아무것도 바꾸지 않는다(일반 실행 영향 없음)
    @Test func inertOutsideTestMode() throws {
        #expect(!E2EFeeds.active)
        #expect(try E2EFeeds.serve("https://openai.com/news/rss.xml") == nil)
        #expect(!E2EFeeds.allows(URL(string: "https://news.e2e.example/x")))
    }

    @Test func rssAndAtomParse() throws {
        let posts = [E2EFeeds.Post(sourceId: "bbc-world", id: "a1", title: "Ocean treaty & summit", summary: "<b>x</b>", date: Date(timeIntervalSince1970: 1_800_000_000),
                                   image: "https://img.e2e.example/a1.png")]
        for xml in [E2EFeeds.rss(title: "가", posts: posts), E2EFeeds.atom(title: "나", posts: posts)] {
            let e = try FeedParser.parseFeed(Data(xml.utf8))
            #expect(e.count == 1)
            #expect(e[0].id == "a1")
            #expect(e[0].title == "Ocean treaty & summit")
            #expect(e[0].link == "https://news.e2e.example/bbc-world/a1")
            #expect(e[0].image == "https://img.e2e.example/a1.png")
            #expect(e[0].date == Date(timeIntervalSince1970: 1_800_000_000))
        }
    }

    @Test func opmlRoundTrip() throws {
        let on = Resources.config.sources.filter { $0.type == "feed" }.prefix(20)
        let back = try OPML.parse(Data(OPML.export(Array(on), sectionName: Sections.name).utf8))
        #expect(back.map(\.url) == on.map(\.url))
    }
}

// 시나리오 시험에서 찾은 버그를 고친 것(e2e-fix)
@Suite struct E2EFixTests {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("e2efix-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func scrap(_ id: String, _ c: String = "모음") -> Scrap {
        Scrap(id: id, item: NewsItem(id: id, title: "제목 \(id)", titleKo: nil, link: "https://a.com/\(id)", date: Date(), summary: "",
                                     sourceId: "s", sourceName: "s", tier: "kr"), quote: nil, quoteOriginal: nil, memo: "메모", collection: c)
    }

    // 1) 스크랩 사본: 원자적으로 쓰고 그대로 읽힘, DB 에 없는 것만 되살림
    @Test func scrapCopyRoundTripAndRestoreList() {
        let f = tempDir().appendingPathComponent("scraps.json")
        let list = [scrap("a"), scrap("b", "다른 모음")]
        Scrapbook.writeCopy(list, to: f)
        let back = Scrapbook.readCopy(f)
        #expect(back?.map(\.id) == ["a", "b"])
        #expect(back?.map(\.collection) == ["모음", "다른 모음"])
        #expect(Scrapbook.restoreList(db: [scrap("a")], copy: list).map(\.id) == ["b"])
        #expect(Scrapbook.readCopy(tempDir().appendingPathComponent("none.json")) == nil)
    }

    // 1) 깨져서 새로 만든 DB 는 치운 파일의 스크랩을 읽히는 만큼 옮겨 온다
    @Test func salvageScrapsFromOtherFile() {
        let d = tempDir()
        let old = Database(file: d.appendingPathComponent("old.sqlite"))
        old.saveScrap(scrap("x")); old.saveScrap(scrap("y", "폴더"))
        let fresh = Database(file: d.appendingPathComponent("new.sqlite"))
        #expect(fresh.importScraps(from: d.appendingPathComponent("old.sqlite")) == 2)
        #expect(Set(fresh.scraps().map(\.id)) == ["x", "y"])
        #expect(fresh.importScraps(from: d.appendingPathComponent("missing.sqlite")) == 0)
    }

    // 1) 통째로 깨진 파일: 새로 만들었다고 표시(사본에서 되살릴 조건)
    @Test func corruptDBIsMarkedRecreated() throws {
        let d = tempDir()
        let f = d.appendingPathComponent("magazine.sqlite")
        try Data(repeating: 0x5A, count: 8192).write(to: f)
        let db = Database(file: f)
        #expect(db.recreated)
        #expect(db.salvagedScraps == 0)
        #expect(!Database(file: d.appendingPathComponent("ok.sqlite")).recreated)
    }

    // 2) 번역 표시
    @Test func translationLabel() {
        #expect(ArticleService.engineLabel(done: 0, total: 5, engine: "Google 번역") == "")
        #expect(ArticleService.engineLabel(done: 2, total: 5, engine: "Google 번역") == "Google 번역 · 일부 번역")
        #expect(ArticleService.engineLabel(done: 5, total: 5, engine: "Google 번역") == "Google 번역")
    }

    // 4) 출처 분야(정치)와 달리 경제 낱말이 강하게 걸리면 경제 칩을 더하고, 알림 분야는 고른 분야 칩을 먼저 쓴다
    @Test func strongKeywordChip() {
        let it = NewsItem(id: "p1", title: "한국은행 기준금리 인하 결정 가계대출 부담 사흘째", titleKo: nil, link: "https://a.com/p1", date: Date(),
                          summary: "", sourceId: "yna-politics", sourceName: "연합뉴스 정치", tier: "kr")
        let p = Sections.place(it)
        #expect(p.primary == "politics")
        #expect(p.strong == "economy")
        #expect(p.chips.contains("economy"))
        #expect(AppModel.notifySection(it, chosen: ["top", "economy", "world", "ai"]) == "economy")
        #expect(AppModel.notifySection(it, chosen: ["politics", "economy"]) == "politics") // 둘 다 고르면 대표 분야
        // 낱말 하나만 걸리면 강한 칩 아님
        let weak = NewsItem(id: "p2", title: "국회 본회의 일정 합의 금리", titleKo: nil, link: "https://a.com/p2", date: Date(),
                            summary: "", sourceId: "yna-politics", sourceName: "연합뉴스 정치", tier: "kr")
        #expect(Sections.place(weak).strong == nil)
    }
}

// 설정 상호작용(e2e-settings)에서 찾은 것
@Suite struct E2ESettingsTests {
    private func it(_ src: String, _ id: String, _ title: String = "제목") -> NewsItem {
        NewsItem(id: id, title: title, titleKo: nil, link: "https://a.com/\(id)", date: Date(), summary: "", sourceId: src, sourceName: src, tier: "kr")
    }

    // 안 읽음: 출처를 끄면 줄고 다시 켜면 돌아온다(어떤 소식이 들었는지 기억). 예전 파일(기억 없음)은 줄이기만
    @Test func unreadFollowsVisibility() {
        let a = it("x", "1"), b = it("y", "2"), c = it("x", "3")
        let keys = [a.key, b.key, c.key]
        #expect(AppModel.recountUnread(unread: 3, keys: keys, visibleUnread: [b]) == 1)          // x 끔
        #expect(AppModel.recountUnread(unread: 1, keys: keys, visibleUnread: [a, b, c]) == 3)    // 다시 켬
        #expect(AppModel.recountUnread(unread: 2, keys: keys, visibleUnread: [a, b, c, it("z", "9")]) == 3) // 안 읽음에 들지 않은 글은 세지 않음
        #expect(AppModel.recountUnread(unread: 5, keys: [], visibleUnread: [a, b]) == 2)          // 예전 파일
        #expect(AppModel.recountUnread(unread: 1, keys: [], visibleUnread: [a, b]) == 1)
    }

    // 숨김·꺼짐·알리지 않음 낱말은 지우지 않고 거르기만: 풀면 그대로 돌아온다
    @Test func hideAndMuteAreFiltersNotDeletes() {
        let items = [it("x", "1", "지역화폐 소식"), it("y", "2", "다른 소식"), it("z", "3")]
        var f = SourceFilter(hidden: ["y"], active: ["x", "y", "z"])
        #expect(AppModel.visible(items, filter: f, mute: ["지역화폐"]).map(\.id) == ["3"])
        f.hidden = []
        #expect(AppModel.visible(items, filter: f, mute: []).map(\.id) == ["1", "2", "3"])
        #expect(AppModel.visible(items, filter: SourceFilter(active: ["z"]), mute: []).map(\.id) == ["3"])
    }

    // 예전 상태 파일(unreadKeys 없음)도 읽힘
    @Test func oldStateWithoutUnreadKeys() throws {
        let s = try JSONDecoder().decode(AppState.self, from: Data(#"{"unread": 4}"#.utf8))
        #expect(s.unread == 4 && s.unreadKeys.isEmpty)
    }

    // 사진 점수(Vision)를 한꺼번에 많이 불러도 Swift 동시성 공용 스레드가 막히지 않는다(첫 실행 정지 버그)
    @Test func photoScoringDoesNotStarveConcurrency() async throws {
        let n = 64
        let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: n, height: n))
        let cg = ctx.makeImage()!
        let scoring = Task { await withTaskGroup(of: Void.self) { g in for _ in 0..<24 { g.addTask { _ = await PhotoQuality.scoreAsync(cg) } } } }
        // 점수를 재는 동안에도 짧은 잠이 제때 깨어나야 한다
        let t0 = ContinuousClock.now
        try await Task.sleep(for: .milliseconds(50))
        #expect(ContinuousClock.now - t0 < .seconds(5))
        await scoring.value
    }
}
