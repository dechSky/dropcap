using System.Runtime.InteropServices;
using Dropcap.Core;
using Dropcap.Ui;
using Dropcap.Ui.Toast;
using Microsoft.Win32;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage.Pickers;

namespace Dropcap.App;

// 운영체제에 맡기는 일(IPlatform): 창 열기·클립보드·저장 대화상자·공유·소리 내어 읽기·로그인 시 실행
internal sealed class Platform(Shell shell) : IPlatform
{
    // MARK: 정적 도우미
    // 다크 모드(앱 테마): AppsUseLightTheme = 0
    public static bool DarkMode()
    {
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return k?.GetValue("AppsUseLightTheme") is int v && v == 0;
        }
        catch { return false; }
    }

    // 움직임 줄이기(N-24): 설정 › 접근성 › 시각 효과 › 애니메이션 효과 끔
    public static bool AnimationsOff()
    {
        if (Environment.GetEnvironmentVariable("DROPCAP_REDUCE_MOTION") == "1") return true;
        try { return !new Windows.UI.ViewManagement.UISettings().AnimationsEnabled; } catch { return false; }
    }

    public static string IconPath => Path.Combine(Store.Dir, "dropcap.ico");

    // 창 아이콘(D-03): 처음 한 번 코드로 그려 둔다
    public static void EnsureIcon()
    {
        try { if (!File.Exists(IconPath)) File.WriteAllBytes(IconPath, AppIcon.Ico(16, 24, 32, 48, 64, 256)); } catch { }
    }

    // MARK: IPlatform
    public void OpenMagazine(string? page = null) => shell.OpenMagazine(page);
    public void OpenSettings(string? tab = null) => shell.OpenSettings(tab);
    public void OpenOnboarding() => shell.OpenOnboarding();
    public void OpenReader(NewsItem item) => shell.OpenReader(item, null);
    public void ReplaceReader(string fromKey, NewsItem next) => shell.ReplaceReader(fromKey, next);
    public void Beep() => Win32.MessageBeep(0);   // 끝이면 경고음(H-04·H-05) — 시스템 기본 소리
    public void CloseWindow(string page) => shell.Close(page);
    public void Quit() => shell.Quit();

    public void CopyText(string text)
    {
        var p = new DataPackage();
        p.SetText(text);
        Clipboard.SetContent(p);
        Clipboard.Flush();
    }

    public async Task<bool> SaveTextFile(string suggestedName, string text)
    {
        var picker = new FileSavePicker { SuggestedFileName = Path.GetFileNameWithoutExtension(suggestedName) };
        picker.FileTypeChoices.Add("Markdown", [".md"]);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, shell.OwnerHwnd());
        var file = await picker.PickSaveFileAsync();
        if (file is null) return false;
        await Windows.Storage.FileIO.WriteTextAsync(file, text);
        return true;
    }

    // 내 기록 내보내기(P-08): JSON 저장 대화상자
    public async Task<bool> SaveJsonFile(string suggestedName, string text)
    {
        var picker = new FileSavePicker { SuggestedFileName = Path.GetFileNameWithoutExtension(suggestedName) };
        picker.FileTypeChoices.Add("Dropcap 기록(JSON)", [".json"]);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, shell.OwnerHwnd());
        var file = await picker.PickSaveFileAsync();
        if (file is null) return false;
        await Windows.Storage.FileIO.WriteTextAsync(file, text);
        return true;
    }

    // 내 기록 가져오기(P-08): 여는 대화상자. 너무 큰 파일(Backup.MaxFileSize, 50MB 넘음)은 읽지 않는다
    public async Task<string?> OpenJsonFile()
    {
        var picker = new FileOpenPicker();
        picker.FileTypeFilter.Add(".json");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, shell.OwnerHwnd());
        var file = await picker.PickSingleFileAsync();
        if (file is null) return null;
        var props = await file.GetBasicPropertiesAsync();
        if (props.Size > (ulong)Backup.MaxFileSize) throw new InvalidOperationException("기록 파일이 너무 큽니다(50MB 까지)");
        return await Windows.Storage.FileIO.ReadTextAsync(file);
    }

    // 공유(R-10): 윈도우 공유 창. 기사 제목과 주소(공개 http(s) 만).
    public void Share(NewsItem item)
    {
        if (!UrlSafety.IsPublicHttp(item.Link)) return;
        var hwnd = shell.OwnerHwnd();
        try
        {
            var interop = DataTransferManager.As<IDataTransferManagerInterop>();
            var ptr = interop.GetForWindow(hwnd, DtmIid);
            var dtm = WinRT.MarshalInterface<DataTransferManager>.FromAbi(ptr);
            dtm.DataRequested += (_, e) =>
            {
                e.Request.Data.Properties.Title = item.DisplayTitle;
                e.Request.Data.SetWebLink(new Uri(item.Link));
                e.Request.Data.SetText($"{item.DisplayTitle}\n{item.Link}");
            };
            interop.ShowShareUIForWindow(hwnd);
        }
        catch { CopyText(item.Link); }
    }

    [ComImport, Guid("3A3DCD6C-3EAB-43DC-BCDE-45671CE800C8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IDataTransferManagerInterop
    {
        nint GetForWindow([In] nint appWindow, [In] ref Guid riid);
        void ShowShareUIForWindow(nint appWindow);
    }
    private static Guid DtmIid = new(0xa5caee9b, 0x8708, 0x49d1, 0x8d, 0x36, 0x67, 0xd2, 0x5a, 0x8d, 0xa0, 0x0c);

    public void Speak(string text, string language) => Speaker.Shared.Speak(text, language);
    public void StopSpeaking() => Speaker.Shared.Stop();
    public bool Speaking => Speaker.Shared.Speaking;

    // 로그인할 때 자동 실행(P-05): HKCU\…\Run
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    public bool LaunchAtLogin
    {
        get
        {
            using var k = Registry.CurrentUser.OpenSubKey(RunKey);
            return k?.GetValue("Dropcap") is string s && s.Contains(Environment.ProcessPath ?? "\0", StringComparison.OrdinalIgnoreCase);
        }
        set
        {
            using var k = Registry.CurrentUser.CreateSubKey(RunKey);
            if (value) k.SetValue("Dropcap", $"\"{Environment.ProcessPath}\""); else k.DeleteValue("Dropcap", throwOnMissingValue: false);
        }
    }

    public bool ReduceMotion => AnimationsOff();

    public void ApplyFont()
    {
        Fonts.UsePretendard = Prefs.Get("usePretendard", true);
        Fonts.Reset();
        shell.SendAppearance();
    }
}
