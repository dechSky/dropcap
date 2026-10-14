using System.Runtime.InteropServices.WindowsRuntime;
using System.Text;
using System.Text.Json;
using Dropcap.Core;
using Microsoft.UI.Dispatching;
using Microsoft.Web.WebView2.Core;

namespace Dropcap.App;

// 화면에 보이지 않는 WebView2 에서 Readability 로 본문만 추린다(R-01·R-02·R-03).
//
// 안전(S-05·S-06·S-10·S-11):
//  - 격리 칸(sandbox): 받아 둔 HTML 을 원래 주소로 띄우되, 응답 머리에 CSP(스크립트·그림·글꼴·스타일시트·연결 모두 금지)를 붙이고
//    그 밖의 요청은 모두 403. 페이지 스크립트는 한 줄도 돌지 않고, 앱이 넣는 추출 코드(ExecuteScript)만 돈다.
//  - 빠른 길(미리 받기·사용자 열기 모두): 앱이 SafeHttp 로 받은 HTML → 격리 칸.
//  - 느린 길(사용자가 연 기사만): 실제 페이지를 띄워(그림·동영상·글꼴 차단, 이동·요청마다 공개 주소 검사)
//    그 HTML 사본만 꺼내 격리 칸에서 추출한다 — 페이지 스크립트는 추출 코드를 볼 수도 건드릴 수도 없다.
internal sealed class Extractor(nint parent, DispatcherQueue ui) : IArticleExtractor
{
    private static readonly Lazy<string> readability = new(() => File.ReadAllText(Path.Combine(WebWindow.WebDir, "Readability.js")));
    private static readonly Lazy<string> script = new(() => File.ReadAllText(Path.Combine(WebWindow.WebDir, "extract.js")));
    private const string Csp = "default-src 'none'; style-src 'unsafe-inline'; img-src 'none'; font-src 'none'; script-src 'none'; connect-src 'none'; frame-src 'none'";
    private const string UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36 Edg/140.0";

    private readonly SemaphoreSlim sandboxGate = new(1, 1);
    private CoreWebView2Controller? sandbox;
    private (string Url, byte[] Html)? serving;

    // WebView2 는 화면 스레드에서만
    private Task<T> OnUi<T>(Func<Task<T>> f)
    {
        var tcs = new TaskCompletionSource<T>();
        if (!ui.TryEnqueue(async () => { try { tcs.SetResult(await f()); } catch (Exception e) { tcs.SetException(e); } }))
            tcs.SetException(new InvalidOperationException("화면 스레드 없음"));
        return tcs.Task;
    }

    public Task<Article?> FromHtmlAsync(string html, Uri baseUri) => OnUi(() => SandboxExtract(html, baseUri));

    public Task<Article?> FromLiveAsync(Uri url) => FromLiveAsync(url, TimeSpan.FromSeconds(15));

    public Task<Article?> FromLiveAsync(Uri url, TimeSpan maxWait) => OnUi(() => LiveExtract(url, maxWait));

    private static async Task<CoreWebView2Controller> Create(nint parent, string profile)
    {
        var env = await WebWindow.EnvAsync();
        var opts = env.CreateCoreWebView2ControllerOptions();
        opts.IsInPrivateModeEnabled = true;       // 쿠키·저장소를 남기지 않음
        opts.ProfileName = profile;
        var c = await env.CreateCoreWebView2ControllerAsync(CoreWebView2ControllerWindowReference.CreateFromWindowHandle((ulong)parent), opts);
        c.IsVisible = false;
        c.Bounds = new Windows.Foundation.Rect(0, 0, 1200, 900);
        var s = c.CoreWebView2.Settings;
        s.AreDevToolsEnabled = false;
        s.AreDefaultContextMenusEnabled = false;
        s.IsStatusBarEnabled = false;
        s.UserAgent = UserAgent;
        c.CoreWebView2.NewWindowRequested += (_, e) => e.Handled = true;   // 팝업 금지
        s.IsWebMessageEnabled = false;            // 추출 칸은 앱과 말을 주고받지 않는다(보안 점검: 한 겹 더)
        s.AreHostObjectsAllowed = false;
        c.CoreWebView2.DownloadStarting += (_, e) => e.Cancel = true;
        c.CoreWebView2.PermissionRequested += (_, e) => e.State = CoreWebView2PermissionState.Deny;
        c.CoreWebView2.IsMuted = true;
        return c;
    }

    // MARK: 격리 칸
    private async Task<CoreWebView2Controller> Sandbox()
    {
        if (sandbox is not null) return sandbox;
        var c = await Create(parent, "dropcap-sandbox");
        var core = c.CoreWebView2;
        // 문서·워커(SharedWorker·ServiceWorker)에서 나온 요청 모두(보안 점검: 문서만 받는 오버로드는 워커의 fetch 를 놓친다)
        core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All, CoreWebView2WebResourceRequestSourceKinds.All);
        core.WebResourceRequested += (_, e) =>
        {
            var env = core.Environment;
            if (serving is { } s && e.Request.Uri == s.Url && e.ResourceContext == CoreWebView2WebResourceContext.Document)
                e.Response = env.CreateWebResourceResponse(new MemoryStream(s.Html).AsRandomAccessStream(), 200, "OK",
                    $"Content-Type: text/html; charset=utf-8\r\nContent-Security-Policy: {Csp}");
            else
                e.Response = env.CreateWebResourceResponse(null, 403, "Forbidden", "");   // 그림·글꼴·스크립트 등 모두 막음(S-10)
        };
        // 격리 칸은 지정한 사본 말고는 어디로도 가지 않는다
        core.NavigationStarting += (_, e) =>
        {
            if (serving is { } s && e.Uri == s.Url) return;
            if (e.Uri.StartsWith("about:", StringComparison.Ordinal)) return;   // data: 이동도 막는다(필요 없음)
            e.Cancel = true;
        };
        return sandbox = c;
    }

    private async Task<Article?> SandboxExtract(string html, Uri baseUri)
    {
        await sandboxGate.WaitAsync();
        try
        {
            var c = await Sandbox();
            serving = (baseUri.AbsoluteUri, Encoding.UTF8.GetBytes(html));
            var done = new TaskCompletionSource<bool>();
            void OnDone(CoreWebView2 s, CoreWebView2NavigationCompletedEventArgs e) => done.TrySetResult(e.IsSuccess);
            c.CoreWebView2.NavigationCompleted += OnDone;
            try
            {
                c.CoreWebView2.Navigate(baseUri.AbsoluteUri);
                await Task.WhenAny(done.Task, Task.Delay(6000));
            }
            finally { c.CoreWebView2.NavigationCompleted -= OnDone; }
            return await Run(c.CoreWebView2);
        }
        catch { return null; }
        finally
        {
            serving = null;
            sandboxGate.Release();
        }
    }

    private static async Task<Article?> Run(CoreWebView2 core)
    {
        var raw = await core.ExecuteScriptAsync(readability.Value + "\n;\n" + script.Value);
        // 돌려받는 값은 JSON 으로 감싼 글자(추출 결과 JSON) 또는 null
        if (string.IsNullOrEmpty(raw) || raw == "null") return null;
        var inner = JsonSerializer.Deserialize<string>(raw);
        return inner is null ? null : Json.Decode<Article>(inner);
    }

    // MARK: 느린 길(R-02): 실제로 띄우고 0.6초 뒤부터 0.4초마다 추출 시도, 두 번 같으면 끝, 최대 15초(접근 거부 사이트는 6초)
    private async Task<Article?> LiveExtract(Uri url, TimeSpan maxWait)
    {
        if (!await UrlSafety.ResolvesPublicAsync(url.AbsoluteUri)) return null;
        var c = await Create(parent, "dropcap-live");
        var core = c.CoreWebView2;
        try
        {
            // 그림·동영상·글꼴은 받지 않는다(S-10). 문서·워커에서 나온 모든 요청을 거친다(보안 점검: 워커의 fetch 도).
            // GET 은 앱이 SafeHttp 로 대신 받아 돌려준다 — 접속하는 순간 IP 를 검사하고 그 IP 로만 붙으므로 DNS 바꿔치기로 내부망 응답을
            // 페이지가 읽을 수 없다(브라우저가 따로 이름을 풀지 않음). GET 이 아닌 요청(POST 등)은 본문 추출에 필요 없어 막는다.
            core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All, CoreWebView2WebResourceRequestSourceKinds.All);
            core.WebResourceRequested += async (_, e) =>
            {
                var env = core.Environment;
                if (e.ResourceContext is CoreWebView2WebResourceContext.Image or CoreWebView2WebResourceContext.Media or CoreWebView2WebResourceContext.Font
                    or CoreWebView2WebResourceContext.Websocket || !string.Equals(e.Request.Method, "GET", StringComparison.OrdinalIgnoreCase))
                {
                    e.Response = env.CreateWebResourceResponse(null, 403, "Forbidden", "");
                    return;
                }
                if (e.Request.Uri.StartsWith("data:", StringComparison.Ordinal)) return;
                var d = e.GetDeferral();
                try
                {
                    var r = await SafeHttp.GetAsync(e.Request.Uri, req =>
                    {
                        if (e.Request.Headers.GetHeader("Accept") is { Length: > 0 } accept) req.Headers.TryAddWithoutValidation("Accept", accept);
                        req.Headers.TryAddWithoutValidation("User-Agent", UserAgent);
                    }, timeout: TimeSpan.FromSeconds(10), maxBody: (long)FetchLimit.Page);
                    // 리다이렉트를 따라갔으면 본문 대신 최종 주소로 넘긴다: 다른 곳의 응답을 요청한 주소(출처)의 것으로 내주지 않게
                    // (보안 검토: 출처 혼동). 브라우저가 최종 주소로 다시 요청하면 이 처리기를 다시 거친다.
                    if (r.FinalUri.AbsoluteUri != new Uri(e.Request.Uri).AbsoluteUri)
                    {
                        e.Response = env.CreateWebResourceResponse(null, 302, "Found", $"Location: {r.FinalUri.AbsoluteUri}");
                        return;
                    }
                    var type = r.ContentHeaders?.ContentType?.ToString() ?? "application/octet-stream";
                    e.Response = env.CreateWebResourceResponse(new MemoryStream(r.Body).AsRandomAccessStream(), r.Status, "OK",
                        $"Content-Type: {type.Replace("\r", "").Replace("\n", "")}");
                }
                catch { e.Response = env.CreateWebResourceResponse(null, 403, "Forbidden", ""); }
                finally { d.Complete(); }
            };
            // 페이지가 내부망 주소로 이동하거나 넘기려 하면 막는다(about:·data: 만 예외)
            // 이동 이벤트는 기다려 줄 수 없으므로: 검사를 마친 주소만 통과시키고, 처음 보는 주소는 막은 뒤 검사가 끝나면 다시 이동한다
            var approved = new HashSet<string> { url.AbsoluteUri };
            core.NavigationStarting += (sender, e) =>
            {
                var target = e.Uri;
                if (target.StartsWith("about:", StringComparison.Ordinal)) return;   // data: 로 이동은 막는다(내려받기·우회 길)
                if (approved.Contains(target)) return;
                e.Cancel = true;
                if (!UrlSafety.IsPublicHttp(target)) return;
                _ = Task.Run(async () =>
                {
                    if (!await UrlSafety.ResolvesPublicAsync(target)) return;
                    ui.TryEnqueue(() => { approved.Add(target); try { core.Navigate(target); } catch { } });
                });
            };
            core.Navigate(url.AbsoluteUri);
            var deadline = DateTime.UtcNow.Add(maxWait);
            await Task.Delay(600);
            var last = 0;
            Article? best = null;
            while (DateTime.UtcNow < deadline)
            {
                if (await Snapshot(core) is { } html && Uri.TryCreate(core.Source, UriKind.Absolute, out var at) && UrlSafety.IsPublicHttp(at.AbsoluteUri))
                {
                    var art = await SandboxExtract(html, at);
                    if (art is { LooksLikeArticle: true })
                    {
                        best = art;
                        var n = art.Blocks.Count;
                        if (n >= 4 && n == last) return art;   // 두 번 연속 같으면 다 그려진 것
                        last = n;
                    }
                }
                await Task.Delay(400);
            }
            return best;
        }
        catch { return null; }
        finally { c.Close(); }
    }

    // 페이지의 지금 HTML 사본(이 값만 격리 칸으로 넘어간다)
    private static async Task<string?> Snapshot(CoreWebView2 core)
    {
        try
        {
            var raw = await core.ExecuteScriptAsync("document.documentElement ? document.documentElement.outerHTML : null");
            return raw is null or "null" ? null : JsonSerializer.Deserialize<string>(raw);
        }
        catch { return null; }
    }
}
