using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Dropcap.Core;

// 피드에 없는 기사도 '나중에 읽기'로(I-05): dropcap://save?url=… 주소(북마클릿), 저장 목록의 '주소로 추가…' 칸, 명령줄 --save.
// 받은 주소는 공개 http(s) 주소인지 먼저 보고(UrlSafety), 기사 머리(og:title·og:image·og:site_name)로 소식을 만들어 저장 목록에 넣는다.
// 본문은 지금의 저장과 똑같이 미리 받아(번역까지) 보관하므로 인터넷 없이도 읽힌다. 맥 Core/SaveLink.swift 와 같은 규칙.
// (맥의 서비스 메뉴 'Dropcap 에 저장'은 윈도우에 같은 것이 없어 북마클릿·주소 칸·명령줄로 대신한다)
public static class SaveLink
{
    public const string Tier = "웹에서 저장";          // 출처 등급 이름표(Resources.TierLabel 이 그대로 보여 줌)
    public const string SourcePrefix = "web:";
    public const int MaxLength = 2048;

    public enum Failure { NotUrl, Unsafe, TooMany }

    public static string Message(Failure f) => f switch
    {
        Failure.NotUrl => "http(s) 기사 주소가 아닙니다",
        Failure.Unsafe => "내부망·특수 주소는 저장하지 않습니다",
        _ => "잠깐 사이에 너무 많이 들어와 멈췄어요",
    };

    public sealed record Result(NewsItem? Item, Failure? Error)
    {
        public bool Ok => Item is not null;
    }

    // MARK: 주소 해석(순수 함수 — 시험 대상)

    private static readonly char[] Quotes = ['<', '>', '"', '\'', '“', '”', '‘', '’'];
    private static readonly Regex HostPort = new(@"^[^/]+:\d+(/|$)");

    // 사람이 넣거나 바깥에서 받은 글에서 저장할 주소 하나. 공개 http(s) 주소만, 조각(#…)과 앞뒤 꺾쇠·따옴표는 뗀다.
    public static string? Normalize(string? raw)
    {
        if (raw is null) return null;
        var s = raw.Trim().Trim(Quotes);
        if (s.Length == 0 || s.Length > MaxLength || s.Any(char.IsWhiteSpace)) return null;
        if (!s.Contains("://", StringComparison.Ordinal)) // 'example.com/a' 처럼 스킴 없이 넣은 주소
        {
            if (!s.Contains('.') || s.StartsWith('/') || (s.Contains(':') && !HostPort.IsMatch(s))) return null;
            s = "https://" + s;
        }
        if (!UrlSafety.IsPublicHttp(s) || !Uri.TryCreate(s, UriKind.Absolute, out var u)) return null;
        if (u.UserInfo.Length > 0) return null; // 아이디·암호가 든 주소는 받지 않음
        var clean = u.GetComponents(UriComponents.HttpRequestUrl, UriFormat.UriEscaped);   // 조각(#…)·아이디 없이
        return clean.Length <= MaxLength && UrlSafety.IsPublicHttp(clean) ? clean : null;
    }

    public static string? CleanTitle(string? s)
    {
        if (s is null) return null;
        var t = Plain.Clean(s);
        if (t.Length == 0) return null;
        var info = new StringInfo(t);
        return info.LengthInTextElements > 300 ? info.SubstringByTextElements(0, 300) : t;
    }

    // 기사 머리에서 제목·사진·사이트 이름·설명(앞 128KB 만 넘겨 받는다). HtmlScan 으로 꼬리표를 하나씩 떼어 본다(큰 페이지에서 멈추지 않게)
    public sealed record Head(string? Title = null, string? Image = null, string? Site = null, string? Description = null);

    public static Head ParseHead(string html, string baseUrl)
    {
        string? Meta(params string[] names)
        {
            foreach (var n in names)
                if (CleanTitle(HtmlScan.Meta(html, n)) is { } v) return v;
            return null;
        }
        var title = Meta("og:title", "twitter:title") ?? CleanTitle(HtmlScan.Title(html));
        string? image = null;
        if (Meta("og:image", "og:image:url", "twitter:image") is { } raw
            && Uri.TryCreate(baseUrl, UriKind.Absolute, out var b) && Uri.TryCreate(b, raw, out var abs) && UrlSafety.IsPublicHttp(abs.AbsoluteUri))
            image = abs.AbsoluteUri;
        return new Head(title, image, Meta("og:site_name", "application-name"), Meta("og:description", "description", "twitter:description"));
    }

    private static string Host(string url) => Uri.TryCreate(url, UriKind.Absolute, out var u) ? u.Host : "";

    // 사이트 이름이 없으면 주소의 이름(www. 뗌)
    public static string SiteName(Head head, string url)
    {
        if (head.Site is { Length: > 0 } s) return s.Length > 60 ? s[..60] : s;
        var host = Host(url);
        if (host.Length == 0) host = "웹";
        return host.StartsWith("www.", StringComparison.Ordinal) ? host[4..] : host;
    }

    public static NewsItem MakeItem(string url, Head head, string? fallbackTitle = null, DateTimeOffset? now = null)
    {
        var site = SiteName(head, url);
        var host = Host(url);
        var path = Uri.TryCreate(url, UriKind.Absolute, out var u) ? u.AbsolutePath : "";
        var title = head.Title ?? fallbackTitle ?? Plain.TitleFromSlug(path.Length == 0 || path == "/" ? (host.Length > 0 ? host : url) : path);
        title = ArticleService.StripSiteName(title, site, title);
        title = StripHostSuffix(title, host);
        var desc = head.Description ?? "";
        return new NewsItem
        {
            Id = url, Title = title, Link = url, Date = now ?? DateTimeOffset.Now, Summary = desc.Length > 300 ? desc[..300] : desc,
            SourceId = SourcePrefix + (host.Length > 0 ? host : "web"), SourceName = site, Tier = Tier, Image = head.Image,
        };
    }

    // 'Initial - Wikipedia' 처럼 끝에 붙은 사이트 이름(주소의 이름과 같은 것)을 뗀다
    public static string StripHostSuffix(string title, string host)
    {
        var h = host.ToLowerInvariant().Replace("-", "");
        foreach (var sep in new[] { " - ", " | ", " – ", " — ", " :: " })
        {
            var i = title.LastIndexOf(sep, StringComparison.Ordinal);
            if (i < 0) continue;
            var tail = new string(title[(i + sep.Length)..].ToLowerInvariant().Where(char.IsLetterOrDigit).ToArray());
            var head = title[..i].Trim();
            if (tail.Length >= 3 && h.Contains(tail, StringComparison.Ordinal) && head.Length >= 3) return head;
        }
        return title;
    }

    // 바깥(주소·명령줄)에서 들어온 저장: 1분에 10번까지(웹 페이지가 dropcap:// 를 마구 부르는 경우 대비)
    public static bool AllowOutside(List<DateTimeOffset> recent, DateTimeOffset now)
    {
        recent.RemoveAll(t => (now - t).TotalSeconds >= 60);
        recent.Add(now);
        return recent.Count <= 10;
    }

    // MARK: 저장(받기 → 저장 목록 → 미리 받기)

    private static readonly List<DateTimeOffset> outside = new();
    // 시험에서 바꿔 끼운다(바깥 서버·DNS 없이)
    internal static Func<string, Task<bool>> Resolves { get; set; } = u => UrlSafety.ResolvesPublicAsync(u);
    internal static Func<string, Task<byte[]?>> Fetch { get; set; } = u => FeedService.Shared.FetchAsync(u, limit: FetchLimit.Page);

    // 저장 목록을 바꾸므로 화면 줄기에서 부른다(await 뒤에도 같은 줄기로 돌아옴)
    public static async Task<Result> SaveAsync(AppModel app, string raw, string? title = null, bool fromOutside = false)
    {
        if (Normalize(raw) is not { } url) return new(null, Failure.NotUrl);
        if (fromOutside)
            lock (outside) if (!AllowOutside(outside, DateTimeOffset.Now)) return new(null, Failure.TooMany);
        if (!UrlSafety.IsPublicHttp(url) || !await Resolves(url)) return new(null, Failure.Unsafe);
        if (app.State.Saved.FirstOrDefault(s => s.Link == url) is { } had) return new(had, null); // 이미 저장함
        var head = new Head();
        try
        {
            if (await Fetch(url) is { } data)
                head = ParseHead(Encoding.UTF8.GetString(data, 0, Math.Min(data.Length, 131_072)), url);
        }
        catch { } // 머리를 못 받아도 주소에서 제목을 지어 저장한다
        var item = MakeItem(url, head, title);
        if (!app.IsSaved(item)) app.ToggleSaved(item); // 저장 + 본문·번역 미리 받기(오프라인 읽기)
        return new(item, null);
    }

    // 바깥에서 들어온 저장은 결과를 작은 알림으로 알린다(제목, 아래 줄)
    public static (string Title, string Sub) Announcement(Result r) => r.Item is { } it
        ? ("나중에 읽기에 저장했어요", $"{it.SourceName} · {it.DisplayTitle}")
        : ("저장하지 못했어요", Message(r.Error ?? Failure.NotUrl));

    // 저장 전 확인 창의 글(아무 웹 페이지나 dropcap:// 를 부를 수 있으므로 한 번 묻는다)
    public const string ConfirmTitle = "이 페이지를 나중에 읽기에 저장할까요?";
    public static string ConfirmBody(string url, string? title) =>
        string.Join("\n", new[] { title, Host(url) is { Length: > 0 } h ? h : null, url.Length > 300 ? url[..300] : url }.OfType<string>());

    // 북마클릿: 지금 보고 있는 페이지를 Dropcap 에 저장
    public const string Bookmarklet = "javascript:(function(){location.href='dropcap://save?url='+encodeURIComponent(location.href)+'&title='+encodeURIComponent(document.title)})()";
}
