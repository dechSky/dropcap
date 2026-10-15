using System.Globalization;
using System.Text.RegularExpressions;

namespace Dropcap.Core;

// 스크랩 → 노트 폴더(Obsidian 보관소 등) 자동 저장(I-06). 맥 Core/ScrapExport.swift 와 같은 동작.
// 켜 두면 스크랩이 바뀔 때마다 폴더별 `<고른 폴더>/<스크랩 폴더 이름>.md` 를 지금의 Markdown 내보내기 형식(Scrapbook.Render)으로 덮어쓴다(원자적 쓰기).
// 고른 폴더는 경로로 기억한다(prefs.json — 맥 UserDefaults 와 같은 이름 scrapExportEnabled·scrapExportPath, 맥의 보안 범위 북마크는 윈도우에 없음).
// 다른 PC 로 옮겨 그 폴더가 없으면 쓰지 않고 '다시 골라 주세요'를 보인다. 끄면 아무 파일도 건드리지 않는다.
public sealed class ScrapExport
{
    public const string EnabledKey = "scrapExportEnabled";
    public const string PathKey = "scrapExportPath";

    private static ScrapExport? shared;
    public static ScrapExport Shared => shared ??= new ScrapExport(() => Scrapbook.Shared);

    // 앱이 넣어 준다: 폴더 고르는 창(취소면 null) · 휴지통으로 옮기기(없으면 예전 파일을 그대로 둔다)
    public static Func<Task<string?>>? PickFolder { get; set; }
    public static Action<string>? Trash { get; set; }

    private readonly Func<Scrapbook> bookOf;           // 쓸 때 처음 연다(설정 화면만 그릴 때는 DB 를 열지 않게)
    private Scrapbook Book => bookOf();
    private readonly object gate = new();
    private CancellationTokenSource? pending;
    private HashSet<string> known = new();            // 지난번에 본 스크랩 폴더 이름(이름 바꾸기를 알아보려고)
    private bool attached;
    private string? missing;                          // 찾지 못한 폴더(다시 고르라고 알림)

    public string? LastError { get; private set; }
    public DateTimeOffset? LastWrite { get; private set; }
    public int DelayMs { get; set; } = 400;            // 잇따른 변경은 잠깐 모아서 한 번에
    public event Action? Changed;                      // 설정 화면을 다시 그리게

    public ScrapExport(Func<Scrapbook> book) => bookOf = book;
    public ScrapExport(Scrapbook book) : this(() => book) { }

    public bool Enabled => Prefs.Get(EnabledKey, false);
    public string? SavedPath => Prefs.Get<string?>(PathKey, null);

    // 고른 폴더(없거나 찾지 못하면 null — 다른 PC 로 옮겼거나 지워졌을 때)
    public string? Folder
    {
        get
        {
            if (SavedPath is not { Length: > 0 } p) return null;
            if (Directory.Exists(p)) { if (missing == p) { missing = null; LastError = null; } return p; }
            if (missing != p) { missing = p; LastError = "폴더를 찾지 못했습니다 — 다시 골라 주세요"; }
            return null;
        }
    }

    public bool HasScraps => Book.Scraps.Count > 0;

    // 한 번만: 스크랩북이 바뀌면 다시 쓴다(Scrapbook.Changed 만 구독)
    public void Attach()
    {
        if (attached) return;
        attached = true;
        var b = Book;
        lock (gate) known = b.Collections.ToHashSet();
        b.Changed += OnBookChanged;
        if (Enabled && Folder is not null) SyncSoon();
    }

    private void OnBookChanged()
    {
        var now = Book.Collections.ToHashSet();
        HashSet<string> before;
        lock (gate) { before = known; known = now; }
        // 폴더 하나가 없어지고 하나가 생기면 이름 바꾸기: 예전 이름의 파일은 휴지통으로(지우지 않고 되살릴 수 있게)
        var gone = before.Except(now).ToList();
        var added = now.Except(before).ToList();
        SyncSoon(gone.Count == 1 && added.Count == 1 ? gone[0] : null);
    }

    // MARK: 켜고 끄기·폴더 고르기

    public void SetEnabled(bool on)
    {
        Prefs.Set(EnabledKey, on);
        if (on) SyncSoon();
        Changed?.Invoke();
    }

    // 켜려는데 폴더가 없으면 먼저 고른다(맥 토글과 같음)
    public async Task Toggle(bool on)
    {
        if (on && Folder is null) await ChooseFolder();
        else SetEnabled(on);
    }

    public async Task ChooseFolder()
    {
        if (PickFolder is not { } pick) return;
        if (await pick() is { Length: > 0 } dir) SetFolder(dir);
    }

    public void SetFolder(string dir)
    {
        if (!Directory.Exists(dir)) { LastError = "폴더를 찾지 못했습니다 — 다시 골라 주세요"; Changed?.Invoke(); return; }
        Prefs.Set(PathKey, Path.GetFullPath(dir));
        missing = null;
        LastError = null;
        if (!Enabled) SetEnabled(true);
        else { SyncSoon(); Changed?.Invoke(); }
    }

    public void ForgetFolder()
    {
        Prefs.Set<string?>(PathKey, null);
        missing = null;
        LastError = null;
        SetEnabled(false);
    }

    // MARK: 쓰기

    // 스크랩이 바뀌면 부른다. 잇따른 변경은 잠깐 모아서 한 번에 쓴다(뒤 스레드에서)
    public void SyncSoon(string? renamedFrom = null)
    {
        if (!Enabled || Folder is null) return;
        if (renamedFrom is not null) TrashOld(renamedFrom);
        CancellationTokenSource cts;
        lock (gate)
        {
            pending?.Cancel();
            pending = cts = new CancellationTokenSource();
        }
        _ = Task.Run(async () =>
        {
            try { await Task.Delay(DelayMs, cts.Token); } catch (OperationCanceledException) { return; }
            SyncNow();
        });
    }

    public void SyncNow()
    {
        if (!Enabled) return;
        if (Folder is not { } dir) { Changed?.Invoke(); return; }
        string? failed = null;
        var book = Book;
        var scraps = book.Scraps;
        lock (gate)
            foreach (var c in book.Collections)
            {
                var list = scraps.Where(s => s.Collection == c).ToList();
                var file = Path.Combine(dir, FileName(c));
                // 비어 있는 폴더는, 전에 써 둔 파일이 있을 때만 비운 내용으로 덮는다(새 빈 파일을 만들지 않음)
                if (list.Count == 0 && !File.Exists(file)) continue;
                var text = Scrapbook.Render(list, c);
                try
                {
                    if (File.Exists(file) && SameIgnoringDate(File.ReadAllText(file), text)) continue; // 바뀐 게 없으면 손대지 않음(동기화 앱이 덜 바쁘게)
                    WriteAtomic(dir, file, text);
                }
                catch (Exception e) { failed = e.Message; }
            }
        LastError = failed is null ? null : "쓰지 못했습니다: " + failed;
        if (failed is null) LastWrite = DateTimeOffset.Now;
        Changed?.Invoke();
    }

    // 같은 폴더의 숨은 임시 파일에 쓴 뒤 바꿔 끼운다(쓰다 꺼져도 예전 파일이 남고, 노트 앱이 반쯤 쓴 파일을 읽지 않게)
    public static void WriteAtomic(string dir, string file, string text)
    {
        var tmp = Path.Combine(dir, "." + Path.GetFileName(file) + "." + Guid.NewGuid().ToString("N")[..8] + ".tmp");
        try
        {
            File.WriteAllText(tmp, text);
            File.Move(tmp, file, overwrite: true);
        }
        finally { try { if (File.Exists(tmp)) File.Delete(tmp); } catch { } }
    }

    private void TrashOld(string name)
    {
        if (Folder is not { } dir || Trash is not { } trash) return;
        var f = Path.Combine(dir, FileName(name));
        try { if (File.Exists(f)) trash(f); } catch { }
    }

    // MARK: 이름(순수 함수 — 시험 대상)

    private const int MaxNameLength = 60;   // 스크랩 폴더 이름과 같은 60자(가져오기의 폴더 이름 규칙)
    private static readonly HashSet<string> Reserved = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    };

    // 파일 이름으로 쓸 수 없는 글자(윈도우: \ / : * ? " < > |, 제어 문자, 맨 앞 . · 맨 끝 . 과 빈칸, 예약 이름)를 바꾸고 너무 길면 자른다.
    // 금지 글자는 맥처럼 전각 글자로 바꿔 보기에는 같게 둔다.
    public static string FileName(string collection)
    {
        var n = new string(collection.Where(ch => !char.IsControl(ch)).Select(ch => ch switch
        {
            '/' => '／', ':' => '：', '\\' => '＼', '*' => '＊', '?' => '？', '"' => '＂', '<' => '＜', '>' => '＞', '|' => '｜',
            _ => ch,
        }).ToArray());
        n = Tidy(n);
        var info = new StringInfo(n);
        if (info.LengthInTextElements > MaxNameLength) n = Tidy(info.SubstringByTextElements(0, MaxNameLength));
        if (n.Length == 0) n = Scrapbook.DefaultCollection;
        var stem = n.Split('.')[0].TrimEnd();
        if (Reserved.Contains(stem)) n = "_" + n;
        return n + ".md";
    }

    private static string Tidy(string n)
    {
        n = n.Trim();
        while (n.StartsWith('.')) n = n[1..].TrimStart();
        return n.TrimEnd('.', ' ', '\t').Trim();
    }

    private static readonly Regex DateLine = new(@"(?m)^_Dropcap 스크랩 · \d{4}-\d{2}-\d{2} · ");

    // 머리의 날짜 줄만 다르면 같은 내용으로 본다
    public static bool SameIgnoringDate(string a, string b)
    {
        static string Strip(string s) => DateLine.Replace(s.Replace("\r\n", "\n"), "_Dropcap 스크랩 · ");
        return Strip(a) == Strip(b);
    }
}
