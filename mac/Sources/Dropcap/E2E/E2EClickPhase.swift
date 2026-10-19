import AppKit
import SwiftUI

// 시험 장치: 디버그 빌드(swift build·swift test·e2e·clicksweep)에만 들어간다. 배포 빌드(build.sh, -c release)에는 없음.
#if DEBUG

// 클릭 시험 단계: 견본 자료를 채운 뒤 화면마다(분야 고르기·상단바·매거진 지면들·읽기 창·설정 탭·물방울) 누를 것을 모두 누른다.
@MainActor
enum E2EClickPhase {
    typealias S = E2EStories

    static func run(_ r: E2ERun) async {
        let m = r.model
        let sw = E2EClickSweep(r)
        // 앞 앱 지키기: 시험 앱이 한 번이라도 앞 앱이 되면 기록(조용한 모드에서는 0이어야 함)
        let me = ProcessInfo.processInfo.processIdentifier
        var stole = 0
        let front0 = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let obs = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.processIdentifier == me { stole += 1; TestLog.write("[앞 앱] 시험 앱이 앞 앱이 됨(\(stole))") }
        }
        defer { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        r.note("[클릭] 모드 \(sw.quiet ? "조용한(포커스 없음)" : "실제 클릭") · 시작 때 앞 앱 \(front0)")
        m.update { $0.intervalMinutes = 600; $0.digestEnabled = false }
        let only = ProcessInfo.processInfo.environment["DROPCAP_CLICK_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        func want(_ s: String) -> Bool { only?.contains(s) ?? true }

        // 분야 고르기(첫 실행 창)
        let onboard: () -> NSWindow? = { NSApp.windows.first { $0.isVisible && $0.title == "관심 분야 고르기" } }
        await r.until(15) { onboard() != nil }
        await r.until(30) { SectionPhotos.shared.images.count >= 10 }
        if want("onboard") {
            for (cfg, bottom) in [("위", false), ("아래", true)] {
                await sw.sweep("분야고르기", config: cfg, window: onboard, prepare: {
                    if onboard() == nil { OnboardingController.open(); await r.sleep(1.5) }
                    if let w = onboard() { scroll(w, bottom: bottom); await r.sleep(0.3) }
                })
            }
        }
        OnboardingController.close()

        // 견본 자료: 고른 분야·출처, 새 글, 묶음·스토리·팔로우·저장·스크랩
        m.chooseSections(["top", "economy", "world", "ai"])
        for id in S.extraKr { m.setEnabled(id, true) }
        await r.until(60) { !Magazine.shared.preparing && Database.shared.itemCount > 0 }
        await r.check()
        let now = Date()
        for s in [S.s1, S.s2, S.s3, S.s4] { r.publish(s, at: now) }
        for (i, s) in S.caps.enumerated() { r.publish(s, at: now, offsetMinutes: Double(i + 1)) }
        r.publish(S.big, at: now, offsetMinutes: 30)
        await r.check()
        if let st = r.storyOf(S.s2), let c = Database.shared.cluster(st) { m.setFollowing(st, true, size: c.size) }
        if let it = Database.shared.items(keys: [r.key("yna-market", "e1-yna-market")]).first?.item {
            if !m.isSaved(it) { m.toggleSaved(it) }
            Scrapbook.shared.add(it, quote: it.displayTitle + " — 인용", original: it.title, memo: "메모", to: "E2E")
        }
        await Magazine.shared.publishDue()
        await r.sleep(3)
        for t in ToastCenter.shared.toasts { ToastCenter.shared.remove(t.id) }
        r.note("[클릭] 자료 준비: 목록 \(m.visibleRecent.count)건 · DB \(Database.shared.itemCount)건")

        // 상단바 창
        if want("menu") { await menuBar(r, sw) }
        // 매거진
        if want("magazine") { await magazine(r, sw) }
        // 읽기 창
        if want("reader") { await reader(r, sw) }
        // 설정
        if want("settings") { await settingsPaths(r, sw); await settings(r, sw) }
        // 물방울
        if want("toast") { await toasts(r, sw) }
        sw.save()
        let n = { (s: String) in sw.rows.filter { $0.result == s }.count }
        let front1 = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        r.record("C", "화면 단추 클릭 훑기", expected: "누를 것마다 그 단추가 맞고 무엇인가 일어남 · 조용한 모드면 시험 앱이 한 번도 앞 앱이 되지 않음",
                 actual: "통과 \(n("통과")) · 맞음만 \(n("통과(맞음만)")) · 실패 \(n("실패")) · 무효 \(n("무효")) · 건너뜀 \(n("건너뜀")) — CLICKS-run.md · 앞 앱 \(front0)→\(front1) · 시험 앱이 앞 앱이 된 횟수 \(stole) · 막은 활성화 시도 \(E2EQuietUI.blocked.count)",
                 pass: n("실패") == 0 && n("무효") == 0 && (!sw.quiet || stole == 0))
        try? E2EQuietUI.blocked.joined(separator: "\n").write(to: r.out.appendingPathComponent("blocked-activations.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: 상단바
    static var statusWindow: NSWindow? // 상단바 아이콘 창(눌러 보고 상단바 창이 열린 것)
    // 시험 실행은 상단바 아이콘을 두지 않으므로(설치된 앱과 겹치지 않게) 상단바 창의 화면(MenuView)을 시험 창에 그대로 띄운다
    static var hostedMenu: NSWindow?
    static func hostMenu() -> NSWindow {
        if let w = hostedMenu, w.isVisible { return w }
        let w = NSWindow(contentViewController: NSHostingController(rootView: MenuView()))
        w.title = "상단바(시험)"
        w.setContentSize(NSSize(width: 370, height: 603))
        w.isReleasedWhenClosed = false
        w.orderFrontRegardless() // 조용한 시험에서는 투명·화면 밖
        hostedMenu = w
        return w
    }
    static var statusHidden: Bool { E2EFeeds.active }
    static func menuPanel() -> NSWindow? {
        if statusHidden { return hostedMenu?.isVisible == true ? hostedMenu : nil }
        return NSApp.windows.first { w in w.isVisible && "\(Swift.type(of: w))".contains("MenuBarExtra") }
            ?? NSApp.windows.first { w in w.isVisible && w.level.rawValue >= NSWindow.Level.statusBar.rawValue && !"\(Swift.type(of: w))".contains("StatusBar") && !"\(Swift.type(of: w))".contains("Toast") && w.frame.height > 200 }
    }
    static func openMenu(_ r: E2ERun) async {
        guard menuPanel() == nil else { return }
        if statusHidden { _ = hostMenu(); await r.sleep(1.0); return }
        // 상단바 아이콘을 진짜로 눌러 연다(우리 앱의 상태 막대 창 중 눌렀을 때 상단바 창이 열리는 것)
        let sw = E2EClickSweep(r)
        let cands = statusWindow.map { [$0] } ?? NSApp.windows.filter { $0.isVisible && "\(Swift.type(of: $0))".contains("StatusBarWindow") }
        func buttons(_ v: NSView?) -> [NSButton] { guard let v else { return [] }; return ((v as? NSButton).map { [$0] } ?? []) + v.subviews.flatMap(buttons) }
        for w in cands {
            // 여는 것은 준비 단계라 상태 막대 단추의 동작을 부른다(시험 대상은 그 안의 것들). 단추가 없으면 진짜 클릭
            if let b = buttons(w.contentView).first { b.performClick(nil) } else { _ = await sw.click(w, NSPoint(x: w.frame.midX, y: w.frame.midY)) }
            await r.until(2) { menuPanel() != nil }
            if menuPanel() != nil { statusWindow = w; break }
        }
        if menuPanel() == nil {
            r.note("[클릭] 상단바 창을 못 엶 · 창: " + NSApp.windows.map { "\(Swift.type(of: $0))'\($0.title)' 보임\($0.isVisible) 층\($0.level.rawValue) \(ix($0.frame.width))×\(ix($0.frame.height))" }.joined(separator: " | "))
        }
        await r.sleep(0.6)
    }
    static func scroll(_ w: NSWindow, bottom: Bool) {
        func all(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? [] + v.subviews.flatMap(all) }
        guard let cv = w.contentView, let sv = all(cv).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }),
              let doc = sv.documentView else { return }
        let y = bottom ? max(0, doc.frame.height - sv.contentView.bounds.height) : 0
        let flipped = doc.isFlipped
        sv.contentView.scroll(to: NSPoint(x: 0, y: flipped ? y : (bottom ? 0 : max(0, doc.frame.height - sv.contentView.bounds.height))))
        sv.reflectScrolledClipView(sv.contentView)
    }

    // 가장 긴 스크롤 영역을 맨 위에서 y 만큼 내린 자리로
    static func scrollBy(_ w: NSWindow, _ y: CGFloat) {
        func all(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? [] + v.subviews.flatMap(all) }
        guard let cv = w.contentView, let sv = all(cv).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }),
              let doc = sv.documentView else { return }
        let maxY = max(0, doc.frame.height - sv.contentView.bounds.height), d = min(y, maxY)
        sv.contentView.scroll(to: NSPoint(x: 0, y: doc.isFlipped ? d : maxY - d))
        sv.reflectScrolledClipView(sv.contentView)
    }

    static func menuBar(_ r: E2ERun, _ sw: E2EClickSweep) async {
        for (cfg, bottom) in [("위", false), ("아래", true)] {
            await sw.sweep("상단바", config: cfg, window: { menuPanel() }, prepare: {
                await openMenu(r)
                if let w = menuPanel() { scroll(w, bottom: bottom); await r.sleep(0.3) }
            })
        }
        // 목록 줄 오른쪽 클릭 메뉴(바로 줄이기) — 메뉴를 실제로 여는 것이라 실제 클릭 모드에서만
        guard !sw.quiet else { r.note("[클릭] 오른쪽 클릭 메뉴는 조용한 모드에서 열지 않음(실제 클릭 모드 --real 에서만)"); return }
        await openMenu(r)
        if let w = menuPanel(), let row = sw.targets(w).first(where: { $0.role == "AXButton" && $0.frame.height > 50 && $0.frame.height < 120 }) {
            let keep = Set(NSApp.windows.filter(\.isVisible).map { "\(ObjectIdentifier($0).hashValue)|\($0.title)" })
            let ok = await sw.click(w, NSPoint(x: row.frame.midX, y: row.frame.midY), right: true)
            await r.sleep(1)
            let menu = sw.effects(sw.fingerprint(w), sw.fingerprint(w), animating: true).first { $0.hasPrefix("메뉴") }
            r.note("[클릭] 상단바 줄 오른쪽 클릭 '\(row.label)': \(ok ? (menu ?? "메뉴 없음") : "무효")")
            await sw.cleanup(keep: keep)
        }
    }

    // MARK: 매거진
    static func magWindow() -> NSWindow? { NSApp.windows.first { $0.isVisible && $0.title == "Dropcap" } }
    static func magazine(_ r: E2ERun, _ sw: E2EClickSweep) async {
        func go(_ page: MagazineView.Page, size: NSSize?, bottom: Bool) async {
            if magWindow() == nil { MagazineController.open(); await r.sleep(4) }
            guard let w = magWindow() else { return }
            if let size, w.frame.size != size { w.setContentSize(size); await r.sleep(0.5) }
            // 지면 안에 제 상태가 있는 스크랩북(고른 폴더·새 폴더 알림)은 다른 지면을 거쳐 새로 그린다 — 앞 단추의 누름이 바꾼 폴더가
            // 다음 단추의 기준이 되면 '스크랩 0'·'새 폴더'·스크랩 카드가 빈 폴더에서 검사돼 실패했다(범위 순회에서만 — 전체 순회는 칩이 '같은 형'이라 누르지 않음)
            if page == .scrapbook { MagazineController.open(page: .today); await r.sleep(0.4) }
            MagazineController.open(page: page)
            await r.sleep(0.8)
            scroll(w, bottom: bottom)
            await r.sleep(0.4)
        }
        MagazineController.open()
        await r.sleep(6)
        guard let w0 = magWindow() else { return }
        let normal = NSSize(width: 1180, height: 820) // 기본 크기(창 자리 기억값과 상관없이)
        let minSize = NSSize(width: max(w0.contentMinSize.width, w0.minSize.width, 640), height: max(w0.contentMinSize.height, w0.minSize.height, 480))
        r.note("[클릭] 매거진 창 기본 \(normal) · 최소 \(minSize)")
        let content: (NSWindow) -> NSRect = { w in var f = w.frame; f.origin.x += 220; f.size.width -= 220; return f } // 옆 목록 빼고
        // 오늘 호: 기본·최소 × 위·아래 (옆 목록은 기본·위에서만)
        let quick = ProcessInfo.processInfo.environment["DROPCAP_CLICK_QUICK"] != nil // 오늘 호 기본·위만(맞음 검사 확인용)
        for (cfg, size, bottom) in [("기본·위", normal, false), ("기본·아래", normal, true), ("최소·위", minSize, false), ("최소·아래", minSize, true)] where !quick || cfg == "기본·위" {
            await sw.sweep("매거진-오늘", config: cfg, window: magWindow, prepare: { await go(.today, size: size, bottom: bottom) },
                           within: cfg == "기본·위" ? nil : content, reset: { magWindow()?.close(); await r.sleep(0.5) })
        }
        if quick { magWindow()?.close(); return }
        // 다른 지면(기본 크기·위)
        var pages: [(String, MagazineView.Page)] = [("이번주", .week), ("경제", .section("economy")), ("스토리", .stories), ("저장", .saved),
                                                    ("스크랩북", .scrapbook), ("검색", .search), ("보관함", .archive)]
        if let st = r.storyOf(S.big) { pages.append(("스토리상세", .story(st))) }
        if let past = Magazine.shared.archive.first { pages.append(("지난호", .issue(past))) }
        for (name, page) in pages {
            await sw.sweep("매거진-\(name)", config: "기본·위", window: magWindow, prepare: { await go(page, size: normal, bottom: false) }, within: content,
                           reset: { magWindow()?.close(); await r.sleep(0.5) })
        }
        magWindow()?.close()
    }

    // MARK: 읽기 창
    static func reader(_ r: E2ERun, _ sw: E2EClickSweep) async {
        for (src, id) in [("bbc-world", "s3-bbc-world"), ("yna-market", "s1-yna-market")] {
            guard let it = Database.shared.items(keys: [r.key(src, id)]).first?.item else { continue }
            let seq = r.model.visibleRecent
            let win: () -> NSWindow? = { NSApp.windows.first { $0.isVisible && $0.title == it.sourceName } }
            await sw.sweep("읽기창-\(src)", config: "기본", window: win, prepare: {
                if win() == nil { ReaderController.open(it, sequence: seq); await r.sleep(4) }
            })
            // 키보드: J·K(다음·이전) · Esc(닫기)
            if win() == nil { ReaderController.open(it, sequence: seq); await r.sleep(4) }
            if let w = win() {
                for (name, ch, code) in [("J", "j", UInt16(38)), ("K", "k", UInt16(40)), ("Esc", "\u{1b}", UInt16(53))] {
                    let a = sw.fingerprint(w)
                    NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); await r.sleep(0.3)
                    sw.key(w, ch, code: code)
                    await r.sleep(1.2)
                    let e = sw.effects(a, sw.fingerprint(w), animating: false)
                    let valid = sw.quiet || NSApp.isActive // 조용한 모드는 창에 직접 보내므로 앱이 앞에 없어도 유효
                    sw.append(.init(screen: "읽기창-\(src)", config: "키보드", label: name, role: "키", result: !valid ? "무효" : (e.isEmpty ? "실패" : "통과"),
                                    effect: e.isEmpty ? "아무 일 없음" : e.joined(separator: " · "), hit: "-", at: "-"))
                }
            }
            NSApp.windows.filter { $0.isVisible && $0.title == it.sourceName }.forEach { $0.close() }
        }
    }

    // MARK: 설정 여는 길(매거진 옆 목록 '설정' 줄 · 매거진·읽기 창 ⌘,): 설정 창이 뜨고 그 창보다 앞에 있어야 통과.
    // 이미 열린 설정 창이 뒤에 있을 때 다시 열면 앞으로 오는지도 본다.
    static func settingsPaths(_ r: E2ERun, _ sw: E2EClickSweep) async {
        let screen = "설정 열기"
        func front(of w: NSWindow) -> Bool {
            guard let s = SettingsWindow.find(), s.isVisible,
                  let si = NSApp.orderedWindows.firstIndex(of: s), let wi = NSApp.orderedWindows.firstIndex(of: w) else { return false }
            return si < wi
        }
        func record(_ label: String, _ role: String, _ w: NSWindow?, _ how: () async -> Void) async {
            guard let w else { sw.append(.init(screen: screen, config: "기본", label: label, role: role, result: "실패", effect: "창을 찾지 못함", hit: "-", at: "-")); return }
            await how()
            await r.until(4) { front(of: w) }
            let ok = front(of: w)
            sw.append(.init(screen: screen, config: "기본", label: label, role: role, result: ok ? "통과" : "실패",
                            effect: ok ? "설정 창이 '\(w.title)' 창 앞에 뜸" : (SettingsWindow.find()?.isVisible == true ? "설정 창이 뒤에 있음" : "설정 창이 안 뜸"),
                            hit: "-", at: "-"))
        }
        // ⌘,: 앱 메뉴가 없어 창의 단축키 처리(performKeyEquivalent)로 받는다. 조용한 모드는 창에 바로, 실제 모드는 이벤트 대기열로
        func cmdComma(_ w: NSWindow) {
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: w.windowNumber, context: nil, characters: ",", charactersIgnoringModifiers: ",",
                                           isARepeat: false, keyCode: 43) else { return }
            if sw.quiet { _ = w.performKeyEquivalent(with: e) } else { NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); NSApp.postEvent(e, atStart: false) }
        }
        func closeSettings() async { SettingsWindow.find()?.close(); await r.sleep(0.5) }

        await closeSettings()
        if magWindow() == nil { MagazineController.open(); await r.sleep(4) }
        MagazineController.open(page: .today); await r.sleep(0.8)
        // 옆 목록 바닥 '설정' 줄(단추): 누른다 — 손쉬운 사용 누름과 창 직접 클릭(실제 클릭 길) 둘 다. 지면은 그대로여야 함
        func tables(_ v: NSView) -> [NSTableView] { ((v as? NSTableView).map { [$0] } ?? []) + v.subviews.flatMap(tables) }
        func selectedLabel(_ w: NSWindow) -> String {
            guard let t = tables(w.contentView ?? NSView()).first, t.selectedRow >= 0 else { return "(없음)" }
            t.scrollRowToVisible(t.selectedRow)
            return sw.targets(w).first { $0.table === t && $0.row == t.selectedRow }?.label ?? "(없음)"
        }
        func settingsButton(_ w: NSWindow) async -> E2EClickSweep.Target? {
            for t in tables(w.contentView ?? NSView()) where t.numberOfRows > 0 { t.scrollRowToVisible(t.numberOfRows - 1) }
            await r.sleep(0.4)
            // 손쉬운 사용 나무는 늦게 생긴다 — 단추가 나올 때까지 몇 번. 끝내 없으면 그 줄(AXRow)
            var side: [E2EClickSweep.Target] = []
            for _ in 0..<4 {
                side = sw.targets(w).filter { $0.frame.minX < w.frame.minX + 260 }
                if let b = side.first(where: { $0.role == "AXButton" && $0.label == "설정" }) { return b }
                await r.sleep(1)
            }
            return side.first { $0.role == "AXRow" && $0.label.contains("설정") }
        }
        // 단추면 손쉬운 사용 누름, 줄이면 그 자리 창 직접 클릭(실제 클릭 길)
        func push(_ w: NSWindow, _ b: E2EClickSweep.Target) async {
            if b.role == "AXButton" { _ = await sw.press(w, b) } else { sw.directClick(w, NSPoint(x: b.frame.midX, y: b.frame.midY)) }
        }
        if let w = magWindow() {
            if let b = await settingsButton(w) {
                await record("옆 목록 '설정' 줄(누름 · \(b.role))", b.role, w) { await push(w, b) }
                await closeSettings()
                if let b2 = await settingsButton(w) {
                    await record("옆 목록 '설정' 줄(직접 클릭)", "AXButton", w) { sw.directClick(w, NSPoint(x: b2.frame.midX, y: b2.frame.midY)) }
                }
                // 이미 열린 설정 창을 매거진 뒤로 보낸 뒤 다시 누르면 앞으로
                SettingsWindow.find()?.order(.below, relativeTo: w.windowNumber); await r.sleep(0.4)
                if let b3 = await settingsButton(w) {
                    await record("옆 목록 '설정' 줄(이미 열림·뒤에 있음)", b3.role, w) { await push(w, b3) }
                }
                // 비교: 고르는 줄('이번 주')을 같은 방법으로 누르면 지면이 바뀌는가(조용한 모드의 옆 목록 누름이 SwiftUI 선택까지 가는지)
                await closeSettings()
                if let wk = sw.targets(w).first(where: { $0.role == "AXRow" && $0.label.contains("이번 주") }) {
                    _ = await sw.press(w, wk); await r.sleep(1)
                    let a = selectedLabel(w)
                    sw.directClick(w, NSPoint(x: wk.frame.midX, y: wk.frame.midY)); await r.sleep(1)
                    r.note("[클릭] 비교: '이번 주' 줄 누름 뒤 고른 줄 '\(a)' · 직접 클릭 뒤 '\(selectedLabel(w))'")
                    MagazineController.open(page: .today); await r.sleep(0.8)
                }
                let sel = selectedLabel(w)
                sw.append(.init(screen: screen, config: "기본", label: "'설정' 줄 누른 뒤 지면", role: "AXButton", result: sel.contains("오늘") ? "통과" : "실패",
                                effect: "옆 목록에서 고른 줄 '\(sel)'", hit: "-", at: "-"))
            } else {
                sw.append(.init(screen: screen, config: "기본", label: "옆 목록 '설정' 줄", role: "AXButton", result: "실패", effect: "단추를 찾지 못함", hit: "-", at: "-"))
            }
        }
        await closeSettings()
        await record("매거진 ⌘,", "키", magWindow()) { if let w = magWindow() { cmdComma(w) } }
        await closeSettings()
        magWindow()?.close(); await r.sleep(0.5)
        // 읽기 창 ⌘,
        if let it = r.model.visibleRecent.first(where: { !$0.itemKind.opensExternally }) {
            let win: () -> NSWindow? = { NSApp.windows.first { $0.isVisible && $0.title == it.sourceName } }
            if win() == nil { ReaderController.open(it, sequence: []); await r.sleep(4) }
            await record("읽기 창 ⌘,", "키", win()) { if let w = win() { cmdComma(w) } }
            await closeSettings()
            win()?.close()
        }
    }

    // MARK: 설정
    static func settings(_ r: E2ERun, _ sw: E2EClickSweep) async {
        let win: () -> NSWindow? = { NSApp.windows.first { $0.isVisible && $0.toolbar?.items.contains { $0.label == "거르기" } == true } }
        // 구독 탭 스냅샷(보기마다 위·조금 아래): 출처 목록 정리 전후 비교용(shots/sources-*.png)
        if win() == nil { _ = await E2ESettings.settingsWindow(r) }
        if let w = win(), await E2ESettings.selectTab(w, "구독") {
            for layout in SourceDirectory.Layout.allCases {
                UserDefaults.standard.set(layout.rawValue, forKey: SourceDirectory.layoutKey)
                await r.sleep(1.2)
                scroll(w, bottom: false); await r.sleep(0.4)
                r.note("[클릭] 구독 스냅샷 \(r.windowShot({ $0 === w }, "sources-\(layout.rawValue)-top"))")
                scrollBy(w, 900); await r.sleep(0.6)
                r.note("[클릭] 구독 스냅샷 \(r.windowShot({ $0 === w }, "sources-\(layout.rawValue)-900"))")
            }
            UserDefaults.standard.removeObject(forKey: SourceDirectory.layoutKey)
            scroll(w, bottom: false)
        }
        await sourcesTab(r, sw, win)
        for tab in ["일반", "분야", "구독", "거르기", "스크랩북"] {
            // 구독 탭은 보기(매체별·분야별·지역별)마다 훑는다
            // 구독 탭: 누를 때마다 켠 출처를 처음대로(모두 켜기·스위치가 다음 단추의 이름·자리를 바꾼다), 못 찾으면 창을 새로(펼친 묶음 비움)
            let enabled0 = r.model.state.enabled
            for layout in tab == "구독" ? SourceDirectory.Layout.allCases.map(Optional.some) : [nil] {
                await sw.sweep("설정-\(tab)", config: layout?.label ?? "기본", window: win, prepare: {
                    if let layout {
                        UserDefaults.standard.set(layout.rawValue, forKey: SourceDirectory.layoutKey)
                        if r.model.state.enabled != enabled0 {
                            let ids = Set(enabled0.keys).union(r.model.state.enabled.keys)
                            r.model.setEnabled(ids: ids.filter { enabled0[$0] == true }, true)
                            r.model.setEnabled(ids: ids.filter { enabled0[$0] != true }, false)
                            await r.sleep(0.4)
                        }
                    }
                    if win() == nil { _ = await E2ESettings.settingsWindow(r) }
                    if let w = win() { _ = await E2ESettings.selectTab(w, tab) }
                }, skip: { t in t.role == "AXButton" && ["해지", "모두 지우기", "지우기"].contains(t.label) },
                   reset: layout == nil ? nil : { win()?.close(); await r.sleep(0.5) })
            }
        }
        UserDefaults.standard.removeObject(forKey: SourceDirectory.layoutKey)
        win()?.close()
    }

    // MARK: 설정 › 구독: 보기 고르기 · 묶음 펼치기 · 찾기(걸린 묶음 자동 펼침)
    static func sourcesTab(_ r: E2ERun, _ sw: E2EClickSweep, _ win: () -> NSWindow?) async {
        let screen = "설정-구독"
        func row(_ label: String, _ role: String, _ ok: Bool, _ effect: String) {
            sw.append(.init(screen: screen, config: "기본", label: label, role: role, result: ok ? "통과" : "실패", effect: effect, hit: "-", at: "-"))
        }
        // 손쉬운 사용 나무의 글(이름·값) 전부
        func texts(_ w: NSWindow) -> [String] {
            var out: [String] = []
            func walk(_ e: Any, _ depth: Int) {
                guard depth < 40, let el = e as? NSAccessibilityElementProtocol else { return }
                let o = el as AnyObject
                let n = E2EClickSweep.name(o)
                if !n.isEmpty { out.append(n) }
                for c in E2EClickSweep.kids(o) { walk(c, depth + 1) }
            }
            walk(w, 0)
            return out
        }
        let key = SourceDirectory.layoutKey
        UserDefaults.standard.set(SourceDirectory.Layout.media.rawValue, forKey: key)
        if win() == nil { _ = await E2ESettings.settingsWindow(r) }
        guard let w = win(), await E2ESettings.selectTab(w, "구독") else {
            row("구독 탭", "-", false, "설정 창·탭을 찾지 못함"); return
        }
        await r.sleep(1.2)
        _ = sw.targets(w); await r.sleep(1.0) // 첫 요청에 나무를 만들기 시작한다

        // 1) 보기 고르기: 분할 칸(NSSegmentedControl)을 고르면 기억값이 바뀌고 묶음 이름이 그 보기의 것으로
        let seg = E2ESettings.all(w.contentView, NSSegmentedControl.self).first { c in
            (0..<c.segmentCount).contains { c.label(forSegment: $0) == SourceDirectory.Layout.section.label }
        }
        for layout in [SourceDirectory.Layout.section, .region, .media] {
            let i = seg.flatMap { c in (0..<c.segmentCount).first { c.label(forSegment: $0) == layout.label } }
            if let seg, let i { seg.selectedSegment = i; _ = seg.sendAction(seg.action, to: seg.target); await r.sleep(1.0) }
            let saved = UserDefaults.standard.string(forKey: key) ?? "(없음)"
            let shown = texts(w)
            let expect = layout == .section ? "경제" : layout == .region ? "해외" : "연합뉴스"
            // 묶음 줄 이름은 '<묶음>, N/M 켬'
            let seen = shown.contains { $0 == expect || $0.hasPrefix("\(expect), ") }
            let ok = i != nil && saved == layout.rawValue && seen
            row("보기 고르기 '\(layout.label)'", "AXRadioGroup", ok,
                i == nil ? "칸을 찾지 못함" : "기억값 \(saved) · 묶음 '\(expect)' \(seen ? "보임" : "안 보임")")
            r.note("[클릭] 구독 보기 \(r.windowShot({ $0 === w }, "sources-pick-\(layout.rawValue)"))")
        }

        // 2) 묶음 펼치기: 보이는 맨 위 묶음 줄을 손쉬운 사용 누름(VoiceOver 길)·창 직접 클릭으로 번갈아 펼치고 접는다 → 출처 줄(알림 단추) 수.
        //    누름이 묶음을 켜면 안 된다(전에는 줄 안 '모두 켜기'가 같이 눌림)
        let rows = { texts(w).filter { $0 == "알림" }.count }
        //    묶음 줄은 펼침 단추(AXButton, 이름 '<묶음>, N/M 켬')
        let group = { sw.targets(w).filter { $0.role == "AXButton" && $0.label.hasSuffix(" 켬") }.max { $0.frame.maxY < $1.frame.maxY } }
        if let g = group() {
            let name = g.label.components(separatedBy: ", ").first ?? g.label
            let on0 = r.model.state.enabled
            var n = rows()
            for (i, direct) in [false, true, true, false].enumerated() {
                guard let t = sw.targets(w).first(where: { $0.role == "AXButton" && $0.label.hasPrefix("\(name), ") }) ?? group() else { break }
                if direct { sw.directClick(w, NSPoint(x: t.frame.minX + 120, y: t.frame.midY)) } else { _ = await sw.press(w, t) }
                await r.sleep(0.8)
                let m = rows(), open = i % 2 == 0
                if i == 0 { r.note("[클릭] 구독 묶음 펼침 \(r.windowShot({ $0 === w }, "sources-expand"))") }
                let kept = r.model.state.enabled == on0
                row("묶음 \(open ? "펼치기" : "접기")(\(direct ? "줄 직접 클릭" : "누름") · '\(name)')", t.role, (open ? m > n : m < n) && kept,
                    "출처 줄 \(n) → \(m)\(kept ? "" : " · 켜짐이 바뀜(누르면 안 됨)")")
                n = m
            }
        } else {
            row("묶음 펼치기", "AXButton", false, "보이는 묶음 줄을 찾지 못함")
        }

        // 3) 찾기: '연합뉴스 경제' → 걸린 수 '…곳 중 …곳' · 그 묶음이 저절로 펼쳐져 짧은 이름 '경제' 줄이 보임
        let field = E2ESettings.all(w.contentView, NSTextField.self).first {
            $0.isEditable && (($0.placeholderString ?? $0.placeholderAttributedString?.string) ?? "").hasPrefix("출처 찾기")
        }
        if let field, E2ESettings.type(field, "연합뉴스 경제", in: w) {
            await r.sleep(1.0)
            let shown = texts(w)
            let count = shown.first { $0.contains("곳 중") } ?? "(없음)"
            let expanded = shown.contains("경제")
            r.note("[클릭] 구독 찾기 \(r.windowShot({ $0 === w }, "sources-search"))")
            row("찾기 칸 '연합뉴스 경제'", "AXTextField", count != "(없음)" && expanded, "걸린 수 '\(count)' · 묶음 자동 펼침 \(expanded ? "O" : "X")")
            _ = E2ESettings.type(field, "", in: w); await r.sleep(0.6)
            row("찾기 지우기", "AXTextField", !texts(w).contains { $0.contains("곳 중") }, "걸린 수 글 사라짐")
            w.makeFirstResponder(nil)
        } else {
            row("찾기 칸", "AXTextField", false, "찾기 칸을 찾지 못함")
        }
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: 물방울
    static func toasts(_ r: E2ERun, _ sw: E2EClickSweep) async {
        // 물방울 판은 진짜 커서가 카드 위에 있을 때만 클릭을 받는다(설계) — 커서를 옮기지 않는 조용한 모드에서는 시험할 수 없다
        if sw.quiet {
            sw.append(.init(screen: "물방울", config: "기본", label: "(카드·닫기·칩)", role: "-", result: "건너뜀",
                            effect: "커서 위치를 보는 화면이라 실제 클릭 모드(--real)에서만", hit: "-", at: "-"))
            return
        }
        let items = Array(r.model.visibleRecent.prefix(2))
        let panel: () -> NSWindow? = { NSApp.windows.first { $0.isVisible && "\(Swift.type(of: $0))".contains("ToastPanel") } }
        await sw.sweep("물방울", config: "기본", window: panel, prepare: {
            if ToastCenter.shared.toasts.isEmpty { ToastCenter.shared.show(items, sound: false); await r.sleep(3) }
            // 물방울 판은 커서가 카드 위에 있을 때만 클릭을 받는다 → 진짜 커서를 첫 카드 위로
            if let w = panel(), let c = ToastCenter.shared.cardFrames.values.first, let scr = NSScreen.screens.first {
                let sp = w.convertPoint(toScreen: NSPoint(x: c.midX, y: w.frame.height - c.midY))
                CGWarpMouseCursorPosition(CGPoint(x: sp.x, y: scr.frame.maxY - sp.y))
                await r.sleep(0.5)
            }
        }, warp: true)
    }
}

extension E2EClickSweep {
    func append(_ row: Row) { appendRow(row) }
}

#endif
