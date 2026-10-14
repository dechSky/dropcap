import AppKit
import ObjectiveC

// 시험(DROPCAP_TEST_E2E)이 사용자 작업을 끊지 않게: 앱 활성화·Dock 아이콘·창 보이기를 막는다.
// - NSApp.activate(…)·NSRunningApplication.current.activate·setActivationPolicy(.regular)·unhide → 아무것도 안 함(기록만)
// - 창을 앞으로 보내는 모든 길(makeKeyAndOrderFront·orderFront·orderFrontRegardless·order) → 투명(alpha 0)·마우스 통과로 만든 뒤 보냄
//   (창은 '보이는' 상태라 그림·손쉬운 사용 나무·hitTest 는 그대로 쓸 수 있지만 사용자 화면에는 안 보이고 클릭도 안 받음)
// 실제 클릭을 쓸 때만(DROPCAP_TEST_REAL_UI=1) 끈다. 앱 코드는 고치지 않고 시험 실행에서만 메서드를 바꿔 끼운다.
enum E2EQuietUI {
    private(set) static var on = false
    nonisolated(unsafe) static var blocked: [String] = []   // 막은 활성화 시도(어디서 불렀는지 확인용)

    // 앱이 다 뜨기 전에(App.init): 실행 파일로 띄운 시험 앱이 켜지면서 앞 앱이 되지 않게 미리 상단바 앱으로 둔다
    static func installEarly() {
        guard E2EFeeds.active, ProcessInfo.processInfo.environment["DROPCAP_TEST_REAL_UI"] == nil else { return }
        _ = NSApplication.shared.setActivationPolicy(.accessory)
        install()
    }

    static func install() {
        guard E2EFeeds.active, ProcessInfo.processInfo.environment["DROPCAP_TEST_REAL_UI"] == nil, !on else { return }
        on = true
        swap(NSApplication.self, NSSelectorFromString("activateIgnoringOtherApps:"), NSSelectorFromString("e2e_activateIgnoringOtherApps:"))
        swap(NSApplication.self, NSSelectorFromString("activate"), NSSelectorFromString("e2e_activateNow"))
        swap(NSApplication.self, #selector(NSApplication.setActivationPolicy(_:)), #selector(NSApplication.e2e_setActivationPolicy(_:)))
        swap(NSApplication.self, #selector(NSApplication.unhide(_:)), #selector(NSApplication.e2e_unhide(_:)))
        swap(NSRunningApplication.self, #selector(NSRunningApplication.activate(options:)), #selector(NSRunningApplication.e2e_activate(options:)))
        swap(NSWindow.self, #selector(NSWindow.makeKeyAndOrderFront(_:)), #selector(NSWindow.e2e_makeKeyAndOrderFront(_:)))
        swap(NSWindow.self, #selector(NSWindow.orderFront(_:)), #selector(NSWindow.e2e_orderFront(_:)))
        swap(NSWindow.self, #selector(NSWindow.orderFrontRegardless), #selector(NSWindow.e2e_orderFrontRegardless))
        swap(NSWindow.self, #selector(NSWindow.order(_:relativeTo:)), #selector(NSWindow.e2e_order(_:relativeTo:))) // 다른 길(경고 창 등)로 보일 때도
        TestLog.write("[조용한 시험] 앱 활성화·창 보이기를 막음(창은 투명·마우스 통과·화면 밖)")
    }

    private static func swap(_ cls: AnyClass, _ a: Selector, _ b: Selector) {
        guard let m1 = class_getInstanceMethod(cls, a), let m2 = class_getInstanceMethod(cls, b) else {
            TestLog.write("[조용한 시험] 바꿔 끼우지 못함: \(cls).\(a)"); return
        }
        method_exchangeImplementations(m1, m2)
    }

    static func note(_ what: String) {
        if blocked.count < 200 { blocked.append(what) }
    }

    // 사용자 화면에 안 보이게: 투명·마우스 통과·그림자 없음
    static func hide(_ w: NSWindow) {
        w.animationBehavior = .none // 열기·닫기 변형 움직임 중에 투명하게 바꾸거나 닫으면 AppKit 이 죽었다(설정 창)
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        w.hasShadow = false
        // 화면 밖으로 옮기면 '가려진 창'이 되어 그림이 갱신되지 않는다(눌러도 바뀐 것을 못 봄) → 자리는 두고 투명·마우스 통과만
    }
}

extension NSApplication {
    @objc(e2e_activateIgnoringOtherApps:) func e2e_activateIgnoring(_ flag: Bool) { E2EQuietUI.note("NSApp.activate(ignoringOtherApps:)") }
    @objc(e2e_activateNow) func e2e_activateNow() { E2EQuietUI.note("NSApp.activate()") }
    @objc func e2e_setActivationPolicy(_ p: NSApplication.ActivationPolicy) -> Bool {
        E2EQuietUI.note("setActivationPolicy(\(p.rawValue))")
        return p == .regular ? true : e2e_setActivationPolicy(p) // .regular(Dock 아이콘)만 막는다
    }
    @objc func e2e_unhide(_ sender: Any?) { E2EQuietUI.note("unhide") }
}

extension NSRunningApplication {
    @objc func e2e_activate(options: NSApplication.ActivationOptions = []) -> Bool {
        if processIdentifier == ProcessInfo.processInfo.processIdentifier { E2EQuietUI.note("NSRunningApplication.activate"); return false }
        return e2e_activate(options: options)
    }
}

extension NSWindow {
    @objc func e2e_makeKeyAndOrderFront(_ sender: Any?) { E2EQuietUI.hide(self); e2e_orderFrontRegardless() } // 키 창도 되지 않게(입력을 받지 않음)
    @objc func e2e_orderFront(_ sender: Any?) { E2EQuietUI.hide(self); e2e_orderFront(sender) }
    @objc func e2e_orderFrontRegardless() { E2EQuietUI.hide(self); e2e_orderFrontRegardless() }
    @objc func e2e_order(_ place: NSWindow.OrderingMode, relativeTo other: Int) {
        if place != .out { E2EQuietUI.hide(self) }
        e2e_order(place, relativeTo: other)
    }
}
