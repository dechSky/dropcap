// 기사 하나를 "읽을 수 있는 상태"로 준비한다: 본문 추리기 → 번역 → 3줄 요약(맥 Reader/ArticleService.swift).
// 알림이 뜨는 순간 미리 준비해 두고(미리 받기), 한 번 준비한 기사는 디스크에 남겨 다시 열면 바로 뜬다.
//
// 본문 추리기(Extract):
// - 빠른 길(R-01): HTML 만 받아(문자 인코딩 감지) 스크립트 없이 Readability 로. 화면 쪽(webkit 기능)이 있으면
//   WebKitGTK 에 스크립트를 끄고 맥과 같은 Readability.js 를 따로 떨어진 공간에서 돌리고, 없으면 같은 알고리즘의
//   Rust 판(dom_smoothie)으로 추린다. 어느 쪽이든 사이트 스크립트는 돌지 않는다(S-06).
// - 느린 길(R-02): 사용자가 열 때만, 화면 쪽이 실제 웹 보기로 띄워 추린다.
use crate::feed_service::SHARED as FEEDS;
use crate::models::NewsItem;
use crate::store::write_atomic;
use crate::summarizer;
use crate::translator::{looks_foreign, SHARED as TR};
use crate::url_safety;
use futures::future::{BoxFuture, FutureExt, Shared};
use once_cell::sync::Lazy;
use regex::Regex;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum BlockKind {
    H,
    P,
    Li,
    Quote,
    Pre,
    Img,
    Cap,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Block {
    #[serde(rename = "type")]
    pub kind: BlockKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub src: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub original: Option<String>,
}

impl Block {
    fn text(kind: BlockKind, t: String) -> Block {
        Block { kind, text: Some(t), src: None, original: None }
    }
    fn img(src: String) -> Block {
        Block { kind: BlockKind::Img, text: None, src: Some(src), original: None }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Article {
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub byline: Option<String>,
    #[serde(rename = "siteName", default)]
    pub site_name: Option<String>,
    pub blocks: Vec<Block>,
}

impl Article {
    // 본문으로 받아들일 만한가(맥 tryExtract 와 같은 기준). 짧은 글(소개글·단신)도 받는다: 글 100자 이상이면 본문으로
    // (예전 '2문단·280자' 기준은 GeekNews 같은 짧은 글을 버렸다)
    pub fn acceptable(&self) -> bool {
        let texts: Vec<&String> = self.blocks.iter().filter_map(|b| b.text.as_ref()).collect();
        !texts.is_empty() && texts.iter().map(|t| t.chars().count()).sum::<usize>() >= MIN_CHARS
    }
}

pub const MIN_CHARS: usize = 100;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stage {
    Extracting = 0,
    Original = 1,
    Translating = 2,
    Done = 3,
    Failed = 4,
}

impl Serialize for Stage {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_i64(*self as i64)
    }
}
impl<'de> Deserialize<'de> for Stage {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        Ok(match i64::deserialize(d)? {
            0 => Stage::Extracting,
            1 => Stage::Original,
            2 => Stage::Translating,
            3 => Stage::Done,
            _ => Stage::Failed,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PreparedArticle {
    pub stage: Stage,
    pub title: String,
    #[serde(rename = "originalTitle")]
    pub original_title: String,
    #[serde(default)]
    pub blocks: Vec<Block>, // 번역됐으면 text=번역, original=원문
    #[serde(default)]
    pub translated: bool,
    #[serde(default)]
    pub engine: String,
    #[serde(default)]
    pub summary: Option<Vec<String>>,
    #[serde(default)]
    pub summarizing: bool,
    #[serde(default)]
    pub fallback: String, // 본문을 못 추렸을 때 보여 줄 요약 번역
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub paywalled: Option<bool>, // 맛보기만 나오고 구독을 권함(유료벽 뒤, G-14)
}

impl PreparedArticle {
    pub fn new(title: &str, original: &str) -> PreparedArticle {
        PreparedArticle {
            stage: Stage::Extracting,
            title: title.into(),
            original_title: original.into(),
            blocks: vec![],
            translated: false,
            engine: String::new(),
            summary: None,
            summarizing: false,
            fallback: String::new(),
            paywalled: None,
        }
    }
}

// 화면 쪽이 웹 엔진으로 추릴 수 있으면 이것을 넣어 준다
pub trait Extract: Send + Sync {
    // 받은 HTML(이미 UTF-8 로 풀린 것)을 스크립트 없이 추리기. None 이면 Rust 판으로.
    fn fast(&self, _html: String, _base: String) -> BoxFuture<'static, Option<Article>> {
        async { None }.boxed()
    }
    // 실제로 띄워서 추리기(사용자가 연 기사만)
    fn slow(&self, _url: String) -> BoxFuture<'static, Option<Article>> {
        async { None }.boxed()
    }
    // 기다리는 시간을 정해 띄우기(접근을 거부하는 사이트는 짧게)
    fn slow_for(&self, url: String, _max_secs: u64) -> BoxFuture<'static, Option<Article>> {
        self.slow(url)
    }
}

pub struct NoEngine;
impl Extract for NoEngine {}

// <meta charset="euc-kr"> 처럼 문서 안에 적힌 인코딩을 찾는다
pub fn sniff_charset(data: &[u8]) -> String {
    static RE: Lazy<Regex> = Lazy::new(|| Regex::new(r#"charset=["']?([a-z0-9_\-]+)"#).unwrap());
    let head = String::from_utf8_lossy(&data[..data.len().min(4096)]).to_lowercase();
    RE.captures(&head).map(|c| c[1].to_string()).unwrap_or_else(|| "utf-8".into())
}

pub fn decode_html(data: &[u8], charset: Option<&str>) -> String {
    let label = charset.map(|s| s.to_string()).unwrap_or_else(|| sniff_charset(data));
    let enc = encoding_rs::Encoding::for_label(label.as_bytes()).unwrap_or(encoding_rs::UTF_8);
    enc.decode(data).0.into_owned()
}

static NEW_WINDOW: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)\((opens in a new (window|tab)|새 창에서 열기)\)").unwrap());
static WS: Lazy<Regex> = Lazy::new(|| Regex::new(r"\s+").unwrap());

// 화면 낭독기 전용 글자·"(새 창에서 열기)" 제거, 공백 정리(맥 추출 스크립트의 clean)
pub fn clean_text(s: &str) -> String {
    WS.replace_all(&NEW_WINDOW.replace_all(s, ""), " ").trim().to_string()
}

pub const SR_ONLY: &str = r#".sr-only, .visually-hidden, .screen-reader-text, [class*="sr-only"], [class*="visually-hidden"]"#;

// Readability 의 결과 HTML 을 블록(제목·문단·목록·인용·코드·그림·캡션)으로(맥 스크립트의 walk 와 같은 규칙)
pub fn blocks_from_html(content: &str, base: &str) -> Vec<Block> {
    let doc = dom_query::Document::from(content);
    let base_url = url::Url::parse(base).ok();
    // http(s) 로 끝나는 절대 주소만
    let abs = |u: Option<String>| -> Option<String> {
        let u = u?;
        let h = match &base_url {
            Some(b) => b.join(&u).ok()?,
            None => url::Url::parse(&u).ok()?,
        };
        matches!(h.scheme(), "http" | "https").then(|| h.to_string())
    };
    let mut out = vec![];
    let body = doc.select("body");
    if let Some(root) = body.nodes().first() {
        walk(root, &abs, &mut out);
    }
    out
}

static PLACEHOLDER: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)(1x1|spacer|blank|pixel)\.(gif|png)").unwrap());

// 늦게 불러오는 사진은 src 가 빈 자리표시이고 진짜 주소는 srcset·data-* 에 있다 — 가장 큰 진짜 주소를 고른다(맥 bestSrc)
pub fn best_src(img: &dom_query::NodeRef, abs: &dyn Fn(Option<String>) -> Option<String>) -> Option<String> {
    let mut cands: Vec<(String, f64)> = vec![];
    let mut from_set = |v: Option<String>| {
        for part in v.unwrap_or_default().split(',') {
            let mut it = part.split_whitespace();
            let Some(u) = it.next() else { continue };
            let d = it.next().unwrap_or("");
            let num: f64 = d.trim_end_matches(['w', 'x']).parse().unwrap_or(0.0);
            let score = if d.ends_with('x') { num * 1000.0 } else if num > 0.0 { num } else { 1.0 };
            cands.push((u.to_string(), score));
        }
    };
    from_set(img.attr("srcset").map(|s| s.to_string()));
    from_set(img.attr("data-srcset").map(|s| s.to_string()));
    // <picture> 안이면 <source> 들도
    let mut p = img.parent();
    while let Some(n) = p {
        if n.node_name().map(|t| t.eq_ignore_ascii_case("picture")).unwrap_or(false) {
            for s in dom_query::Selection::from(n.clone()).select("source").nodes() {
                from_set(s.attr("srcset").or_else(|| s.attr("data-srcset")).map(|x| x.to_string()));
            }
            break;
        }
        p = n.parent();
    }
    cands.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    for (u, _) in cands {
        if let Some(h) = abs(Some(u)) {
            return Some(h);
        }
    }
    for a in ["data-src", "data-lazy-src", "data-original", "data-url", "src"] {
        if let Some(v) = img.attr(a) {
            if !v.starts_with("data:") {
                if let Some(h) = abs(Some(v.to_string())) {
                    if !PLACEHOLDER.is_match(&h) {
                        return Some(h);
                    }
                }
            }
        }
    }
    None
}

fn walk(el: &dom_query::NodeRef, abs: &dyn Fn(Option<String>) -> Option<String>, out: &mut Vec<Block>) {
    for n in el.element_children() {
        let tag = n.node_name().map(|t| t.to_lowercase()).unwrap_or_default();
        let t = clean_text(&n.text());
        let sel = dom_query::Selection::from(n.clone());
        let first_img_src = || sel.select("img").nodes().first().and_then(|i| best_src(i, abs));
        match tag.as_str() {
            "h1" | "h2" | "h3" | "h4" | "h5" | "h6" => {
                if !t.is_empty() {
                    out.push(Block::text(BlockKind::H, t))
                }
            }
            "p" => {
                if !t.is_empty() {
                    out.push(Block::text(BlockKind::P, t))
                }
                if let Some(s) = first_img_src() {
                    out.push(Block::img(s))
                }
            }
            "li" => {
                if !t.is_empty() {
                    out.push(Block::text(BlockKind::Li, t))
                }
            }
            "blockquote" => {
                if !t.is_empty() {
                    out.push(Block::text(BlockKind::Quote, t))
                }
            }
            "pre" => {
                if !t.is_empty() {
                    out.push(Block::text(BlockKind::Pre, n.text().to_string()))
                }
            }
            "img" => {
                if let Some(s) = best_src(&n, abs) {
                    out.push(Block::img(s))
                }
            }
            "picture" => {
                if let Some(s) = first_img_src() {
                    out.push(Block::img(s))
                }
            }
            "figure" => {
                if let Some(s) = first_img_src() {
                    out.push(Block::img(s))
                }
                if let Some(cap) = sel.select("figcaption").nodes().first() {
                    let c = clean_text(&cap.text());
                    if !c.is_empty() {
                        out.push(Block::text(BlockKind::Cap, c))
                    }
                }
            }
            _ => walk(&n, abs, out),
        }
    }
}

// 빠른 길의 Rust 판: 스크립트 없이 HTML 만으로.
// 기본 기준(500자)으로 못 찾으면 짧은 글(GeekNews 소개글 등)을 위해 100자 기준으로 한 번 더, 그래도 못 찾으면
// 본문으로 보이는 영역(id·class 에 content·article·topic·post·entry 가 든 것) 가운데 글이 가장 많은 곳(맥 스크립트와 같은 순서)
pub fn extract_html(html: &str, base: &str) -> Option<Article> {
    let readable = |threshold: Option<usize>| -> Option<Article> {
        let doc = dom_query::Document::from(html);
        doc.select(SR_ONLY).remove();
        let cfg = threshold.map(|t| dom_smoothie::Config { char_threshold: t, ..Default::default() });
        let mut r = dom_smoothie::Readability::with_document(doc, Some(base), cfg).ok()?;
        let a = r.parse().ok()?;
        let art = Article {
            title: Some(a.title.clone()).filter(|t| !t.is_empty()),
            byline: a.byline.clone(),
            site_name: a.site_name.clone(),
            blocks: with_plain_lines(blocks_from_html(&a.content, base), &a.content),
        };
        art.acceptable().then_some(art)
    };
    readable(None).or_else(|| readable(Some(MIN_CHARS))).or_else(|| content_region(html, base))
}

const REGION: &str = r#"article, main, [id*="content" i], [class*="content" i], [id*="topic" i], [class*="article" i], [class*="post" i], [class*="entry" i], [itemprop="articleBody"]"#;
const REGION_JUNK: &str = r#"script, style, nav, form, button, .related-topics, [class*="related" i], [class*="share" i]"#;

// 본문으로 보이는 영역 가운데 글이 가장 많은 곳(80자 이상 · 40000자 미만, 머리·꼬리·옆 메뉴 안은 뺌)
pub fn content_region(html: &str, base: &str) -> Option<Article> {
    let doc = dom_query::Document::from(html);
    doc.select(SR_ONLY).remove();
    let mut best: Option<(String, usize)> = None;
    for n in doc.select(REGION).nodes() {
        let mut p = n.parent();
        let mut inside = false;
        while let Some(a) = p {
            if matches!(a.node_name().map(|t| t.to_lowercase()).as_deref(), Some("nav" | "header" | "footer" | "aside")) {
                inside = true;
                break;
            }
            p = a.parent();
        }
        if inside {
            continue;
        }
        let len = clean_text(&n.text()).chars().count();
        if len > best.as_ref().map(|b| b.1).unwrap_or(0) && len < 40000 {
            best = Some((n.html().to_string(), len));
        }
    }
    let (inner, len) = best?;
    if len < 80 {
        return None;
    }
    let region = dom_query::Document::from(inner.as_str());
    region.select(REGION_JUNK).remove();
    let content = region.select("body").html().to_string();
    let title = doc.select("title").text().trim().to_string();
    let art = Article {
        title: Some(title).filter(|t| !t.is_empty()),
        byline: None,
        site_name: None,
        blocks: with_plain_lines(blocks_from_html(&content, base), &content),
    };
    art.acceptable().then_some(art)
}

// 문단 태그 없이 맨 글자로 든 본문(GeekNews 등): 줄 단위로 문단을 만든다
pub fn with_plain_lines(mut blocks: Vec<Block>, content: &str) -> Vec<Block> {
    if blocks.iter().any(|b| matches!(b.kind, BlockKind::P | BlockKind::Li)) {
        return blocks;
    }
    let doc = dom_query::Document::from(content);
    for br in doc.select("br").nodes() {
        br.replace_with_html("\n");
    }
    for blk in doc.select("div, p, li, h1, h2, h3, h4, h5, h6, section").nodes() {
        blk.append_html("\n");
    }
    let text = doc.select("body").text().to_string();
    for line in text.split('\n').map(clean_text).filter(|t| t.chars().count() > 1) {
        blocks.push(Block::text(BlockKind::P, line));
    }
    blocks
}

// 스크립트·스타일을 뺀 보이는 글자 수(대략) — 글이 이미 많은 페이지는 느린 길을 돌려도 같으므로 건너뛴다
pub fn visible_text_length(html: &str) -> usize {
    static TAGS: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?is)<(script|style|noscript|svg)\b[^>]*>.*?</(script|style|noscript|svg)>").unwrap());
    static ANY: Lazy<Regex> = Lazy::new(|| Regex::new(r"<[^>]+>").unwrap());
    let head: String = html.chars().take(800_000).collect();
    let t = TAGS.replace_all(&head, " ");
    let t = ANY.replace_all(&t, " ");
    WS.replace_all(&t, " ").chars().count()
}

// 접근을 거부한(401·403·429) 뒤 느린 길도 실패한 곳: 이번 실행 동안은 바로 대체 화면
static BLOCKED_HOSTS: Lazy<Mutex<std::collections::HashSet<String>>> = Lazy::new(|| Mutex::new(Default::default()));

pub fn host_of(link: &str) -> String {
    url::Url::parse(link).ok().and_then(|u| u.host_str().map(|h| h.to_lowercase())).unwrap_or_default()
}

pub fn is_blocked_host(link: &str) -> bool {
    BLOCKED_HOSTS.lock().unwrap().contains(&host_of(link))
}

pub fn file_name(link: &str) -> String {
    let h = Sha256::digest(link.as_bytes());
    let hex: String = h.iter().map(|b| format!("{b:02x}")).collect();
    format!("{}.json", &hex[..24])
}

type Listener = Box<dyn Fn(&PreparedArticle) + Send + Sync>;

pub struct ArticleService {
    dir: PathBuf,
    extractor: Mutex<Arc<dyn Extract>>,
    memory: Mutex<(HashMap<String, PreparedArticle>, VecDeque<String>)>,
    inflight: Mutex<HashMap<String, Shared<BoxFuture<'static, PreparedArticle>>>>,
    listeners: Mutex<HashMap<String, HashMap<u64, Listener>>>,
    next_id: Mutex<u64>,
    pinned: Mutex<Arc<dyn Fn() -> Vec<String> + Send + Sync>>, // 저장한 기사 링크(디스크 정리에서 제외)
    recorder: Mutex<Arc<Recorder>>, // 사용자가 연 기사의 추리기 결과(유료 기사 배우기, G-14)
}

type Recorder = dyn Fn(&NewsItem, bool, bool) + Send + Sync; // (기사, 실패, 막힘)

pub const MEMORY_LIMIT: usize = 40;
pub const DISK_LIMIT: usize = 150;

impl ArticleService {
    pub fn new(dir: PathBuf) -> Arc<ArticleService> {
        let d = dir.join("articles");
        let _ = std::fs::create_dir_all(&d);
        Arc::new(ArticleService {
            dir: d,
            extractor: Mutex::new(Arc::new(NoEngine)),
            memory: Mutex::new((HashMap::new(), VecDeque::new())),
            inflight: Mutex::new(HashMap::new()),
            listeners: Mutex::new(HashMap::new()),
            next_id: Mutex::new(0),
            pinned: Mutex::new(Arc::new(Vec::new)),
            recorder: Mutex::new(Arc::new(|_, _, _| {})),
        })
    }

    pub fn set_extractor(&self, e: Arc<dyn Extract>) {
        *self.extractor.lock().unwrap() = e;
    }
    pub fn set_pinned(&self, f: Arc<dyn Fn() -> Vec<String> + Send + Sync>) {
        *self.pinned.lock().unwrap() = f;
    }
    pub fn set_recorder(&self, f: Arc<Recorder>) {
        *self.recorder.lock().unwrap() = f;
    }
    fn record(&self, item: &NewsItem, failed: bool, blocked: bool) {
        let f = self.recorder.lock().unwrap().clone();
        f(item, failed, blocked);
    }

    // 진행 상황을 받아 보기(읽기 창). 돌려받은 id 로 그만 받기.
    pub fn observe(&self, link: &str, cb: Listener) -> u64 {
        let mut n = self.next_id.lock().unwrap();
        *n += 1;
        self.listeners.lock().unwrap().entry(link.to_string()).or_default().insert(*n, cb);
        *n
    }
    pub fn stop_observing(&self, link: &str, id: u64) {
        if let Some(m) = self.listeners.lock().unwrap().get_mut(link) {
            m.remove(&id);
        }
    }

    fn path(&self, link: &str) -> PathBuf {
        self.dir.join(file_name(link))
    }

    pub fn cached(&self, link: &str) -> Option<PreparedArticle> {
        if let Some(m) = self.memory.lock().unwrap().0.get(link) {
            if m.stage == Stage::Done {
                return Some(m.clone()); // 실패한 기사는 다음에 다시 시도
            }
        }
        let p = self.path(link);
        let a: PreparedArticle = serde_json::from_slice(&std::fs::read(&p).ok()?).ok()?;
        if a.stage != Stage::Done {
            return None;
        }
        self.remember(link, &a);
        // 최근에 쓴 것을 오래 남김
        if let Ok(f) = std::fs::File::options().append(true).open(&p) {
            let _ = f.set_modified(std::time::SystemTime::now());
        }
        Some(a)
    }

    fn remember(&self, link: &str, a: &PreparedArticle) {
        let mut m = self.memory.lock().unwrap();
        if !m.0.contains_key(link) {
            m.1.push_back(link.to_string());
            if m.1.len() > MEMORY_LIMIT {
                if let Some(old) = m.1.pop_front() {
                    m.0.remove(&old); // 메모리에는 최근 40개만
                }
            }
        }
        m.0.insert(link.to_string(), a.clone());
    }

    fn forget(&self, link: &str) {
        let mut m = self.memory.lock().unwrap();
        m.0.remove(link);
        m.1.retain(|l| l != link);
    }

    pub fn memory_len(&self) -> usize {
        self.memory.lock().unwrap().0.len()
    }

    fn emit(&self, link: &str, a: &PreparedArticle) {
        self.remember(link, a);
        if let Some(ls) = self.listeners.lock().unwrap().get(link) {
            for cb in ls.values() {
                cb(a);
            }
        }
    }

    // 이미 준비 중이면 같은 작업을 기다린다.
    // interactive: 사용자가 연 기사(스크립트가 필요한 사이트도 띄움). 미리 받기는 false — 스크립트 없이 빠른 길만.
    pub fn prepare(self: &Arc<Self>, item: NewsItem, interactive: bool) -> BoxFuture<'static, PreparedArticle> {
        let me = self.clone();
        async move {
            // 요약을 만드는 중이면 요약까지 기다림
            let pending = me.inflight.lock().unwrap().get(&item.link).cloned();
            if let (Some(t), Some(c)) = (pending, me.cached(&item.link)) {
                if c.summarizing {
                    return t.await;
                }
            }
            if let Some(c) = me.cached(&item.link) {
                return c;
            }
            let existing = me.inflight.lock().unwrap().get(&item.link).cloned();
            if let Some(t) = existing {
                let r = t.await;
                // 미리 받기가 스크립트 없이 실패했으면, 사용자가 열었을 때는 제대로 다시 시도
                if r.stage == Stage::Failed && interactive {
                    me.inflight.lock().unwrap().remove(&item.link);
                    return me.prepare(item, true).await;
                }
                return r;
            }
            let me2 = me.clone();
            let it2 = item.clone();
            let fut: Shared<BoxFuture<'static, PreparedArticle>> = async move { me2.run(it2, interactive).await }.boxed().shared();
            me.inflight.lock().unwrap().insert(item.link.clone(), fut.clone());
            let r = fut.clone().await;
            // 그 사이 실패한 미리 받기를 치우고 다시 시작한 작업이 있으면 그것은 지우지 않는다
            let mut inf = me.inflight.lock().unwrap();
            if inf.get(&item.link).map(|f| f.ptr_eq(&fut)).unwrap_or(false) {
                inf.remove(&item.link);
            }
            drop(inf);
            r
        }
        .boxed()
    }

    async fn extract(&self, link: &str, interactive: bool) -> Option<Article> {
        if !url_safety::resolves_public(link).await {
            return None;
        }
        let ex = self.extractor.lock().unwrap().clone();
        let t0 = std::time::Instant::now();
        let host = host_of(link);
        let mut refused = false; // 사이트가 접근을 거부(401·403·429)
        let mut rich_page = false; // 받은 HTML 에 글이 이미 많다(스크립트로 그리는 빈 껍데기가 아님)
        // 2MB 를 넘는 페이지는 빠른 길을 건너 느린 길(웹 보기)로(S-12)
        let got = FEEDS.fetch_with_encoding(link, false, crate::feed_service::FetchLimit::Page).await;
        if let Err(crate::net::FeedError::Http(code)) = &got {
            refused = matches!(code, 401 | 403 | 429);
        }
        if let Ok(Some(body)) = got {
            let html = decode_html(&body.data, body.encoding.as_deref());
            rich_page = visible_text_length(&html) > 600;
            let art = match ex.fast(html.clone(), link.to_string()).await {
                Some(a) if a.acceptable() => Some(a),
                _ => {
                    let l = link.to_string();
                    tokio::task::spawn_blocking(move || extract_html(&html, &l)).await.ok().flatten()
                }
            };
            if let Some(a) = art {
                log::info!("[기사] 빠른 길 {:.2}초", t0.elapsed().as_secs_f64());
                return Some(a);
            }
        }
        if !interactive {
            return None;
        }
        // 접근을 거부하는 사이트(예: GeekNews 403)는 느린 길도 대개 막힌다: 짧게만 시도하고, 그래도 막히면 이번 실행 동안은 바로 대체 화면
        if BLOCKED_HOSTS.lock().unwrap().contains(&host) {
            log::info!("[기사] {host} 은 막힌 사이트라 건너뜀");
            return None;
        }
        // 글이 다 들어 있는데도 못 추린 페이지는 스크립트를 돌려도 같으므로 느린 길(최대 15초)을 건너뛴다
        if rich_page {
            log::info!("[기사] 빠른 길 실패, 글이 있는 페이지라 느린 길 건너뜀 {host}");
            return None;
        }
        let art = ex.slow_for(link.to_string(), if refused { 6 } else { 15 }).await.filter(|a| a.acceptable());
        if art.is_none() && refused {
            BLOCKED_HOSTS.lock().unwrap().insert(host);
        }
        log::info!("[기사] 느린 길 {:.2}초 {}", t0.elapsed().as_secs_f64(), if art.is_none() { "실패" } else { "성공" });
        art
    }

    async fn run(self: Arc<Self>, item: NewsItem, interactive: bool) -> PreparedArticle {
        let mut a = PreparedArticle::new(item.display_title(), &item.title);
        self.emit(&item.link, &a);
        let Some(art) = self.extract(&item.link, interactive).await else {
            if !interactive {
                // 미리 받기 실패는 조용히 넘기고, 열 때 다시 시도
                self.forget(&item.link);
                let mut f = PreparedArticle::new(item.display_title(), &item.title);
                f.stage = Stage::Failed;
                return f;
            }
            self.record(&item, true, false);
            a.fallback = TR.translate(&item.summary).await;
            a.stage = Stage::Failed;
            self.emit(&item.link, &a);
            return a;
        };
        let art_title = art.title.clone().filter(|t| !t.is_empty()).unwrap_or_else(|| item.title.clone());
        a.original_title = art_title.clone();
        a.blocks = art.blocks.clone();
        if crate::paywall::looks_blocked(&art.blocks) {
            a.paywalled = Some(true);
        }
        if interactive {
            self.record(&item, false, a.paywalled == Some(true));
        }
        log::info!("[기사] 그림 {}개", art.blocks.iter().filter(|b| b.kind == BlockKind::Img).count());
        let texts: Vec<String> = art.blocks.iter().filter_map(|b| b.text.clone()).collect();
        let sample: String = texts.join(" ").chars().take(2000).collect();
        if looks_foreign(&sample) {
            // 원문을 먼저 보여 주고, 위에서부터 번역으로 바꿔 끼운다(첫 8문단+제목 → 나머지)
            a.title = item.title_ko.clone().unwrap_or_else(|| art_title.clone());
            a.stage = Stage::Translating;
            self.emit(&item.link, &a);
            let idx: Vec<usize> =
                (0..art.blocks.len()).filter(|&i| art.blocks[i].text.is_some() && art.blocks[i].kind != BlockKind::Pre).collect();
            let chunks = [idx.iter().take(8).cloned().collect::<Vec<_>>(), idx.iter().skip(8).cloned().collect::<Vec<_>>()];
            // 실제로 바뀐(번역된) 문단 수 — 번역이 모두 실패하면 원문이 그대로 돌아온다(맥 efdeb13)
            let (mut done, mut total, mut engine) = (0usize, 0usize, String::new());
            for (n, chunk) in chunks.iter().enumerate() {
                if chunk.is_empty() && n != 0 {
                    continue;
                }
                let mut inputs: Vec<String> = if n == 0 { vec![art_title.clone()] } else { vec![] };
                inputs.extend(chunk.iter().map(|&i| art.blocks[i].text.clone().unwrap()));
                let (mut out, used) = TR.translate_many_reporting(&inputs).await;
                if used != crate::translator::Engine::None {
                    engine = used.label().to_string(); // 이 기사에 실제로 쓴 엔진(T-08)
                }
                if n == 0 {
                    a.title = out.remove(0);
                }
                let (d, t) = merge_translated(&mut a.blocks, &art.blocks, chunk, &out);
                done += d;
                total += t;
                a.translated = done > 0;
                self.emit(&item.link, &a);
            }
            a.engine = engine_label(done, total, &engine);
        } else {
            a.title = art_title.clone();
        }
        a.stage = Stage::Done;
        a.summarizing = summarizer::available().await;
        self.emit(&item.link, &a);
        if a.summarizing {
            a.summary = summarizer::summarize(&art_title, &texts).await;
            a.summarizing = false;
            self.emit(&item.link, &a);
        }
        self.save(&item.link, &a);
        a
    }

    fn save(&self, link: &str, a: &PreparedArticle) {
        let Ok(data) = serde_json::to_vec(a) else { return };
        let _ = write_atomic(&self.path(link), &data);
        self.prune();
    }

    // 오래된 것부터 지워 개수를 지킨다. 저장한 기사는 오프라인으로 읽을 수 있게 지우지 않는다.
    pub fn prune(&self) {
        let Ok(rd) = std::fs::read_dir(&self.dir) else { return };
        let mut files: Vec<(PathBuf, std::time::SystemTime)> = rd
            .flatten()
            .filter(|e| e.path().extension().map(|x| x == "json").unwrap_or(false))
            .map(|e| (e.path(), e.metadata().and_then(|m| m.modified()).unwrap_or(std::time::UNIX_EPOCH)))
            .collect();
        if files.len() <= DISK_LIMIT {
            return;
        }
        let total = files.len();
        files.sort_by_key(|f| f.1);
        let pinned: Vec<String> = (self.pinned.lock().unwrap())().iter().map(|l| file_name(l)).collect();
        for (p, _) in files
            .into_iter()
            .filter(|(p, _)| !pinned.iter().any(|n| p.file_name().map(|f| f == n.as_str()).unwrap_or(false)))
            .take(total - DISK_LIMIT)
        {
            let _ = std::fs::remove_file(p);
        }
    }
}

// 번역 결과를 본문에 끼운다(맥 ArticleService.run): 외국어로 보이는 문단만 세고(total), 실제로 바뀐 것만(done) 번역으로 바꾼다.
// 번역 안 된 문단은 원문 그대로 두고 original 도 비워 둔다(원문 보기 대상 아님). out[k] 는 chunk[k] 의 번역
pub fn merge_translated(blocks: &mut [Block], src: &[Block], chunk: &[usize], out: &[String]) -> (usize, usize) {
    let (mut done, mut total) = (0, 0);
    for (k, &i) in chunk.iter().enumerate() {
        let Some(orig) = src.get(i).and_then(|b| b.text.as_deref()) else { continue };
        if !looks_foreign(orig) {
            continue;
        }
        total += 1;
        let Some(t) = out.get(k).filter(|t| t.as_str() != orig) else { continue };
        done += 1;
        blocks[i].original = Some(orig.to_string());
        blocks[i].text = Some(t.clone());
    }
    (done, total)
}

// 읽기 창의 번역 표시: 번역된 문단이 없으면 표시 없음, 일부만 됐으면 '… · 일부 번역'(맥 ArticleService.engineLabel)
pub fn engine_label(done: usize, total: usize, engine: &str) -> String {
    if done == 0 {
        return String::new();
    }
    let engine = if engine.is_empty() { crate::translator::Engine::Google.label() } else { engine };
    if done < total {
        format!("{engine} · 일부 번역")
    } else {
        engine.to_string()
    }
}

// 읽는 시간(한국어 분당 500자 · 영어 분당 230낱말)
pub fn reading_minutes(texts: &[String]) -> i64 {
    let all = texts.join(" ");
    let m = if looks_foreign(&all) {
        all.split_whitespace().count() as f64 / 230.0
    } else {
        all.chars().filter(|c| !c.is_whitespace()).count() as f64 / 500.0
    };
    (m.round() as i64).max(1)
}

// 번역된 웹페이지로 보기(translate.goog)
pub fn translate_goog(link: &str) -> Option<String> {
    let u = url::Url::parse(link).ok()?;
    let host = u.host_str()?.replace('-', "--").replace('.', "-");
    let mut out = url::Url::parse(&format!("https://{host}.translate.goog{}", u.path())).ok()?;
    {
        let mut q = out.query_pairs_mut();
        for (k, v) in u.query_pairs() {
            q.append_pair(&k, &v);
        }
        q.append_pair("_x_tr_sl", "auto").append_pair("_x_tr_tl", "ko").append_pair("_x_tr_hl", "ko");
    }
    Some(out.to_string())
}


// 본문 다듬기(맥 Reader/BodyCleanup.swift): 기자 이름·이메일 줄은 본문에서 빼서 제목 아래 '바이라인'으로,
// 사진·영상 없이 남은 짧은 설명 문구는 뺀다.
pub mod body_cleanup {
    use super::{Block, BlockKind};
    use once_cell::sync::Lazy;
    use regex::Regex;
    use std::collections::HashSet;

    // "김가람 기자 reporter@example.com", "이나래 기자 desk@example.com Powered by AI", "홍길동 특파원", "By Jane Doe"
    static BYLINE: Lazy<Regex> = Lazy::new(|| {
        Regex::new(r"^\s*(?:\[[^\]]{1,20}\]\s*)?([가-힣]{2,4})\s?(기자|특파원|에디터|선임기자|객원기자|논설위원)(?:\s*[=·,]?\s*[\w.+-]+@[\w-]+(?:\.[\w-]+)+)?(?:\s*Powered by [\w .]{1,40})?\s*$").unwrap()
    });
    static ENGLISH: Lazy<Regex> = Lazy::new(|| Regex::new(r"^\s*By\s+[A-Z][a-z]+(?:\s+[A-Z][a-z.]+){0,3}\s*$").unwrap());
    // 사진·영상 설명만 남은 줄: "AI 생성 영상", "사진=연합뉴스", "(사진 제공: ○○)", "그래픽=○○"
    static ORPHAN: Lazy<Regex> = Lazy::new(|| {
        Regex::new(r"^\s*[\(\[]?\s*(?:AI\s?생성\s?(?:영상|이미지|사진)|(?:사진|영상|이미지|그래픽|자료)\s?(?:=|제공|출처|:)[^.。]{0,30})\s*[\)\]]?\s*$").unwrap()
    });

    pub fn byline(text: &str) -> Option<String> {
        if let Some(c) = BYLINE.captures(text) {
            return Some(format!("{} {}", &c[1], &c[2]));
        }
        if ENGLISH.is_match(text) {
            return Some(text.trim().to_string());
        }
        None
    }

    pub fn is_orphan_caption(text: &str, next_is_image: bool) -> bool {
        !next_is_image && text.chars().count() <= 40 && ORPHAN.is_match(text)
    }

    // 본문에서 뺄 문단 번호와 바이라인(여러 명이면 " · " 로 이어 붙임)
    pub fn analyze(blocks: &[Block]) -> (HashSet<usize>, Option<String>) {
        let mut skip = HashSet::new();
        let mut names: Vec<String> = vec![];
        for (i, b) in blocks.iter().enumerate() {
            if b.kind != BlockKind::P {
                continue;
            }
            let t = b.original.as_deref().or(b.text.as_deref()).unwrap_or("");
            if let Some(n) = byline(t) {
                skip.insert(i);
                if !names.contains(&n) {
                    names.push(n);
                }
                continue;
            }
            let next = blocks.get(i + 1).map(|n| n.kind == BlockKind::Img).unwrap_or(false);
            if is_orphan_caption(t, next) {
                skip.insert(i);
            }
        }
        (skip, if names.is_empty() { None } else { Some(names.join(" · ")) })
    }

    // 본문에서 빼는 블록 전부(맥 ReaderView.hiddenBlocks): 기자 줄·짝 잃은 설명 문구, 표지와 같은 사진(주소가 같거나 크기 표기만 다른 것)
    // 처음 한 번, 기자 프로필·로고 같은 잡그림, 그리고 뺀 그림 바로 뒤의 사진 설명(사진 없이 설명만 남지 않게)
    pub fn hidden(blocks: &[Block], cover: Option<&str>) -> HashSet<usize> {
        use super::image_key;
        let (mut out, _) = analyze(blocks);
        if let Some(c) = cover {
            if let Some(dup) = blocks.iter().position(|b| b.kind == BlockKind::Img && image_key::same(b.src.as_deref(), Some(c))) {
                out.insert(dup);
            }
        }
        for (i, b) in blocks.iter().enumerate() {
            if b.kind == BlockKind::Img && image_key::is_junk(b.src.as_deref()) {
                out.insert(i);
            }
        }
        let caps: Vec<usize> = out
            .iter()
            .filter(|&&i| blocks[i].kind == BlockKind::Img && blocks.get(i + 1).map(|n| n.kind == BlockKind::Cap).unwrap_or(false))
            .map(|i| i + 1)
            .collect();
        out.extend(caps);
        out
    }
}

// 사진 주소 비교(맥 ReaderView 의 ImageKey): 같은 사진의 다른 크기, 기사 사진이 아닌 잡그림
pub mod image_key {
    use once_cell::sync::Lazy;
    use regex::Regex;

    static SUFFIX: Lazy<Regex> =
        Lazy::new(|| Regex::new(r"([-_](v?\d{2,4}(x\d{2,4})?|thumb(nail)?|small|medium|large|scaled|crop(ped)?|resize[d]?|\d{2,4}w))+$").unwrap());
    static JUNK: Lazy<Regex> = Lazy::new(|| {
        Regex::new(r"(default[-_]?user|avatar|profile|reporter|byline|author|gravatar|/logo|logo[-_.]|favicon|/icons?/|icon[-_.]|spacer|blank\.|1x1|pixel\.|badge|sprite|emoji|/ads?/)").unwrap()
    });

    pub fn key(url: &str) -> String {
        let mut u = url.to_lowercase();
        if let Some(q) = u.find(['?', '#']) {
            u.truncate(q);
        }
        let mut name = u.rsplit('/').next().unwrap_or(&u).to_string();
        if let Some(dot) = name.rfind('.') {
            if name.len() - dot <= 5 {
                name.truncate(dot);
            }
        }
        SUFFIX.replace(&name, "").to_string()
    }

    // 기사 사진이 아닌 잡그림: 기자 프로필·아바타·로고·아이콘·추적용 1픽셀
    pub fn is_junk(url: Option<&str>) -> bool {
        let Some(u) = url else { return true };
        let u = u.to_lowercase();
        let name = u.split('?').next().unwrap_or(&u);
        JUNK.is_match(name)
    }

    pub fn same(a: Option<&str>, b: Option<&str>) -> bool {
        let (Some(a), Some(b)) = (a, b) else { return false };
        if a == b {
            return true;
        }
        let (ka, kb) = (key(a), key(b));
        ka.chars().count() >= 6 && ka == kb
    }
}
