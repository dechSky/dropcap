using System.Runtime.InteropServices;
using static Dropcap.App.Win32;

namespace Dropcap.App;

// 보이지 않는 창 하나: 트레이 아이콘 누름, 전역 단축키, 잠자기에서 깸, 화면 구성 바뀜, 탐색기 다시 시작을 받는다.
// (메시지 전용 창은 방송 메시지를 못 받으므로 보이지 않는 보통 창으로 만든다)
internal sealed class MessageWindow : IDisposable
{
    public const uint TrayMessage = WM_APP + 1;
    public nint Handle { get; }
    private readonly WndProc proc;   // 가비지 수집되지 않게 붙들어 둔다
    private readonly uint taskbarCreated;

    public event Action<uint, int, int>? Tray;       // (이벤트, 화면 x, 화면 y)
    public event Action<int>? HotKey;
    public event Action? Resumed;
    public event Action? DisplayChanged;
    public event Action? TaskbarCreated;
    public event Action? SettingChanged;

    public MessageWindow()
    {
        proc = Proc;
        var cls = new WNDCLASSEX
        {
            cbSize = Marshal.SizeOf<WNDCLASSEX>(),
            lpfnWndProc = proc,
            hInstance = GetModuleHandle(null),
            lpszClassName = "DropcapMessageWindow",
        };
        RegisterClassEx(ref cls);
        Handle = CreateWindowEx(WS_EX_TOOLWINDOW, cls.lpszClassName, "Dropcap", WS_POPUP, 0, 0, 0, 0, 0, 0, cls.hInstance, 0);
        taskbarCreated = RegisterWindowMessage("TaskbarCreated");
    }

    private nint Proc(nint hWnd, uint msg, nint wParam, nint lParam)
    {
        switch (msg)
        {
            case TrayMessage:
                // NOTIFYICON_VERSION_4: lParam 아래 16비트 = 이벤트, wParam = 누른 자리(x, y)
                Tray?.Invoke((uint)(lParam & 0xFFFF), (short)(wParam & 0xFFFF), (short)((wParam >> 16) & 0xFFFF));
                return 0;
            case WM_HOTKEY:
                HotKey?.Invoke((int)wParam);
                return 0;
            case WM_POWERBROADCAST:
                if (wParam == PBT_APMRESUMEAUTOMATIC) Resumed?.Invoke();
                return 1;
            case WM_DISPLAYCHANGE:
                DisplayChanged?.Invoke();
                break;
            case WM_SETTINGCHANGE:
                SettingChanged?.Invoke();
                break;
        }
        if (msg == taskbarCreated && taskbarCreated != 0) TaskbarCreated?.Invoke();
        return DefWindowProc(hWnd, msg, wParam, lParam);
    }

    public void Dispose() => DestroyWindow(Handle);
}
