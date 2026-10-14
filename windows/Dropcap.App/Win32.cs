using System.Runtime.InteropServices;

namespace Dropcap.App;

// 윈도우 API(트레이·단축키·레이어드 창·모니터·전원·소리). 필요한 것만.
internal static class Win32
{
    public delegate nint WndProc(nint hWnd, uint msg, nint wParam, nint lParam);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WNDCLASSEX
    {
        public int cbSize;
        public uint style;
        public WndProc lpfnWndProc;
        public int cbClsExtra, cbWndExtra;
        public nint hInstance, hIcon, hCursor, hbrBackground;
        public string? lpszMenuName;
        public string lpszClassName;
        public nint hIconSm;
    }

    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct SIZE { public int cx, cy; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; public int Width => Right - Left; public int Height => Bottom - Top; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct MONITORINFO { public int cbSize; public RECT rcMonitor, rcWork; public uint dwFlags; }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public struct BLENDFUNCTION { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }

    [StructLayout(LayoutKind.Sequential)]
    public struct BITMAPINFOHEADER
    {
        public int biSize, biWidth, biHeight;
        public short biPlanes, biBitCount;
        public int biCompression, biSizeImage, biXPelsPerMeter, biYPelsPerMeter, biClrUsed, biClrImportant;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct NOTIFYICONDATA
    {
        public int cbSize;
        public nint hWnd;
        public uint uID, uFlags, uCallbackMessage;
        public nint hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szTip;
        public uint dwState, dwStateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szInfo;
        public uint uVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string szInfoTitle;
        public uint dwInfoFlags;
        public Guid guidItem;
        public nint hBalloonIcon;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct NOTIFYICONIDENTIFIER { public int cbSize; public nint hWnd; public uint uID; public Guid guidItem; }

    [StructLayout(LayoutKind.Sequential)]
    public struct ICONINFO { public bool fIcon; public int xHotspot, yHotspot; public nint hbmMask, hbmColor; }

    public const uint WS_POPUP = 0x80000000, WS_VISIBLE = 0x10000000;
    public const int WS_EX_LAYERED = 0x80000, WS_EX_TRANSPARENT = 0x20, WS_EX_NOACTIVATE = 0x08000000, WS_EX_TOOLWINDOW = 0x80, WS_EX_TOPMOST = 0x8, WS_EX_APPWINDOW = 0x40000;
    public const int GWL_EXSTYLE = -20, GWL_STYLE = -16;
    public const int SW_HIDE = 0, SW_SHOWNOACTIVATE = 4;
    public const uint SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2, SWP_NOACTIVATE = 0x10, SWP_SHOWWINDOW = 0x40, SWP_FRAMECHANGED = 0x20, SWP_NOZORDER = 0x4;
    public static readonly nint HWND_TOPMOST = -1;
    public const uint ULW_ALPHA = 2;
    public const byte AC_SRC_ALPHA = 1;

    public const uint WM_DESTROY = 0x2, WM_HOTKEY = 0x312, WM_POWERBROADCAST = 0x218, WM_DISPLAYCHANGE = 0x7E, WM_SETTINGCHANGE = 0x1A,
        WM_LBUTTONDOWN = 0x201, WM_LBUTTONUP = 0x202, WM_RBUTTONUP = 0x205, WM_MOUSEACTIVATE = 0x21, WM_APP = 0x8000, WM_DPICHANGED = 0x2E0,
        WM_CONTEXTMENU = 0x7B, WM_NCHITTEST = 0x84, WM_USER = 0x400;
    public const int MA_NOACTIVATE = 3;
    public const nint PBT_APMRESUMEAUTOMATIC = 0x12, PBT_APMRESUMESUSPEND = 0x7;
    public const uint NIM_ADD = 0, NIM_MODIFY = 1, NIM_DELETE = 2, NIM_SETVERSION = 4;
    public const uint NIF_MESSAGE = 1, NIF_ICON = 2, NIF_TIP = 4, NIF_SHOWTIP = 0x80;
    public const uint NOTIFYICON_VERSION_4 = 4;
    public const uint NIN_SELECT = WM_USER, NIN_KEYSELECT = WM_USER + 1;
    public const uint MOD_ALT = 1, MOD_CONTROL = 2, MOD_NOREPEAT = 0x4000;
    public const uint MONITOR_DEFAULTTONEAREST = 2;
    public const uint SND_ASYNC = 1, SND_MEMORY = 4, SND_NODEFAULT = 2;
    public const int DWMWA_WINDOW_CORNER_PREFERENCE = 33, DWMWCP_ROUND = 2;

    [DllImport("user32", CharSet = CharSet.Unicode, SetLastError = true)] public static extern ushort RegisterClassEx(ref WNDCLASSEX wc);
    [DllImport("user32", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern nint CreateWindowEx(int exStyle, string cls, string name, uint style, int x, int y, int w, int h, nint parent, nint menu, nint inst, nint param);
    [DllImport("user32")] public static extern nint DefWindowProc(nint hWnd, uint msg, nint wParam, nint lParam);
    [DllImport("user32")] public static extern bool DestroyWindow(nint hWnd);
    [DllImport("user32", CharSet = CharSet.Unicode)] public static extern uint RegisterWindowMessage(string s);
    [DllImport("user32")] public static extern bool ShowWindow(nint hWnd, int cmd);
    [DllImport("user32")] public static extern bool SetWindowPos(nint hWnd, nint after, int x, int y, int w, int h, uint flags);
    [DllImport("user32", EntryPoint = "GetWindowLongPtrW")] public static extern nint GetWindowLongPtr(nint hWnd, int index);
    [DllImport("user32", EntryPoint = "SetWindowLongPtrW")] public static extern nint SetWindowLongPtr(nint hWnd, int index, nint value);
    [DllImport("user32")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32")] public static extern nint MonitorFromPoint(POINT p, uint flags);
    [DllImport("user32", CharSet = CharSet.Unicode)] public static extern bool GetMonitorInfo(nint mon, ref MONITORINFO info);
    [DllImport("shcore")] public static extern int GetDpiForMonitor(nint mon, int type, out uint dpiX, out uint dpiY);
    [DllImport("user32")] public static extern uint GetDpiForWindow(nint hWnd);
    [DllImport("user32")] public static extern bool SetForegroundWindow(nint hWnd);
    [DllImport("user32")] public static extern nint GetForegroundWindow();
    [DllImport("user32")] public static extern bool RegisterHotKey(nint hWnd, int id, uint mods, uint vk);
    [DllImport("user32")] public static extern bool UnregisterHotKey(nint hWnd, int id);
    [DllImport("user32", SetLastError = true)]
    public static extern bool UpdateLayeredWindow(nint hWnd, nint hdcDst, ref POINT pptDst, ref SIZE psize, nint hdcSrc, ref POINT pptSrc, uint crKey, ref BLENDFUNCTION pblend, uint flags);
    [DllImport("user32")] public static extern nint GetDC(nint hWnd);
    [DllImport("user32")] public static extern int ReleaseDC(nint hWnd, nint hdc);
    [DllImport("user32")] public static extern nint CreateIconIndirect(ref ICONINFO info);
    [DllImport("user32")] public static extern bool DestroyIcon(nint h);
    [DllImport("gdi32")] public static extern nint CreateCompatibleDC(nint hdc);
    [DllImport("gdi32")] public static extern bool DeleteDC(nint hdc);
    [DllImport("gdi32")] public static extern nint SelectObject(nint hdc, nint obj);
    [DllImport("gdi32")] public static extern bool DeleteObject(nint obj);
    [DllImport("gdi32")] public static extern nint CreateDIBSection(nint hdc, ref BITMAPINFOHEADER bmi, uint usage, out nint bits, nint section, uint offset);
    [DllImport("gdi32")] public static extern nint CreateBitmap(int w, int h, uint planes, uint bpp, nint bits);
    [DllImport("shell32", CharSet = CharSet.Unicode)] public static extern bool Shell_NotifyIcon(uint msg, ref NOTIFYICONDATA data);
    [DllImport("shell32")] public static extern int Shell_NotifyIconGetRect(ref NOTIFYICONIDENTIFIER id, out RECT rect);
    [DllImport("shell32")] public static extern int SHQueryUserNotificationState(out int state);
    [DllImport("winmm", EntryPoint = "PlaySoundW")] public static extern bool PlaySound(nint data, nint hmod, uint flags);
    [DllImport("dwmapi")] public static extern int DwmSetWindowAttribute(nint hWnd, int attr, ref int value, int size);
    [DllImport("kernel32", CharSet = CharSet.Unicode)] public static extern nint GetModuleHandle(string? name);

    public const uint MF_STRING = 0, MF_POPUP = 0x10, MF_GRAYED = 1, TPM_RETURNCMD = 0x100, TPM_NONOTIFY = 0x80;
    [DllImport("user32")] public static extern nint CreatePopupMenu();
    [DllImport("user32", CharSet = CharSet.Unicode)] public static extern bool AppendMenu(nint menu, uint flags, nuint id, string text);
    [DllImport("user32")] public static extern int TrackPopupMenu(nint menu, uint flags, int x, int y, int reserved, nint hWnd, nint rect);
    [DllImport("user32")] public static extern bool DestroyMenu(nint menu);

    // 방해하지 않기(N-23): 전체 화면 앱·발표 중·집중 지원이면 true
    // QUNS_BUSY=2, QUNS_RUNNING_D3D_FULL_SCREEN=3, QUNS_PRESENTATION_MODE=4, QUNS_QUIET_TIME=6
    public static bool UserBusy()
    {
        try { return SHQueryUserNotificationState(out var s) == 0 && s is 2 or 3 or 4 or 6; } catch { return false; }
    }

    public static (RECT Work, RECT Monitor, double Scale) MonitorAt(POINT p)
    {
        var mon = MonitorFromPoint(p, MONITOR_DEFAULTTONEAREST);
        var info = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
        GetMonitorInfo(mon, ref info);
        var scale = GetDpiForMonitor(mon, 0, out var dx, out _) == 0 ? dx / 96.0 : 1.0;
        return (info.rcWork, info.rcMonitor, scale);
    }

    public static nint MonitorHandleAt(POINT p) => MonitorFromPoint(p, MONITOR_DEFAULTTONEAREST);
}
