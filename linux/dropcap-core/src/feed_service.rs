// 출처 하나를 받아 와서 NewsItem 목록으로 바꾼다. ETag·Last-Modified 로 바뀐 것이 없으면 None.
use crate::feed_parser::{self, plain, Entry};
use crate::models::{NewsItem, Source};
use crate::net::{self, FeedError};
use crate::url_safety::is_public_http;
use once_cell::sync::Lazy;
use regex::{Regex, RegexBuilder};
use std::collections::HashMap;
use std::io::Read;
use std::sync::Mutex;
use std::time::Duration;

#[derive(Clone, Default)]
struct Validator {
    etag: Option<String>,
    modified: Option<String>,
}

pub struct FeedService {
    validators: Mutex<HashMap<String, Validator>>,
    pending: Mutex<HashMap<String, Validator>>, // 해석이 성공해야 확정
    first_seen: Mutex<HashMap<String, chrono::DateTime<chrono::Utc>>>, // 날짜 없는 글을 처음 본 시각
}

pub static SHARED: Lazy<FeedService> =
    Lazy::new(|| FeedService { validators: Mutex::new(HashMap::new()), pending: Mutex::new(HashMap::new()), first_seen: Mutex::new(HashMap::new()) });

// 받는 크기 상한(S-12 · 맥 FetchLimit): 받는 도중 넘으면 바로 끊는다. gzip 을 푼 뒤에는 32MB 상한(gzip::LIMIT)
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FetchLimit {
    Feed,  // 피드·사이트맵·채널 찾기 10MB
    Page,  // 기사 페이지(본문 추리기·사이트맵 제목·og:image) 2MB
    Image, // 사진 8MB
}

impl FetchLimit {
    pub fn bytes(self) -> usize {
        match self {
            FetchLimit::Feed => 10_485_760,
            FetchLimit::Page => 2_097_152,
            FetchLimit::Image => 8_388_608,
        }
    }
}

// 사이트맵 출처의 글 주소 정규식은 앱에 든 기본 출처(같은 id·같은 정규식)의 것만 쓴다(맥 sitemapPattern).
// 상태 파일·가져온 기록에서 온 값은 믿지 않는다(regex crate 는 선형이지만 아주 큰 정규식·이상한 값을 들이지 않게)
pub fn sitemap_pattern(source: &Source) -> Option<String> {
    let m = source.match_.as_ref()?;
    crate::models::resources::CONFIG.sources.iter().any(|b| b.id == source.id && b.match_.as_ref() == Some(m)).then(|| m.clone())
}

pub struct Body {
    pub data: Vec<u8>,
    pub encoding: Option<String>,
}

impl FeedService {
    pub async fn fetch(&self, url: &str, conditional: bool) -> Result<Option<Vec<u8>>, FeedError> {
        Ok(self.fetch_with_encoding(url, conditional, FetchLimit::Feed).await?.map(|b| b.data))
    }

    // 기사 페이지(2MB 상한)
    pub async fn fetch_page(&self, url: &str) -> Result<Option<Vec<u8>>, FeedError> {
        Ok(self.fetch_with_encoding(url, false, FetchLimit::Page).await?.map(|b| b.data))
    }

    // 잠깐의 서버 오류(5xx·429, YouTube 피드의 간헐적 404)는 한 번 더 시도한다
    pub async fn fetch_with_encoding(&self, url: &str, conditional: bool, limit: FetchLimit) -> Result<Option<Body>, FeedError> {
        let youtube = url.contains("youtube.com/feeds");
        let mut attempt = 0u64;
        loop {
            match self.fetch_once(url, conditional, limit).await {
                Err(FeedError::Http(code)) if code == 429 || (500..=504).contains(&code) || (code == 404 && youtube) => {
                    attempt += 1;
                    if attempt > if youtube { 2 } else { 1 } {
                        return Err(FeedError::Http(code));
                    }
                    let ms = if code == 429 { 3000 } else { 1500 * attempt };
                    tokio::time::sleep(Duration::from_millis(ms)).await;
                }
                other => return other,
            }
        }
    }

    async fn fetch_once(&self, url: &str, conditional: bool, limit: FetchLimit) -> Result<Option<Body>, FeedError> {
        let mut headers = vec![("accept", "application/rss+xml, application/atom+xml, application/xml, text/xml, text/html;q=0.8".to_string())];
        if conditional {
            if let Some(v) = self.validators.lock().unwrap().get(url).cloned() {
                if let Some(e) = v.etag {
                    headers.push(("if-none-match", e));
                }
                if let Some(m) = v.modified {
                    headers.push(("if-modified-since", m));
                }
            }
        }
        let r = net::get(url, &headers, limit.bytes()).await?;
        if r.status == 304 {
            return Ok(None);
        }
        if !(200..300).contains(&r.status) {
            return Err(FeedError::Http(r.status));
        }
        if conditional {
            self.pending.lock().unwrap().insert(url.to_string(), Validator { etag: r.etag, modified: r.last_modified });
        }
        Ok(Some(Body { data: gzip::inflate_if_needed(r.data), encoding: r.charset }))
    }

    pub async fn items(&self, source: &Source, conditional: bool) -> Result<Option<Vec<NewsItem>>, FeedError> {
        let now = chrono::Utc::now();
        let health = &crate::source_health::BOOK;
        let parsed: Result<Option<Vec<Entry>>, FeedError> = async {
            let Some(data) = self.fetch(&source.url, conditional).await? else { return Ok(None) };
            Ok(Some(match (sitemap_pattern(source), source.is_sitemap()) {
                (Some(m), true) => {
                    let re = Regex::new(&m).map_err(|_| FeedError::BadFormat)?;
                    feed_parser::parse_sitemap(&data, &re)?
                }
                _ => feed_parser::parse_feed(&data)?,
            }))
        }
        .await;
        let mut entries = match parsed {
            Ok(Some(e)) => e,
            Ok(None) => {
                health.record_unchanged(&source.id, now);
                return Ok(None);
            }
            Err(e) => {
                health.record_failure(&source.id, &e.to_string());
                return Err(e);
            }
        };
        // 날짜 없는 피드는 맨 위 글이 바뀌었는지로 새 글을 판단
        let dated = entries.iter().any(|e| e.date.is_some());
        feed_parser::feed_dates::repair(&mut entries, &source.id, now, &mut self.first_seen.lock().unwrap());
        let newest = if dated { entries.iter().filter_map(|e| e.date).max() } else { None };
        health.record_success(&source.id, newest, entries.first().map(|e| e.id.clone()), entries.len() as i64, now);
        // 해석에 성공했을 때만 "바뀐 것 없음" 표시를 확정한다(실패한 피드가 304 로 가려지지 않게)
        if let Some(v) = self.pending.lock().unwrap().remove(&source.url) {
            self.validators.lock().unwrap().insert(source.url.clone(), v);
        }
        // http(s) 링크만: file:// · smb:// 같은 주소는 열지 않는다
        Ok(Some(
            entries
                .into_iter()
                .filter(|e| is_public_http(&e.link))
                .map(|e| {
                    let mut it = NewsItem::new(&e.id, &e.title, &e.link, &source.id, &source.name, &source.tier);
                    it.date = e.date;
                    it.summary = e.summary.clone();
                    it.image = e.image.and_then(|u| url::Url::parse(&e.link).and_then(|b| b.join(&u)).ok().map(|u| u.to_string()));
                    it.kind = source.kind.clone();
                    it
                })
                .collect(),
        ))
    }

    // 사이트맵에서 찾은 새 글은 본문을 받아 제목·설명을 채운다
    pub async fn fill_title(&self, item: &mut NewsItem) {
        let Ok(Some(data)) = self.fetch_page(&item.link).await else {
            item.title = plain::title_from_slug(&item.link);
            return;
        };
        let html = String::from_utf8_lossy(&data).to_string();
        let meta = |p: &str| -> Option<String> {
            RegexBuilder::new(p).case_insensitive(true).build().ok()?.captures(&html).map(|c| c[1].to_string())
        };
        static SUFFIX: Lazy<Regex> = Lazy::new(|| Regex::new(r"\s*[|\\-]\s*Anthropic\s*$").unwrap());
        let title = meta(r#"<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)"#).or_else(|| meta(r"<title[^>]*>([^<]+)</title>"));
        item.title = title
            .map(|t| SUFFIX.replace(&plain::clean(&t), "").to_string())
            .filter(|t| !t.is_empty())
            .unwrap_or_else(|| plain::title_from_slug(&item.link));
        if let Some(d) = meta(r#"<meta[^>]+name=["']description["'][^>]+content=["']([^"']+)"#) {
            item.summary = plain::clean(&d).chars().take(300).collect();
        }
        if item.image.is_none() {
            if let Some(img) = meta(r#"<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)"#) {
                item.image = Some(img);
            }
        }
    }

    // 대표 사진이 없는 기사는 페이지 머리의 og:image 를 찾아 채운다(공개 주소만, 앞 64KB 만 읽음)
    pub async fn og_image(&self, link: &str) -> Option<String> {
        let data = self.fetch_page(link).await.ok()??;
        let head = String::from_utf8_lossy(&data[..data.len().min(65536)]).to_string();
        for p in [
            r#"<meta[^>]+property=["']og:image(?::url)?["'][^>]+content=["']([^"']+)"#,
            r#"<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image"#,
            r#"<meta[^>]+name=["']twitter:image["'][^>]+content=["']([^"']+)"#,
        ] {
            let re = RegexBuilder::new(p).case_insensitive(true).build().ok()?;
            if let Some(c) = re.captures(&head) {
                let raw = c[1].replace("&amp;", "&");
                let base = url::Url::parse(link).ok()?;
                return base.join(&raw).ok().map(|u| u.to_string());
            }
        }
        None
    }
}

// Content-Encoding 없이 gzip 본문을 보내는 서버(DeepMind 등) 대비. 크기 값은 믿지 않고 32MB 상한.
pub mod gzip {
    use super::*;
    pub const LIMIT: u64 = 32 << 20;

    pub fn inflate_if_needed(data: Vec<u8>) -> Vec<u8> {
        if data.len() <= 18 || data[0] != 0x1F || data[1] != 0x8B {
            return data;
        }
        let mut out = Vec::new();
        let mut d = flate2::read::GzDecoder::new(&data[..]).take(LIMIT);
        match d.read_to_end(&mut out) {
            Ok(n) if n > 0 => out,
            _ => data,
        }
    }
}
