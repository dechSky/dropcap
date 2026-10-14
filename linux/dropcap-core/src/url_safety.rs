// 피드에서 온 주소는 믿지 않는다. 공개 인터넷의 http(s) 주소만 받는다(맥 Core/URLSafety.swift 와 같은 규칙).
//
// 1) is_public_http: 주소 모양만 보고 바로 판단(스킴·이름·IP 글자). 숫자 꼼수(0x7f.1, 127.1 등)는 거절.
//    입력 글자 그대로의 이름과, URL 표준으로 정규화된 이름(%31%32%37.0.0.1 → 127.0.0.1) 둘 다 통과해야 한다.
// 2) resolves_public: 이름을 실제 IP 로 풀어 하나라도 내부망이면 거절(5분 기억).
// 3) 접속하는 순간: net::GuardedResolver 가 연결할 IP 를 직접 골라 주고 그 IP 를 검사한다.
//    (맥은 받은 뒤 확인 · 리눅스는 연결 전에 확인하므로 DNS 바꿔치기 때도 요청이 나가지 않는다)
use once_cell::sync::Lazy;
use regex::Regex;
use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::sync::Mutex;
use std::time::{Duration, Instant};

static ODD_NUMERIC: Lazy<Regex> = Lazy::new(|| Regex::new(r"^[0-9a-fx.]+$").unwrap());

pub fn is_public_http(url: &str) -> bool {
    let Some((scheme, rest)) = url.split_once("://") else { return false };
    let scheme = scheme.to_ascii_lowercase();
    if scheme != "http" && scheme != "https" {
        return false;
    }
    let Some(raw) = raw_host(rest) else { return false };
    if !host_ok(&raw) {
        return false;
    }
    // URL 표준 정규화 뒤의 이름도 같은 검사(실제 요청은 이 이름으로 나간다)
    let Ok(parsed) = url::Url::parse(url) else { return false };
    match parsed.host() {
        Some(url::Host::Ipv4(a)) => is_public_v4(&a.octets()),
        Some(url::Host::Ipv6(a)) => is_public_v6(&a.octets()),
        Some(url::Host::Domain(d)) => host_ok(&d.to_ascii_lowercase()),
        None => false,
    }
}

// "user:pw@host:port/path" 에서 host 만(대괄호 IPv6 포함, 소문자)
fn raw_host(rest: &str) -> Option<String> {
    let end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let auth = &rest[..end];
    let hostport = auth.rsplit_once('@').map(|(_, h)| h).unwrap_or(auth);
    let host = if hostport.starts_with('[') {
        let close = hostport.find(']')?;
        &hostport[..=close]
    } else {
        hostport.split(':').next().unwrap_or("")
    };
    if host.is_empty() {
        None
    } else {
        Some(host.to_lowercase())
    }
}

fn host_ok(h: &str) -> bool {
    let mut host = h.to_string();
    if host.starts_with('[') && host.ends_with(']') {
        host = host[1..host.len() - 1].to_string();
    }
    if host.ends_with('.') {
        host.pop();
    }
    if host.is_empty() {
        return false;
    }
    if host == "localhost"
        || host.ends_with(".localhost")
        || host.ends_with(".local")
        || host.ends_with(".internal")
        || host.ends_with(".lan")
        || host.ends_with(".home.arpa")
        || host.ends_with(".arpa")
    {
        return false;
    }
    if let Some(v4) = parse_v4(&host) {
        return is_public_v4(&v4);
    }
    if host.contains(':') {
        return match parse_v6(&host) {
            Some(v6) => is_public_v6(&v6),
            None => false,
        };
    }
    // 점 없는 이름(intranet), 숫자·16진수로만 된 이상한 표기(2130706433, 0x7f.1, 127.1)는 거절
    if !host.contains('.') {
        return false;
    }
    if ODD_NUMERIC.is_match(&host) && host.chars().last().map(|c| c.is_ascii_digit()).unwrap_or(false) {
        return false;
    }
    true
}

// 표준 4칸 10진수만. 앞자리 0(0177 = 8진수 127 로 읽는 곳이 있음)은 IP 로 보지 않는다 → 위에서 거절
pub fn parse_v4(s: &str) -> Option<[u8; 4]> {
    let parts: Vec<&str> = s.split('.').collect();
    if parts.len() != 4 || !parts.iter().all(|p| p.len() == 1 || !p.starts_with('0')) {
        return None;
    }
    s.parse::<Ipv4Addr>().ok().map(|a| a.octets())
}

pub fn parse_v6(s: &str) -> Option<[u8; 16]> {
    s.parse::<Ipv6Addr>().ok().map(|a| a.octets())
}

pub fn is_public_v4(b: &[u8; 4]) -> bool {
    match (b[0], b[1]) {
        (0, _) | (10, _) | (127, _) => false,
        (169, 254) | (192, 168) => false,
        (172, 16..=31) => false,
        (100, 64..=127) => false, // 통신사 공유 주소
        (192, 0) if b[2] == 0 => false,
        (198, 18..=19) => false, // 시험용
        _ => b[0] < 224,         // 멀티캐스트·예약 제외
    }
}

pub fn is_public_v6(b: &[u8; 16]) -> bool {
    if b[..15].iter().all(|&x| x == 0) {
        return false; // :: 와 ::1
    }
    if b[0] & 0xFE == 0xFC {
        return false; // fc00::/7 고유 로컬
    }
    if b[0] == 0xFE && b[1] & 0xC0 == 0x80 {
        return false; // fe80::/10 링크 로컬
    }
    if b[0] == 0xFE && b[1] & 0xC0 == 0xC0 {
        return false; // fec0::/10 사이트 로컬(폐지됐지만 내부망에 남아 있음)
    }
    if b[0] == 0xFF {
        return false; // 멀티캐스트
    }
    let v4 = |i: usize| [b[i], b[i + 1], b[i + 2], b[i + 3]];
    if b[..10].iter().all(|&x| x == 0) && b[10] == 0xFF && b[11] == 0xFF {
        return is_public_v4(&v4(12)); // ::ffff:a.b.c.d
    }
    if b[..12].iter().all(|&x| x == 0) {
        return is_public_v4(&v4(12)); // ::a.b.c.d (옛 표기)
    }
    if b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xFF && b[3] == 0x9B {
        return is_public_v4(&v4(12)); // 64:ff9b::/96 NAT64
    }
    if b[0] == 0x20 && b[1] == 0x02 {
        return is_public_v4(&v4(2)); // 2002::/16 6to4
    }
    true
}

pub fn is_public_ip(ip: &IpAddr) -> bool {
    match ip {
        IpAddr::V4(a) => is_public_v4(&a.octets()),
        IpAddr::V6(a) => is_public_v6(&a.octets()),
    }
}

// MARK: 이름 풀기(5분 기억)
static CACHE: Lazy<Mutex<HashMap<String, (bool, Instant)>>> = Lazy::new(|| Mutex::new(HashMap::new()));

fn cache_get(h: &str) -> Option<bool> {
    let m = CACHE.lock().unwrap();
    m.get(h).filter(|e| e.1.elapsed() < Duration::from_secs(300)).map(|e| e.0)
}

pub(crate) fn cache_set(h: &str, ok: bool) {
    let mut m = CACHE.lock().unwrap();
    if m.len() > 500 {
        m.clear();
    }
    m.insert(h.to_string(), (ok, Instant::now()));
}

pub fn host_of(url: &str) -> Option<String> {
    let u = url::Url::parse(url).ok()?;
    u.host_str().map(|h| h.trim_start_matches('[').trim_end_matches(']').to_ascii_lowercase())
}

// 이름을 실제로 풀어 모든 주소가 공개 주소일 때만 true
pub async fn resolves_public(url: &str) -> bool {
    if !is_public_http(url) {
        return false;
    }
    let Some(bare) = host_of(url) else { return false };
    if parse_v4(&bare).is_some() || bare.contains(':') {
        return true; // IP 글자는 1단계에서 이미 판단
    }
    if let Some(c) = cache_get(&bare) {
        return c;
    }
    let ok = match tokio::net::lookup_host((bare.as_str(), 0)).await {
        Ok(addrs) => {
            let list: Vec<_> = addrs.collect();
            !list.is_empty() && list.iter().all(|a| is_public_ip(&a.ip()))
        }
        Err(_) => false,
    };
    cache_set(&bare, ok);
    ok
}

// 기사 링크를 바깥(브라우저·앱)으로 여는 곳은 모두 이것만 쓴다: 공개 http(s) 주소만 돌려준다
pub fn external_link(link: &str) -> Option<String> {
    if is_public_http(link) {
        url::Url::parse(link).ok().map(|u| u.to_string())
    } else {
        None
    }
}
