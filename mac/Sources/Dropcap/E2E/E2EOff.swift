import Foundation

// 배포 빌드: 시험 장치(E2E/*)가 빠진 자리. 앱 코드가 묻는 몇 곳만 '꺼짐'으로 남긴다.
#if !DEBUG
enum E2EFeeds {
    static let active = false
    static func allows(_ url: URL?) -> Bool { false }
    static func serve(_ url: String) async throws -> (data: Data, encoding: String?)? { nil }
    static func noteExternal(_ u: String) {}
}
#endif
