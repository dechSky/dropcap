import AppKit
import SwiftUI

// 시험 장치: 디버그 빌드에만 들어간다.
#if DEBUG

// DROPCAP_TEST_ARCHIVE_SHOT=<폴더>: 보관함(일·주·월·연)·검색 '오래된 기사' 화면을 화면 밖 창에 그려 png 로 남긴다.
//  앱을 앞으로 띄우지 않고(활성화 없음) 사용자 화면에도 보이지 않는다. DROPCAP_TEST_ARCHIVE_DATE=YYYY-MM-DD 로 기준 날,
//  DROPCAP_TEST_ARCHIVE_QUERY 로 검색어를 정한다.
@MainActor
enum ArchiveTestHooks {
    static func run(_ env: [String: String]) {
        guard let dir = env["DROPCAP_TEST_ARCHIVE_SHOT"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let day = env["DROPCAP_TEST_ARCHIVE_DATE"].flatMap { f.date(from: $0) } ?? Date()
        var scenes: [(String, AnyView)] = Archive.Period.allCases.map { p in ("archive-\(p.rawValue)", AnyView(ArchiveView(onIssue: { _ in }, start: (p, day)))) }
        scenes.append(("archive-today-month", AnyView(ArchiveView(onIssue: { _ in }, start: (.month, Date())))))
        if let q = env["DROPCAP_TEST_ARCHIVE_QUERY"] { scenes.append(("search", AnyView(SearchView(initial: q)))) }
        Task {
            try? await Task.sleep(for: .seconds(2))
            for (name, view) in scenes {
                let w = NSWindow(contentViewController: NSHostingController(rootView: view.frame(width: 900, height: 1100).background(Palette.canvas)))
                w.styleMask = [.titled, .fullSizeContentView]
                let minX = NSScreen.screens.map(\.frame.minX).min() ?? 0
                w.setFrameOrigin(NSPoint(x: minX - 5000, y: -5000))
                w.orderBack(nil)
                try? await Task.sleep(for: .seconds(3))
                if let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
                }
                w.orderOut(nil)
            }
            TestLog.write("[보관함 시험] 장면 \(scenes.count)개 찍음")
            NSApp.terminate(nil)
        }
    }
}
#endif
