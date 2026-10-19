namespace Dropcap.Core.Tests;

// 보안 점검 낮음 — 윈도우 앱(WinUI) 쪽은 맥에서 돌릴 수 없어 원본 글로 확인한다
public class SecurityLow4Tests
{
    private static string AppSource(string name) => File.ReadAllText(Path.Combine(ExtractJs.Root(), "windows", "Dropcap.App", name));

    // 창 열기 움직임(Present) 도중 창을 닫으면 타이머가 닫힌 창의 AppWindow.MoveAndResize 를 부를 수 있었다.
    // 닫힐 때 타이머를 멈추고, 틱도 닫힌 창이면 아무것도 하지 않는다
    [Fact]
    public void PresentStopsWhenWindowCloses()
    {
        var src = AppSource("WebWindow.cs");
        var closedHandler = src[src.IndexOf("Window.Closed += ", StringComparison.Ordinal)..];
        closedHandler = closedHandler[..closedHandler.IndexOf('\n')];
        Assert.Contains("motion?.Stop()", closedHandler);
        Assert.Contains("closed = true", closedHandler);
        var present = src[src.IndexOf("public void Present()", StringComparison.Ordinal)..];
        var tick = present[present.IndexOf("timer.Tick += ", StringComparison.Ordinal)..];
        var firstLine = tick.Split('\n').Skip(2).First(); // '{' 다음 줄이 틱의 첫 줄
        Assert.Contains("if (closed)", firstLine);
        Assert.Contains("motion = ", present);
    }
}
