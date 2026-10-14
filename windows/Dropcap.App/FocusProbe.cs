using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using Dropcap.Core;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Storage.Streams;
using static Dropcap.App.Win32;

namespace Dropcap.App;

// 회의·발표 중 자동 조용히(N-25)의 윈도우 감지. 판단은 Core 의 FocusGuard(맥과 같음), 여기서는 읽기만 한다.
//  - 전체 화면: 운영체제가 알려 주는 상태(전체 화면 앱·D3D 전체 화면·발표 모드) 또는 앞에 있는 다른 앱의 창이 모니터 하나를 통째로 덮음
//    (작업 표시줄 위까지만 키운 창은 아님 · 바탕 화면·우리 창은 뺌 · 창 제목은 읽지 않음)
//  - 화면 공유: 그때만 떠 있는 도우미 프로세스 이름(Zoom 공유 CptHost)
//  - 캘린더: 패키지 없는 배포라 윈도우 일정 API 를 쓸 수 없음(설정에서 끔 · FEATURES N-25 에 사유)
internal sealed class FocusProbe : IFocusProbe
{
    public bool FullScreen()
    {
        try
        {
            if (SHQueryUserNotificationState(out var s) == 0 && s is 2 or 3 or 4) return true;
            var fg = GetForegroundWindow();
            if (fg == 0 || fg == GetShellWindow() || fg == GetDesktopWindow() || IsDesktop(fg) || !IsWindowVisible(fg)) return false;
            GetWindowThreadProcessId(fg, out var pid);
            if (!GetWindowRect(fg, out var r)) return false;
            var mi = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
            if (!GetMonitorInfo(MonitorFromWindow(fg, 2), ref mi)) return false;   // MONITOR_DEFAULTTONEAREST
            var m = mi.rcMonitor;
            return FocusGuard.CoversScreen(
                [new FocusGuard.WindowInfo((int)pid, 0, new FocusGuard.Rect(r.Left, r.Top, r.Width, r.Height))], (int)pid,
                [new FocusGuard.Rect(m.Left, m.Top, m.Width, m.Height)], Environment.ProcessId);
        }
        catch { return false; }
    }

    public IReadOnlyList<string> ProcessNames()
    {
        var o = new List<string>();
        foreach (var p in Process.GetProcesses())
        {
            try { o.Add(p.ProcessName); } catch { }
            finally { p.Dispose(); }
        }
        return o;
    }

    // 바탕 화면(아이콘 층)은 화면을 덮지만 '쓰는 중'이 아니다
    private static bool IsDesktop(nint hwnd)
    {
        var sb = new System.Text.StringBuilder(64);
        GetClassName(hwnd, sb, sb.Capacity);
        return sb.ToString() is "Progman" or "WorkerW";
    }

    [DllImport("user32", CharSet = CharSet.Unicode)] private static extern int GetClassName(nint hWnd, System.Text.StringBuilder name, int max);
}

// 사진 속 글자 면적(M-24 사진 점수): 윈도우 글자 인식(Windows.Media.Ocr, 사용자 언어 — 한국어·영어 등 설치된 것)
// 줄마다 낱말 상자를 합친 사각형의 넓이를 더한다(맥 Vision 글자 인식 결과의 줄 상자와 같은 셈).
internal static class PhotoOcr
{
    private static OcrEngine? engine;
    private static bool tried;
    private static readonly SemaphoreSlim gate = new(1, 1);

    public static async Task<double> TextRatioAsync(byte[] jpeg)
    {
        await gate.WaitAsync();   // 엔진 하나를 차례로
        try
        {
            if (!tried) { tried = true; engine = OcrEngine.TryCreateFromUserProfileLanguages(); }
            if (engine is null) return 0;
            using var ms = new InMemoryRandomAccessStream();
            await ms.WriteAsync(jpeg.AsBuffer());
            ms.Seek(0);
            var dec = await BitmapDecoder.CreateAsync(ms);
            using var bmp = await dec.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
            if (bmp.PixelWidth > OcrEngine.MaxImageDimension || bmp.PixelHeight > OcrEngine.MaxImageDimension) return 0;
            var res = await engine.RecognizeAsync(bmp);
            double area = 0;
            foreach (var line in res.Lines)
            {
                if (line.Words.Count == 0) continue;
                var l = line.Words.Min(w => w.BoundingRect.X);
                var t = line.Words.Min(w => w.BoundingRect.Y);
                var rr = line.Words.Max(w => w.BoundingRect.X + w.BoundingRect.Width);
                var b = line.Words.Max(w => w.BoundingRect.Y + w.BoundingRect.Height);
                area += Math.Max(0, rr - l) * Math.Max(0, b - t);
            }
            return Math.Min(1, area / ((double)bmp.PixelWidth * bmp.PixelHeight));
        }
        catch { return 0; }
        finally { gate.Release(); }
    }
}
