import AppKit
import SwiftUI
import UserNotifications

@main
struct DropcapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
        } label: {
            // 안 읽은 소식이 있으면 채워진 아이콘
            Image(systemName: model.state.unread > 0 ? "newspaper.fill" : "newspaper")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    // 이름이 바뀌기 전 번들(io.github.neulloopa.ainewsalert)의 화면 설정(글꼴·정렬·스크랩 폴더 등)을 한 번 옮긴다
    static func migrateDefaults() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedFromAINewsAlert"), let old = UserDefaults(suiteName: "io.github.neulloopa.ainewsalert") else { return }
        for key in ["usePretendard", "readerFontSize", "magSort", "listSort", "scrapCollections", "lastScrapCollection"] {
            if d.object(forKey: key) == nil, let v = old.object(forKey: key) { d.set(v, forKey: key) }
        }
        d.set(true, forKey: "migratedFromAINewsAlert")
    }

    private var lockFD: Int32 = -1

    func applicationWillTerminate(_ notification: Notification) { Store.flush() } // 묶어 둔 저장을 끝내기 전에 바로 쓴다

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 이미 실행 중이면 끈다: 둘이 동시에 돌면 같은 소식을 두 번 알린다
        lockFD = open(Store.dir.appendingPathComponent("native.lock").path, O_CREAT | O_RDWR, 0o644)
        if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            NSLog("Dropcap 이 이미 실행 중이라 종료합니다")
            exit(0)
        }
        NSApp.setActivationPolicy(.accessory) // Dock 에 나타나지 않음
        Self.migrateDefaults()
        Typography.register()
        MainActor.assumeIsolated { SaveLink.install() } // 서비스 메뉴 'Dropcap 에 저장'
        if SystemNotifier.available { UNUserNotificationCenter.current().delegate = self }
        // 이름이 바뀌기 전 앱(AI News Alert)이 떠 있으면 같은 소식을 두 번 알리므로 끈다
        for old in NSRunningApplication.runningApplications(withBundleIdentifier: "io.github.neulloopa.ainewsalert") { old.terminate() }
        MainActor.assumeIsolated {
            AppModel.shared.start()
            SectionStartup.run() // 첫 실행 분야 고르기 + 시험 훅
            Integrations.start() // 위젯·Spotlight(Integrations/)
            // 시험용: DROPCAP_TEST_URL=<기사 주소> 면 읽기 창을, DROPCAP_TEST_TOAST=1 이면 알림 미리 보기를 바로 띄운다
            let env = ProcessInfo.processInfo.environment
            ReaderSaveTestHooks.run(env)
            ExtrasTestHooks.run(env) // 유료 표시·오늘 호·저녁 정리·사진 점수 시험(UI/ExtrasTestHooks.swift)
            if let u = env["DROPCAP_TEST_URL"] {
                ReaderController.open(NewsItem(id: u, title: u, titleKo: nil, link: u, date: Date(), summary: "", sourceId: "openai", sourceName: "시험", tier: "lab"))
                if let dir = env["DROPCAP_TEST_SHOT_DIR"] {
                    for sec in [3, 8, 20] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(sec)) {
                            guard let v = NSApp.windows.first(where: { $0.isVisible && $0.title == "시험" })?.contentView,
                                  let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                            v.cacheDisplay(in: v.bounds, to: rep)
                            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/reader-\(sec).png"))
                        }
                    }
                }
            }
            if let subs = env["DROPCAP_TEST_SUBSCRIBE"] { // 시험용: 추천 채널 구독
                Task { for id in subs.split(separator: ",") { if let s = ChannelCatalog.all.first(where: { $0.id == id }) { _ = await AppModel.shared.subscribe(s) } } }
            }
            if env["DROPCAP_TEST_SCRAP"] != nil { // 시험용: 견본 스크랩
                Task { try? await Task.sleep(for: .seconds(25))
                    let resolved = await Magazine.shared.today().sections.flatMap(\.items)
                    for it in resolved.prefix(3) {
                        Scrapbook.shared.add(it, quote: it.displayTitle + " — 핵심 문단 예시입니다.", original: it.title, memo: "보고서에 인용", to: "GPT 조사")
                        Scrapbook.shared.add(it, to: "GPT 조사")
                    }
                }
            }
            if env["DROPCAP_TEST_MENU"] != nil, let dir = env["DROPCAP_TEST_SHOT_DIR"] { // 시험용: 상단바 창을 일반 창에 띄워 찍기
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    let w = NSWindow(contentViewController: NSHostingController(rootView: MenuView()))
                    w.title = "menu-test"
                    w.appearance = NSAppearance(named: .darkAqua)
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    w.makeKeyAndOrderFront(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        if let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) { // 창 그대로(스크롤 목록 포함)
                            v.cacheDisplay(in: v.bounds, to: rep)
                            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/menu-win.png"))
                        }
                        if let st = env["DROPCAP_TEST_LISTSTYLE"] { UserDefaults.standard.set(st, forKey: "listStyle2") }
                        for it in AppModel.shared.state.recent { // 사진을 미리 받아 둠(화면 없이 그릴 때는 .task 가 돌지 않음)
                            if let u = [it.image, Magazine.shared.storedImage(it.key)].compactMap({ $0 }).first(where: { !ImageKey.isJunk($0) }),
                               let img = ImageLoader.shared.cachedImage(u) { RowThumb.preloaded[it.key] = img }
                        }
                        let r = ImageRenderer(content: MenuView(snapshot: true).environment(\.colorScheme, .dark).background(Color(white: 0.16)))
                        r.scale = 2
                        if let cg = r.cgImage {
                            try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/menu.png"))
                        }
                    }
                }
            }
            if env["DROPCAP_TEST_SETTINGS"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
            }
            if env["DROPCAP_TEST_MAGAZINE"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MagazineController.open() }
                if let dir = env["DROPCAP_TEST_SHOT_DIR"] {
                    func shot(_ name: String) {
                        guard let v = NSApp.windows.first(where: { $0.isVisible && $0.title == "Dropcap" })?.contentView,
                              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                        v.cacheDisplay(in: v.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
                    }
                    // 가장 긴 스크롤 영역(지면)을 찾아 아래로 내려 가며 찍는다
                    func scroll(to y: CGFloat) {
                        func all(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? [] + v.subviews.flatMap(all) }
                        guard let root = NSApp.windows.first(where: { $0.title == "Dropcap" })?.contentView,
                              let sv = all(root).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }) else { return }
                        sv.contentView.scroll(to: NSPoint(x: 0, y: y))
                        sv.reflectScrolledClipView(sv.contentView)
                    }
                    for sec in [4, 12, 40] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(sec)) { shot("mag-\(sec)") }
                    }
                    for (i, y) in [700, 1400, 2100, 2800, 3500, 4200].enumerated() {
                        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(42 + i * 2)) { scroll(to: CGFloat(y)) }
                        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(43 + i * 2)) { shot("scroll-\(y)") }
                    }
                }
            }
            if let u = env["DROPCAP_TEST_IMAGE"] { // 시험용: 사진 하나를 안전 로더로 받아 결과를 기록
                Task {
                    do {
                        let data = try await FeedService.shared.fetch(u)
                        NSLog("[사진 시험] 받음 %d바이트", data?.count ?? -1)
                    } catch { NSLog("[사진 시험] 받기 실패: %@", String(describing: error)) }
                    let img = await ImageLoader.shared.image(u)
                    NSLog("[사진 시험] 로더 결과: %@", img.map { "\($0.size)" } ?? "nil")
                }
            }
            if env["DROPCAP_TEST_BURST"] != nil { // 시험용: 견본 알림 3건을 한꺼번에(두 번째부터 바로 떨어짐)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let samples: [(String, String, String, String)] = [
                        ("openai", "OpenAI", "새 소식은 이렇게 떨어집니다", "This is how new stories will drop in"),
                        ("verge", "The Verge", "두 번째 소식부터는 맺히지 않고 바로 떨어집니다", "From the second item it drops straight in"),
                        ("aitimes", "AI타임스", "세 번째 소식도 이어서 내려앉습니다", "The third one lands right after"),
                    ]
                    let items = samples.map { s in
                        NewsItem(id: AppModel.previewID, title: s.3, titleKo: s.2, link: "", date: Date(), summary: "",
                                 sourceId: s.0, sourceName: s.1 + " · 미리 보기", tier: "lab")
                    }
                    ToastCenter.shared.show(items, sound: AppModel.shared.state.settings.sound)
                }
            }
            if env["DROPCAP_TEST_WELCOME"] != nil, let dir = env["DROPCAP_TEST_SHOT_DIR"] { // 시험용: 환영 알림이 끝까지 빠지는지
                for sec in [3, 7, 10, 14] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(sec)) {
                        NSLog("[환영 시험] %d초: 알림 %d개", sec, ToastCenter.shared.toasts.count)
                        ToastCenter.shared.snapshot(to: "\(dir)/welcome-\(sec).png")
                    }
                }
            }
            if let path = env["DROPCAP_TEST_IMGTR"], let img = NSImage(contentsOfFile: path), let dir = env["DROPCAP_TEST_SHOT_DIR"] { // 시험용: 사진 번역 창
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { ImageTranslateWindow.open(img, url: path, title: "시험") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                    guard let v = NSApp.windows.first(where: { $0.isVisible && $0.title.hasPrefix("사진 번역") })?.contentView,
                          let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/imgtr.png"))
                }
            }
            if let dir = env["DROPCAP_TEST_ICONLAB"] { SectionIconLab.render(to: dir) } // 시험용: 분야 아이콘 시안
            if let dir = env["DROPCAP_TEST_CARDLAB"] { // 시험용: 분야 카드 세 방식(피드를 받은 뒤 그림)
                Task { try? await Task.sleep(for: .seconds(Double(env["DROPCAP_TEST_CARDLAB_WAIT"] ?? "90") ?? 90)); await SectionCardLab.render(to: dir) }
            }
            if env["DROPCAP_TEST_TOAST"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { AppModel.shared.preview() }
                if let dir = env["DROPCAP_TEST_SHOT_DIR"] {
                    for ms in [1300, 1700, 1950, 2100, 2200, 2300, 2450, 3400] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) {
                            ToastCenter.shared.snapshot(to: "\(dir)/toast-\(ms).png")
                        }
                    }
                }
            }
        }
    }

    // 시스템 알림을 눌렀을 때
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let key = response.notification.request.content.userInfo["key"] as? String
        await MainActor.run {
            if let sec = response.notification.request.content.userInfo["section"] as? String { // 묶음 알림
                MagazineController.open(page: .section(sec))
            } else if let key, let item = AppModel.shared.state.recent.first(where: { $0.key == key }) {
                AppModel.shared.open(item)
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
