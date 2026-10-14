import AppKit
import SwiftUI

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
        if want("settings") { await settings(r, sw) }
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
                                                    ("스크랩북", .scrapbook), ("검색", .search)]
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

    // MARK: 설정
    static func settings(_ r: E2ERun, _ sw: E2EClickSweep) async {
        let win: () -> NSWindow? = { NSApp.windows.first { $0.isVisible && $0.toolbar?.items.contains { $0.label == "거르기" } == true } }
        for tab in ["일반", "분야", "구독", "거르기", "스크랩북"] {
            await sw.sweep("설정-\(tab)", config: "기본", window: win, prepare: {
                if win() == nil { _ = await E2ESettings.settingsWindow(r) }
                if let w = win() { _ = await E2ESettings.selectTab(w, tab) }
            }, skip: { t in t.role == "AXButton" && ["해지", "모두 지우기", "지우기"].contains(t.label) })
        }
        win()?.close()
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
