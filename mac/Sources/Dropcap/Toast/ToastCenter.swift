import AppKit
import SwiftUI

// 상단바 바로 아래 오른쪽에 떠 있는 투명한 패널 하나에 물방울 알림을 쌓는다.
// 카드가 없는 곳은 클릭이 뒤쪽 앱으로 그대로 지나간다.
struct Toast: Identifiable, Equatable {
    enum Kind: Equatable { case news(NewsItem), info(String, String), more(Int), digest(Int), bundle(String, [NewsItem]), watch(String, [NewsItem]) }
    let id = UUID()
    let kind: Kind
    var playSound = false
    var quickDrop = false   // 여러 건일 때 두 번째부터: 맺히는 단계를 건너뛰고 바로 떨어짐

    @MainActor var accent: Color {
        if case .news(let it) = kind { return it.accent }
        return Color.accentColor
    }
}

@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()
    nonisolated static let panelWidth: CGFloat = 400
    nonisolated static let panelHeight: CGFloat = 600

    @Published var toasts: [Toast] = []
    @Published var hoveredID: UUID?   // 커서 아래 카드
    @Published var notchMode = false // 가운데 노치에서 떨어질 때는 물방울이 노치처럼 검게 시작한다
    var cardFrames: [UUID: CGRect] = [:] // 패널 안 좌표(위쪽 원점)

    private var panel: ToastPanel?
    private var panelScreen: NSScreen?
    private var placedAt: AppState.Settings.Position? // 패널을 마지막으로 놓을 때의 위치 설정
    private var screenObserver: NSObjectProtocol?
    private var mouseTimer: Timer?
    private let maxVisible = 4

    func show(_ items: [NewsItem], sound: Bool) {
        let cards = items.prefix(3).map { Toast(kind: .news($0)) }
        var queue = Array(cards)
        if items.count > 3 { queue.append(Toast(kind: .more(items.count - 3))) }
        if !queue.isEmpty, sound { queue[0].playSound = true }
        for i in queue.indices.dropFirst() { queue[i].quickDrop = true }
        // 여러 건이면 조금씩 시간차를 두고 하나씩 떨어뜨린다
        for (i, t) in queue.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.32) { self.push(t) }
        }
    }

    func showInfo(_ title: String, sub: String) { push(Toast(kind: .info(title, sub))) }

    // 지켜볼 낱말 하루 정리("오늘 ○○ 소식 3건")
    func showWatch(word: String, items: [NewsItem]) {
        guard !items.isEmpty else { return }
        var t = Toast(kind: .watch(word, items))
        t.playSound = AppModel.shared.state.settings.sound
        push(t)
    }

    func showDigest(count: Int) {
        var t = Toast(kind: .digest(count))
        t.playSound = AppModel.shared.state.settings.sound
        push(t)
    }

    // 묶음: 고였던 분야 소식을 한 방울로("경제 7건")
    func showBundle(section: String, items: [NewsItem]) {
        guard !items.isEmpty else { return }
        var t = Toast(kind: .bundle(section, items))
        t.playSound = AppModel.shared.state.settings.sound
        push(t)
    }

    func showWelcome() {
        showInfo("Dropcap 실행 중", sub: "새 소식이 오면 이렇게 상단바에서 떨어집니다")
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
        case .digest: MagazineController.open()
        case .bundle(let sec, _): MagazineController.open(page: .section(sec))
        case .watch(let word, _): MagazineController.search(word)
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
        guard let panel, Self.cursorScreen() != nil else { return } // 화면이 하나도 없으면(덮개 닫힘 등) 띄우지 않음
        if Self.needsPlace(visible: panel.isVisible, placedAt: placedAt, wanted: AppModel.shared.state.settings.position) {
            place(panel) // 새로 뜨는 알림은 마우스가 있는 화면에, 지금 설정한 위치에
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

    // 시험용: 떠 있는 패널의 자리(안 보이면 nil)
    var panelFrame: NSRect? { panel?.isVisible == true ? panel?.frame : nil }

    // 시험용: 패널 화면을 PNG 로 저장(화면 캡처 권한 없이 확인할 때)
    func snapshot(to path: String) {
        guard let view = panel?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    // 기본은 화면 위쪽 정가운데(노치가 있으면 노치에서 떨어짐). 설정에서 오른쪽 위로 바꿀 수 있다
    static func cursorScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    // 패널을 다시 놓을지: 숨어 있었거나 위치 설정이 놓을 때와 달라졌으면.
    // (예전엔 위치 설정을 보지 않아 알림이 떠 있는 동안 '오른쪽 위'로 바꾸면 다음 알림도 가운데에 떨어졌다)
    // 마우스가 다른 화면으로 가도 이미 뜬 알림은 처음 화면에 둔다 — 그동안 오는 새 알림도 같은 패널(그 화면)에 쌓인다.
    // 화면이 빠지거나 해상도가 바뀔 때만 screenObserver 가 다시 놓는다.
    nonisolated static func needsPlace(visible: Bool, placedAt: AppState.Settings.Position?, wanted: AppState.Settings.Position) -> Bool {
        !visible || placedAt != wanted
    }

    // 화면과 위치 설정에 맞는 패널 자리. 가운데는 화면 정가운데(노치 아래), 오른쪽은 상단바 아래 오른쪽 끝에서 2pt 안쪽
    nonisolated static func panelRect(screen: NSRect, visible vf: NSRect, position: AppState.Settings.Position) -> NSRect {
        let x = position == .center ? screen.midX - panelWidth / 2 : vf.maxX - panelWidth - 2
        return NSRect(x: x, y: vf.maxY - panelHeight, width: panelWidth, height: panelHeight)
    }

    // 패널을 놓을 화면: 이미 떠 있으면 그 화면(아직 꽂혀 있으면), 새로 뜨면 마우스가 있는 화면
    nonisolated static func chooseScreen<S: Equatable>(visible: Bool, current: S?, screens: [S], cursor: S?) -> S? {
        if visible, let current, screens.contains(current) { return current }
        return cursor
    }

    private func place(_ panel: NSPanel) {
        guard let screen = Self.chooseScreen(visible: panel.isVisible, current: panelScreen, screens: NSScreen.screens, cursor: Self.cursorScreen()) else { return }
        let position = AppModel.shared.state.settings.position
        panelScreen = screen
        placedAt = position
        notchMode = position == .center && screen.safeAreaInsets.top > 0
        panel.setFrame(Self.panelRect(screen: screen.frame, visible: screen.visibleFrame, position: position), display: false)
    }

    // 카드 위에 마우스가 있을 때만 패널이 클릭을 받는다
    private func updateMousePassThrough() {
        guard let panel, panel.isVisible else { return }
        let p = NSEvent.mouseLocation
        let local = NSPoint(x: p.x - panel.frame.minX, y: panel.frame.maxY - p.y)
        let hit = cardFrames.first { $0.value.insetBy(dx: -10, dy: -10).contains(local) }?.key
        let inside = hit != nil
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        if hoveredID != hit { hoveredID = hit } // 카드의 '마우스 올림' 상태는 여기서만 정한다
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
