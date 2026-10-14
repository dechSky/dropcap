import Carbon.HIToolbox

// 어느 앱을 쓰고 있든 쓸 수 있는 단축키(손쉬운 사용 권한 필요 없음)
// ⌥⌘N 가장 최근 안 읽은 소식 · ⌥⌘M 매거진
enum HotKey {
    enum Key: UInt32 {
        case n = 45 // kVK_ANSI_N
        case m = 46 // kVK_ANSI_M
    }
    nonisolated(unsafe) private static var handlers: [UInt32: () -> Void] = [:]
    nonisolated(unsafe) private static var refs: [EventHotKeyRef?] = []
    nonisolated(unsafe) private static var installed = false
    nonisolated(unsafe) static var unavailable: Set<UInt32> = [] // 다른 앱이 먼저 써서 등록하지 못한 키(설정에 표시)

    @MainActor static func register(key: Key, _ action: @escaping () -> Void) {
        if E2EFeeds.active { return } // 시험 실행은 설치된 Dropcap 의 ⌥⌘N·⌥⌘M 과 겹치지 않게 전역 단축키를 쓰지 않는다
        guard handlers[key.rawValue] == nil else { return }
        handlers[key.rawValue] = action
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &id)
                let n = id.id
                DispatchQueue.main.async { HotKey.handlers[n]?() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        var ref: EventHotKeyRef?
        let err = RegisterEventHotKey(key.rawValue, UInt32(cmdKey | optionKey), EventHotKeyID(signature: OSType(0x41494E41), id: key.rawValue),
                                      GetApplicationEventTarget(), 0, &ref)
        if err != noErr { // 다른 앱이 같은 단축키를 쓰는 중(A-29)
            unavailable.insert(key.rawValue)
            NSLog("[단축키] ⌥⌘%@ 를 등록하지 못함(%d) — 다른 앱이 쓰는 중일 수 있음", key == .n ? "N" : "M", err)
        }
        refs.append(ref)
    }
}
