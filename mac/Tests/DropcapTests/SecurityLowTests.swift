import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import WebKit
@testable import Dropcap

// 보안 점검(2026-10-14) 낮음 등급 M7(판정 함수)·M8·M10·M11 (M9 는 배포 빌드 확인: scripts/check-release-hooks.sh)
@Suite struct SecurityLowTests {
    // M7(받아들인 위험): 시스템 프록시를 거친 연결은 출처 밖 도메인이라도 연결 전 이름 확인으로 받는다.
    // 설정된 프록시가 없는데 프록시 연결이면 막는다(예전 동작 그대로).
    @Test func proxiedHopJudgedByNameCheckOnly() {
        let proxied = RequestGuard.Hop(proxied: true, remote: "10.0.0.8")
        #expect(RequestGuard.judge([proxied], systemProxy: true).safe)                 // 사진 CDN·번역 등 출처 밖 도메인도
        #expect(RequestGuard.judge([proxied, proxied], systemProxy: true).safe)        // 리다이렉트 포함
        #expect(!RequestGuard.judge([proxied], systemProxy: false).safe)               // 설정 없는 프록시 연결은 막음
        // 직접 연결은 예전처럼 IP 로
        #expect(RequestGuard.judge([.init(proxied: false, remote: "93.184.216.34")], systemProxy: false).safe)
        #expect(!RequestGuard.judge([.init(proxied: false, remote: "192.168.0.2")], systemProxy: true).safe)
        #expect(!RequestGuard.judge([proxied, .init(proxied: false, remote: "127.0.0.1")], systemProxy: true).safe)
        #expect(!RequestGuard.judge([.init(proxied: false, remote: nil)], systemProxy: false).safe) // 모르면 막음
        #expect(!RequestGuard.judge([], systemProxy: true).safe) // 확인한 연결이 없으면 막음
    }

    // M8: 느린 길(자바스크립트 켜짐)에서 페이지 스크립트가 내부망으로 요청하지 못하게 content rule 로도 막는다
    @Test @MainActor func slowPathBlocksPrivateNetworks() {
        let filters = ArticleExtractor.privateNetworkFilters
        func blocked(_ s: String) -> Bool {
            filters.contains { f in s.range(of: f, options: [.regularExpression, .caseInsensitive]) != nil }
        }
        for u in ["http://127.0.0.1:8080/x", "https://10.1.2.3/", "http://192.168.0.1/admin", "http://172.16.0.1/", "http://172.31.255.1/",
                  "http://169.254.169.254/latest/meta-data", "http://0.0.0.0/", "http://100.64.0.1/", "http://localhost/", "http://localhost:3000/a",
                  "http://printer.local/", "http://[::1]/", "http://[fe80::1]/", "http://[fd00::1]/", "http://[::ffff:7f00:1]/", "ws://127.0.0.1/",
                  "http://user@127.0.0.1/"] {
            #expect(blocked(u), "\(u)")
        }
        for u in ["https://www.example.com/a", "https://172.217.1.1/", "https://10x.example/", "https://localhost.example.com/",
                  "https://cdn.example/192.168.0.1.jpg", "https://100.10.0.1/"] {
            #expect(!blocked(u), "\(u)")
        }
        let rules = ArticleExtractor.rules(block: ["image"])
        #expect(rules.count == filters.count + 1)
    }

    @Test @MainActor func slowPathRulesCompile() async throws {
        let rules = ArticleExtractor.rules(block: ["image", "media"])
        let json = String(decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self)
        let id = "dropcap-test-\(UUID().uuidString)"
        let store = try #require(WKContentRuleListStore.default())
        let list = try await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json)
        #expect(list != nil)
        try? await store.removeContentRuleList(forIdentifier: id)
    }

    // M10: 단축어 저장도 아이디·암호가 든 주소를 받지 않는다(SaveLink.normalize 와 같게)
    @Test func intentSaveRejectsCredentials() {
        #expect(IntentLogic.savableURL("https://user:pw@example.com/a") == nil)
        #expect(IntentLogic.savableURL("user@example.com/a") == nil)
        #expect(IntentLogic.savableURL("https://example.com/a#frag")?.absoluteString == "https://example.com/a")
        #expect(IntentLogic.savableURL("<https://example.com/b>")?.absoluteString == "https://example.com/b")
    }

    // M11: 사진 압축 폭탄 — 받은 크기(8MB)는 작아도 풀면 수백 메가픽셀인 사진은 풀기 전에 거른다
    @Test func imageBombRejectedBeforeDecode() throws {
        let small = try png(width: 64, height: 48)
        #expect(ImageLoader.decode(small) != nil)
        let bomb = try zeroPNG(side: 8_000) // 64메가픽셀, 파일은 수십 KB
        #expect(bomb.count < 200_000)
        let src = try #require(CGImageSourceCreateWithData(bomb as CFData, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        #expect(props?[kCGImagePropertyPixelWidth] as? Int == 8_000) // 머리만 읽어도 크기를 안다
        #expect(!ImageLoader.pixelsAcceptable(src))
        #expect(ImageLoader.decode(bomb) == nil)
        #expect(ImageLoader.pixelsAcceptable(try #require(CGImageSourceCreateWithData(small as CFData, nil))))
    }

    private func png(width: Int, height: Int) throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let img = try #require(ctx.makeImage())
        let out = NSMutableData()
        let dst = try #require(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dst, img, nil)
        #expect(CGImageDestinationFinalize(dst))
        return out as Data
    }

    // 진짜로 풀리는 큰 PNG: 흑백 1비트, 모두 0(줄마다 필터 0 + 0 바이트). zlib 로 감싸 IDAT 하나에.
    private func zeroPNG(side: Int) throws -> Data {
        let raw = Data(count: side * (1 + (side + 7) / 8))
        let deflated = try (raw as NSData).compressed(using: .zlib) as Data // 머리 없는 deflate
        var z = Data([0x78, 0x9C]) + deflated
        let adler = UInt32(raw.count % 65521) << 16 | 1 // 모두 0 인 자료의 adler32
        z += be(adler)
        var ihdr = be(UInt32(side)) + be(UInt32(side))
        ihdr += Data([1, 0, 0, 0, 0]) // 1비트 · 흑백 · 기본 압축·필터 · 비월 없음
        return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + chunk("IHDR", ihdr) + chunk("IDAT", z) + chunk("IEND", Data())
    }

    private func be(_ v: UInt32) -> Data { Data([UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }

    private func chunk(_ type: String, _ body: Data) -> Data {
        let tb = Data(type.utf8) + body
        return be(UInt32(body.count)) + tb + be(crc32([UInt8](tb)))
    }

    private func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for x in bytes {
            c ^= UInt32(x)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        }
        return ~c
    }
}
