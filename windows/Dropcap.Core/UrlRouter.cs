namespace Dropcap.Core;

// dropcap:// 주소와 명령줄 인자 해석(I-04 · I-02 대신). 맥 Integrations/URLRouter.swift 와 같은 길:
//   dropcap://open?key=<기사 key>     그 기사 읽기 창
//   dropcap://magazine                 매거진 열기
//   dropcap://save?url=<주소>[&title=]  나중에 읽기로 저장(북마클릿 — 저장 전 확인 창)
// 윈도우에는 단축어 앱이 없어 명령줄로도 부른다: Dropcap.exe --magazine · Dropcap.exe --save <주소>(사용자가 직접 부른 것이라 묻지 않음 — 맥 단축어와 같음).
// 실제로 여는 일은 앱(Shell)이 하고, 여기서는 글자만 본다(순수 함수 — 시험 대상).
public abstract record Route
{
    public sealed record Open(string Key) : Route;
    public sealed record Magazine : Route;
    public sealed record Save(string Url, string? Title, bool Confirm) : Route;
}

public static class UrlRouter
{
    public const string Scheme = "dropcap";
    public const int MaxLength = 8192;   // 이보다 긴 주소는 보지 않는다(저장할 주소 자체는 SaveLink.MaxLength)
    public const string MagazineLink = "dropcap://magazine";

    public static string OpenLink(string key) => "dropcap://open?key=" + Uri.EscapeDataString(key);

    // dropcap://<동작>?<이름>=<값>&… (dropcap:save?… 처럼 // 없이 와도). 모르는 동작·빠진 값이면 null
    public static Route? Parse(string? raw)
    {
        if (raw is null || raw.Length > MaxLength) return null;
        var s = raw.Trim();
        if (!s.StartsWith(Scheme + ":", StringComparison.OrdinalIgnoreCase)) return null;
        s = s[(Scheme.Length + 1)..];
        if (s.StartsWith("//", StringComparison.Ordinal)) s = s[2..];
        var hash = s.IndexOf('#');
        if (hash >= 0) s = s[..hash];
        var q = s.IndexOf('?');
        var action = (q < 0 ? s : s[..q]).Trim('/').ToLowerInvariant();
        var query = Query(q < 0 ? "" : s[(q + 1)..]);
        switch (action)
        {
            case "open":
                return query.TryGetValue("key", out var key) && key.Length > 0 ? new Route.Open(key) : null;
            case "magazine":
                return new Route.Magazine();
            case "save":
                if (!query.TryGetValue("url", out var u) || SaveLink.Normalize(u) is not { } url) return null;
                return new Route.Save(url, SaveLink.CleanTitle(query.GetValueOrDefault("title")), Confirm: true);
            default:
                return null;
        }
    }

    // 이름=값 목록(같은 이름은 앞의 것). '+' 는 그대로 둔다(맥 URLComponents 와 같음)
    public static Dictionary<string, string> Query(string q)
    {
        var o = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var part in q.Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var eq = part.IndexOf('=');
            var name = Unescape(eq < 0 ? part : part[..eq]);
            var value = eq < 0 ? "" : Unescape(part[(eq + 1)..]);
            if (name is not null && value is not null) o.TryAdd(name, value);
        }
        return o;
    }

    private static string? Unescape(string s)
    {
        try { return Uri.UnescapeDataString(s); } catch { return null; }
    }

    // 명령줄: 주소 하나(dropcap://…, 주소 연결로 켜졌을 때) · --magazine · --save <주소>
    public static Route? FromArgs(IReadOnlyList<string> args)
    {
        if (args.Count == 0) return null;
        var a = args[0].Trim();
        if (a.StartsWith(Scheme + ":", StringComparison.OrdinalIgnoreCase)) return Parse(a);
        return a.ToLowerInvariant() switch
        {
            "--magazine" or "/magazine" => new Route.Magazine(),
            "--save" or "/save" when args.Count > 1 && SaveLink.Normalize(args[1]) is { } url => new Route.Save(url, null, Confirm: false),
            _ => null,
        };
    }
}
