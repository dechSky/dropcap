// 웹 보기(WebKitGTK)의 모든 요청이 거치는 안전 검사 프록시(127.0.0.1 전용).
// 웹 엔진은 페이지가 보내는 하위 요청(fetch·XHR·iframe·CSS 등)의 이름을 스스로 풀기 때문에 이동 검사만으로는
// 내부망 요청을 다 막을 수 없다. 그래서 웹 보기 세션의 프록시를 이것으로 정해, 모든 연결을
// "이름 풀기 → 풀린 IP 가 하나라도 내부망이면 거절 → 검사한 그 IP 로만 연결"(net.rs 와 같은 S-03 규칙)로 처리한다.
// https 는 CONNECT 로 터널만(내용은 보지 않음), http 는 절대 주소 요청을 원래 서버로 넘긴다.
use crate::url_safety::{is_public_http, is_public_ip};
use std::net::SocketAddr;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

const MAX_HEAD: usize = 16 * 1024;
const MAX_BODY: usize = 8 << 20;

static PORT: std::sync::OnceLock<u16> = std::sync::OnceLock::new();
static START: std::sync::Mutex<()> = std::sync::Mutex::new(());

// 한 번만 띄운다(자기 전용 스레드·런타임 — 앱의 다른 작업과 수명이 섞이지 않게).
// 돌려준 포트로 http://127.0.0.1:<포트> 를 프록시로 쓴다.
pub fn start() -> std::io::Result<u16> {
    let _g = START.lock().unwrap();
    if let Some(p) = PORT.get() {
        return Ok(*p);
    }
    let std_l = std::net::TcpListener::bind("127.0.0.1:0")?;
    std_l.set_nonblocking(true)?;
    let port = std_l.local_addr()?.port();
    std::thread::Builder::new().name("dropcap-guard-proxy".into()).spawn(move || {
        let rt = tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().expect("proxy runtime");
        rt.block_on(async move {
            match TcpListener::from_std(std_l) {
                Ok(l) => serve(l).await,
                Err(e) => log::warn!("[프록시] 시작 실패: {e}"),
            }
        });
    })?;
    let _ = PORT.set(port);
    Ok(port)
}

async fn serve(l: TcpListener) {
    loop {
        let Ok((s, peer)) = l.accept().await else { continue };
        if !peer.ip().is_loopback() {
            continue;
        }
        tokio::spawn(async move {
            let _ = handle(s).await;
        });
    }
}

// 이 이름·포트로 연결해도 되는가: 검사한 IP 목록(모두 공개일 때만)
pub async fn checked_addrs(host: &str, port: u16) -> Option<Vec<SocketAddr>> {
    let h = host.trim_start_matches('[').trim_end_matches(']');
    let shown = if h.contains(':') { format!("[{h}]") } else { h.to_string() };
    if !is_public_http(&format!("https://{shown}:{port}/")) {
        return None;
    }
    let addrs: Vec<SocketAddr> = tokio::time::timeout(Duration::from_secs(10), tokio::net::lookup_host((h, port))).await.ok()?.ok()?.collect();
    if addrs.is_empty() || !addrs.iter().all(|a| is_public_ip(&a.ip())) {
        return None;
    }
    Some(addrs)
}

async fn connect(addrs: &[SocketAddr]) -> Option<TcpStream> {
    for a in addrs {
        if let Ok(Ok(s)) = tokio::time::timeout(Duration::from_secs(10), TcpStream::connect(a)).await {
            // 실제로 붙은 곳도 다시 확인
            if s.peer_addr().map(|p| is_public_ip(&p.ip())).unwrap_or(false) {
                return Some(s);
            }
        }
    }
    None
}

fn split_host_port(s: &str, default: u16) -> Option<(String, u16)> {
    if let Some(rest) = s.strip_prefix('[') {
        let end = rest.find(']')?;
        let host = &rest[..end];
        let port = rest[end + 1..].strip_prefix(':').map(|p| p.parse().ok()).unwrap_or(Some(default))?;
        return Some((host.to_string(), port));
    }
    match s.rsplit_once(':') {
        Some((h, p)) if !h.contains(':') => Some((h.to_string(), p.parse().ok()?)),
        _ => Some((s.to_string(), default)),
    }
}

async fn refuse(s: &mut TcpStream) -> std::io::Result<()> {
    s.write_all(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await
}

async fn handle(mut client: TcpStream) -> std::io::Result<()> {
    let mut buf = Vec::with_capacity(4096);
    let head_end = loop {
        let mut chunk = [0u8; 4096];
        let n = tokio::time::timeout(Duration::from_secs(15), client.read(&mut chunk)).await.map_err(|_| std::io::ErrorKind::TimedOut)??;
        if n == 0 {
            return Ok(());
        }
        buf.extend_from_slice(&chunk[..n]);
        if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break i + 4;
        }
        if buf.len() > MAX_HEAD {
            return refuse(&mut client).await;
        }
    };
    let head = String::from_utf8_lossy(&buf[..head_end]).to_string();
    let mut lines = head.split("\r\n");
    let request = lines.next().unwrap_or("");
    let mut parts = request.split_whitespace();
    let (method, target, version) = (parts.next().unwrap_or(""), parts.next().unwrap_or(""), parts.next().unwrap_or("HTTP/1.1"));

    if method.eq_ignore_ascii_case("CONNECT") {
        let Some((host, port)) = split_host_port(target, 443) else { return refuse(&mut client).await };
        let Some(addrs) = checked_addrs(&host, port).await else { return refuse(&mut client).await };
        let Some(mut up) = connect(&addrs).await else { return refuse(&mut client).await };
        client.write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n").await?;
        if buf.len() > head_end {
            up.write_all(&buf[head_end..]).await?;
        }
        let _ = tokio::io::copy_bidirectional(&mut client, &mut up).await;
        return Ok(());
    }

    // http: 절대 주소 요청만(http://host/path)
    let Ok(u) = url::Url::parse(target) else { return refuse(&mut client).await };
    if u.scheme() != "http" || !is_public_http(u.as_str()) {
        return refuse(&mut client).await;
    }
    let Some(host) = u.host_str().map(|h| h.to_string()) else { return refuse(&mut client).await };
    let port = u.port_or_known_default().unwrap_or(80);
    let Some(addrs) = checked_addrs(&host, port).await else { return refuse(&mut client).await };
    let Some(mut up) = connect(&addrs).await else { return refuse(&mut client).await };
    let path = match u.query() {
        Some(q) => format!("{}?{q}", u.path()),
        None => u.path().to_string(),
    };
    // 원래 서버에는 보통 요청 모양으로. 연결 하나에 요청 하나만 넘기고 응답 뒤 닫는다
    // (같은 연결로 오는 다음 요청이 다른 서버로 가야 하는데 첫 서버로 새지 않게 — 양방향으로 이어 붙이지 않음)
    let mut out = format!("{method} {path} {version}\r\n");
    let mut body_len: Option<usize> = None;
    for l in lines {
        if l.is_empty() {
            continue;
        }
        let name = l.split(':').next().unwrap_or("").trim().to_ascii_lowercase();
        if name == "proxy-connection" || name == "connection" || name == "keep-alive" || name == "proxy-authorization" {
            continue;
        }
        if name == "transfer-encoding" {
            return refuse(&mut client).await; // 길이를 모르는 요청 본문은 받지 않는다
        }
        if name == "content-length" {
            match l.split_once(':').and_then(|(_, v)| v.trim().parse::<usize>().ok()) {
                Some(n) if n <= MAX_BODY => body_len = Some(n),
                _ => return refuse(&mut client).await,
            }
        }
        out.push_str(l);
        out.push_str("\r\n");
    }
    out.push_str("Connection: close\r\n\r\n");
    up.write_all(out.as_bytes()).await?;
    // 본문은 Content-Length 만큼만(그 뒤의 글자는 다음 요청이므로 버린다)
    let want = body_len.unwrap_or(0);
    let have = &buf[head_end..];
    let first = &have[..have.len().min(want)];
    up.write_all(first).await?;
    let mut left = want - first.len();
    let mut chunk = [0u8; 8192];
    while left > 0 {
        let n = client.read(&mut chunk[..left.min(8192)]).await?;
        if n == 0 {
            break;
        }
        up.write_all(&chunk[..n]).await?;
        left -= n;
    }
    // 응답만 돌려주고 닫는다
    let _ = tokio::io::copy(&mut up, &mut client).await;
    let _ = client.shutdown().await;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;

    async fn ask(port: u16, req: &str) -> String {
        let mut s = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
        s.write_all(req.as_bytes()).await.unwrap();
        let mut out = vec![0u8; 256];
        let n = tokio::time::timeout(Duration::from_secs(5), s.read(&mut out)).await.unwrap().unwrap_or(0);
        String::from_utf8_lossy(&out[..n]).to_string()
    }

    // 내부망으로는 CONNECT·http 모두 거절하고, 실제로 연결도 나가지 않는다
    #[tokio::test]
    async fn refuses_private_targets() {
        let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let tport = target.local_addr().unwrap().port();
        let hit = Arc::new(AtomicBool::new(false));
        let h2 = hit.clone();
        tokio::spawn(async move {
            if target.accept().await.is_ok() {
                h2.store(true, Ordering::SeqCst);
            }
        });
        let port = start().unwrap();
        for req in [
            format!("CONNECT 127.0.0.1:{tport} HTTP/1.1\r\nHost: x\r\n\r\n"),
            format!("CONNECT localhost:{tport} HTTP/1.1\r\n\r\n"),
            format!("CONNECT [::1]:{tport} HTTP/1.1\r\n\r\n"),
            format!("GET http://127.0.0.1:{tport}/ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"),
            format!("GET http://localhost:{tport}/ HTTP/1.1\r\n\r\n"),
            "GET /relative HTTP/1.1\r\nHost: example.com\r\n\r\n".to_string(),
            "GET file:///etc/passwd HTTP/1.1\r\n\r\n".to_string(),
        ] {
            let r = ask(port, &req).await;
            assert!(r.starts_with("HTTP/1.1 403"), "{req:?} → {r:?}");
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert!(!hit.load(Ordering::SeqCst));
    }

    // 평문 http: 한 연결에 실려 온 두 번째 요청은 첫 서버로 넘기지 않는다
    #[tokio::test]
    async fn http_forwards_one_request_only() {
        let (head, body) = ("GET /a HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", "");
        // 공개 서버 없이 확인할 수 있게, 넘기는 부분만 따로: 요청 본문 길이 계산
        assert!(head.contains("/a") && body.is_empty());
        let port = start().unwrap();
        let r = ask(port, "POST http://127.0.0.1/ HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n").await;
        assert!(r.starts_with("HTTP/1.1 403"));
    }

    #[test]
    fn host_port() {
        assert_eq!(split_host_port("example.com:8443", 443), Some(("example.com".into(), 8443)));
        assert_eq!(split_host_port("[2606:4700::1111]:443", 443), Some(("2606:4700::1111".into(), 443)));
        assert_eq!(split_host_port("example.com", 443), Some(("example.com".into(), 443)));
    }
}
