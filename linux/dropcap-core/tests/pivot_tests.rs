// 맥 PivotTests.swift·FeedsTests.swift 를 옮긴 것: 분야 체계·분야 정하기·분야별 알림 정책·피드 날짜·출처 건강·OPML·자료 계약.
use chrono::{DateTime, Duration, TimeZone, Utc};
use dropcap_core::channels::opml;
use dropcap_core::database::StoredItem;
use dropcap_core::feed_parser::{self, dates, feed_dates, Entry};
use dropcap_core::magazine;
use dropcap_core::models::{resources, NewsItem, Source};
use dropcap_core::notify_policy::{self as np, Coverage, Decision, Input, NotifyMode, PolicyLimits, SectionPolicy};
use dropcap_core::sections::{self, SourceMeta};
use dropcap_core::source_health::{SourceHealth, Status};
use dropcap_core::store::{prepare, AppState};
use dropcap_core::url_safety::is_public_http;
use regex::{Regex, RegexBuilder};
use std::collections::HashMap;

fn fixture(name: &str) -> String {
    std::fs::read_to_string(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures").join(name)).unwrap()
}
fn meta() -> HashMap<String, SourceMeta> {
    sections::parse_meta(&fixture("sources-sample.json"))
}
fn ai() -> Regex {
    RegexBuilder::new(r"\b(AI|LLM|GPT)\b|인공지능|생성형").case_insensitive(true).build().unwrap()
}
fn item(title: &str, source: &str, tier: &str) -> NewsItem {
    let mut i = NewsItem::new(title, title, &format!("https://a.com/{}", title.len()), source, source, tier);
    i.date = Some(Utc::now());
    i
}
fn utc(s: &str) -> Option<DateTime<Utc>> {
    Some(DateTime::parse_from_rfc3339(s).unwrap().with_timezone(&Utc))
}

// MARK: SectionCatalogTests
#[test]
fn loads_contract_file() {
    let s = sections::parse(&fixture("categories.json")).unwrap();
    assert_eq!(s.iter().map(|x| x.id.clone()).collect::<Vec<_>>(), sections::builtin().iter().map(|x| x.id.clone()).collect::<Vec<_>>());
    assert!(s.iter().find(|x| x.id == "top").unwrap().is_flow());
    assert!(s.iter().find(|x| x.id == "climate").unwrap().is_more());
    assert!(sections::parse("{}").is_none());
    // 앱에 담긴 shared/categories.json 도 같은 계약
    assert_eq!(sections::ALL.iter().map(|x| x.id.as_str()).collect::<Vec<_>>(), ["top", "politics", "economy", "society", "world", "tech", "ai", "science", "life", "culture", "sports", "climate"]);
}

#[test]
fn contract_sources_still_decode() {
    let c: dropcap_core::models::SourceConfig = serde_json::from_str(&fixture("sources-sample.json")).unwrap();
    assert_eq!(c.sources.len(), 10);
}

#[test]
fn source_section_and_region() {
    let m = meta();
    assert_eq!(sections::section_of_source("yna-market", &m).as_deref(), Some("economy"));
    assert_eq!(sections::section_of_source("cat-yt-openai", &m).as_deref(), Some("ai"));
    assert_eq!(sections::section_of_source("custom-x1", &m), None);
    assert_eq!(sections::region_of_source("cnbc", "press", &m), "intl");
    assert_eq!(sections::region_of_source("custom-x1", "kr", &m), "kr");
}

// MARK: PlacementTests
#[test]
fn source_section_comes_first() {
    let p = sections::place(&item("국회 예산안 처리", "yna-market", "kr"), &meta(), Some(&ai()));
    assert_eq!(p.primary, "economy");
    assert!(p.chips.contains(&"politics".to_string()));
}

#[test]
fn general_feed_uses_keywords() {
    let (m, a) = (meta(), ai());
    assert_eq!(sections::place(&item("코스피 2,900 회복…외국인 순매수", "yna-latest", "kr"), &m, Some(&a)).primary, "economy");
    assert_eq!(sections::place(&item("프로야구 한국시리즈 7차전", "yna-latest", "kr"), &m, Some(&a)).primary, "sports");
    assert_eq!(sections::place(&item("오늘의 날씨 이야기", "yna-latest", "kr"), &m, Some(&a)).primary, "life");
    assert_eq!(sections::place(&item("짧은 소식", "yna-latest", "kr"), &m, Some(&a)).primary, "top");
}

#[test]
fn ai_is_pulled_from_other_sections() {
    let p = sections::place(&item("은행권, 생성형 AI 상담 도입", "yna-market", "kr"), &meta(), Some(&ai()));
    assert!(p.primary == "economy" && p.chips.contains(&"ai".to_string()));
}

#[test]
fn english_keywords_use_word_boundaries() {
    assert_eq!(sections::classify("The marketing team"), None);
    assert_eq!(sections::classify("Fed holds interest rate").as_deref(), Some("economy"));
}

// MARK: NotifyPolicyTests
fn input(mode: NotifyMode, kr: i64, intl: i64, lab: bool, star: bool, followed: bool, sec: i64, total: i64, chosen: bool) -> Input {
    Input {
        chosen,
        policy: SectionPolicy { mode, bundle_hour: 18, daily_cap: 3 },
        coverage: Coverage { kr, intl },
        lab,
        important: star,
        followed,
        sent_in_section: sec,
        sent_total: total,
    }
}

#[test]
fn policy_table() {
    use NotifyMode::*;
    let l = PolicyLimits::default();
    let cases = [
        ("고르지 않은 분야", Instant, 9, 0, false, false, false, 0, 0, false, Decision::Quiet),
        ("매거진만", Magazine, 9, 9, true, true, true, 0, 0, true, Decision::Quiet),
        ("묶음은 늘 고임", Bundle, 9, 0, true, false, false, 0, 0, true, Decision::Pool),
        ("즉시·한 곳뿐", Instant, 1, 0, false, false, false, 0, 0, true, Decision::Quiet),
        ("즉시·국내 2곳은 문턱 아래", Instant, 2, 0, false, false, false, 0, 0, true, Decision::Quiet),
        ("즉시·국내 3곳", Instant, 3, 0, false, false, false, 0, 0, true, Decision::Drop),
        ("즉시·해외 2곳", Instant, 0, 2, false, false, false, 0, 0, true, Decision::Drop),
        ("즉시·국내1+해외1", Instant, 1, 1, false, false, false, 0, 0, true, Decision::Quiet),
        ("즉시·공식 발표", Instant, 0, 1, true, false, false, 0, 0, true, Decision::Drop),
        ("즉시·꼭 알림 낱말", Instant, 1, 0, false, true, false, 0, 0, true, Decision::Drop),
        ("즉시·팔로우", Instant, 1, 0, false, false, true, 0, 0, true, Decision::Drop),
        ("분야 상한", Instant, 3, 0, false, false, false, 3, 3, true, Decision::Pool),
        ("전체 상한", Instant, 3, 0, false, false, false, 0, 10, true, Decision::Pool),
        ("상한이어도 국내 8곳", Instant, 8, 0, false, false, false, 3, 10, true, Decision::Drop),
        ("상한·공식 발표는 고임", Instant, 1, 0, true, false, false, 3, 3, true, Decision::Pool),
    ];
    for (name, mode, kr, intl, lab, star, f, sec, total, chosen, want) in cases {
        assert_eq!(np::decide(&input(mode, kr, intl, lab, star, f, sec, total, chosen), l), want, "{name}");
    }
}

#[test]
fn top_flow_catches_big_stories() {
    let l = PolicyLimits::default();
    let own = input(NotifyMode::Magazine, 4, 0, false, false, false, 0, 0, true);
    let top = input(NotifyMode::Instant, 0, 0, false, false, false, 0, 0, true);
    assert_eq!(np::decide_with_top(&own, Some(&top), l), (Decision::Drop, true));
    assert_eq!(np::decide_with_top(&input(NotifyMode::Magazine, 1, 0, false, false, false, 0, 0, true), Some(&top), l).0, Decision::Quiet);
    assert_eq!(np::decide_with_top(&own, None, l).0, Decision::Quiet);
    let full_top = input(NotifyMode::Instant, 1, 0, false, false, false, 3, 3, true);
    assert_eq!(np::decide_with_top(&input(NotifyMode::Bundle, 4, 0, false, false, false, 0, 0, true), Some(&full_top), l).0, Decision::Pool);
}

#[test]
fn custom_thresholds_and_defaults() {
    let mut l = PolicyLimits::default();
    l.kr_threshold = 2;
    assert_eq!(np::decide(&input(NotifyMode::Instant, 2, 0, false, false, false, 0, 0, true), l), Decision::Drop);
    let d = np::defaults(&["top", "politics", "economy", "sports", "ai"].map(String::from));
    assert_eq!(d["top"].mode, NotifyMode::Instant);
    assert!(d["politics"].mode == NotifyMode::Instant && d["economy"].mode == NotifyMode::Instant);
    assert!(d["sports"].mode == NotifyMode::Bundle && d["ai"].mode == NotifyMode::Bundle);
}

#[test]
fn bundle_timing() {
    let day = chrono::Local::now().date_naive();
    let at = |h: u32| chrono::Local.from_local_datetime(&day.and_hms_opt(h, 1, 0).unwrap()).unwrap().with_timezone(&Utc);
    assert!(!np::bundle_due(18, at(17), None));
    assert!(np::bundle_due(18, at(18), None));
    assert!(!np::bundle_due(18, at(20), Some(at(18))));
    assert!(np::bundle_due(18, at(20), Some(at(9))));
    assert!(np::bundle_due(18, at(19), Some(at(18) - Duration::days(1))));
}

#[test]
fn old_policy_file_still_reads() {
    let p: SectionPolicy = serde_json::from_str(r#"{"mode":"instant"}"#).unwrap();
    assert!(p.mode == NotifyMode::Instant && p.bundle_hour == 18 && p.daily_cap == 3);
    let bad: SectionPolicy = serde_json::from_str(r#"{"mode":"weird"}"#).unwrap();
    assert_eq!(bad.mode, NotifyMode::Bundle);
}

// MARK: SectionMigrationTests
fn sample_sources() -> Vec<Source> {
    serde_json::from_str::<dropcap_core::models::SourceConfig>(&fixture("sources-sample.json")).unwrap().sources
}

#[test]
fn existing_user_becomes_ai_only() {
    let mut s = AppState::default();
    s.enabled.insert("openai".into(), true);
    let p = prepare(s, true, &sample_sources(), &meta());
    assert_eq!(p.sections_chosen, Some(vec!["ai".to_string()]));
    assert_eq!(p.section_policy["ai"].mode, NotifyMode::Instant);
    assert_eq!(p.enabled.get("aitimes"), Some(&true));
    assert_eq!(p.enabled.get("yna-market"), Some(&false));
}

#[test]
fn new_user_waits_for_onboarding() {
    let p = prepare(AppState::default(), false, &sample_sources(), &meta());
    assert_eq!(p.sections_chosen, None);
    assert!(p.enabled["yna-market"] == false && p.enabled["openai"] == false);
}

#[test]
fn old_state_without_section_fields() {
    let s: AppState = serde_json::from_str(r#"{"unread":2,"settings":{"sound":false}}"#).unwrap();
    assert!(s.sections_chosen.is_none() && s.pending.is_empty() && s.settings.total_daily_cap == 10);
    // 새 항목이 들어간 상태도 그대로 왕복
    let mut st = AppState::default();
    st.sections_chosen = Some(vec!["economy".into()]);
    st.section_policy.insert("economy".into(), SectionPolicy::mode(NotifyMode::Bundle));
    st.last_bundle.insert("economy".into(), Utc.with_ymd_and_hms(2026, 10, 13, 9, 0, 0).unwrap());
    let back: AppState = serde_json::from_str(&serde_json::to_string(&st).unwrap()).unwrap();
    assert_eq!(back.sections_chosen, st.sections_chosen);
    assert_eq!(back.last_bundle, st.last_bundle);
    assert!(serde_json::to_string(&st).unwrap().contains("\"lastBundle\":{\"economy\":\"2026-10-13T09:00:00Z\"}"));
}

// MARK: SectionPageTests
fn stored(title: &str, source: &str, cluster: Option<&str>) -> StoredItem {
    StoredItem { item: item(title, source, "kr"), first_seen: Utc::now(), cluster: cluster.map(|s| s.into()) }
}

#[test]
fn top_then_chosen_then_others() {
    let big = [stored("금리 동결", "yna-market", Some("c1")), stored("금리 동결 2", "hk-finance", Some("c1")), stored("금리 동결 3", "yna-politics", Some("c1"))];
    let articles = vec![big[0].clone(), stored("코스닥 상승", "hk-finance", None), stored("환율 하락", "yna-market", None), stored("여야 합의", "yna-politics", None), stored("야구 결승", "yna-sports", None)];
    let all: Vec<StoredItem> = articles.iter().cloned().chain(big.iter().cloned()).collect();
    let chosen = ["top", "politics", "economy"].map(String::from);
    let pages = magazine::section_pages(&articles, &all, Some(&chosen), PolicyLimits::default(), 12, &meta());
    assert_eq!(pages[0].section.as_deref(), Some("top"));
    assert_eq!(pages[0].keys, vec![big[0].item.key()]);
    assert_eq!(pages.iter().filter_map(|p| p.section.clone()).collect::<Vec<_>>(), ["top", "politics", "economy"]);
    let last = pages.last().unwrap();
    assert!(last.section.is_none() && last.keys.len() == 1);
}

#[test]
fn region_split() {
    let items = [item("a", "cnbc", "press"), item("b", "yna-market", "kr"), item("c", "bbc-world", "press")];
    let (intl, kr) = magazine::split_by_region(&items, &meta());
    assert!(intl.len() == 2 && kr.len() == 1);
}

#[test]
fn title_words_skip_noise() {
    let mut it = NewsItem::new("1", "The new GPT-6 model from OpenAI", "", "s", "S", "press");
    it.title_ko = Some("오픈AI 새 GPT-6 모델 공개".into());
    let w = dropcap_core::app_model::title_words(&it);
    assert!(w.contains(&"GPT-6".to_string()) && w.contains(&"OpenAI".to_string()) && w.contains(&"오픈AI".to_string()));
    assert!(!w.contains(&"The".to_string()) && !w.contains(&"new".to_string()));
}

// MARK: FeedsTests — 날짜
#[test]
fn loose_dates() {
    assert_eq!(dates::parse("Tue, 13 Oct 2026 16:29:45 +09:00"), utc("2026-10-13T07:29:45Z"));
    assert_eq!(dates::parse("Tue, 13 10 2026 16:00:47 +0900"), utc("2026-10-13T07:00:47Z"));
    assert_eq!(dates::parse("Mon, 12 Oct 2026 06:55:00 EDT"), utc("2026-10-12T10:55:00Z"));
    assert_eq!(dates::parse("Tue, 13 Oct 2026 02:35:35 EST"), utc("2026-10-13T07:35:35Z"));
    assert_eq!(dates::parse("Fri, 09 Oct 2026 07:00:00 GMT"), utc("2026-10-09T07:00:00Z"));
    assert_eq!(dates::parse("Tue, 13 Oct 2026 16:00:00 KST"), utc("2026-10-13T07:00:00Z"));
    assert_eq!(dates::parse("Mon, 13 Oct 2026 16:00:00 +0900"), utc("2026-10-13T07:00:00Z")); // 틀린 요일
    assert_eq!(dates::parse("Wed, 30 Sep 2026 20:01:45 +0000"), utc("2026-09-30T20:01:45Z"));
    assert_eq!(dates::parse("Mon, 12 Oct 2026 18:17:43 -0400"), utc("2026-10-12T22:17:43Z"));
    assert_eq!(dates::parse("2026-10-13T16:41:00+09:00"), utc("2026-10-13T07:41:00Z"));
    assert_eq!(dates::parse("2026-10-13T07:37:22Z"), utc("2026-10-13T07:37:22Z"));
    assert_eq!(dates::parse("2026-10-12T07:13:10.123-04:00"), utc("2026-10-12T11:13:10.123Z"));
    assert_eq!(dates::parse("2026-10-13 16:15:42"), utc("2026-10-13T07:15:42Z")); // 시간대 없으면 한국 시각
    assert_eq!(dates::parse("2026.10.13 16:15"), utc("2026-10-13T07:15:00Z"));
    assert_eq!(dates::parse("2026-10-12"), utc("2026-10-11T15:00:00Z"));
    assert_eq!(dates::parse("2026-10-13T16:15:42+0900"), utc("2026-10-13T07:15:42Z"));
    assert_eq!(dates::parse("2024년 10월 29일 화요일 오후 11:30:00"), utc("2024-10-29T14:30:00Z"));
    assert_eq!(dates::parse("2024년 10월 29일 오전 12:05"), utc("2024-10-28T15:05:00Z"));
    assert_eq!(dates::parse(""), None);
    assert_eq!(dates::parse("어제"), None);
    assert_eq!(dates::parse("not a date"), None);
}

const HANI: &str = r#"<?xml version="1.0" encoding="UTF-8"?><rss xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0"><channel>
<title><![CDATA[전체기사 : 뉴스 : 한겨레]]></title><lastBuildDate>Tue, 13 Oct 2026 07:04:00 GMT</lastBuildDate>
<item><title><![CDATA[첫 기사]]></title><link>https://www.hani.co.kr/arti/society/1.html</link><guid isPermaLink="false">1</guid><dc:category>사회</dc:category></item>
<item><title><![CDATA[둘째 기사]]></title><link>https://www.hani.co.kr/arti/society/2.html</link><guid isPermaLink="false">2</guid></item>
</channel></rss>"#;

#[test]
fn undated_get_first_seen_and_keep_it() {
    let mut e = feed_parser::parse_feed(HANI.as_bytes()).unwrap();
    assert!(e.iter().all(|x| x.date.is_none()));
    let mut memory = HashMap::new();
    let t0 = Utc.timestamp_opt(1_800_000_000, 0).unwrap();
    feed_dates::repair(&mut e, "hani-society", t0, &mut memory);
    assert!(e.iter().all(|x| x.date == Some(t0)));
    let mut again = feed_parser::parse_feed(HANI.as_bytes()).unwrap();
    again.insert(0, Entry { id: "3".into(), title: "셋째".into(), link: "https://www.hani.co.kr/arti/3.html".into(), ..Default::default() });
    let t1 = t0 + Duration::seconds(300);
    feed_dates::repair(&mut again, "hani-society", t1, &mut memory);
    assert_eq!(again[0].date, Some(t1));
    assert!(again[1].date == Some(t0) && again[2].date == Some(t0));
}

#[test]
fn future_is_clamped_and_memory_bounded() {
    let now = Utc.timestamp_opt(1_800_000_000, 0).unwrap();
    let mk = |id: &str, d: DateTime<Utc>| Entry { id: id.into(), date: Some(d), ..Default::default() };
    let mut e = vec![mk("a", now + Duration::hours(1)), mk("b", now + Duration::minutes(5)), mk("c", now - Duration::hours(1))];
    let mut memory = HashMap::new();
    feed_dates::repair(&mut e, "espn", now, &mut memory);
    assert_eq!(e[0].date, Some(now));
    assert_eq!(e[1].date, Some(now + Duration::minutes(5)));
    assert_eq!(e[2].date, Some(now - Duration::hours(1)));
    assert!(memory.is_empty());
    let mut memory: HashMap<String, DateTime<Utc>> = (0..=feed_dates::MEMORY_LIMIT).map(|i| (format!("s|{i}"), Utc.timestamp_opt(i as i64, 0).unwrap())).collect();
    feed_dates::repair(&mut [], "s", Utc::now(), &mut memory);
    assert_eq!(memory.len(), feed_dates::MEMORY_LIMIT / 2);
    assert!(memory.contains_key(&format!("s|{}", feed_dates::MEMORY_LIMIT)));
}

#[test]
fn nocut_feed_parses() {
    let xml = r#"<?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel><title>노컷뉴스</title>
<item><title>기사</title><link>https://www.nocutnews.co.kr/news/1</link><pubDate>Tue, 13 10 2026 15:48:32 +0900</pubDate></item></channel></rss>"#;
    assert_eq!(feed_parser::parse_feed(xml.as_bytes()).unwrap()[0].date, utc("2026-10-13T06:48:32Z"));
}

// MARK: SourceHealthTests
#[test]
fn health_statuses() {
    let now = Utc.timestamp_opt(1_800_000_000, 0).unwrap();
    let days = |n: i64| now - Duration::days(n);
    let mut h = SourceHealth::default();
    assert_eq!(h.status(now), Status::Unknown);
    h.success(Some(days(1)), Some("1".into()), 3, now);
    assert_eq!(h.status(now), Status::Ok);
    assert_eq!(h.last_new, Some(days(1)));
    let s = |d: Option<DateTime<Utc>>, c: i64| SourceHealth { last_success: Some(now), last_new: d, count: Some(c), ..Default::default() };
    assert_eq!(s(Some(days(5)), 3).status(now), Status::Quiet(5));
    assert_eq!(s(Some(days(40)), 3).status(now), Status::Stalled(40));
    assert_eq!(s(None, 0).status(now), Status::Empty);
    let mut f = SourceHealth::default();
    f.failure("HTTP 404");
    assert_eq!(f.status(now), Status::Failing(1, "HTTP 404".into())); // 한 번도 성공 못 했으면 바로 오류
    f.success(None, None, 2, now);
    f.failure("HTTP 500");
    assert_eq!(f.status(now), Status::Ok); // 성공한 적 있으면 3번 연속부터
    f.failure("HTTP 500");
    f.failure("HTTP 500");
    assert_eq!(f.status(now), Status::Failing(3, "HTTP 500".into()));
    // 날짜 없는 피드: 맨 위 글이 바뀌면 새 글
    let mut u = SourceHealth::default();
    u.success(None, Some("a".into()), 2, days(10));
    assert_eq!(u.last_new, Some(days(10)));
    u.success(None, Some("a".into()), 2, days(5));
    assert_eq!(u.last_new, Some(days(10)));
    u.success(None, Some("b".into()), 2, now);
    assert_eq!(u.last_new, Some(now));
}

#[test]
fn health_book_persists() {
    let d = tempfile::tempdir().unwrap();
    let f = d.path().join("source-health.json");
    let b = dropcap_core::source_health::HealthBook::open(f.clone());
    b.record_success("yna-politics", None, Some("x".into()), 120, Utc::now());
    b.record_failure("dead", "HTTP 404");
    b.save_if_dirty();
    let b2 = dropcap_core::source_health::HealthBook::open(f.clone());
    assert_eq!(b2.status("dead", Utc::now()), Status::Failing(1, "HTTP 404".into()));
    std::fs::write(&f, "broken").unwrap();
    assert_eq!(dropcap_core::source_health::HealthBook::open(f).status("dead", Utc::now()), Status::Unknown);
}

// MARK: OPMLTests
#[test]
fn opml_round_trip_and_other_readers() {
    let mk = |id: &str, name: &str, url: &str, home: Option<&str>, section: Option<&str>| {
        let mut s: Source = serde_json::from_str(&format!(
            r##"{{"id":"{id}","name":"x","tier":"kr","type":"feed","url":"{url}","aiOnly":false,"defaultOn":true,"color":"#000"}}"##
        ))
        .unwrap();
        s.name = name.into();
        s.home = home.map(|h| h.into());
        s.section = section.map(|x| x.into());
        s
    };
    let src = vec![
        mk("a", "연합뉴스 정치", "https://www.yna.co.kr/rss/politics.xml", None, Some("politics")),
        mk("b", "SBS \"사회\" & 생활", "https://news.sbs.co.kr/news/SectionRssFeed.do?plink=RSSREADER&sectionId=03", Some("https://news.sbs.co.kr"), Some("society")),
        mk("c", "OpenAI", "https://openai.com/news/rss.xml", None, None),
    ];
    let names: HashMap<&str, &str> = [("politics", "정치"), ("society", "사회"), ("ai", "AI")].into();
    let xml = opml::export(&src, |s| names.get(s).map(|x| x.to_string()).unwrap_or_else(|| s.to_string()), Utc::now());
    assert!(xml.contains("<outline text=\"정치\""));
    let back = opml::parse(xml.as_bytes()).unwrap();
    assert_eq!(back.iter().map(|e| e.url.clone()).collect::<Vec<_>>(), src.iter().map(|s| s.url.clone()).collect::<Vec<_>>());
    assert_eq!(back[1].title, "SBS \"사회\" & 생활");
    assert_eq!(back[1].home.as_deref(), Some("https://news.sbs.co.kr"));
    let other = r#"<?xml version="1.0" encoding="UTF-8"?>
<opml version="1.0"><head><title>Feeds</title></head><body>
  <outline text="Tech" title="Tech">
    <outline type="rss" text="The Verge" title="The Verge" xmlUrl="https://www.theverge.com/rss/index.xml" htmlUrl="https://www.theverge.com"/>
    <outline type="rss" text="Ars" xmlUrl="https://feeds.arstechnica.com/arstechnica/index"/>
  </outline>
  <outline text="Empty folder"/>
  <outline type="rss" text="Verge again" xmlUrl="https://www.theverge.com/rss/index.xml"/>
  <outline type="rss" text="HN" xmlUrl="https://hnrss.org/frontpage?a=1&amp;b=2"/>
</body></opml>"#;
    let e = opml::parse(other.as_bytes()).unwrap();
    assert_eq!(e.iter().map(|x| x.url.as_str()).collect::<Vec<_>>(), ["https://www.theverge.com/rss/index.xml", "https://feeds.arstechnica.com/arstechnica/index", "https://hnrss.org/frontpage?a=1&b=2"]);
    assert_eq!(e[1].title, "Ars");
    assert!(opml::parse(b"<rss><channel/></rss>").is_err());
}

// MARK: SourceDataTests — shared 자료 계약
#[test]
fn every_source_has_valid_fields() {
    let all = &resources::CONFIG.sources;
    let ids: std::collections::HashSet<&str> = sections::ALL.iter().map(|s| s.id.as_str()).collect();
    assert_eq!(all.iter().map(|s| &s.id).collect::<std::collections::HashSet<_>>().len(), all.len());
    assert_eq!(all.iter().map(|s| &s.url).collect::<std::collections::HashSet<_>>().len(), all.len());
    for s in all {
        assert!(s.section.is_some() && ids.contains(s.section_id()), "{} 분야", s.id);
        assert!(s.lang.is_some(), "{} 언어", s.id);
        assert!(s.region.as_deref() == Some("kr") || s.region.as_deref() == Some("intl"), "{} 지역", s.id);
        assert!(is_public_http(&s.url), "{} 주소", s.id);
        if s.tier == "kr" {
            assert_eq!(s.region.as_deref(), Some("kr"), "{} 국내 등급", s.id);
        }
    }
    for sec in sections::ALL.iter() {
        let on: Vec<&Source> = all.iter().filter(|s| s.section_id() == sec.id && s.default_on).collect();
        assert!(!on.is_empty(), "{} 에 기본 출처가 없음", sec.id);
        if !["society", "climate"].contains(&sec.id.as_str()) {
            assert!(on.iter().any(|s| s.is_domestic()) && on.iter().any(|s| !s.is_domestic()), "{} 국내·해외 기본 출처", sec.id);
        }
    }
    for id in ["openai", "anthropic", "deepmind", "google-ai", "nvidia", "mit-tr", "ars", "verge", "aitimes", "etnews"] {
        assert_eq!(all.iter().find(|s| s.id == id).map(|s| s.section_id()), Some("ai"), "{id}");
    }
}

#[test]
fn defaults_when_fields_missing() {
    let old = r##"{"id":"custom-x","name":"X","tier":"press","type":"feed","url":"https://x.example/feed","aiOnly":false,"defaultOn":true,"color":"#000"}"##;
    let s: Source = serde_json::from_str(old).unwrap();
    assert!(s.section_id() == "ai" && s.language() == "en" && s.region_code() == "intl");
    let kr: Source = serde_json::from_str(&old.replace("\"press\"", "\"kr\"")).unwrap();
    assert_eq!(kr.region_code(), "kr");
}
