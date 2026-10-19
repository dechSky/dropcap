import Foundation

// 시험용 기록: DROPCAP_TEST_LOG=<파일> 이면 그 파일에 한 줄씩 덧붙인다(시험 실행에서 로그가 사라지는 일이 있어 파일로 확실하게)
enum TestLog {
    #if DEBUG
    static let path = ProcessInfo.processInfo.environment["DROPCAP_TEST_LOG"]
    #else
    static let path: String? = nil // 배포 빌드는 NSLog 만
    #endif
    static func write(_ s: String) {
        NSLog("%@", s)
        guard let path, let data = (s + "\n").data(using: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { try? data.write(to: URL(fileURLWithPath: path)) }
    }
}

// 시험용 환경 변수 DROPCAP_TEST_<이름>: 디버그 빌드에서만 읽는다. 배포 빌드에서는 늘 nil(시험 장치가 배포 앱에서 켜지지 않게)
enum TestEnv {
    static func get(_ name: String) -> String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["DROPCAP_TEST_" + name]
        #else
        nil
        #endif
    }
}
