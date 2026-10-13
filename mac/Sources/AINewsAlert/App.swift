import AppKit
import SwiftUI
import UserNotifications

@main
struct AINewsAlertApp: App {
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
    private var lockFD: Int32 = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 이미 실행 중이면 끈다: 둘이 동시에 돌면 같은 소식을 두 번 알린다
        lockFD = open(Store.dir.appendingPathComponent("native.lock").path, O_CREAT | O_RDWR, 0o644)
        if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            NSLog("AI News Alert 이 이미 실행 중이라 종료합니다")
            exit(0)
        }
        NSApp.setActivationPolicy(.accessory) // Dock 에 나타나지 않음
        Typography.register()
        if SystemNotifier.available { UNUserNotificationCenter.current().delegate = self }
        MainActor.assumeIsolated {
            AppModel.shared.start()
            // 시험용: AINEWS_TEST_URL=<기사 주소> 면 읽기 창을, AINEWS_TEST_TOAST=1 이면 알림 미리 보기를 바로 띄운다
            let env = ProcessInfo.processInfo.environment
            if let u = env["AINEWS_TEST_URL"] {
                ReaderController.open(NewsItem(id: u, title: u, titleKo: nil, link: u, date: Date(), summary: "", sourceId: "openai", sourceName: "시험", tier: "lab"))
                if let dir = env["AINEWS_TEST_SHOT_DIR"] {
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
            if env["AINEWS_TEST_MAGAZINE"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MagazineController.open() }
                if let dir = env["AINEWS_TEST_SHOT_DIR"] {
                    for sec in [4, 12, 40] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(sec)) {
                            guard let v = NSApp.windows.first(where: { $0.isVisible && $0.title == "AI 매거진" })?.contentView,
                                  let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                            v.cacheDisplay(in: v.bounds, to: rep)
                            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/mag-\(sec).png"))
                        }
                    }
                }
            }
            if env["AINEWS_TEST_TOAST"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { AppModel.shared.preview() }
                if let dir = env["AINEWS_TEST_SHOT_DIR"] {
                    for ms in [1700, 2150, 2250, 2350, 2450, 2600, 2800, 3050, 3400, 4500, 6500, 8500] {
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
            if let key, let item = AppModel.shared.state.recent.first(where: { $0.key == key }) {
                AppModel.shared.open(item)
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
