using System.Text;
using System.Text.RegularExpressions;

namespace Dropcap.Core;

// 구독 채널: 추천 목록 + 아무 주소나 넣으면 알맞은 피드를 찾아 주는 해석기(K 절)
public static class ChannelCatalog
{
    private static Source C(string id, string name, string url, string kind, string group, string color, bool notify = true, string? home = null, bool aiOnly = false) =>
        new()
        {
            Id = "cat-" + id, Name = name, Tier = "press", Type = "feed", Url = url, AiOnly = aiOnly, DefaultOn = true,
            Color = color, Kind = kind, NotifyDefault = notify, Group = group, Home = home,
        };

    private static Source Yt(string id, string name, string channel, string color = "#FF0033") =>
        C(id, name, $"https://www.youtube.com/feeds/videos.xml?channel_id={channel}", "video", "YouTube", color,
            home: $"https://www.youtube.com/channel/{channel}");

    private static Source Gh(string repo, string name) =>
        C("gh-" + repo.Replace("/", "-"), name, $"https://github.com/{repo}/releases.atom", "release", "오픈소스 릴리스", "#6E7681",
            home: $"https://github.com/{repo}");

    // 2026-10 확인한 주소들(맥 Channels.swift 와 같은 37개 — FEATURES K-01 은 36개로 적혀 있음)
    public static readonly IReadOnlyList<Source> All =
    [
        Yt("yt-openai", "OpenAI (YouTube)", "UCXZCJLdBC09xxGZ6gcdrc6A"),
        Yt("yt-anthropic", "Anthropic (YouTube)", "UCrDwWp7EBBv4NwvScIpBDOA"),
        Yt("yt-deepmind", "Google DeepMind (YouTube)", "UCP7jMXSY2xbc3KCAE0MHQ-A"),
        Yt("yt-2mp", "Two Minute Papers", "UCbfYPyITQ-7l4upoX8nvctg"),
        Yt("yt-aiexplained", "AI Explained", "UCNJ1Ymd5yFuUPtn21xtRbbw"),
        Yt("yt-yannic", "Yannic Kilcher", "UCZHmQk67mSJgfCCTn7xBfew"),

        C("importai", "Import AI", "https://importai.substack.com/feed", "article", "뉴스레터·블로그", "#3D5AFE"),
        C("simonw", "Simon Willison", "https://simonwillison.net/atom/everything/", "article", "뉴스레터·블로그", "#8B5CF6", notify: false),
        C("latentspace", "Latent Space", "https://www.latent.space/feed", "article", "뉴스레터·블로그", "#0EA5E9"),
        C("interconnects", "Interconnects", "https://www.interconnects.ai/feed", "article", "뉴스레터·블로그", "#F59E0B"),
        C("oneuseful", "One Useful Thing", "https://www.oneusefulthing.org/feed", "article", "뉴스레터·블로그", "#10B981"),
        C("aheadofai", "Ahead of AI", "https://magazine.sebastianraschka.com/feed", "article", "뉴스레터·블로그", "#EF4444"),
        C("lilianweng", "Lil'Log (Lilian Weng)", "https://lilianweng.github.io/index.xml", "article", "뉴스레터·블로그", "#EC4899"),
        C("gradient", "The Gradient", "https://thegradient.pub/rss/", "article", "뉴스레터·블로그", "#14B8A6"),

        C("msr", "Microsoft Research", "https://www.microsoft.com/en-us/research/feed/", "article", "연구소", "#0078D4"),
        C("appleml", "Apple Machine Learning", "https://machinelearning.apple.com/rss.xml", "article", "연구소", "#555555"),
        C("googleresearch", "Google Research", "https://research.google/blog/rss/", "article", "연구소", "#4285F4"),
        C("bair", "Berkeley AI Research", "https://bair.berkeley.edu/blog/feed.xml", "article", "연구소", "#003262"),

        C("arxiv-ai", "arXiv cs.AI", "https://rss.arxiv.org/rss/cs.AI", "paper", "논문", "#B31B1B", notify: false),
        C("arxiv-cl", "arXiv cs.CL (언어)", "https://rss.arxiv.org/rss/cs.CL", "paper", "논문", "#B31B1B", notify: false),
        C("arxiv-lg", "arXiv cs.LG (학습)", "https://rss.arxiv.org/rss/cs.LG", "paper", "논문", "#B31B1B", notify: false),

        Gh("ollama/ollama", "Ollama"),
        Gh("vllm-project/vllm", "vLLM"),
        Gh("ggml-org/llama.cpp", "llama.cpp"),
        Gh("huggingface/transformers", "Transformers"),
        Gh("anthropics/claude-code", "Claude Code"),
        Gh("openai/openai-python", "OpenAI Python SDK"),

        C("hn-ai", "Hacker News (AI·100점 이상)", "https://hnrss.org/newest?q=AI+OR+LLM&points=100", "post", "커뮤니티", "#FF6600", notify: false),
        // Reddit 은 로그인 없는 피드 요청을 자주 막는다(429). 막히면 다음 확인 때 다시 받는다.
        C("r-localllama", "r/LocalLLaMA (오늘 인기)", "https://www.reddit.com/r/LocalLLaMA/top/.rss?t=day", "post", "커뮤니티", "#FF4500", notify: false),
        C("r-ml", "r/MachineLearning (오늘 인기)", "https://www.reddit.com/r/MachineLearning/top/.rss?t=day", "post", "커뮤니티", "#FF4500", notify: false),

        C("bloter", "블로터", "https://www.bloter.net/rss/allArticle.xml", "article", "국내", "#E4002B", aiOnly: true),
        C("byline", "바이라인네트워크", "https://byline.network/feed/", "article", "국내", "#111827", aiOnly: true),
        C("yozm", "요즘IT", "https://yozm.wishket.com/magazine/feed/", "article", "국내", "#4F46E5", aiOnly: true),
        C("kakaotech", "카카오 기술 블로그", "https://tech.kakao.com/feed/", "article", "국내", "#FEE500"),
        C("naverd2", "네이버 D2", "https://d2.naver.com/d2.atom", "article", "국내", "#03C75A"),

        C("practicalai", "Practical AI (팟캐스트)", "https://changelog.com/practicalai/feed", "podcast", "팟캐스트", "#5A67D8"),
        C("twiml", "TWIML AI (팟캐스트)", "https://feeds.megaphone.fm/MLN2155636147", "podcast", "팟캐스트", "#2563EB"),
    ];

    public static readonly IReadOnlyList<string> Groups = ["YouTube", "뉴스레터·블로그", "연구소", "논문", "오픈소스 릴리스", "커뮤니티", "국내", "팟캐스트"];
}

// 주소(또는 짧은 표기)를 받아 구독할 피드를 찾는다
public static class ChannelResolver
{
    public sealed record Found(string FeedUrl, string Name, ItemKind Kind, string? Home, bool NotifyDefault);

    public sealed class Failure(string message) : Exception(message)
    {
        public static Failure NotFound() => new("이 주소에서 구독할 수 있는 피드를 찾지 못했습니다");
        public static Failure Unsafe() => new("공개 인터넷 주소만 구독할 수 있습니다");
    }

    public static async Task<Found> ResolveAsync(string input, CancellationToken ct = default)
    {
        var s = input.Trim();
        if (s.Length == 0) throw Failure.NotFound();

        // 짧은 표기
        var rm = Regex.Match(s, "^/?r/([A-Za-z0-9_]+)/?$");
        if (rm.Success)
        {
            var sub = rm.Groups[1].Value;
            return await CheckAsync($"https://www.reddit.com/r/{sub}/top/.rss?t=day", ItemKind.Post, $"r/{sub} (오늘 인기)", notify: false, ct: ct);
        }
        if (Regex.IsMatch(s, @"^(cs|stat|math|eess|q-bio)\.[A-Za-z]{2}$"))
            return await CheckAsync($"https://rss.arxiv.org/rss/{s}", ItemKind.Paper, $"arXiv {s}", notify: false, ct: ct);
        if (s.ToLowerInvariant() is "hn" or "hacker news")
            return await CheckAsync("https://hnrss.org/frontpage", ItemKind.Post, "Hacker News", notify: false, ct: ct);
        if (!s.Contains("://")) s = "https://" + s;
        if (!Uri.TryCreate(s, UriKind.Absolute, out var url) || url.Host.Length == 0) throw Failure.NotFound();
        if (!await UrlSafety.ResolvesPublicAsync(url.AbsoluteUri, ct)) throw Failure.Unsafe();
        var host = url.Host.ToLowerInvariant();
        var path = url.AbsolutePath;

        // YouTube: 채널·핸들·재생목록
        if (host.EndsWith("youtube.com") || host == "youtu.be")
        {
            var list = System.Web.HttpUtility.ParseQueryString(url.Query)["list"];
            if (!string.IsNullOrEmpty(list))
                return await CheckAsync($"https://www.youtube.com/feeds/videos.xml?playlist_id={list}", ItemKind.Video, home: url.AbsoluteUri, ct: ct);
            var ch = Regex.Match(path, @"/channel/(UC[\w-]{22})");
            if (ch.Success)
                return await CheckAsync($"https://www.youtube.com/feeds/videos.xml?channel_id={ch.Groups[1].Value}", ItemKind.Video, home: url.AbsoluteUri, ct: ct);
            // @핸들·/c/·/user/: 페이지에서 채널 ID 를 찾는다
            string? html = null;
            try { if (await FeedService.Shared.FetchAsync(url.AbsoluteUri, ct: ct) is { } d) html = Encoding.UTF8.GetString(d); } catch { }
            if (html is not null && (FirstMatch(html, "<link rel=\"canonical\" href=\"https://www\\.youtube\\.com/channel/(UC[\\w-]{22})\"")
                                     ?? FirstMatch(html, "\"(?:channelId|externalId)\":\"(UC[\\w-]{22})\"")) is { } id)
                return await CheckAsync($"https://www.youtube.com/feeds/videos.xml?channel_id={id}", ItemKind.Video, home: url.AbsoluteUri, ct: ct);
            throw Failure.NotFound();
        }
        // GitHub 저장소 → 릴리스
        if (host == "github.com")
        {
            var parts = path.Split('/', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length >= 2)
                return await CheckAsync($"https://github.com/{parts[0]}/{parts[1]}/releases.atom", ItemKind.Release, $"{parts[1]} 릴리스",
                    $"https://github.com/{parts[0]}/{parts[1]}", ct: ct);
        }
        // Reddit
        if (host.EndsWith("reddit.com") && Regex.Match(path, "/r/([A-Za-z0-9_]+)") is { Success: true } rr)
        {
            var sub = rr.Groups[1].Value;
            return await CheckAsync($"https://www.reddit.com/r/{sub}/top/.rss?t=day", ItemKind.Post, $"r/{sub} (오늘 인기)", notify: false, ct: ct);
        }
        // arXiv 목록
        if (host.EndsWith("arxiv.org") && Regex.Match(path, @"/list/([a-z\-]+\.[A-Za-z]{2})") is { Success: true } ar)
        {
            var cat = ar.Groups[1].Value;
            return await CheckAsync($"https://rss.arxiv.org/rss/{cat}", ItemKind.Paper, $"arXiv {cat}", notify: false, ct: ct);
        }
        // Medium·Substack
        if (host == "medium.com" && path.Split('/', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() is { } user && user.StartsWith('@'))
            return await CheckAsync($"https://medium.com/feed/{user}", ItemKind.Article, home: url.AbsoluteUri, ct: ct);
        if (host.EndsWith(".substack.com"))
            return await CheckAsync($"https://{host}/feed", ItemKind.Article, home: url.AbsoluteUri, ct: ct);

        // 그 밖: 주소 자체가 피드인지 → 페이지가 알려 주는 피드(<link rel="alternate">) → 흔한 위치
        if (await TryCheckAsync(url.AbsoluteUri, ItemKind.Article, ct: ct) is { } f0) return f0;
        byte[]? page = null;
        try { page = await FeedService.Shared.FetchAsync(url.AbsoluteUri, ct: ct); } catch { }
        if (page is not null)
        {
            var html = Encoding.UTF8.GetString(page, 0, Math.Min(page.Length, 200_000));
            foreach (var href in Alternates(html))
                if (Uri.TryCreate(url, href, out var u) && await TryCheckAsync(u.AbsoluteUri, ItemKind.Article, home: url.AbsoluteUri, ct: ct) is { } f1)
                    return f1;
        }
        var root = url.GetLeftPart(UriPartial.Authority); // IPv6 주소([..])·포트도 그대로(맥 A-01)
        foreach (var p in new[] { "/feed", "/rss", "/feed.xml", "/atom.xml", "/index.xml", "/rss.xml", "/blog/feed", "/blog/rss.xml" })
            if (await TryCheckAsync(root + p, ItemKind.Article, home: root, ct: ct) is { } f2) return f2;
        throw Failure.NotFound();
    }

    private static async Task<Found?> TryCheckAsync(string feed, ItemKind kind, string? name = null, string? home = null, CancellationToken ct = default)
    {
        try { return await CheckAsync(feed, kind, name, home, ct: ct); } catch { return null; }
    }

    // 실제로 받아서 글이 있는지 확인(K-03)
    private static async Task<Found> CheckAsync(string feed, ItemKind kind, string? name = null, string? home = null, bool notify = true, CancellationToken ct = default)
    {
        var data = await FeedService.Shared.FetchAsync(feed, ct: ct) ?? throw Failure.NotFound();
        var entries = FeedParser.ParseFeed(data);
        // 논문 피드는 발표 사이에 잠시 비어 있을 수 있다 — 형식이 맞으면 받아들인다
        if (entries.Count == 0 && !(kind == ItemKind.Paper && FeedParser.FeedTitle(data) is not null)) throw Failure.NotFound();
        var title = name ?? FeedParser.FeedTitle(data) ?? (Uri.TryCreate(feed, UriKind.Absolute, out var fu) ? fu.Host : feed);
        // 하루에 글이 많이 올라오는 채널은 알림 기본값을 끈다
        var recent = entries.Count(e => e.Date is { } d && DateTimeOffset.Now - d < TimeSpan.FromHours(24));
        return new Found(feed, title, kind, home, notify && recent <= 15);
    }

    // <link …> 를 하나씩 떼어 본다(HtmlScan — 정규식 되풀이 훑기로 큰 페이지에서 멈추지 않게, 보안 점검)
    internal static IEnumerable<string> Alternates(string html)
    {
        foreach (var tag in HtmlScan.Tags("link", html))
        {
            if (!string.Equals(HtmlScan.Attr(tag, "rel"), "alternate", StringComparison.OrdinalIgnoreCase)) continue;
            if (HtmlScan.Attr(tag, "type")?.ToLowerInvariant() is not ("application/rss+xml" or "application/atom+xml")) continue;
            if (HtmlScan.Attr(tag, "href") is { Length: > 0 } h) yield return h.Replace("&amp;", "&");
        }
    }

    private static string? FirstMatch(string s, string pattern)
    {
        var m = Regex.Match(s, pattern);
        return m.Success && m.Groups.Count > 1 ? m.Groups[1].Value : null;
    }
}
