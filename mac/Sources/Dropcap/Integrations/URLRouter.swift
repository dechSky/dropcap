import AppKit
import CoreSpotlight
import DropcapShared
import Foundation

// dropcap:// 주소 처리기. 위젯·Spotlight·단축어가 앱을 부를 때 쓴다.
// host 별로 등록한다: 다른 기능(예: dropcap://save)은 URLRouter.register("save") { url in ... } 한 줄로 더한다.
@MainActor
enum URLRouter {
    private static var handlers: [String: @MainActor (URL) -> Bool] = [
        "open": { url in
            guard let key = WidgetLink.key(from: url), let item = item(forKey: key) else { return false }
            AppModel.shared.open(item)
            return true
        },
        "magazine": { _ in MagazineController.open(); return true },
        "save": { url in SaveLink.handle([url]); return true }, // dropcap://save?url=… (북마클릿·단축어, 저장 전 확인 창)
    ]

    static func register(_ host: String, _ handler: @escaping @MainActor (URL) -> Bool) {
        handlers[host.lowercased()] = handler
    }

    @discardableResult
    static func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == WidgetLink.scheme, let host = url.host?.lowercased(), let h = handlers[host] else { return false }
        let ok = h(url)
        NSLog("[주소] dropcap://%@ 처리=%@", host, ok ? "예" : "아니오")
        return ok
    }

    // 기사 key → 기사(최근 목록 · 나중에 읽기 · 스크랩 · 매거진 DB 순서로 찾는다)
    static func item(forKey key: String) -> NewsItem? {
        let s = AppModel.shared.state
        return s.recent.first { $0.key == key }
            ?? s.saved.first { $0.key == key }
            ?? Scrapbook.shared.scraps.first { $0.item.key == key }?.item
            ?? Database.shared.items(keys: [key]).first?.item
    }
}

// 앱 대리자에 붙이는 처리(App.swift 를 고치지 않게 확장으로 둔다)
extension AppDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for u in urls { URLRouter.handle(u) }
        }
    }

    // Spotlight 결과를 눌렀을 때
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let id = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return false }
        return MainActor.assumeIsolated { SpotlightIndexer.open(id) }
    }
}
