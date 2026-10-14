using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Text;

namespace Dropcap.Core;

// 바깥으로 나가는 모든 요청(피드·기사·사진·번역)은 이 클라이언트만 쓴다.
// - 연결 콜백(S-03): 접속하는 순간 이름을 풀어 모든 IP 를 검사하고, 검사한 그 IP 로만 소켓을 연다. 확인 못 하면 막는다.
// - 프록시(S-03 예외): 시스템 프록시가 설정돼 있을 때 그 프록시로 가는 연결만 허용(이때는 요청 전 이름 확인에 맡김).
// - 리다이렉트(S-04): 자동으로 따라가지 않고, 다음 주소를 같은 검사에 통과시킨 뒤에만 따라간다.
public static class SafeHttp
{
    public const string UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Dropcap/1.0";
    public const long MaxBody = 32L << 20;

    private static readonly IWebProxy? systemProxy = SystemProxy();
    public static readonly HttpClient Client = Create();

    // 마지막으로 막은 연결(로그·오류 문구용)
    public static string? LastBlocked { get; private set; }

    private static IWebProxy? SystemProxy()
    {
        try { return HttpClient.DefaultProxy; } catch { return null; }
    }

    private static HttpClient Create()
    {
        var h = new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            AutomaticDecompression = DecompressionMethods.All,
            UseCookies = false,
            ConnectTimeout = TimeSpan.FromSeconds(15),
            PooledConnectionLifetime = TimeSpan.FromMinutes(5),
            UseProxy = systemProxy is not null,
            Proxy = systemProxy,
            ConnectCallback = ConnectAsync,
        };
        var c = new HttpClient(h) { Timeout = Timeout.InfiniteTimeSpan };
        c.DefaultRequestHeaders.UserAgent.ParseAdd(UserAgent);
        return c;
    }

    // 프록시로 가는 연결인가(시스템에 프록시가 실제로 설정돼 있고, 이 요청이 그 프록시를 쓰는 경우만)
    internal static bool IsSystemProxyEndpoint(Uri? request, string host, int port)
    {
        if (systemProxy is null || request is null) return false;
        try
        {
            if (systemProxy.IsBypassed(request)) return false;
            var p = systemProxy.GetProxy(request);
            return p is not null && p != request && string.Equals(p.Host, host, StringComparison.OrdinalIgnoreCase) && p.Port == port;
        }
        catch { return false; }
    }

    private static async ValueTask<Stream> ConnectAsync(SocketsHttpConnectionContext ctx, CancellationToken ct)
    {
        var host = ctx.DnsEndPoint.Host.Trim('[', ']');
        var port = ctx.DnsEndPoint.Port;
        IPAddress[] targets;
        if (IsSystemProxyEndpoint(ctx.InitialRequestMessage.RequestUri, host, port))
        {
            // 사용자가 설정한 프록시(회사망 등): 프록시 자체는 내부망일 수 있으므로 IP 검사 대신 요청 전 이름 확인에 맡긴다
            targets = await Dns.GetHostAddressesAsync(host, ct);
        }
        else
        {
            var addrs = await ResolveCheckedAsync(host, ct);
            if (addrs is null)
            {
                LastBlocked = host;
                throw new BlockedException($"접속 IP {host}");
            }
            targets = addrs;
        }
        Exception? last = null;
        foreach (var ip in targets)
        {
            var s = new Socket(ip.AddressFamily, SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
            try
            {
                await s.ConnectAsync(new IPEndPoint(ip, port), ct);
                return new NetworkStream(s, ownsSocket: true);
            }
            catch (Exception e) { last = e; s.Dispose(); }
        }
        throw last ?? new HttpRequestException("연결 실패");
    }

    // 접속 직전에 다시 푼다(5분 기억을 쓰지 않음): 모든 IP 가 공개 주소여야 하고, 그 IP 로만 접속한다
    internal static async Task<IPAddress[]?> ResolveCheckedAsync(string host, CancellationToken ct)
    {
        if (!UrlSafety.IsPublicHost(host)) return null;
        if (UrlSafety.ParseV4(host) is { } v4) return [new IPAddress(v4)];
        if (host.Contains(':')) return UrlSafety.ParseV6(host) is { } v6 ? [new IPAddress(v6)] : null;
        try
        {
            var all = await Dns.GetHostAddressesAsync(host, ct);
            return all.Length > 0 && all.All(UrlSafety.IsPublic) ? all : null;
        }
        catch (SocketException) { return null; }
    }

    public sealed record Response(int Status, byte[] Body, string? Charset, HttpResponseHeaders Headers, HttpContentHeaders? ContentHeaders, Uri FinalUri);

    // 요청 하나: 이름 확인 → 보내기 → 리다이렉트도 같은 검사(최대 10번) → 본문(32MB 까지)
    public static async Task<Response> GetAsync(string url, Action<HttpRequestMessage>? configure = null, TimeSpan? timeout = null,
        long maxBody = MaxBody, CancellationToken ct = default)
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(timeout ?? TimeSpan.FromSeconds(20));
        var current = url;
        for (var hop = 0; hop < 10; hop++)
        {
            if (!await UrlSafety.ResolvesPublicAsync(current, cts.Token)) throw new BlockedException(hop == 0 ? "주소 확인" : "리다이렉트");
            using var req = new HttpRequestMessage(HttpMethod.Get, current);
            configure?.Invoke(req);
            using var resp = await Client.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, cts.Token);
            var code = (int)resp.StatusCode;
            if (code is >= 300 and < 400 && code != 304 && resp.Headers.Location is { } loc)
            {
                current = new Uri(new Uri(current), loc).AbsoluteUri;
                continue;
            }
            // 304·오류 응답의 본문은 받지 않는다(S-12)
            var body = code is >= 200 and < 300 ? await ReadCappedAsync(resp.Content, maxBody, cts.Token) : [];
            return new Response(code, body, resp.Content.Headers.ContentType?.CharSet?.Trim('"'), resp.Headers, resp.Content.Headers, new Uri(current));
        }
        throw new FeedException("리다이렉트가 너무 많음");
    }

    // 받는 대로 모으다가 상한을 넘으면 그 자리에서 멈춘다(다 받은 뒤 버리지 않음). 헤더의 길이가 이미 넘으면 한 바이트도 받지 않는다(S-12)
    internal static async Task<byte[]> ReadCappedAsync(HttpContent content, long max, CancellationToken ct)
    {
        if (content.Headers.ContentLength is { } len && len > max) throw new TooLargeException(max);
        await using var s = await content.ReadAsStreamAsync(ct);
        using var ms = new MemoryStream();
        var buf = new byte[81920];
        int n;
        while ((n = await s.ReadAsync(buf, ct)) > 0)
        {
            if (ms.Length + n > max) throw new TooLargeException(max);
            ms.Write(buf, 0, n);
        }
        return ms.ToArray();
    }

    // 문자 인코딩 이름 → 글자. 모르면 UTF-8.
    public static string Decode(byte[] data, string? charset)
    {
        Encoding enc;
        try { enc = charset is null ? Encoding.UTF8 : Encoding.GetEncoding(charset); } catch { enc = Encoding.UTF8; }
        return enc.GetString(data);
    }

    static SafeHttp() => Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
}

// 받는 크기 상한(S-12 · 맥 FetchLimit): 피드·사이트맵·채널 찾기 10MB · 기사 페이지 2MB · 사진 8MB. gzip 을 푼 뒤에는 32MB(Gzip)
public static class FetchLimit
{
    public const long Feed = 10_485_760;
    public const long Page = 2_097_152;
    public const long Image = 8_388_608;
}

public sealed class TooLargeException(long limit) : FeedException($"응답이 너무 커서 받다가 멈춤({limit >> 20}MB 넘음)")
{
    public long Limit { get; } = limit;
}
