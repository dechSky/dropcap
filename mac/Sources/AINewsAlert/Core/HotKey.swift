import Carbon.HIToolbox

// 어느 앱을 쓰고 있든 ⌥⌘N 을 누르면 가장 최근 안 읽은 소식을 연다(손쉬운 사용 권한 필요 없음)
enum HotKey {
    nonisolated(unsafe) private static var handler: (() -> Void)?
    nonisolated(unsafe) private static var ref: EventHotKeyRef?

    @MainActor static func register(_ action: @escaping () -> Void) {
        guard ref == nil else { return }
        handler = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.handler?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x41494E41), id: 1) // 'AINA'
        RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
    }
}
