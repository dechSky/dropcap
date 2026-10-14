// WebKitGTK 6 로 본문 추리기(webkit 기능 · 맥 Reader/ArticleExtractor.swift 와 같은 방식).
// 1) 빠른 길(R-01): 핵심이 받은 HTML 을 스크립트를 끈 웹 보기에 base 주소와 함께 넣고, 맥과 같은 Readability.js 로 추린다.
//    그림·동영상·글꼴·스타일·스크립트 등은 내용 차단 규칙으로 아예 받지 않는다(S-06·S-10).
// 2) 느린 길(R-02): 사용자가 연 기사만, 스크립트를 켠 웹 보기로 실제로 띄워 0.6초 뒤부터 0.4초마다 추리고 두 번 같으면 끝(최대 15초).
// 추출 스크립트는 페이지와 떨어진 world("dropcap")에서 돈다 — 페이지 스크립트가 건드리지 못한다(S-11).
// 웹 보기 안의 이동은 about:·data: 외에는 url_safety::resolves_public 을 통과해야 한다(S-05, 비동기 판단).
// 그와 별도로 웹 보기의 모든 요청은 핵심의 guard_proxy 를 거쳐, 하위 요청·DNS 바꿔치기도 연결 순간에 막힌다.
// 핵심(tokio 스레드)의 Extract 호출은 메인 루프로 넘겨 처리하고 결과만 돌려준다(WebKit 은 메인 스레드 전용).
use crate::app::{bg, resource, ui};
use dropcap_core::article::{Article, Extract};
use gtk::glib;
use gtk::prelude::*;
use std::cell::RefCell;
use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::time::{Duration, Instant};
use webkit6::prelude::*;

const WORLD: &str = "dropcap";
const UA: &str = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15";

const FAST_BLOCK: [&str; 11] = ["image", "media", "font", "style-sheet", "script", "raw", "svg-document", "popup", "fetch", "websocket", "other"];
const SLOW_BLOCK: [&str; 5] = ["image", "media", "font", "popup", "websocket"];

// 맥 ArticleExtractor.script 와 같은 추출 스크립트
const SCRIPT: &str = r#"(() => {
  const doc = document.cloneNode(true);
  doc.querySelectorAll('.sr-only, .visually-hidden, .screen-reader-text, [class*="sr-only"], [class*="visually-hidden"]').forEach((n) => n.remove());
  const art = new Readability(doc).parse();
  if (!art || !art.content) return null;
  const box = new DOMParser().parseFromString(art.content, 'text/html').body;
  const blocks = [];
  const abs = (u) => { try { const h = new URL(u, location.href).href; return /^https?:/.test(h) ? h : null; } catch { return null; } };
  const bestSrc = (img) => {
    if (!img) return null;
    const cands = [];
    const fromSet = (v) => (v || '').split(',').map(x => x.trim().split(/\s+/)).forEach(([u, d]) => {
      if (u) cands.push([u, parseFloat(d) || (d && d.endsWith('x') ? parseFloat(d) * 1000 : 1)]);
    });
    fromSet(img.getAttribute('srcset')); fromSet(img.getAttribute('data-srcset'));
    const pic = img.closest('picture');
    if (pic) pic.querySelectorAll('source').forEach(s => fromSet(s.getAttribute('srcset') || s.getAttribute('data-srcset')));
    cands.sort((a, b) => b[1] - a[1]);
    for (const [u] of cands) { const h = abs(u); if (h) return h; }
    for (const a of ['data-src', 'data-lazy-src', 'data-original', 'data-url', 'src']) {
      const v = img.getAttribute(a);
      if (v && !v.startsWith('data:')) { const h = abs(v); if (h && !/(1x1|spacer|blank|pixel)\.(gif|png)/i.test(h)) return h; }
    }
    return null;
  };
  const clean = (s) => (s || '').replace(/\((opens in a new (window|tab)|새 창에서 열기)\)/gi, '').replace(/\s+/g, ' ').trim();
  const walk = (el) => {
    for (const n of el.children) {
      const tag = n.tagName.toLowerCase();
      const t = clean(n.textContent);
      if (/^h[1-6]$/.test(tag)) { if (t) blocks.push({ type: 'h', text: t }); }
      else if (tag === 'p') {
        const img = n.querySelector('img'); const src = bestSrc(img);
        if (t) blocks.push({ type: 'p', text: t });
        if (src) blocks.push({ type: 'img', src });
      }
      else if (tag === 'li') { if (t) blocks.push({ type: 'li', text: t }); }
      else if (tag === 'blockquote') { if (t) blocks.push({ type: 'quote', text: t }); }
      else if (tag === 'pre') { if (t) blocks.push({ type: 'pre', text: n.textContent }); }
      else if (tag === 'img') { const s = bestSrc(n); if (s) blocks.push({ type: 'img', src: s }); }
      else if (tag === 'picture') { const s = bestSrc(n.querySelector('img')); if (s) blocks.push({ type: 'img', src: s }); }
      else if (tag === 'figure') {
        const s = bestSrc(n.querySelector('img'));
        if (s) blocks.push({ type: 'img', src: s });
        const cap = n.querySelector('figcaption'); const c = cap && clean(cap.textContent);
        if (c) blocks.push({ type: 'cap', text: c });
      }
      else walk(n);
    }
  };
  walk(box);
  return JSON.stringify({ title: art.title, byline: art.byline, siteName: art.siteName, blocks });
})();"#;

thread_local! {
    static READABILITY: String = std::fs::read_to_string(resource("Readability.js")).unwrap_or_default();
    static FILTERS: RefCell<HashMap<&'static str, webkit6::UserContentFilter>> = RefCell::new(HashMap::new());
}

type Fut = Pin<Box<dyn Future<Output = Option<Article>> + Send>>;

struct WebExtract;

// 메인 루프에서 f 를 돌리고 결과를 tokio 쪽으로
fn on_main<F, R>(f: F) -> Fut
where
    F: FnOnce() -> R + Send + 'static,
    R: Future<Output = Option<Article>> + 'static,
{
    let (tx, rx) = tokio::sync::oneshot::channel();
    glib::MainContext::default().invoke(move || {
        let fut = f();
        glib::spawn_future_local(async move {
            let _ = tx.send(fut.await);
        });
    });
    Box::pin(async move { rx.await.ok().flatten() })
}

impl Extract for WebExtract {
    fn fast(&self, html: String, base: String) -> Fut {
        on_main(move || run_fast(html, base))
    }
    fn slow(&self, url: String) -> Fut {
        on_main(move || run_slow(url))
    }
}

// 웹 보기의 모든 요청이 거치는 안전 검사 프록시의 포트(못 띄우면 웹 엔진을 쓰지 않음 — fail closed)
static PROXY_PORT: std::sync::OnceLock<u16> = std::sync::OnceLock::new();

pub fn install() {
    let ui = ui();
    match dropcap_core::guard_proxy::start() {
        Ok(port) => {
            let _ = PROXY_PORT.set(port);
            ui.core.articles.set_extractor(Arc::new(WebExtract));
        }
        Err(e) => log::warn!("[기사] 안전 검사 프록시를 띄우지 못해 웹 엔진 추출을 끔: {e}"),
    }
}

// 차단 규칙(맥 WKContentRuleList 와 같은 JSON). 한 번 만들면 이번 실행 동안 다시 쓴다.
async fn filter(id: &'static str, types: &[&str]) -> Option<webkit6::UserContentFilter> {
    if let Some(f) = FILTERS.with(|m| m.borrow().get(id).cloned()) {
        return Some(f);
    }
    let rule = serde_json::json!([{ "trigger": { "url-filter": ".*", "resource-type": types }, "action": { "type": "block" } }]);
    let dir = ui().core.store.dir.join("webkit-filters");
    let _ = std::fs::create_dir_all(&dir);
    let store = webkit6::UserContentFilterStore::new(&dir.to_string_lossy());
    match store.save_future(id, &glib::Bytes::from_owned(rule.to_string().into_bytes())).await {
        Ok(f) => {
            FILTERS.with(|m| m.borrow_mut().insert(id, f.clone()));
            Some(f)
        }
        Err(e) => {
            log::warn!("[기사] 차단 규칙을 만들지 못함: {e}");
            None
        }
    }
}

struct Web {
    view: webkit6::WebView,
    holder: gtk::Window,
}

impl Drop for Web {
    fn drop(&mut self) {
        self.view.stop_loading();
        self.holder.destroy();
    }
}

async fn make_web(js: bool, block: &[&str], id: &'static str) -> Option<Web> {
    let settings = webkit6::Settings::new();
    settings.set_enable_javascript(true); // 앱이 넣는 추출 스크립트는 돈다
    settings.set_enable_javascript_markup(js); // 꺼지면 페이지 자신의 스크립트는 돌지 않음
    settings.set_auto_load_images(false);
    settings.set_enable_media(false);
    settings.set_enable_webaudio(false);
    settings.set_media_playback_requires_user_gesture(true);
    settings.set_user_agent(Some(UA));
    let ucm = webkit6::UserContentManager::new();
    // 차단 규칙이 없으면 빠른 길은 쓰지 않는다(그림·스크립트를 받지 않는다는 약속을 지킬 수 없으므로)
    match filter(id, block).await {
        Some(f) => ucm.add_filter(&f),
        None if !js => return None,
        None => {}
    }
    // 모든 요청(이동·하위 요청·fetch·iframe)을 안전 검사 프록시로: 접속 순간 IP 검사(S-03·S-05)
    let port = *PROXY_PORT.get()?;
    let session = webkit6::NetworkSession::new_ephemeral();
    let proxy = webkit6::NetworkProxySettings::new(Some(&format!("http://127.0.0.1:{port}")), &[]);
    session.set_proxy_settings(webkit6::NetworkProxyMode::Custom, Some(&proxy));
    let view = webkit6::WebView::builder().settings(&settings).user_content_manager(&ucm).network_session(&session).build();
    view.set_size_request(1200, 900);
    // 이동 검사(S-05): 결정을 붙잡아 두고 이름 풀기까지 마친 뒤 허락·거절
    view.connect_decide_policy(|_, decision, kind| match kind {
        webkit6::PolicyDecisionType::NewWindowAction => {
            decision.ignore(); // 새 창(팝업)은 열지 않음
            true
        }
        webkit6::PolicyDecisionType::NavigationAction => {
            let uri = decision
                .downcast_ref::<webkit6::NavigationPolicyDecision>()
                .and_then(|d| d.navigation_action())
                .and_then(|a| a.request())
                .and_then(|r| r.uri())
                .map(|u| u.to_string())
                .unwrap_or_default();
            if uri.starts_with("about:") || uri.starts_with("data:") {
                decision.use_();
                return true;
            }
            if !dropcap_core::url_safety::is_public_http(&uri) {
                decision.ignore();
                return true;
            }
            let d = decision.clone();
            bg(async move { dropcap_core::url_safety::resolves_public(&uri).await }, move |ok| if ok { d.use_() } else { d.ignore() });
            true
        }
        _ => false,
    });
    let holder = gtk::Window::new();
    holder.set_default_size(1200, 900);
    holder.set_child(Some(&view));
    Some(Web { view, holder })
}

// 다 뜨기(또는 실패)를 기다린다. 최대 secs 초.
async fn wait_for_load(view: &webkit6::WebView, secs: u64) {
    let (tx, rx) = async_channel::bounded::<()>(2);
    let t1 = tx.clone();
    let h1 = view.connect_load_changed(move |_, ev| {
        if ev == webkit6::LoadEvent::Finished {
            let _ = t1.try_send(());
        }
    });
    let h2 = view.connect_load_failed(move |_, _, _, _| {
        let _ = tx.try_send(());
        false
    });
    let _ = glib::future_with_timeout(Duration::from_secs(secs), rx.recv()).await;
    view.disconnect(h1);
    view.disconnect(h2);
}

// 앱이 가진 고정 스크립트(Readability.js·추출 스크립트)만 떨어진 world 에서 돌린다 — 페이지에서 온 글자를 코드로 돌리지 않음
async fn eval(view: &webkit6::WebView, script: &str) -> Option<webkit6::javascriptcore::Value> {
    let (tx, rx) = async_channel::bounded(1);
    view.evaluate_javascript(script, Some(WORLD), None, None::<&gtk::gio::Cancellable>, move |r| {
        let _ = tx.try_send(r.ok());
    });
    glib::future_with_timeout(Duration::from_secs(5), rx.recv()).await.ok()?.ok()?
}

// 페이지와 떨어진 world 에서: Readability 는 한 번만 넣고, 이후엔 짧은 추출 스크립트만 다시 돌린다
async fn try_extract(view: &webkit6::WebView) -> Option<Article> {
    let loaded = eval(view, "typeof Readability !== 'undefined'").await.map(|v| v.is_boolean() && v.to_boolean()).unwrap_or(false);
    if !loaded {
        let src = READABILITY.with(|r| r.clone());
        if src.is_empty() {
            return None;
        }
        eval(view, &format!("{src}\n;true")).await;
    }
    let v = eval(view, SCRIPT).await?;
    if !v.is_string() {
        return None;
    }
    let art: Article = serde_json::from_str(&v.to_str()).ok()?;
    art.acceptable().then_some(art)
}

async fn run_fast(html: String, base: String) -> Option<Article> {
    let web = make_web(false, &FAST_BLOCK, "dropcap-fast").await?;
    web.view.load_html(&html, Some(&base));
    wait_for_load(&web.view, 6).await;
    try_extract(&web.view).await
}

async fn run_slow(url: String) -> Option<Article> {
    if !dropcap_core::url_safety::is_public_http(&url) {
        return None;
    }
    let web = make_web(true, &SLOW_BLOCK, "dropcap-full").await?;
    web.view.load_uri(&url);
    // 다 뜨기를 기다리지 않고, 0.6초 뒤부터 0.4초마다 본문이 생겼는지 본다(최대 15초)
    let deadline = Instant::now() + Duration::from_secs(15);
    glib::timeout_future(Duration::from_millis(600)).await;
    let mut last = 0usize;
    while Instant::now() < deadline {
        if let Some(art) = try_extract(&web.view).await {
            let n = art.blocks.len();
            if n >= 4 && n == last {
                return Some(art); // 두 번 연속 같으면 다 그려진 것
            }
            last = n;
        }
        glib::timeout_future(Duration::from_millis(400)).await;
    }
    try_extract(&web.view).await
}
