using System.Text.Json;
using System.Text.Json.Nodes;
using Dropcap.Core;

namespace Dropcap.Ui;

// 운영체제에 맡길 일(윈도우 앱이 구현). 화면 명령 처리기는 이것만 부른다.
public interface IPlatform
{
    void OpenMagazine(string? page = null);
    void OpenSettings(string? tab = null);
    void OpenOnboarding();                                         // 관심 분야 고르기(G-03, 첫 실행·설정에서 다시)
    void OpenReader(NewsItem item);
    // 읽기 창 J·K(H-05): 열린 창(fromKey)에서 같은 목록의 다음·이전 기사로 바꾼다. 기본은 새 창으로 열기
    void ReplaceReader(string fromKey, NewsItem next) => OpenReader(next);
    void Beep() { }                                                // 끝이면 경고음(H-04·H-05)
    void CloseWindow(string page);
    void Quit();
    void CopyText(string text);
    Task<bool> SaveTextFile(string suggestedName, string text);   // 저장 대화상자
    void Share(NewsItem item);                                     // 공유(윈도우 공유 창)
    void Speak(string text, string language);                     // 소리 내어 읽기(R-09)
    void StopSpeaking();
    bool Speaking { get; }
    bool LaunchAtLogin { get; set; }                               // P-05
    bool ReduceMotion { get; }                                     // N-24
    void ApplyFont();                                              // P-03 바뀌면 열린 화면에 알림
}

// 화면(웹 페이지) 하나의 명령 처리기
public interface IPage
{
    string Name { get; }
    Task<object?> Handle(string cmd, JsonObject args);
}

// 화면 → 앱 명령을 받아 처리하고, 앱 → 화면 알림을 보낸다.
// 메시지: 화면 → {id, page, cmd, args} / 앱 → {id, ok, data|error} · {event, data}
public sealed class Bridge
{
    private readonly Dictionary<string, IPage> pages = new();
    private readonly Dictionary<string, List<Action<string>>> sinks = new(); // 페이지 이름 → 열린 창들의 보내기

    public void Register(IPage p) => pages[p.Name] = p;
    public IPage? Page(string name) => pages.GetValueOrDefault(name);

    // 창이 열릴 때 보내기 함수를 등록(닫힐 때 해제)
    public IDisposable Attach(string page, Action<string> post)
    {
        lock (sinks)
        {
            if (!sinks.TryGetValue(page, out var l)) sinks[page] = l = new();
            l.Add(post);
        }
        return new Detach(() => { lock (sinks) sinks[page].Remove(post); });
    }

    private sealed class Detach(Action a) : IDisposable { public void Dispose() => a(); }

    // 앱 → 화면 알림(열린 창 모두)
    public void Emit(string page, string ev, object? data = null)
    {
        var json = JsonSerializer.Serialize(new { @event = ev, data }, Json.Options);
        List<Action<string>> l;
        lock (sinks) l = sinks.TryGetValue(page, out var s) ? s.ToList() : new();
        foreach (var post in l) post(json);
    }

    public void EmitAll(string ev, object? data = null)
    {
        List<string> names;
        lock (sinks) names = sinks.Keys.ToList();
        foreach (var n in names) Emit(n, ev, data);
    }

    // 화면에서 온 메시지 하나 → 답(JSON). 처리 중 예외는 오류로 돌려준다.
    public async Task<string> Receive(string page, string message)
    {
        int? id = null;
        try
        {
            var m = JsonNode.Parse(message) as JsonObject ?? throw new InvalidDataException("메시지 형식");
            id = m["id"]?.GetValue<int>();
            var name = m["page"]?.GetValue<string>() is { Length: > 0 } pn ? pn : page;
            // 창이 자기 페이지가 아닌 다른 페이지 명령을 보내지 못하게
            if (name != page) throw new UnauthorizedAccessException("다른 화면의 명령");
            var cmd = m["cmd"]?.GetValue<string>() ?? throw new InvalidDataException("명령 없음");
            var args = m["args"] as JsonObject ?? new JsonObject();
            var p = pages.GetValueOrDefault(page) ?? throw new InvalidOperationException("모르는 화면 " + page);
            var data = await p.Handle(cmd, args);
            return JsonSerializer.Serialize(new { id, ok = true, data }, Json.Options);
        }
        catch (Exception e)
        {
            return JsonSerializer.Serialize(new { id, ok = false, error = e.Message }, Json.Options);
        }
    }
}

public static class Args
{
    public static string Str(this JsonObject a, string k, string fallback = "") =>
        a[k] is JsonValue v && v.TryGetValue<string>(out var s) ? s : fallback;
    public static string? StrOrNull(this JsonObject a, string k) =>
        a[k] is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;
    public static bool Bool(this JsonObject a, string k, bool fallback = false) =>
        a[k] is JsonValue v && v.TryGetValue<bool>(out var b) ? b : fallback;
    public static int Int(this JsonObject a, string k, int fallback = 0)
    {
        if (a[k] is not JsonValue v) return fallback;
        if (v.TryGetValue<int>(out var i)) return i;
        if (v.TryGetValue<double>(out var d)) return (int)d;
        return fallback;
    }
    public static double Num(this JsonObject a, string k, double fallback = 0) =>
        a[k] is JsonValue v && v.TryGetValue<double>(out var d) ? d : fallback;
}
