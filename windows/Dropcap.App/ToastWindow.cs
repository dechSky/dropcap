using System.Diagnostics;
using System.Runtime.InteropServices;
using Dropcap.Core;
using Dropcap.Ui;
using Dropcap.Ui.Toast;
using Microsoft.UI.Dispatching;
using Microsoft.Win32;
using static Dropcap.App.Win32;

namespace Dropcap.App;

// 물방울 알림 창(N 절): 투명·항상 위·초점을 빼앗지 않음·카드 밖은 클릭 통과(N-22).
// SkiaSharp 로 그린 장면을 레이어드 창(UpdateLayeredWindow, 픽셀마다 알파)에 올린다.
internal sealed class ToastWindow : IDisposable
{
    private readonly ToastEngine engine = new();
    private readonly ToastRenderer renderer;
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private readonly DispatcherQueueTimer timer;
    private readonly WndProc proc;
    private readonly nint hwnd;
    private readonly AppModel model;
    private GCHandle soundPin;

    private double scale = 1;
    private POINT origin;            // 창 왼쪽 위(화면 픽셀)
    private nint monitor;            // 지금 창이 있는 모니터
    private bool shown;
    private bool clickable;          // 카드 위라 클릭을 받는 중
    private double? otherScreenSince;
    private double? fadeStart;       // 다른 화면으로 옮겨 가는 중(0.14초 사라짐 → 자리 옮김 → 0.2초 나타남)
    private bool fadeMoved;
    private double lastFrame;
    private double? emptySince;

    public event Action<ToastCard>? Opened;

    private double Now => clock.Elapsed.TotalSeconds;

    public ToastWindow(AppModel model, DispatcherQueue queue)
    {
        this.model = model;
        renderer = new ToastRenderer(engine)
        {
            Image = url => ImageLoader.Shared.Cached(url) ?? Fetch(url),
            IsSaved = model.IsSaved,
        };
        engine.Measure = renderer.Measure;
        engine.AccentOf = id => ItemView.SafeColor(model.SourceById(id)?.Color);
        engine.Sound += _ => PlayDrop();
        engine.Opened += c => Opened?.Invoke(c);
        engine.NeedsThumb += FindThumb;
        soundPin = GCHandle.Alloc(DropSound.Wav, GCHandleType.Pinned);

        proc = Proc;
        var cls = new WNDCLASSEX { cbSize = Marshal.SizeOf<WNDCLASSEX>(), lpfnWndProc = proc, hInstance = GetModuleHandle(null), lpszClassName = "DropcapToast" };
        RegisterClassEx(ref cls);
        hwnd = CreateWindowEx(WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST,
            cls.lpszClassName, "Dropcap 알림", WS_POPUP, 0, 0, 1, 1, 0, 0, cls.hInstance, 0);

        timer = queue.CreateTimer();
        timer.Interval = TimeSpan.FromMilliseconds(16);
        timer.Tick += (_, _) => Frame();
    }

    // MARK: 넣기(AppUi 가 부름)
    public void ShowNews(IReadOnlyList<NewsItem> items, bool sound) { Prepare(); engine.Show(items, sound, Now); Start(); }
    public void ShowInfo(string title, string sub) { Prepare(); engine.ShowInfo(title, sub, Now); Start(); }
    public void ShowDigest(int count, bool sound) { Prepare(); engine.ShowDigest(count, sound, Now); Start(); }
    public void ShowWelcome() { Prepare(); engine.ShowWelcome(Now); Start(); }
    public void ShowBundle(string section, IReadOnlyList<NewsItem> items, bool sound) { Prepare(); engine.ShowBundle(section, items, sound, Now); Start(); }

    private void Prepare()
    {
        engine.ReduceMotion = Platform.AnimationsOff();   // N-24
        renderer.Dark = Platform.DarkMode();
        Fonts.UsePretendard = Prefs.Get("usePretendard", true);
        // 새 알림은 언제나 마우스가 있는 화면에(N-11)
        if (!shown || MonitorHandleAt(Cursor()) != monitor) Place();
    }

    private void Start()
    {
        emptySince = null;
        if (!shown)
        {
            ShowWindow(hwnd, SW_SHOWNOACTIVATE);   // 지금 쓰던 앱의 입력 초점은 빼앗지 않는다
            SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
            shown = true;
        }
        if (!timer.IsRunning) timer.Start();
    }

    public void Replace() { if (shown) Place(); }   // 화면 구성이 바뀌면 다시 자리 잡음

    private static POINT Cursor() { GetCursorPos(out var p); return p; }

    // 천장(N-20): 커서가 있는 모니터의 작업 영역 위쪽 가장자리(작업 표시줄이 위에 있으면 그 아래). 가운데 또는 오른쪽 위.
    private void Place()
    {
        var p = Cursor();
        var (work, _, s) = MonitorAt(p);
        monitor = MonitorHandleAt(p);
        scale = s;
        var w = (int)Math.Ceiling(ToastEngine.PanelWidth * scale);
        var center = model.State.Settings.Position == ToastPosition.Center;
        var x = center ? work.Left + (work.Width - w) / 2 : work.Right - w - (int)(2 * scale);
        origin = new POINT { X = x, Y = work.Top };
    }

    // MARK: 한 장면
    private void Frame()
    {
        var now = Now;
        engine.Tick(now);
        if (!engine.Visible)
        {
            // 다 사라지면 0.4초 뒤 창을 숨긴다
            emptySince ??= now;
            if (now - emptySince > 0.4) Hide();
            return;
        }
        emptySince = null;
        TrackMouse(now);
        // 잔잔하면 초당 12번만(N-03)
        var fps = engine.FramesPerSecond(now);
        timer.Interval = TimeSpan.FromMilliseconds(fps >= 60 ? 16 : 33);
        if (fps < 60 && now - lastFrame < 1.0 / 12 && fadeStart is null) return;
        lastFrame = now;
        Draw(now);
    }

    private void Draw(double now)
    {
        byte alpha = 255;
        if (fadeStart is { } fs)
        {
            var k = now - fs;
            if (k < 0.14) alpha = (byte)(255 * (1 - k / 0.14));
            else
            {
                if (!fadeMoved) { fadeMoved = true; Place(); }
                var k2 = (k - 0.14) / 0.2;
                alpha = (byte)(255 * Math.Clamp(k2, 0, 1));
                if (k2 >= 1) fadeStart = null;
            }
        }
        using var bmp = renderer.RenderBitmap(now, (float)scale);
        Blit(bmp, alpha);
    }

    private void Blit(SkiaSharp.SKBitmap bmp, byte alpha)
    {
        var screen = GetDC(0);
        var mem = CreateCompatibleDC(screen);
        var bi = new BITMAPINFOHEADER { biSize = Marshal.SizeOf<BITMAPINFOHEADER>(), biWidth = bmp.Width, biHeight = -bmp.Height, biPlanes = 1, biBitCount = 32 };
        var dib = CreateDIBSection(mem, ref bi, 0, out var bits, 0, 0);
        Marshal.Copy(bmp.Bytes, 0, bits, bmp.Bytes.Length);   // BGRA, 미리 곱한 알파
        var old = SelectObject(mem, dib);
        var size = new SIZE { cx = bmp.Width, cy = bmp.Height };
        var src = new POINT();
        var pos = origin;
        var blend = new BLENDFUNCTION { BlendOp = 0, SourceConstantAlpha = alpha, AlphaFormat = AC_SRC_ALPHA };
        UpdateLayeredWindow(hwnd, screen, ref pos, ref size, mem, ref src, 0, ref blend, ULW_ALPHA);
        SelectObject(mem, old);
        DeleteObject(dib);
        DeleteDC(mem);
        ReleaseDC(0, screen);
    }

    private void Hide()
    {
        timer.Stop();
        ShowWindow(hwnd, SW_HIDE);
        shown = false;
        SetClickable(false);
    }

    // MARK: 마우스(N-13): 카드 위에 있을 때만 창이 클릭을 받는다. 카드 영역은 카드 자체 크기로.
    private (float X, float Y) Local(POINT p) => ((float)((p.X - origin.X) / scale), (float)((p.Y - origin.Y) / scale));

    private void TrackMouse(double now)
    {
        var p = Cursor();
        FollowCursorScreen(p, now);
        var (x, y) = Local(p);
        var hit = engine.HitTest(x, y);
        SetClickable(hit.Card is not null);
        engine.SetHover(hit.Card);   // 카드의 '마우스 올림' 상태는 여기서만 정한다
    }

    private void SetClickable(bool on)
    {
        if (clickable == on) return;
        clickable = on;
        var ex = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
        ex = on ? ex & ~(nint)WS_EX_TRANSPARENT : ex | WS_EX_TRANSPARENT;
        SetWindowLongPtr(hwnd, GWL_EXSTYLE, ex);
    }

    // 알림이 떠 있는 동안 마우스가 다른 화면에 0.25초 머물면 카드가 살짝 사라졌다가 그 화면에 다시 나타난다(N-11)
    private void FollowCursorScreen(POINT p, double now)
    {
        if (fadeStart is not null || engine.Cards.Count == 0) return;
        if (MonitorHandleAt(p) == monitor) { otherScreenSince = null; return; }
        otherScreenSince ??= now;
        if (now - otherScreenSince < 0.25) return;
        otherScreenSince = null;
        fadeStart = now;
        fadeMoved = false;
    }

    private nint Proc(nint h, uint msg, nint wParam, nint lParam)
    {
        switch (msg)
        {
            case WM_MOUSEACTIVATE:
                return MA_NOACTIVATE;   // 눌러도 이 창이 초점을 가져가지 않음
            case WM_RBUTTONUP:
            {
                var (rx, ry) = Local(new POINT { X = origin.X + (short)(lParam & 0xFFFF), Y = origin.Y + (short)((lParam >> 16) & 0xFFFF) });
                if (engine.HitTest(rx, ry).Card is { Item: { } it } card) ReduceMenu(card, it);
                return 0;
            }
            case WM_LBUTTONUP:
                var (x, y) = Local(new POINT { X = origin.X + (short)(lParam & 0xFFFF), Y = origin.Y + (short)((lParam >> 16) & 0xFFFF) });
                OnClick(engine.HitTest(x, y));
                return 0;
        }
        return DefWindowProc(h, msg, wParam, lParam);
    }

    private void OnClick(Hit hit)
    {
        if (hit.Card is not { } c) return;
        switch (hit.Part)
        {
            case HitPart.Save when c.Item is { } it:
                model.ToggleSaved(it);
                break;
            case HitPart.Browser when c.Item is { } it:
                ExternalLink.Open(it.Link);
                model.SetRead(it, true);
                engine.Leave(c, quick: true, Now);
                break;
            default:
                engine.Click(hit, Now);
                break;
        }
    }

    // 카드의 화면 위치(읽기 창이 그 자리에서 커져 나오게)
    public Windows.Graphics.RectInt32? CardScreenRect(ToastCard c)
    {
        if (!engine.Cards.Contains(c)) return null;
        var left = (ToastEngine.PanelWidth - ToastEngine.CardWidth) / 2;
        return new Windows.Graphics.RectInt32(origin.X + (int)(left * scale), origin.Y + (int)(c.Y * scale), (int)(ToastEngine.CardWidth * scale), (int)(c.Height * scale));
    }

    // 바로 줄이기(G-11): 이 출처 숨기기 · 이 분야 덜 받기 · 이 낱말 알리지 않기(제목 낱말 고르기)
    private void ReduceMenu(ToastCard card, NewsItem it)
    {
        var menu = CreatePopupMenu();
        var words = CreatePopupMenu();
        var list = AppModel.TitleWords(it);
        for (var i = 0; i < list.Count; i++) AppendMenu(words, MF_STRING, (nuint)(100 + i), list[i]);
        var sec = model.NotifySection(it);
        AppendMenu(menu, MF_STRING, 1, $"이 출처 숨기기 · {it.SourceName}");
        AppendMenu(menu, MF_STRING, 2, $"이 분야 덜 받기 · {Sections.Name(sec)} ({model.Policy(sec).Mode.Label()} → {(model.Policy(sec).Mode == NotifyMode.Instant ? "묶음" : "매거진만")})");
        AppendMenu(menu, MF_POPUP | (list.Count == 0 ? MF_GRAYED : 0), (nuint)words, "이 낱말 알리지 않기");
        GetCursorPos(out var p);
        SetForegroundWindow(hwnd);   // 메뉴가 바깥을 누르면 닫히게(이 순간만)
        var cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY, p.X, p.Y, 0, hwnd, 0);
        DestroyMenu(menu);
        switch (cmd)
        {
            case 1: model.HideSource(it.SourceId); engine.Leave(card, quick: true, Now); break;
            case 2: model.LessOf(sec); break;
            case >= 100 when cmd - 100 < list.Count: model.MuteWord(list[cmd - 100]); engine.Leave(card, quick: true, Now); break;
        }
    }

    // MARK: 사진(N-06): 피드에 없으면 떨어지는 동안 og:image 를 찾아 온다
    private async void FindThumb(ToastCard c)
    {
        if (c.Item is not { } it) return;
        var url = await FeedService.Shared.OgImageAsync(it.Link);
        if (url is null || c.Leaving) return;
        c.Thumb = url;
        c.Height = renderer.Measure(c);
        _ = ImageLoader.Shared.ImageAsync(url);
    }

    private readonly HashSet<string> fetching = new();
    private SkiaSharp.SKImage? Fetch(string url)
    {
        if (fetching.Add(url)) _ = ImageLoader.Shared.ImageAsync(url);
        return null;
    }

    // "똑"(N-04): 파일 없이 메모리의 WAV
    private void PlayDrop()
    {
        try { PlaySound(soundPin.AddrOfPinnedObject(), 0, SND_MEMORY | SND_ASYNC | SND_NODEFAULT); } catch { }
    }

    public void Dispose()
    {
        timer.Stop();
        DestroyWindow(hwnd);
        if (soundPin.IsAllocated) soundPin.Free();
    }
}
