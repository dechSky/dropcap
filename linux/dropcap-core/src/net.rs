// 바깥으로 나가는 모든 요청이 쓰는 HTTP 클라이언트.
// 접속하는 순간 IP 검사(S-03): 이름 풀기를 이 앱이 직접 하고(GuardedResolver), 풀린 주소가 하나라도 내부망이면
// 연결 자체를 하지 않는다. 연결은 검사한 그 IP 로만 가므로 확인 뒤 DNS 응답을 바꾸는 공격도 막힌다.
// IP 글자 주소는 이름 풀기를 거치지 않으므로 is_public_http 가 미리 막고, 받은 뒤에도 실제 접속 IP 를 한 번 더 본다.
// 리다이렉트도 같은 검사(S-04). 프록시는 환경 변수로 시스템 프록시가 설정된 경우만 허용(그 이름만 예외).
use crate::url_safety::{self, is_public_ip};
use once_cell::sync::Lazy;
use reqwest::dns::{Addrs, Name, Resolve, Resolving};
use std::collections::HashSet;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

pub const USER_AGENT: &str = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/605.1.15 (KHTML, like Gecko) Dropcap/1.0";
pub const MAX_BODY: usize = 32 << 20;

#[derive(Debug, Clone, PartialEq)]
pub enum FeedError {
    BadFormat,
    Http(u16),
    Blocked(String),
    Net(String),
}

impl std::fmt::Display for FeedError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FeedError::Blocked(why) => write!(f, "안전하지 않은 주소라 막음: {why}"),
            FeedError::BadFormat => write!(f, "RSS/Atom 형식을 알아볼 수 없음"),
            FeedError::Http(c) => write!(f, "HTTP {c}"),
            FeedError::Net(e) => write!(f, "{e}"),
        }
    }
}
impl std::error::Error for FeedError {}

// 시스템 프록시(환경 변수)의 이름들
fn proxy_hosts() -> HashSet<String> {
    let mut out = HashSet::new();
    for k in ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"] {
        if let Ok(v) = std::env::var(k) {
            let v = if v.contains("://") { v } else { format!("http://{v}") };
            if let Some(h) = url_safety::host_of(&v) {
                out.insert(h);
            }
        }
    }
    out
}

pub fn system_proxy_configured() -> bool {
    !proxy_hosts().is_empty()
}

struct GuardedResolver {
    proxies: HashSet<String>,
}

impl Resolve for GuardedResolver {
    fn resolve(&self, name: Name) -> Resolving {
        let host = name.as_str().to_ascii_lowercase();
        let is_proxy = self.proxies.contains(&host);
        Box::pin(async move {
            let addrs: Vec<SocketAddr> = tokio::net::lookup_host((host.as_str(), 0))
                .await
                .map_err(|e| Box::new(e) as Box<dyn std::error::Error + Send + Sync>)?
                .collect();
            if addrs.is_empty() {
                return Err(Box::new(FeedError::Blocked("이름을 풀지 못함".into())) as _);
            }
            if !is_proxy {
                let ok = addrs.iter().all(|a| is_public_ip(&a.ip()));
                url_safety::cache_set(&host, ok);
                if !ok {
                    return Err(Box::new(FeedError::Blocked(format!("접속 IP {}", addrs[0].ip()))) as _);
                }
            }
            let it: Addrs = Box::new(addrs.into_iter());
            Ok(it)
        })
    }
}

fn build(timeout: u64) -> reqwest::Client {
    let proxies = proxy_hosts();
    let mut b = reqwest::Client::builder()
        .user_agent(USER_AGENT)
        .timeout(Duration::from_secs(timeout))
        .connect_timeout(Duration::from_secs(10))
        .dns_resolver(Arc::new(GuardedResolver { proxies: proxies.clone() }))
        // 리다이렉트는 get() 이 직접 따라가며 단계마다 이름 풀기까지 검사한다(프록시를 거쳐도)
        .redirect(reqwest::redirect::Policy::none());
    if proxies.is_empty() {
        b = b.no_proxy();
    }
    b.build().expect("HTTP 클라이언트")
}

pub static CLIENT: Lazy<reqwest::Client> = Lazy::new(|| build(20));

pub struct Fetched {
    pub status: u16,
    pub data: Vec<u8>,
    pub charset: Option<String>,
    pub etag: Option<String>,
    pub last_modified: Option<String>,
}

pub const MAX_REDIRECTS: usize = 10;

// 이 주소로 요청해도 되는가: 공개 주소 + 실제로 풀린 IP 가 모두 공개 + 프록시 자신의 이름이 아님
async fn allowed(url: &str) -> bool {
    if !url_safety::resolves_public(url).await {
        return false;
    }
    // 프록시 이름은 이름 풀기 검사에서 예외이므로, 피드 주소가 그 이름을 쓰면 막는다
    !url_safety::host_of(url).map(|h| proxy_hosts().contains(&h)).unwrap_or(true)
}

// 안전 검사를 거쳐 받는다(리다이렉트는 단계마다 같은 검사, S-04). 304 는 status 로 알려 준다.
pub async fn get(url: &str, headers: &[(&str, String)], limit: usize) -> Result<Fetched, FeedError> {
    let mut current = url.to_string();
    let mut hops = 0;
    let mut resp = loop {
        if !allowed(&current).await {
            return Err(FeedError::Blocked(if hops == 0 { "주소 확인".into() } else { "리다이렉트".into() }));
        }
        let mut req = CLIENT.get(&current);
        for (k, v) in headers {
            req = req.header(*k, v);
        }
        let r = req.send().await.map_err(net_err)?;
        if !r.status().is_redirection() || r.status().as_u16() == 304 {
            break r;
        }
        let Some(loc) = r.headers().get("location").and_then(|v| v.to_str().ok()) else { break r };
        let next = url::Url::parse(&current).and_then(|b| b.join(loc)).map_err(|_| FeedError::Blocked("리다이렉트".into()))?;
        hops += 1;
        if hops > MAX_REDIRECTS {
            return Err(FeedError::Net("리다이렉트가 너무 많음".into()));
        }
        current = next.to_string();
    };
    // 실제 접속 IP 를 한 번 더(프록시를 거치면 프록시 IP 라 이름 확인에 맡김). 모르면 막는다.
    let proxied = system_proxy_configured();
    match resp.remote_addr() {
        Some(a) if !proxied && !is_public_ip(&a.ip()) => return Err(FeedError::Blocked(format!("접속 IP {}", a.ip()))),
        None if !proxied => return Err(FeedError::Blocked("접속 IP 확인 안 됨".into())),
        _ => {}
    }
    let status = resp.status().as_u16();
    let h = resp.headers();
    let header = |n: &str| h.get(n).and_then(|v| v.to_str().ok()).map(|s| s.to_string());
    let etag = header("etag");
    let last_modified = header("last-modified");
    let charset = header("content-type").and_then(|ct| {
        ct.split(';')
            .find_map(|p| p.trim().strip_prefix("charset=").map(|c| c.trim_matches('"').to_ascii_lowercase()))
    });
    let mut data = Vec::new();
    while let Some(chunk) = resp.chunk().await.map_err(net_err)? {
        if data.len() + chunk.len() > limit {
            return Err(FeedError::Net("응답이 너무 큼".into()));
        }
        data.extend_from_slice(&chunk);
    }
    Ok(Fetched { status, data, charset, etag, last_modified })
}

fn net_err(e: reqwest::Error) -> FeedError {
    // 이름 풀기·리다이렉트에서 막은 것은 막음으로 알린다
    let mut src: Option<&dyn std::error::Error> = Some(&e);
    while let Some(s) = src {
        if let Some(f) = s.downcast_ref::<FeedError>() {
            return f.clone();
        }
        src = s.source();
    }
    if e.is_timeout() {
        FeedError::Net("시간 초과".into())
    } else {
        FeedError::Net(e.without_url().to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // 이름이 내부망으로 풀리면 연결 전에 막는다(접속 순간 검사)
    #[tokio::test]
    async fn resolver_blocks_loopback_name() {
        let r = GuardedResolver { proxies: HashSet::new() };
        let name: Name = "localhost".parse().unwrap();
        let out = r.resolve(name).await;
        assert!(out.is_err());
    }

    // 이름 확인을 건너뛰고 클라이언트를 바로 불러도(DNS 바꿔치기 상황) 내부망으로는 연결되지 않는다
    #[tokio::test]
    async fn client_never_connects_to_loopback_by_name() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let accepted = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let a2 = accepted.clone();
        tokio::spawn(async move {
            if listener.accept().await.is_ok() {
                a2.store(true, std::sync::atomic::Ordering::SeqCst);
            }
        });
        let r = CLIENT.get(format!("http://localhost:{port}/")).send().await;
        assert!(r.is_err());
        assert!(matches!(net_err(r.unwrap_err()), FeedError::Blocked(_)));
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert!(!accepted.load(std::sync::atomic::Ordering::SeqCst), "연결이 나가면 안 됨");
    }

    #[tokio::test]
    async fn get_refuses_private_literal() {
        assert!(matches!(get("http://127.0.0.1:9/", &[], 10).await, Err(FeedError::Blocked(_))));
    }
}
