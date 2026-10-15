// 맥 ReaderSaveTests(SaveLinkParse·ScrapExportFile) · IntegrationTests(WidgetLink·IntentLogic·Spotlight) · SecurityTests 일부를 옮긴 것.
// 바깥 서버 없이 돈다.
use chrono::{Duration, TimeZone, Utc};
use dropcap_core::category::NewsCategory;
use dropcap_core::models::NewsItem;
use dropcap_core::save_link::{self as sl, Head};
use dropcap_core::scrap_export::{self as se, Config};
use dropcap_core::scrapbook::Scrap;
use dropcap_core::search_index as si;
use dropcap_core::url_router::{self as ur, Cli, Route, SectionChoice};

// MARK: 아무 주소 저장(I-05)

#[test]
fn normalizes_plain_and_bare_addresses() {
    assert_eq!(sl::normalize("  https://example.com/a/b?x=1#top \n").as_deref(), Some("https://example.com/a/b?x=1"));
    assert_eq!(sl::normalize("example.com/news/1").as_deref(), Some("https://example.com/news/1"));
    assert_eq!(sl::normalize("<https://example.com/a>").as_deref(), Some("https://example.com/a"));
    assert_eq!(sl::normalize("example.com:8080/a").as_deref(), Some("https://example.com:8080/a"));
}

#[test]
fn rejects_unsafe_or_non_web() {
    for bad in [
        "http://localhost/x", "http://192.168.0.1/admin", "http://127.0.0.1:8080", "http://[::1]/", "file:///etc/passwd",
        "javascript:alert(1)", "mailto:a@example.com", "ftp://example.com/a", "http://intranet/", "http://router.local/",
        "https://user:pw@example.com/a", "hello world", "", "smb://example.com/share", "http://0x7f.1/", "localhost:8080",
    ] {
        assert!(sl::normalize(bad).is_none(), "{bad}");
    }
    assert!(sl::normalize(&format!("https://example.com/{}", "a".repeat(3000))).is_none()); // 너무 긴 주소
}

#[test]
fn parses_scheme_url() {
    let enc = "https%3A%2F%2Fexample.com%2Fpost%3Fid%3D3%26q%3Da%2Bb";
    let (u, t) = sl::parse_scheme(&format!("dropcap://save?url={enc}&title=%EC%A0%9C%EB%AA%A9")).unwrap();
    assert_eq!(u, "https://example.com/post?id=3&q=a+b");
    assert_eq!(t.as_deref(), Some("제목"));
    assert_eq!(sl::parse_scheme("dropcap:save?url=https://example.com/a").map(|r| r.0).as_deref(), Some("https://example.com/a"));
    assert!(sl::parse_scheme("dropcap://save?url=http%3A%2F%2F10.0.0.1%2F").is_none()); // 내부망
    assert!(sl::parse_scheme("dropcap://delete?url=https://example.com/a").is_none()); // 모르는 동작
    assert!(sl::parse_scheme("https://save?url=https://example.com/a").is_none()); // 다른 스킴
    assert!(sl::parse_scheme("dropcap://save").is_none());
    // '+' 는 띄어쓰기로 바꾸지 않는다(맥과 같게), 깨진 % 는 그대로
    assert_eq!(sl::percent_decode("a+b%2"), "a+b%2");
}

#[test]
fn reads_article_head() {
    let html = r#"<html><head><title>Fallback | Site</title>
        <meta property="og:title" content="Big &amp; New Model">
        <meta content="/img/cover.jpg" property="og:image">
        <meta property="og:site_name" content="Example News">
        <meta name="description" content="A summary.">
        </head></html>"#;
    let h = sl::parse_head(html, "https://example.com/a/b");
    assert_eq!(h.title.as_deref(), Some("Big & New Model"));
    assert_eq!(h.image.as_deref(), Some("https://example.com/img/cover.jpg"));
    assert_eq!(h.site.as_deref(), Some("Example News"));
    assert_eq!(h.description.as_deref(), Some("A summary."));
    let h2 = sl::parse_head(r#"<title>Only Title</title><meta property="og:image" content="http://127.0.0.1/x.png">"#, "https://example.com/");
    assert_eq!(h2.title.as_deref(), Some("Only Title"));
    assert!(h2.image.is_none()); // 내부망 사진 주소는 받지 않음
    // 빈 og:title 은 건너뛰고 twitter:title
    let h3 = sl::parse_head(
        r#"<meta property="og:title" content=""><meta name="twitter:title" content="트윗 제목"><meta property="og:site_name" content="사이트">"#,
        "https://a.example/",
    );
    assert_eq!((h3.title.as_deref(), h3.site.as_deref()), (Some("트윗 제목"), Some("사이트")));
    assert_eq!(sl::attr(r#" data-src="a" src="b""#, "src").as_deref(), Some("b"));
    assert!(sl::attr(r#" content="닫히지 않음"#, "content").is_none());
}

#[test]
fn head_parsers_on_hostile_pages_are_fast() {
    let metas = "<meta property='og:title' content=".repeat(20_000);
    let titles = "<title>".repeat(50_000);
    let t = std::time::Instant::now();
    let _ = sl::parse_head(&metas, "https://a.example/");
    let _ = sl::title(&titles);
    assert!(t.elapsed().as_secs() < 4, "{:?}", t.elapsed());
}

#[test]
fn makes_saved_item() {
    let u = "https://www.example.com/2026/10/some-story";
    let now = Utc::now();
    let it = sl::make_item(u, &Head { title: Some("Some Story - Example".into()), ..Default::default() }, None, now);
    assert_eq!(it.source_name, "example.com");
    assert_eq!((it.link.as_str(), it.id.as_str()), (u, u));
    assert_eq!(it.tier, sl::TIER);
    assert!(it.source_id.starts_with(sl::SOURCE_PREFIX));
    assert_eq!(it.title, "Some Story");
    let no_head = sl::make_item(u, &Head::default(), Some("북마클릿 제목"), now);
    assert_eq!(no_head.title, "북마클릿 제목");
    assert!(!sl::make_item(u, &Head::default(), None, now).title.is_empty()); // 머리를 못 받아도 주소에서 제목
}

#[test]
fn strips_site_suffix_matching_host() {
    assert_eq!(sl::strip_host_suffix("Initial - Wikipedia", "en.wikipedia.org"), "Initial");
    assert_eq!(sl::strip_host_suffix("A story | The Verge", "www.theverge.com"), "A story");
    assert_eq!(sl::strip_host_suffix("Rock - Paper", "example.com"), "Rock - Paper"); // 사이트 이름이 아니면 그대로
}

#[test]
fn bookmarklet_uses_scheme() {
    assert!(sl::BOOKMARKLET.starts_with("javascript:"));
    assert!(sl::BOOKMARKLET.contains("dropcap://save?url='+encodeURIComponent(location.href)"));
}

#[test]
fn outside_saves_are_rate_limited() {
    let r = sl::RateLimit::new(std::time::Duration::from_secs(60), 10);
    let t0 = std::time::Instant::now();
    for _ in 0..10 {
        assert!(r.allow_at(t0));
    }
    assert!(!r.allow_at(t0)); // 11번째
    assert!(r.allow_at(t0 + std::time::Duration::from_secs(61))); // 1분 뒤 다시
}

// MARK: dropcap:// 주소(I-04)

#[test]
fn open_links_round_trip_keys_with_special_characters() {
    let key = "openai|https://openai.com/news/a?b=1&c=2#x";
    let u = ur::open_link(key);
    assert!(u.starts_with("dropcap://open?key="));
    assert_eq!(ur::key(&u).as_deref(), Some(key));
    assert!(ur::key("dropcap://open").is_none());
    assert!(ur::key("https://open?key=a").is_none());
    assert_eq!(ur::key("DROPCAP://OPEN?key=z").as_deref(), Some("z"));
    assert_eq!(ur::route(&u), Route::Open(key.into()));
}

#[test]
fn routes() {
    assert_eq!(ur::route("dropcap://magazine"), Route::Magazine);
    assert_eq!(ur::route("dropcap://magazine/"), Route::Magazine);
    assert_eq!(ur::route("dropcap://save?url=https%3A%2F%2Fexample.com%2Fa"), Route::Save("https://example.com/a".into(), None));
    assert_eq!(ur::route("dropcap://save?url=http%3A%2F%2Flocalhost%2F"), Route::BadSave);
    assert_eq!(ur::route("dropcap://format-disk"), Route::Unknown);
    assert_eq!(ur::route("https://example.com/"), Route::Unknown);
    assert_eq!(ur::route(&ur::save_link("https://example.com/a?b=1&c=2")), Route::Save("https://example.com/a?b=1&c=2".into(), None));
}

// MARK: 명령줄(I-02)

fn args(a: &[&str]) -> Vec<String> {
    std::iter::once("dropcap").chain(a.iter().copied()).map(String::from).collect()
}

#[test]
fn command_line() {
    assert_eq!(ur::cli(&args(&[])), Cli::Run { uris: vec![] });
    assert_eq!(ur::cli(&args(&["--background"])), Cli::Run { uris: vec![] });
    assert_eq!(ur::cli(&args(&["--magazine"])), Cli::Run { uris: vec![ur::MAGAZINE.into()] });
    assert_eq!(ur::cli(&args(&["--save", "example.com/a"])), Cli::Run { uris: vec![ur::save_link("example.com/a")] });
    assert!(matches!(ur::cli(&args(&["--save", "http://192.168.0.1/"])), Cli::Error(_)));
    assert!(matches!(ur::cli(&args(&["--save"])), Cli::Error(_)));
    assert_eq!(ur::cli(&args(&["dropcap://open?key=a"])), Cli::Run { uris: vec!["dropcap://open?key=a".into()] });
    assert_eq!(ur::cli(&args(&["--latest"])), Cli::Latest { section: None, count: 5, json: false });
    assert_eq!(ur::cli(&args(&["--latest", "500", "--section", "연구", "--json"])), Cli::Latest { section: Some("연구".into()), count: 20, json: true });
    assert_eq!(ur::cli(&args(&["--help"])), Cli::Help);
}

#[test]
fn section_parameter_resolves() {
    let c = |id: &str| SectionChoice::Only(NewsCategory::from_raw(id).unwrap());
    assert_eq!(ur::section(None), SectionChoice::All);
    assert_eq!(ur::section(Some("  ")), SectionChoice::All);
    assert_eq!(ur::section(Some("전체")), SectionChoice::All);
    assert_eq!(ur::section(Some("연구")), c("research"));
    assert_eq!(ur::section(Some("Model")), c("model"));
    assert_eq!(ur::section(Some("모델·제품")), c("model"));
    assert_eq!(ur::section(Some("투자")), c("business")); // '투자·기업' 앞부분
    assert_eq!(ur::section(Some("기업")), c("business")); // 가운뎃점 뒤 낱말
    assert_eq!(ur::section(Some("날씨")), SectionChoice::Unknown);
    assert_eq!(ur::section_names().len(), NewsCategory::all().len());
}

fn item(id: &str, title: &str, mins: i64) -> NewsItem {
    let mut it = NewsItem::new(id, title, &format!("https://example.com/{id}"), "s", "S", "press");
    it.date = Some(Utc::now() - Duration::minutes(mins));
    it
}

#[test]
fn count_and_latest_filter() {
    assert_eq!(ur::count(None), 5);
    assert_eq!(ur::count(Some(0)), 1);
    assert_eq!(ur::count(Some(500)), ur::MAX_COUNT);
    let items = [item("p", "New benchmark paper from researchers", 5), item("m", "OpenAI launches new model", 1), item("q", "Another research study", 3)];
    let ids = |v: Vec<NewsItem>| v.into_iter().map(|i| i.id).collect::<Vec<_>>();
    assert_eq!(ids(ur::latest(&items, None, 2)), ["m", "q"]);
    let research = NewsCategory::from_raw("research").unwrap();
    assert_eq!(ids(ur::latest(&items, Some(research), 5)), ["q", "p"]);
    let out = ur::format_latest(&items[..1], true, Utc::now());
    let v: serde_json::Value = serde_json::from_str(&out).unwrap();
    assert_eq!(v[0]["link"], "https://example.com/p");
    assert!(ur::format_latest(&[], false, Utc::now()).contains("없습니다"));
}

// MARK: 데스크톱 검색(I-03)

#[test]
fn search_finds_saved_and_scraps() {
    let mut a = item("a", "OpenAI ships agents", 1);
    a.title_ko = Some("오픈AI 에이전트 출시".into());
    let b = item("b", "Quantum chips", 2);
    let mut s = Scrap::new(b.clone(), Some("양자 칩의 오류율".into()), None, "보고서용", "조사");
    s.created = Utc.with_ymd_and_hms(2026, 10, 1, 0, 0, 0).unwrap();
    let docs = si::docs(&[a.clone()], &[s.clone()]);
    assert_eq!(docs.len(), 2);
    let t = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    assert_eq!(si::search(&docs, &t(&["에이전트"])), vec![format!("saved:{}", a.key())]);
    assert_eq!(si::search(&docs, &t(&["openai"])), vec![format!("saved:{}", a.key())]); // 원제도 찾음
    assert_eq!(si::search(&docs, &t(&["보고서"])), vec![format!("scrap:{}", s.id)]); // 메모
    assert_eq!(si::search(&docs, &t(&["dropcap"])).len(), 2);
    assert!(si::search(&docs, &t(&["에이전트", "양자"])).is_empty()); // 낱말은 모두 맞아야
    assert!(si::search(&docs, &t(&["a"])).is_empty()); // 한 글자는 찾지 않음
    assert_eq!(si::item_for(&format!("scrap:{}", s.id), &[a.clone()], &[s.clone()]).map(|i| i.id).as_deref(), Some("b"));
    assert_eq!(si::item_for(&format!("saved:{}", a.key()), &[a.clone()], &[]).map(|i| i.id).as_deref(), Some("a"));
    assert!(si::item_for("saved:없음", &[a], &[s]).is_none());
}

// MARK: 스크랩 노트 폴더(I-06)

#[test]
fn safe_file_names() {
    assert_eq!(se::file_name("GPT 조사"), "GPT 조사.md");
    assert_eq!(se::file_name("a/b:c"), "a／b：c.md");
    assert_eq!(se::file_name("..hidden"), "hidden.md");
    assert_eq!(se::file_name("   "), "스크랩.md");
    assert_eq!(se::file_name(&"가".repeat(300)).chars().count(), 123);
}

#[test]
fn ignores_only_date_line() {
    let a = "# c\n\n_Dropcap 스크랩 · 2026-10-12 · 2건_\n\n## x\n";
    let b = "# c\n\n_Dropcap 스크랩 · 2026-10-13 · 2건_\n\n## x\n";
    let c = "# c\n\n_Dropcap 스크랩 · 2026-10-13 · 3건_\n\n## x\n";
    assert!(se::same_ignoring_date(a, b));
    assert!(!se::same_ignoring_date(a, c));
}

#[test]
fn sync_writes_per_collection_and_reports_renamed() {
    let dir = tempfile::tempdir().unwrap();
    let it = item("a", "A story", 1);
    let s1 = Scrap::new(it.clone(), Some("인용".into()), None, "메모", "조사");
    let mut cfg = Config::default();
    let cols = vec!["스크랩".to_string(), "조사".to_string()];
    let out = se::sync(dir.path(), &[s1.clone()], &cols, &mut cfg);
    assert_eq!(out.wrote, vec!["조사.md".to_string()]); // 빈 '스크랩' 폴더는 파일을 만들지 않음
    assert!(out.error.is_none());
    let text = std::fs::read_to_string(dir.path().join("조사.md")).unwrap();
    assert!(text.starts_with("# 조사") && text.contains("> 인용") && text.contains("- 메모: 메모"));
    // 바뀐 게 없으면 다시 쓰지 않음
    assert!(se::sync(dir.path(), &[s1.clone()], &cols, &mut cfg).wrote.is_empty());
    // 폴더 이름이 바뀌면 새 파일을 쓰고 예전 파일을 알려 줌(휴지통은 부르는 쪽)
    let mut s2 = s1.clone();
    s2.collection = "연구 노트".into();
    let out = se::sync(dir.path(), &[s2], &["스크랩".into(), "연구 노트".into()], &mut cfg);
    assert_eq!(out.wrote, vec!["연구 노트.md".to_string()]);
    assert_eq!(out.stale, vec![dir.path().join("조사.md")]);
    assert_eq!(cfg.written, vec!["연구 노트.md".to_string()]);
    // 임시 파일이 남지 않음
    assert!(std::fs::read_dir(dir.path()).unwrap().all(|e| !e.unwrap().file_name().to_string_lossy().contains(".tmp-")));
    // 폴더가 없으면 쓰지 않고 알림
    assert!(se::sync(&dir.path().join("없음"), &[], &cols, &mut cfg).error.is_some());
}

#[test]
fn config_defaults_safely() {
    let dir = tempfile::tempdir().unwrap();
    let c = Config::load(dir.path()); // 파일 없음(예전 판에서 옮겨 옴)
    assert!(!c.enabled && c.path.is_none() && c.search);
    std::fs::write(dir.path().join(se::FILE), br#"{"scrapExportEnabled":true,"future":1}"#).unwrap(); // 모르는 값은 무시
    let c = Config::load(dir.path());
    assert!(c.enabled && c.search && c.written.is_empty());
    std::fs::write(dir.path().join(se::FILE), b"{broken").unwrap();
    assert_eq!(Config::load(dir.path()), Config::default());
    let mut c = Config::default();
    c.path = Some("/tmp/x".into());
    c.save(dir.path());
    assert_eq!(Config::load(dir.path()).path.as_deref(), Some("/tmp/x"));
}
