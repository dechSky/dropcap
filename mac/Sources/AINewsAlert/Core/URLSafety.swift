import Foundation

// 피드에서 온 주소는 믿지 않는다. 공개 인터넷의 http(s) 주소만 받는다.
// 내부망(공유기 관리 화면, localhost, 사설 IP 등)으로 이 Mac 이 몰래 요청하지 않게 막는다.
enum URLSafety {
    static func isPublicHTTP(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal")
            || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") || !host.contains(".") && !host.contains(":") {
            return false
        }
        if let v4 = ipv4(host) { return !isPrivateV4(v4) }
        if host.contains(":") { return !isPrivateV6(host) }
        return true
    }

    private static func ipv4(_ h: String) -> [Int]? {
        let p = h.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4, h.split(separator: ".").count == 4, p.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return p
    }

    private static func isPrivateV4(_ p: [Int]) -> Bool {
        switch (p[0], p[1]) {
        case (0, _), (10, _), (127, _): return true
        case (169, 254), (192, 168): return true
        case (172, 16...31): return true
        case (100, 64...127): return true // 통신사 공유 주소
        default: return p[0] >= 224 // 멀티캐스트·예약
        }
    }

    private static func isPrivateV6(_ h: String) -> Bool {
        let s = h.lowercased()
        if s == "::1" || s == "::" { return true }
        if s.hasPrefix("fc") || s.hasPrefix("fd") || s.hasPrefix("fe8") || s.hasPrefix("fe9") || s.hasPrefix("fea") || s.hasPrefix("feb") { return true }
        if s.hasPrefix("::ffff:") { return ipv4(String(s.dropFirst(7))).map(isPrivateV4) ?? true }
        return false
    }
}
