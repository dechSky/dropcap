// 실제 네트워크 시험. 바깥 서버 상태에 따라 흔들리므로 DROPCAP_LIVE_TESTS=1 일 때만 돈다(맥 LiveFeedTests·ChannelTests·URLSafetyDNSTests).
use dropcap_core::channels::{self, CATALOG};
use dropcap_core::feed_service::SHARED as FEEDS;
use dropcap_core::models::{resources, ItemKind};
use dropcap_core::url_safety::resolves_public;

fn live() -> bool {
    std::env::var("DROPCAP_LIVE_TESTS").as_deref() == Ok("1")
}

#[tokio::test]
async fn default_sources_load() {
    if !live() {
        return;
    }
    let mut failures = vec![];
    for src in resources::CONFIG.sources.iter().filter(|s| s.default_on) {
        match FEEDS.items(src, false).await {
            Ok(Some(items)) if !items.is_empty() => {}
            Ok(_) => failures.push(format!("{}: 0건", src.id)),
            Err(e) => failures.push(format!("{}: {e}", src.id)),
        }
    }
    assert!(failures.is_empty(), "{failures:?}");
}

#[tokio::test]
async fn resolves_channels() {
    if !live() {
        return;
    }
    for (input, kind) in [
        ("cs.CL", ItemKind::Paper),
        ("https://github.com/ollama/ollama", ItemKind::Release),
        ("https://www.youtube.com/@TwoMinutePapers", ItemKind::Video),
        ("simonwillison.net", ItemKind::Article),
        ("https://www.latent.space", ItemKind::Article),
    ] {
        let f = channels::resolve(input).await.unwrap_or_else(|e| panic!("{input}: {e}"));
        assert_eq!(f.kind, kind, "{input} → {}", f.feed_url);
        assert!(f.feed_url.starts_with("https://"));
    }
}

#[tokio::test]
async fn rejects_private() {
    if !live() {
        return;
    }
    assert!(channels::resolve("http://192.168.0.1/feed").await.is_err());
}

#[tokio::test]
async fn catalog_feeds_load() {
    if !live() {
        return;
    }
    let mut bad = vec![];
    for s in CATALOG.iter().filter(|s| !s.url.contains("reddit.com")) {
        match FEEDS.items(s, false).await {
            Ok(Some(i)) if !i.is_empty() || s.kind.as_deref() == Some("paper") => {}
            Ok(_) => bad.push(format!("{}: 0건", s.name)),
            Err(e) => bad.push(format!("{}: {e}", s.name)),
        }
    }
    assert!(bad.is_empty(), "{bad:?}");
}

#[tokio::test]
async fn name_resolving_to_loopback_is_blocked() {
    if !live() {
        return;
    }
    assert!(!resolves_public("http://127.0.0.1.nip.io/").await);
    assert!(!resolves_public("http://localtest.me/").await);
    assert!(resolves_public("https://openai.com/").await);
}

// 접속 순간 검사: 공개처럼 보이는 이름이 127.0.0.1 로 풀려도 연결 자체가 나가지 않는다
#[tokio::test]
async fn dns_rebinding_name_never_connects() {
    if !live() {
        return;
    }
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let hit = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let h2 = hit.clone();
    tokio::spawn(async move {
        if listener.accept().await.is_ok() {
            h2.store(true, std::sync::atomic::Ordering::SeqCst);
        }
    });
    let r = dropcap_core::net::CLIENT.get(format!("http://localtest.me:{port}/")).send().await;
    assert!(r.is_err());
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    assert!(!hit.load(std::sync::atomic::Ordering::SeqCst));
}

#[tokio::test]
async fn google_translate_works() {
    if !live() {
        return;
    }
    let out = dropcap_core::translator::SHARED.translate_many(&["Hello world".to_string(), "Good morning".to_string()]).await;
    assert!(out.iter().all(|t| !dropcap_core::translator::looks_foreign(t)), "{out:?}");
}
