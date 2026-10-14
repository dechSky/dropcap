namespace Dropcap.Core;

// 회의·발표 중 자동 조용히(N-25 · D-8): 전체 화면 앱을 쓰는 중, 화면을 공유·기록하는 중이면
// 물방울 대신 고이게 한다(방해 금지와 같은 길 — 안 읽은 소식으로 쌓이고, 떨어질 소식은 묶음으로). 맥 Core/FocusGuard.swift 와 같은 판단.
// 윈도우에서 실제로 읽는 일(앞 창·모니터·프로세스 이름)은 앱(Dropcap.App)의 IFocusProbe 가 한다.
public enum FocusReason { Fullscreen, Sharing, Calendar }

public static class FocusReasons
{
    public static string Label(this FocusReason r) => r switch
    {
        FocusReason.Fullscreen => "전체 화면 사용 중",
        FocusReason.Sharing => "화면 공유·기록 중",
        _ => "캘린더 일정 중",
    };
}

public static class FocusGuard
{
    // 화면을 공유·기록하는 동안에만 떠 있는 도우미 프로세스(이름, .exe 없이)
    // CptHost: Zoom 화면 공유(윈도우·맥 같은 이름). Teams·Meet 브라우저 공유는 공개 API 로 알 수 없어 '전체 화면'으로만 잡힌다.
    public static readonly IReadOnlySet<string> SharingProcesses = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "CptHost" };

    public readonly record struct Rect(double X, double Y, double Width, double Height);
    public sealed record WindowInfo(int Pid, int Layer, Rect Bounds);

    // 앞에 있는 다른 앱의 보통 창이 어느 화면을 통째로 덮는가(작업 표시줄까지 가린 전체 화면 · 발표 모드)
    public static bool CoversScreen(IEnumerable<WindowInfo> windows, int? frontPid, IEnumerable<Rect> screens, int ownPid)
    {
        if (frontPid is not { } front || front == ownPid) return false;
        var s = screens.ToList();
        return windows.Any(w => w.Pid == front && w.Layer == 0 && s.Any(m =>
            Math.Abs(w.Bounds.Width - m.Width) < 1 && Math.Abs(w.Bounds.Height - m.Height) < 1));
    }

    public static bool Sharing(IEnumerable<string> processNames) =>
        processNames.Any(n => SharingProcesses.Contains(n.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? n[..^4] : n));

    // 일정 중인가: 하루 종일 일정·'한가함'으로 둔 일정·거절한 일정은 빼고, 지금이 시작~끝 사이
    public sealed record EventInfo(DateTimeOffset Start, DateTimeOffset End, bool AllDay, bool Free, bool Declined);
    public static bool InEvent(IEnumerable<EventInfo> events, DateTimeOffset now) =>
        events.Any(e => !e.AllDay && !e.Free && !e.Declined && e.Start <= now && now < e.End);
}

// 지금 이 PC 에서 읽기(앱이 구현). 캘린더는 패키지 없는 배포라 윈도우 일정 API(AppointmentStore)를 쓸 수 없어 null.
public interface IFocusProbe
{
    bool FullScreen();
    IReadOnlyList<string> ProcessNames();
    bool? InCalendarEvent(DateTimeOffset now) => null;
    bool CalendarSupported => false;
}

// 설정을 따라 지금 조용히 할 이유를 알려 준다(15초 동안 기억 — 확인·1분 타이머가 자주 묻지 않게)
public sealed class FocusMonitor
{
    public IFocusProbe? Probe { get; set; }
    public sealed record Fixed(FocusReason? Reason);
    public Fixed? Override { get; set; } // 시험용: 감지 결과를 정해 둔다(DROPCAP_TEST_FOCUS)
    private (DateTimeOffset At, FocusReason? Reason)? cached;
    private readonly object gate = new();

    public bool CalendarSupported => Probe?.CalendarSupported ?? false;

    public FocusReason? Reason(StateSettings s, DateTimeOffset now)
    {
        if (Override is { } o) return o.Reason;
        lock (gate) if (cached is { } c && now - c.At < TimeSpan.FromSeconds(15) && now >= c.At) return c.Reason;
        var r = Detect(s, now);
        lock (gate) cached = (now, r);
        return r;
    }

    public void Invalidate() { lock (gate) cached = null; }

    private FocusReason? Detect(StateSettings s, DateTimeOffset now)
    {
        if (Probe is not { } p) return null;
        try
        {
            if (s.AutoQuietFullscreen && p.FullScreen()) return FocusReason.Fullscreen;
            if (s.AutoQuietSharing && FocusGuard.Sharing(p.ProcessNames())) return FocusReason.Sharing;
            if (s.AutoQuietCalendar && p.CalendarSupported && p.InCalendarEvent(now) == true) return FocusReason.Calendar;
        }
        catch { }
        return null;
    }

    // 시험용 값: fullscreen · sharing · calendar · none
    public static Fixed? ParseOverride(string? v) => v switch
    {
        "fullscreen" => new(FocusReason.Fullscreen),
        "sharing" => new(FocusReason.Sharing),
        "calendar" => new(FocusReason.Calendar),
        "none" => new(null),
        _ => null,
    };
}
