// 맥 mac/Tests/DropcapTests/CoreTests.swift 의 사례를 그대로 옮긴 것 + 리눅스 판에서 더 확인하는 것.
use chrono::{Duration, TimeZone, Utc};
use dropcap_core::app_model::{self, apply_keywords, fresh_items, group_same_story, in_quiet, set_read_in};
use dropcap_core::article::{self, Block, BlockKind, PreparedArticle, Stage};
use dropcap_core::category::NewsCategory;
use dropcap_core::database::Database;
use dropcap_core::feed_parser::{self, dates, plain};
use dropcap_core::feed_service::gzip;
use dropcap_core::magazine::{self, Interest, IssueKind};
use dropcap_core::models::{resources, NewsItem, Source};
use dropcap_core::scrapbook::{self, Scrap};
use dropcap_core::store::{AppState, Position, Settings, Store, Style};
use dropcap_core::story_match;
use dropcap_core::translator::{self, looks_foreign};
use dropcap_core::url_safety::is_public_http;
use regex::Regex;

fn item(title: &str, en: Option<&str>, source: Option<&str>) -> NewsItem {
    let mut it = NewsItem::new(
        title,
        title,
        &format!("https://x.com/{}", title.chars().take(8).collect::<String>()),
        &source.map(|s| s.to_string()).unwrap_or_else(|| uuid_like(title)),
        "S",
        "press",
    );
    it.title_en = en.map(|s| s.to_string());
    it
}

fn uuid_like(seed: &str) -> String {
    use std::sync::atomic::{AtomicUsize, Ordering};
    static N: AtomicUsize = AtomicUsize::new(0);
    format!("src-{}-{}", N.fetch_add(1, Ordering::SeqCst), seed.len())
}

// MARK: StoryMatchTests
#[test]
fn same_story_different_outlets() {
    let a = story_match::tokens("OpenAI launches GPT-6 with new reasoning features");
    let b = story_match::tokens("GPT-6 launches: OpenAI reveals reasoning features");
    assert!(story_match::similar(&a, &b));
}

#[test]
fn different_stories() {
    let a = story_match::tokens("Microsoft announces Maia 300 AI chip");
    let b = story_match::tokens("Meta releases its first frontier model, Muse Wonder");
    assert!(!story_match::similar(&a, &b));
}

#[test]
fn short_titles_never_match() {
    assert!(!story_match::similar(&story_match::tokens("AI news"), &story_match::tokens("AI news")));
}

#[test]
fn korean_titles() {
    let a = story_match::tokens("마이크로소프트, 자체 AI 칩 마이아 300 공개");
    let b = story_match::tokens("마이크로소프트 마이아 300 공개…자체 AI 칩 확대");
    assert!(story_match::similar(&a, &b));
}

// MARK: QuietHoursTests
#[test]
fn quiet_overnight() {
    assert!(in_quiet(23, 23, 7));
    assert!(in_quiet(3, 23, 7));
    assert!(!in_quiet(7, 23, 7));
    assert!(!in_quiet(12, 23, 7));
}
#[test]
fn quiet_same_day() {
    assert!(in_quiet(13, 12, 14));
    assert!(!in_quiet(14, 12, 14));
}
#[test]
fn quiet_empty_range() {
    assert!(!in_quiet(5, 5, 5));
}

// MARK: FeedParserTests
#[test]
fn rss() {
    let xml = r#"<?xml version="1.0"?><rss version="2.0"><channel><title>x</title>
<item><title><![CDATA[Hello &amp; <b>world</b>]]></title><link>https://a.com/1</link><guid>g1</guid>
<pubDate>Mon, 12 Oct 2026 10:00:00 +0000</pubDate><description>&lt;p&gt;Sum&lt;/p&gt;</description></item>
</channel></rss>"#;
    let e = feed_parser::parse_feed(xml.as_bytes()).unwrap();
    assert_eq!(e.len(), 1);
    assert_eq!(e[0].id, "g1");
    assert_eq!(e[0].title, "Hello & world");
    assert!(e[0].date.is_some());
    assert_eq!(e[0].summary, "Sum");
}

#[test]
fn atom_prefers_alternate_link() {
    let xml = r#"<feed xmlns="http://www.w3.org/2005/Atom"><entry><id>tag:1</id><title>T</title>
<link rel="self" href="https://a.com/self"/><link rel="alternate" href="https://a.com/post"/>
<updated>2026-10-12T10:00:00Z</updated></entry></feed>"#;
    let e = feed_parser::parse_feed(xml.as_bytes()).unwrap();
    assert_eq!(e.first().map(|x| x.link.as_str()), Some("https://a.com/post"));
}

#[test]
fn sitemap_filters_by_pattern() {
    let xml = r#"<urlset><url><loc>https://www.anthropic.com/news/claude-x</loc><lastmod>2026-10-01T00:00:00Z</lastmod></url>
<url><loc>https://www.anthropic.com/careers</loc></url></urlset>"#;
    let re = Regex::new(r"^https:\/\/www\.anthropic\.com\/news\/[^/]+$").unwrap();
    let e = feed_parser::parse_sitemap(xml.as_bytes(), &re).unwrap();
    assert_eq!(e.iter().map(|x| x.link.clone()).collect::<Vec<_>>(), vec!["https://www.anthropic.com/news/claude-x"]);
}

// 뉴스 사이트맵: 발행 시각(news:publication_date)을 먼저, 없으면 lastmod(한국일보·문화일보는 발행 시각만)
#[test]
fn sitemap_reads_news_publication_date() {
    let xml = r#"<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:news="http://www.google.com/schemas/sitemap-news/0.9">
<url><loc>https://www.hankookilbo.com/News/Read/A1</loc><news:news><news:publication_date>2026-10-15T09:30:00+09:00</news:publication_date></news:news></url>
<url><loc>https://www.hankookilbo.com/News/Read/A2</loc><lastmod>2026-10-15T01:00:00Z</lastmod><news:news><news:publication_date>2026-10-14T23:00:00Z</news:publication_date></news:news></url>
<url><loc>https://www.hankookilbo.com/News/Read/A3</loc><lastmod>2026-10-15T02:00:00Z</lastmod></url></urlset>"#;
    let e = feed_parser::parse_sitemap(xml.as_bytes(), &Regex::new("/News/Read/").unwrap()).unwrap();
    let want = [Utc.with_ymd_and_hms(2026, 10, 15, 0, 30, 0).unwrap(), Utc.with_ymd_and_hms(2026, 10, 14, 23, 0, 0).unwrap(), Utc.with_ymd_and_hms(2026, 10, 15, 2, 0, 0).unwrap()];
    assert_eq!(e.iter().map(|x| x.date).collect::<Vec<_>>(), want.map(Some).to_vec());
}

#[test]
fn garbage_throws() {
    assert!(feed_parser::parse_feed(b"<html><body>nope</body></html>").is_err());
}

#[test]
fn rdf_and_images() {
    let xml = r#"<rdf:RDF><item><title>A</title><link>https://a.com/r</link><dc:date>2026-10-12T10:00:00Z</dc:date><description>x</description></item></rdf:RDF>"#;
    let e = feed_parser::parse_feed(xml.as_bytes()).unwrap();
    assert_eq!(e[0].id, "https://a.com/r");
    // 대표 사진 순서: media:thumbnail 우선, 그다음 본문 첫 <img>
    let xml = r#"<rss><channel><item><title>t</title><link>https://a.com/1</link>
<media:content url="https://a.com/v.mp4" type="video/mp4"><media:thumbnail url="https://a.com/thumb.jpg"/></media:content>
<description>&lt;img src="https://a.com/body.jpg"&gt;</description></item>
<item><title>u</title><link>https://a.com/2</link><description>&lt;p&gt;&lt;img alt="" src='https://a.com/b2.png'&gt;&lt;/p&gt;</description></item>
<item><title>v</title><link>https://a.com/3</link><enclosure url="https://a.com/e.jpg" type="image/jpeg"/></item></channel></rss>"#;
    let e = feed_parser::parse_feed(xml.as_bytes()).unwrap();
    assert_eq!(e[0].image.as_deref(), Some("https://a.com/thumb.jpg"));
    assert_eq!(e[1].image.as_deref(), Some("https://a.com/b2.png"));
    assert_eq!(e[2].image.as_deref(), Some("https://a.com/e.jpg"));
}

#[test]
fn summary_is_300_chars() {
    let long = "가".repeat(500);
    let xml = format!("<rss><channel><item><title>t</title><link>https://a.com/1</link><description>{long}</description></item></channel></rss>");
    let e = feed_parser::parse_feed(xml.as_bytes()).unwrap();
    assert_eq!(e[0].summary.chars().count(), 300);
}

#[test]
fn euc_kr_feed() {
    let (bytes, _, _) = encoding_rs::EUC_KR.encode("<?xml version=\"1.0\" encoding=\"euc-kr\"?><rss><channel><item><title>인공지능 소식</title><link>https://a.com/1</link></item></channel></rss>");
    let e = feed_parser::parse_feed(&bytes).unwrap();
    assert_eq!(e[0].title, "인공지능 소식");
}

// MARK: StoreTests
#[test]
fn decodes_old_state_file() {
    let old = r#"{"seen":{"openai|x":1},"seeded":["openai"],"enabled":{"openai":true},"recent":[],"errors":{},"unread":2,
 "settings":{"style":"drop","sound":false,"intervalMinutes":10,"position":"auto"}}"#;
    let s: AppState = serde_json::from_str(old).unwrap();
    assert_eq!(s.seen.get("openai|x"), Some(&1.0));
    assert_eq!(s.unread, 2);
    assert!(!s.settings.sound);
    assert_eq!(s.settings.interval_minutes, 10);
    assert_eq!(s.settings.position, Position::Center);
    assert!(s.saved.is_empty() && s.read.is_empty() && s.custom_sources.is_empty());
}

#[test]
fn decodes_old_read_list() {
    let s: AppState = serde_json::from_str(r#"{"read":["x|1","y|2"]}"#).unwrap();
    let mut k: Vec<_> = s.read.keys().cloned().collect();
    k.sort();
    assert_eq!(k, vec!["x|1", "y|2"]);
}

#[test]
fn round_trip() {
    let mut s = AppState::default();
    s.settings.must_keywords = vec!["GPT".into()];
    s.read.insert("a|b".into(), 1.0);
    s.last_check = Some(Utc.with_ymd_and_hms(2026, 10, 13, 1, 2, 3).unwrap());
    let json = serde_json::to_string(&s).unwrap();
    assert!(json.contains("\"lastCheck\":\"2026-10-13T01:02:03Z\"")); // 맥과 같은 날짜 글자
    let back: AppState = serde_json::from_str(&json).unwrap();
    assert_eq!(back.settings.must_keywords, vec!["GPT"]);
    assert_eq!(back.read.get("a|b"), Some(&1.0));
    assert_eq!(back.last_check, s.last_check);
}

#[test]
fn broken_fields_keep_the_rest() {
    // 깨진 항목(unread 가 글자, recent 의 한 건이 모양이 틀림)이 있어도 나머지는 읽힌다
    let j = r#"{"unread":"many","seen":{"a|1":5},"recent":[{"bad":1},{"id":"1","title":"T","link":"https://a.com","sourceId":"s","sourceName":"S","tier":"press"}],
               "settings":{"style":"neon","digestHour":7}}"#;
    let s: AppState = serde_json::from_str(j).unwrap();
    assert_eq!(s.unread, 0);
    assert_eq!(s.seen.len(), 1);
    assert_eq!(s.recent.len(), 1);
    assert_eq!(s.settings.style, Style::Drop);
    assert_eq!(s.settings.digest_hour, 7);
}

#[test]
fn store_backup_atomic_and_seen_limit() {
    let dir = tempfile::tempdir().unwrap();
    let store = Store::new(dir.path().to_path_buf());
    assert!(!store.exists());
    let mut s = store.load();
    assert_eq!(s.enabled.get("openai"), Some(&false)); // 새 사용자는 관심 분야를 고르기 전엔 분야 출처를 켜지 않음(G-03)
    assert_eq!(s.enabled.get("huggingface"), Some(&false));
    for i in 0..8100 {
        s.seen.insert(format!("k|{i}"), i as f64);
    }
    store.save(&s);
    assert!(!dir.path().join("native-state.bak.json").exists()); // 첫 파일이라 백업할 것이 없음
    let loaded = store.load();
    assert_eq!(loaded.seen.len(), 8000);
    assert!(!loaded.seen.contains_key("k|0")); // 오래된 것부터 정리
    // 다음 실행의 첫 저장 전에 .bak
    let store2 = Store::new(dir.path().to_path_buf());
    store2.save(&loaded);
    assert!(dir.path().join("native-state.bak.json").exists());
}

#[test]
fn data_dir_env() {
    std::env::set_var("DROPCAP_DATA_DIR", "/tmp/dropcap-test-dir");
    assert_eq!(dropcap_core::store::data_dir_from_env(), std::path::PathBuf::from("/tmp/dropcap-test-dir"));
    std::env::remove_var("DROPCAP_DATA_DIR");
}

// MARK: MiscTests
#[test]
fn gzip_inflate() {
    use flate2::write::GzEncoder;
    use std::io::Write;
    let mut e = GzEncoder::new(Vec::new(), flate2::Compression::default());
    e.write_all(b"<rss>hello</rss>").unwrap();
    let gz = e.finish().unwrap();
    assert_eq!(gzip::inflate_if_needed(gz), b"<rss>hello</rss>");
    assert_eq!(gzip::inflate_if_needed(b"plain".to_vec()), b"plain");
}

#[test]
fn gzip_size_is_capped() {
    // 크기 값을 믿지 않는다: 압축이 풀리면 32MB 를 넘는 폭탄도 상한까지만
    use flate2::write::GzEncoder;
    use std::io::Write;
    let mut e = GzEncoder::new(Vec::new(), flate2::Compression::best());
    let zeros = vec![0u8; 1 << 20];
    for _ in 0..40 {
        e.write_all(&zeros).unwrap();
    }
    let gz = e.finish().unwrap();
    assert!(gzip::inflate_if_needed(gz).len() as u64 <= gzip::LIMIT);
}

#[test]
fn looks_foreign_cases() {
    assert!(looks_foreign("OpenAI releases a new model"));
    assert!(!looks_foreign("오픈AI가 새 모델을 공개했다"));
    assert!(!looks_foreign("   "));
}

#[test]
fn dates_cases() {
    assert!(dates::parse("Tue, 13 Oct 2026 01:02:03 GMT").is_some());
    assert!(dates::parse("2026-10-13T01:02:03.123Z").is_some());
    assert!(dates::parse("garbage").is_none());
    assert!(dates::parse("Tue, 13 Oct 2026 01:02:03 +0900").is_some());
    assert!(dates::parse("13 Oct 2026 01:02:03 +0000").is_some());
    assert!(dates::parse("2026-10-13 01:02:03").is_some());
}

#[test]
fn plain_clean_and_slug() {
    assert_eq!(plain::clean("<p>A&nbsp;&#8220;b&#8221;</p>\n  c"), "A “b” c");
    assert_eq!(plain::title_from_slug("https://www.anthropic.com/news/claude-opus_5"), "Claude opus 5");
}

// MARK: CategoryTests
#[test]
fn classifies() {
    assert_eq!(NewsCategory::classify("OpenAI launches GPT-6"), NewsCategory::id("model"));
    assert_eq!(NewsCategory::classify("Anthropic raises $5B at $200B valuation"), NewsCategory::id("business"));
    assert_eq!(NewsCategory::classify("EU AI Act enforcement begins, regulators say"), NewsCategory::id("policy"));
    assert_eq!(NewsCategory::classify("New jailbreak exploit hits chatbots"), NewsCategory::id("security"));
    assert_eq!(NewsCategory::classify("Researchers publish benchmark for reasoning"), NewsCategory::id("research"));
    assert_eq!(NewsCategory::classify("정부, AI 기본법 시행령 발표"), NewsCategory::id("policy"));
    assert_eq!(NewsCategory::classify("업스테이지, 1000억 투자 유치"), NewsCategory::id("business"));
    assert_eq!(NewsCategory::classify("Weekend reading list"), NewsCategory::id("other"));
}

#[test]
fn kind_overrides_category() {
    let mut p = item("Weekend reading list", None, None);
    p.kind = Some("paper".into());
    assert_eq!(p.category(), NewsCategory::id("research"));
    p.kind = Some("release".into());
    assert_eq!(p.category(), NewsCategory::id("model"));
}

// MARK: URLSafetyTests
#[test]
fn allows_public() {
    for u in ["https://openai.com/news/x", "http://www.aitimes.com/a?b=1", "https://8.8.8.8/x", "https://[2606:4700::1111]/"] {
        assert!(is_public_http(u), "{u}");
    }
}

#[test]
fn blocks_private_and_odd_schemes() {
    for u in [
        "http://localhost:8080/", "http://127.0.0.1/", "http://192.168.0.1/admin", "http://10.1.2.3/", "http://172.20.0.5/",
        "http://169.254.169.254/latest/meta-data", "http://router.local/", "http://intranet/", "http://[::1]/", "http://[fd00::1]/",
        "http://[::ffff:192.168.1.1]/", "file:///etc/passwd", "smb://server/share", "javascript:alert(1)", "http://0.0.0.0/",
        // 숫자 표기 꼼수
        "http://2130706433/", "http://0x7f.1/", "http://127.1/", "http://0177.0.0.1/", "http://0x7f000001/",
        "http://[0:0:0:0:0:0:0:1]/", "http://[::ffff:7f00:1]/", "http://[64:ff9b::7f00:1]/", "http://[2002:c0a8:0101::]/",
        "http://localhost./", "http://[fe80::1]/",
    ] {
        assert!(!is_public_http(u), "{u}");
    }
}

#[test]
fn blocks_linux_extras() {
    // 리눅스 판에서 더: 정규화하면 내부망이 되는 표기, 사용자 정보로 가린 주소, CGNAT·멀티캐스트·시험용
    for u in [
        "http://%31%32%37.0.0.1/", "http://user@127.0.0.1/", "http://evil.com@10.0.0.1/", "http://100.64.0.1/", "http://224.0.0.1/",
        "http://198.18.0.1/", "http://192.0.0.8/", "http://printer.lan/", "http://box.home.arpa/", "http://db.internal/", "http://a.localhost/",
        "http://[ff02::1]/", "HTTP://LOCALHOST/", "http://[::]/",
    ] {
        assert!(!is_public_http(u), "{u}");
    }
    assert!(is_public_http("https://user:pw@example.com:8443/x"));
}

// MARK: SameStoryMeaningTests
#[test]
fn same_outlet_never_merges() {
    assert!(!story_match::same(
        &item("OpenAI launches GPT-6 with new reasoning", None, Some("a")),
        &item("OpenAI launches GPT-6 with new reasoning", None, Some("a"))
    ));
}

#[test]
fn groups_across_languages() {
    let ko = item(
        "메타, 자체 최고 모델 ‘뮤즈 원더’ 출시로 프런티어 경쟁 합류",
        Some("Meta joins frontier competition by launching its own top model 'Muse Wonder'"),
        None,
    );
    let en = item("Meta has some Wonder Full new AI models", None, None);
    assert!(story_match::same(&ko, &en));
    let ko2 = item("\"AI 대신 SI 써라\"...트럼프 압박에 실리콘밸리 굴복", Some("\"Use SI instead of AI\"... Silicon Valley succumbs to Trump pressure"), None);
    assert!(story_match::same(&ko2, &item("Silicon Valley is falling in line with Trump’s attempt to rename AI", None, None)));
}

#[test]
fn keeps_different_stories_apart() {
    assert!(!story_match::same(
        &item("Microsoft’s new AI chip makes it less reliant on Nvidia’s GPUs", None, None),
        &item("Meta has some Wonder Full new AI models", None, None)
    ));
    assert!(!story_match::same(
        &item("Anthropic is cutting off its internal evaluations from the internet", None, None),
        &item("Anthropic's Claude AI submitted false murder tip to Philadelphia police", None, None)
    ));
    assert!(!story_match::same(
        &item("Learning to use local AI is exciting, overwhelming, and frustrating", None, None),
        &item("AI agent makers are promising privacy — will they deliver?", None, None)
    ));
}

// MARK: SameStoryFalsePositiveTests
#[test]
fn unrelated_korean_translations_stay_apart() {
    assert!(!story_match::same(
        &item("Epic Games reportedly pivoting to \"AI first\" game development model", None, None),
        &item("[AI리더의 서가] Physical AI 데이터의 새로운 법칙", Some("[AI Leader's Bookshelf] New Rules of Physical AI Data"), None)
    ));
    assert!(!story_match::same(
        &item("Amazon has over 1 million robot workers. What’s next for human employees?", None, None),
        &item("포스코DX, AI 스타트업 인핸스에 20억 투자", Some("POSCO DX invests 2 billion won in AI startup Enhance"), None)
    ));
}

// MARK: ScrapExportTests
#[test]
fn markdown_groups_by_article() {
    let mut it = NewsItem::new("1", "Meta has new AI models", "https://example.com/a", "verge", "The Verge", "press");
    it.title_ko = Some("메타의 새 AI 모델".into());
    it.date = Some(Utc.timestamp_opt(1_791_800_000, 0).unwrap());
    let a = Scrap::new(it.clone(), Some("메타가 새 모델을 공개했다.".into()), Some("Meta released a new model.".into()), "보고서 1장", "조사");
    let b = Scrap::new(it.clone(), None, None, "", "조사");
    let md = scrapbook::render(&[b, a], "조사");
    assert!(md.starts_with("# 조사"));
    assert_eq!(md.matches("## [메타의 새 AI 모델](https://example.com/a)").count(), 1); // 기사는 한 번만
    assert!(md.contains("> 메타가 새 모델을 공개했다."));
    assert!(md.contains("> _Meta released a new model._"));
    assert!(md.contains("- 메모: 보고서 1장"));
    assert!(md.contains("원제: Meta has new AI models"));
}

#[test]
fn markdown_exact_format() {
    // 맥 Scrapbook.render 와 글자 하나까지 같은지(날짜는 고정)
    let mut it = NewsItem::new("1", "T", "https://e.com/a", "s", "Src", "press");
    it.title_ko = Some("제목".into());
    let q = Scrap::new(it.clone(), Some("줄1\n줄2".into()), Some("orig".into()), "메모", "폴더");
    let now = Utc.with_ymd_and_hms(2026, 10, 13, 12, 0, 0).unwrap();
    let md = scrapbook::render_at(&[q], "폴더", now);
    let day = now.with_timezone(&chrono::Local).format("%Y-%m-%d");
    assert_eq!(md, format!("# 폴더\n\n_Dropcap 스크랩 · {day} · 1건_\n\n## [제목](https://e.com/a)\n\nSrc · 원제: T\n\n> 줄1\n> 줄2\n>\n> _orig_\n\n- 메모: 메모\n\n"));
}

#[test]
fn scrapbook_collections() {
    let dir = tempfile::tempdir().unwrap();
    let db = std::sync::Arc::new(Database::open(dir.path()));
    let mut sb = scrapbook::Scrapbook::new(db, dir.path().to_path_buf());
    assert_eq!(sb.collections, vec!["스크랩"]);
    let it = NewsItem::new("1", "T", "https://e.com/a", "s", "Src", "press");
    sb.add(&it, Some("문단".into()), None, "", None);
    sb.add(&it, Some("문단".into()), None, "", None); // 같은 문단 두 번은 안 됨
    assert_eq!(sb.scraps.len(), 1);
    sb.create_collection("조사");
    sb.add(&it, None, None, "", Some("조사"));
    assert_eq!(sb.last_collection(), "조사"); // 처음엔 마지막 쓴 폴더
    sb.rename("조사", "보고서");
    assert!(sb.collections.contains(&"보고서".to_string()) && !sb.collections.contains(&"조사".to_string()));
    assert!(sb.is_scrapped(&it, Some("문단")));
    let id = sb.scraps[0].id.clone();
    sb.remove(&id);
    assert_eq!(sb.scraps.len(), 1);
}

// MARK: 알림 판단
#[test]
fn keywords_after_translation() {
    let mut st = Settings::default();
    st.must_keywords = vec![" 오픈AI ".into()];
    st.mute_keywords = vec!["crypto".into()];
    let mut a = item("OpenAI ships", None, None);
    a.title_ko = Some("오픈AI 출시".into());
    let b = item("Crypto AI coin", None, None);
    let out = apply_keywords(vec![a, b], &st);
    assert_eq!(out.len(), 1);
    assert_eq!(out[0].important, Some(true));
}

#[test]
fn grouping_picks_lab_and_counts_related() {
    let now = Utc::now();
    let mut press = item("OpenAI launches GPT-6 with new reasoning features", None, Some("verge"));
    press.source_name = "The Verge".into();
    press.date = Some(now);
    let mut lab = item("GPT-6 launches: OpenAI reveals reasoning features", None, Some("openai"));
    lab.tier = "lab".into();
    lab.source_name = "OpenAI".into();
    lab.date = Some(now - Duration::minutes(5));
    let mut recent = vec![];
    let out = group_same_story(vec![press, lab], &mut recent, &Default::default(), now);
    assert_eq!(out.len(), 1);
    assert_eq!(out[0].source_id, "openai");
    assert_eq!(out[0].related, Some(vec!["The Verge".to_string()]));
    // 36시간 안에 이미 알린 소식이면 알리지 않고 출처만 더함
    let mut recent = out.clone();
    let mut again = item("OpenAI launches GPT-6 with reasoning features today", None, Some("ars"));
    again.source_name = "Ars Technica".into();
    again.date = Some(now);
    let out2 = group_same_story(vec![again.clone()], &mut recent, &Default::default(), now);
    assert!(out2.is_empty());
    assert_eq!(recent[0].related_count(), 2);
    // 숨긴 글(숨긴 출처·'알리지 않음' — 지우지 않고 거르기만 함)과는 견주지 않는다: 보이는 새 글이 묻히지 않게
    let hidden: std::collections::HashSet<String> = recent.iter().map(|r| r.key()).collect();
    let out3 = group_same_story(vec![again], &mut recent, &hidden, now);
    assert_eq!(out3.len(), 1);
    assert_eq!(recent[0].related_count(), 2);
}

#[test]
fn fresh_seeds_first_and_skips_old() {
    let mut st = AppState::default();
    let src = resources::CONFIG.sources[0].clone();
    let now = Utc::now();
    let mut a = item("a", None, Some(&src.id));
    a.date = Some(now);
    // 처음 켠 출처: 기억만
    assert!(fresh_items(&mut st, vec![a.clone()], &src, now).is_empty());
    assert!(st.seeded.contains(&src.id));
    let mut b = item("b", None, Some(&src.id));
    b.date = Some(now - Duration::days(4)); // 3일보다 오래됨
    let mut c = item("c", None, Some(&src.id));
    c.date = Some(now);
    let out = fresh_items(&mut st, vec![a, b, c], &src, now);
    assert_eq!(out.iter().map(|i| i.id.clone()).collect::<Vec<_>>(), vec!["c"]);
}

#[test]
fn read_trims_to_2000() {
    let mut st = AppState::default();
    for i in 0..3000 {
        st.read.insert(format!("k|{i}"), i as f64);
    }
    set_read_in(&mut st, "new|1", true, 99999.0);
    assert_eq!(st.read.len(), 2000);
    assert!(st.read.contains_key("new|1") && !st.read.contains_key("k|0"));
}

#[test]
fn preview_and_clock() {
    let p = app_model::preview_item();
    assert_eq!(p.title_ko.as_deref(), Some("새 소식은 이렇게 떨어집니다"));
    assert!(p.link.is_empty());
    assert_eq!(app_model::clock(None), "아직 없음");
    assert!(app_model::clock(Some(Utc::now())).starts_with('오'));
    let t = app_model::tomorrow_morning(chrono::Local::now(), 8);
    assert_eq!(t.with_timezone(&chrono::Local).format("%H:%M").to_string(), "08:00");
}

#[test]
fn ai_only_pattern() {
    assert!(resources::ai_match("NVIDIA unveils new GPU for inference"));
    assert!(resources::ai_match("생성형 서비스 확대"));
    assert!(!resources::ai_match("Quarterly earnings call for gaming division"));
}

#[test]
fn sources_json_bundled() {
    let c = &*resources::CONFIG;
    assert_eq!(c.version, 2); // 일반 뉴스 전환 뒤 자료 형식
    assert!(c.sources.iter().any(|s| s.id == "anthropic" && s.is_sitemap()));
    assert_eq!(resources::tier_label("lab"), "공식 발표");
}

// MARK: 번역
#[test]
fn translator_batches() {
    let texts: Vec<String> = vec!["a".repeat(2000), "b".repeat(1700), "c".repeat(200), "d".repeat(10)];
    let b = translator::batches(&texts, &[0, 1, 2, 3], 3800);
    assert_eq!(b, vec![vec![0, 1], vec![2, 3]]);
    let u = translator::google_url("Hello world", "ko");
    assert!(u.starts_with("https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=ko&dt=t&q=Hello"));
    assert_eq!(translator::parse_google(r#"[[["안녕 ","Hello ",null],["세계","world",null]],null,"en"]"#.as_bytes()).as_deref(), Some("안녕 세계"));
}

#[test]
fn summary_lines() {
    let r = dropcap_core::summarizer::parse_lines("요약:\n- 첫 줄\n• 둘째 줄\n-   셋째\n- 넷째").unwrap();
    assert_eq!(r, vec!["첫 줄", "둘째 줄", "셋째"]);
    assert!(dropcap_core::summarizer::parse_lines("없음").is_none());
}

// MARK: 매거진
fn stored(db: &Database, title: &str, src: &str, tier: &str, hours_ago: i64, image: bool, kind: Option<&str>) -> NewsItem {
    let mut it = NewsItem::new(title, title, &format!("https://e.com/{}", title.replace(' ', "-")), src, src, tier);
    it.date = Some(Utc::now() - Duration::hours(hours_ago));
    it.kind = kind.map(|s| s.into());
    if image {
        it.image = Some("https://e.com/i.jpg".into());
    }
    db.upsert(&it, None, Utc::now());
    it
}

#[test]
fn magazine_issue_layout() {
    let db = Database::in_memory();
    stored(&db, "OpenAI launches GPT model", "openai", "lab", 1, true, None);
    stored(&db, "Claude model update released", "verge", "press", 2, false, None);
    stored(&db, "Gemini model introducing feature", "ars", "press", 2, false, None);
    stored(&db, "Startup raises funding round", "tc", "press", 3, false, None); // 1건뿐인 분야 → 그 밖의 소식
    stored(&db, "Weekend reading list", "kr", "kr", 3, false, None);
    for i in 0..6 {
        stored(&db, &format!("Paper number {i} on attention"), "arxiv", "press", 1, false, Some("paper"));
    }
    let interest = Interest::default();
    let now = Utc::now();
    let issue = magazine::make_issue(&db, IssueKind::Daily, now - Duration::days(1), now + Duration::minutes(1), "t", &magazine::Editorial { interest, ..Default::default() });
    assert_eq!(issue.count, 5); // 맥처럼 기사만 센다(논문 6건 제외)
    assert_eq!(issue.cover.as_deref(), Some("openai|OpenAI launches GPT model")); // 사진 있는 1등
    let labels: Vec<String> = issue.sections.iter().map(|s| s.label()).collect();
    assert_eq!(labels, vec!["AI", "그 밖의 소식", "논문"]); // 분야 지면(G-10): 고른 분야가 없으면 모든 분야를 고른 것처럼
    let other = issue.sections.iter().find(|s| s.label() == "그 밖의 소식").unwrap();
    assert_eq!(other.keys.len(), 2);
    let paper = issue.sections.iter().find(|s| s.kind.as_deref() == Some("paper")).unwrap();
    assert_eq!(paper.keys.len(), 4); // 채널당 4개까지
    // 호 JSON 은 맥과 같은 모양
    let j = serde_json::to_value(&issue).unwrap();
    assert_eq!(j["kind"], "daily");
    assert_eq!(j["sections"][0]["category"], "other");
    assert_eq!(j["sections"][0]["section"], "ai"); // 맥 Issue.Section 과 같은 모양(분야 지면은 section)
}

#[test]
fn score_formula() {
    let mut it = NewsItem::new("1", "t", "https://e.com", "openai", "OpenAI", "lab");
    let now = Utc::now();
    it.date = Some(now);
    it.important = Some(true);
    it.image = Some("x".into());
    let s = dropcap_core::database::StoredItem { item: it, first_seen: now, cluster: None };
    let v = magazine::score(&s, 3, now, &Interest::default());
    let expect = 2.2 + 1.6 * (4.0f64).ln() + 2.5 + 0.0 + 2.0 + 0.4;
    assert!((v - expect).abs() < 1e-9, "{v} vs {expect}");
    let mut interest = Interest::default();
    interest.category.insert("other".into(), 4.0);
    interest.source.insert("openai".into(), 2.0);
    interest.source.insert("x".into(), 8.0);
    let w = interest.weight(NewsCategory::id("other"), Some("openai"));
    assert!((w - (1.0 + 0.5 * (3.0f64).ln() / (9.0f64).ln())).abs() < 1e-9);
}

#[test]
fn ingest_clusters_stories_and_search() {
    let db = Database::in_memory();
    let now = Utc::now();
    let mut a = NewsItem::new("a", "OpenAI launches GPT-6 with new reasoning features", "https://a.com/1", "verge", "The Verge", "press");
    a.date = Some(now - Duration::hours(2));
    let mut b = NewsItem::new("b", "GPT-6 launches: OpenAI reveals reasoning features", "https://b.com/1", "openai", "OpenAI", "lab");
    b.date = Some(now - Duration::hours(1));
    let mut c = NewsItem::new("c", "Totally unrelated robotics piece", "https://c.com/1", "ars", "Ars", "press");
    c.date = Some(now);
    magazine::ingest(&db, &[a, b.clone(), c], &[]);
    let stories = magazine::stories(&db, &Default::default());
    assert_eq!(stories.len(), 1);
    assert_eq!(stories[0].size, 2);
    assert_eq!(stories[0].title, b.title); // 공식 발표 제목을 스토리 이름으로
    assert_eq!(db.items_in_cluster(&stories[0].id).len(), 2);
    assert_eq!(db.search("robotics", 200).len(), 1);
    assert_eq!(db.search("100%", 200).len(), 0);
    db.set_image(&b.key(), "https://b.com/i.jpg");
    assert_eq!(db.search("reveals", 10)[0].image.as_deref(), Some("https://b.com/i.jpg"));
    db.prune(1, 2, Utc::now(), &|_| "ai".into());
    assert_eq!(db.item_count(), 1);
}

#[test]
fn publish_due_ids() {
    let db = Database::in_memory();
    let it = stored(&db, "Old model news", "verge", "press", 30, false, None);
    let _ = it;
    let list = magazine::publish_due(&db, &magazine::Editorial::default(), Utc::now());
    assert!(list.iter().any(|i| i.id.starts_with("daily-")));
    let again = magazine::publish_due(&db, &magazine::Editorial::default(), Utc::now());
    assert_eq!(list.len(), again.len()); // 두 번 발행하지 않음
    let d = &list[0];
    assert!(d.title().ends_with(" 호") || d.title().starts_with("주간 · "));
    assert!(Regex::new(r"^\d{4}-W\d{2}$").unwrap().is_match(&magazine::week_id(Utc::now())));
}

#[test]
fn database_survives_broken_file() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("magazine.sqlite"), b"this is not sqlite at all, just junk bytes......").unwrap();
    let db = Database::open(dir.path());
    let it = NewsItem::new("1", "T", "https://e.com/a", "s", "Src", "press");
    db.upsert(&it, None, Utc::now());
    assert_eq!(db.item_count(), 1);
    assert!(dir.path().join("magazine.broken.sqlite").exists());
}

// MARK: 읽기
#[test]
fn blocks_from_readability_html() {
    let html = r#"<html><body><div><h2>Head</h2><p>First (opens in a new window) para.</p><p><img src="/i.png"></p>
<ul><li>one</li><li> </li></ul><blockquote>quoted</blockquote><pre>let x = 1;
let y = 2;</pre><figure><img src="https://cdn.e.com/f.jpg"><figcaption>Cap (새 창에서 열기)</figcaption></figure></div></body></html>"#;
    let b = article::blocks_from_html(html, "https://e.com/post");
    let kinds: Vec<BlockKind> = b.iter().map(|x| x.kind).collect();
    assert_eq!(kinds, vec![BlockKind::H, BlockKind::P, BlockKind::Img, BlockKind::Li, BlockKind::Quote, BlockKind::Pre, BlockKind::Img, BlockKind::Cap]);
    assert_eq!(b[1].text.as_deref(), Some("First para."));
    assert_eq!(b[2].src.as_deref(), Some("https://e.com/i.png"));
    assert_eq!(b[5].text.as_deref(), Some("let x = 1;\nlet y = 2;"));
    assert_eq!(b[7].text.as_deref(), Some("Cap"));
}

#[test]
fn fast_path_extracts_without_scripts() {
    let para = "This is a fairly long paragraph about a new AI model release that keeps going for a while so that the readability scorer thinks it is real content, with commas, and more words. ";
    let html = format!(
        r#"<html><head><title>Big News</title><script>document.body.innerHTML='hacked'</script></head><body><nav>menu</nav><article><h1>Big News</h1>
<span class="sr-only">Skip to content</span><p>One. {p}</p><p>Two. {p}</p><p>Three. {p}</p></article><footer>foot</footer></body></html>"#,
        p = para
    ); // 문단마다 글이 달라야 함(같은 글은 한 번만)
    let a = article::extract_html(&html, "https://e.com/n").expect("본문");
    assert!(a.blocks.iter().filter(|b| b.kind == BlockKind::P).count() >= 3);
    assert!(!a.blocks.iter().any(|b| b.text.as_deref().unwrap_or("").contains("Skip to content")));
    assert!(!a.blocks.iter().any(|b| b.text.as_deref().unwrap_or("").contains("hacked")));
}

#[test]
fn charset_detection() {
    assert_eq!(article::sniff_charset(br#"<meta charset="EUC-KR">"#), "euc-kr");
    assert_eq!(article::sniff_charset(b"<html>"), "utf-8");
    let (bytes, _, _) = encoding_rs::EUC_KR.encode("<meta charset=euc-kr><p>한글</p>");
    assert!(article::decode_html(&bytes, None).contains("한글"));
}

#[test]
fn prepared_article_json_like_mac() {
    let mut a = PreparedArticle::new("제목", "Title");
    a.stage = Stage::Done;
    a.blocks = vec![Block { kind: BlockKind::P, text: Some("번역".into()), src: None, original: Some("orig".into()) }];
    let j = serde_json::to_value(&a).unwrap();
    assert_eq!(j["stage"], 3);
    assert_eq!(j["blocks"][0]["type"], "p");
    assert_eq!(j["originalTitle"], "Title");
    let back: PreparedArticle = serde_json::from_value(j).unwrap();
    assert_eq!(back, a);
}

#[test]
fn reading_time_and_translate_goog() {
    let en: Vec<String> = vec!["word ".repeat(460)];
    assert_eq!(article::reading_minutes(&en), 2);
    let ko: Vec<String> = vec!["가".repeat(1500)];
    assert_eq!(article::reading_minutes(&ko), 3);
    assert_eq!(article::reading_minutes(&["짧음".to_string()]), 1);
    assert_eq!(
        article::translate_goog("https://www.the-verge.com/a/b?x=1").as_deref(),
        Some("https://www-the--verge-com.translate.goog/a/b?x=1&_x_tr_sl=auto&_x_tr_tl=ko&_x_tr_hl=ko")
    );
}

#[tokio::test]
async fn article_cache_memory_and_disk() {
    let dir = tempfile::tempdir().unwrap();
    let svc = article::ArticleService::new(dir.path().to_path_buf());
    // 디스크에 완료된 기사를 두면 읽힌다, 실패한 것은 기억하지 않는다
    let mut done = PreparedArticle::new("t", "t");
    done.stage = Stage::Done;
    std::fs::write(dir.path().join("articles").join(article::file_name("https://e.com/1")), serde_json::to_vec(&done).unwrap()).unwrap();
    let mut failed = done.clone();
    failed.stage = Stage::Failed;
    std::fs::write(dir.path().join("articles").join(article::file_name("https://e.com/2")), serde_json::to_vec(&failed).unwrap()).unwrap();
    assert!(svc.cached("https://e.com/1").is_some());
    assert!(svc.cached("https://e.com/2").is_none());
    // 디스크 150개 유지, 저장 기사는 지우지 않음
    for i in 0..160 {
        std::fs::write(dir.path().join("articles").join(article::file_name(&format!("https://e.com/x{i}"))), b"{}").unwrap();
        if i == 0 {
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
    }
    svc.set_pinned(std::sync::Arc::new(|| vec!["https://e.com/x0".to_string()]));
    svc.prune();
    let n = std::fs::read_dir(dir.path().join("articles")).unwrap().count();
    assert_eq!(n, 150);
    assert!(dir.path().join("articles").join(article::file_name("https://e.com/x0")).exists());
}

#[tokio::test]
async fn blocked_article_is_failed_not_fetched() {
    // 내부망 주소의 기사는 받지 않고 실패(요약 번역으로 대신) — 미리 받기는 조용히
    let dir = tempfile::tempdir().unwrap();
    let svc = article::ArticleService::new(dir.path().to_path_buf());
    let mut it = NewsItem::new("1", "T", "http://127.0.0.1:9/a", "s", "S", "press");
    it.summary = "요약".into();
    let r = svc.prepare(it.clone(), false).await;
    assert_eq!(r.stage, Stage::Failed);
    let r = svc.prepare(it, true).await;
    assert_eq!(r.stage, Stage::Failed);
    assert_eq!(r.fallback, "요약");
}

// MARK: 사진
#[test]
fn image_shrinks_to_1400() {
    let img = image::RgbImage::from_pixel(3000, 1500, image::Rgb([200, 10, 10]));
    let mut png = Vec::new();
    image::DynamicImage::ImageRgb8(img).write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png).unwrap();
    let jpg = dropcap_core::images::shrink(&png).unwrap();
    let back = image::load_from_memory(&jpg).unwrap();
    assert_eq!((back.width(), back.height()), (1400, 700));
    assert!(dropcap_core::images::shrink(&vec![0u8; 9 << 20]).is_none()); // 8MB 넘으면 버림
}

#[test]
fn image_dir_prune() {
    let dir = tempfile::tempdir().unwrap();
    for i in 0..610 {
        std::fs::write(dir.path().join(format!("{i}.jpg")), b"x").unwrap();
    }
    dropcap_core::images::prune_dir(dir.path(), 600, 500);
    assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 500);
}

// MARK: 운영체제
#[test]
fn single_instance_lock() {
    let dir = tempfile::tempdir().unwrap();
    let first = dropcap_core::system::single_instance(dir.path());
    assert!(first.is_some());
    // 같은 잠금을 다른 파일 핸들로 다시 잡으면 실패해야 한다(두 번째 실행)
    let child = std::process::Command::new("sh")
        .arg("-c")
        .arg(format!("exec 9>>'{}'; flock -n 9 && echo got || echo busy", dir.path().join("dropcap.lock").display()))
        .output();
    if let Ok(o) = child {
        let s = String::from_utf8_lossy(&o.stdout);
        if s.contains("got") || s.contains("busy") {
            assert!(s.contains("busy"), "{s}");
        }
    }
    drop(first);
    assert!(dropcap_core::system::single_instance(dir.path()).is_some());
}

#[test]
fn autostart_file() {
    let dir = tempfile::tempdir().unwrap();
    use dropcap_core::system::*;
    assert!(!launch_at_login(dir.path()));
    set_launch_at_login(dir.path(), true, "/opt/My Apps/Dropcap.AppImage").unwrap();
    assert!(launch_at_login(dir.path()));
    let s = std::fs::read_to_string(dir.path().join(AUTOSTART_FILE)).unwrap();
    assert!(s.contains("Exec=\"/opt/My Apps/Dropcap.AppImage\" --background"));
    set_launch_at_login(dir.path(), false, "x").unwrap();
    assert!(!launch_at_login(dir.path()));
}

// MARK: 구독 채널
#[test]
fn catalog_like_mac() {
    let c = &*dropcap_core::channels::CATALOG;
    assert_eq!(c.len(), 37); // 맥 ChannelCatalog.all 과 같은 수(FEATURES 의 36 은 맥 목록을 센 실제 값 37 과 다름)
    let groups: std::collections::HashSet<_> = c.iter().filter_map(|s| s.group.clone()).collect();
    assert_eq!(groups.len(), 8);
    let simon = c.iter().find(|s| s.id == "cat-simonw").unwrap();
    assert_eq!(simon.notify_default, Some(false));
    let bloter = c.iter().find(|s| s.id == "cat-bloter").unwrap();
    assert!(bloter.ai_only);
}

#[test]
fn channel_plans() {
    use dropcap_core::channels::{plan, Plan};
    use dropcap_core::models::ItemKind;
    let feed = |p: Plan| match p {
        Plan::Check { feed, kind, .. } => (feed, kind),
        other => panic!("{other:?}"),
    };
    assert_eq!(feed(plan("r/LocalLLaMA").unwrap()), ("https://www.reddit.com/r/LocalLLaMA/top/.rss?t=day".into(), ItemKind::Post));
    assert_eq!(feed(plan("cs.AI").unwrap()), ("https://rss.arxiv.org/rss/cs.AI".into(), ItemKind::Paper));
    assert_eq!(feed(plan("hn").unwrap()).0, "https://hnrss.org/frontpage");
    assert_eq!(feed(plan("https://github.com/ollama/ollama/tree/main").unwrap()).0, "https://github.com/ollama/ollama/releases.atom");
    assert_eq!(
        feed(plan("https://www.youtube.com/channel/UCXZCJLdBC09xxGZ6gcdrc6A").unwrap()).0,
        "https://www.youtube.com/feeds/videos.xml?channel_id=UCXZCJLdBC09xxGZ6gcdrc6A"
    );
    assert_eq!(feed(plan("https://www.youtube.com/playlist?list=PL123").unwrap()).0, "https://www.youtube.com/feeds/videos.xml?playlist_id=PL123");
    assert!(matches!(plan("https://www.youtube.com/@TwoMinutePapers").unwrap(), Plan::YouTubePage(_)));
    assert_eq!(feed(plan("https://old.reddit.com/r/MachineLearning/").unwrap()).0, "https://www.reddit.com/r/MachineLearning/top/.rss?t=day");
    assert_eq!(feed(plan("https://arxiv.org/list/cs.CL/recent").unwrap()).0, "https://rss.arxiv.org/rss/cs.CL");
    assert_eq!(feed(plan("https://medium.com/@karpathy").unwrap()).0, "https://medium.com/feed/@karpathy");
    assert_eq!(feed(plan("importai.substack.com").unwrap()).0, "https://importai.substack.com/feed");
    assert!(matches!(plan("simonwillison.net").unwrap(), Plan::Generic(_)));
    assert_eq!(plan("http://192.168.0.1/feed"), Err(dropcap_core::channels::Failure::Unsafe));
    assert_eq!(plan("  "), Err(dropcap_core::channels::Failure::NotFound));
    let alts = dropcap_core::channels::alternates(r#"<link rel="alternate" type="application/rss+xml" href="/feed?a=1&amp;b=2"><link rel="alternate" hreflang="en" href="/en">"#);
    assert_eq!(alts, vec!["/feed?a=1&b=2"]);
    assert!(dropcap_core::channels::custom_id("https://x.com/feed").starts_with("custom-"));
}

#[test]
fn busy_channel_notify_off_and_empty_paper_ok() {
    use dropcap_core::channels::found_from;
    use dropcap_core::models::ItemKind;
    let now = Utc::now();
    let mut entries = vec![];
    for i in 0..16 {
        entries.push(feed_parser::Entry { id: i.to_string(), date: Some(now - Duration::hours(1)), ..Default::default() });
    }
    let f = found_from("https://e.com/feed", b"<rss><channel><title>Busy</title></channel></rss>", &entries, ItemKind::Article, None, None, true).unwrap();
    assert!(!f.notify_default);
    assert_eq!(f.name, "Busy");
    let p = found_from("https://rss.arxiv.org/rss/cs.AI", b"<rss><channel><title>cs.AI updates</title></channel></rss>", &[], ItemKind::Paper, None, None, false);
    assert!(p.is_ok());
    let e = found_from("https://e.com/feed", b"<rss><channel><title>x</title></channel></rss>", &[], ItemKind::Article, None, None, true);
    assert!(e.is_err());
}

#[test]
fn source_json_like_mac() {
    let s: Source = serde_json::from_str(r##"{"id":"x","name":"X","tier":"press","type":"feed","url":"https://x.com/f","aiOnly":false,"defaultOn":true,"color":"#000000","kind":"video","notifyDefault":false}"##).unwrap();
    assert_eq!(s.item_kind(), dropcap_core::models::ItemKind::Video);
    let j = serde_json::to_value(&s).unwrap();
    assert_eq!(j["type"], "feed");
    assert!(j.get("match").is_none());
}

#[test]
fn lazy_images_pick_real_source() {
    let html = r#"<html><body><div>
<p><img src="data:image/gif;base64,R0lG" data-src="/real.jpg"></p>
<p>Text with picture <img src="/spacer.gif" srcset="/s.jpg 320w, /l.jpg 1280w"></p>
<picture><source srcset="/p2.webp 2x, /p1.webp 1x"><img src="/fallback.jpg"></picture>
<p><img src="javascript:alert(1)"></p>
</div></body></html>"#;
    let b = article::blocks_from_html(html, "https://e.com/a/");
    let imgs: Vec<String> = b.iter().filter(|x| x.kind == BlockKind::Img).filter_map(|x| x.src.clone()).collect();
    assert_eq!(imgs, vec!["https://e.com/real.jpg", "https://e.com/l.jpg", "https://e.com/p2.webp"]);
    // 글과 사진이 함께 있는 문단은 둘 다
    assert!(b.iter().any(|x| x.kind == BlockKind::P && x.text.as_deref() == Some("Text with picture")));
}

#[test]
fn publish_due_daily_window() {
    // 일간 호 기간은 전날 18시 ~ 그날 18시
    let db = Database::in_memory();
    stored(&db, "Old model news", "verge", "press", 30, false, None);
    let list = magazine::publish_due(&db, &magazine::Editorial::default(), Utc::now());
    for i in list.iter().filter(|i| i.id.starts_with("daily-")) {
        assert_eq!((i.to - i.from).num_hours(), 24);
        assert_eq!(i.to.with_timezone(&chrono::Local).format("%H").to_string(), "18");
    }
}

#[test]
fn search_ignores_urls_and_field_names() {
    let db = Database::in_memory();
    let it = NewsItem::new("1", "Robots", "https://titlekosummary.com/x", "s", "Src", "press");
    db.upsert(&it, None, Utc::now());
    assert_eq!(db.search("titleko", 10).len(), 0);
    assert_eq!(db.search("Robo", 10).len(), 1);
}

#[test]
fn categories_come_from_data() {
    use dropcap_core::category::{CategoryTable, BUNDLED};
    let t = CategoryTable::parse(BUNDLED).unwrap();
    assert_eq!(t.order.first().map(|s| s.as_str()), Some("model"));
    // 화면 순서·이름·색은 정의 파일 그대로
    let all = NewsCategory::all();
    assert_eq!(all.iter().map(|c| c.label()).collect::<Vec<_>>(), vec!["모델·제품", "연구", "정책·규제", "투자·기업", "보안", "기타"]);
    assert!(NewsCategory::other().is_other());
    // 모르는 분야 이름(정의가 바뀐 뒤의 옛 기록)도 읽힌다
    let c: NewsCategory = serde_json::from_str("\"economy\"").unwrap();
    assert!(c.is_other());
    // 다른 정의(일반 뉴스) 모양도 받아들인다
    let general = r##"{"fallback":"etc","order":["economy","etc"],"categories":[{"id":"economy","label":"경제","color":"#00AA00","words":["금리","stock"]},{"id":"etc","label":"그 밖","color":"#888888"}]}"##;
    let g = CategoryTable::parse(general).unwrap();
    assert_eq!(g.categories.len(), 2);
    assert!(CategoryTable::parse(r#"{"fallback":"x","order":[],"categories":[]}"#).is_err());
}

#[test]
fn fast_path_keeps_article_images() {
    let para = "This is a fairly long paragraph about a new AI model release that keeps going for a while so that the readability scorer thinks it is real content, with commas, and more words. ";
    let html = format!(
        r#"<html><head><title>Big News</title></head><body><article><h1>Big News</h1><p>{p}</p>
<figure><img src="https://cdn.e.com/photo.jpg" width="800" height="450"><figcaption>A photo caption</figcaption></figure>
<p>{p}</p><p><img src="https://cdn.e.com/inline.jpg" width="640" height="360"></p><p>{p}</p></article></body></html>"#,
        p = para
    );
    let a = article::extract_html(&html, "https://e.com/n").expect("본문");
    let imgs: Vec<_> = a.blocks.iter().filter(|b| b.kind == BlockKind::Img).collect();
    assert!(imgs.len() >= 1, "{:?}", a.blocks.iter().map(|b| b.kind).collect::<Vec<_>>());
}

// MARK: 맥 AuditTests·새 CoreTests 이식
#[test]
fn entities_skip_title_case_words() {
    let e = story_match::entities("OCP Global Summit: Amid Ecosystem Adoption, NVIDIA Opens Vera Rubin Architecture");
    assert!(e.contains("nvidia") && e.contains("ocp") && !e.contains("global") && !e.contains("summit"), "{e:?}");
    let e2 = story_match::entities("OpenAI launches GPT-6 for iPhone");
    for w in ["openai", "gpt-6", "iphone"] {
        assert!(e2.contains(w), "{e2:?}");
    }
}

#[test]
fn title_case_common_word_does_not_merge() {
    assert!(!story_match::same(
        &item("OCP Global Summit: Amid Ecosystem Adoption, NVIDIA Opens Vera Rubin Architecture to Help Scale AI Factories Worldwide", None, None),
        &item("AI 업무 플랫폼 '팔레트 에이전트' 글로벌 출시", Some("Global launch of AI business platform ‘Palette Agent’… “Integrated support from planning to app production”"), None)
    ));
}

#[test]
fn category_no_partial_word_matches() {
    assert!(NewsCategory::classify("The impact of rapid growth in capital markets").is_other());
    assert!(NewsCategory::classify("A flaw that may happen in urban areas").is_other());
    assert_eq!(NewsCategory::classify("EU passes the AI Act"), NewsCategory::id("policy"));
    assert_eq!(NewsCategory::classify("OpenAI raises funding at new valuation"), NewsCategory::id("business"));
    assert_eq!(NewsCategory::classify("새 모델 출시"), NewsCategory::id("model"));
}

#[test]
fn decodes_common_and_numeric_entities() {
    assert_eq!(plain::clean("Sam&rsquo;s &ldquo;agent&rdquo; &#x2019; &#8217; &hellip; &mdash;"), "Sam’s “agent” ’ ’ … —");
    assert_eq!(plain::clean("a &amp;lt;b&amp;gt; c"), "a &lt;b&gt; c");
    assert_eq!(plain::clean("AT&amp;T"), "AT&T");
    assert_eq!(plain::clean("R&D &unknownthing; &#0; x & y"), "R&D &unknownthing; &#0; x & y");
}

#[test]
fn translator_cache_stays_under_limit() {
    let t = translator::Translator::new_for_test();
    for i in 0..=(translator::CACHE_LIMIT + 10) {
        t.remember(&format!("text {i}"), &format!("번역 {i}"));
    }
    assert!(t.cache_len() <= translator::CACHE_LIMIT && t.cache_len() > 0);
}

#[test]
fn blocks_site_local_ipv6() {
    assert!(!is_public_http("http://[fec0::1]/"));
    assert!(!is_public_http("http://[feff::1]/"));
    assert!(is_public_http("https://[2606:4700::1111]/"));
}

#[test]
fn corrupt_state_falls_back_to_backup() {
    use dropcap_core::store::read_state;
    let d = tempfile::tempdir().unwrap();
    let main = d.path().join("native-state.json");
    let bak = d.path().join("native-state.bak.json");
    std::fs::write(&main, "{\"seen\": {\"a|1\": 1").unwrap(); // 중간에 잘린 파일
    std::fs::write(&bak, r#"{"seen":{"a|1":1},"unread":3,"seeded":["a"]}"#).unwrap();
    let (s, from_backup) = read_state(&main, &bak);
    assert!(from_backup && s.unread == 3 && s.seeded == vec!["a"]);
    assert!(d.path().join("native-state.broken.json").exists());
    std::fs::write(&main, "not json").unwrap();
    let (s, fb) = read_state(&main, &d.path().join("none.json"));
    assert!(fb && s.seen.is_empty()); // .bak 을 덮어쓰지 않게 표시
    std::fs::write(&main, r#"{"unread":5}"#).unwrap();
    let (s, fb) = read_state(&main, &bak);
    assert!(!fb && s.unread == 5);
    let (_, missing) = read_state(&d.path().join("x.json"), &bak);
    assert!(!missing); // 처음 실행은 복구가 아니다
    // Store 를 통해: 본 파일이 깨졌으면 첫 저장 때 .bak 을 깨진 파일로 덮지 않는다
    std::fs::write(&main, "garbage").unwrap();
    let store = Store::new(d.path().to_path_buf());
    let st = store.load();
    store.save(&st);
    assert!(std::fs::read_to_string(&bak).unwrap().contains("\"unread\":3"));
}

#[test]
fn seen_is_pruned_oldest_first() {
    let mut seen = std::collections::HashMap::new();
    for i in 0..10 {
        seen.insert(format!("k{i}"), i as f64);
    }
    let p = dropcap_core::store::pruned(&seen, 6);
    assert_eq!(p.len(), 6);
    assert!(!p.contains_key("k0") && !p.contains_key("k3") && p.contains_key("k4") && p.contains_key("k9"));
    assert_eq!(dropcap_core::store::pruned(&seen, 20).len(), 10);
}

#[test]
fn broken_db_moves_wal_aside() {
    let d = tempfile::tempdir().unwrap();
    std::fs::write(d.path().join("magazine.sqlite"), vec![0x41u8; 4096]).unwrap();
    std::fs::write(d.path().join("magazine.sqlite-wal"), b"junk").unwrap();
    let db = Database::open(d.path());
    db.upsert(&NewsItem::new("1", "OpenAI ships a model", "https://openai.com/a", "openai", "OpenAI", "lab"), None, Utc::now());
    assert_eq!(db.item_count(), 1);
    assert!(d.path().join("magazine.broken.sqlite").exists());
    // 옛 WAL 은 옆으로 치우거나(SQLite 가 닫으며 지우기도 함) 해서 새 파일에 섞이지 않는다
    assert!(std::fs::read(d.path().join("magazine.sqlite-wal")).map(|b| b != b"junk").unwrap_or(true));
    // 멀쩡한 파일은 그대로
    drop(db);
    let db2 = Database::open(d.path());
    assert_eq!(db2.item_count(), 1);
}

#[test]
fn enrich_skips_already_tried() {
    let mk = |id: &str, image: Option<&str>| dropcap_core::database::StoredItem {
        item: {
            let mut i = NewsItem::new(id, id, &format!("https://a.com/{id}"), "s", "S", "press");
            i.image = image.map(|s| s.into());
            i.date = Some(Utc::now());
            i
        },
        first_seen: Utc::now(),
        cluster: None,
    };
    let mut items: Vec<_> = (0..20).map(|i| mk(&i.to_string(), None)).collect();
    items.push(mk("img", Some("https://a.com/x.jpg")));
    let first = magazine::to_enrich(items.clone(), &Default::default());
    assert_eq!(first.len(), 12);
    assert_eq!(first[0].item.id, "0");
    let tried: std::collections::HashSet<String> = first.iter().map(|s| s.item.key()).collect();
    let next = magazine::to_enrich(items, &tried);
    assert_eq!(next.iter().map(|s| s.item.id.clone()).collect::<Vec<_>>(), (12..20).map(|i| i.to_string()).collect::<Vec<_>>());
}

#[test]
fn translate_goog_keeps_encoded_path() {
    assert_eq!(
        article::translate_goog("https://www.ai-news.co.kr/news/AI%20%ED%95%9C%EA%B8%80?id=3").as_deref(),
        Some("https://www-ai--news-co-kr.translate.goog/news/AI%20%ED%95%9C%EA%B8%80?id=3&_x_tr_sl=auto&_x_tr_tl=ko&_x_tr_hl=ko")
    );
}

#[test]
fn recluster_and_follow() {
    let db = Database::in_memory();
    let now = Utc::now();
    let mut a = NewsItem::new("a", "OpenAI launches GPT-6 with new reasoning features", "https://a.com/1", "verge", "The Verge", "press");
    a.date = Some(now - Duration::hours(3));
    magazine::ingest(&db, &[a.clone()], &[]);
    let cid = db.cluster_of(&a.key()).unwrap();
    let mut b = NewsItem::new("b", "GPT-6 launches: OpenAI reveals reasoning features", "https://b.com/1", "openai", "OpenAI", "lab");
    b.date = Some(now);
    let grown = magazine::ingest(&db, &[b.clone()], &[cid.clone()]);
    assert_eq!(grown.len(), 1);
    assert_eq!(grown[0].1.key(), b.key());
    assert_eq!(magazine::recluster(&db), 2);
    let stories = magazine::stories(&db, &Default::default());
    assert_eq!(stories.len(), 1);
    let (live, past) = magazine::story_groups(&db, now, &Default::default());
    assert_eq!((live.len(), past.len()), (1, 0));
    assert_eq!(db.coverage(&[a.key(), b.key()]).get(&a.key()), Some(&2));
}

#[test]
fn body_cleanup_bylines_and_captions() {
    use dropcap_core::article::body_cleanup::*;
    assert_eq!(byline("김가람 기자 reporter@example.com").as_deref(), Some("김가람 기자"));
    assert_eq!(byline("이나래 기자 desk@example.com Powered by AI").as_deref(), Some("이나래 기자"));
    assert_eq!(byline("이나래 기자 desk@example.com Powered by Example AI Solution").as_deref(), Some("이나래 기자"));
    assert_eq!(byline("By Jane Doe").as_deref(), Some("By Jane Doe"));
    assert_eq!(byline("김가람 기자는 이날 현장에서 다음과 같이 말했다."), None);
    assert!(is_orphan_caption("AI 생성 영상", false));
    assert!(is_orphan_caption("사진=연합뉴스", false));
    assert!(!is_orphan_caption("사진=연합뉴스", true));
    assert!(!is_orphan_caption("여수시 여문문화의거리가 정원과 공연을 결합한 축제 공간으로 활용되고 있다.", false));
}

#[test]
fn image_keys() {
    use dropcap_core::article::image_key::*;
    assert!(is_junk(Some("https://cdn.aitimes.com/image/newsroom/default-user.png")));
    assert!(is_junk(Some("https://x.com/assets/logo.svg")));
    assert!(is_junk(Some("https://secure.gravatar.com/avatar/abc?s=96")));
    assert!(!is_junk(Some("https://cdn.aitimes.com/news/photo/202610/216198_220220_302.jpg")));
    assert!(!is_junk(Some("https://x.com/wp-content/uploads/2026/10/catalog-hero.jpg")));
    assert!(same(Some("https://cdn.aitimes.com/news/photo/202610/216199_220221_5549.jpg"), Some("https://cdn.aitimes.com/news/thumbnail/202610/216199_220221_5549_v150.jpg")));
    assert!(same(Some("https://x.com/wp-content/uploads/2026/10/gpt6-hero-1024x576.png"), Some("https://x.com/wp-content/uploads/2026/10/gpt6-hero.png?w=1200")));
}

#[test]
fn importance_order() {
    let now = Utc::now();
    let mut a = NewsItem::new("a", "A", "https://a.com", "s", "S", "press");
    a.date = Some(now);
    let mut b = NewsItem::new("b", "B", "https://b.com", "s", "S", "press");
    b.date = Some(now - Duration::hours(5));
    let mut cov = std::collections::HashMap::new();
    cov.insert(b.key(), 3);
    assert_eq!(app_model::by_importance(vec![a, b], &cov, now)[0].id, "b");
}
