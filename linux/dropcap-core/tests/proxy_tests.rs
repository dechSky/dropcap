// 맥 기존 동작과 같음: 시스템 프록시가 있어도 보내기 전에 앱이 이름을 풀어 공개 대역이 아니면 막는다.
// 출처 밖 주소(사진 CDN·기사·번역)는 그대로 프록시로 보낸다. 프록시가 이름을 다시 푸는 남은 위험은 받아들임(PROGRESS).
// 환경 변수가 프로세스 전체에 걸리므로 이 파일에는 시험을 하나만 둔다. 이름 풀기가 안 되는 곳(오프라인)에서는 건너뛴다.
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

async fn resolves(host: &str) -> bool {
    tokio::time::timeout(Duration::from_secs(5), tokio::net::lookup_host((host, 80))).await.map(|r| r.is_ok()).unwrap_or(false)
}

#[tokio::test]
async fn proxy_mode_still_checks_names_before_sending() {
    let source_host = url::Url::parse(&dropcap_core::models::resources::CONFIG.sources.iter().find(|s| s.url.starts_with("http://") || s.url.starts_with("https://")).unwrap().url)
        .unwrap()
        .host_str()
        .unwrap()
        .to_string();
    if !resolves("example.com").await || !resolves(&source_host).await {
        eprintln!("이름 풀기가 안 돼 건너뜀");
        return;
    }
    // 가짜 프록시: 받은 요청의 첫 줄을 적고 200 으로 답한다
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let seen: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(vec![]));
    let s2 = seen.clone();
    tokio::spawn(async move {
        loop {
            let Ok((mut c, _)) = l.accept().await else { return };
            let mut buf = vec![0u8; 4096];
            let n = c.read(&mut buf).await.unwrap_or(0);
            let line = String::from_utf8_lossy(&buf[..n]).lines().next().unwrap_or("").to_string();
            s2.lock().unwrap().push(line);
            let _ = c.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok").await;
        }
    });
    for k in ["HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy", "NO_PROXY", "no_proxy"] {
        std::env::remove_var(k);
    }
    std::env::set_var("HTTP_PROXY", format!("http://127.0.0.1:{port}"));
    std::env::set_var("http_proxy", format!("http://127.0.0.1:{port}"));

    // 내부망으로 풀리는 이름: 프록시로도 보내지 않는다(연결 전 이름 확인)
    if resolves("localtest.me").await {
        let r = tokio::time::timeout(Duration::from_secs(8), dropcap_core::net::get("http://localtest.me/dropcap-proxy-check", &[], 1 << 16)).await;
        assert!(matches!(r, Ok(Err(dropcap_core::net::FeedError::Blocked(_)))), "{:?}", r.as_ref().map(|x| x.as_ref().map(|f| f.status)));
        assert!(!seen.lock().unwrap().iter().any(|l| l.contains("localtest.me")), "내부망 이름이 프록시로 나감: {:?}", seen.lock().unwrap());
    }
    // 출처 밖 공개 주소도 프록시로(사진 CDN·기사·번역이 막히지 않게)
    let r = tokio::time::timeout(Duration::from_secs(8), dropcap_core::net::get("http://example.com/dropcap-proxy-check", &[], 1 << 16)).await;
    assert!(seen.lock().unwrap().iter().any(|l| l.contains("example.com")), "공개 주소가 프록시를 거치지 않음: {:?}", seen.lock().unwrap());
    assert_eq!(r.unwrap().unwrap().data, b"ok");
    // 출처 피드도 프록시로
    let r = tokio::time::timeout(Duration::from_secs(8), dropcap_core::net::get(&format!("http://{source_host}/dropcap-proxy-check"), &[], 1 << 16)).await;
    assert!(seen.lock().unwrap().iter().any(|l| l.contains(&source_host)), "출처 도메인이 프록시를 거치지 않음: {:?}", seen.lock().unwrap());
    assert_eq!(r.unwrap().unwrap().data, b"ok");
}
