import Foundation
import Testing
@testable import AINewsAlert

// 실제 네트워크로 기본 출처를 받아 본다(안전 검사가 정상 출처를 막지 않는지)
@Suite(.serialized) struct LiveFeedTests {
    @Test func defaultSourcesLoad() async throws {
        var failures: [String] = []
        for src in Resources.config.sources where src.defaultOn {
            do {
                let items = try await FeedService.shared.items(for: src) ?? []
                if items.isEmpty { failures.append("\(src.id): 0건") }
            } catch {
                failures.append("\(src.id): \(error.localizedDescription)")
            }
        }
        #expect(failures.isEmpty, "\(failures)")
    }
}
