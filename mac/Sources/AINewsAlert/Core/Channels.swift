import Foundation

// 구독 채널: 추천 목록 + 아무 주소나 넣으면 알맞은 피드를 찾아 주는 해석기
enum ChannelCatalog {
    private static func c(_ id: String, _ name: String, _ url: String, _ kind: String, _ group: String,
                          color: String, notify: Bool = true, home: String? = nil, aiOnly: Bool = false) -> Source {
        Source(id: "cat-" + id, name: name, tier: "press", type: "feed", url: url, match: nil, aiOnly: aiOnly, defaultOn: true,
               color: color, kind: kind, notifyDefault: notify, group: group, home: home)
    }
    private static func yt(_ id: String, _ name: String, _ channel: String, color: String = "#FF0033") -> Source {
        c(id, name, "https://www.youtube.com/feeds/videos.xml?channel_id=\(channel)", "video", "YouTube", color: color,
          home: "https://www.youtube.com/channel/\(channel)")
    }
    private static func gh(_ repo: String, _ name: String) -> Source {
        c("gh-" + repo.replacingOccurrences(of: "/", with: "-"), name, "https://github.com/\(repo)/releases.atom", "release", "오픈소스 릴리스",
          color: "#6E7681", home: "https://github.com/\(repo)")
    }

    // 2026-10 확인한 주소들
    static let all: [Source] = [
        yt("yt-openai", "OpenAI (YouTube)", "UCXZCJLdBC09xxGZ6gcdrc6A"),
        yt("yt-anthropic", "Anthropic (YouTube)", "UCrDwWp7EBBv4NwvScIpBDOA"),
        yt("yt-deepmind", "Google DeepMind (YouTube)", "UCP7jMXSY2xbc3KCAE0MHQ-A"),
        yt("yt-2mp", "Two Minute Papers", "UCbfYPyITQ-7l4upoX8nvctg"),
        yt("yt-aiexplained", "AI Explained", "UCNJ1Ymd5yFuUPtn21xtRbbw"),
        yt("yt-yannic", "Yannic Kilcher", "UCZHmQk67mSJgfCCTn7xBfew"),

        c("importai", "Import AI", "https://importai.substack.com/feed", "article", "뉴스레터·블로그", color: "#3D5AFE"),
        c("simonw", "Simon Willison", "https://simonwillison.net/atom/everything/", "article", "뉴스레터·블로그", color: "#8B5CF6", notify: false),
        c("latentspace", "Latent Space", "https://www.latent.space/feed", "article", "뉴스레터·블로그", color: "#0EA5E9"),
        c("interconnects", "Interconnects", "https://www.interconnects.ai/feed", "article", "뉴스레터·블로그", color: "#F59E0B"),
        c("oneuseful", "One Useful Thing", "https://www.oneusefulthing.org/feed", "article", "뉴스레터·블로그", color: "#10B981"),
        c("aheadofai", "Ahead of AI", "https://magazine.sebastianraschka.com/feed", "article", "뉴스레터·블로그", color: "#EF4444"),
        c("lilianweng", "Lil'Log (Lilian Weng)", "https://lilianweng.github.io/index.xml", "article", "뉴스레터·블로그", color: "#EC4899"),
        c("gradient", "The Gradient", "https://thegradient.pub/rss/", "article", "뉴스레터·블로그", color: "#14B8A6"),

        c("msr", "Microsoft Research", "https://www.microsoft.com/en-us/research/feed/", "article", "연구소", color: "#0078D4"),
        c("appleml", "Apple Machine Learning", "https://machinelearning.apple.com/rss.xml", "article", "연구소", color: "#555555"),
        c("googleresearch", "Google Research", "https://research.google/blog/rss/", "article", "연구소", color: "#4285F4"),
        c("bair", "Berkeley AI Research", "https://bair.berkeley.edu/blog/feed.xml", "article", "연구소", color: "#003262"),

        c("arxiv-ai", "arXiv cs.AI", "https://rss.arxiv.org/rss/cs.AI", "paper", "논문", color: "#B31B1B", notify: false),
        c("arxiv-cl", "arXiv cs.CL (언어)", "https://rss.arxiv.org/rss/cs.CL", "paper", "논문", color: "#B31B1B", notify: false),
        c("arxiv-lg", "arXiv cs.LG (학습)", "https://rss.arxiv.org/rss/cs.LG", "paper", "논문", color: "#B31B1B", notify: false),

        gh("ollama/ollama", "Ollama"),
        gh("vllm-project/vllm", "vLLM"),
        gh("ggml-org/llama.cpp", "llama.cpp"),
        gh("huggingface/transformers", "Transformers"),
        gh("anthropics/claude-code", "Claude Code"),
        gh("openai/openai-python", "OpenAI Python SDK"),

        c("hn-ai", "Hacker News (AI·100점 이상)", "https://hnrss.org/newest?q=AI+OR+LLM&points=100", "post", "커뮤니티", color: "#FF6600", notify: false),
        // Reddit 은 로그인 없는 피드 요청을 자주 막는다(429). 막히면 다음 확인 때 다시 받는다.
        c("r-localllama", "r/LocalLLaMA (오늘 인기)", "https://www.reddit.com/r/LocalLLaMA/top/.rss?t=day", "post", "커뮤니티", color: "#FF4500", notify: false),
        c("r-ml", "r/MachineLearning (오늘 인기)", "https://www.reddit.com/r/MachineLearning/top/.rss?t=day", "post", "커뮤니티", color: "#FF4500", notify: false),

        c("bloter", "블로터", "https://www.bloter.net/rss/allArticle.xml", "article", "국내", color: "#E4002B", aiOnly: true),
        c("byline", "바이라인네트워크", "https://byline.network/feed/", "article", "국내", color: "#111827", aiOnly: true),
        c("yozm", "요즘IT", "https://yozm.wishket.com/magazine/feed/", "article", "국내", color: "#4F46E5", aiOnly: true),
        c("kakaotech", "카카오 기술 블로그", "https://tech.kakao.com/feed/", "article", "국내", color: "#FEE500"),
        c("naverd2", "네이버 D2", "https://d2.naver.com/d2.atom", "article", "국내", color: "#03C75A"),

        c("practicalai", "Practical AI (팟캐스트)", "https://changelog.com/practicalai/feed", "podcast", "팟캐스트", color: "#5A67D8"),
        c("twiml", "TWIML AI (팟캐스트)", "https://feeds.megaphone.fm/MLN2155636147", "podcast", "팟캐스트", color: "#2563EB"),
    ]

    static let groups = ["YouTube", "뉴스레터·블로그", "연구소", "논문", "오픈소스 릴리스", "커뮤니티", "국내", "팟캐스트"]
}

// 주소(또는 짧은 표기)를 받아 구독할 피드를 찾는다
enum ChannelResolver {
    struct Found {
        var feedURL: String
        var name: String
        var kind: ItemKind
        var home: String?
        var notifyDefault: Bool
    }

    enum Failure: LocalizedError {
        case notFound, unsafe
        var errorDescription: String? {
            switch self {
            case .notFound: return "이 주소에서 구독할 수 있는 피드를 찾지 못했습니다"
            case .unsafe: return "공개 인터넷 주소만 구독할 수 있습니다"
            }
        }
    }

    static func resolve(_ input: String) async throws -> Found {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw Failure.notFound }

        // 짧은 표기
        if let m = s.range(of: #"^/?r/([A-Za-z0-9_]+)/?$"#, options: .regularExpression) {
            let sub = s[m].replacingOccurrences(of: "/", with: "").dropFirst()
            return try await check("https://www.reddit.com/r/\(sub)/top/.rss?t=day", kind: .post, name: "r/\(sub) (오늘 인기)", notify: false)
        }
        if s.range(of: #"^(cs|stat|math|eess|q-bio)\.[A-Za-z]{2}$"#, options: .regularExpression) != nil {
            return try await check("https://rss.arxiv.org/rss/\(s)", kind: .paper, name: "arXiv \(s)", notify: false)
        }
        if s.lowercased() == "hn" || s.lowercased() == "hacker news" {
            return try await check("https://hnrss.org/frontpage", kind: .post, name: "Hacker News", notify: false)
        }
        if !s.contains("://") { s = "https://" + s }
        guard var url = URL(string: s), let host = url.host?.lowercased() else { throw Failure.notFound }
        guard await URLSafety.resolvesPublic(url) else { throw Failure.unsafe }
        let path = url.path

        // YouTube: 채널·핸들·재생목록
        if host.hasSuffix("youtube.com") || host == "youtu.be" {
            if let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "list" })?.value {
                return try await check("https://www.youtube.com/feeds/videos.xml?playlist_id=\(q)", kind: .video, home: url.absoluteString)
            }
            if let r = path.range(of: #"/channel/(UC[\w-]{22})"#, options: .regularExpression) {
                let id = path[r].replacingOccurrences(of: "/channel/", with: "")
                return try await check("https://www.youtube.com/feeds/videos.xml?channel_id=\(id)", kind: .video, home: url.absoluteString)
            }
            // @핸들·/c/·/user/: 페이지에서 채널 ID 를 찾는다
            if let html = try? await FeedService.shared.fetch(url.absoluteString).map({ String(decoding: $0, as: UTF8.self) }),
               let id = firstMatch(html, #"<link rel="canonical" href="https://www\.youtube\.com/channel/(UC[\w-]{22})""#)
                ?? firstMatch(html, #""(?:channelId|externalId)":"(UC[\w-]{22})""#) {
                return try await check("https://www.youtube.com/feeds/videos.xml?channel_id=\(id)", kind: .video, home: url.absoluteString)
            }
            throw Failure.notFound
        }
        // GitHub 저장소 → 릴리스
        if host == "github.com" {
            let parts = path.split(separator: "/").map(String.init)
            if parts.count >= 2 {
                return try await check("https://github.com/\(parts[0])/\(parts[1])/releases.atom", kind: .release,
                                       name: "\(parts[1]) 릴리스", home: "https://github.com/\(parts[0])/\(parts[1])")
            }
        }
        // Reddit
        if host.hasSuffix("reddit.com"), let r = path.range(of: #"/r/([A-Za-z0-9_]+)"#, options: .regularExpression) {
            let sub = path[r].replacingOccurrences(of: "/r/", with: "")
            return try await check("https://www.reddit.com/r/\(sub)/top/.rss?t=day", kind: .post, name: "r/\(sub) (오늘 인기)", notify: false)
        }
        // arXiv 목록
        if host.hasSuffix("arxiv.org"), let r = path.range(of: #"/list/([a-z\-]+\.[A-Za-z]{2})"#, options: .regularExpression) {
            let cat = path[r].replacingOccurrences(of: "/list/", with: "")
            return try await check("https://rss.arxiv.org/rss/\(cat)", kind: .paper, name: "arXiv \(cat)", notify: false)
        }
        // Medium·Substack
        if host == "medium.com", let user = path.split(separator: "/").first, user.hasPrefix("@") {
            return try await check("https://medium.com/feed/\(user)", kind: .article, home: url.absoluteString)
        }
        if host.hasSuffix(".substack.com") {
            return try await check("https://\(host)/feed", kind: .article, home: url.absoluteString)
        }

        // 그 밖: 주소 자체가 피드인지 → 페이지가 알려 주는 피드(<link rel="alternate">) → 흔한 위치
        if let f = try? await check(url.absoluteString, kind: .article) { return f }
        if let data = try? await FeedService.shared.fetch(url.absoluteString) {
            let html = String(decoding: data.prefix(200_000), as: UTF8.self)
            for href in alternates(html) {
                if let u = URL(string: href, relativeTo: url)?.absoluteURL, let f = try? await check(u.absoluteString, kind: .article, home: url.absoluteString) {
                    return f
                }
            }
        }
        url = URL(string: "\(url.scheme ?? "https")://\(host)")!
        for p in ["/feed", "/rss", "/feed.xml", "/atom.xml", "/index.xml", "/rss.xml", "/blog/feed", "/blog/rss.xml"] {
            if let f = try? await check(url.absoluteString + p, kind: .article, home: url.absoluteString) { return f }
        }
        throw Failure.notFound
    }

    // 실제로 받아서 글이 있는지 확인
    private static func check(_ feed: String, kind: ItemKind, name: String? = nil, home: String? = nil, notify: Bool = true) async throws -> Found {
        guard let data = try await FeedService.shared.fetch(feed) else { throw Failure.notFound }
        let entries = try FeedParser.parseFeed(data)
        guard !entries.isEmpty else { throw Failure.notFound }
        let title = name ?? FeedParser.feedTitle(data) ?? URL(string: feed)?.host ?? feed
        // 하루에 글이 많이 올라오는 채널은 알림 기본값을 끈다
        let recent = entries.compactMap(\.date).filter { Date().timeIntervalSince($0) < 24 * 3600 }.count
        return Found(feedURL: feed, name: title, kind: kind, home: home, notifyDefault: notify && recent <= 15)
    }

    private static func alternates(_ html: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"<link[^>]+rel=["']alternate["'][^>]*>"#, options: [.caseInsensitive]) else { return [] }
        return re.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { m in
            guard let r = Range(m.range, in: html) else { return nil }
            let tag = String(html[r])
            guard tag.range(of: #"type=["']application/(rss|atom)\+xml["']"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
            return firstMatch(tag, #"href=["']([^"']+)["']"#)?.replacingOccurrences(of: "&amp;", with: "&")
        }
    }

    private static func firstMatch(_ s: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }
}
