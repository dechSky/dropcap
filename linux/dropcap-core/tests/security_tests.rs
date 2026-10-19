// 보안 점검 리눅스 항목 재현·고침 시험
use dropcap_core::url_safety::is_public_http;

#[test]
fn hex_ip_spellings_are_rejected() {
    for u in ["http://0x7f.0.0.0xa/", "http://0x7f.1/", "http://0xa.0.0.1/x", "http://0x7f.0x0.0x0.0x1/", "http://10.0.0.0xa/"] {
        assert!(!is_public_http(u), "{u}");
    }
    assert!(is_public_http("https://0xabc.example.com/"));
}

use dropcap_core::backup;
use dropcap_core::store::Settings;

// 상태 파일·가져온 기록의 범위 밖 수치(Int.max 간격은 곱셈 넘침·0 은 쉬지 않고 받기)
#[test]
fn settings_are_clamped_when_read() {
    let s: Settings = serde_json::from_str(r#"{"intervalMinutes":9223372036854775807,"quietStart":99,"digestHour":-3,"totalDailyCap":0,"bigThreshold":1000}"#).unwrap();
    assert_eq!(s.interval_minutes, 1440);
    assert_eq!(s.quiet_start, 23);
    assert_eq!(s.digest_hour, 0);
    assert_eq!(s.total_daily_cap, 1);
    assert_eq!(s.big_threshold, 20);
    let z: Settings = serde_json::from_str(r#"{"intervalMinutes":0}"#).unwrap();
    assert_eq!(z.interval_minutes, 1);
}

fn backup_json(extra: &str) -> Vec<u8> {
    format!(r#"{{"format":"dropcap-backup","version":1{extra}}}"#).into_bytes()
}

#[test]
fn imported_backup_is_sanitized() {
    let b = backup::decode(&backup_json(r##","settings":{"intervalMinutes":7,"digestHour":2,"mustKeywords":["  a ","A","","xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"]},
      "customSources":[
        {"id":"custom-ok","name":"OK","tier":"press","type":"sitemap","url":"https://ok.example/feed","match":"^(a+)+$","aiOnly":true,"defaultOn":true,"color":"red; } * { background: url(http://10.0.0.1/x) "},
        {"id":"openai","name":"가짜 기본 출처","tier":"lab","type":"feed","url":"https://evil.example/feed","aiOnly":false,"defaultOn":true,"color":"#000"},
        {"id":"custom-local","name":"내부","tier":"press","type":"feed","url":"http://192.168.0.1/feed","aiOnly":false,"defaultOn":true,"color":"#000"}],
      "sectionPolicy":{"economy":{"mode":"bundle","bundleHour":99,"dailyCap":0},"nope":{"mode":"bundle","bundleHour":9,"dailyCap":3}},
      "sectionsChosen":["economy","nope","economy"],
      "saved":[{"id":"1","title":"t","link":"https://ok.example/1","sourceId":"s","sourceName":"S","summary":"","tier":"press"},
               {"id":"2","title":"t","link":"javascript:alert(1)","sourceId":"s","sourceName":"S","summary":"","tier":"press"}],
      "scraps":[{"id":"x","item":{"id":"1","title":"t","link":"https://ok.example/1","sourceId":"s","sourceName":"S","summary":"","tier":"press"},"memo":"","collection":"아주 긴 폴더 이름 아주 긴 폴더 이름 아주 긴 폴더 이름 아주 긴 폴더 이름 아주 긴 폴더 이름 아주 긴 폴더 이름 아주 긴 폴더 이름 아주 긴 폴더 이름 ","created":"2027-01-01T00:00:00Z"}],
      "scrapFolders":["보고서"," ","보고서"]"##))
    .unwrap();
    assert_eq!(b.settings.interval_minutes, 5); // 고를 수 있는 값이 아니면 기본
    assert_eq!(b.settings.digest_hour, 5);
    assert_eq!(b.settings.must_keywords, vec!["a".to_string()]);
    assert_eq!(b.custom_sources.len(), 1);
    let c = &b.custom_sources[0];
    assert_eq!(c.id, "custom-ok");
    assert_eq!(c.color, "#3B82F6"); // CSS 에 그대로 들어가지 않게
    assert!(c.match_.is_none() && c.kind_type == "feed" && !c.ai_only);
    assert_eq!(b.section_policy.len(), 1);
    assert_eq!((b.section_policy["economy"].bundle_hour, b.section_policy["economy"].daily_cap), (23, 1));
    assert_eq!(b.sections_chosen, Some(vec!["economy".to_string()]));
    assert_eq!(b.saved.len(), 1);
    assert_eq!(b.scraps[0].collection, "스크랩");
    assert_eq!(b.scrap_folders, vec!["보고서".to_string()]);
}

#[test]
fn oversized_backup_file_is_refused() {
    let d = tempfile::tempdir().unwrap();
    let f = d.path().join("big.json");
    let file = std::fs::File::create(&f).unwrap();
    file.set_len((backup::MAX_FILE_BYTES + 1) as u64).unwrap(); // 실제로 쓰지 않고 크기만
    assert_eq!(backup::read_file(&f), Err(backup::Failure::TooLarge));
    assert!(backup::Failure::TooLarge.to_string().contains("50MB"));
}

// 사이트맵 정규식은 앱에 든 기본 출처(같은 id·같은 정규식)의 것만
#[test]
fn sitemap_pattern_only_from_bundled_sources() {
    use dropcap_core::feed_service::sitemap_pattern;
    use dropcap_core::models::resources;
    let bundled = resources::CONFIG.sources.iter().find(|s| s.is_sitemap() && s.match_.is_some()).cloned().expect("기본 사이트맵 출처");
    assert_eq!(sitemap_pattern(&bundled).as_deref(), bundled.match_.as_deref());
    let mut forged = bundled.clone();
    forged.match_ = Some("^(a+)+$".into());
    assert_eq!(sitemap_pattern(&forged), None);
    let mut custom = bundled.clone();
    custom.id = "custom-x".into();
    assert_eq!(sitemap_pattern(&custom), None);
}

// 숨은 웹 보기는 보여 줄 수 없는 응답·첨부를 들이지 않는다(내려받기로 바뀌지 않게)
#[test]
fn web_view_refuses_downloads() {
    use dropcap_core::url_safety::web_response_allowed;
    assert!(web_response_allowed(true, None));
    assert!(web_response_allowed(true, Some("inline")));
    assert!(!web_response_allowed(true, Some("attachment; filename=x.desktop")));
    assert!(!web_response_allowed(true, Some(" Attachment")));
    assert!(!web_response_allowed(false, None));
}

// 사진 크기 폭탄 — 가로·세로가 8192 를 넘으면 풀지 않는다
#[test]
fn huge_image_dimensions_are_refused() {
    let mut png = Vec::new();
    image::DynamicImage::new_luma8(8300, 1).write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png).unwrap();
    assert!(dropcap_core::images::shrink(&png).is_none());
    let mut ok = Vec::new();
    image::DynamicImage::new_rgb8(800, 600).write_to(&mut std::io::Cursor::new(&mut ok), image::ImageFormat::Png).unwrap();
    assert!(dropcap_core::images::shrink(&ok).is_some());
}

// 데이터 폴더 0700 · 파일 0600
#[cfg(unix)]
#[test]
fn data_files_are_private() {
    use std::os::unix::fs::PermissionsExt;
    let d = tempfile::tempdir().unwrap();
    let dir = d.path().join("data");
    let store = dropcap_core::store::Store::new(dir.clone());
    store.save(&Default::default());
    assert_eq!(std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777, 0o700);
    assert_eq!(std::fs::metadata(store.file()).unwrap().permissions().mode() & 0o777, 0o600);
    let f = dir.join("x.json");
    dropcap_core::store::write_atomic(&f, b"{}").unwrap();
    assert_eq!(std::fs::metadata(&f).unwrap().permissions().mode() & 0o777, 0o600);
}

// 특수 대역(문서용·Teredo·폐기·로컬 NAT64 등)
#[test]
fn special_ranges_are_not_public() {
    use dropcap_core::url_safety::{parse_v4, parse_v6, is_public_v4, is_public_v6};
    for a in ["192.0.2.1", "198.51.100.7", "203.0.113.9"] {
        assert!(!is_public_v4(&parse_v4(a).unwrap()), "{a}");
    }
    for a in ["2001:db8::1", "2001::1", "100::1", "64:ff9b:1::a00:1", "3fff::1"] {
        assert!(!is_public_v6(&parse_v6(a).unwrap()), "{a}");
    }
    assert!(is_public_v6(&parse_v6("2606:4700::1111").unwrap()));
    assert!(is_public_v4(&parse_v4("8.8.8.8").unwrap()));
}

// Ollama 의 원격(클라우드) 모델은 이름이 아니라 목록의 원격 표시로도 거른다
#[test]
fn ollama_remote_models_are_skipped() {
    let tags = serde_json::json!({"models":[
        {"name":"mystery:latest","remote_model":"gpt-oss:120b","remote_host":"https://ollama.com:443"},
        {"name":"nomic-embed-text:latest"},
        {"name":"qwen2.5:7b"}]});
    assert_eq!(dropcap_core::summarizer::pick_local(&tags, None).as_deref(), Some("qwen2.5:7b"));
    assert_eq!(dropcap_core::summarizer::pick_local(&tags, Some("mystery")), None);
}

// ── 깊게 겹친 상자 ──
use dropcap_core::article::extract_html;
use dropcap_core::reader_extract::{gather, pre_clean, rough_depth, MAX_PARSE_DEPTH};
use std::time::{Duration, Instant};

const LONG: &str = "This is a fairly long paragraph of article text that should exceed eighty characters easily, yes indeed.";
fn long_ps(n: usize) -> String {
    (0..n).map(|i| format!("<p>{i} {LONG}</p>")).collect()
}
// spawn_blocking 과 같은 2MB 스택의 스레드에서
fn on_2mb<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> T {
    std::thread::Builder::new().stack_size(2 << 20).spawn(f).unwrap().join().unwrap()
}

// 깊게 겹친 인라인·div 에서 재귀가 스택을 넘어 프로세스가 죽던 것(span 8,000겹: 고치기 전 abort)
#[test]
fn deep_nesting_does_not_overflow_the_stack() {
    for n in [8000usize, 15000] {
        let span = format!("<html><body><article>{}<p>{}x{}</p></article></body></html>", long_ps(10), "<span>".repeat(n), "</span>".repeat(n));
        let a = on_2mb(move || extract_html(&span, "https://ex.com/a"));
        assert!(a.is_some_and(|a| a.blocks.len() >= 10), "span {n}");
    }
    let div = format!("<html><body><article>{}{}{}</article></body></html>", "<div>".repeat(8000), long_ps(10), "</div>".repeat(8000));
    assert!(on_2mb(move || extract_html(&div, "https://ex.com/a")).is_some(), "div 8000");
}

// html5ever 는 겹친 div 파싱이 깊이²라, 대략 센 깊이가 상한을 넘으면 파싱하지 않는다
#[test]
fn absurd_div_nesting_is_refused_quickly() {
    assert!(rough_depth(&format!("<html><body>{}</body></html>", long_ps(50))) < 10);
    // 닫지 않는 p·li·br·img, 주석·script 안의 '<' 는 세지 않는다
    let page = format!("<div><ul>{}</ul><script>for(i=0;i<n;i++){{}}</script><!-- <div> -->{}</div>", "<li>x".repeat(50_000), "<p>y<br><img src=a>".repeat(50_000));
    assert!(rough_depth(&page) <= 3, "{}", rough_depth(&page));
    // 짝 없는 닫는 표지(</p>·</span>)로 깊이를 줄여 피하지 못한다
    assert!(rough_depth(&"<div></p></span>".repeat(30_000)) >= 30_000);
    assert_eq!(rough_depth("<script>a</script><style>b</style><div><div></div></div>"), 2);
    let n = MAX_PARSE_DEPTH + 1000;
    let deep = format!("<html><body>{}{}{}</body></html>", "<div>".repeat(n), long_ps(10), "</div>".repeat(n));
    let t = Instant::now();
    assert!(on_2mb(move || extract_html(&deep, "https://ex.com/a")).is_none());
    assert!(t.elapsed() < Duration::from_secs(1));
}

// 형제 상자 안에 본문 상자와 같은 class 가 N겹 — 겹마다 하위 전체를 복사해 N²(2,000겹 60초+)
#[test]
fn nested_core_class_is_gathered_once() {
    let n = 2000;
    let html = format!(
        "<html><head><title>t</title></head><body><div id=w><div class=\"x\">{}</div><section class=\"y\">{}<p>{LONG}</p>{}</section></div></body></html>",
        long_ps(8), "<div class=\"x\">t ".repeat(n), "</div>".repeat(n));
    let t = Instant::now();
    let a = on_2mb(move || extract_html(&html, "https://ex.com/a")).expect("본문");
    assert!(t.elapsed() < Duration::from_secs(3), "{:?}", t.elapsed());
    assert!(a.blocks.len() <= 20);
    // gather 만(깊이 손질 없이)도 바깥 상자 한 벌만
    let html = format!("<html><body><div id=w><div class=\"x\">{}</div><section class=\"y\">{}<p>{LONG}</p>{}</section></div></body></html>", long_ps(5), "<div class=\"x\">t ".repeat(n), "</div>".repeat(n));
    let d = dom_query::Document::from(html.as_str());
    let (c, _) = gather(&format!("<div>{}</div>", long_ps(5)), &d);
    assert!(c.len() < html.len() * 2, "{} vs {}", c.len(), html.len());
}

// 겹친 군더더기 상자마다 하위 글을 세던 것(N²) — 바깥 상자를 지우면 그 안은 건너뛴다
#[test]
fn nested_junk_boxes_are_cleaned_once() {
    let html = format!("<html><body>{}{}z{}</body></html>", long_ps(2000), "<div class=\"author-box\">ab ".repeat(20000), "</div>".repeat(20000));
    let d = dom_query::Document::from(html.as_str());
    let t = Instant::now();
    pre_clean(&d);
    assert!(t.elapsed() < Duration::from_secs(2), "{:?}", t.elapsed());
    assert_eq!(d.select(".author-box").length(), 0);
    assert_eq!(d.select("p").length(), 2000);
}
