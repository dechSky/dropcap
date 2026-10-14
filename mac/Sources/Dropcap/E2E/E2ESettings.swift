import AppKit
import DropcapShared
import SwiftUI

// 시나리오 13~22: 설정과의 상호작용. 단계마다 상단바 목록·안 읽음 수·매거진 오늘 호·스토리·검색·알림 대기열·위젯 스냅숏 JSON 을 같이 본다.
// 설정 창의 실제 칸(낱말 입력·글꼴 토글)은 창의 AppKit 컨트롤을 찾아 직접 입력·누르고, 못 찾으면 같은 동작을 모델로 하고 그렇다고 적는다.
@MainActor
enum E2ESettings {
    // 한 출처(또는 낱말)가 화면 곳곳에 보이는지
    struct Surfaces: CustomStringConvertible {
        var menu = false, today = false, story = false, search = false, pending = false, widget = false
        var unread = 0
        var description: String {
            "목록 \(menu ? "O" : "X") · 오늘 호 \(today ? "O" : "X") · 스토리 \(story ? "O" : "X") · 검색 \(search ? "O" : "X") · 대기열 \(pending ? "O" : "X") · 위젯 \(widget ? "O" : "X") · 안 읽음 \(unread)"
        }
        var anywhere: Bool { menu || today || story || search || pending || widget }
    }

    static func surfaces(_ r: E2ERun, source: String, term: String, waitWidget: Bool = true) async -> Surfaces {
        let m = r.model
        var s = Surfaces()
        s.menu = m.visibleRecent.contains { $0.sourceId == source }
        let t = await Magazine.shared.today()
        s.today = ([t.cover?.item].compactMap { $0 } + t.sections.flatMap(\.items)).contains { $0.sourceId == source }
        s.story = Magazine.shared.stories().contains { c in Magazine.shared.storyItems(c.id).contains { $0.sourceId == source } }
        s.search = await Magazine.shared.search(term).contains { $0.sourceId == source }
        s.pending = m.state.pending.contains { $0.item.sourceId == source }
        if waitWidget { await r.sleep(3.5) } // 위젯은 상태가 바뀌면 2초 묶어서 스스로 쓴다(직접 부르지 않음 — 실제 경로 확인)
        let f = WidgetExporter.shared.dir.appendingPathComponent(WidgetSnapshot.fileName)
        if let d = try? Data(contentsOf: f), let w = WidgetSnapshot.decode(d) {
            s.widget = ([w.cover].compactMap { $0 } + w.latest).contains { $0.key.hasPrefix(source + "|") }
        }
        s.unread = m.state.unread
        return s
    }

    // MARK: 설정 창 컨트롤
    static func settingsWindow(_ r: E2ERun) async -> NSWindow? {
        NSApp.activate(ignoringOtherApps: true)
        // 앱이 쓰는 길(MenuView 의 @Environment(\.openSettings))과 같게: 작은 SwiftUI 화면을 띄워 openSettings() 를 부른다
        let opener = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless], backing: .buffered, defer: false)
        opener.isReleasedWhenClosed = false // 코드로 만든 창은 닫을 때 스스로 풀려(기본값) Swift 참조와 겹쳐 두 번 풀리며 죽었다
        opener.contentView = NSHostingView(rootView: SettingsOpener())
        opener.orderFrontRegardless()
        var w: NSWindow?
        let find = { NSApp.windows.first { $0.isVisible && $0.toolbar?.items.contains { $0.label == "거르기" } == true } }
        await r.until(4) { w = find(); return w != nil }
        opener.close()
        if w == nil { // 예전 길(선택자)도 한 번
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            await r.until(3) { w = find(); return w != nil }
        }
        if w == nil { // 못 찾으면 무엇이 떠 있는지 남긴다(다음에 맞추려고)
            for x in NSApp.windows where x.isVisible {
                r.note("  창 '\(x.title)' 도구막대 \(x.toolbar?.items.map { "[\($0.itemIdentifier.rawValue)|\($0.label)]" }.joined() ?? "없음") 종류 \(Swift.type(of: x))")
            }
        }
        return w
    }
    static func selectTab(_ w: NSWindow, _ label: String) async -> Bool {
        guard let item = w.toolbar?.items.first(where: { $0.label == label }), let a = item.action else { return false }
        NSApp.sendAction(a, to: item.target, from: item)
        try? await Task.sleep(for: .milliseconds(600))
        return true
    }
    static func all<T: NSView>(_ v: NSView?, _ t: T.Type) -> [T] {
        guard let v else { return [] }
        return ((v as? T).map { [$0] } ?? []) + v.subviews.flatMap { all($0, t) }
    }
    // 손쉬운 사용 나무에서 이름에 label 이 든 켬/끔 단추를 찾아 누른다(SwiftUI 토글은 AppKit 제목이 비어 있음)
    static func pressAX(in w: NSWindow, label: String) -> Bool {
        func walk(_ e: Any, _ depth: Int) -> Bool {
            guard depth < 40, let el = e as? NSAccessibilityElementProtocol else { return false }
            let obj = el as AnyObject
            let name = E2EClickSweep.name(obj)
            let role = E2EClickSweep.role(obj)
            if name.contains(label), ["AXCheckBox", "AXButton", "AXToggle", "AXSwitch"].contains(role) {
                return obj.accessibilityPerformPress?() ?? false
            }
            for c in (obj.accessibilityChildren?() ?? nil) ?? [] where walk(c, depth + 1) { return true }
            return false
        }
        return walk(w, 0)
    }

    // 글자 칸에 사람이 치듯 넣기(바인딩·onChange 가 실제로 돈다)
    static func type(_ field: NSTextField, _ text: String, in w: NSWindow) -> Bool {
        guard w.makeFirstResponder(field), let ed = field.currentEditor() as? NSTextView else { return false }
        ed.selectAll(nil)
        ed.insertText(text, replacementRange: ed.selectedRange())
        return true
    }

    // MARK: 단계
    static func run(_ r: E2ERun) async {
        let m = r.model
        r.setClock(r.at(day: 1, 22, 50), "설정 상호작용")
        let now = Date()

        // 13·14) 출처 끄기 → 다시 켜기 — guardian-world 단독 + bbc-world 와 함께 다룬 스토리(검색어 'Zephyrine')
        let gx = E2EStory(id: "g1", base: "Zephyrine lighthouse keepers restore coastal signal network", tails: E2EStories.enTails, sources: ["guardian-world", "bbc-world"])
        r.publish(gx, at: now)
        await r.check()
        var mark = r.toastMark
        let before = await surfaces(r, source: "guardian-world", term: "Zephyrine")
        let unread0 = m.state.unread
        m.setEnabled("guardian-world", false)
        let off = await surfaces(r, source: "guardian-world", term: "Zephyrine")
        r.record("13", "출처 끄기(설정 토글) → 그 출처 글이 모든 곳에서 즉시 빠짐",
                 expected: "끄기 전엔 보임 · 끈 뒤 목록·오늘 호·스토리·검색·대기열·위젯 모두 X · 안 읽음 줄어듦",
                 actual: "전: \(before) → 후: \(off)",
                 pass: before.menu && before.search && !off.anywhere && off.unread < unread0)
        m.setEnabled("guardian-world", true)
        await r.until(30) { !m.checking }
        await r.check()
        let on = await surfaces(r, source: "guardian-world", term: "Zephyrine")
        let dupes = r.newsToasts(since: mark).filter { $0.sourceId == "guardian-world" || $0.id.hasPrefix("g1-") }
        r.record("14", "다시 켜기 → 그대로 돌아옴(지우지 않음) · 중복 알림 없음",
                 expected: "목록·오늘 호·스토리·검색·위젯 다시 O · 새 확인에서 guardian-world 물방울 없음 · 안 읽음은 끄기 전 값으로",
                 actual: "\(on) · 물방울 \(dupes.map(\.id)) · 안 읽음 끄기 전 \(unread0)",
                 pass: on.menu && on.today == before.today && on.story == before.story && on.search && on.widget == before.widget && dupes.isEmpty && on.unread == unread0)

        // 15) 직접 추가한 채널 해지 → 다시 구독
        if let src = m.state.customSources.first(where: { $0.url == E2EFeeds.customURL("e2e-a") }) {
            E2EFeeds.postCustom("e2e-a", .init(sourceId: src.id, id: "e2e-a-new", title: "Quillwort 견본 피드 새 글", summary: "직접 추가한 채널의 새 글",
                                               date: Date(), image: "https://img.\(E2EFeeds.host)/e2e-a-new.png"))
            await r.check()
            let b = await surfaces(r, source: src.id, term: "Quillwort")
            m.removeCustomSource(src.id)
            let gone = await surfaces(r, source: src.id, term: "Quillwort")
            mark = r.toastMark
            let err = await m.addChannel(E2EFeeds.customURL("e2e-a"), name: src.name)
            let back = await surfaces(r, source: src.id, term: "Quillwort")
            r.record("15", "직접 추가한 채널 해지 → 빠짐 · 같은 주소로 다시 구독하면 돌아옴",
                     expected: "해지 전 목록·검색 O · 해지 뒤 모두 X · 다시 구독(같은 id) 뒤 목록·검색 O · 알림 없음",
                     actual: "전 \(b) → 해지 \(gone) → 다시 \(back) · 구독 결과 \(err ?? "성공") · 물방울 \(r.newsToasts(since: mark).count)",
                     pass: b.menu && !gone.anywhere && err == nil && back.menu && back.search && r.newsToasts(since: mark).isEmpty)
        } else {
            r.record("15", "직접 추가한 채널 해지", expected: "-", actual: "직접 추가한 채널(e2e-a)이 없음", pass: false)
        }

        // 16) 분야 빼기 → 다시 넣기 (AI: s4 는 openai)
        let aiOn = Sections.meta.values.filter { $0.section == Sections.ai && $0.defaultOn == true }.map(\.id).sorted()
        E2EFeeds.post(.init(sourceId: "openai", id: "ai2", title: "Larkspur sample note on evaluation tooling", summary: "AI 분야 견본",
                            date: Date(), image: "https://img.\(E2EFeeds.host)/ai2.png"))
        await r.check()
        let aiB = await surfaces(r, source: "openai", term: "Larkspur")
        m.chooseSections(["top", "economy", "world"])
        let aiOff = await surfaces(r, source: "openai", term: "Larkspur")
        let pendAI = m.state.pending.contains { $0.section == Sections.ai }
        m.chooseSections(["top", "economy", "world", "ai"])
        await r.until(30) { !Magazine.shared.preparing }
        let reOn = aiOn.filter { m.state.enabled[$0] != true }
        let aiBack = await surfaces(r, source: "openai", term: "Larkspur")
        r.record("16", "분야 고르기에서 분야 빼기 → 그 분야 글 빠짐 · 묶음 대기열 정리 · 다시 넣으면 기본 출처 다시 켜짐",
                 expected: "AI 빼기 전 openai 글 보임(대기열 O) → 빼면 모두 X·AI 대기열 없음 → 다시 넣으면 AI 기본 출처 \(aiOn.count)곳 켜짐·글 돌아옴",
                 actual: "전 \(aiB) → 뺌 \(aiOff) · AI 대기열 \(pendAI) → 다시 \(aiBack) · 안 켜진 기본 출처 \(reOn)",
                 pass: aiB.menu && !aiOff.anywhere && !pendAI && reOn.isEmpty && aiBack.menu && aiBack.search)

        // 17) 숨기기 → 숨김 해제(bbc-world 는 켜진 채)
        let hb = await surfaces(r, source: "bbc-world", term: "Zephyrine")
        m.hideSource("bbc-world")
        let hh = await surfaces(r, source: "bbc-world", term: "Zephyrine")
        m.unhideSource("bbc-world")
        let hu = await surfaces(r, source: "bbc-world", term: "Zephyrine")
        r.record("17", "출처 숨기기 → 켜져 있어도 빠짐 · 숨김 해제로 돌아옴",
                 expected: "숨기면 모두 X(켜짐은 그대로) · 해제하면 숨기기 전과 같음",
                 actual: "전 \(hb) → 숨김 \(hh)(켜짐 \(m.state.enabled["bbc-world"] == true)) → 해제 \(hu)",
                 pass: !hh.anywhere && m.state.enabled["bbc-world"] == true && hu.search == hb.search && hu.today == hb.today && hu.story == hb.story)

        // 18) 저장한 기사는 출처를 꺼도 남음
        let savedKey = r.key("yna-market", "e1-yna-market")
        m.setEnabled("yna-market", false)
        let keep = m.state.saved.contains { $0.key == savedKey }
        let menuGone = !m.visibleRecent.contains { $0.sourceId == "yna-market" }
        m.setEnabled("yna-market", true)
        await r.until(30) { !m.checking }
        r.record("18", "저장한 기사는 출처를 꺼도 저장 목록에 남음",
                 expected: "yna-market 끔 → 상단바 목록에서는 빠지고 나중에 읽기(e1)는 남음",
                 actual: "목록에서 빠짐 \(menuGone) · 저장 목록에 남음 \(keep)",
                 pass: keep && menuGone)

        // 19) 알림 모드·하루 상한 바꾸기 → 다음 확인부터
        // 국내 2곳(문턱 아래)+꼭 알림 낱말: 주요 뉴스 흐름(문턱을 넘을 때만)에 걸리지 않아 경제 분야 정책만 보인다
        // 이야기마다 낱말이 겹치지 않게('지역화폐'만 같음) — 겹치면 같은 소식으로 묶여 두 번째부터는 알리지 않는다
        let bodies = ["남해": "어촌 수산물 직거래 장터 개장", "동해": "관광 숙박 할인 쿠폰 추가 배포", "서해": "갯벌 체험 마을 방문객 급증",
                      "북부": "산간 도로 제설 예산 증액", "남부": "농산물 산지 가격 안정 대책", "강원": "스키장 인근 상권 겨울 특수",
                      "충청": "산업단지 청년 일자리 박람회", "전라": "전통 발효 식품 수출 상담회", "경상": "조선소 협력업체 납품 대금 조기 지급"]
        let econ = { (id: String, w: String) in E2EStory(id: id, base: "\(w) 지역화폐 \(bodies[w]!)", tails: E2EStories.koTails, sources: ["yna-market", "sbs-top"]) }
        let mustSaved = m.state.settings.mustKeywords
        m.update { $0.mustKeywords = mustSaved + ["지역화폐"] }
        var modeLog: [String] = []
        var modeOK = true
        for (mode, want) in [(NotifyMode.magazine, "조용"), (.bundle, "고임"), (.instant, "알림")] {
            m.setPolicy("economy") { $0.mode = mode; $0.dailyCap = 10 }
            let s = econ("p" + mode.rawValue.prefix(3), ["남해", "동해", "서해"][[NotifyMode.magazine, .bundle, .instant].firstIndex(of: mode)!])
            r.publish(s, at: Date())
            mark = r.toastMark
            await r.check()
            let got = r.dropped(s, in: r.newsToasts(since: mark)) ? "알림" : (r.pending(s) != nil ? "고임" : "조용")
            modeLog.append("\(mode.label)→\(got)")
            if got != want { modeOK = false }
        }
        let sentEcon = m.state.notifyLog.filter { $0.section == "economy" }.count
        m.setPolicy("economy") { $0.dailyCap = sentEcon } // 이미 보낸 만큼 → 다음 것은 경제로는 못 감
        let c1 = econ("pc1", "북부")
        r.publish(c1, at: Date())
        var log0 = m.state.notifyLog.count
        await r.check()
        let capFull = m.state.notifyLog.dropFirst(log0).map(\.section)
        m.setPolicy("economy") { $0.dailyCap = sentEcon + 5 }
        let c2 = econ("pc2", "남부")
        r.publish(c2, at: Date())
        log0 = m.state.notifyLog.count
        await r.check()
        let capOpen = m.state.notifyLog.dropFirst(log0).map(\.section)
        r.record("19", "알림 모드(매거진만↔묶음↔즉시)·하루 상한 바꾸기 → 다음 확인부터 바로 반영",
                 expected: "(국내 2곳+꼭 알림 낱말 소식) 매거진만→조용 · 묶음→고임 · 즉시→알림 · 상한을 오늘 보낸 수로 낮추면 경제로 안 감(고임) · 올리면 경제로 알림",
                 actual: "\(modeLog.joined(separator: " · ")) · 상한=\(sentEcon): 기록 \(capFull) 고임 \(r.pending(c1) ?? "-") · 상한=\(sentEcon + 5): 기록 \(capOpen)",
                 pass: modeOK && !capFull.contains("economy") && r.pending(c1) == "economy" && capOpen == ["economy"])
        m.update { $0.mustKeywords = mustSaved }

        // 20) 낱말 거르기: 설정 창 '거르기' 칸에 입력 → 0.6초 뒤 저장 → 기존 목록 ★·숨김 바로
        let starTarget = m.visibleRecent.first { $0.title.contains("Zephyrine") }
        let muteTarget = m.visibleRecent.first { $0.title.contains("지역화폐") }
        var path = "설정 창"
        let mustBefore = m.state.settings.mustKeywords, muteBefore = m.state.settings.muteKeywords
        var early = false, savedAfter = false
        if let w = await settingsWindow(r), await selectTab(w, "거르기") {
            let fields = all(w.contentView, NSTextField.self).filter { $0.isEditable }
            if fields.count >= 2, type(fields[0], "Zephyrine", in: w), type(fields[1], (muteBefore + ["지역화폐"]).joined(separator: ", "), in: w) {
                await r.sleep(0.3)
                early = m.state.settings.mustKeywords != mustBefore
                await r.sleep(0.8)
                savedAfter = m.state.settings.mustKeywords.contains("Zephyrine") && m.state.settings.muteKeywords.contains("지역화폐")
                r.windowShot({ $0 === w }, "20-settings-filters")
            } else { path = "모델(칸 \(fields.count)개 — 입력 실패)" }
            w.close()
        } else { path = "모델(설정 창·탭 못 찾음)" }
        if !path.hasPrefix("설정 창") { // 같은 동작을 모델로(0.6초 타이머 포함)
            KeywordSaveTimer.shared.schedule { m.update { $0.mustKeywords = ["Zephyrine"]; $0.muteKeywords = muteBefore + ["지역화폐"] }; m.reapplyKeywords() }
            await r.sleep(0.3); early = m.state.settings.mustKeywords != mustBefore
            await r.sleep(0.8); savedAfter = m.state.settings.mustKeywords.contains("Zephyrine")
        }
        let starred = starTarget.map { t in m.visibleRecent.first { $0.key == t.key }?.important == true } ?? false
        let muted = muteTarget.map { t in !m.visibleRecent.contains { $0.key == t.key } } ?? false
        // 낱말을 다시 지우면 숨겼던 기사가 돌아오는가(거르기만, 지우지 않음)
        m.update { $0.mustKeywords = mustBefore; $0.muteKeywords = muteBefore }
        m.reapplyKeywords()
        let unmuted = muteTarget.map { t in m.visibleRecent.contains { $0.key == t.key } } ?? false
        // 설정 창이 열린 채 바깥에서 낱말이 바뀐 뒤 탭을 옮겨도(칸이 사라질 때 저장) 옛 글자로 되돌리지 않는가
        var stale = "확인 안 함"
        if let w = await settingsWindow(r), await selectTab(w, "거르기"), await selectTab(w, "일반") {
            await r.sleep(1)
            stale = m.state.settings.muteKeywords == muteBefore && m.state.settings.mustKeywords == mustBefore ? "그대로" : "되돌림 \(m.state.settings.muteKeywords)"
            w.close()
        }
        r.record("20", "낱말 거르기(꼭 알림·알리지 않음) 입력 → 0.6초 뒤 저장, 기존 목록 ★·숨김 바로 반영",
                 expected: "입력 0.3초엔 아직 저장 안 됨 · 0.6초 뒤 저장 · 'Zephyrine' 기사에 ★ · '지역화폐' 기사 목록에서 빠짐 · 낱말을 지우면 다시 보임 · 그 뒤 설정 창 탭을 옮겨도 옛 글자로 되돌리지 않음",
                 actual: "경로 \(path) · 0.3초 저장됨 \(early) · 1.1초 저장됨 \(savedAfter) · ★ \(starred) · 숨김 \(muted) · 낱말 지운 뒤 돌아옴 \(unmuted) · 탭 옮긴 뒤 낱말 \(stale)",
                 pass: !early && savedAfter && starred && muted && unmuted && stale != "확인 안 함" && !stale.hasPrefix("되돌림"))

        // 21) 글꼴 끄기 → 열린 창 다시 그려짐
        let e0 = Appearance.shared.epoch
        MagazineController.open()
        await r.sleep(5)
        let shotA = r.windowShot({ $0.title == "Dropcap" }, "21-font-on")
        var fpath = "설정 창"
        if let w = await settingsWindow(r), await selectTab(w, "일반"), pressAX(in: w, label: "Pretendard") {
            await r.sleep(0.5)
            w.close()
        } else {
            if let w = NSApp.windows.first(where: { $0.isVisible && $0.toolbar != nil }) {
                let names = all(w.contentView, NSControl.self).map { "\(Swift.type(of: $0)):\(($0 as? NSButton)?.title ?? ""):\($0.accessibilityLabel() ?? "")" }
                r.note("  설정 창 컨트롤 \(names.prefix(30))")
                w.close()
            }
            fpath = "모델(토글 못 찾음)"
            UserDefaults.standard.set(false, forKey: "usePretendard"); Appearance.shared.changed()
        }
        await r.sleep(2)
        let e1 = Appearance.shared.epoch
        let fontOff = !Typography.usePretendard
        let shotB = r.windowShot({ $0.title == "Dropcap" }, "21-font-off")
        let differs = (try? Data(contentsOf: r.out.appendingPathComponent(shotA))) != (try? Data(contentsOf: r.out.appendingPathComponent(shotB)))
        UserDefaults.standard.set(true, forKey: "usePretendard"); Appearance.shared.changed() // 되돌림
        NSApp.windows.first { $0.title == "Dropcap" }?.close()
        r.record("21", "글꼴 끄기 → 열린 창 다시 그려짐",
                 expected: "Pretendard 끔 → Appearance.epoch +1 · 열린 매거진 창 글꼴이 바뀜(전후 그림이 다름)",
                 actual: "경로 \(fpath) · epoch \(e0)→\(e1) · 글꼴 꺼짐 \(fontOff) · 전후 그림 다름 \(differs)",
                 pass: e1 > e0 && fontOff && differs, shots: [shotA, shotB])

        // 22) 방해 금지·잠시 끄기 켜기/끄기 → 다음 확인부터
        m.update { $0.mustKeywords = mustSaved + ["지역화폐"] }
        defer { m.update { $0.mustKeywords = mustSaved } }
        var qlog: [String] = []
        var qOK = true
        let hour = Calendar.current.component(.hour, from: Date())
        for (i, (label, apply, want)) in [
            ("방해 금지 켬", { m.update { $0.quietEnabled = true; $0.quietStart = hour; $0.quietEnd = (hour + 1) % 24 } }, false),
            ("방해 금지 끔", { m.update { $0.quietEnabled = false } }, true),
            ("잠시 끄기 켬", { m.snooze(Date().addingTimeInterval(3600)) }, false),
            ("잠시 끄기 끔", { m.snooze(nil) }, true),
        ].enumerated() {
            apply()
            let s = econ("q\(i)", ["강원", "충청", "전라", "경상"][i])
            r.publish(s, at: Date())
            mark = r.toastMark
            await r.check()
            let dropped = r.dropped(s, in: r.newsToasts(since: mark))
            qlog.append("\(label)→\(dropped ? "알림" : "조용")")
            if dropped != want { qOK = false }
        }
        r.record("22", "방해 금지·잠시 끄기 켜기/끄기 → 다음 확인부터",
                 expected: "켬 → 물방울 없음 · 끔 → 바로 다음 확인에서 물방울",
                 actual: qlog.joined(separator: " · "), pass: qOK)
    }
}

private struct SettingsOpener: View {
    @Environment(\.openSettings) private var openSettings
    var body: some View { Color.clear.frame(width: 1, height: 1).onAppear { openSettings() } }
}
