import AppKit
import Darwin
import Foundation

// 피드에서 온 주소는 믿지 않는다. 공개 인터넷의 http(s) 주소만 받는다.
// 내부망(공유기 관리 화면, localhost, 사설 IP 등)으로 이 Mac 이 몰래 요청하지 않게 막는다.
//
// 두 단계로 본다.
// 1) isPublicHTTP: 주소 모양만 보고 바로 판단(스킴·이름·IP 글자). 숫자처럼 생긴 이상한 표기(0x7f.1, 127.1 등)는 거절.
// 2) resolvesPublic: 이름을 실제 IP 로 풀어 보고, 하나라도 내부망이면 거절(127.0.0.1.nip.io 같은 이름 대비).
// 3) 받은 뒤: 실제로 접속한 IP 를 다시 보고 내부망이면 응답을 버린다(FeedService.RequestGuard).
// 남는 위험: DNS rebinding 때 요청 자체는 한 번 나갈 수 있다(내용은 쓰지 않음). 사용자가 직접 연 기사의 웹 보기는 일반 브라우저와 같은 수준.
enum URLSafety {
    static func isPublicHTTP(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal")
            || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") || host.hasSuffix(".arpa") {
            return false
        }
        if let v4 = parseV4(host) { return isPublic(v4: v4) }
        if host.contains(":") {
            guard let v6 = parseV6(host) else { return false }
            return isPublic(v6: v6)
        }
        // 점 없는 이름(intranet), 숫자·16진수로만 된 이상한 표기(2130706433, 0x7f.1, 127.1)는 거절
        if !host.contains(".") { return false }
        if host.range(of: #"^[0-9a-fx.]+$"#, options: .regularExpression) != nil, host.last.map({ $0.isNumber }) == true { return false }
        return true
    }

    // 이름을 실제로 풀어 모든 주소가 공개 주소일 때만 true. 결과는 5분간 기억.
    static func resolvesPublic(_ url: URL?) async -> Bool {
        if E2EFeeds.allows(url) { return true } // 시나리오 시험(DROPCAP_TEST_E2E)에서만 견본 호스트(*.e2e.example)
        guard isPublicHTTP(url), let host = url?.host?.lowercased() else { return false }
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if parseV4(bare) != nil || bare.contains(":") { return true } // IP 글자는 1단계에서 이미 판단
        if let c = await Cache.shared.get(bare) { return c }
        let ok = await Task.detached(priority: .utility) { lookup(bare) }.value
        await Cache.shared.set(bare, ok)
        return ok
    }

    private static func lookup(_ host: String) -> Bool {
        var hints = addrinfo(ai_flags: AI_DEFAULT, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return false }
        defer { freeaddrinfo(first) }
        var any = false
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let ai = p {
            any = true
            if ai.pointee.ai_family == AF_INET {
                let sin = ai.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                let b = withUnsafeBytes(of: sin.sin_addr.s_addr) { Array($0) }
                if !isPublic(v4: b) { return false }
            } else if ai.pointee.ai_family == AF_INET6 {
                let sin6 = ai.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                let b = withUnsafeBytes(of: sin6.sin6_addr) { Array($0) }
                if !isPublic(v6: b) { return false }
            } else {
                return false
            }
            p = ai.pointee.ai_next
        }
        return any
    }

    // MARK: IP 해석(운영체제 표준 함수, 엄격한 표기만)
    static func parseV4(_ s: String) -> [UInt8]? {
        var a = in_addr()
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        // 앞자리 0(0177 = 8진수 127 로 읽는 곳이 있음)은 표준 표기가 아니므로 IP 로 보지 않는다 → 아래에서 거절
        guard parts.count == 4, parts.allSatisfy({ $0.count == 1 || !$0.hasPrefix("0") }),
              inet_pton(AF_INET, s, &a) == 1 else { return nil }
        return withUnsafeBytes(of: a.s_addr) { Array($0) }
    }

    static func parseV6(_ s: String) -> [UInt8]? {
        var a = in6_addr()
        guard inet_pton(AF_INET6, s, &a) == 1 else { return nil }
        return withUnsafeBytes(of: a) { Array($0) }
    }

    static func isPublic(v4 b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        switch (b[0], b[1]) {
        case (0, _), (10, _), (127, _): return false
        case (169, 254), (192, 168): return false
        case (172, 16...31): return false
        case (100, 64...127): return false   // 통신사 공유 주소
        case (192, 0) where b[2] == 0: return false
        case (198, 18...19): return false     // 시험용
        default: return b[0] < 224            // 멀티캐스트·예약 제외
        }
    }

    static func isPublic(v6 b: [UInt8]) -> Bool {
        guard b.count == 16 else { return false }
        if b[0..<15].allSatisfy({ $0 == 0 }) { return false }                   // :: 와 ::1
        if b[0] & 0xFE == 0xFC { return false }                                  // fc00::/7 고유 로컬
        if b[0] == 0xFE && b[1] & 0xC0 == 0x80 { return false }                  // fe80::/10 링크 로컬
        if b[0] == 0xFE && b[1] & 0xC0 == 0xC0 { return false }                  // fec0::/10 사이트 로컬(폐지됐지만 내부망에 남아 있음)
        if b[0] == 0xFF { return false }                                         // 멀티캐스트
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF { // ::ffff:a.b.c.d
            return isPublic(v4: Array(b[12..<16]))
        }
        if b[0..<12].allSatisfy({ $0 == 0 }) { return isPublic(v4: Array(b[12..<16])) } // ::a.b.c.d (옛 표기)
        if b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xFF && b[3] == 0x9B {        // 64:ff9b::/96 NAT64
            return isPublic(v4: Array(b[12..<16]))
        }
        if b[0] == 0x20 && b[1] == 0x02 { return isPublic(v4: Array(b[2..<6])) } // 2002::/16 6to4
        return true
    }

    private actor Cache {
        static let shared = Cache()
        private var map: [String: (ok: Bool, at: Date)] = [:]
        func get(_ h: String) -> Bool? {
            guard let e = map[h], Date().timeIntervalSince(e.at) < 300 else { return nil }
            return e.ok
        }
        func set(_ h: String, _ ok: Bool) {
            if map.count > 500 { map.removeAll() }
            map[h] = (ok, Date())
        }
    }
}

// 기사 링크를 바깥(브라우저·앱)으로 여는 곳은 모두 이것만 쓴다: 공개 http(s) 주소만 연다
enum ExternalLink {
    @discardableResult
    static func open(_ link: String?) -> Bool {
        guard let link, let u = URL(string: link), URLSafety.isPublicHTTP(u) else { return false }
        return NSWorkspace.shared.open(u)
    }
}
