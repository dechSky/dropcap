using Dropcap.Core;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Dropcap.App;

public static class Program
{
    private static FileStream? instanceLock;
    internal static string[] StartArgs { get; private set; } = [];   // dropcap:// 주소·--magazine·--save 로 켜졌을 때(I-02·I-04)

    [STAThread]
    public static void Main(string[] args)
    {
        // 앱은 하나만(C-12): 데이터 폴더의 잠금 파일을 독점으로 연다. 이미 실행 중이면 바로 끝낸다(같은 소식을 두 번 알리지 않게).
        // 받은 인자(dropcap:// 주소 등)가 있으면 떠 있는 앱으로 넘기고 끝낸다.
        try
        {
            instanceLock = new FileStream(Path.Combine(Store.Dir, "native.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        }
        catch (IOException)
        {
            if (args.Length > 0) Protocol.Forward(args);
            return;
        }
        StartArgs = args;
        Protocol.Register();   // dropcap:// 주소 연결(HKCU, 실행 파일을 옮겼으면 고쳐 씀)
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
        var queue = DispatcherQueue.GetForCurrentThread();
        shell = new Shell(queue);
        shell.Start();
        shell.RunTestHooks();
        var s = shell;
        // 스크랩 노트 폴더 내보내기(I-06): 폴더 고르는 창·휴지통은 운영체제에, 설정 창은 바뀌면 다시 그림
        ScrapExport.PickFolder = () => new Platform(s).PickFolder();
        ScrapExport.Trash = Platform.MoveToRecycleBin;
        ScrapExport.Shared.Changed += () => queue.TryEnqueue(() => s.Bridge.Emit("settings", "changed"));
        ScrapExport.Shared.Attach();
        // dropcap:// 주소·명령줄(I-02·I-04): 켤 때 받은 것, 그 뒤 두 번째 실행이 넘긴 것
        Protocol.Handle(s, Program.StartArgs);
        Protocol.Listen(a => queue.TryEnqueue(() => Protocol.Handle(s, a)));
    }

    private static void Log(Exception e)
    {
        try { File.AppendAllText(Path.Combine(Store.Dir, "errors.log"), $"{DateTimeOffset.Now:O} {e}\n"); } catch { }
    }
}
