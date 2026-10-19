import AppKit
import Foundation

// 시험 장치(M9): 디버그 빌드(swift build·swift test·e2e·clicksweep)에만 들어간다. 배포 빌드(build.sh, -c release)에는 없음.
#if DEBUG

// 설정이 실제 동작에 반영되는지(scripts/e2e/settings.sh). DROPCAP_TEST_E2E_PHASE=settings 일 때,
// 그리고 시나리오 main 의 설정 상호작용(E2ESettings) 끝에서도 돈다. 값 저장·다시 켜기 유지는 swift test(SettingsQATests)가 본다.
@MainActor
enum E2ESettingsEffects {
    static func run(_ r: E2ERun) async {
        if r.phase == "settings" { OnboardingController.close() } // 따로 돌 때: 첫 실행 고르기 창은 치움
        await position(r)
    }

    // S1) 알림 위치: 바꾸면 다음 알림(미리 보기 포함)부터 곧바로 그 자리 — 앞 알림이 아직 떠 있어도
    static func position(_ r: E2ERun) async {
        let m = r.model, saved = m.state.settings.position, style = m.state.settings.style
        defer { m.update { $0.position = saved; $0.style = style } }
        m.update { $0.style = .drop; $0.position = .center }
        m.preview()
        await r.sleep(1)
        let screen = ToastCenter.cursorScreen()
        let c = ToastCenter.shared.panelFrame
        m.update { $0.position = .right }
        m.preview() // 앞 미리 보기가 아직 떠 있는 동안(사용자가 바꾸고 바로 눌러 보는 순서)
        await r.sleep(1)
        let right1 = ToastCenter.shared.panelFrame
        // 다 사라진 뒤의 다음 알림
        await r.until(30) { ToastCenter.shared.panelFrame == nil }
        m.preview()
        await r.sleep(1)
        let right2 = ToastCenter.shared.panelFrame
        m.update { $0.position = .center }
        m.preview()
        await r.sleep(1)
        let back = ToastCenter.shared.panelFrame
        func at(_ f: NSRect?) -> String {
            guard let f, let s = screen else { return "없음" }
            if abs(f.midX - s.frame.midX) < 2 { return "가운데" }
            if abs(f.maxX - (s.visibleFrame.maxX - 2)) < 2 { return "오른쪽" }
            return "x \(Int(f.minX))"
        }
        let got = [c, right1, right2, back].map(at)
        r.record("S1", "알림 위치 바꾸면 다음 알림부터 그 자리",
                 expected: "가운데 → (떠 있는 중에) 오른쪽 → (다 사라진 뒤) 오른쪽 → 가운데",
                 actual: got.joined(separator: " → "),
                 pass: got == ["가운데", "오른쪽", "오른쪽", "가운데"])
        await r.until(30) { ToastCenter.shared.panelFrame == nil }
    }
}

#endif
