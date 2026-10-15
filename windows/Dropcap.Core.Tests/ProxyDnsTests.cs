using System.Net;
using System.Net.Sockets;
using System.Text;
using Dropcap.Core;

namespace Dropcap.Core.Tests;

// 보안 점검 W6: 시스템 프록시를 거칠 때도 DNS 바꿔치기 막기.
// 프록시 모드에서는 접속 IP 를 직접 볼 수 없으므로(프록시가 이름을 푼다), 보내기 직전에 목적지 이름을 기억 없이 다시 풀어
// 공개 주소가 아니면 막는다. 프록시 응답을 출처 도메인으로 제한하지는 않는다(사진 CDN·출처 밖 기사·번역이 막히므로 — 맥에서 되돌림).
public sealed class ProxyDnsTests : IDisposable
{
    private readonly TcpListener listener = new(IPAddress.Loopback, 0);
    private int proxied;                       // 가짜 프록시가 받은 요청 수
    private readonly Dictionary<string, IPAddress> names = new(StringComparer.OrdinalIgnoreCase);

    public ProxyDnsTests()
    {
        listener.Start();
        _ = Task.Run(Serve);
    }

    public void Dispose() => listener.Stop();

    // 무엇을 물어도 200 "ok" 를 돌려주는 프록시(회사망 프록시 자리)
    private async Task Serve()
    {
        while (true)
        {
            TcpClient c;
            try { c = await listener.AcceptTcpClientAsync(); } catch { return; }
            _ = Task.Run(async () =>
            {
                using (c)
                {
                    var s = c.GetStream();
                    var buf = new byte[8192];
                    var got = new StringBuilder();
                    while (!got.ToString().Contains("\r\n\r\n"))
                    {
                        var n = await s.ReadAsync(buf);
                        if (n == 0) return;
                        got.Append(Encoding.ASCII.GetString(buf, 0, n));
                    }
                    Interlocked.Increment(ref proxied);
                    await s.WriteAsync(Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"));
                }
            });
        }
    }

    private Task<IPAddress[]> Dns(string host, CancellationToken ct) =>
        Task.FromResult(IPAddress.TryParse(host, out var ip) ? [ip] : names.TryGetValue(host, out var a) ? [a] : Array.Empty<IPAddress>());

    private HttpClient Client() =>
        SafeHttp.Create(new WebProxy($"http://127.0.0.1:{((IPEndPoint)listener.LocalEndpoint).Port}"), Dns);

    [Fact]
    public async Task ProxiedRequestToNameNowPointingInsideIsBlocked()
    {
        // 요청 전 검사(5분 기억)는 공개 주소로 통과했지만, 지금은 이름이 내부망을 가리킨다(바꿔치기)
        names["rebind.example"] = IPAddress.Parse("192.168.0.10");
        using var c = Client();
        await Assert.ThrowsAnyAsync<Exception>(() => c.GetAsync("http://rebind.example/feed"));
        Assert.Equal(0, proxied);                 // 프록시로 나가지도 않음
        names["loop.example"] = IPAddress.Loopback;
        await Assert.ThrowsAnyAsync<Exception>(() => c.GetAsync("http://loop.example/feed"));
        names.Remove("gone.example");             // 풀리지 않는 이름도 막음(직접 연결과 같음)
        await Assert.ThrowsAnyAsync<Exception>(() => c.GetAsync("http://gone.example/feed"));
        Assert.Equal(0, proxied);
    }

    [Fact]
    public async Task ProxiedRequestToPublicNameGoesThroughProxy()
    {
        // 출처 밖 도메인(사진 CDN 등)도 공개 주소면 그대로 — 프록시 응답을 출처 도메인으로 제한하지 않음
        names["cdn.example"] = IPAddress.Parse("93.184.216.34");
        using var c = Client();
        var r = await c.GetAsync("http://cdn.example/photo.jpg");
        Assert.Equal(HttpStatusCode.OK, r.StatusCode);
        Assert.Equal("ok", await r.Content.ReadAsStringAsync());
        Assert.Equal(1, proxied);
    }

    [Fact]
    public async Task EveryProxiedRequestIsCheckedAgain()
    {
        // 기억하지 않는다: 같은 이름이 처음엔 공개, 다음엔 내부망이면 두 번째는 막음
        names["flip.example"] = IPAddress.Parse("93.184.216.34");
        using var c = Client();
        Assert.Equal(HttpStatusCode.OK, (await c.GetAsync("http://flip.example/a")).StatusCode);
        names["flip.example"] = IPAddress.Parse("10.0.0.5");
        await Assert.ThrowsAnyAsync<Exception>(() => c.GetAsync("http://flip.example/b"));
        Assert.Equal(1, proxied);
    }
}
