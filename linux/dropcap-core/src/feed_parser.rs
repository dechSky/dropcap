// 간단한 나무를 만든 뒤 RSS·Atom·RDF·사이트맵을 해석한다(맥 Core/FeedParser.swift 와 같은 규칙).
use crate::net::FeedError;
use chrono::{DateTime, NaiveDateTime, TimeZone, Utc};
use once_cell::sync::Lazy;
use quick_xml::events::Event;
use regex::Regex;

#[derive(Debug, Clone, Default)]
pub struct XNode {
    pub name: String,
    pub attrs: Vec<(String, String)>,
    pub children: Vec<XNode>,
    pub text: String,
}

impl XNode {
    pub fn child(&self, n: &str) -> Option<&XNode> {
        self.children.iter().find(|c| c.name == n)
    }
    pub fn all<'a>(&'a self, n: &'a str) -> impl Iterator<Item = &'a XNode> + 'a {
        self.children.iter().filter(move |c| c.name == n)
    }
    pub fn value(&self, n: &str) -> String {
        self.child(n).map(|c| c.text.trim().to_string()).unwrap_or_default()
    }
    pub fn attr(&self, k: &str) -> Option<&str> {
        self.attrs.iter().find(|(a, _)| a == k).map(|(_, v)| v.as_str())
    }
}

#[derive(Debug, Clone, Default)]
pub struct Entry {
    pub id: String,
    pub title: String,
    pub link: String,
    pub date: Option<DateTime<Utc>>,
    pub summary: String,
    pub image: Option<String>,
}

fn non_empty(s: String) -> Option<String> {
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

// XML 기본 엔티티와 숫자 참조만 푼다. 모르는 것(&nbsp; 등)은 그대로 두어 Plain::clean 이 처리한다.
pub fn xml_unescape(s: &str) -> String {
    if !s.contains('&') {
        return s.to_string();
    }
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(i) = rest.find('&') {
        out.push_str(&rest[..i]);
        let tail = &rest[i..];
        if let Some(end) = tail[..tail.len().min(12)].find(';') {
            let ent = &tail[1..end];
            let rep = match ent {
                "lt" => Some('<'),
                "gt" => Some('>'),
                "amp" => Some('&'),
                "quot" => Some('"'),
                "apos" => Some('\''),
                _ if ent.starts_with("#x") || ent.starts_with("#X") => {
                    u32::from_str_radix(&ent[2..], 16).ok().and_then(char::from_u32)
                }
                _ if ent.starts_with('#') => ent[1..].parse::<u32>().ok().and_then(char::from_u32),
                _ => None,
            };
            if let Some(c) = rep {
                out.push(c);
                rest = &tail[end + 1..];
                continue;
            }
        }
        out.push('&');
        rest = &tail[1..];
    }
    out.push_str(rest);
    out
}

static DECL_ENCODING: Lazy<Regex> = Lazy::new(|| Regex::new(r#"(?i)^\s*<\?xml[^>]*encoding=["']([A-Za-z0-9_\-]+)["']"#).unwrap());

// 선언된 문자 인코딩(euc-kr 등)을 UTF-8 로
pub fn decode_xml(data: &[u8]) -> String {
    let head = String::from_utf8_lossy(&data[..data.len().min(200)]);
    if let Some(c) = DECL_ENCODING.captures(&head) {
        let label = c[1].to_ascii_lowercase();
        if label != "utf-8" && label != "utf8" {
            if let Some(enc) = encoding_rs::Encoding::for_label(label.as_bytes()) {
                let (s, _, _) = enc.decode(data);
                return s.into_owned();
            }
        }
    }
    let (s, _, _) = encoding_rs::UTF_8.decode(data);
    s.into_owned()
}

// 깊게 중첩된 피드(스택 넘침·느린 해제)를 막는 깊이 한도. 실제 피드는 10단계 안팎.
pub const MAX_DEPTH: usize = 64;

pub fn tree(data: &[u8]) -> Result<XNode, FeedError> {
    let text = decode_xml(data);
    let mut reader = quick_xml::Reader::from_str(&text);
    {
        let c = reader.config_mut();
        c.trim_text(false);
        c.check_end_names = false;
        c.expand_empty_elements = false;
    }
    let mut stack: Vec<XNode> = vec![XNode { name: "#root".into(), ..Default::default() }];
    let attrs_of = |e: &quick_xml::events::BytesStart| -> Vec<(String, String)> {
        e.attributes()
            .flatten()
            .map(|a| {
                let k = String::from_utf8_lossy(a.key.as_ref()).to_string();
                let v = xml_unescape(&String::from_utf8_lossy(&a.value));
                (k, v)
            })
            .collect()
    };
    let mut failed = false;
    let mut skipped = 0usize; // 한도보다 깊은 요소는 통째로 건너뛴다
    loop {
        let ev = reader.read_event();
        if skipped > 0 {
            match ev {
                Ok(Event::Start(_)) => skipped += 1,
                Ok(Event::End(_)) => skipped -= 1,
                Ok(Event::Eof) => break,
                Err(_) => {
                    failed = true;
                    break;
                }
                _ => {}
            }
            continue;
        }
        match ev {
            Ok(Event::Start(_)) if stack.len() > MAX_DEPTH => skipped = 1,
            Ok(Event::Empty(_)) if stack.len() > MAX_DEPTH => {}
            Ok(Event::Start(e)) => {
                let n = XNode { name: String::from_utf8_lossy(e.name().as_ref()).to_string(), attrs: attrs_of(&e), ..Default::default() };
                stack.push(n);
            }
            Ok(Event::Empty(e)) => {
                let n = XNode { name: String::from_utf8_lossy(e.name().as_ref()).to_string(), attrs: attrs_of(&e), ..Default::default() };
                stack.last_mut().unwrap().children.push(n);
            }
            Ok(Event::End(_)) => {
                if stack.len() > 1 {
                    let n = stack.pop().unwrap();
                    stack.last_mut().unwrap().children.push(n);
                }
            }
            Ok(Event::Text(t)) => {
                let raw = String::from_utf8_lossy(t.as_ref()).to_string();
                stack.last_mut().unwrap().text.push_str(&xml_unescape(&raw));
            }
            Ok(Event::CData(t)) => {
                stack.last_mut().unwrap().text.push_str(&String::from_utf8_lossy(t.as_ref()));
            }
            Ok(Event::GeneralRef(r)) => {
                let raw = format!("&{};", String::from_utf8_lossy(r.as_ref()));
                stack.last_mut().unwrap().text.push_str(&xml_unescape(&raw));
            }
            Ok(Event::Eof) => break,
            Ok(_) => {}
            Err(_) => {
                failed = true;
                break;
            }
        }
    }
    // 닫히지 않은 요소도 나무에 붙인다(깨진 피드도 읽을 수 있는 만큼)
    while stack.len() > 1 {
        let n = stack.pop().unwrap();
        stack.last_mut().unwrap().children.push(n);
    }
    let root = stack.pop().unwrap();
    if failed && root.children.is_empty() {
        return Err(FeedError::BadFormat);
    }
    Ok(root)
}

static IMG_TAG: Lazy<Regex> = Lazy::new(|| Regex::new(r#"<img[^>]+src=["']([^"']+)["']"#).unwrap());

fn is_image(n: &XNode) -> bool {
    if n.attr("medium") == Some("image") || n.attr("type").map(|t| t.starts_with("image")).unwrap_or(false) {
        return true;
    }
    let u = n.attr("url").unwrap_or("").to_lowercase();
    n.attr("medium").is_none() && n.attr("type").is_none() && [".jpg", ".jpeg", ".png", ".webp", ".gif"].iter().any(|e| u.contains(e))
}

// 대표 사진: media:thumbnail → media:content(그림만) → media:group 썸네일 → 그림 enclosure → 본문 첫 <img>
pub fn image(it: &XNode) -> Option<String> {
    for n in &it.children {
        match n.name.as_str() {
            "media:thumbnail" => {
                if let Some(u) = n.attr("url") {
                    return Some(u.into());
                }
            }
            "media:content" => {
                if let Some(u) = n.attr("url") {
                    if is_image(n) {
                        return Some(u.into());
                    }
                }
                if let Some(t) = n.child("media:thumbnail").and_then(|t| t.attr("url")) {
                    return Some(t.into());
                }
            }
            "media:group" => {
                if let Some(t) = n.child("media:thumbnail").and_then(|t| t.attr("url")) {
                    return Some(t.into());
                }
                if let Some(u) = n.all("media:content").find(|c| is_image(c)).and_then(|c| c.attr("url")) {
                    return Some(u.into());
                }
            }
            "enclosure" => {
                if n.attr("type").map(|t| t.starts_with("image")).unwrap_or(false) {
                    if let Some(u) = n.attr("url") {
                        return Some(u.into());
                    }
                }
            }
            _ => {}
        }
    }
    for field in ["content:encoded", "content", "description", "summary"] {
        let html = it.value(field);
        if let Some(c) = IMG_TAG.captures(&html) {
            return Some(c[1].to_string());
        }
    }
    None
}

fn prefix(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

// 피드 자체의 이름(구독할 때 기본 이름으로)
pub fn feed_title(data: &[u8]) -> Option<String> {
    let root = tree(data).ok()?;
    let t = root
        .child("rss")
        .and_then(|r| r.child("channel"))
        .map(|c| c.value("title"))
        .and_then(non_empty)
        .or_else(|| root.child("feed").map(|f| f.value("title")).and_then(non_empty))
        .or_else(|| root.child("rdf:RDF").and_then(|r| r.child("channel")).map(|c| c.value("title")).and_then(non_empty));
    t.map(|t| plain::clean(&t))
}

pub fn parse_feed(data: &[u8]) -> Result<Vec<Entry>, FeedError> {
    let root = tree(data)?;
    if let Some(channel) = root.child("rss").and_then(|r| r.child("channel")) {
        return Ok(channel
            .all("item")
            .map(|it| {
                let link = it.value("link");
                Entry {
                    id: non_empty(it.value("guid")).unwrap_or_else(|| link.clone()),
                    title: plain::clean(&it.value("title")),
                    date: dates::parse(&non_empty(it.value("pubDate")).unwrap_or_else(|| it.value("dc:date"))),
                    summary: prefix(&plain::clean(&it.value("description")), 300),
                    image: image(it),
                    link,
                }
            })
            .collect());
    }
    if let Some(feed) = root.child("feed") {
        return Ok(feed
            .all("entry")
            .map(|it| {
                let links: Vec<&XNode> = it.all("link").collect();
                let alt = links.iter().find(|l| l.attr("rel").unwrap_or("alternate") == "alternate").or(links.first());
                let link = alt.map(|l| l.attr("href").map(|s| s.to_string()).unwrap_or_else(|| l.text.trim().to_string())).unwrap_or_default();
                Entry {
                    id: non_empty(it.value("id")).unwrap_or_else(|| link.clone()),
                    title: plain::clean(&it.value("title")),
                    date: dates::parse(&non_empty(it.value("published")).unwrap_or_else(|| it.value("updated"))),
                    summary: prefix(&plain::clean(&non_empty(it.value("summary")).unwrap_or_else(|| it.value("content"))), 300),
                    image: image(it),
                    link,
                }
            })
            .collect());
    }
    if let Some(rdf) = root.child("rdf:RDF") {
        return Ok(rdf
            .all("item")
            .map(|it| Entry {
                id: it.value("link"),
                title: plain::clean(&it.value("title")),
                link: it.value("link"),
                date: dates::parse(&it.value("dc:date")),
                summary: prefix(&plain::clean(&it.value("description")), 300),
                image: None,
            })
            .collect());
    }
    Err(FeedError::BadFormat)
}

pub fn parse_sitemap(data: &[u8], pattern: &Regex) -> Result<Vec<Entry>, FeedError> {
    let root = tree(data)?;
    let set = root.child("urlset").ok_or(FeedError::BadFormat)?;
    Ok(set
        .all("url")
        .filter_map(|u| {
            let loc = u.value("loc");
            if !pattern.is_match(&loc) {
                return None;
            }
            Some(Entry { id: loc.clone(), title: String::new(), link: loc, date: dates::parse(&u.value("lastmod")), summary: String::new(), image: None })
        })
        .collect())
}

pub mod dates {
    use super::*;
    use chrono::FixedOffset;

    // 시간대가 없는 국내 표기는 한국 시각으로 읽는다(맥 Dates.seoul)
    pub fn seoul() -> FixedOffset {
        FixedOffset::east_opt(9 * 3600).unwrap()
    }

    static WEEKDAY: Lazy<Regex> = Lazy::new(|| Regex::new(r"^[A-Za-z]{2,9}\.?,?\s+").unwrap());
    static SPACES: Lazy<Regex> = Lazy::new(|| Regex::new(r"\s+").unwrap());
    static ZONE_NAME: Lazy<Regex> = Lazy::new(|| Regex::new(r"\s?([A-Z]{1,4})$").unwrap());
    static COLON_OFF: Lazy<Regex> = Lazy::new(|| Regex::new(r"([+-]\d\d):(\d\d)$").unwrap());
    static KOREAN: Lazy<Regex> = Lazy::new(|| {
        Regex::new(r"(\d{4})년\s*(\d{1,2})월\s*(\d{1,2})일(?:\s*\S+요일)?(?:\s*(오전|오후))?(?:\s*(\d{1,2}):(\d{2})(?::(\d{2}))?)?").unwrap()
    });
    // 숫자로 바꿔 읽을 시간대 이름
    const ZONES: [(&str, &str); 14] = [
        ("KST", "+0900"), ("JST", "+0900"), ("UT", "+0000"), ("UTC", "+0000"), ("GMT", "+0000"), ("Z", "+0000"),
        ("EST", "-0500"), ("EDT", "-0400"), ("CST", "-0600"), ("CDT", "-0500"), ("MST", "-0700"), ("MDT", "-0600"), ("PST", "-0800"), ("PDT", "-0700"),
    ];

    pub fn parse(s: &str) -> Option<DateTime<Utc>> {
        let t = s.trim();
        if t.is_empty() {
            return None;
        }
        if let Ok(d) = DateTime::parse_from_rfc3339(t) {
            return Some(d.with_timezone(&Utc));
        }
        if let Ok(d) = DateTime::parse_from_rfc2822(t) {
            return Some(d.with_timezone(&Utc));
        }
        for f in ["%a, %d %b %Y %H:%M:%S %z", "%d %b %Y %H:%M:%S %z", "%a, %d %b %Y %H:%M %z"] {
            if let Ok(d) = DateTime::parse_from_str(t, f) {
                return Some(d.with_timezone(&Utc));
            }
        }
        parse_loose(t)
    }

    // 흔한 비표준 표기: '+09:00'(RFC 822 에 콜론), 시간대 이름, 틀린 요일, 숫자 월, 한국어 표기, 시간대 없는 표기(맥 Dates.parseLoose)
    fn parse_loose(t: &str) -> Option<DateTime<Utc>> {
        if let Some(d) = korean(t) {
            return Some(d);
        }
        let mut n = WEEKDAY.replace(t, "").to_string(); // 요일 떼기
        n = SPACES.replace_all(&n, " ").to_string();
        if let Some(c) = ZONE_NAME.captures(&n) {
            let name = c[1].to_string();
            if let Some((_, off)) = ZONES.iter().find(|(k, _)| *k == name) {
                let start = c.get(0).unwrap().start();
                n = format!("{} {}", &n[..start], off);
            }
        }
        n = COLON_OFF.replace(&n, "$1$2").to_string(); // +09:00 → +0900
        for f in ["%d %b %Y %H:%M:%S %z", "%d %b %Y %H:%M %z", "%d %m %Y %H:%M:%S %z", "%d %m %Y %H:%M %z", "%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M:%S%.3f%z", "%Y-%m-%d %H:%M:%S %z", "%Y-%m-%d %H:%M:%S%z"] {
            if let Ok(d) = DateTime::parse_from_str(&n, f) {
                return Some(d.with_timezone(&Utc));
            }
        }
        let tz = seoul();
        for f in ["%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M", "%Y.%m.%d %H:%M:%S", "%Y.%m.%d %H:%M", "%Y/%m/%d %H:%M:%S", "%Y/%m/%d %H:%M"] {
            if let Ok(nd) = NaiveDateTime::parse_from_str(&n, f) {
                return tz.from_local_datetime(&nd).single().map(|d| d.with_timezone(&Utc));
            }
        }
        for f in ["%Y-%m-%d", "%Y.%m.%d", "%Y/%m/%d"] {
            if let Ok(nd) = chrono::NaiveDate::parse_from_str(&n, f) {
                return tz.from_local_datetime(&nd.and_hms_opt(0, 0, 0)?).single().map(|d| d.with_timezone(&Utc));
            }
        }
        None
    }

    // '2024년 10월 29일 화요일 오후 11:30:00' 같은 한국어 표기(한국 시각)
    fn korean(t: &str) -> Option<DateTime<Utc>> {
        if !t.contains('년') {
            return None;
        }
        let c = KOREAN.captures(t)?;
        let num = |i: usize| c.get(i).and_then(|m| m.as_str().parse::<u32>().ok());
        let (y, mo, d) = (c[1].parse::<i32>().ok()?, num(2)?, num(3)?);
        let mut h = num(5).unwrap_or(0);
        match c.get(4).map(|m| m.as_str()) {
            Some("오후") if h < 12 => h += 12,
            Some("오전") if h == 12 => h = 0,
            _ => {}
        }
        let nd = chrono::NaiveDate::from_ymd_opt(y, mo, d)?.and_hms_opt(h, num(6).unwrap_or(0), num(7).unwrap_or(0))?;
        seoul().from_local_datetime(&nd).single().map(|d| d.with_timezone(&Utc))
    }
}

// 피드 날짜 다듬기(맥 FeedDates): 받은 뒤 한 번에 적용한다.
// - 날짜가 없는 글은 처음 본 시각을 날짜로(같은 실행 동안 바뀌지 않게 기억)
// - 지금보다 10분 넘게 앞선 시각(시간대를 잘못 찍은 피드, 예약 글)은 받은 시각으로 자른다
pub mod feed_dates {
    use super::Entry;
    use chrono::{DateTime, Utc};
    use std::collections::HashMap;

    pub const FUTURE_SLACK_SECS: i64 = 10 * 60;
    pub const MEMORY_LIMIT: usize = 20000;

    pub fn repair(entries: &mut [Entry], source_id: &str, now: DateTime<Utc>, first_seen: &mut HashMap<String, DateTime<Utc>>) {
        for e in entries.iter_mut() {
            match e.date {
                Some(d) if (d - now).num_seconds() > FUTURE_SLACK_SECS => e.date = Some(now),
                Some(_) => {}
                None => {
                    let key = format!("{source_id}|{}", e.id);
                    e.date = Some(*first_seen.entry(key).or_insert(now));
                }
            }
        }
        if first_seen.len() > MEMORY_LIMIT {
            let mut v: Vec<(String, DateTime<Utc>)> = first_seen.iter().map(|(k, v)| (k.clone(), *v)).collect();
            v.sort_by_key(|x| x.1);
            for (k, _) in v.into_iter().take(first_seen.len() - MEMORY_LIMIT / 2) {
                first_seen.remove(&k);
            }
        }
    }
}

pub mod plain {
    use super::*;
    static TAGS: Lazy<Regex> = Lazy::new(|| Regex::new(r"<[^>]*>").unwrap());
    static WS: Lazy<Regex> = Lazy::new(|| Regex::new(r"\s+").unwrap());
    static DASHES: Lazy<Regex> = Lazy::new(|| Regex::new(r"[-_]+").unwrap());
    static ENTITY: Lazy<Regex> = Lazy::new(|| Regex::new(r"&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z]{2,8});").unwrap());
    const NAMED: [(&str, &str); 20] = [
        ("nbsp", " "), ("amp", "&"), ("lt", "<"), ("gt", ">"), ("quot", "\""), ("apos", "'"),
        ("rsquo", "’"), ("lsquo", "‘"), ("ldquo", "“"), ("rdquo", "”"), ("hellip", "…"), ("ndash", "–"), ("mdash", "—"),
        ("middot", "·"), ("bull", "•"), ("laquo", "«"), ("raquo", "»"), ("copy", "©"), ("reg", "®"), ("trade", "™"),
    ];

    pub fn clean(s: &str) -> String {
        let out = decode_entities(&TAGS.replace_all(s, " "));
        WS.replace_all(&out, " ").trim().to_string()
    }

    // 한 번에 훑어 푼다(&amp;lt; 가 '<' 로 두 번 풀리지 않게). 숫자 표기는 모두, 이름 표기는 흔한 것만(맥 Plain.decodeEntities).
    pub fn decode_entities(s: &str) -> String {
        if !s.contains('&') {
            return s.to_string();
        }
        ENTITY
            .replace_all(s, |c: &regex::Captures| {
                let body = &c[1];
                let rep = if let Some(num) = body.strip_prefix('#') {
                    let v = match num.strip_prefix(['x', 'X']) {
                        Some(h) => u32::from_str_radix(h, 16).ok(),
                        None => num.parse::<u32>().ok(),
                    };
                    v.filter(|v| *v != 0).and_then(char::from_u32).map(|ch| ch.to_string())
                } else {
                    NAMED.iter().find(|(k, _)| *k == body || *k == body.to_lowercase()).map(|(_, v)| v.to_string())
                };
                rep.unwrap_or_else(|| c[0].to_string())
            })
            .to_string()
    }

    pub fn title_from_slug(url: &str) -> String {
        let slug = url.split('/').filter(|s| !s.is_empty()).last().unwrap_or(url);
        let t = DASHES.replace_all(slug, " ").to_string();
        let mut c = t.chars();
        match c.next() {
            Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
            None => String::new(),
        }
    }
}
