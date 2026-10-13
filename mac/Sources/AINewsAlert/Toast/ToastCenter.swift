import AppKit
import SwiftUI

// 상단바 바로 아래 오른쪽에 떠 있는 투명한 패널 하나에 물방울 알림을 쌓는다.
// 카드가 없는 곳은 클릭이 뒤쪽 앱으로 그대로 지나간다.
struct Toast: Identifiable, Equatable {
    enum Kind: Equatable { case news(NewsItem), info(String, String), more(Int), digest(Int) }
    let id = UUID()
    let kind: Kind
    var playSound = false

    @MainActor var accent: Color {
        if case .news(let it) = kind { return it.accent }
        return Color.accentColor
    }
}

@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()
    static let panelWidth: CGFloat = 400
    static let panelHeight: CGFloat = 600

    @Published var toasts: [Toast] = []
    @Published var hoveredID: UUID?   // 커서 아래 카드
    @Published var notchMode = false // 가운데 노치에서 떨어질 때는 물방울이 노치처럼 검게 시작한다
    var cardFrames: [UUID: CGRect] = [:] // 패널 안 좌표(위쪽 원점)

    private var panel: ToastPanel?
    private var panelScreen: NSScreen?
    private var screenObserver: NSObjectProtocol?
    private var otherScreenSince: Date?
    private var moving = false
    private var mouseTimer: Timer?
    private let maxVisible = 4

    func show(_ items: [NewsItem], sound: Bool) {
        let cards = items.prefix(3).map { Toast(kind: .news($0)) }
        var queue = Array(cards)
        if items.count > 3 { queue.append(Toast(kind: .more(items.count - 3))) }
        if !queue.isEmpty, sound { queue[0].playSound = true }
        // 여러 건이면 조금씩 시간차를 두고 하나씩 떨어뜨린다
        for (i, t) in queue.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.32) { self.push(t) }
        }
    }

    func showInfo(_ title: String, sub: String) { push(Toast(kind: .info(title, sub))) }

    func showDigest(count: Int) {
        var t = Toast(kind: .digest(count))
        t.playSound = AppModel.shared.state.settings.sound
        push(t)
    }

    func showWelcome() {
        showInfo("AI News Alert 실행 중", sub: "새 AI 소식이 오면 이렇게 상단바에서 떨어집니다")
    }

    private func push(_ t: Toast) {
        ensurePanel()
        withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
            toasts.insert(t, at: 0)
        }
        while toasts.count > maxVisible, let last = toasts.last {
            remove(last.id)
        }
    }

    func remove(_ id: UUID) {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
            toasts.removeAll { $0.id == id }
        }
        cardFrames.removeValue(forKey: id)
        if hoveredID == id { hoveredID = nil }
        if toasts.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.toasts.isEmpty else { return }
                self.panel?.orderOut(nil)
                self.mouseTimer?.invalidate()
                self.mouseTimer = nil
            }
        }
    }

    func open(_ t: Toast) {
        switch t.kind {
        case .news(let item): AppModel.shared.open(item)
        case .digest: DigestController.open()
        default: break
        }
    }

    // MARK: 패널
    private func ensurePanel() {
        if panel == nil {
            let p = ToastPanel(contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight))
            let host = NSHostingView(rootView: ToastStack().environmentObject(self))
            host.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight)
            p.contentView = host
            panel = p
        }
        guard let panel else { return }
        if !panel.isVisible || panelScreen != Self.cursorScreen() {
            place(panel) // 새 알림은 언제나 마우스가 있는 화면에
            panel.alphaValue = 1
            panel.orderFrontRegardless() // 지금 쓰던 앱의 입력 초점은 빼앗지 않는다
        }
        if screenObserver == nil {
            // 모니터를 꽂거나 빼거나 해상도를 바꾸면 자리를 다시 잡는다
            screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let p = self.panel, p.isVisible else { return }
                    self.place(p)
                }
            }
        }
        if mouseTimer == nil {
            let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateMousePassThrough() }
            }
            RunLoop.main.add(t, forMode: .common)
            mouseTimer = t
        }
    }

    // 시험용: 패널 화면을 PNG 로 저장(화면 캡처 권한 없이 확인할 때)
    func snapshot(to path: String) {
        guard let view = panel?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    // 기본은 화면 위쪽 정가운데(노치가 있으면 노치에서 떨어짐). 설정에서 오른쪽 위로 바꿀 수 있다
    static func cursorScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func place(_ panel: NSPanel) {
        let screen = Self.cursorScreen()
        panelScreen = screen
        let vf = screen.visibleFrame // 상단바 아래부터
        let hasNotch = screen.safeAreaInsets.top > 0
        let center = AppModel.shared.state.settings.position == .center
        notchMode = center && hasNotch
        let x = center ? screen.frame.midX - Self.panelWidth / 2 : vf.maxX - Self.panelWidth - 2
        panel.setFrame(NSRect(x: x, y: vf.maxY - Self.panelHeight, width: Self.panelWidth, height: Self.panelHeight), display: false)
    }

    // 카드 위에 마우스가 있을 때만 패널이 클릭을 받는다
    private func updateMousePassThrough() {
        guard let panel, panel.isVisible else { return }
        followCursorScreen(panel)
        let p = NSEvent.mouseLocation
        let local = NSPoint(x: p.x - panel.frame.minX, y: panel.frame.maxY - p.y)
        let hit = cardFrames.first { $0.value.insetBy(dx: -10, dy: -10).contains(local) }?.key
        let inside = hit != nil
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        if hoveredID != hit { hoveredID = hit } // 카드의 '마우스 올림' 상태는 여기서만 정한다
    }

    // 알림이 떠 있는 동안 마우스가 다른 화면으로 가서 잠시 머물면, 카드가 살짝 사라졌다가 그 화면에 다시 나타난다
    private func followCursorScreen(_ panel: NSPanel) {
        guard !moving, !toasts.isEmpty else { return }
        let target = Self.cursorScreen()
        guard target != panelScreen else { otherScreenSince = nil; return }
        if otherScreenSince == nil { otherScreenSince = Date(); return }
        guard Date().timeIntervalSince(otherScreenSince!) > 0.25 else { return }
        otherScreenSince = nil
        moving = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                self.place(panel)
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.2
                    panel.animator().alphaValue = 1
                }, completionHandler: { MainActor.assumeIsolated { self.moving = false } })
            }
        })
    }
}

final class ToastPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
