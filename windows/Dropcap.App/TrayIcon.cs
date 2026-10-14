using System.Runtime.InteropServices;
using Dropcap.Ui.Toast;
using Microsoft.Win32;
using SkiaSharp;
using static Dropcap.App.Win32;

namespace Dropcap.App;

// 트레이 아이콘(U-01): 신문 모양, 안 읽은 소식이 있으면 채워진 모양. 누르면 작은 창을 띄운다.
internal sealed class TrayIcon : IDisposable
{
    private readonly MessageWindow window;
    private nint icon;
    private bool filled;
    private bool added;
    private string tip = "Dropcap";

    public event Action<int, int>? Clicked;    // 화면 좌표

    public TrayIcon(MessageWindow window)
    {
        this.window = window;
        window.Tray += OnTray;
        window.TaskbarCreated += () => { added = false; Show(); };   // 탐색기가 다시 시작되면 다시 넣는다
        window.SettingChanged += () => Update(filled, tip, force: true); // 작업 표시줄 밝기가 바뀌면 색도
    }

    private void OnTray(uint ev, int x, int y)
    {
        if (ev is NIN_SELECT or NIN_KEYSELECT or WM_LBUTTONUP or WM_CONTEXTMENU) Clicked?.Invoke(x, y);
    }

    private NOTIFYICONDATA Data() => new()
    {
        cbSize = Marshal.SizeOf<NOTIFYICONDATA>(),
        hWnd = window.Handle,
        uID = 1,
        uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP,
        uCallbackMessage = MessageWindow.TrayMessage,
        hIcon = icon,
        szTip = tip,
        szInfo = "",
        szInfoTitle = "",
    };

    public void Show()
    {
        if (icon == 0) icon = MakeIcon(filled);
        var d = Data();
        if (!added)
        {
            added = Shell_NotifyIcon(NIM_ADD, ref d);
            d.uVersion = NOTIFYICON_VERSION_4;
            Shell_NotifyIcon(NIM_SETVERSION, ref d);
        }
        else Shell_NotifyIcon(NIM_MODIFY, ref d);
    }

    public void Update(bool unread, string tooltip, bool force = false)
    {
        if (!force && unread == filled && tooltip == tip) return;
        filled = unread;
        tip = tooltip.Length > 127 ? tooltip[..127] : tooltip;
        var old = icon;
        icon = MakeIcon(filled);
        Show();
        if (old != 0) DestroyIcon(old);
    }

    // 트레이 아이콘이 화면 어디에 있는지(작은 창을 그 곁에 띄우려고)
    public RECT? Rect()
    {
        var id = new NOTIFYICONIDENTIFIER { cbSize = Marshal.SizeOf<NOTIFYICONIDENTIFIER>(), hWnd = window.Handle, uID = 1 };
        return Shell_NotifyIconGetRect(ref id, out var r) == 0 ? r : null;
    }

    // 작업 표시줄이 밝은 테마면 검은 아이콘, 어두우면 흰 아이콘
    private static bool LightTaskbar()
    {
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return k?.GetValue("SystemUsesLightTheme") is int v && v == 1;
        }
        catch { return false; }
    }

    private static nint MakeIcon(bool filled)
    {
        var size = (int)Math.Round(16 * Math.Max(1, GetDpiForWindow(GetForegroundWindow()) / 96.0));
        size = Math.Clamp(size, 16, 64);
        using var bmp = AppIcon.Tray(size, filled, LightTaskbar() ? new SKColor(0, 0, 0) : new SKColor(255, 255, 255));
        return ToHIcon(bmp);
    }

    public static nint ToHIcon(SKBitmap bmp)
    {
        var bi = new BITMAPINFOHEADER { biSize = Marshal.SizeOf<BITMAPINFOHEADER>(), biWidth = bmp.Width, biHeight = -bmp.Height, biPlanes = 1, biBitCount = 32 };
        var color = CreateDIBSection(0, ref bi, 0, out var bits, 0, 0);
        using (var straight = bmp.Copy(SKColorType.Bgra8888))
        {
            if (straight.AlphaType == SKAlphaType.Premul)
            {
                using var un = new SKBitmap(new SKImageInfo(bmp.Width, bmp.Height, SKColorType.Bgra8888, SKAlphaType.Unpremul));
                straight.CopyTo(un, SKColorType.Bgra8888);
                Marshal.Copy(un.Bytes, 0, bits, un.Bytes.Length);
            }
            else Marshal.Copy(straight.Bytes, 0, bits, straight.Bytes.Length);
        }
        var mask = CreateBitmap(bmp.Width, bmp.Height, 1, 1, 0);
        var info = new ICONINFO { fIcon = true, hbmColor = color, hbmMask = mask };
        var h = CreateIconIndirect(ref info);
        DeleteObject(color);
        DeleteObject(mask);
        return h;
    }

    public void Dispose()
    {
        var d = Data();
        Shell_NotifyIcon(NIM_DELETE, ref d);
        if (icon != 0) DestroyIcon(icon);
    }
}
