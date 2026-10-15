using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Dropcap.Core;
using Microsoft.Win32;

namespace Dropcap.App;

// dropcap:// 주소 연결(I-04)과 명령줄(I-02 대신): 맥 Integrations/URLRouter.swift 자리.
// - 등록: HKCU\Software\Classes\dropcap(패키지 없는 앱도 사용자 범위에 등록할 수 있다 — 자동 실행 HKCU\…\Run 과 같은 방식). 실행 파일을 옮기면 다음 실행 때 고쳐 쓴다.
// - 앱은 하나만(C-12): 이미 떠 있으면 두 번째 실행은 받은 인자를 이름 붙은 파이프(이 사용자만)로 넘기고 바로 끝난다.
// - 해석·검사는 Core UrlRouter·SaveLink(순수 함수, 시험), 여기서는 열기·확인 창·알림만.
internal static class Protocol
{
    private const string ClassesKey = @"Software\Classes\" + UrlRouter.Scheme;
    private const int MaxMessage = 32 * 1024;

    // MARK: 주소 연결 등록
    public static void Register()
    {
        try
        {
            if (Environment.ProcessPath is not { } exe) return;
            var command = $"\"{exe}\" \"%1\"";
            using var k = Registry.CurrentUser.CreateSubKey(ClassesKey);
            if (k.GetValue("") as string != "URL:Dropcap") k.SetValue("", "URL:Dropcap");
            if (k.GetValue("URL Protocol") is null) k.SetValue("URL Protocol", "");
            using (var icon = k.CreateSubKey("DefaultIcon"))
                if (icon.GetValue("") as string != $"\"{exe}\",0") icon.SetValue("", $"\"{exe}\",0");
            using var cmd = k.CreateSubKey(@"shell\open\command");
            if (cmd.GetValue("") as string != command) cmd.SetValue("", command);
        }
        catch { } // 등록하지 못해도 앱은 그대로 돈다(주소로 부르는 것만 안 됨)
    }

    // MARK: 이미 떠 있는 앱으로 넘기기(같은 사용자·같은 세션만)
    private static string PipeName
    {
        get
        {
            var user = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Environment.UserDomainName + "\\" + Environment.UserName)))[..16];
            return $"Dropcap.Native.{System.Diagnostics.Process.GetCurrentProcess().SessionId}.{user}";
        }
    }

    // 두 번째 실행: 인자를 넘긴다(먼저 뜬 앱이 아직 받을 준비 중이면 3초까지 기다림)
    public static bool Forward(string[] args)
    {
        try
        {
            var data = JsonSerializer.SerializeToUtf8Bytes(args.Take(4).ToArray());
            if (data.Length > MaxMessage) return false;
            using var c = new NamedPipeClientStream(".", PipeName, PipeDirection.Out, PipeOptions.CurrentUserOnly);
            c.Connect(3000);
            c.Write(data);
            c.Flush();
            return true;
        }
        catch { return false; }
    }

    // 먼저 뜬 앱: 넘어온 인자를 받는다(뒤 스레드에서 — received 는 화면 줄기로 넘겨서 처리할 것)
    public static void Listen(Action<string[]> received)
    {
        var name = PipeName;
        _ = Task.Run(async () =>
        {
            while (true)
            {
                try
                {
                    using var s = new NamedPipeServerStream(name, PipeDirection.In, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                    await s.WaitForConnectionAsync();
                    using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                    var buf = new MemoryStream();
                    var chunk = new byte[4096];
                    int n;
                    while ((n = await s.ReadAsync(chunk, timeout.Token)) > 0)
                    {
                        buf.Write(chunk, 0, n);
                        if (buf.Length > MaxMessage) break;
                    }
                    if (buf.Length <= MaxMessage && JsonSerializer.Deserialize<string[]>(buf.ToArray()) is { } args) received(args);
                }
                catch { await Task.Delay(500); }
            }
        });
    }

    // MARK: 처리(화면 줄기에서)
    public static void Handle(Shell shell, IReadOnlyList<string> args)
    {
        var route = UrlRouter.FromArgs(args);
        switch (route)
        {
            case Route.Open o:
                if (Find(shell, o.Key) is { } it) shell.Model.Open(it);
                break;
            case Route.Magazine:
                shell.OpenMagazine(null);
                break;
            case Route.Save s:
                _ = SaveAsync(shell, s);
                break;
        }
    }

    // 기사 key → 기사(최근 목록 · 나중에 읽기 · 스크랩 · 매거진 DB 순서로 찾는다 — 맥과 같음)
    private static NewsItem? Find(Shell shell, string key)
    {
        var st = shell.Model.State;
        return st.Recent.FirstOrDefault(i => i.Key == key)
            ?? st.Saved.FirstOrDefault(i => i.Key == key)
            ?? shell.Scrapbook.Scraps.FirstOrDefault(s => s.Item.Key == key)?.Item
            ?? shell.Magazine.Stored(key)?.Item;
    }

    private static int asking;   // 떠 있는 확인 창 수(웹 페이지가 마구 불러도 창이 쌓이지 않게)

    // 아무 웹 페이지나 dropcap:// 를 부를 수 있으므로(브라우저의 '항상 허용' 뒤에는 묻지 않음) 저장 전에 한 번 묻는다.
    // 명령줄 --save 는 사용자가 직접 부른 것이라 묻지 않는다(맥 단축어와 같음). 시험(DROPCAP_TEST_SCHEME)에서는 묻지 않음.
    private static async Task SaveAsync(Shell shell, Route.Save s)
    {
        if (s.Confirm && Environment.GetEnvironmentVariable("DROPCAP_TEST_SCHEME") is null)
        {
            if (Interlocked.Increment(ref asking) > 2) { Interlocked.Decrement(ref asking); return; }
            try
            {
                var body = SaveLink.ConfirmTitle + "\n\n" + SaveLink.ConfirmBody(s.Url, s.Title);
                // 화면 줄기를 막지 않게 뒤 스레드에서 띄운다(맨 앞에, 다른 창 위에)
                var answer = await Task.Run(() => MessageBoxW(0, body, "Dropcap", MB_OKCANCEL | MB_ICONQUESTION | MB_SETFOREGROUND | MB_TOPMOST));
                if (answer != IDOK) return;
            }
            finally { Interlocked.Decrement(ref asking); }
        }
        var r = await SaveLink.SaveAsync(shell.Model, s.Url, s.Title, fromOutside: true);
        var (title, sub) = SaveLink.Announcement(r);
        shell.ShowInfo(title, sub);
    }

    private const uint MB_OKCANCEL = 0x1, MB_ICONQUESTION = 0x20, MB_SETFOREGROUND = 0x10000, MB_TOPMOST = 0x40000;
    private const int IDOK = 1;
    [DllImport("user32", CharSet = CharSet.Unicode)] private static extern int MessageBoxW(nint hWnd, string text, string caption, uint type);
}
