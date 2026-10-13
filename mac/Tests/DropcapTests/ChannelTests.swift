import Foundation
import Testing
@testable import Dropcap

// 실제 네트워크로 주소 해석기를 확인한다
// 바깥 서버 상태에 따라 흔들리므로 DROPCAP_LIVE_TESTS=1 일 때만 돈다
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DROPCAP_LIVE_TESTS"] == "1"))
struct ChannelResolverTests {
    @Test(arguments: [
        ("cs.CL", ItemKind.paper),
        ("https://github.com/ollama/ollama", ItemKind.release),
        ("https://www.youtube.com/@TwoMinutePapers", ItemKind.video),
        ("simonwillison.net", ItemKind.article),
        ("https://www.latent.space", ItemKind.article),
    ])
    func resolves(input: String, kind: ItemKind) async throws {
        let f = try await ChannelResolver.resolve(input)
        #expect(f.kind == kind, "\(input) → \(f.feedURL)")
        #expect(f.feedURL.hasPrefix("https://"))
    }

    @Test func rejectsPrivate() async {
        await #expect(throws: (any Error).self) { try await ChannelResolver.resolve("http://192.168.0.1/feed") }
    }

    @Test func catalogFeedsLoad() async {
        var bad: [String] = []
        for s in ChannelCatalog.all where !s.url.contains("reddit.com") { // 레딧은 연속 요청을 막을 때가 많아 제외
            do { if (try await FeedService.shared.items(for: s, conditional: false) ?? []).isEmpty, s.kind != "paper" { bad.append(s.name + ": 0건") } }
            catch { bad.append("\(s.name): \(error.localizedDescription)") }
        }
        #expect(bad.isEmpty, "\(bad)")
    }
}
