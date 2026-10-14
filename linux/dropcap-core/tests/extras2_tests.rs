// 맥 Extras2Tests.swift 를 옮긴 것: 받는 크기 상한(S-12) · 지켜볼 낱말(N-27) · 내 기록 내보내기·가져오기(P-08) · 번역 긴 문단·엔진(T-08) · A-31
use chrono::{TimeZone, Utc};
use dropcap_core::backup::{self, Failure, Summary};
use dropcap_core::feed_parser;
use dropcap_core::feed_service::FetchLimit;
use dropcap_core::models::{NewsItem, Source};
use dropcap_core::net::{self, FeedError};
use dropcap_core::notify_policy::{self as np, Coverage, Decision, Input, NotifyMode, PolicyLimits, SectionPolicy};
use dropcap_core::scrapbook::Scrap;
use dropcap_core::store::{AppState, Settings};
use dropcap_core::translator::{self, Translator};
use dropcap_core::watch_words;
use std::collections::HashMap;

// MARK: 1. 받는 크기 상한(S-12)
fn chunks(n: usize, size: usize) -> impl futures::Stream<Item = Result<Vec<u8>, FeedError>> {
    futures::stream::iter((0..n).map(move |_| Ok(vec![1u8; size])))
}

#[tokio::test]
async fn collect_stops_at_limit() {
    assert!(matches!(net::collect(chunks(100, 1), None, 50).await, Err(FeedError::TooLarge(50))));
    assert_eq!(net::collect(chunks(50, 1), Some(50), 50).await.unwrap().len(), 50);
    // 헤더만 보고 거절(본문을 한 바이트도 읽지 않음)
    let polled = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let p2 = polled.clone();
    let s = futures::stream::iter(0..10).map(move |_| {
        p2.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        Ok::<Vec<u8>, FeedError>(vec![1u8; 10])
    });
    use futures::StreamExt;
    assert!(matches!(net::collect(s, Some(51), 50).await, Err(FeedError::TooLarge(50))));
    assert_eq!(polled.load(std::sync::atomic::Ordering::SeqCst), 0);
}

#[tokio::test]
async fn undeclared_big_stream_is_cut_without_reading_it_all() {
    // 길이를 밝히지 않고 60MB 를 흘려도 10MB 를 조금 넘는 데서 멈춘다
    let read = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let r2 = read.clone();
    use futures::StreamExt;
    let s = futures::stream::iter(0..(60 * 8)).map(move |_| {
        r2.fetch_add(128 << 10, std::sync::atomic::Ordering::SeqCst);
        Ok::<Vec<u8>, FeedError>(vec![0u8; 128 << 10])
    });
    assert!(net::collect(s, None, FetchLimit::Feed.bytes()).await.is_err());
    assert!(read.load(std::sync::atomic::Ordering::SeqCst) < 11 << 20);
}

#[tokio::test]
async fn limits_depend_on_kind() {
    let three_mb = || chunks(3 * 8, 128 << 10);
    assert!(net::collect(three_mb(), None, FetchLimit::Page.bytes()).await.is_err());
    assert_eq!(net::collect(three_mb(), None, FetchLimit::Feed.bytes()).await.unwrap().len(), 3 << 20);
    assert!(net::collect(chunks(9 * 8, 128 << 10), None, FetchLimit::Image.bytes()).await.is_err());
}

#[test]
fn limit_values() {
    assert!(FetchLimit::Feed.bytes() == 10 << 20 && FetchLimit::Page.bytes() == 2 << 20 && FetchLimit::Image.bytes() == 8 << 20);
    assert!(FeedError::TooLarge(10 << 20).to_string().contains("10MB"));
}

// MARK: 2. 지켜볼 낱말(N-27)
fn item(title: &str, ko: Option<&str>, key: &str, mins_ago: i64) -> NewsItem {
    let mut it = NewsItem::new(key, title, &format!("https://a.example/{key}"), "s", "S", "press");
    it.title_ko = ko.map(|k| k.to_string());
    it.date = Some(Utc::now() - chrono::Duration::minutes(mins_ago));
    it
}

#[test]
fn english_word_boundary_korean_substring() {
    assert!(watch_words::matches("Apple", "Apple unveils new chip"));
    assert!(!watch_words::matches("Apple", "Pineapple prices rise"));
    assert!(watch_words::matches("apple", "APPLE's results"));
    assert!(watch_words::matches("삼성전자", "삼성전자가 신제품을 공개했다"));
    assert!(watch_words::matches("AI 기본법", "국회, AI 기본법 개정안 통과"));
    assert!(watch_words::matches("GPT-6", "OpenAI ships GPT-6 today"));
    assert!(!watch_words::matches("GPT-6", "OpenAI ships GPT-60 today"));
    assert!(watch_words::matches("GPT-6", "GPT-60 and later GPT-6")); // 첫 자리가 걸리지 않아도 뒤에서 찾음
}

#[test]
fn match_uses_translated_title_and_order() {
    let it = item("Samsung profit jumps", Some("삼성전자 이익 급증"), "1", 0);
    let w = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    assert_eq!(watch_words::first_match(&it, &w(&["엔비디아", "삼성전자", "Samsung"])).as_deref(), Some("삼성전자"));
    assert_eq!(watch_words::first_match(&it, &w(&["엔비디아"])), None);
    assert_eq!(watch_words::normalized(&w(&[" 삼성전자 ", "", "Apple", "apple"])), w(&["삼성전자", "Apple"]));
}

#[test]
fn daily_digest_counts_per_word() {
    let list = vec![
        item("Nvidia earnings beat", None, "1", 1),
        item("Nvidia and Apple team up", None, "2", 0),
        item("Nvidia earnings beat", None, "1", 1), // 같은 기사
        item("Unrelated", None, "3", 0),
    ];
    let words: Vec<String> = ["Nvidia", "Apple", "Tesla"].iter().map(|s| s.to_string()).collect();
    let d = watch_words::digest(&list, &words);
    assert_eq!(d.iter().map(|x| x.0.as_str()).collect::<Vec<_>>(), vec!["Nvidia", "Apple"]);
    assert_eq!(d[0].1.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(), vec!["2", "1"]);
}

#[test]
fn watched_story_notifies_regardless_of_section_but_respects_total_cap() {
    let l = PolicyLimits::default();
    let mut i = Input {
        chosen: false,
        policy: SectionPolicy { mode: NotifyMode::Magazine, bundle_hour: 18, daily_cap: 3 },
        coverage: Coverage { kr: 1, intl: 0 },
        lab: false,
        important: false,
        followed: false,
        watched: true,
        sent_in_section: 0,
        sent_total: 0,
    };
    assert_eq!(np::decide(&i, l), Decision::Drop);
    i.sent_total = l.total_cap;
    assert_eq!(np::decide(&i, l), Decision::Pool);
    i.coverage = Coverage { kr: 9, intl: 0 };
    assert_eq!(np::decide(&i, l), Decision::Drop); // 크게 보도된 소식은 상한을 넘어도
    i.watched = false;
    i.coverage = Coverage { kr: 1, intl: 0 };
    i.sent_total = 0;
    assert_eq!(np::decide(&i, l), Decision::Quiet);
}

#[test]
fn old_settings_have_no_watch_words() {
    let s: Settings = serde_json::from_str(r#"{"mustKeywords":["x"]}"#).unwrap();
    assert!(s.watch_keywords.is_empty() && s.must_keywords == vec!["x".to_string()]);
    let v = serde_json::to_value(Settings { watch_keywords: vec!["a".into()], ..Settings::default() }).unwrap();
    assert_eq!(v["watchKeywords"][0], "a"); // 맥 상태 파일과 같은 이름
    let st: AppState = serde_json::from_str(r#"{"lastWatchDigest":"2026-10-14T00:00:00Z"}"#).unwrap();
    assert!(st.last_watch_digest.is_some());
}

#[test]
fn apply_keywords_marks_watch() {
    let s = Settings { watch_keywords: vec!["Nvidia".into()], ..Settings::default() };
    let out = dropcap_core::app_model::apply_keywords(vec![item("Nvidia earnings", None, "1", 0), item("Other", None, "2", 0)], &s);
    assert_eq!(out[0].watch.as_deref(), Some("Nvidia"));
    assert_eq!(out[1].watch, None);
}

#[test]
fn digest_window_until_noon() {
    use dropcap_core::app_model::digest_window;
    assert!(digest_window(9, 9) && digest_window(11, 9) && !digest_window(12, 9) && !digest_window(8, 9));
    assert!(digest_window(12, 12) && !digest_window(13, 12)); // 정오 이후 시각이면 그 한 시간
}

// MARK: 3. 내 기록 내보내기·가져오기(P-08)
fn news(id: &str) -> NewsItem {
    let mut it = NewsItem::new(id, &format!("T{id}"), &format!("https://a.example/{id}"), "s", "S", "press");
    it.date = Some(Utc.timestamp_opt(1_800_000_000, 0).unwrap());
    it
}

fn source(id: &str, url: &str) -> Source {
    serde_json::from_value(serde_json::json!({"id": id, "name": id, "tier": "press", "type": "feed", "url": url, "aiOnly": false, "defaultOn": true, "color": "#000"})).unwrap()
}

fn scrap(id: &str, item: NewsItem, quote: &str, collection: &str) -> Scrap {
    let mut s = Scrap::new(item, Some(quote.into()), None, "", collection);
    s.id = id.into();
    s.created = Utc.timestamp_opt(1_800_000_000, 0).unwrap();
    s
}

fn home() -> (AppState, Vec<Scrap>) {
    let mut s = AppState::default();
    s.settings.digest_hour = 7;
    s.settings.must_keywords = vec!["GPT-6".into()];
    s.settings.watch_keywords = vec!["삼성전자".into()];
    s.sections_chosen = Some(vec!["ai".into(), "economy".into()]);
    s.section_policy = HashMap::from([("economy".to_string(), SectionPolicy { mode: NotifyMode::Bundle, bundle_hour: 17, daily_cap: 3 })]);
    s.enabled = HashMap::from([("verge".to_string(), true), ("nyt".to_string(), false)]);
    s.notify = HashMap::from([("verge".to_string(), false)]);
    s.custom_sources = vec![source("custom-a", "https://custom-a.example/feed")];
    s.hidden_sources = vec!["spam".into()];
    s.followed_stories = vec!["story-1".into()];
    s.saved = vec![news("1"), news("2")];
    let mut sc = scrap("sc1", news("1"), "문단", "보고서");
    sc.memo = "메모".into();
    (s, vec![sc])
}

fn strs(v: &[&str]) -> Vec<String> {
    v.iter().map(|s| s.to_string()).collect()
}

#[test]
fn round_trips_and_rejects_other_files() {
    let (s, scraps) = home();
    let b = backup::make(&s, &scraps, &strs(&["스크랩", "보고서", "빈 폴더"]), Utc.timestamp_opt(1_800_000_000, 0).unwrap());
    let data = backup::encode(&b);
    assert_eq!(backup::decode(&data).unwrap(), b);
    let text = String::from_utf8(data).unwrap();
    assert!(!text.contains("\"read\"")); // 읽음 기록·본 글 기억은 담지 않음
    assert!(text.contains("\"format\": \"dropcap-backup\"") && text.contains("\"version\": 1"));
    assert!(text.find("\"app\"").unwrap() < text.find("\"customSources\"").unwrap()); // 키 정렬
    assert_eq!(backup::decode(br#"{"hello":1}"#), Err(Failure::NotBackup));
    assert_eq!(backup::decode(b"not json"), Err(Failure::NotBackup));
    assert_eq!(backup::decode(br#"{"format":"dropcap-backup","version":99}"#), Err(Failure::NewerVersion(99)));
    let partial = backup::decode(br#"{"format":"dropcap-backup","version":1,"saved":[]}"#).unwrap(); // 빠진 항목은 기본값
    assert!(partial.scraps.is_empty() && partial.settings == Settings::default());
}

// 맥이 만든 파일(같은 키 이름·날짜 형식)을 그대로 읽는다 — 기기 사이 옮기기
#[test]
fn reads_mac_backup_file() {
    let mac = r##"{
  "app" : "mac",
  "customSources" : [ { "aiOnly" : false, "color" : "#000", "defaultOn" : true, "id" : "custom-a", "name" : "A", "tier" : "press", "type" : "feed", "url" : "https://a.example/feed" } ],
  "enabled" : { "verge" : true },
  "exported" : "2027-01-15T08:00:00Z",
  "followedStories" : [ "story-1" ],
  "format" : "dropcap-backup",
  "hiddenSources" : [ ],
  "notify" : { },
  "saved" : [ { "id" : "1", "link" : "https://a.example/1", "sourceId" : "s", "sourceName" : "S", "summary" : "", "tier" : "press", "title" : "T1", "date" : "2027-01-15T08:00:00Z" } ],
  "scrapFolders" : [ "스크랩", "보고서" ],
  "scraps" : [ { "collection" : "보고서", "created" : "2027-01-15T08:00:00Z", "id" : "SC1", "item" : { "id" : "1", "link" : "https://a.example/1", "sourceId" : "s", "sourceName" : "S", "summary" : "", "tier" : "press", "title" : "T1" }, "memo" : "메모", "quote" : "문단" } ],
  "sectionPolicy" : { "economy" : { "bundleHour" : 17, "dailyCap" : 3, "mode" : "bundle" } },
  "sectionsChosen" : [ "economy" ],
  "settings" : { "autoQuietCalendar" : true, "digestHour" : 7, "mustKeywords" : [ "GPT-6" ], "style" : "drop", "watchKeywords" : [ "삼성전자" ] },
  "version" : 1
}"##;
    let b = backup::decode(mac.as_bytes()).unwrap();
    assert_eq!(b.app, "mac");
    assert_eq!(b.settings.digest_hour, 7);
    assert!(b.settings.auto_quiet_calendar);
    assert_eq!(b.settings.watch_keywords, strs(&["삼성전자"]));
    assert_eq!(b.section_policy["economy"].bundle_hour, 17);
    assert_eq!(b.custom_sources[0].id, "custom-a");
    assert_eq!(b.saved[0].key(), "s|1");
    assert_eq!(b.scraps[0].memo, "메모");
    assert_eq!(b.scrap_folders, strs(&["스크랩", "보고서"]));
}

#[test]
fn merge_into_fresh_device_takes_everything() {
    let (s, scraps) = home();
    let b = backup::make(&s, &scraps, &strs(&["스크랩", "보고서", "빈 폴더"]), Utc::now());
    let m = backup::merge(&b, &AppState::default(), &[], &strs(&["스크랩"]));
    assert_eq!(m.state.settings, s.settings);
    assert_eq!(m.state.sections_chosen, Some(strs(&["economy", "ai"]))); // 분야 순서로
    assert_eq!(m.state.section_policy["economy"].bundle_hour, 17);
    assert!(m.state.enabled.get("verge") == Some(&true) && m.state.enabled.get("nyt").is_none());
    assert_eq!(m.state.custom_sources.iter().map(|x| x.id.as_str()).collect::<Vec<_>>(), vec!["custom-a"]);
    assert_eq!(m.state.saved.iter().map(|x| x.id.as_str()).collect::<Vec<_>>(), vec!["1", "2"]);
    assert_eq!(m.new_scraps.iter().map(|x| x.id.as_str()).collect::<Vec<_>>(), vec!["sc1"]);
    assert_eq!(m.folders, strs(&["스크랩", "보고서", "빈 폴더"]));
    assert!(m.summary.settings_taken && m.summary.saved == 2 && m.summary.scraps == 1);
}

#[test]
fn merge_into_used_device_skips_same_and_keeps_local() {
    let (s, scraps) = home();
    let b = backup::make(&s, &scraps, &strs(&["보고서"]), Utc::now());
    let mut mine = AppState::default();
    mine.settings.digest_hour = 10; // 이 기기에서 바꾼 값은 지킨다
    mine.settings.must_keywords = strs(&["gpt-6", "Claude"]);
    mine.enabled = HashMap::from([("verge".to_string(), false), ("nyt".to_string(), true)]);
    mine.notify = HashMap::from([("verge".to_string(), true)]);
    mine.saved = vec![news("2"), news("9")];
    mine.custom_sources = vec![source("other", "https://custom-a.example/feed")];
    let same = scrap("different-id", news("1"), "문단", "보고서");
    let m = backup::merge(&b, &mine, std::slice::from_ref(&same), &strs(&["스크랩", "보고서"]));
    assert!(m.state.settings.digest_hour == 10 && !m.summary.settings_taken);
    assert_eq!(m.state.settings.must_keywords, strs(&["gpt-6", "Claude"])); // 대소문자만 다른 같은 낱말은 건너뜀
    assert_eq!(m.state.settings.watch_keywords, strs(&["삼성전자"]));
    assert_eq!(m.state.enabled, HashMap::from([("verge".to_string(), true), ("nyt".to_string(), true)]));
    assert_eq!(m.state.notify.get("verge"), Some(&true));
    assert_eq!(m.state.saved.iter().map(|x| x.id.as_str()).collect::<Vec<_>>(), vec!["2", "9", "1"]);
    assert_eq!(m.state.custom_sources.len(), 1); // 같은 주소는 건너뜀
    assert!(m.new_scraps.is_empty()); // 같은 기사·문단·폴더
    assert!(m.state.hidden_sources == strs(&["spam"]) && m.state.followed_stories == strs(&["story-1"]));
    let again = backup::merge(&b, &m.state, std::slice::from_ref(&same), &m.folders); // 두 번 가져와도 그대로
    assert_eq!(again.summary, Summary::default());
    assert!(again.summary.text().contains("새로 더할 것이 없었습니다"));
}

#[test]
fn restore_undoes_import() {
    let (s, scraps) = home();
    let before = backup::make(&AppState::default(), &[], &[], Utc::now());
    let merged = backup::merge(&backup::make(&s, &scraps, &[], Utc::now()), &AppState::default(), &[], &[]).state;
    let back = backup::restore(&before, &merged);
    assert!(back.saved.is_empty() && back.custom_sources.is_empty() && back.settings == Settings::default() && back.sections_chosen.is_none());
}

#[test]
fn before_import_files_keep_latest_five() {
    let d = tempfile::tempdir().unwrap();
    let b = backup::make(&AppState::default(), &[], &[], Utc::now());
    let mut last = None;
    for i in 0..7 {
        last = Some(backup::write_before_import(d.path(), &b, Utc::now() + chrono::Duration::seconds(i)).unwrap());
    }
    assert_eq!(std::fs::read_dir(d.path()).unwrap().count(), 5);
    assert_eq!(backup::latest_before_import(d.path()), last);
    assert!(backup::decode(&std::fs::read(last.unwrap()).unwrap()).is_ok());
}

#[test]
fn extra_folders_skip_used_and_default() {
    let sc = vec![scrap("a", news("1"), "q", "보고서")];
    assert_eq!(backup::extra_folders(&strs(&["스크랩", "보고서", "빈 폴더"]), &sc), strs(&["빈 폴더"]));
}

// MARK: 4. 번역(T-08)
#[test]
fn long_paragraph_splits_at_sentences() {
    let text = "This is a sentence about the economy and markets today. ".repeat(120); // 약 6800자
    let chunks = translator::sentence_chunks(&text, translator::REQUEST_LIMIT);
    assert_eq!(chunks.len(), 2);
    assert!(chunks.iter().all(|c| c.chars().count() <= translator::REQUEST_LIMIT));
    assert_eq!(chunks.concat(), text); // 아무것도 잃지 않음
    assert!(chunks[0].ends_with(". ")); // 문장 끝에서 나눔
    let one = "가".repeat(10_000); // 문장 끝이 없는 아주 긴 글
    let parts = translator::sentence_chunks(&one, 4500);
    assert_eq!(parts.iter().map(|p| p.chars().count()).collect::<Vec<_>>(), vec![4500, 4500, 1000]);
    assert_eq!(parts.concat(), one);
    assert_eq!(translator::sentence_chunks("짧은 글", 4500), vec!["짧은 글".to_string()]);
}

#[tokio::test]
async fn engine_comes_from_cache_not_global() {
    let t = Translator::new_for_test();
    t.remember("Cached apple sentence", "캐시된 문장");
    let (texts, engine) = t.translate_many_reporting(&["Cached apple sentence".to_string()]).await;
    assert_eq!(texts, vec!["캐시된 문장".to_string()]);
    assert_eq!(engine, translator::Engine::Google);
    let (_, none) = t.translate_many_reporting(&["이미 한국어입니다".to_string()]).await;
    assert_eq!(none, translator::Engine::None);
}

// MARK: 5. A-31: guid·link 가 모두 빈 글
#[test]
fn entries_without_guid_or_link_get_distinct_stable_ids() {
    let xml = r#"<rss><channel>
<item><title>First</title><pubDate>Mon, 12 Oct 2026 09:00:00 GMT</pubDate></item>
<item><title>Second</title><pubDate>Mon, 12 Oct 2026 10:00:00 GMT</pubDate></item>
<item><title>Has link</title><link>https://a.example/x</link></item>
</channel></rss>"#;
    let e = feed_parser::parse_feed(xml.as_bytes()).unwrap();
    assert!(e[0].id != e[1].id && e[0].id.starts_with("noid-"));
    assert_eq!(e[2].id, "https://a.example/x");
    assert_eq!(feed_parser::parse_feed(xml.as_bytes()).unwrap()[0].id, e[0].id); // 다시 읽어도 같은 값
    assert_ne!(feed_parser::fallback_id("A", "1"), feed_parser::fallback_id("A", "2"));
    // 맥 FeedParser.fallbackID 와 같은 값(이 Mac 의 Swift 로 잰 값) — 기기 사이에서도 같은 글로 본다
    assert_eq!(feed_parser::fallback_id("Hello world", "Tue, 13 Oct 2026 10:00:00 +0900"), "noid-3jyacbp5a1utm");
}
