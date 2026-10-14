import Foundation

// 시험용 기록: DROPCAP_TEST_LOG=<파일> 이면 그 파일에 한 줄씩 덧붙인다(시험 실행에서 로그가 사라지는 일이 있어 파일로 확실하게)
enum TestLog {
    static let path = ProcessInfo.processInfo.environment["DROPCAP_TEST_LOG"]
    static func write(_ s: String) {
        NSLog("%@", s)
        guard let path, let data = (s + "\n").data(using: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { try? data.write(to: URL(fileURLWithPath: path)) }
    }
}
