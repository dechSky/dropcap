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

    @MainActor static func register(key: Key, _ action: @escaping () -> Void) {
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
        RegisterEventHotKey(key.rawValue, UInt32(cmdKey | optionKey), EventHotKeyID(signature: OSType(0x41494E41), id: key.rawValue),
                            GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }
}
