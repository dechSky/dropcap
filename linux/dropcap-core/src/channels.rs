// 구독 채널: 추천 목록 + 아무 주소나 넣으면 알맞은 피드를 찾아 주는 해석기(맥 Core/Channels.swift).
use crate::feed_parser;
use crate::feed_service::SHARED as FEEDS;
use crate::models::{ItemKind, Source};
use crate::url_safety;
use chrono::Utc;
use once_cell::sync::Lazy;
use regex::{Regex, RegexBuilder};

fn c(id: &str, name: &str, url: &str, kind: &str, group: &str, color: &str, notify: bool, home: Option<String>, ai_only: bool) -> Source {
    Source {
        id: format!("cat-{id}"),
        name: name.into(),
        tier: "press".into(),
        kind_type: "feed".into(),
        url: url.into(),
        match_: None,
        ai_only,
        default_on: true,
        color: color.into(),
        kind: Some(kind.into()),
        notify_default: Some(notify),
        group: Some(group.into()),
        home,
        section: None,
        lang: None,
        region: None,
    }
}

fn a(id: &str, name: &str, url: &str, kind: &str, group: &str, color: &str) -> Source {
    c(id, name, url, kind, group, color, true, None, false)
}

fn yt(id: &str, name: &str, channel: &str) -> Source {
    c(
        id,
        name,
        &format!("https://www.youtube.com/feeds/videos.xml?channel_id={channel}"),
        "video",
        "YouTube",
        "#FF0033",
        true,
        Some(format!("https://www.youtube.com/channel/{channel}")),
        false,
    )
}

fn gh(repo: &str, name: &str) -> Source {
    c(
        &format!("gh-{}", repo.replace('/', "-")),
        name,
        &format!("https://github.com/{repo}/releases.atom"),
        "release",
        "오픈소스 릴리스",
        "#6E7681",
        true,
        Some(format!("https://github.com/{repo}")),
        false,
    )
}

// 2026-10 확인한 주소들(맥과 같은 37개)
pub static CATALOG: Lazy<Vec<Source>> = Lazy::new(|| {
    vec![
        yt("yt-openai", "OpenAI (YouTube)", "UCXZCJLdBC09xxGZ6gcdrc6A"),
        yt("yt-anthropic", "Anthropic (YouTube)", "UCrDwWp7EBBv4NwvScIpBDOA"),
        yt("yt-deepmind", "Google DeepMind (YouTube)", "UCP7jMXSY2xbc3KCAE0MHQ-A"),
        yt("yt-2mp", "Two Minute Papers", "UCbfYPyITQ-7l4upoX8nvctg"),
        yt("yt-aiexplained", "AI Explained", "UCNJ1Ymd5yFuUPtn21xtRbbw"),
        yt("yt-yannic", "Yannic Kilcher", "UCZHmQk67mSJgfCCTn7xBfew"),
        a("importai", "Import AI", "https://importai.substack.com/feed", "article", "뉴스레터·블로그", "#3D5AFE"),
        c("simonw", "Simon Willison", "https://simonwillison.net/atom/everything/", "article", "뉴스레터·블로그", "#8B5CF6", false, None, false),
        a("latentspace", "Latent Space", "https://www.latent.space/feed", "article", "뉴스레터·블로그", "#0EA5E9"),
        a("interconnects", "Interconnects", "https://www.interconnects.ai/feed", "article", "뉴스레터·블로그", "#F59E0B"),
        a("oneuseful", "One Useful Thing", "https://www.oneusefulthing.org/feed", "article", "뉴스레터·블로그", "#10B981"),
        a("aheadofai", "Ahead of AI", "https://magazine.sebastianraschka.com/feed", "article", "뉴스레터·블로그", "#EF4444"),
        a("lilianweng", "Lil'Log (Lilian Weng)", "https://lilianweng.github.io/index.xml", "article", "뉴스레터·블로그", "#EC4899"),
        a("gradient", "The Gradient", "https://thegradient.pub/rss/", "article", "뉴스레터·블로그", "#14B8A6"),
        a("msr", "Microsoft Research", "https://www.microsoft.com/en-us/research/feed/", "article", "연구소", "#0078D4"),
        a("appleml", "Apple Machine Learning", "https://machinelearning.apple.com/rss.xml", "article", "연구소", "#555555"),
        a("googleresearch", "Google Research", "https://research.google/blog/rss/", "article", "연구소", "#4285F4"),
        a("bair", "Berkeley AI Research", "https://bair.berkeley.edu/blog/feed.xml", "article", "연구소", "#003262"),
        c("arxiv-ai", "arXiv cs.AI", "https://rss.arxiv.org/rss/cs.AI", "paper", "논문", "#B31B1B", false, None, false),
        c("arxiv-cl", "arXiv cs.CL (언어)", "https://rss.arxiv.org/rss/cs.CL", "paper", "논문", "#B31B1B", false, None, false),
        c("arxiv-lg", "arXiv cs.LG (학습)", "https://rss.arxiv.org/rss/cs.LG", "paper", "논문", "#B31B1B", false, None, false),
        gh("ollama/ollama", "Ollama"),
        gh("vllm-project/vllm", "vLLM"),
        gh("ggml-org/llama.cpp", "llama.cpp"),
        gh("huggingface/transformers", "Transformers"),
        gh("anthropics/claude-code", "Claude Code"),
        gh("openai/openai-python", "OpenAI Python SDK"),
        c("hn-ai", "Hacker News (AI·100점 이상)", "https://hnrss.org/newest?q=AI+OR+LLM&points=100", "post", "커뮤니티", "#FF6600", false, None, false),
        // Reddit 은 로그인 없는 피드 요청을 자주 막는다(429). 막히면 다음 확인 때 다시 받는다.
        c("r-localllama", "r/LocalLLaMA (오늘 인기)", "https://www.reddit.com/r/LocalLLaMA/top/.rss?t=day", "post", "커뮤니티", "#FF4500", false, None, false),
        c("r-ml", "r/MachineLearning (오늘 인기)", "https://www.reddit.com/r/MachineLearning/top/.rss?t=day", "post", "커뮤니티", "#FF4500", false, None, false),
        c("bloter", "블로터", "https://www.bloter.net/rss/allArticle.xml", "article", "국내", "#E4002B", true, None, true),
        c("byline", "바이라인네트워크", "https://byline.network/feed/", "article", "국내", "#111827", true, None, true),
        c("yozm", "요즘IT", "https://yozm.wishket.com/magazine/feed/", "article", "국내", "#4F46E5", true, None, true),
        a("kakaotech", "카카오 기술 블로그", "https://tech.kakao.com/feed/", "article", "국내", "#FEE500"),
        a("naverd2", "네이버 D2", "https://d2.naver.com/d2.atom", "article", "국내", "#03C75A"),
        a("practicalai", "Practical AI (팟캐스트)", "https://changelog.com/practicalai/feed", "podcast", "팟캐스트", "#5A67D8"),
        a("twiml", "TWIML AI (팟캐스트)", "https://feeds.megaphone.fm/MLN2155636147", "podcast", "팟캐스트", "#2563EB"),
    ]
});

pub const GROUPS: [&str; 8] = ["YouTube", "뉴스레터·블로그", "연구소", "논문", "오픈소스 릴리스", "커뮤니티", "국내", "팟캐스트"];

#[derive(Debug, Clone, PartialEq)]
pub struct Found {
    pub feed_url: String,
    pub name: String,
    pub kind: ItemKind,
    pub home: Option<String>,
    pub notify_default: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Failure {
    NotFound,
    Unsafe,
}

impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Failure::NotFound => write!(f, "이 주소에서 구독할 수 있는 피드를 찾지 못했습니다"),
            Failure::Unsafe => write!(f, "공개 인터넷 주소만 구독할 수 있습니다"),
        }
    }
}

// 받지 않고 바로 정할 수 있는 짧은 표기·이름 규칙(시험할 수 있게 나눔)
#[derive(Debug, Clone, PartialEq)]
pub enum Plan {
    Check { feed: String, kind: ItemKind, name: Option<String>, home: Option<String>, notify: bool },
    YouTubePage(String),
    Generic(String),
}

static RE_SUB: Lazy<Regex> = Lazy::new(|| Regex::new(r"^/?r/([A-Za-z0-9_]+)/?$").unwrap());
static RE_ARXIV: Lazy<Regex> = Lazy::new(|| Regex::new(r"^(cs|stat|math|eess|q-bio)\.[A-Za-z]{2}$").unwrap());
static RE_YT_CH: Lazy<Regex> = Lazy::new(|| Regex::new(r"/channel/(UC[\w-]{22})").unwrap());
static RE_R_PATH: Lazy<Regex> = Lazy::new(|| Regex::new(r"/r/([A-Za-z0-9_]+)").unwrap());
static RE_ARXIV_LIST: Lazy<Regex> = Lazy::new(|| Regex::new(r"/list/([a-z\-]+\.[A-Za-z]{2})").unwrap());

pub fn plan(input: &str) -> Result<Plan, Failure> {
    let mut s = input.trim().to_string();
    if s.is_empty() {
        return Err(Failure::NotFound);
    }
    let check = |feed: String, kind: ItemKind, name: Option<String>, home: Option<String>, notify: bool| Ok(Plan::Check { feed, kind, name, home, notify });
    if let Some(m) = RE_SUB.captures(&s) {
        let sub = &m[1];
        return check(format!("https://www.reddit.com/r/{sub}/top/.rss?t=day"), ItemKind::Post, Some(format!("r/{sub} (오늘 인기)")), None, false);
    }
    if RE_ARXIV.is_match(&s) {
        return check(format!("https://rss.arxiv.org/rss/{s}"), ItemKind::Paper, Some(format!("arXiv {s}")), None, false);
    }
    let low = s.to_lowercase();
    if low == "hn" || low == "hacker news" {
        return check("https://hnrss.org/frontpage".into(), ItemKind::Post, Some("Hacker News".into()), None, false);
    }
    if !s.contains("://") {
        s = format!("https://{s}");
    }
    let url = url::Url::parse(&s).map_err(|_| Failure::NotFound)?;
    let host = url.host_str().ok_or(Failure::NotFound)?.to_lowercase();
    if !url_safety::is_public_http(url.as_str()) {
        return Err(Failure::Unsafe);
    }
    let path = url.path().to_string();
    let full = url.to_string();
    // YouTube: 채널·핸들·재생목록
    if host.ends_with("youtube.com") || host == "youtu.be" {
        if let Some((_, list)) = url.query_pairs().find(|(k, _)| k == "list") {
            return check(format!("https://www.youtube.com/feeds/videos.xml?playlist_id={list}"), ItemKind::Video, None, Some(full), true);
        }
        if let Some(m) = RE_YT_CH.captures(&path) {
            return check(format!("https://www.youtube.com/feeds/videos.xml?channel_id={}", &m[1]), ItemKind::Video, None, Some(full), true);
        }
        return Ok(Plan::YouTubePage(full)); // @핸들·/c/·/user/: 페이지에서 채널 ID 를 찾는다
    }
    // GitHub 저장소 → 릴리스
    if host == "github.com" {
        let parts: Vec<&str> = path.split('/').filter(|p| !p.is_empty()).collect();
        if parts.len() >= 2 {
            return check(
                format!("https://github.com/{}/{}/releases.atom", parts[0], parts[1]),
                ItemKind::Release,
                Some(format!("{} 릴리스", parts[1])),
                Some(format!("https://github.com/{}/{}", parts[0], parts[1])),
                true,
            );
        }
    }
    if host.ends_with("reddit.com") {
        if let Some(m) = RE_R_PATH.captures(&path) {
            let sub = &m[1];
            return check(format!("https://www.reddit.com/r/{sub}/top/.rss?t=day"), ItemKind::Post, Some(format!("r/{sub} (오늘 인기)")), None, false);
        }
    }
    if host.ends_with("arxiv.org") {
        if let Some(m) = RE_ARXIV_LIST.captures(&path) {
            let cat = &m[1];
            return check(format!("https://rss.arxiv.org/rss/{cat}"), ItemKind::Paper, Some(format!("arXiv {cat}")), None, false);
        }
    }
    if host == "medium.com" {
        if let Some(user) = path.split('/').find(|p| !p.is_empty()) {
            if user.starts_with('@') {
                return check(format!("https://medium.com/feed/{user}"), ItemKind::Article, None, Some(full), true);
            }
        }
    }
    if host.ends_with(".substack.com") {
        return check(format!("https://{host}/feed"), ItemKind::Article, None, Some(full), true);
    }
    Ok(Plan::Generic(full))
}

pub async fn resolve(input: &str) -> Result<Found, Failure> {
    let p = plan(input)?;
    // 이름을 실제로 풀어 내부망이면 거절
    let probe = match &p {
        Plan::Check { feed, .. } => feed.clone(),
        Plan::YouTubePage(u) | Plan::Generic(u) => u.clone(),
    };
    if !url_safety::resolves_public(&probe).await {
        return Err(Failure::Unsafe);
    }
    match p {
        Plan::Check { feed, kind, name, home, notify } => check(&feed, kind, name, home, notify).await,
        Plan::YouTubePage(u) => {
            let html = FEEDS.fetch(&u, false).await.ok().flatten().map(|d| String::from_utf8_lossy(&d).to_string()).ok_or(Failure::NotFound)?;
            let id = first_match(&html, r#"<link rel="canonical" href="https://www\.youtube\.com/channel/(UC[\w-]{22})""#)
                .or_else(|| first_match(&html, r#""(?:channelId|externalId)":"(UC[\w-]{22})""#))
                .ok_or(Failure::NotFound)?;
            check(&format!("https://www.youtube.com/feeds/videos.xml?channel_id={id}"), ItemKind::Video, None, Some(u), true).await
        }
        Plan::Generic(u) => {
            // 주소 자체가 피드인지 → 페이지가 알려 주는 피드(<link rel="alternate">) → 흔한 위치
            if let Ok(f) = check(&u, ItemKind::Article, None, None, true).await {
                return Ok(f);
            }
            let base = url::Url::parse(&u).map_err(|_| Failure::NotFound)?;
            if let Ok(Some(data)) = FEEDS.fetch(&u, false).await {
                let html: String = String::from_utf8_lossy(&data[..data.len().min(200_000)]).to_string();
                for href in alternates(&html) {
                    if let Ok(abs) = base.join(&href) {
                        if let Ok(f) = check(abs.as_str(), ItemKind::Article, None, Some(u.clone()), true).await {
                            return Ok(f);
                        }
                    }
                }
            }
            // 뿌리 주소: IPv6·포트도 그대로(맥 A-01)
            let mut r = base.clone();
            r.set_path("");
            r.set_query(None);
            r.set_fragment(None);
            let root = r.as_str().trim_end_matches('/').to_string();
            for p in ["/feed", "/rss", "/feed.xml", "/atom.xml", "/index.xml", "/rss.xml", "/blog/feed", "/blog/rss.xml"] {
                if let Ok(f) = check(&format!("{root}{p}"), ItemKind::Article, None, Some(root.clone()), true).await {
                    return Ok(f);
                }
            }
            Err(Failure::NotFound)
        }
    }
}

// 실제로 받아서 글이 있는지 확인
async fn check(feed: &str, kind: ItemKind, name: Option<String>, home: Option<String>, notify: bool) -> Result<Found, Failure> {
    let data = FEEDS.fetch(feed, false).await.ok().flatten().ok_or(Failure::NotFound)?;
    let entries = feed_parser::parse_feed(&data).map_err(|_| Failure::NotFound)?;
    found_from(feed, &data, &entries, kind, name, home, notify)
}

pub fn found_from(
    feed: &str,
    data: &[u8],
    entries: &[feed_parser::Entry],
    kind: ItemKind,
    name: Option<String>,
    home: Option<String>,
    notify: bool,
) -> Result<Found, Failure> {
    // 논문 피드는 발표 사이에 잠시 비어 있을 수 있다 — 형식이 맞으면 받아들인다
    let title = feed_parser::feed_title(data);
    if entries.is_empty() && !(kind == ItemKind::Paper && title.is_some()) {
        return Err(Failure::NotFound);
    }
    let name = name.or(title).unwrap_or_else(|| url_safety::host_of(feed).unwrap_or_else(|| feed.to_string()));
    // 하루에 글이 많이 올라오는 채널은 알림 기본값을 끈다(15건 넘게)
    let now = Utc::now();
    let recent = entries.iter().filter_map(|e| e.date).filter(|d| (now - *d).num_seconds() < 24 * 3600).count();
    Ok(Found { feed_url: feed.into(), name, kind, home, notify_default: notify && recent <= 15 })
}

pub fn alternates(html: &str) -> Vec<String> {
    static LINK: Lazy<Regex> = Lazy::new(|| RegexBuilder::new(r#"<link[^>]+rel=["']alternate["'][^>]*>"#).case_insensitive(true).build().unwrap());
    static TYPE: Lazy<Regex> = Lazy::new(|| RegexBuilder::new(r#"type=["']application/(rss|atom)\+xml["']"#).case_insensitive(true).build().unwrap());
    LINK.find_iter(html)
        .filter(|m| TYPE.is_match(m.as_str()))
        .filter_map(|m| first_match(m.as_str(), r#"href=["']([^"']+)["']"#).map(|h| h.replace("&amp;", "&")))
        .collect()
}

fn first_match(s: &str, pattern: &str) -> Option<String> {
    Regex::new(pattern).ok()?.captures(s).and_then(|c| c.get(1)).map(|m| m.as_str().to_string())
}

// 직접 추가한 채널의 id(맥과 같은 djb2 해시 · 36진수)
pub fn custom_id(feed_url: &str) -> String {
    let mut h: i64 = 5381;
    for ch in feed_url.chars() {
        h = h.wrapping_mul(33).wrapping_add(ch as i64);
    }
    format!("custom-{}", radix36((h & 0x7fff_ffff) as u64))
}

fn radix36(mut n: u64) -> String {
    if n == 0 {
        return "0".into();
    }
    let digits = b"0123456789abcdefghijklmnopqrstuvwxyz";
    let mut out = vec![];
    while n > 0 {
        out.push(digits[(n % 36) as usize]);
        n /= 36;
    }
    out.reverse();
    String::from_utf8(out).unwrap()
}

pub const PALETTE: [&str; 7] = ["#6E56CF", "#0090FF", "#E5484D", "#30A46C", "#F76B15", "#D6409F", "#12A594"];

// OPML 가져오기·내보내기(맥 Channels.swift 의 OPML). 내보내기는 출처를 분야별 묶음으로, 가져오기는 피드 주소만 모은다.
pub mod opml {
    use crate::feed_parser::{self, XNode};
    use crate::models::Source;

    #[derive(Debug, Clone, PartialEq)]
    pub struct Entry {
        pub title: String,
        pub url: String,
        pub home: Option<String>,
    }

    pub fn escape(s: &str) -> String {
        s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;").replace('\'', "&apos;")
    }

    pub fn export(sources: &[Source], section_name: impl Fn(&str) -> String, date: chrono::DateTime<chrono::Utc>) -> String {
        let mut out = format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<opml version=\"2.0\">\n  <head>\n    <title>Dropcap 구독 목록</title>\n    <dateCreated>{}</dateCreated>\n  </head>\n  <body>\n",
            date.format("%a, %d %b %Y %H:%M:%S +0000")
        );
        let mut order: Vec<String> = vec![];
        for s in sources {
            if !order.iter().any(|o| o == s.section_id()) {
                order.push(s.section_id().to_string());
            }
        }
        for sec in order {
            let name = escape(&section_name(&sec));
            out += &format!("    <outline text=\"{name}\" title=\"{name}\">\n");
            for s in sources.iter().filter(|s| s.section_id() == sec) {
                let mut attrs = format!("type=\"rss\" text=\"{0}\" title=\"{0}\" xmlUrl=\"{1}\"", escape(&s.name), escape(&s.url));
                if let Some(h) = &s.home {
                    attrs += &format!(" htmlUrl=\"{}\"", escape(h));
                }
                out += &format!("      <outline {attrs}/>\n");
            }
            out += "    </outline>\n";
        }
        out += "  </body>\n</opml>\n";
        out
    }

    // 안쪽 묶음까지 훑어 xmlUrl 이 있는 것만, 같은 주소는 한 번만
    pub fn parse(data: &[u8]) -> Result<Vec<Entry>, crate::net::FeedError> {
        let root = feed_parser::tree(data)?;
        let body = root.child("opml").and_then(|o| o.child("body")).ok_or(crate::net::FeedError::BadFormat)?;
        let mut out = vec![];
        let mut seen = std::collections::HashSet::new();
        fn walk(n: &XNode, out: &mut Vec<Entry>, seen: &mut std::collections::HashSet<String>) {
            for c in n.all("outline") {
                if let Some(u) = c.attr("xmlUrl").or_else(|| c.attr("xmlurl")).map(|u| u.trim().to_string()) {
                    if !u.is_empty() && seen.insert(u.clone()) {
                        let t = c.attr("title").or_else(|| c.attr("text")).unwrap_or("").trim().to_string();
                        out.push(Entry { title: t, url: u, home: c.attr("htmlUrl").map(|s| s.to_string()) });
                    }
                }
                walk(c, out, seen);
            }
        }
        walk(body, &mut out, &mut seen);
        Ok(out)
    }
}
