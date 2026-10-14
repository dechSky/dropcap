import AppKit
import SwiftUI

// 시나리오 단계. 기대값은 docs/research/COMPETITIVE.md (다)-3 의 알림 정책(NotifyPolicy)과 지시서의 단계 설명을 따른다.
@MainActor
enum E2EPhases {
    typealias S = E2EStories
    static let chosen = ["top", "economy", "world", "ai"]

    // MARK: - main: 1~11, 12 준비
    static func main(_ r: E2ERun) async {
        let m = r.model
        // 자동 확인 간격을 길게(시나리오가 확인 시점을 정한다). 아침 브리핑은 이 시나리오 밖이라 끈다.
        m.update { $0.intervalMinutes = 600; $0.digestEnabled = false }
        r.note("설정: 확인 간격 600분, 아침 브리핑 끔(시나리오가 확인 시점을 정함)")

        // 1) 첫 실행 → 분야 고르기
        let isOnboard: (NSWindow) -> Bool = { $0.title == "관심 분야 고르기" }
        let shown = await r.until(15) { NSApp.windows.contains { $0.isVisible && isOnboard($0) } }
        let need = Sections.pickable.filter { !$0.isMore }.count
        let filled = await r.until(45) { SectionPhotos.shared.images.count >= need }
        await r.sleep(1)
        let p1 = r.shotPath("01-onboarding")
        OnboardingController.snapshot(to: p1)
        r.record("1", "첫 실행 → 분야 고르기 화면(유리 카드, 사진 채워짐)",
                 expected: "고르기 창이 뜨고 분야 카드 \(need)개에 사진이 채워짐 · 아직 분야 없음",
                 actual: "창 \(shown ? "뜸" : "안 뜸") · 사진 \(SectionPhotos.shared.images.count)/\(Sections.all.count)개 · needsOnboarding=\(m.needsOnboarding)",
                 pass: shown && filled && m.needsOnboarding, shots: ["shots/" + (p1 as NSString).lastPathComponent])

        // 2) 분야 고르기(주요 + 경제·국제·AI)
        var mark = r.toastMark
        m.chooseSections(["ai", "world", "economy", "top"]) // 고른 순서와 상관없이 분야 순서로 정렬되는지도 본다
        OnboardingController.close()
        let pol = Dictionary(uniqueKeysWithValues: chosen.map { ($0, m.policy($0).mode) })
        let wantPol: [String: NotifyMode] = ["top": .instant, "economy": .instant, "world": .instant, "ai": .bundle]
        var wrongOn: [String] = [], wrongOff: [String] = []
        for (id, meta) in Sections.meta {
            guard let sec = meta.section else { continue }
            let on = m.state.enabled[id] == true
            if chosen.contains(sec), meta.defaultOn == true, !on { wrongOff.append(id) }
            if !chosen.contains(sec), on { wrongOn.append(id) }
        }
        // 고른 분야 출처로 매거진 첫 호를 채울 때까지(첫 실행 직후의 빈 채우기와 구별하려고 기사 수로 본다)
        let backfilled = await r.until(60) { !Magazine.shared.preparing && Database.shared.itemCount > 0 }
        r.record("2", "분야 고르기 → 기본 출처 켜짐 · 알림 모드 기본값",
                 expected: "고른 분야 = 주요·경제·국제·AI(분야 순) · 경제·국제 즉시, AI 묶음, 주요 즉시 · 고른 분야 기본 출처만 켜짐 · 매거진 첫 호 채움",
                 actual: "고른 분야 \(m.chosenSections) · 모드 \(chosen.map { "\($0)=\(pol[$0]!.rawValue)" }.joined(separator: ",")) · 꺼져야 할데 켜짐 \(wrongOn.sorted()) · 켜져야 할데 꺼짐 \(wrongOff.sorted()) · 매거진 첫 호 \(backfilled ? "채움" : "안 됨")(\(Database.shared.itemCount)건)",
                 pass: m.chosenSections == chosen && pol == wantPol && wrongOn.isEmpty && wrongOff.isEmpty && backfilled)
        // 국내 8곳 이상 이야기를 만들려고 고르지 않은 분야의 국내 출처 3곳을 더 켠다(사용자가 설정에서 켜는 것과 같음)
        for id in S.extraKr { m.setEnabled(id, true) }
        r.note("국내 출처 3곳 더 켬: \(S.extraKr)")

        // 3) 첫 확인 → 기존 글은 알리지 않고 기억만(C-08)
        await r.check()
        await r.until(30) { !m.checking }
        let enabled = m.allSources.filter { m.state.enabled[$0.id] == true }.map(\.id)
        let unseeded = enabled.filter { !m.state.seeded.contains($0) }
        var news = r.newsToasts(since: mark)
        r.record("3", "첫 확인 → 기존 글은 알리지 않고 기억만(C-08)",
                 expected: "물방울 0 · 최근 목록 0 · 안 읽음 0 · 켜진 출처 모두 '기억함(seeded)'",
                 actual: "물방울 \(news.count) · 최근 \(m.state.recent.count) · 안 읽음 \(m.state.unread) · 기억 안 한 출처 \(unseeded) · 본 글 \(m.state.seen.count)건",
                 pass: news.isEmpty && m.state.recent.isEmpty && m.state.unread == 0 && unseeded.isEmpty)

        // 4) 새 글 도착
        r.setClock(r.at(10, 5), "새 글 도착")
        let now4 = Date()
        for s in [S.s1, S.s2, S.s3, S.s4] { r.publish(s, at: now4) }
        mark = r.toastMark
        await r.check()
        news = r.newsToasts(since: mark)
        let shot4 = await r.toastShot("04-drops")
        let c1 = await r.coverage(S.s1), c2 = await r.coverage(S.s2), c3 = await r.coverage(S.s3)
        let s2InMag = !Database.shared.items(keys: [r.key("yna-market", "s2-yna-market")]).isEmpty
        let ok4 = r.dropped(S.s1, in: news) && r.dropped(S.s3, in: news) && !r.dropped(S.s2, in: news) && !r.dropped(S.s4, in: news)
            && r.pending(S.s2) == nil && s2InMag && r.pending(S.s4) == Sections.ai
        r.record("4", "새 글 도착 → 즉시 분야는 문턱 넘은 소식만 물방울, 못 넘은 건 매거진만 / 묶음 분야는 고임",
                 expected: "s1(경제·국내 3곳) 물방울 · s3(국제·해외 2곳) 물방울 · s2(국내 2곳) 매거진만(고이지 않음) · s4(AI 1곳, 묶음) 고임",
                 actual: "물방울 \(news.map(\.id)) · 보도 수 s1=\(fmt(c1)) s2=\(fmt(c2)) s3=\(fmt(c3)) · s2 매거진 \(s2InMag) 고임 \(r.pending(S.s2) ?? "-") · s4 고임 \(r.pending(S.s4) ?? "-") · 안 읽음 \(m.state.unread)",
                 pass: ok4, shots: [shot4])

        // 5) 하루 상한
        r.setClock(r.at(10, 30), "하루 상한")
        let now5 = Date()
        for (i, s) in S.caps.enumerated() { r.publish(s, at: now5, offsetMinutes: Double(i)) }
        r.publish(S.big, at: now5, offsetMinutes: 30) // 가장 오래된 것: 상한이 다 찬 뒤에 판단됨
        mark = r.toastMark
        let log0 = m.state.notifyLog.count
        await r.check()
        news = r.newsToasts(since: mark)
        let newLog = m.state.notifyLog.dropFirst(log0).map(\.section)
        let cb = await r.coverage(S.big)
        let flags = S.caps.map { s in "\(s.id)=\(r.notified(s) ? "알림" : (r.pending(s).map { "고임(\($0))" } ?? "조용"))" }
        let shot5 = await r.toastShot("05-caps")
        let wantCaps = [true, true, true, true, true, false]
        let ok5 = zip(S.caps, wantCaps).allSatisfy { r.notified($0) == $1 } && r.pending(S.caps[5]) == "economy"
            && r.notified(S.big) && (cb?.kr ?? 0) >= 8
            && newLog.filter { $0 == "economy" }.count == 3 && newLog.filter { $0 == "top" }.count == 3
        r.record("5", "하루 상한 넘김 → 고임, 국내 8곳 이상은 상한 무시",
                 expected: "경제 하루 3건(s1 포함) → e1·e2 경제로, e3~e5 는 주요 뉴스 흐름(상한 3)으로, e6 은 고임(경제) · b8(국내 8곳) 은 상한을 넘어 알림",
                 actual: "\(flags.joined(separator: " ")) · b8=\(r.notified(S.big) ? "알림" : "안 알림") 보도 \(fmt(cb)) · 이번 기록 분야 \(newLog) · 물방울 카드 \(news.count)장(+더 보기 \(r.toasts(since: mark).filter { if case .more = $0 { return true }; return false }.count))",
                 pass: ok5, shots: [shot5])

        // 6) 묶음 시각 지남
        r.setClock(r.at(18, 1), "묶음 시각(18시) 지남")
        mark = r.toastMark
        let gotBundle = await r.until(80) { r.toasts(since: mark).contains { if case .bundle = $0 { return true }; return false } }
        await r.sleep(3)
        let bundles = r.toasts(since: mark).compactMap { k -> (String, [NewsItem])? in if case .bundle(let s, let i) = k { return (s, i) }; return nil }
        let shot6 = await r.toastShot("06-bundle")
        let econ = bundles.first { $0.0 == "economy" }
        r.record("6", "묶음 시각 지남 → \"경제 N건\" 한 방울(제목 2줄)",
                 expected: "경제 묶음 1방울(e6 포함) · AI 묶음 1방울(s4) · 고인 소식 비움 · (제목 2줄은 스냅샷으로 확인)",
                 actual: gotBundle ? bundles.map { "\(Sections.name($0.0)) \($0.1.count)건[\($0.1.map(\.id).joined(separator: ","))]" }.joined(separator: " · ") + " · 남은 고임 \(m.state.pending.count)" : "1분 넘게 기다려도 묶음 없음",
                 pass: r.clock.working ? (econ.map { $0.1.contains { $0.id.hasPrefix("e6-") } } ?? false) && bundles.contains { $0.0 == "ai" } && m.state.pending.isEmpty : nil,
                 shots: [shot6])

        // 7) 같은 이야기 재보도 → 다시 알리지 않음(36시간) · 팔로우한 스토리는 새 보도 알림
        r.setClock(r.at(20, 0), "재보도")
        r.publish(S.s1again, at: Date())
        mark = r.toastMark
        let logBefore = m.state.notifyLog.count
        await r.check()
        news = r.newsToasts(since: mark)
        let sameStory = r.storyOf(S.s1again) == r.storyOf(S.s1)
        r.record("7-가", "같은 이야기 재보도(10시간 뒤) → 다시 알리지 않음",
                 expected: "s1 을 다른 곳(yna-world)이 다시 보도 → 같은 스토리로 묶이고 물방울 없음",
                 actual: "같은 스토리 \(sameStory) · 물방울 \(news.map(\.id)) · 알림 기록 +\(m.state.notifyLog.count - logBefore)",
                 pass: sameStory && !r.dropped(S.s1again, in: news) && m.state.notifyLog.count == logBefore)

        if let st = r.storyOf(S.s2), let c = Database.shared.cluster(st) {
            m.setFollowing(st, true, size: c.size)
            r.note("s2 스토리 팔로우: \(st) (보도 \(c.size))")
        }
        r.publish(S.s2follow, at: Date())
        mark = r.toastMark
        await r.check()
        let infos = r.toasts(since: mark).compactMap { k -> String? in if case .info(let a, let b) = k { return a + " / " + b }; return nil }
        news = r.newsToasts(since: mark)
        let shot7 = await r.toastShot("07-follow")
        let grownToast = infos.contains { $0.contains("팔로우한 스토리에 새 보도") }
        r.record("7-나", "팔로우한 스토리 → 새 보도 알림",
                 expected: "s2(매거진만이던 스토리)를 팔로우 → sbs-top 이 새로 보도하면 '팔로우한 스토리에 새 보도' 한 번",
                 actual: "안내 \(infos) · 소식 물방울 \(news.map(\.id)) · s2 고임 \(r.pending(S.s2) ?? "-")",
                 pass: grownToast, shots: [shot7])
        if grownToast && r.dropped(S.s2follow, in: news) {
            r.note("※ 팔로우 새 보도가 안내와 소식 물방울로 두 번 떨어짐")
        }

        r.setClock(r.at(day: 1, 22, 30), "36시간 뒤")
        r.publish(S.s1late, at: Date())
        mark = r.toastMark
        await r.check()
        news = r.newsToasts(since: mark)
        r.record("7-다", "36시간이 지난 같은 이야기",
                 expected: "s1 첫 알림(10:05)에서 36시간 넘게 지남 → 같은 이야기여도 다시 알릴 수 있음(설계: 36시간 기억)",
                 actual: "물방울 \(news.map(\.id)) · s1 알림 기록 \(r.notified(S.s1))",
                 pass: r.clock.working ? r.dropped(S.s1late, in: news) : nil)
        await r.sleep(2)

        // 8) 방해 금지·잠시 끄기
        r.setClock(r.at(day: 1, 22, 35), "방해 금지")
        m.update { $0.quietEnabled = true; $0.quietStart = 22; $0.quietEnd = 23 }
        var unread0 = m.state.unread
        r.publish(S.q1, at: Date())
        mark = r.toastMark
        await r.check()
        news = r.newsToasts(since: mark)
        r.record("8-가", "방해 금지 시간 → 알림 없이 안 읽음에만",
                 expected: "q1(해외 2곳·국제 즉시) 물방울 없음 · 안 읽음 +1 · 고였다가 나중에 묶음으로",
                 actual: "방해 금지 중 \(m.isQuietTime) · 물방울 \(news.map(\.id)) · 안 읽음 \(unread0)→\(m.state.unread) · q1 고임 \(r.pending(S.q1) ?? "-")",
                 pass: m.isQuietTime && news.isEmpty && m.state.unread == unread0 + 1 && r.pending(S.q1) == "world")
        m.update { $0.quietEnabled = false }
        m.snooze(Date().addingTimeInterval(3600))
        unread0 = m.state.unread
        r.publish(S.q2, at: Date())
        mark = r.toastMark
        await r.check()
        news = r.newsToasts(since: mark)
        r.record("8-나", "잠시 끄기(1시간) → 알림 없이 안 읽음에만",
                 expected: "q2 물방울 없음 · 안 읽음 +1 · 고임",
                 actual: "잠시 끔 \(m.isSnoozed) · 물방울 \(news.map(\.id)) · 안 읽음 \(unread0)→\(m.state.unread) · q2 고임 \(r.pending(S.q2) ?? "-")",
                 pass: m.isSnoozed && news.isEmpty && m.state.unread == unread0 + 1 && r.pending(S.q2) == "world")
        m.snooze(nil)
        mark = r.toastMark
        let after8 = await r.until(80) { r.toasts(since: mark).contains { if case .bundle("world", _) = $0 { return true }; return false } }
        await r.sleep(2)
        let shot8 = await r.toastShot("08-after-quiet")
        r.record("8-다", "잠시 끄기를 풀면 고인 소식이 묶음으로",
                 expected: "다음 1분 점검에서 '국제 2건'(q1·q2) 묶음 한 방울",
                 actual: r.toasts(since: mark).map(E2ERun.describe).joined(separator: " · ").nonEmpty ?? "없음",
                 pass: after8, shots: [shot8])

        // 9) 화면 스냅샷
        await screens(r)

        // 10) 스크랩·저장·주소로 추가·OPML
        await keep(r)

        // 11) 줄이기
        await reduce(r)

        // 13~22) 설정과의 상호작용
        await E2ESettings.run(r)

        // 12 준비: 다시 시작해 비교할 값
        writeFacts(r, "facts-before.json")
        r.note("12 준비: 상태를 적고 끝냄(run.sh 가 다시 띄움)")
    }

    // MARK: 9
    static func screens(_ r: E2ERun) async {
        let m = r.model
        // 상단바 목록: 사진을 미리 받아 둠(화면 없이 그릴 때는 .task 가 돌지 않음)
        for it in m.state.recent {
            if let u = [it.image, Magazine.shared.storedImage(it.key)].compactMap({ $0 }).first(where: { !ImageKey.isJunk($0) }) {
                if let img = await ImageLoader.shared.image(u) { RowThumb.preloaded[it.key] = img }
            }
        }
        let d = UserDefaults.standard
        let oldSort = d.string(forKey: "listSort"), oldStyle = d.string(forKey: "listStyle2")
        d.set("hero", forKey: "listStyle2")
        var shots: [String] = []
        for sort in ["newest", "important", "source"] {
            d.set(sort, forKey: "listSort")
            await r.sleep(0.5)
            shots.append(r.render(MenuView(snapshot: true).environment(\.colorScheme, .dark).background(Color(white: 0.16)), "09-menu-\(sort)"))
        }
        d.set(oldSort, forKey: "listSort"); d.set(oldStyle, forKey: "listStyle2")
        let withImg = m.state.recent.filter { RowThumb.preloaded[$0.key] != nil }.count
        r.record("9-가", "상단바 목록(첫 소식 크게·썸네일·분야 칩·정렬 3종)",
                 expected: "최신순·중요순·출처별 세 장 · 첫 소식 크게 · 줄마다 썸네일·분야 칩(눈으로 확인)",
                 actual: "목록 \(m.state.recent.count)건 · 사진 있는 줄 \(withImg) · 그림 \(shots.filter { $0.hasPrefix("shots/") }.count)장",
                 pass: nil, shots: shots)
        let late = m.state.recent.first { $0.id == "s1-yna-politics" }
        r.record("9-라", "분야 칩: 출처 분야와 다른 분야 낱말이 강하면 칩을 하나 더",
                 expected: "정치 출처가 보도한 '한국은행 기준금리…'(s1) → 대표 '정치' + 덧붙인 '경제' 칩 · 알림 분야는 고른 분야인 경제",
                 actual: late.map { "대표 \($0.section) · 덧붙임 \($0.extraTopic ?? "-") · 칩 \($0.sectionChips) · 알림 분야 \(m.notifySection($0))" } ?? "목록에 없음",
                 pass: late.map { $0.extraTopic == "economy" && m.notifySection($0) == "economy" } ?? false, shots: [shots.first ?? ""])

        // 매거진: 오늘 · 경제 분야 · 스토리
        MagazineController.open()
        await r.sleep(8)
        var mshots = [r.windowShot({ $0.title == "Dropcap" }, "09-mag-today")]
        MagazineController.open(page: .section("economy"))
        await r.sleep(4)
        mshots.append(r.windowShot({ $0.title == "Dropcap" }, "09-mag-economy"))
        if let st = r.storyOf(E2EStories.big) {
            MagazineController.open(page: .story(st))
            await r.sleep(4)
            mshots.append(r.windowShot({ $0.title == "Dropcap" }, "09-mag-story-b8"))
        }
        if let st = r.storyOf(E2EStories.s3) {
            MagazineController.open(page: .story(st))
            await r.sleep(4)
            mshots.append(r.windowShot({ $0.title == "Dropcap" }, "09-mag-story-s3"))
        }
        let today = await Magazine.shared.today()
        let split = r.storyOf(E2EStories.big).map { Magazine.splitByRegion(Magazine.shared.storyItems($0)) }
        r.record("9-나", "매거진(분야 유리 띠·스토리·해외/국내 나란히)",
                 expected: "오늘 호에 고른 분야 지면 · 경제 분야 머리 유리 띠 · b8 스토리 보도 목록 · (해외/국내 나란히는 두 지역이 섞인 스토리가 있어야 보임)",
                 actual: "오늘 호 분야 \(today.sections.count)개(\(today.sections.prefix(6).map { "\($0.items.count)" }.joined(separator: "/"))) · b8 스토리 국내 \(split?.kr.count ?? 0)·해외 \(split?.intl.count ?? 0)",
                 pass: nil, shots: mshots)
        NSApp.windows.first { $0.title == "Dropcap" }?.close()

        // 읽기 창: 해외(번역) · 국내
        var rshots: [String] = []
        for (src, id) in [("bbc-world", "s3-bbc-world"), ("yna-market", "s1-yna-market")] {
            guard let it = Database.shared.items(keys: [r.key(src, id)]).first?.item else { continue }
            ReaderController.open(it)
            await r.sleep(12)
            rshots.append(r.windowShot({ $0.title == it.sourceName }, "09-reader-\(src)"))
            NSApp.windows.first { $0.isVisible && $0.title == it.sourceName }?.close()
        }
        var label = "-", labelOK = false
        if let it = Database.shared.items(keys: [r.key("bbc-world", "s3-bbc-world")]).first?.item {
            let a = await ArticleService.shared.prepare(it)
            let changed = a.blocks.contains { $0.original != nil }
            label = "번역됨 \(a.translated) · 바뀐 문단 \(changed) · 표시 '\(a.engine)'"
            labelOK = a.translated == changed && (a.translated ? !a.engine.isEmpty : a.engine.isEmpty) // 번역이 안 됐으면 엔진 표시 없음
        }
        r.record("9-마", "번역 표시: 번역된 문단이 없으면 표시 없음",
                 expected: "시험 모드는 Google 이 막혀 번역 실패 → translated=false · 엔진 표시 없음(기기 내 번역이 되면 그 엔진 표시)",
                 actual: label, pass: labelOK)
        r.record("9-다", "읽기 창(번역·바이라인·사진·모양)",
                 expected: "견본 기사 본문·바이라인·사진이 보임 · 해외 기사는 번역(기기 내 번역이 있으면) · 모양 메뉴는 눈으로",
                 actual: "읽기 창 \(rshots.filter { $0.hasPrefix("shots/") }.count)장",
                 pass: nil, shots: rshots)
    }

    // MARK: 10
    static func keep(_ r: E2ERun) async {
        let m = r.model
        guard let it = Database.shared.items(keys: [r.key("yna-market", "e1-yna-market")]).first?.item else {
            r.record("10-가", "스크랩·저장", expected: "-", actual: "견본 기사 없음", pass: false); return
        }
        Scrapbook.shared.add(it, quote: it.displayTitle + " — 인용 예시", original: it.title, memo: "E2E 메모", to: "E2E")
        Scrapbook.shared.add(it, to: "E2E")
        if !m.isSaved(it) { m.toggleSaved(it) }
        let scraps = Scrapbook.shared.scraps.filter { $0.item.key == it.key }
        r.record("10-가", "스크랩·나중에 읽기 저장",
                 expected: "E2E 모음에 스크랩 2개(인용·기사) · 나중에 읽기에 1건",
                 actual: "스크랩 \(scraps.count)개 · 저장 \(m.isSaved(it))",
                 pass: scraps.count >= 2 && m.isSaved(it))

        // dropcap://save → 확인 창 → '저장'
        let link = "https://news.\(E2EFeeds.host)/saved/page-1"
        let u = URL(string: "dropcap://save?url=\(link.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)&title=E2E%20saved")!
        var alertShot = "(확인 창 없음)", alertText = ""
        let t = Timer(timeInterval: 1.5, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard let w = NSApp.modalWindow else { return }
                alertText = w.contentView.map(allText)?.joined(separator: " | ") ?? ""
                if let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    let p = r.shotPath("10-save-confirm")
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: p))
                    alertShot = "shots/" + (p as NSString).lastPathComponent
                }
                NSApp.stopModal(withCode: .alertFirstButtonReturn) // '저장'
            }
        }
        RunLoop.main.add(t, forMode: .common)
        let mark = r.toastMark
        URLRouter.handle(u)
        let saved = await r.until(15) { m.state.saved.contains { $0.link == link } }
        await r.sleep(1)
        let infos = r.toasts(since: mark).map(E2ERun.describe)
        r.record("10-나", "주소로 추가(dropcap://save → 확인 창 → 저장)",
                 expected: "'나중에 읽기에 저장할까요?' 확인 창 → 저장 → 나중에 읽기에 들어가고 안내 물방울",
                 actual: "확인 창 글: \(alertText.prefix(160)) · 저장됨 \(saved) · \(infos)",
                 pass: alertText.contains("저장할까요") && saved, shots: [alertShot])

        // OPML 내보내기 → 다시 읽기(왕복) → 새 피드 2곳을 더해 가져오기
        let on = m.allSources.filter { m.state.enabled[$0.id] == true && $0.type == "feed" }
        let xml = OPML.export(on, sectionName: Sections.name)
        let ex = r.out.appendingPathComponent("export.opml")
        try? xml.write(to: ex, atomically: true, encoding: .utf8)
        let back = (try? OPML.parse(Data(contentsOf: ex))) ?? []
        let roundTrip = Set(back.map(\.url)) == Set(on.map(\.url)) && back.count == on.count
        E2EFeeds.addCustomFeed("e2e-a", title: "견본 피드 가", now: Date())
        E2EFeeds.addCustomFeed("e2e-b", title: "견본 피드 나", now: Date())
        let extra = """
            <outline text="E2E"><outline type="rss" text="견본 피드 가" xmlUrl="\(E2EFeeds.customURL("e2e-a"))"/>
            <outline type="rss" text="견본 피드 나" xmlUrl="\(E2EFeeds.customURL("e2e-b"))"/></outline>
          </body>
        """
        let imp = r.out.appendingPathComponent("import.opml")
        try? xml.replacingOccurrences(of: "  </body>", with: extra).write(to: imp, atomically: true, encoding: .utf8)
        let importer = OPMLImporter()
        await importer.run(imp)
        let customs = m.state.customSources.filter { $0.url.contains(E2EFeeds.host) }
        r.record("10-다", "OPML 내보내기·가져오기 왕복",
                 expected: "내보낸 \(on.count)곳이 그대로 다시 읽힘 · 가져오기: 새 2곳 추가, 나머지 \(on.count)곳은 이미 있음, 실패 0",
                 actual: "왕복 \(roundTrip)(\(back.count)곳) · \(importer.summary ?? "-") · 실패 \(importer.failed.map { "\($0.title): \($0.reason)" })",
                 pass: roundTrip && importer.added == 2 && importer.skipped == on.count && importer.failed.isEmpty && customs.count == 2)
    }

    // MARK: 11
    static func reduce(_ r: E2ERun) async {
        let m = r.model
        r.setClock(r.at(day: 1, 22, 45), "줄이기")
        // 출처 숨기기
        m.hideSource("hk-finance")
        r.publish(E2EStories.hidden, at: Date())
        var mark = r.toastMark
        await r.check()
        var news = r.newsToasts(since: mark)
        let ch = await r.coverage(E2EStories.hidden.with(sources: ["yna-market"]))
        r.record("11-가", "출처 숨기기 → 다음 알림부터 반영",
                 expected: "hk-finance 숨김 → h1 은 국내 2곳(문턱 못 넘음)으로 세어져 물방울 없음 · 목록에 hk-finance 글 없음",
                 actual: "물방울 \(news.map(\.id)) · h1 보도 \(fmt(ch)) · 목록의 hk-finance \(m.state.recent.filter { $0.sourceId == "hk-finance" }.count)건",
                 pass: !r.dropped(E2EStories.hidden, in: news) && m.state.recent.allSatisfy { $0.sourceId != "hk-finance" })

        // 이 분야 덜 받기(결정: 주요 뉴스 흐름으로도 떨어뜨리지 않고 묶음으로)
        mark = r.toastMark
        m.lessOf("world")
        let lessInfo = r.toasts(since: mark).compactMap { k -> String? in if case .info(let a, _) = k { return a }; return nil }
        r.publish(E2EStories.less, at: Date())
        mark = r.toastMark
        let log0 = m.state.notifyLog.count
        await r.check()
        news = r.newsToasts(since: mark)
        let newLog = m.state.notifyLog.dropFirst(log0).map(\.section)
        r.record("11-나", "이 분야 덜 받기 → 다음 알림부터 반영",
                 expected: "누르면 '이 분야는 저녁 묶음으로 모아 드릴게요' 안내 · 국제: 즉시 → 묶음(덜 받기) · w2(해외 2곳)는 주요 뉴스로도 떨어지지 않고 국제 묶음으로 고임",
                 actual: "안내 \(lessInfo) · 국제 모드 \(m.policy("world").mode.rawValue) 덜 받기 \(m.policy("world").less) · 물방울 \(news.map(\.id)) · 이번 기록 분야 \(newLog) · w2 고임 \(r.pending(E2EStories.less) ?? "-")",
                 pass: lessInfo.contains { $0.contains("저녁 묶음") } && m.policy("world").mode == .bundle && m.policy("world").less
                    && !r.dropped(E2EStories.less, in: news) && newLog.isEmpty && r.pending(E2EStories.less) == "world")

        // 낱말 알리지 않기
        m.muteWord("희토류")
        r.publish(E2EStories.muted, at: Date())
        r.publish(E2EStories.control, at: Date(), offsetMinutes: 1)
        mark = r.toastMark
        await r.check()
        news = r.newsToasts(since: mark)
        let mutedSeen = m.state.recent.contains { $0.title.contains("희토류") } || m.state.pending.contains { $0.item.title.contains("희토류") }
        let shot = await r.toastShot("11-reduce")
        r.record("11-다", "낱말 알리지 않기 → 다음 알림부터 반영",
                 expected: "'희토류' 든 m1 은 물방울·목록·고임 모두 없음 · 같은 때 온 c1(국내 3곳)은 물방울",
                 actual: "물방울 \(news.map(\.id)) · m1 목록/고임 \(mutedSeen) · c1 알림 \(r.notified(E2EStories.control))",
                 pass: !r.dropped(E2EStories.muted, in: news) && !mutedSeen && r.dropped(E2EStories.control, in: news), shots: [shot])
    }

    // MARK: 12
    struct Facts: Codable, Equatable {
        var chosen: [String]?
        var hidden: [String]
        var saved: [String]
        var followed: [String]
        var custom: [String]
        var mute: [String]
        var worldMode: String
        var scraps: Int
        var notifiedStories: Int
        var unread: Int
    }
    static func facts(_ m: AppModel) -> Facts {
        Facts(chosen: m.state.sectionsChosen, hidden: m.state.hiddenSources.sorted(), saved: m.state.saved.map(\.key).sorted(),
              followed: m.state.followedStories.sorted(), custom: m.state.customSources.map(\.id).sorted(), mute: m.state.settings.muteKeywords,
              worldMode: m.policy("world").mode.rawValue, scraps: Scrapbook.shared.scraps.count,
              notifiedStories: m.state.notifiedStories.count, unread: m.state.unread)
    }
    static func writeFacts(_ r: E2ERun, _ name: String) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(facts(r.model)).write(to: r.out.appendingPathComponent(name))
    }
    static func readFacts(_ r: E2ERun, _ name: String) -> Facts? {
        (try? Data(contentsOf: r.out.appendingPathComponent(name))).flatMap { try? JSONDecoder().decode(Facts.self, from: $0) }
    }

    static func restart(_ r: E2ERun) async {
        let m = r.model
        await r.sleep(6)
        let before = readFacts(r, "facts-before.json")
        var now = facts(m)
        now.notifiedStories = before?.notifiedStories ?? now.notifiedStories // 36시간 지난 기록은 정리될 수 있어 비교에서 뺌
        let onboard = NSApp.windows.contains { $0.isVisible && $0.title == "관심 분야 고르기" }
        let diff = before.map { b in Mirror(reflecting: b).children.compactMap { c -> String? in
            let a = Mirror(reflecting: now).children.first { $0.label == c.label }?.value
            return "\(a ?? "")" == "\(c.value)" ? nil : "\(c.label ?? "?"): \(c.value) → \(a ?? "")"
        } } ?? ["이전 값 없음"]
        r.record("12-가", "앱 다시 시작 → 상태 유지",
                 expected: "고른 분야·숨긴 출처·저장·팔로우·직접 추가 출처·알리지 않음 낱말·분야 모드·스크랩·안 읽음 그대로 · 분야 고르기 창 안 뜸",
                 actual: diff.isEmpty ? "모두 같음 · 고르기 창 \(onboard ? "뜸" : "안 뜸")" : "다름: \(diff) · 고르기 창 \(onboard ? "뜸" : "안 뜸")",
                 pass: before != nil && diff.isEmpty && !onboard)
        Store.save(m.state) // 이번 실행 첫 쓰기 → 직전 파일이 .bak 으로 남는다(복구 시험에 씀)
        Store.flush()
        writeFacts(r, "facts-restart.json")
    }

    static func recover(_ r: E2ERun) async {
        let m = r.model
        await r.sleep(6)
        let fm = FileManager.default
        let dir = Store.dir
        let brokenState = fm.fileExists(atPath: dir.appendingPathComponent("native-state.broken.json").path)
        let brokenDB = fm.fileExists(atPath: dir.appendingPathComponent("magazine.broken.sqlite").path)
        let before = readFacts(r, "facts-restart.json")
        let now = facts(m)
        let kept = before.map { $0.chosen == now.chosen && $0.hidden == now.hidden && $0.saved == now.saved && $0.custom == now.custom && $0.mute == now.mute } ?? false
        r.record("12-나", "상태 파일 깨짐 → .bak 에서 복구",
                 expected: "깨진 native-state.json 은 .broken.json 으로 남고 .bak 에서 설정·저장·숨김을 되살림 · 분야 고르기 창 안 뜸",
                 actual: "broken.json \(brokenState) · 되살린 값 같음 \(kept) · 고른 분야 \(m.chosenSections) · 저장 \(now.saved.count) · 숨김 \(now.hidden)",
                 pass: brokenState && kept && !m.needsOnboarding)
        r.publish(E2EStories.after, at: Date())
        let mark = r.toastMark
        await r.check()
        let news = r.newsToasts(since: mark)
        let inDB = !Database.shared.items(keys: [r.key("yna-market", "r1-yna-market")]).isEmpty
        r.record("12-다", "매거진 DB 깨짐 → 새 DB 로 계속",
                 expected: "깨진 magazine.sqlite 는 .broken.sqlite 로 치우고 새 DB 로 시작 · 스크랩은 사본(scraps.json)·치운 파일에서 되살림 · 새 글(r1, 국내 3곳)이 DB 에 들어가고 알림",
                 actual: "broken.sqlite \(brokenDB) · DB 기사 \(Database.shared.itemCount)건 · r1 DB \(inDB) · 물방울 \(news.map(\.id)) · 스크랩 \(Scrapbook.shared.scraps.count)개(이전 \(before?.scraps ?? -1))",
                 pass: brokenDB && inDB && r.dropped(E2EStories.after, in: news) && Scrapbook.shared.scraps.count == (before?.scraps ?? -1))
        r.note("스크랩 복구: 치운 파일에서 \(Database.shared.salvagedScraps)개 · scraps.json 있음 \(fm.fileExists(atPath: Scrapbook.copyFile().path))")
        writeReport(r)
    }

    // 세 실행의 결과를 모아 표로(E2E-run.md)
    static func writeReport(_ r: E2ERun) {
        var rows: [E2EStep] = []
        for p in ["main", "restart", "recover"] {
            let f = r.out.appendingPathComponent("results-\(p).json")
            if p == r.phase { rows += r.stepsSoFar; continue }
            if let d = try? Data(contentsOf: f), let s = try? JSONDecoder().decode([E2EStep].self, from: d) { rows += s }
        }
        var md = "# Dropcap 시나리오 시험 결과\n\n| 단계 | 내용 | 기대 | 실제 | 결과 | 스냅샷 |\n|---|---|---|---|---|---|\n"
        func cell(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
        for s in rows {
            md += "| \(s.id) | \(cell(s.title)) | \(cell(s.expected)) | \(cell(s.actual)) | \(s.pass.map { $0 ? "통과" : "**실패**" } ?? "눈으로") | \(s.shots.joined(separator: "<br>")) |\n"
        }
        md += "\n통과 \(rows.filter { $0.pass == true }.count) · 실패 \(rows.filter { $0.pass == false }.count) · 눈으로 확인 \(rows.filter { $0.pass == nil }.count)\n"
        try? md.write(to: r.out.appendingPathComponent("E2E-run.md"), atomically: true, encoding: .utf8)
    }

    static func fmt(_ c: Coverage?) -> String { c.map { "국내\($0.kr)·해외\($0.intl)" } ?? "-" }
}

extension E2EStory {
    func with(sources: [String]) -> E2EStory { E2EStory(id: id, base: base, tails: tails, sources: sources, summary: summary) }
}

// 창 안의 글(확인 창 문구 확인용)
@MainActor
private func allText(_ v: NSView) -> [String] {
    var out: [String] = []
    if let t = v as? NSTextField, !t.stringValue.isEmpty { out.append(t.stringValue) }
    for s in v.subviews { out += allText(s) }
    return out
}
