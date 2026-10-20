import AppKit
import Foundation
import Testing
@testable import Dropcap

// 남은 개선 묶음: 유료 기사 표시·무료 보도 안내 · 회의 중 조용히 · 오늘 호 완독 · 분야별 저녁 정리 · 분야 대표 사진 점수

private func news(_ id: String, source: String, tier: String = "press", link: String? = nil, date: Date = Date(),
                  title: String? = nil, kind: String? = nil) -> NewsItem {
    var it = NewsItem(id: id, title: title ?? "Title \(id)", titleKo: nil, link: link ?? "https://\(source).example/\(id)", date: date,
                      summary: "summary \(id)", sourceId: source, sourceName: source.uppercased(), tier: tier)
    it.kind = kind
    return it
}

private func tempDB() throws -> (Database, URL) {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("dropcap-extras-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return (Database(file: d.appendingPathComponent("magazine.sqlite")), d)
}

// MARK: 1. 유료 기사(G-14 · D-9)
@Suite struct PaywallTests {
    let meta: [String: SourceMeta] = [
        "wsj": SourceMeta(id: "wsj", paywall: "hard"),
        "nyt": SourceMeta(id: "nyt", paywall: "metered"),
        "verge": SourceMeta(id: "verge"),
        "yna": SourceMeta(id: "yna"),
    ]

    @Test func declaredBeatsDomainAndLearning() {
        #expect(Paywall.kind(sourceId: "wsj", link: "https://www.wsj.com/a", meta: meta) == .hard)
        #expect(Paywall.kind(sourceId: "nyt", link: "https://www.nytimes.com/a", meta: meta) == .metered)
        #expect(Paywall.kind(sourceId: "verge", link: "https://www.theverge.com/a", meta: meta) == nil)
    }

    @Test func customSourcesUseKnownDomainsIncludingSubdomains() {
        #expect(Paywall.domainKind("https://www.ft.com/content/1") == .hard)
        #expect(Paywall.domainKind("https://edition.economist.com/x") == .hard)
        #expect(Paywall.domainKind("https://cooking.nytimes.com/r") == .metered)
        #expect(Paywall.domainKind("https://notft.com/x") == nil)
        #expect(Paywall.domainKind("https://ft.com.evil.example/x") == nil)
        #expect(Paywall.kind(sourceId: "custom-1", link: "https://www.bloomberg.com/news/a", meta: meta) == .hard)
    }

    @Test func learnsFromFailureRateOnlyAfterEnoughTries() {
        let few = ["verge": Database.ExtractStat(tries: 4, fails: 4, blocked: 0)]
        #expect(Paywall.kind(sourceId: "verge", link: "https://www.theverge.com/a", meta: meta, stats: few) == nil)
        let many = ["verge": Database.ExtractStat(tries: 10, fails: 4, blocked: 3)]
        #expect(Paywall.kind(sourceId: "verge", link: "https://www.theverge.com/a", meta: meta, stats: many) == .learned)
        let ok = ["verge": Database.ExtractStat(tries: 10, fails: 2, blocked: 1)]
        #expect(Paywall.kind(sourceId: "verge", link: "https://www.theverge.com/a", meta: meta, stats: ok) == nil)
    }

    @Test func teaserWithSubscribePromptLooksBlocked() {
        let teaser = [Block(type: .p, text: "The central bank surprised markets on Tuesday."),
                      Block(type: .p, text: "Subscribe to continue reading this article.")]
        #expect(Paywall.looksBlocked(teaser))
        let kr = [Block(type: .p, text: "기사 첫 문단입니다."), Block(type: .p, text: "이 기사는 유료 회원만 볼 수 있습니다.")]
        #expect(Paywall.looksBlocked(kr))
        // 본문이 충분하면 끝의 구독 권유는 무시
        let long = Array(repeating: Block(type: .p, text: String(repeating: "Full paragraph of the story. ", count: 10)), count: 8)
            + [Block(type: .p, text: "Subscribe to read more stories like this.")]
        #expect(!Paywall.looksBlocked(long))
        #expect(!Paywall.looksBlocked([Block(type: .p, text: "Short but free note.")]))
    }

    @Test func freeAlternativesSkipPaywalledHiddenSelfAndChannels() {
        let me = news("1", source: "wsj")
        let story = [me,
                     news("2", source: "nyt"),                                      // metered — 열리지 않을 수 있어 권하지 않음
                     news("3", source: "verge", date: Date().addingTimeInterval(-60)),
                     news("4", source: "yna", tier: "kr", date: Date().addingTimeInterval(-3600)),
                     news("5", source: "hidden"),
                     news("6", source: "verge"),                                    // 같은 출처 두 번은 한 번만
                     news("7", source: "tube", kind: "video")]
        let alts = Paywall.freeAlternatives(me, story: story, hidden: ["hidden"], meta: meta)
        #expect(alts.map(\.id) == ["4", "6"]) // 국내 먼저, 그다음 언론 최신
    }

    @Test func sourcesJSONMarksKnownPaywalls() {
        let all = Resources.config.sources
        for s in all where s.paywall != nil { #expect(["hard", "metered"].contains(s.paywall!), "\(s.id)") }
        #expect(all.first { $0.id == "wsj-markets" }?.paywall == "hard")
        #expect(all.filter { $0.id.hasPrefix("nyt-") }.allSatisfy { $0.paywall == "hard" }) // 앱은 403 으로 못 읽음
        #expect(all.first { $0.id == "verge" }?.paywall == "metered") // 구독 문·isAccessibleForFree=false
        #expect(Sections.meta["wsj-markets"]?.paywall == "hard")
    }

    @Test func oldCustomSourceWithoutPaywallStillDecodes() throws {
        let old = ##"{"id":"custom-x","name":"X","tier":"press","type":"feed","url":"https://x.example/feed","aiOnly":false,"defaultOn":true,"color":"#000"}"##
        #expect(try JSONDecoder().decode(Source.self, from: Data(old.utf8)).paywall == nil)
    }

    @Test func extractStatsAccumulateAndDecay() throws {
        let (db, dir) = try tempDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        db.recordExtract(source: "a", failed: true, blocked: false)
        db.recordExtract(source: "a", failed: false, blocked: true)
        db.recordExtract(source: "a", failed: false, blocked: false)
        #expect(db.extractStats()["a"] == Database.ExtractStat(tries: 3, fails: 1, blocked: 1))
        for _ in 0..<60 { db.recordExtract(source: "b", failed: true, blocked: false) }
        let b = db.extractStats()["b"]!
        #expect(b.tries <= 50 && b.tries > 20 && b.failRate == 1) // 50번이 넘으면 반으로 줄어 최근 결과가 크게
    }
}

// MARK: 2. 회의·발표 중 자동 조용히(N-25 · D-8)
@Suite struct FocusGuardTests {
    let screen = CGSize(width: 1512, height: 982)

    @Test func fullscreenWindowOfFrontAppCovers() {
        let wins = [FocusGuard.WindowInfo(pid: 10, layer: 0, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982))]
        #expect(FocusGuard.coversScreen(wins, frontPID: 10, screens: [screen], ownPID: 1))
        #expect(!FocusGuard.coversScreen(wins, frontPID: 11, screens: [screen], ownPID: 1)) // 뒤에 있는 앱
        #expect(!FocusGuard.coversScreen(wins, frontPID: 1, screens: [screen], ownPID: 1))  // Dropcap 자신(매거진 전체 화면)
        let zoomed = [FocusGuard.WindowInfo(pid: 10, layer: 0, bounds: CGRect(x: 0, y: 33, width: 1512, height: 949))] // 메뉴 막대 아래까지만
        #expect(!FocusGuard.coversScreen(zoomed, frontPID: 10, screens: [screen], ownPID: 1))
        let overlay = [FocusGuard.WindowInfo(pid: 10, layer: 25, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982))]
        #expect(!FocusGuard.coversScreen(overlay, frontPID: 10, screens: [screen], ownPID: 1)) // 보통 창이 아닌 것(바탕·떠 있는 막)
        let second = [FocusGuard.WindowInfo(pid: 10, layer: 0, bounds: CGRect(x: 1512, y: 0, width: 2560, height: 1440))]
        #expect(FocusGuard.coversScreen(second, frontPID: 10, screens: [screen, CGSize(width: 2560, height: 1440)], ownPID: 1))
    }

    @Test func sharingHelpers() {
        #expect(FocusGuard.sharing(["Finder", "CptHost"]))
        #expect(FocusGuard.sharing(["screencaptureui"]))
        #expect(!FocusGuard.sharing(["zoom.us", "sharingd", "Safari"])) // Zoom 이 켜져 있기만 한 것·공유 데몬은 아님
    }

    @Test func calendarEventsCountOnlyBusyTimedOnes() {
        let now = Date()
        func ev(_ s: Double, _ e: Double, allDay: Bool = false, free: Bool = false, declined: Bool = false) -> FocusGuard.EventInfo {
            .init(start: now.addingTimeInterval(s), end: now.addingTimeInterval(e), allDay: allDay, free: free, declined: declined)
        }
        #expect(FocusGuard.inEvent([ev(-600, 600)], now: now))
        #expect(!FocusGuard.inEvent([ev(-600, 600, allDay: true)], now: now))
        #expect(!FocusGuard.inEvent([ev(-600, 600, free: true)], now: now))
        #expect(!FocusGuard.inEvent([ev(-600, 600, declined: true)], now: now))
        #expect(!FocusGuard.inEvent([ev(-1200, -60), ev(60, 1200)], now: now)) // 끝난 일정·아직 안 시작한 일정
        #expect(!FocusGuard.inEvent([ev(-600, 0)], now: now)) // 끝나는 순간에는 풀림
    }

    @Test func settingsDefaultsForOldFiles() throws {
        let old = try JSONDecoder().decode(AppState.Settings.self, from: Data(#"{"style":"drop","quietEnabled":true}"#.utf8))
        #expect(old.autoQuietFullscreen && old.autoQuietSharing && !old.autoQuietCalendar)
        #expect(old.quietEnabled)
        var s = AppState.Settings()
        s.autoQuietCalendar = true; s.autoQuietSharing = false
        let back = try JSONDecoder().decode(AppState.Settings.self, from: JSONEncoder().encode(s))
        #expect(back.autoQuietCalendar && !back.autoQuietSharing && back.autoQuietFullscreen)
    }

    @Test @MainActor func overrideSilencesLikeQuietHours() {
        let m = FocusMonitor.shared
        m.override = .some(.calendar)
        defer { m.override = nil; m.invalidate() }
        #expect(m.reason(AppState.Settings()) == .calendar)
        m.override = .some(nil)
        #expect(m.reason(AppState.Settings()) == nil)
    }
}

// MARK: 3. 오늘 호 완독(M-23)
@Suite struct TodayIssueTests {
    private func page(_ section: String?, _ ids: [String], kind: String? = nil) -> (section: Dropcap.Issue.Section, items: [NewsItem]) {
        (Dropcap.Issue.Section(category: .other, keys: ids, kind: kind, section: section), ids.map { news($0, source: "s") })
    }

    @Test func representativeKeys() {
        let sections = [page("top", ["t1", "t2", "t3", "t4"]),
                        page("economy", ["e1", "t1", "e2", "e3", "e4"]),
                        page("sports", ["s1", "s2"]),          // 고르지 않은 분야
                        page("ai", ["a1"]),
                        page(nil, ["o1", "o2"]),               // 그 밖의 소식
                        page(nil, ["v1"], kind: "video")]      // 구독 채널
        let keys = TodayIssue.keys(cover: "c", sections: sections, chosen: ["top", "economy", "ai"])
        #expect(keys == ["c", "s|t1", "s|t2", "s|t3", "s|e1", "s|e2", "s|a1"]) // 경제 첫 줄의 t1 은 주요 뉴스와 겹쳐 한 번만
        #expect(TodayIssue.keys(cover: nil, sections: [], chosen: ["ai"]).isEmpty)
    }

    @Test func nextIssueText() {
        #expect(TodayIssue.nextIssueText(digestEnabled: true, digestHour: 9) == "다음 호는 내일 오전 9시 브리핑으로 알려 드릴게요")
        #expect(TodayIssue.nextIssueText(digestEnabled: true, digestHour: 12) == "다음 호는 내일 오후 12시 브리핑으로 알려 드릴게요")
        #expect(TodayIssue.nextIssueText(digestEnabled: false, digestHour: 9) == "다음 호는 내일 아침에 엮여요")
    }

    @Test func doneMarkLastsOnlyThatDay() throws {
        let d = try #require(UserDefaults(suiteName: "dropcap-today-\(UUID().uuidString)"))
        let today = Date()
        #expect(!TodayIssue.isMarkedDone(d, now: today))
        TodayIssue.markDone(d, now: today)
        #expect(TodayIssue.isMarkedDone(d, now: today))
        #expect(!TodayIssue.isMarkedDone(d, now: today.addingTimeInterval(24 * 3600)))
    }
}

// MARK: 4. 분야별 저녁 정리(N-26)
@Suite struct EveningBriefTests {
    @Test func parsesLinesWithEvidence() {
        let text = """
        오늘 경제 소식입니다.
        - 한국은행이 기준금리를 동결했다 [1][3]
        • 코스피가 반도체 강세로 올랐다 [2]
        - 근거 없는 문장은 버린다
        - 범위 밖 번호만 단 줄도 버린다 [9]
        - 환율은 1,380원대에서 움직였다 [4] [4]
        - 네 번째 줄은 잘린다 [1]
        """
        let lines = Summarizer.parseBriefing(text, count: 4)
        #expect(lines?.map(\.text) == ["한국은행이 기준금리를 동결했다", "코스피가 반도체 강세로 올랐다", "환율은 1,380원대에서 움직였다"])
        #expect(lines?.map(\.refs) == [[0, 2], [1], [3]])
        #expect(Summarizer.parseBriefing("- 근거가 없다\n- 역시 없다", count: 3) == nil)
    }

    @Test func promptCarriesOriginalTitlesAndSources() {
        var a = news("1", source: "yna", title: "Fed holds rates")
        a.titleKo = "연준 금리 동결"
        let p = Summarizer.briefingPrompt(section: "경제", items: [a, news("2", source: "cnbc", title: "Stocks rally")])
        #expect(p.contains("[1] Fed holds rates (연준 금리 동결) — YNA"))
        #expect(p.contains("[2] Stocks rally — CNBC"))
        #expect(p.hasPrefix("분야: 경제"))
    }

    @Test func briefSurvivesStateRoundTripAndOldStateHasNone() throws {
        var s = AppState()
        s.briefs["economy"] = SectionBrief(section: "economy", at: Date(timeIntervalSince1970: 1_800_000_000),
                                           items: [news("1", source: "yna", date: Date(timeIntervalSince1970: 1_800_000_000))], lines: [.init(text: "금리 동결", refs: [0])])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(AppState.self, from: enc.encode(s))
        #expect(back.briefs == s.briefs)
        #expect(try dec.decode(AppState.self, from: Data("{}".utf8)).briefs.isEmpty)
    }
}

// MARK: 5. 분야 대표 사진 점수(M-24)
@Suite struct PhotoQualityTests {
    private func render(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx)
        return ctx.makeImage()!
    }

    // 사진 같은 그림: 부드러운 색 변화 + 잡음
    private var photo: CGImage {
        render(960, 540) { ctx in
            var g = SystemRandomNumberGenerator()
            for y in stride(from: 0, to: 540, by: 6) {
                for x in stride(from: 0, to: 960, by: 6) {
                    let n = Double.random(in: -0.12...0.12, using: &g)
                    ctx.setFillColor(red: 0.2 + 0.6 * Double(x) / 960 + n, green: 0.35 + 0.4 * sin(Double(y) / 80) + n, blue: 0.5 + 0.3 * cos(Double(x + y) / 120) + n, alpha: 1)
                    ctx.fill(CGRect(x: x, y: y, width: 6, height: 6))
                }
            }
        }
    }
    // 웹사이트 화면 캡처: 흰 바탕에 글자 줄이 빽빽
    private var screenshot: CGImage {
        render(1280, 800) { ctx in
            ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: 1280, height: 800))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30, weight: .medium), .foregroundColor: NSColor.black]
            for i in 0..<16 {
                ("ニュース速報 Breaking news headline number \(i) 経済 政治 国際" as NSString).draw(at: NSPoint(x: 40, y: 760 - i * 48), withAttributes: attrs)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }
    // 로고: 흰 바탕에 색 원 하나
    private var logo: CGImage {
        render(600, 600) { ctx in
            ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 600))
            ctx.setFillColor(red: 0.9, green: 0.1, blue: 0.2, alpha: 1); ctx.fillEllipse(in: CGRect(x: 150, y: 150, width: 300, height: 300))
        }
    }

    @Test func shapeAndSizeScores() {
        #expect(PhotoQuality.aspectScore(width: 1600, height: 900) == 1)
        #expect(PhotoQuality.aspectScore(width: 600, height: 600) < 0.75)
        #expect(PhotoQuality.aspectScore(width: 400, height: 800) == 0)
        #expect(PhotoQuality.aspectScore(width: 2000, height: 300) < 0.2)
        #expect(PhotoQuality.sizeScore(width: 1200, height: 675) == 1)
        #expect(PhotoQuality.sizeScore(width: 120, height: 80) == 0)
        #expect(PhotoQuality.textScore(0.02) == 1 && PhotoQuality.textScore(0.2) == 0)
    }

    @Test func gatesKeepGraphicsAndScreenshotsOut() {
        let good = PhotoQuality.combine(aspect: 1, size: 1, textRatio: 0, colorVariety: 1, flatness: 0.21) // 밤하늘 사진
        #expect(PhotoQuality.good(good.total))
        #expect(!PhotoQuality.good(PhotoQuality.combine(aspect: 1, size: 1, textRatio: 0.24, colorVariety: 1).total))          // 큰 글자 그림
        #expect(!PhotoQuality.good(PhotoQuality.combine(aspect: 1, size: 1, textRatio: 0, colorVariety: 1, flatness: 0.4).total)) // 그래픽·여백
        #expect(!PhotoQuality.good(PhotoQuality.combine(aspect: 1, size: 1, textRatio: 0.07, colorVariety: 0.63, flatness: 0.3).total)) // 앱 화면 캡처(실측)
    }

    @Test func photoPassesScreenshotAndLogoFail() {
        let p = PhotoQuality.score(photo), s = PhotoQuality.score(screenshot), l = PhotoQuality.score(logo)
        #expect(PhotoQuality.good(p.total), "사진 \(p)")
        #expect(!PhotoQuality.good(s.total), "화면 캡처 \(s)")
        #expect(s.textRatio > 0.05 && s.flatness > 0.25, "글자 면적 \(s.textRatio) · 단색 \(s.flatness)") // 단색 바탕 + 글자 = 화면 캡처
        #expect(!PhotoQuality.good(l.total), "로고 \(l)")
        #expect(p.colorVariety > l.colorVariety && p.colorVariety > s.colorVariety)
    }

    @Test func coverSkipsBadPhotosButKeepsUnmeasured() {
        var a = news("a", source: "x"); a.image = "https://img.example/a.jpg"
        var b = news("b", source: "x"); b.image = "https://img.example/b.jpg"
        let c = news("c", source: "x")
        #expect(Editor.pickCover([a, b, c], scores: [:]) == a.key)                              // 아직 재지 않음 → 그대로
        #expect(Editor.pickCover([a, b, c], scores: [a.image!: 0.2]) == b.key)                  // 화면 캡처는 건너뜀
        #expect(Editor.pickCover([a, b, c], scores: [a.image!: 0.2, b.image!: 0.3]) == c.key)   // 좋은 사진이 없으면 사진 없는 기사
        #expect(Editor.pickCover([a, b], scores: [a.image!: 0.2, b.image!: 0.3]) == nil)        // 그것도 없으면 부르는 쪽이 1등을 쓴다
    }

    @Test @MainActor func sectionPhotoPrefersMeasuredGood() {
        var a = news("a", source: "x"); a.image = "https://img.example/a.jpg"
        var b = news("b", source: "x"); b.image = "https://img.example/b.jpg"
        #expect(SectionPhoto.best([a, b], scores: [a.image!: 0.3, b.image!: 0.9])?.key == b.key)
        #expect(SectionPhoto.best([a, b], scores: [a.image!: 0.3])?.key == b.key)
        #expect(SectionPhoto.best([a, b], scores: [:])?.key == a.key)
        #expect(SectionPhoto.best([a, b], scores: [a.image!: 0.1, b.image!: 0.2]) == nil)
    }

    @Test func scoresPersist() throws {
        let (db, dir) = try tempDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        db.saveImageScore("https://img.example/a.jpg", PhotoQuality.combine(aspect: 1, size: 1, textRatio: 0.3, colorVariety: 0.2))
        let got = db.imageScores(["https://img.example/a.jpg", "https://img.example/none.jpg"])
        #expect(got.count == 1)
        #expect(!PhotoQuality.good(got["https://img.example/a.jpg"]))
    }
}
