using System.Runtime.InteropServices.WindowsRuntime;
using Dropcap.Core;
using Dropcap.Ui;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using Windows.Graphics;
using static Dropcap.App.Win32;

namespace Dropcap.App;

// 웹 화면(web/<화면>.html)을 띄운 WinUI 3 창. 앱이 만든 페이지만 띄우고, 바깥 요청은 모두 막는다.
//  - https://app.dropcap.example/ → 앱의 web 폴더(가상 호스트)
//  - https://img.dropcap.example/?u= → 안전 사진 로더(S-07·R-18)
//  - 그 밖의 요청 → 403, 바깥으로 가는 이동 → 막고 사용자가 누른 링크만 ExternalLink 로(S-08)
internal sealed class WebWindow
{
    public const string AppHost = "app.dropcap.example";
    public const string ImgHost = "img.dropcap.example";

    public Window Window { get; }
    public WebView2 View { get; }
    public string Page { get; }
    public AppWindow AppWindow => Window.AppWindow;
    public nint Hwnd { get; }
    public event Action? Closed;

    private readonly Bridge bridge;
    private string query;
    private IDisposable? attach;
    private CoreWebView2? core;
    private static CoreWebView2Environment? env;
    private static readonly SemaphoreSlim envGate = new(1, 1);

    public static string WebDir => Path.Combine(AppContext.BaseDirectory, "web");

    public WebWindow(Bridge bridge, string page, string query, string title, SizeInt32 size)
    {
        this.bridge = bridge;
        Page = page;
        this.query = query;
        View = new WebView2 { DefaultBackgroundColor = Platform.DarkMode() ? Windows.UI.Color.FromArgb(255, 30, 30, 30) : Windows.UI.Color.FromArgb(255, 245, 245, 247) };
        Window = new Window { Content = View, Title = title };
        Hwnd = WinRT.Interop.WindowNative.GetWindowHandle(Window);
        AppWindow.Resize(Scaled(size));
        if (File.Exists(Platform.IconPath)) AppWindow.SetIcon(Platform.IconPath);
        Window.Closed += (_, _) => { attach?.Dispose(); Closed?.Invoke(); };
        _ = InitAsync();
    }

    public double Scale => GetDpiForWindow(Hwnd) / 96.0;
    public SizeInt32 Scaled(SizeInt32 s) { var k = Math.Max(1, GetDpiForWindow(Hwnd) / 96.0); return new SizeInt32((int)(s.Width * k), (int)(s.Height * k)); }

    public static async Task<CoreWebView2Environment> EnvAsync()
    {
        await envGate.WaitAsync();
        try
        {
            return env ??= await CoreWebView2Environment.CreateWithOptionsAsync("", Path.Combine(Store.Dir, "webview"), new CoreWebView2EnvironmentOptions());
        }
        finally { envGate.Release(); }
    }

    private async Task InitAsync()
    {
        await View.EnsureCoreWebView2Async(await EnvAsync());
        core = View.CoreWebView2;
        var s = core.Settings;
        s.AreDefaultContextMenusEnabled = false;      // 화면이 자기 메뉴를 그림(글 칸은 웹 기본)
        s.AreBrowserAcceleratorKeysEnabled = false;   // Ctrl+F·Ctrl+P·F5 등은 화면이 받음
        s.IsStatusBarEnabled = false;
        s.IsZoomControlEnabled = false;
        s.IsPinchZoomEnabled = false;
        s.IsSwipeNavigationEnabled = false;
        s.IsGeneralAutofillEnabled = false;
        s.IsPasswordAutosaveEnabled = false;
        s.AreDevToolsEnabled = Environment.GetEnvironmentVariable("DROPCAP_DEVTOOLS") == "1";
        core.SetVirtualHostNameToFolderMapping(AppHost, WebDir, CoreWebView2HostResourceAccessKind.Deny);
        core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All);
        core.WebResourceRequested += OnResource;
        core.NavigationStarting += (_, e) =>
        {
            if (Uri.TryCreate(e.Uri, UriKind.Absolute, out var u) && u.Host == AppHost) return;
            e.Cancel = true;
            if (e.IsUserInitiated) ExternalLink.Open(e.Uri);   // 공개 http(s) 만
        };
        core.NewWindowRequested += (_, e) => { e.Handled = true; if (e.IsUserInitiated) ExternalLink.Open(e.Uri); };
        core.DownloadStarting += (_, e) => e.Cancel = true;
        core.PermissionRequested += (_, e) => e.State = CoreWebView2PermissionState.Deny;
        core.WebMessageReceived += async (_, e) =>
        {
            // 앱 폴더(가상 호스트)에서 온 말만 듣는다(보안 점검: 한 겹 더 — 지금은 iframe 이 막혀 있어 다른 출처가 없음)
            if (!Uri.TryCreate(e.Source, UriKind.Absolute, out var from) || from.Host != AppHost) return;
            var reply = await bridge.Receive(Page, e.WebMessageAsJson);
            core?.PostWebMessageAsJson(reply);
        };
        var q = Window.DispatcherQueue;
        attach = bridge.Attach(Page, json => q.TryEnqueue(() => core?.PostWebMessageAsJson(json)));
        core.NavigationCompleted += (_, _) => SendAppearance();
        core.Navigate($"https://{AppHost}/{Page}.html{(query.Length == 0 ? "" : query.StartsWith('#') ? query : "?" + query)}");
    }

    // 같은 창에서 다른 주소로(읽기 창 J·K, H-05)
    public void Go(string newQuery)
    {
        query = newQuery;
        core?.Navigate($"https://{AppHost}/{Page}.html{(query.Length == 0 ? "" : "?" + query)}");
    }

    public void SendAppearance() =>
        core?.PostWebMessageAsJson(System.Text.Json.JsonSerializer.Serialize(new
        {
            @event = "appearance",
            data = new { pretendard = Prefs.Get("usePretendard", true), reduceMotion = Platform.AnimationsOff() },
        }, Json.Options));

    private async void OnResource(CoreWebView2 sender, CoreWebView2WebResourceRequestedEventArgs e)
    {
        if (!Uri.TryCreate(e.Request.Uri, UriKind.Absolute, out var u)) { e.Response = Deny(); return; }
        if (u.Host == AppHost) return;                     // 가상 호스트가 앱 폴더에서 준다
        if (u.Host != ImgHost) { e.Response = Deny(); return; }   // 바깥 요청은 모두 막음
        var deferral = e.GetDeferral();
        try
        {
            var target = System.Web.HttpUtility.ParseQueryString(u.Query)["u"];
            var bytes = target is null ? null : await ImageLoader.Shared.JpegAsync(target);
            e.Response = bytes is null ? Deny(404)
                : env!.CreateWebResourceResponse(new MemoryStream(bytes).AsRandomAccessStream(), 200, "OK", "Content-Type: image/jpeg\r\nCache-Control: max-age=86400");
        }
        catch { e.Response = Deny(); }
        finally { deferral.Complete(); }
    }

    private static CoreWebView2WebResourceResponse Deny(int code = 403) => env!.CreateWebResourceResponse(null, code, code == 404 ? "Not Found" : "Forbidden", "");

    public void Emit(string ev, object? data = null) => bridge.Emit(Page, ev, data);

    // 창 테두리: 둥근 모서리(윈도우 11)
    public void RoundCorners()
    {
        var v = DWMWCP_ROUND;
        DwmSetWindowAttribute(Hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref v, sizeof(int));
    }

    // 작업 표시줄·Alt+Tab 에서 숨김(트레이 창)
    public void HideFromTaskbar()
    {
        AppWindow.IsShownInSwitchers = false;
        var ex = GetWindowLongPtr(Hwnd, GWL_EXSTYLE);
        SetWindowLongPtr(Hwnd, GWL_EXSTYLE, (ex | WS_EX_TOOLWINDOW) & ~(nint)WS_EX_APPWINDOW);
    }

    // 창 열기(docs/DESIGN.md · 맥 WindowMotion 과 같은 규칙): 제자리에서 0.96 → 1 로 살짝 커지며 내용이 나타난다(0.25초, 들어옴 곡선).
    // 모든 앱 창(읽기·매거진·분야 고르기·설정)이 이것으로 열린다. 시스템 '애니메이션 효과'가 꺼져 있으면 그냥 나타난다.
    // WinUI 창 자체는 투명도를 바꿀 수 없어 창 틀은 바로 보이고 내용(WebView)만 0 → 1 로 흐려졌다가 또렷해진다.
    public void Present()
    {
        var to = new RectInt32(AppWindow.Position.X, AppWindow.Position.Y, AppWindow.Size.Width, AppWindow.Size.Height);
        if (Platform.AnimationsOff()) { Window.Activate(); return; }
        int dw = (int)Math.Round(to.Width * (1 - Motion.StartScale) / 2), dh = (int)Math.Round(to.Height * (1 - Motion.StartScale) / 2);
        var from = new RectInt32(to.X + dw, to.Y + dh, to.Width - 2 * dw, to.Height - 2 * dh);
        View.Opacity = 0;
        AppWindow.MoveAndResize(from);
        Window.Activate();
        var t0 = DateTime.UtcNow;
        var timer = Window.DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromMilliseconds(10);
        timer.Tick += (tm, _) =>
        {
            var k = Math.Min(1, (DateTime.UtcNow - t0).TotalSeconds / Motion.Standard);
            var e = Motion.Enter(k);
            int L(int a, int b) => (int)Math.Round(a + (b - a) * e);
            AppWindow.MoveAndResize(new RectInt32(L(from.X, to.X), L(from.Y, to.Y), L(from.Width, to.Width), L(from.Height, to.Height)));
            View.Opacity = e;
            if (k >= 1) { View.Opacity = 1; tm.Stop(); }
        };
        timer.Start();
    }
}
