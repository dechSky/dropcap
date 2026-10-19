import AppKit
import Foundation
import Testing
@testable import Dropcap

// 설정 전수 점검: 값이 실제 동작에 반영되는지. 앱을 띄워 보는 쪽은 scripts/e2e/settings.sh(E2ESettingsEffects).
@Suite struct SettingsQATests {
    typealias Position = AppState.Settings.Position

    // 알림 위치: 떠 있는 패널도 위치 설정이 바뀌면 다음 알림에서 다시 놓는다(예전엔 숨었을 때·마우스 화면이 바뀔 때만)
    @Test func positionChangeReplacesVisiblePanel() {
        #expect(ToastCenter.needsPlace(visible: true, placedAt: .center, wanted: .right))
        #expect(ToastCenter.needsPlace(visible: true, placedAt: .right, wanted: .center))
        #expect(!ToastCenter.needsPlace(visible: true, placedAt: .right, wanted: .right))
        #expect(ToastCenter.needsPlace(visible: false, placedAt: .right, wanted: .right))
        #expect(ToastCenter.needsPlace(visible: true, placedAt: nil, wanted: .center))
    }

    // 이미 뜬 알림은 마우스를 따라 다른 화면으로 옮기지 않는다. 새로 뜰 때만 마우스 화면, 그 화면이 빠졌으면 마우스 화면
    @Test func shownPanelStaysOnItsScreen() {
        #expect(ToastCenter.chooseScreen(visible: true, current: 1, screens: [1, 2], cursor: 2) == 1)
        #expect(ToastCenter.chooseScreen(visible: false, current: 1, screens: [1, 2], cursor: 2) == 2)
        #expect(ToastCenter.chooseScreen(visible: true, current: 1, screens: [2], cursor: 2) == 2)
        #expect(ToastCenter.chooseScreen(visible: true, current: nil as Int?, screens: [1, 2], cursor: 2) == 2)
        // 떠 있는 동안 마우스가 다른 화면에 있어도 새 알림 때 다시 놓지 않는다(위치 설정이 같으면)
        #expect(!ToastCenter.needsPlace(visible: true, placedAt: .center, wanted: .center))
    }

    @Test func panelRectFollowsPosition() {
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982), vf = NSRect(x: 0, y: 0, width: 1512, height: 944)
        let c = ToastCenter.panelRect(screen: screen, visible: vf, position: .center)
        let r = ToastCenter.panelRect(screen: screen, visible: vf, position: .right)
        #expect(c.midX == screen.midX)
        #expect(r.maxX == vf.maxX - 2)
        #expect(c.maxY == vf.maxY && r.maxY == vf.maxY) // 둘 다 상단바 바로 아래
        // 두 번째 모니터(왼쪽에 놓인 화면)에서도 그 화면 기준
        let left = NSRect(x: -1920, y: 0, width: 1920, height: 1080), lvf = NSRect(x: -1920, y: 0, width: 1920, height: 1055)
        #expect(ToastCenter.panelRect(screen: left, visible: lvf, position: .right).maxX == -2)
    }

    // 고인 소식(묶음 대기열)도 설정을 따른다: '알리지 않음' 낱말 · 알림 끈 출처 · '매거진만' 분야는 묶음 시각에 나가지 않음
    @Test func pendingFollowsMuteBellAndMagazineOnly() {
        func pend(_ id: String, _ title: String, src: String, sec: String) -> AppState.PendingItem {
            .init(item: NewsItem(id: id, title: title, link: "", date: Date(), summary: "", sourceId: src, sourceName: src, tier: "media"),
                  section: sec, story: id, at: Date())
        }
        let all = [pend("a", "Chip prices rise", src: "s1", sec: "economy"),
                   pend("b", "주식 시장 마감", src: "s1", sec: "economy"),
                   pend("c", "Rate decision", src: "s2", sec: "economy"),
                   pend("d", "Election news", src: "s1", sec: "politics")]
        let kept = AppModel.prunePending(all, mute: AppModel.words(["주식"]), notifies: { $0 != "s2" }, magazineOnly: { $0 == "politics" })
        #expect(kept.map(\.item.id) == ["a"])
        // 아무것도 안 바뀌면 그대로
        #expect(AppModel.prunePending(all, mute: [], notifies: { _ in true }, magazineOnly: { _ in false }).count == 4)
    }
}
