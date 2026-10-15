// 피드에 없는 기사도 '나중에 읽기'로(맥 Core/SaveLink.swift): dropcap://save?url=… 주소(북마클릿·명령줄), 저장 목록 위 '주소로 추가…' 칸.
// 받은 주소는 공개 http(s) 주소인지 먼저 보고(url_safety), 기사 머리(og:title·og:image·og:site_name)로 소식을 만든다.
// 저장 목록에 넣는 것과 본문·번역 미리 받기는 AppModel::toggle_saved 가 한다(지금의 저장과 똑같이 — 인터넷 없이도 읽힘).
// 맥의 서비스 메뉴 'Dropcap 에 저장'은 리눅스 데스크톱에 공통 서비스 메뉴가 없어 옮기지 않는다.
use crate::feed_parser::plain;
use crate::feed_service::SHARED as FEEDS;
use crate::models::NewsItem;
use crate::url_safety;
use chrono::{DateTime, Utc};
use std::collections::VecDeque;
use std::sync::Mutex;
use std::time::{Duration, Instant};

pub const TIER: &str = "웹에서 저장"; // 출처 등급 이름표(tier_label 이 그대로 보여 줌)
pub const SOURCE_PREFIX: &str = "web:";
pub const MAX_LENGTH: usize = 2048;
const HEAD_BYTES: usize = 131_072; // 기사 머리는 앞 128KB 만
const MAX_TAG: usize = 2000; // 꼬리표 하나·<title> 글의 최대 길이

// 북마클릿: 지금 보고 있는 페이지를 Dropcap 에 저장(맥과 같은 글)
pub const BOOKMARKLET: &str =
    "javascript:(function(){location.href='dropcap://save?url='+encodeURIComponent(location.href)+'&title='+encodeURIComponent(document.title)})()";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Failure {
    NotUrl,
    Unsafe,
    TooMany,
}

impl Failure {
    pub fn message(self) -> &'static str {
        match self {
            Failure::NotUrl => "http(s) 기사 주소가 아닙니다",
            Failure::Unsafe => "내부망·특수 주소는 저장하지 않습니다",
            Failure::TooMany => "잠깐 사이에 너무 많이 들어와 멈췄어요",
        }
    }
}

// MARK: 주소 해석(순수 함수 — 시험 대상)

static PORT_ONLY: once_cell::sync::Lazy<regex::Regex> = once_cell::sync::Lazy::new(|| regex::Regex::new(r"^[^/]+:\d+(/|$)").unwrap());

// 사람이 넣은 글에서 저장할 주소 하나. 공개 http(s) 주소만, 조각(#…)과 앞뒤 꺾쇠·따옴표는 뗀다.
pub fn normalize(raw: &str) -> Option<String> {
    let s = raw.trim().trim_matches(|c: char| "<>\"'“”‘’".contains(c));
    if s.is_empty() || s.chars().count() > MAX_LENGTH || s.chars().any(char::is_whitespace) {
        return None;
    }
    let mut s = s.to_string();
    if !s.contains("://") {
        // 'example.com/a' 처럼 스킴 없이 넣은 주소
        if !s.contains('.') || s.starts_with('/') || (s.contains(':') && !PORT_ONLY.is_match(&s)) {
            return None;
        }
        s = format!("https://{s}");
    }
    let mut u = url::Url::parse(&s).ok()?;
    u.set_fragment(None);
    if !u.username().is_empty() || u.password().is_some() {
        return None; // 아이디·암호가 든 주소는 받지 않음
    }
    let out = u.to_string();
    (url_safety::is_public_http(&s) && url_safety::is_public_http(&out) && out.len() <= MAX_LENGTH + 16).then_some(out)
}

// 퍼센트 풀기('+' 는 그대로 — 맥 URLComponents.queryItems 와 같게)
pub fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            let hex = |c: u8| (c as char).to_digit(16);
            if let (Some(h), Some(l)) = (hex(b[i + 1]), hex(b[i + 2])) {
                out.push((h * 16 + l) as u8);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

// 주소 글에 넣을 값(영문·숫자·-._~ 만 그대로)
pub fn percent_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 3);
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b"-._~".contains(&b) {
            out.push(b as char);
        } else {
            out += &format!("%{b:02X}");
        }
    }
    out
}

// 물음표 뒤의 이름=값 목록
pub fn query_items(link: &str) -> Vec<(String, String)> {
    let Some((_, q)) = link.split_once('?') else { return vec![] };
    let q = q.split('#').next().unwrap_or("");
    q.split('&')
        .filter(|p| !p.is_empty())
        .map(|p| {
            let (k, v) = p.split_once('=').unwrap_or((p, ""));
            (percent_decode(k), percent_decode(v))
        })
        .collect()
}

// dropcap://save?url=<주소>[&title=<제목>] — 북마클릿·명령줄용
pub fn parse_scheme(link: &str) -> Option<(String, Option<String>)> {
    let (scheme, rest) = link.split_once(':')?;
    if !scheme.eq_ignore_ascii_case(crate::url_router::SCHEME) {
        return None;
    }
    let action = rest.split(['?', '#']).next().unwrap_or("").trim_matches('/').to_lowercase();
    if action != "save" {
        return None;
    }
    let q = query_items(link);
    let raw = q.iter().find(|(k, _)| k == "url").map(|(_, v)| v.as_str())?;
    let u = normalize(raw)?;
    let title = q.iter().find(|(k, _)| k == "title").and_then(|(_, v)| clean_title(v));
    Some((u, title))
}

pub fn clean_title(s: &str) -> Option<String> {
    let t = plain::clean(s);
    (!t.is_empty()).then(|| t.chars().take(300).collect())
}

// MARK: 기사 머리 읽기(정규식 되풀이 훑기 없이 한 번 훑음 — 큰 페이지에서 멈추지 않게, 맥 HTMLScan)

// <name ...> 꼬리표들의 속성 글(이름 뒤 ~ '>' 앞). 너무 긴 꼬리표는 건너뛴다.
fn tags<'a>(html: &'a str, name: &str) -> Vec<&'a str> {
    let lower = html.to_ascii_lowercase(); // 아스키만 바꿔 바이트 위치가 그대로
    let needle = format!("<{name}");
    let mut out = vec![];
    let mut from = 0;
    while let Some(p) = lower[from..].find(&needle) {
        let start = from + p + needle.len();
        from = start;
        let Some(c) = lower[start..].chars().next() else { break };
        if !(c.is_whitespace() || c == '>' || c == '/') {
            continue;
        }
        let window = &lower[start..lower.len().min(start + MAX_TAG)];
        let Some(gt) = window.find('>') else { continue };
        if let Some(t) = html.get(start..start + gt) {
            out.push(t);
        }
        from = start + gt;
    }
    out
}

// 꼬리표 속성 하나(따옴표가 닫히지 않으면 없음)
pub fn attr(tag: &str, name: &str) -> Option<String> {
    let b = tag.as_bytes();
    let mut i = 0;
    while i < b.len() {
        while i < b.len() && (b[i].is_ascii_whitespace() || b[i] == b'/') {
            i += 1;
        }
        let ns = i;
        while i < b.len() && !b[i].is_ascii_whitespace() && b[i] != b'=' && b[i] != b'/' {
            i += 1;
        }
        let key = &tag[ns..i];
        while i < b.len() && b[i].is_ascii_whitespace() {
            i += 1;
        }
        let mut value: Option<String> = None;
        if i < b.len() && b[i] == b'=' {
            i += 1;
            while i < b.len() && b[i].is_ascii_whitespace() {
                i += 1;
            }
            if i < b.len() && (b[i] == b'"' || b[i] == b'\'') {
                let q = b[i];
                let vs = i + 1;
                let end = b[vs..].iter().position(|c| *c == q)?; // 닫히지 않은 따옴표: 더 읽지 않음
                value = Some(tag[vs..vs + end].to_string());
                i = vs + end + 1;
            } else {
                let vs = i;
                while i < b.len() && !b[i].is_ascii_whitespace() {
                    i += 1;
                }
                value = Some(tag[vs..i].to_string());
            }
        }
        if key.eq_ignore_ascii_case(name) {
            return value;
        }
        if ns == i {
            i += 1; // 진행 보장
        }
    }
    None
}

// meta property/name 이 keys 중 하나인 content(keys 순서대로, accept 를 통과한 첫 값)
pub fn meta(html: &str, keys: &[&str], accept: impl Fn(&str) -> Option<String>) -> Option<String> {
    let mut found: Vec<(String, String)> = vec![];
    for t in tags(html, "meta") {
        let Some(key) = attr(t, "property").or_else(|| attr(t, "name")) else { continue };
        let Some(content) = attr(t, "content") else { continue };
        found.push((key.to_lowercase(), content));
    }
    for k in keys {
        for (key, v) in &found {
            if key == k {
                if let Some(a) = accept(v) {
                    return Some(a);
                }
            }
        }
    }
    None
}

// <title>…</title> 안 글(길어야 2000자)
pub fn title(html: &str) -> Option<String> {
    let lower = html.to_ascii_lowercase();
    let mut from = 0;
    while let Some(p) = lower[from..].find("<title") {
        let start = from + p + 6;
        from = start;
        let Some(c) = lower[start..].chars().next() else { return None };
        if !(c == '>' || c.is_whitespace()) {
            continue;
        }
        let gt = lower[start..lower.len().min(start + MAX_TAG)].find('>')?;
        let body_start = start + gt + 1;
        let body = &lower[body_start..lower.len().min(body_start + MAX_TAG)];
        let end = body.find("</title")?;
        let t = html.get(body_start..body_start + end)?;
        return (!t.contains('<')).then(|| t.to_string());
    }
    None
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Head {
    pub title: Option<String>,
    pub image: Option<String>,
    pub site: Option<String>,
    pub description: Option<String>,
}

pub fn parse_head(html: &str, base: &str) -> Head {
    let mut cut = html.len().min(HEAD_BYTES);
    while !html.is_char_boundary(cut) {
        cut -= 1;
    }
    let html = &html[..cut];
    let m = |keys: &[&str]| meta(html, keys, clean_title);
    let mut h = Head {
        title: m(&["og:title", "twitter:title"]),
        site: m(&["og:site_name", "application-name"]),
        description: m(&["og:description", "description", "twitter:description"]),
        image: None,
    };
    if h.title.is_none() {
        h.title = title(html).and_then(|t| clean_title(&t));
    }
    if let Some(raw) = m(&["og:image", "og:image:url", "twitter:image"]) {
        if let Some(u) = url::Url::parse(base).ok().and_then(|b| b.join(&raw).ok()) {
            let s = u.to_string();
            if url_safety::is_public_http(&s) {
                h.image = Some(s); // 내부망 사진 주소는 받지 않음
            }
        }
    }
    h
}

// 사이트 이름이 없으면 주소의 이름(www. 뗌)
pub fn site_name(head: &Head, link: &str) -> String {
    if let Some(s) = head.site.as_deref().filter(|s| !s.is_empty()) {
        return s.chars().take(60).collect();
    }
    let host = url_safety::host_of(link).unwrap_or_else(|| "웹".into());
    host.strip_prefix("www.").map(str::to_string).unwrap_or(host)
}

fn norm(s: &str) -> String {
    s.to_lowercase().chars().filter(|c| c.is_alphanumeric()).collect()
}

// 제목 끝의 ' - 사이트 이름' 떼기(맥 ArticleService.stripSiteName)
pub fn strip_site_name(title: &str, source: &str, feed_title: &str) -> String {
    for sep in [" - ", " | ", " – ", " — ", " :: ", " · "] {
        let Some(p) = title.rfind(sep) else { continue };
        let head = title[..p].trim();
        let tail = title[p + sep.len()..].trim();
        if head.is_empty() {
            continue;
        }
        let (nt, ns) = (norm(tail), norm(source));
        if nt == ns || norm(head) == norm(feed_title) || (!ns.is_empty() && nt.contains(&ns)) {
            return head.to_string();
        }
    }
    title.to_string()
}

// 'Initial - Wikipedia' 처럼 끝에 붙은 사이트 이름(주소의 이름과 같은 것)을 뗀다
pub fn strip_host_suffix(title: &str, host: &str) -> String {
    let h = host.to_lowercase().replace('-', "");
    for sep in [" - ", " | ", " – ", " — ", " :: "] {
        let Some(p) = title.rfind(sep) else { continue };
        let tail = norm(&title[p + sep.len()..]);
        let head = title[..p].trim();
        if tail.chars().count() >= 3 && h.contains(&tail) && head.chars().count() >= 3 {
            return head.to_string();
        }
    }
    title.to_string()
}

pub fn make_item(link: &str, head: &Head, fallback_title: Option<&str>, now: DateTime<Utc>) -> NewsItem {
    let site = site_name(head, link);
    let host = url_safety::host_of(link).unwrap_or_default();
    let path = url::Url::parse(link).map(|u| u.path().to_string()).unwrap_or_default();
    let mut title = head
        .title
        .clone()
        .or_else(|| fallback_title.map(str::to_string))
        .unwrap_or_else(|| plain::title_from_slug(if path.is_empty() || path == "/" { if host.is_empty() { link } else { &host } } else { &path }));
    title = strip_site_name(&title, &site, &title.clone());
    title = strip_host_suffix(&title, &host);
    let src = format!("{SOURCE_PREFIX}{}", if host.is_empty() { "web" } else { &host });
    let mut it = NewsItem::new(link, &title, link, &src, &site, TIER);
    it.date = Some(now);
    it.summary = head.description.clone().unwrap_or_default().chars().take(300).collect();
    it.image = head.image.clone();
    it
}

// MARK: 바깥에서 몰려오는 것 막기(웹 페이지가 dropcap:// 를 마구 부르는 경우 대비) — 1분에 10번까지
pub struct RateLimit {
    times: Mutex<VecDeque<Instant>>,
    window: Duration,
    limit: usize,
}

impl RateLimit {
    pub const fn new(window: Duration, limit: usize) -> RateLimit {
        RateLimit { times: Mutex::new(VecDeque::new()), window, limit }
    }
    pub fn allow_at(&self, now: Instant) -> bool {
        let mut t = self.times.lock().unwrap();
        while t.front().map(|f| now.duration_since(*f) >= self.window).unwrap_or(false) {
            t.pop_front();
        }
        t.push_back(now);
        t.len() <= self.limit
    }
    pub fn allow(&self) -> bool {
        self.allow_at(Instant::now())
    }
}

pub static OUTSIDE: RateLimit = RateLimit::new(Duration::from_secs(60), 10);

// MARK: 받기 → 소식 만들기(저장 목록에 넣는 건 부르는 쪽: 이미 저장했는지는 already 로)
pub async fn fetch_item(link: &str, title: Option<String>, from_outside: bool, already: Vec<NewsItem>) -> Result<(NewsItem, bool), Failure> {
    let Some(link) = normalize(link) else { return Err(Failure::NotUrl) };
    if from_outside && !OUTSIDE.allow() {
        return Err(Failure::TooMany);
    }
    if !url_safety::resolves_public(&link).await {
        return Err(Failure::Unsafe);
    }
    if let Some(had) = already.into_iter().find(|s| s.link == link) {
        return Ok((had, false)); // 이미 저장함
    }
    let mut head = Head::default();
    if let Ok(Some(data)) = FEEDS.fetch_page(&link).await {
        let n = data.len().min(HEAD_BYTES);
        head = parse_head(&String::from_utf8_lossy(&data[..n]), &link);
    }
    Ok((make_item(&link, &head, title.as_deref(), Utc::now()), true))
}
