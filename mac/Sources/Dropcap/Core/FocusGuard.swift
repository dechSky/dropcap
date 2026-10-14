import AppKit
import CoreGraphics
import EventKit
import Foundation

// 회의·발표 중 자동 조용히(N-25 · D-8): 전체 화면 앱을 쓰는 중, 화면을 공유·기록하는 중, 캘린더 일정 중이면
// 물방울 대신 고이게 한다(방해 금지와 같은 길 — 안 읽은 소식으로 쌓이고, 떨어질 소식은 묶음으로).
// 모두 공개 API 만 쓴다: 창 목록(CGWindowList, 창 이름은 읽지 않음) · 실행 중인 프로세스 이름 · EventKit.
enum FocusReason: String, Equatable, Sendable {
    case fullscreen, sharing, calendar
    var label: String {
        switch self {
        case .fullscreen: return "전체 화면 사용 중"
        case .sharing: return "화면 공유·기록 중"
        case .calendar: return "캘린더 일정 중"
        }
    }
}

enum FocusGuard {
    // 화면을 공유·기록하는 동안에만 떠 있는 도우미 프로세스
    // CptHost: Zoom 화면 공유 · screencaptureui: macOS 화면 기록(⇧⌘5) · ScreenSharingAgent·SSInvitationAgent: 화면 공유 앱 연결
    static let sharingProcesses: Set<String> = ["CptHost", "screencaptureui", "ScreenSharingAgent", "SSInvitationAgent"]

    struct WindowInfo: Equatable { var pid: Int32; var layer: Int; var bounds: CGRect }

    // 앞에 있는 앱의 보통 창이 어느 화면을 통째로 덮는가(메뉴 막대까지 가린 전체 화면 · 발표 모드)
    static func coversScreen(_ windows: [WindowInfo], frontPID: Int32?, screens: [CGSize], ownPID: Int32) -> Bool {
        guard let front = frontPID, front != ownPID else { return false }
        return windows.contains { w in
            w.pid == front && w.layer == 0 && screens.contains { abs(w.bounds.width - $0.width) < 1 && abs(w.bounds.height - $0.height) < 1 }
        }
    }

    static func sharing(_ processNames: [String]) -> Bool { processNames.contains { sharingProcesses.contains($0) } }

    // 일정 중인가: 하루 종일 일정·'한가함'으로 둔 일정·거절한 일정은 빼고, 지금이 시작~끝 사이
    struct EventInfo: Equatable { var start: Date; var end: Date; var allDay: Bool; var free: Bool; var declined: Bool }
    static func inEvent(_ events: [EventInfo], now: Date) -> Bool {
        events.contains { !$0.allDay && !$0.free && !$0.declined && $0.start <= now && now < $0.end }
    }

    // MARK: 지금 이 Mac 에서 읽기
    static func liveWindows() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { d in
            guard let pid = d[kCGWindowOwnerPID as String] as? Int32, let layer = d[kCGWindowLayer as String] as? Int,
                  let b = d[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b) else { return nil }
            return WindowInfo(pid: pid, layer: layer, bounds: r)
        }
    }

    static func liveProcessNames() -> [String] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var out: [String] = []
        var buf = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(Int(max(n, 0))) where pid > 0 {
            if proc_name(pid, &buf, UInt32(buf.count)) > 0 { out.append(String(cString: buf)) }
        }
        return out
    }
}

// 앱 안에서 쓰는 쪽: 설정을 따라 지금 조용히 할 이유를 알려 준다(15초 동안 기억 — 확인·1분 타이머가 자주 묻지 않게)
@MainActor
final class FocusMonitor: ObservableObject {
    static let shared = FocusMonitor()
    private let store = EKEventStore()
    private var cached: (at: Date, reason: FocusReason?)?
    @Published private(set) var calendarAccess: Bool = FocusMonitor.hasCalendarAccess
    var override: FocusReason?? // 시험용: 감지 결과를 정해 둔다

    static var hasCalendarAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func reason(_ s: AppState.Settings, now: Date = Date()) -> FocusReason? {
        if let o = override { return o }
        if let c = cached, now.timeIntervalSince(c.at) < 15 { return c.reason }
        let r = detect(s, now: now)
        cached = (now, r)
        return r
    }

    func invalidate() { cached = nil }

    private func detect(_ s: AppState.Settings, now: Date) -> FocusReason? {
        if s.autoQuietFullscreen {
            let screens = NSScreen.screens.map(\.frame.size)
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if FocusGuard.coversScreen(FocusGuard.liveWindows(), frontPID: front, screens: screens, ownPID: ProcessInfo.processInfo.processIdentifier) {
                return .fullscreen
            }
        }
        if s.autoQuietSharing, FocusGuard.sharing(FocusGuard.liveProcessNames()) { return .sharing }
        if s.autoQuietCalendar, Self.hasCalendarAccess {
            let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-12 * 3600), end: now.addingTimeInterval(60), calendars: nil)
            let events = store.events(matching: pred).map { e in
                FocusGuard.EventInfo(start: e.startDate, end: e.endDate, allDay: e.isAllDay, free: e.availability == .free,
                                     declined: e.attendees?.first { $0.isCurrentUser }?.participantStatus == .declined)
            }
            if FocusGuard.inEvent(events, now: now) { return .calendar }
        }
        return nil
    }

    // 사용자가 '캘린더 일정 중' 을 켤 때만 권한을 묻는다. 거절하면 false(설정은 꺼진 채로 둔다)
    func requestCalendar() async -> Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false } // `swift run` 개발 실행에는 권한 문구가 없다
        let ok = (try? await store.requestFullAccessToEvents()) ?? false
        calendarAccess = ok
        invalidate()
        return ok
    }
}
