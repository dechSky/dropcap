using Dropcap.Core;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Dropcap.App;

public static class Program
{
    private static FileStream? instanceLock;

    [STAThread]
    public static void Main()
    {
        // 앱은 하나만(C-12): 데이터 폴더의 잠금 파일을 독점으로 연다. 이미 실행 중이면 바로 끝낸다(같은 소식을 두 번 알리지 않게).
        try
        {
            instanceLock = new FileStream(Path.Combine(Store.Dir, "native.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        }
        catch (IOException)
        {
            return;
        }
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(p =>
        {
            SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            _ = new App();
        });
        instanceLock.Dispose();
    }
}

// XAML 파일 없이 코드로만 만든 WinUI 3 앱. 창은 Shell 이 열고 닫는다.
public sealed class App : Application
{
    private Shell? shell;

    public App()
    {
        // 창이 하나도 없어도(트레이에만 있어도) 끝나지 않는다
        DispatcherShutdownMode = DispatcherShutdownMode.OnExplicitShutdown;
        UnhandledException += (_, e) => { e.Handled = true; Log(e.Exception); };
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Resources.MergedDictionaries.Add(new XamlControlsResources());
        shell = new Shell(DispatcherQueue.GetForCurrentThread());
        shell.Start();
        shell.RunTestHooks();
    }

    private static void Log(Exception e)
    {
        try { File.AppendAllText(Path.Combine(Store.Dir, "errors.log"), $"{DateTimeOffset.Now:O} {e}\n"); } catch { }
    }
}
