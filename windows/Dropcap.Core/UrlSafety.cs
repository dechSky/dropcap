using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Text.RegularExpressions;

namespace Dropcap.Core;

// 피드에서 온 주소는 믿지 않는다. 공개 인터넷의 http(s) 주소만 받는다.
// 내부망(공유기 관리 화면, localhost, 사설 IP 등)으로 이 PC 가 몰래 요청하지 않게 막는다.
//
// 1) IsPublicHttp: 주소 모양만 보고 바로 판단(스킴·이름·IP 글자). 숫자처럼 생긴 이상한 표기(0x7f.1, 127.1 등)는 거절.
// 2) ResolvesPublicAsync: 이름을 실제 IP 로 풀어 보고, 하나라도 내부망이면 거절(127.0.0.1.nip.io 같은 이름 대비).
// 3) 접속하는 순간: SafeHttp 의 연결 콜백이 이름을 다시 풀어 모든 IP 를 검사하고, 검사한 그 IP 로만 접속한다.
//    맥(받은 뒤 접속 IP 확인)보다 강하다 — DNS 바꿔치기(rebinding)로도 요청 자체가 내부망으로 나가지 않는다.
public static class UrlSafety
{
    public static bool IsPublicHttp(string? url)
    {
        if (string.IsNullOrWhiteSpace(url) || !Uri.TryCreate(url, UriKind.Absolute, out var uri)) return false;
        var scheme = uri.Scheme.ToLowerInvariant();
        if (scheme is not ("http" or "https")) return false;
        // .NET Uri 는 0x7f.1 같은 표기를 127.0.0.1 로 바꿔 버리므로, 원래 글자에서 이름을 꺼내 엄격하게 본다
        var host = RawHost(url);
        if (string.IsNullOrEmpty(host)) return false;
        return IsPublicHost(host);
    }

    public static bool IsPublicHost(string rawHost)
    {
        var host = rawHost.ToLowerInvariant();
        if (host.StartsWith('[') && host.EndsWith(']')) host = host[1..^1];
        if (host.EndsWith('.')) host = host[..^1];
        if (host.Length == 0 || host.Contains('%') || host.Contains(' ')) return false;
        if (host == "localhost" || host.EndsWith(".localhost") || host.EndsWith(".local") || host.EndsWith(".internal")
            || host.EndsWith(".lan") || host.EndsWith(".home.arpa") || host.EndsWith(".arpa"))
            return false;
        if (ParseV4(host) is { } v4) return IsPublicV4(v4);
        if (host.Contains(':'))
        {
            var v6 = ParseV6(host);
            return v6 is not null && IsPublicV6(v6);
        }
        // 점 없는 이름(intranet), 숫자·16진수로만 된 이상한 표기(2130706433, 0x7f.1, 127.1)는 거절
        if (!host.Contains('.')) return false;
        if (OddNumeric.IsMatch(host) && char.IsDigit(host[^1])) return false;
        return true;
    }

    private static readonly Regex OddNumeric = new("^[0-9a-fx.]+$");

    // scheme://[사용자@]이름[:포트]/... 에서 이름만(원래 글자 그대로)
    public static string? RawHost(string url)
    {
        var i = url.IndexOf("://", StringComparison.Ordinal);
        if (i < 0) return null;
        var rest = url[(i + 3)..];
        var end = rest.IndexOfAny(['/', '?', '#', '\\']);
        var authority = end < 0 ? rest : rest[..end];
        var at = authority.LastIndexOf('@');
        if (at >= 0) authority = authority[(at + 1)..];
        if (authority.StartsWith('['))
        {
            var close = authority.IndexOf(']');
            return close < 0 ? null : authority[..(close + 1)];
        }
        var colon = authority.LastIndexOf(':');
        return colon >= 0 ? authority[..colon] : authority;
    }

    // 이름을 실제로 풀어 모든 주소가 공개 주소일 때만 true. 결과는 5분간 기억.
    public static async Task<bool> ResolvesPublicAsync(string? url, CancellationToken ct = default)
    {
        if (!IsPublicHttp(url)) return false;
        var bare = RawHost(url!)!.ToLowerInvariant().Trim('[', ']').TrimEnd('.');
        if (ParseV4(bare) is not null || bare.Contains(':')) return true; // IP 글자는 1단계에서 이미 판단
        var addrs = await LookupAsync(bare, ct);
        return addrs is not null;
    }

    private static readonly ConcurrentDictionary<string, (IPAddress[]? Addrs, DateTime At)> cache = new();

    // 공개 주소만 돌려준다(하나라도 내부망이면 null). 5분간 기억.
    internal static async Task<IPAddress[]?> LookupAsync(string host, CancellationToken ct)
    {
        if (cache.TryGetValue(host, out var c) && DateTime.UtcNow - c.At < TimeSpan.FromMinutes(5)) return c.Addrs;
        IPAddress[]? ok;
        try
        {
            var all = await Dns.GetHostAddressesAsync(host, ct);
            ok = all.Length > 0 && all.All(IsPublic) ? all : null;
        }
        catch (SocketException) { ok = null; }
        if (cache.Count > 500) cache.Clear();
        cache[host] = (ok, DateTime.UtcNow);
        return ok;
    }

    public static bool IsPublic(IPAddress a)
    {
        var b = a.GetAddressBytes();
        return a.AddressFamily switch
        {
            AddressFamily.InterNetwork => IsPublicV4(b),
            AddressFamily.InterNetworkV6 => IsPublicV6(b),
            _ => false,
        };
    }

    // MARK: IP 해석(엄격한 표기만: 10진수 4칸, 앞자리 0 없음)
    public static byte[]? ParseV4(string s)
    {
        var parts = s.Split('.');
        if (parts.Length != 4) return null;
        var b = new byte[4];
        for (var i = 0; i < 4; i++)
        {
            var p = parts[i];
            // 앞자리 0(0177 = 8진수 127 로 읽는 곳이 있음)은 표준 표기가 아니므로 IP 로 보지 않는다 → 거절
            if (p.Length is 0 or > 3 || !p.All(char.IsAsciiDigit) || (p.Length > 1 && p[0] == '0')) return null;
            var v = int.Parse(p);
            if (v > 255) return null;
            b[i] = (byte)v;
        }
        return b;
    }

    public static byte[]? ParseV6(string s)
    {
        var bare = s.Split('%')[0];
        if (!bare.Contains(':') || !IPAddress.TryParse(bare, out var a) || a.AddressFamily != AddressFamily.InterNetworkV6) return null;
        return a.GetAddressBytes();
    }

    public static bool IsPublicV4(byte[] b)
    {
        if (b.Length != 4) return false;
        return (b[0], b[1]) switch
        {
            (0, _) or (10, _) or (127, _) => false,
            (169, 254) or (192, 168) => false,
            (172, >= 16 and <= 31) => false,
            (100, >= 64 and <= 127) => false,   // 통신사 공유 주소
            (192, 0) when b[2] == 0 => false,
            (198, 18 or 19) => false,           // 시험용
            _ => b[0] < 224,                    // 멀티캐스트·예약 제외
        };
    }

    public static bool IsPublicV6(byte[] b)
    {
        if (b.Length != 16) return false;
        if (b.Take(15).All(x => x == 0)) return false;                               // :: 와 ::1
        if ((b[0] & 0xFE) == 0xFC) return false;                                     // fc00::/7 고유 로컬
        if (b[0] == 0xFE && (b[1] & 0xC0) == 0x80) return false;                     // fe80::/10 링크 로컬
        if (b[0] == 0xFE && (b[1] & 0xC0) == 0xC0) return false;                     // fec0::/10 사이트 로컬(폐지됐지만 내부망에 남아 있음)
        if (b[0] == 0xFF) return false;                                              // 멀티캐스트
        if (b.Take(10).All(x => x == 0) && b[10] == 0xFF && b[11] == 0xFF)           // ::ffff:a.b.c.d
            return IsPublicV4(b[12..16]);
        if (b.Take(12).All(x => x == 0)) return IsPublicV4(b[12..16]);              // ::a.b.c.d (옛 표기)
        if (b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xFF && b[3] == 0x9B)            // 64:ff9b::/96 NAT64
            return IsPublicV4(b[12..16]);
        if (b[0] == 0x20 && b[1] == 0x02) return IsPublicV4(b[2..6]);               // 2002::/16 6to4
        return true;
    }
}

// 기사 링크를 바깥(브라우저·앱)으로 여는 곳은 모두 이것만 쓴다: 공개 http(s) 주소만 연다(S-08)
public static class ExternalLink
{
    // 실제로 여는 일은 화면 쪽(Windows.System.Launcher)이 이 검사를 거친 뒤에만
    public static Func<Uri, bool>? Opener { get; set; }

    public static bool Open(string? link)
    {
        if (link is null || !UrlSafety.IsPublicHttp(link) || !Uri.TryCreate(link, UriKind.Absolute, out var u)) return false;
        return Opener?.Invoke(u) ?? false;
    }
}
