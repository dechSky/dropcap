import AppKit
import SwiftUI

// 시험 장치: 디버그 빌드(swift build·swift test·e2e·clicksweep)에만 들어간다. 배포 빌드(build.sh, -c release)에는 없음.
#if DEBUG

// 화면 단추 하나하나 실제 클릭 시험(DROPCAP_TEST_E2E_PHASE=clicks, mac/scripts/clicksweep.sh).
// 창의 손쉬운 사용 나무에서 누를 수 있는 것(단추·링크·체크·팝업·탭…)을 모두 찾아, 각각의 가운데에 진짜 마우스 누름·뗌을 보내고
// ① 그 자리를 실제로 맞은 것이 그 단추인가(다른 것이 덮고 있지 않은가) ② 눌렀더니 무엇이 일어났는가(창·지면·메뉴·물방울·상태·그림 변화)를 적는다.
// 앱이 앞에 없어(사용자가 다른 앱을 쓰는 중) 클릭이 '창 활성화'로만 쓰이면 '무효'로 적고 한 번 더 해 본다.
// 손쉬운 사용 요소의 자리는 무한·NaN 일 수 있다(SwiftUI) — 정수로 바꿀 때 죽지 않게
func ix(_ d: CGFloat) -> Int { d.isFinite ? Int(d) : -1 }

@MainActor
final class E2EClickSweep {
    struct Row: Codable {
        var screen: String
        var config: String
        var label: String
        var role: String
        var result: String      // 통과 · 실패 · 무효 · 건너뜀
        var effect: String
        var hit: String
        var at: String          // 창 안 좌표(왼쪽 위 원점)
    }

    let r: E2ERun
    private(set) var rows: [Row] = []
    // 형 목록: 형 열쇠 → 대표(처음 검사한 화면·이름). 같은 형은 앱 전체에서 대표만 검사하고 나머지는 '같은 형'으로 적는다
    private(set) var typeReps: [String: String] = [:]
    private(set) var typeCounts: [String: Int] = [:]

    // 형 열쇠: 역할 · 높이(10px) · 폭(넓음/보통/좁음) · 사진 있음 여부. 모양이 갈리면(사진 유무·크기) 다른 형
    static func typeKey(_ t: Target) -> String {
        var img = false
        walk(t.el) { o, d in if d > 0, d < 8, role(o) == "AXImage" { img = true } }
        let w = t.frame.width > 400 ? "넓음" : t.frame.width > 120 ? "보통" : "좁음"
        return "\(t.role)|높이\(ix(t.frame.height / 10) * 10)|\(w)|\(img ? "사진" : "글")"
    }
    private var menuTracked: NSMenu?
    private var menuObs: NSObjectProtocol?

    // SwiftUI 는 손쉬운 사용 앱이 붙어 있을 때만 화면 요소 나무를 만든다 → 붙은 것처럼 알려 나무를 만들게 한다
    static func primeAccessibility() {
        let pick = ProcessInfo.processInfo.environment["DROPCAP_AX_PRIME"] ?? "enhanced"
        let attrs = pick == "none" ? [] : pick == "enhanced" ? ["AXEnhancedUserInterface"] : pick == "both" ? ["AXEnhancedUserInterface", "AXManualAccessibility"] : ["AXManualAccessibility"]
        for attr in attrs {
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: attr))
        }
    }

    init(_ r: E2ERun) {
        self.r = r
        menuObs = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { self?.menuTracked = n.object as? NSMenu }
        }
    }

    // MARK: 누를 것 찾기
    struct Target {
        let el: AnyObject
        let role: String
        let label: String
        let frame: NSRect   // 화면 좌표
        var group = ""      // 같은 모양의 되풀이 요소(카드·칩·줄)를 묶는 열쇠
        var table: NSTableView? = nil
        var row: Int? = nil
    }
    static let pressRoles: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXLink",
                                         "AXDisclosureTriangle", "AXToggle", "AXSwitch", "AXTextField", "AXSearchField", "AXTabButton", "AXCell", "AXRow"]

    // 손쉬운 사용 값은 글자가 아닌 것(NSNumber 등)이 올 수 있다 — 바로 String 으로 받으면 예외가 나고, Swift 작업 안에서는
    // 그 예외가 삼켜져 작업이 끊기고 main 큐가 멈췄다(클릭 시험을 만들며 겪음). 그래서 객체로 받아 확인한다.
    static func text(_ o: AnyObject, _ sel: Selector) -> String? {
        guard o.responds(to: sel), let v = o.perform(sel)?.takeUnretainedValue() else { return nil }
        if let s = v as? String { return s }
        if let a = v as? NSAttributedString { return a.string }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
    static func name(_ o: AnyObject) -> String {
        let parts = [text(o, #selector(NSAccessibilityProtocol.accessibilityLabel)), text(o, #selector(NSAccessibilityProtocol.accessibilityTitle)),
                     text(o, #selector(NSAccessibilityProtocol.accessibilityValue))]
        return parts.compactMap { $0 }.filter { !$0.isEmpty }.first.map { String($0.prefix(60)) } ?? ""
    }
    static func role(_ o: AnyObject) -> String { text(o, #selector(NSAccessibilityProtocol.accessibilityRole)) ?? "?" }

    // 아이들: 보통은 children, 목록(AXOutline)은 rows, 게으른 묶음(AXOpaqueProviderGroup)은 navigation order·visible children 으로만 준다
    static func kids(_ o: AnyObject) -> [Any] {
        var out: [Any] = (o.accessibilityChildren?() ?? nil) ?? []
        if out.isEmpty { out = (o.accessibilityChildrenInNavigationOrder?() ?? nil) ?? [] }
        if out.isEmpty { out = (o.accessibilityVisibleChildren?() ?? nil) ?? [] }
        if out.isEmpty { out = (o.accessibilityRows?() ?? nil) ?? [] }
        if out.isEmpty { out = (o.accessibilityContents?() ?? nil) ?? [] }
        return out
    }

    // 나무 전부(덤프용)
    static func walk(_ root: Any, _ f: (AnyObject, Int) -> Void, depth: Int = 0) {
        guard depth < 60, let el = root as? NSAccessibilityElementProtocol else { return }
        let o = el as AnyObject
        f(o, depth)
        for c in kids(o) { walk(c, f, depth: depth + 1) }
    }

    // 나무 읽기는 main 큐 블록에서(예외가 나면 작업 안에서 삼켜지지 않고 바로 드러나게)
    func findTargets(_ w: NSWindow, within: NSRect? = nil) async -> [Target] {
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume(returning: MainActor.assumeIsolated { self.targets(w, within: within) }) } }
    }

    // 스크롤 영역 안의 요소는 그 영역의 보이는 틀 안에 있어야 누를 수 있다(머리 아래로 밀려 올라간 카드 등은 빼고)
    static func clipped(_ o: AnyObject) -> NSRect? {
        var up: AnyObject? = (o.accessibilityParent?() ?? nil) as AnyObject?
        var clip: NSRect?
        for _ in 0..<30 {
            guard let u = up else { break }
            if role(u) == "AXScrollArea", let f = u.accessibilityFrame?(), f.width.isFinite { clip = clip.map { $0.intersection(f) } ?? f }
            up = (u.accessibilityParent?() ?? nil) as AnyObject?
        }
        return clip
    }

    func targets(_ w: NSWindow, within: NSRect? = nil) -> [Target] {
        var out: [Target] = []
        let visible = within ?? w.frame
        Self.walk(w) { o, _ in
            let role = Self.role(o)
            guard Self.pressRoles.contains(role) else { return }
            let f = o.accessibilityFrame?() ?? .zero
            guard f.width.isFinite, f.height.isFinite, f.width >= 4, f.height >= 4 else { return }
            let c = NSPoint(x: f.midX, y: f.midY)
            guard visible.insetBy(dx: 2, dy: 2).contains(c) else { return } // 화면에 보이는 것만(스크롤 밖은 다른 설정에서)
            if let clip = Self.clipped(o), !clip.insetBy(dx: 2, dy: 2).contains(c) { return }
            if (o.isAccessibilityEnabled?() ?? true) == false { return }
            // 창 제목 줄의 닫기·작게·크게 단추는 시스템 것이라 시험하지 않는다
            if let sub = Self.text(o, #selector(NSAccessibilityProtocol.accessibilitySubrole)),
               ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"].contains(sub) { return }
            let parent = (o.accessibilityParent?() ?? nil) as AnyObject?
            out.append(Target(el: o, role: role, label: Self.name(o), frame: f,
                              group: "\(role)|\(parent.map { ObjectIdentifier($0).hashValue } ?? 0)|\(ix(f.height / 12))"))
        }
        // AppKit 목록(NSOutlineView·NSTableView — SwiftUI 옆 목록)은 손쉬운 사용 나무에 줄이 안 나와 줄 사각형으로 더한다
        func tables(_ v: NSView) -> [NSTableView] { ((v as? NSTableView).map { [$0] } ?? []) + v.subviews.flatMap(tables) }
        for t in tables(w.contentView ?? NSView()) {
            for row in 0..<t.numberOfRows {
                let rect = t.rect(ofRow: row)
                guard rect.height >= 8, t.visibleRect.contains(NSPoint(x: rect.midX, y: rect.midY)) else { continue }
                let rv = t.rowView(atRow: row, makeIfNecessary: false)
                if rv?.isGroupRowStyle == true { continue } // 구역 머리(이번 호·분야·모아 보기)는 누를 것이 아님
                func texts(_ v: NSView?) -> [String] { guard let v else { return [] }; return ((v as? NSTextField).map { [$0.stringValue] } ?? []) + v.subviews.flatMap(texts) }
                var label = rv.map { texts($0).joined(separator: " ") } ?? ""
                if label.isEmpty, let rv { label = Self.name(rv) }
                if label.isEmpty, let cell = t.view(atColumn: 0, row: row, makeIfNecessary: false) { // SwiftUI 줄: 칸의 손쉬운 사용 이름
                    var names: [String] = []
                    Self.walk(cell) { o, _ in let n = Self.name(o); if !n.isEmpty, names.count < 3 { names.append(n) } }
                    label = names.joined(separator: " ")
                }
                let sr = w.convertToScreen(t.convert(rect, to: nil))
                guard visible.contains(NSPoint(x: sr.midX, y: sr.midY)) else { continue }
                out.append(Target(el: (rv ?? t) as AnyObject, role: "AXRow", label: label.isEmpty ? "줄 \(row)" : label, frame: sr, table: t, row: row))
            }
        }
        // 같은 자리·같은 이름이 겹치면(단추 안의 단추) 하나만
        var seen = Set<String>()
        return out.filter { seen.insert("\(ix($0.frame.midX)),\(ix($0.frame.midY)),\($0.label)").inserted }
    }

    func dump(_ w: NSWindow, _ name: String) {
        var lines: [String] = []
        Self.walk(w) { o, d in
            let f = o.accessibilityFrame?() ?? .zero
            lines.append("\(String(repeating: " ", count: d))\(Self.role(o)) '\(Self.name(o))' \(ix(f.minX)),\(ix(f.minY)) \(ix(f.width))×\(ix(f.height))")
        }
        try? lines.joined(separator: "\n").write(to: r.out.appendingPathComponent("ax-\(name).txt"), atomically: true, encoding: .utf8)
    }

    // MARK: 지문(눌렀더니 무엇이 바뀌었나)
    struct Print: Equatable {
        var windows: [String]
        var image: Int?
        var state: Int
        var toasts: Int
        var scraps: Int
        var pasteboard: Int
        var external: Int
        var modal: Bool
        var responder: String
    }
    func imageHash(_ w: NSWindow) -> Int? {
        guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        guard let p = rep.bitmapData else { return nil }
        var h = Hasher()
        h.combine(bytes: UnsafeRawBufferPointer(start: p, count: rep.bytesPerRow * rep.pixelsHigh))
        return h.finalize()
    }
    // 화면이 멈출 때까지(움직임이 끝날 때까지) 기다린 뒤의 그림. 끝내 안 멈추면 nil(그림으로는 판단 못 함)
    func settledImage(_ w: NSWindow, timeout: Double = 3) async -> Int? {
        var last = imageHash(w), waited = 0.0
        while waited < timeout {
            await r.sleep(0.3); waited += 0.3
            let now = imageHash(w)
            if now == last { return now }
            last = now
        }
        return nil
    }

    // '새로 고침'처럼 확인을 시작하는 단추는 결과(물방울·새 글)가 확인이 끝나야 나온다 — 견본 피드도 10초 넘게 걸려
    // 0.6초 뒤 비교하면 '아무 일 없음'으로 적혔다(범위 순회에서 이 단추가 형 대표가 될 때만 드러남)
    func settleCheck() async {
        guard r.model.checking else { return }
        _ = await r.until(30) { !r.model.checking }
        await r.sleep(0.3)
    }

    func fingerprint(_ w: NSWindow) -> Print {
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys; enc.dateEncodingStrategy = .secondsSince1970
        var st = r.model.state; st.lastCheck = nil; st.seen = [:]
        return Print(windows: NSApp.windows.filter(\.isVisible).map { "\(ObjectIdentifier($0).hashValue)|\($0.title)" }.sorted(),
                     image: imageHash(w), state: (try? enc.encode(st))?.hashValue ?? 0, toasts: r.toastMark,
                     scraps: Scrapbook.shared.scraps.count, pasteboard: NSPasteboard.general.changeCount,
                     external: E2EFeeds.externalCount, modal: NSApp.modalWindow != nil,
                     responder: w.firstResponder.map { "\(Swift.type(of: $0))" } ?? "")
    }
    func effects(_ a: Print, _ b: Print, animating: Bool) -> [String] {
        var e: [String] = []
        let added = Set(b.windows).subtracting(a.windows), gone = Set(a.windows).subtracting(b.windows)
        if !added.isEmpty { e.append("창 열림 \(added.map { $0.split(separator: "|").dropFirst().joined() }.map { $0.isEmpty ? "(제목 없음)" : $0 })") }
        if !gone.isEmpty { e.append("창 닫힘 \(gone.count)") }
        if menuTracked != nil { e.append("메뉴 열림 [\(menuTracked!.items.filter { !$0.isSeparatorItem }.prefix(8).map(\.title).joined(separator: ", "))]") }
        if b.modal { e.append("모달(저장·열기 창·확인 창)") }
        if b.toasts != a.toasts { e.append("물방울 \(b.toasts - a.toasts)") }
        if b.state != a.state { e.append("상태 바뀜") }
        if b.scraps != a.scraps { e.append("스크랩 \(b.scraps - a.scraps)") }
        if b.pasteboard != a.pasteboard { e.append("복사(클립보드는 다른 앱도 바꿀 수 있음)") }
        if b.external != a.external { e.append("바깥 열기") }
        if b.responder != a.responder { e.append("초점 \(b.responder)") }
        if !animating, a.image != b.image, e.isEmpty { e.append("화면 바뀜") }
        return e
    }

    // MARK: 조용한 누르기(포커스 없음): 같은 프로세스 안의 손쉬운 사용 '누름'
    var quiet: Bool { E2EQuietUI.on }
    // 맞음 검사 점: 가운데 + 안쪽 네 귀퉁이(크기의 1/4 안쪽, 최소 3px)
    func hitPoints(_ t: Target) -> [NSPoint] {
        let f = t.frame, dx = max(3, f.width / 4), dy = max(3, f.height / 4)
        return [NSPoint(x: f.midX, y: f.midY), NSPoint(x: f.minX + dx, y: f.minY + dy), NSPoint(x: f.maxX - dx, y: f.minY + dy),
                NSPoint(x: f.minX + dx, y: f.maxY - dy), NSPoint(x: f.maxX - dx, y: f.maxY - dy)]
    }
    enum Pressed { case done, skipped(String), failed(String) }
    func press(_ w: NSWindow, _ t: Target) async -> Pressed {
        if ["AXMenuButton", "AXPopUpButton"].contains(t.role) { return .skipped("메뉴는 열지 않음(열면 입력을 붙잡음) — 맞음만 확인") }
        if let tv = t.table, let row = t.row {
            // 옆 목록 줄: 그 목록 뷰에 누름·뗌을 직접(앱을 앞으로 띄우지 않음). 뗌을 먼저 대기열에 넣어 두면 누름의 추적이 그걸 받고 끝난다
            let p = tv.convert(NSPoint(x: tv.rect(ofRow: row).midX, y: tv.rect(ofRow: row).midY), to: nil)
            func ev(_ k: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: k, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            guard let down = ev(.leftMouseDown), let up = ev(.leftMouseUp) else { return .failed("이벤트를 만들 수 없음") }
            NSApp.postEvent(up, atStart: true)
            tv.mouseDown(with: down)
            return .done
        }
        if ["AXTextField", "AXSearchField"].contains(t.role) {
            // 글 칸은 창 직접 클릭으로(실제 클릭 길 — 칸이 덮였거나 너무 좁으면 초점이 안 감)
            directClick(w, NSPoint(x: t.frame.midX, y: t.frame.midY))
            return .done
        }
        // 손쉬운 사용 누름: SwiftUI 는 실제로 동작하고도 false 를 돌려주기도 한다(읽기 창 '모양') → 바뀐 것이 있으면 된 것으로(대체 클릭으로 되돌리지 않게)
        let winsBefore = NSApp.windows.filter(\.isVisible).count, imgBefore = imageHash(w)
        if t.el.accessibilityPerformPress?() ?? false { return .done }
        await r.sleep(0.5)
        if NSApp.windows.filter(\.isVisible).count != winsBefore || imageHash(w) != imgBefore { return .done }
        // 켬/끔(SwiftUI 스위치)은 누름 대신 값 바꾸기, AppKit 단추(창 제목 줄 등)는 단추 동작으로
        if ["AXCheckBox", "AXSwitch", "AXToggle"].contains(t.role) {
            let get = #selector(NSAccessibilityProtocol.accessibilityValue), set = #selector(NSAccessibilityProtocol.setAccessibilityValue(_:))
            let v = Self.text(t.el, get)
            if t.el.responds(to: set) { _ = t.el.perform(set, with: NSNumber(value: v != "1")) }
            if Self.text(t.el, get) != v { return .done }
        }
        // 스위치(AppKit NSSwitch·SwiftUI PlatformSwitch): 키 창이 아니면 첫 클릭을 '창 고르기'로 쓰므로, 클릭이 하는 일(상태 뒤집고 동작 보내기)을 그대로
        if let sw = t.el as? NSSwitch ?? (t.el as? NSView).flatMap({ v in
            func find(_ v: NSView) -> NSSwitch? { (v as? NSSwitch) ?? v.subviews.lazy.compactMap(find).first }
            return find(v)
        }) {
            sw.state = sw.state == .on ? .off : .on
            sw.sendAction(sw.action, to: sw.target)
            return .done
        }
        if let c = t.el as? NSControl, !"\(Swift.type(of: c))".contains("Switch") { c.performClick(nil); return .done } // AppKit 단추
        // 마지막: 창 직접 클릭(SwiftUI 스위치·도구 막대 탭·물방울 카드 등 손쉬운 사용 누름을 받지 않는 것) — 앱 활성화·커서 이동 없음
        directClick(w, NSPoint(x: t.frame.midX, y: t.frame.midY))
        return .done
    }

    // 창에 직접 누름·뗌(앱 활성화·커서 이동 없음). SwiftUI 의 실제 클릭 길(어느 뷰가 클릭을 받는가)을 그대로 탄다
    func directClick(_ w: NSWindow, _ sp: NSPoint) {
        let p = w.convertPoint(fromScreen: sp)
        func ev(_ k: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: k, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        guard let down = ev(.leftMouseDown), let up = ev(.leftMouseUp) else { return }
        NSApp.postEvent(up, atStart: true) // 누름이 뗌을 기다리며 추적하면 이걸 받고, 아니면 대기열에서 이 창으로 간다
        w.sendEvent(down)
    }

    // 실제 클릭 모드: 사용자가 쉬는 동안만(마지막 입력이 N분 넘었을 때). 입력이 생기면 앱을 숨기고 다시 한가해질 때까지 기다린다
    static var idleNeeded: Double { (Double(ProcessInfo.processInfo.environment["DROPCAP_CLICK_IDLE_MIN"] ?? "3") ?? 3) * 60 }
    static var idleSeconds: Double { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!) }
    func waitForIdle() async {
        guard Self.idleSeconds < Self.idleNeeded else { return }
        NSApp.hide(nil)
        r.note("[클릭] 사용자 입력이 있어 멈춤 — \(Int(Self.idleNeeded / 60))분 한가해질 때까지 기다림")
        while Self.idleSeconds < Self.idleNeeded { await r.sleep(5) }
        r.note("[클릭] 다시 시작")
    }

    // MARK: 누르기
    // 진짜 마우스 이벤트(이벤트 대기열에 누름·뗌). 앱이 앞에 오지 못하면 false(무효)
    func click(_ w: NSWindow, _ sp: NSPoint, right: Bool = false) async -> Bool {
        if !quiet { await waitForIdle() }
        NSApp.activate(ignoringOtherApps: true)
        if w.canBecomeKey { w.makeKeyAndOrderFront(nil) } else { w.orderFrontRegardless() }
        await r.until(2) { NSApp.isActive && (w.isKeyWindow || !w.canBecomeKey) }
        guard NSApp.isActive else { return false }
        let p = w.convertPoint(fromScreen: sp)
        let kinds: [NSEvent.EventType] = right ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp]
        for k in kinds {
            if let e = NSEvent.mouseEvent(with: k, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                NSApp.postEvent(e, atStart: false)
            }
        }
        return true
    }
    func key(_ w: NSWindow, _ chars: String, code: UInt16) {
        for k in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: k, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                        isARepeat: false, keyCode: code) {
                if quiet { if k == .keyDown { w.sendEvent(e) } } else { NSApp.postEvent(e, atStart: false) } // 조용한 모드: 창에 바로(앱을 앞으로 안 띄움)
            }
        }
    }

    // 그 자리를 실제로 맞는 손쉬운 사용 요소가 이 단추(또는 그 안)인가
    func hitCheck(_ w: NSWindow, _ t: Target, at point: NSPoint? = nil) -> (ok: Bool, what: String) {
        let sp = point ?? NSPoint(x: t.frame.midX, y: t.frame.midY)
        if let v = t.el as? NSView { // AppKit 줄: 그 자리를 맞는 뷰가 그 줄(또는 그 안)인가
            let hv = w.contentView?.superview?.hitTest(w.convertPoint(fromScreen: sp))
            var x = hv; while let y = x { if y === v { return (true, "그 줄") }; x = y.superview }
            return (hv.map { $0 is NSTableView || $0.isDescendant(of: v) } ?? false, "맞은 뷰 \(hv.map { "\(Swift.type(of: $0))" } ?? "없음")")
        }
        // 창 → 내용 뷰 순으로 물어 가장 깊은 요소를(틀 뷰에 물으면 창 자신이 돌아온다)
        let cands: [Any?] = [w.accessibilityHitTest(sp), w.contentView?.accessibilityHitTest(sp)]
        guard let hit = cands.compactMap({ $0 }).first(where: { Self.role($0 as AnyObject) != "AXWindow" }) ?? cands.compactMap({ $0 }).first else { return (true, "알 수 없음") }
        var el: AnyObject? = hit as AnyObject
        var n = 0
        while let o = el, n < 12 {
            if o === t.el { return (true, n == 0 ? "그 단추" : "그 단추 안") }
            el = (o.accessibilityParent?() ?? nil) as AnyObject?
            n += 1
        }
        let h = hit as AnyObject
        let hf = h.accessibilityFrame?() ?? .zero
        // 맞은 것이 이 단추를 품은 상위(묶음·창)이면 SwiftUI 가 더 깊이 알려 주지 않는 것 — 덮였다고 볼 수 없다
        var up: AnyObject? = t.el
        for _ in 0..<12 {
            guard let o = up else { break }
            if o === h { return (true, "상위만 맞음(\(Self.role(h)))") }
            up = (o.accessibilityParent?() ?? nil) as AnyObject?
        }
        // 이름·자리가 같은 요소(SwiftUI 가 요소를 새로 만든 경우)는 같은 것으로 본다
        if Self.name(h) == t.label, abs(hf.midX - t.frame.midX) < 2, abs(hf.midY - t.frame.midY) < 2 { return (true, "같은 자리 같은 이름") }
        return (false, "덮음: \(Self.role(h)) '\(Self.name(h))' \(ix(hf.width))×\(ix(hf.height))")
    }

    // 눌러서 연 것 정리(메뉴·모달·새 창)
    func cleanup(keep: Set<String>) async {
        if let m = menuTracked { m.cancelTracking(); menuTracked = nil; await r.sleep(0.2) }
        if let mw = NSApp.modalWindow { NSApp.stopModal(withCode: .cancel); mw.orderOut(nil); await r.sleep(0.2) }
        for w in NSApp.windows where w.isVisible && !keep.contains("\(ObjectIdentifier(w).hashValue)|\(w.title)") {
            let cls = "\(Swift.type(of: w))"
            if cls.contains("StatusBar") || cls.contains("ToastPanel") { continue }
            if cls.contains("Popover") || cls.contains("MenuBarExtra") { key(w, "\u{1b}", code: 53); await r.sleep(0.2) }
            if w.isVisible { w.close() }
        }
        await r.sleep(0.2)
    }

    // MARK: 한 화면 훑기
    // window: 그 화면의 창 · prepare: 매 클릭 전에 화면을 기준 상태로(지면 되돌리기 등) · within: 이 영역 안의 것만(화면 좌표)
    func sweep(_ screen: String, config: String, window: () -> NSWindow?, prepare: (() async -> Void)? = nil,
               within: ((NSWindow) -> NSRect)? = nil, skip: (Target) -> Bool = { _ in false }, limit: Int = 400, warp: Bool = false,
               reset: (() async -> Void)? = nil) async {
        await prepare?()
        if let w = window() { _ = await findTargets(w); await r.sleep(1.0) } // 첫 요청에 나무를 만들기 시작하므로 한 번 묻고 기다린다
        guard let w0 = window() else {
            rows.append(Row(screen: screen, config: config, label: "(창)", role: "-", result: "실패", effect: "창을 찾지 못함", hit: "-", at: "-"))
            return
        }
        dump(w0, "\(screen)-\(config)")
        // 공통 요소(카드·칩·목록 줄·옆 목록 줄)는 형마다 앱 전체에서 대표 1개만. 이 지면에서 두 번 이상 나오거나 앞 지면에서 이미 본 형이면 공통.
        // 한 번만 나오는 단추는 지면 고유로 보고 이름까지 열쇠에 넣어 각각 검사한다.
        let all = targets(w0, within: within?(w0))
        var onPage: [String: Int] = [:]
        let keys = all.map { Self.typeKey($0) }
        for k in keys { onPage[k, default: 0] += 1 }
        var list: [Target] = []
        for (t, k0) in zip(all, keys) {
            // 이름이 긴 것(기사 카드·목록 줄: 제목·'n분 전'이 섞임)은 내용이지 단추 이름이 아니므로 언제나 모양으로만 묶는다
            let common = onPage[k0]! >= 2 || typeReps[k0] != nil || t.label.count > 24
            let k = common ? k0 : k0 + "|" + t.label
            typeCounts[k, default: 0] += 1
            if let rep = typeReps[k] {
                rows.append(Row(screen: screen, config: config, label: t.label, role: t.role, result: "같은 형", effect: "대표: \(rep)", hit: "-", at: "-"))
                continue
            }
            typeReps[k] = "\(screen)/\(config) '\(t.label.prefix(30))'"
            list.append(t)
        }
        let frame0 = w0.frame
        r.note("[클릭] \(screen) · \(config): 누를 것 \(list.count)개(전체 \(all.count)개 중 대표) · 앞 앱 \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
        var i = 0
        while i < min(list.count, limit) {
            await prepare?()
            if window() == nil { await r.sleep(0.8); await prepare?() }
            guard let w = window() else {
                rows.append(Row(screen: screen, config: config, label: list[i].label, role: list[i].role, result: "실패", effect: "창을 다시 열지 못함", hit: "-", at: "-"))
                i += 1; continue
            }
            // 기준 상태에서 다시 찾는다(SwiftUI 가 요소를 새로 만들 수 있음) — 같은 순번·이름
            var now = targets(w, within: within?(w))
            // 게으른 묶음(카드 격자)은 늦게 생긴다 — 같은 이름 또는 같은 제목 조각이 나올 때까지 3초까지
            let titleKey = list[i].label.components(separatedBy: ", ").max(by: { $0.count < $1.count }) ?? ""
            var tries = 0
            while tries < 10, !now.contains(where: { $0.label == list[i].label || (titleKey.count >= 8 && $0.label.contains(titleKey)) }) {
                await r.sleep(0.3); now = targets(w, within: within?(w)); tries += 1
            }
            // 그래도 없으면 창을 새로 열어(칩 거르기 같은 화면 안 상태를 비움) 한 번 더
            if let reset, !now.contains(where: { $0.label == list[i].label || (titleKey.count >= 8 && $0.label.contains(titleKey)) }) {
                await reset(); await prepare?()
                if let w2 = window() { now = targets(w2, within: within?(w2)) }
            }
            // 창이 다른 자리에 다시 열릴 수 있어(상단바 창) 창 안 상대 위치로 맞춘다
            let rel = { (f: NSRect, win: NSRect) in NSPoint(x: f.midX - win.minX, y: f.midY - win.minY) }
            let want = rel(list[i].frame, frame0)
            guard let t = now.first(where: { $0.label == list[i].label && abs(rel($0.frame, w.frame).x - want.x) < 4 && abs(rel($0.frame, w.frame).y - want.y) < 4 })
                    ?? now.first(where: { $0.label == list[i].label && $0.role == list[i].role && !list[i].label.isEmpty })
                    // 목록 줄은 이름에 '방금→1분 전'·읽음 표시가 섞이고 자리도 바뀐다 → 이름에서 가장 긴 조각(제목)으로
                    ?? { let key = list[i].label.components(separatedBy: ", ").max(by: { $0.count < $1.count }) ?? ""
                         return key.count >= 8 ? now.first(where: { $0.role == list[i].role && $0.label.contains(key) }) : nil }()
                    // 그래도 없으면 같은 역할·같은 자리
                    ?? now.first(where: { $0.role == list[i].role && abs(rel($0.frame, w.frame).x - want.x) < 6 && abs(rel($0.frame, w.frame).y - want.y) < 6 }) else {
                rows.append(Row(screen: screen, config: config, label: list[i].label, role: list[i].role, result: "실패", effect: "기준 상태에서 다시 찾지 못함", hit: "-", at: "-"))
                i += 1; continue
            }
            let at = w.convertPoint(fromScreen: NSPoint(x: t.frame.midX, y: t.frame.midY))
            let atStr = "\(ix(at.x)),\(ix(w.frame.height - at.y)) 창\(ix(w.frame.minX)),\(ix(w.frame.minY))"
            if skip(t) {
                rows.append(Row(screen: screen, config: config, label: t.label, role: t.role, result: "건너뜀", effect: "의도적으로 누르지 않음", hit: "-", at: atStr))
                i += 1; continue
            }
            var hit = hitCheck(w, t)
            if quiet { // 여러 점에서: 이웃 사진 넘침 같은 덮개는 가운데가 아닌 귀퉁이에서만 걸리기도 한다
                for p in hitPoints(t).dropFirst() {
                    let h = hitCheck(w, t, at: p)
                    if !h.ok { hit = (false, h.what + " @귀퉁이"); break }
                }
            }
            let keep = Set(NSApp.windows.filter(\.isVisible).map { "\(ObjectIdentifier($0).hashValue)|\($0.title)" })
            // 앞 클릭의 움직임(카드 선택 효과·사진 나타남)이 끝난 뒤에 재고, 누른 뒤에도 멈출 때까지 기다려 비교한다
            // (예전엔 움직이는 중이면 그림 변화를 아예 무시해, 눌린 카드를 '아무 일 없음'으로 적었다)
            let stableBefore = await settledImage(w)
            var before = fingerprint(w); before.image = stableBefore
            menuTracked = nil
            let wasSelected = (t.table.map { tv in t.row.map { tv.selectedRowIndexes.contains($0) } ?? false } ?? false)
                || (t.el.isAccessibilitySelected?() ?? false)
                || (w.toolbar.flatMap { tb in tb.items.first { $0.itemIdentifier == tb.selectedItemIdentifier }?.label } == t.label) // 지금 고른 도구 막대 탭
            var valid = true
            var pressNote: String?
            if quiet {
                switch await press(w, t) {
                case .done: break
                case .skipped(let why): pressNote = why
                case .failed(let why): pressNote = "누름 실패: " + why
                }
            } else {
                if warp, ProcessInfo.processInfo.environment["DROPCAP_TEST_WARP"] != nil, let scr = NSScreen.screens.first { // 진짜 커서 이동은 따로 켤 때만
                    CGWarpMouseCursorPosition(CGPoint(x: t.frame.midX, y: scr.frame.maxY - t.frame.midY)); await r.sleep(0.3)
                }
                valid = await click(w, NSPoint(x: t.frame.midX, y: t.frame.midY), right: false)
                if !valid { await r.sleep(2); valid = await click(w, NSPoint(x: t.frame.midX, y: t.frame.midY)) }
            }
            await r.sleep(0.6)
            await settleCheck()
            let wa = w.isVisible ? w : (window() ?? w)
            var after = fingerprint(wa)
            after.image = await settledImage(wa)
            let animating = stableBefore == nil || after.image == nil
            var e = effects(before, after, animating: animating)
            if e.isEmpty, wasSelected { e.append("이미 고른 것(눌러도 그대로)") } // 누르기 전에 이미 골라져 있던 것만
            if e.isEmpty, ["AXTextField", "AXSearchField"].contains(t.role), (w.firstResponder as? NSTextView)?.isFieldEditor == true {
                e.append("초점(이미 이 칸)") // 이미 초점이 있던 칸은 바뀌는 것이 없다
            }
            // 맞음 검사(조용한 모드): 같은 자리에 창 직접 클릭을 보내 실제로 그 단추가 받는지(덮개가 가로채면 아무 일 없음)
            var clickNote = ""
            // 스위치는 키 창이 아니면 첫 클릭을 '창 고르기'로 써서 직접 클릭 검사가 맞지 않는다 → 손쉬운 사용 맞음만
            if quiet, pressNote == nil, !e.isEmpty, !["AXTextField", "AXSearchField", "AXCheckBox", "AXSwitch", "AXToggle"].contains(t.role), t.table == nil {
                await cleanup(keep: keep)
                await prepare?()
                if let w2 = window(), let t2 = targets(w2, within: within?(w2)).first(where: { $0.label == t.label && $0.role == t.role }) ?? Optional(t) {
                    let b2 = await settledImage(w2)
                    var pb = fingerprint(w2); pb.image = b2
                    menuTracked = nil
                    directClick(w2, NSPoint(x: t2.frame.midX, y: t2.frame.midY))
                    await r.sleep(0.6)
                    await settleCheck()
                    let w3 = w2.isVisible ? w2 : (window() ?? w2)
                    var pa = fingerprint(w3); pa.image = await settledImage(w3)
                    var e2 = effects(pb, pa, animating: b2 == nil || pa.image == nil)
                    // 지면을 새로 그린 직후엔 첫 직접 클릭이 가끔 빈다(스크랩북 폴더 칩: 범위 순회는 통과·전체 순회에서만 한 번씩) —
                    // 한 번 더 눌러 보고 그래도 아무 일 없을 때만 덮개로 본다(진짜 덮개는 두 번째도 닿지 않음)
                    if e2.isEmpty && !wasSelected, let w4 = window() {
                        await r.sleep(0.8)
                        let b4 = await settledImage(w4)
                        var pb4 = fingerprint(w4); pb4.image = b4
                        directClick(w4, NSPoint(x: t2.frame.midX, y: t2.frame.midY))
                        await r.sleep(0.6)
                        await settleCheck()
                        let w5 = w4.isVisible ? w4 : (window() ?? w4)
                        var pa4 = fingerprint(w5); pa4.image = await settledImage(w5)
                        e2 = effects(pb4, pa4, animating: b4 == nil || pa4.image == nil).map { $0 + "(두 번째 직접 클릭)" }
                    }
                    if e2.isEmpty && !wasSelected { hit = (false, "직접 클릭이 닿지 않음(덮개가 가로챔?) — 누름은 됨"); clickNote = " · 직접 클릭: 아무 일 없음" }
                    else { clickNote = " · 직접 클릭: " + (e2.isEmpty ? "그대로(이미 고른 것)" : e2.joined(separator: "·")) }
                }
            }
            e = e.isEmpty ? e : e.map { $0 } + (clickNote.isEmpty ? [] : [String(clickNote.dropFirst(3))])
            let result: String
            if !valid { result = "무효" }
            else if !hit.ok { result = "실패" }
            else if let n = pressNote, n.hasPrefix("메뉴") { result = "통과(맞음만)"; e.append(n) }
            else if let n = pressNote, e.isEmpty { result = "실패"; e.append(n) }
            else if let n = pressNote { result = "통과"; e.append("(\(n) — 그래도 일어남)") }
            else if e.isEmpty { result = "실패" }
            else { result = "통과" }
            rows.append(Row(screen: screen, config: config, label: t.label, role: t.role, result: result,
                            effect: valid ? (e.isEmpty ? "아무 일 없음" : e.joined(separator: " · ")) : "앱이 앞에 오지 못함(비활성)",
                            hit: hit.what, at: atStr))
            if result == "실패" {
                if let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: r.out.appendingPathComponent("shots/click-fail-\(screen)-\(config)-\(i).png"))
                }
            }
            r.note("  [\(result)] \(screen)/\(config) '\(t.label)' \(t.role) @\(atStr) · \(rows.last!.effect) · \(hit.what)")
            await cleanup(keep: keep)
            save()
            i += 1
        }
    }

    func appendRow(_ row: Row) { rows.append(row) }

    func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
        if let d = try? enc.encode(rows) { try? d.write(to: r.out.appendingPathComponent("results-clicks.json")) }
        var md = "| 화면 | 설정 | 항목 | 역할 | 결과 | 일어난 일 | 맞은 것 | 좌표 |\n|---|---|---|---|---|---|---|---|\n"
        func c(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
        for x in rows { md += "| \(x.screen) | \(x.config) | \(c(x.label)) | \(x.role) | \(x.result) | \(c(x.effect)) | \(c(x.hit)) | \(x.at) |\n" }
        let n = { (s: String) in self.rows.filter { $0.result == s }.count }
        md += "\n통과 \(n("통과")) · 맞음만 확인(메뉴) \(n("통과(맞음만)")) · 실패 \(n("실패")) · 무효 \(n("무효")) · 같은 형(대표만 검사) \(n("같은 형")) · 건너뜀 \(n("건너뜀"))\n"
        md += "\n## 형 목록(형 열쇠 → 대표 · 앱 전체에서 나온 수)\n\n| 형 | 대표 | 수 |\n|---|---|---|\n"
        for (k, v) in typeReps.sorted(by: { $0.key < $1.key }) { md += "| \(c(k)) | \(c(v)) | \(typeCounts[k] ?? 0) |\n" }
        try? md.write(to: r.out.appendingPathComponent("CLICKS-run.md"), atomically: true, encoding: .utf8)
    }
}

#endif
