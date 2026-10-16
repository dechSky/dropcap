// 맥 PaywallEarlyTests.swift 를 옮긴 것: 유료 기사를 목록 단계에서 알리기(paywall-early)
// ① 피드가 기사마다 적은 유료 표시(feed-paid-mark) ② 미리 받기에서 맛보기로 판정된 기사(teaser-mark)
use chrono::{Duration, Utc};
use dropcap_core::article::Block;
use dropcap_core::database::{Database, ExtractStat};
use dropcap_core::feed_parser;
use dropcap_core::models::NewsItem;
use dropcap_core::paywall::{self, PaywallBook, PaywallKind};
use dropcap_core::sections::{self, SourceMeta};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

fn item(id: &str, source: &str, link: &str, paid: Option<bool>) -> NewsItem {
    let mut it = NewsItem::new(id, &format!("Title {id}"), link, source, &source.to_uppercase(), "press");
    it.paid = paid;
    it
}

fn p(t: &str) -> Block {
    serde_json::from_value(serde_json::json!({"type": "p", "text": t})).unwrap()
}

// 2026-10-16 실제 피드에서 본 표시 꼴(글·주소는 지어냄)
const FEED_XML: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/"><channel><title>T</title>
<item><title>STAT+: Example drug maker posts results</title><link>https://news.example/a</link><category><![CDATA[Biotech]]></category></item>
<item><title>Plain story</title><link>https://news.example/b</link><category><![CDATA[STAT+]]></category></item>
<item><title>Another plain story</title><link>https://news.example/c</link><category><![CDATA[Artificial intelligence]]></category><category><![CDATA[Subscriber-Only Stories]]></category></item>
<item><title>Exempt story</title><link>https://news.example/d</link><category>Research</category><category>internal-paywall-exempt</category></item>
<item><title>No mark</title><link>https://news.example/e</link><category>Premium cars</category></item>
<item><title>Mid STAT+: not a prefix</title><link>https://news.example/f</link></item>
</channel></rss>"#;

const ATOM_XML: &str = r#"<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom"><title>T</title>
<entry><title>A</title><id>a</id><link href="https://news.example/a"/><category term="Subscriber-Only Stories"/></entry>
<entry><title>B</title><id>b</id><link href="https://news.example/b"/></entry>
</feed>"#;

#[test]
fn rss_marks() {
    let e = feed_parser::parse_feed(FEED_XML.as_bytes()).unwrap();
    assert_eq!(e.iter().map(|x| x.paid).collect::<Vec<_>>(), vec![Some(true), Some(true), Some(true), Some(false), None, None]);
}

#[test]
fn atom_category_term() {
    let e = feed_parser::parse_feed(ATOM_XML.as_bytes()).unwrap();
    assert_eq!(e.iter().map(|x| x.paid).collect::<Vec<_>>(), vec![Some(true), None]);
}

// 기사 단위 값이 출처 값보다 앞선다
#[test]
fn article_mark_beats_source() {
    let meta: HashMap<String, SourceMeta> =
        sections::parse_meta(r#"{"sources":[{"id":"stat","paywall":"metered"},{"id":"nyt","paywall":"hard"}]}"#);
    let none = HashMap::new();
    assert_eq!(paywall::kind("stat", "https://www.statnews.com/a", Some(true), false, &meta, &none), Some(PaywallKind::Hard));
    assert_eq!(paywall::kind("stat", "https://www.statnews.com/a", None, false, &meta, &none), Some(PaywallKind::Metered));
    assert_eq!(paywall::kind("nyt", "https://www.nytimes.com/a", Some(false), false, &meta, &none), None);
    assert_eq!(paywall::kind("x", "https://free.example/a", Some(true), false, &meta, &none), Some(PaywallKind::Hard));
    // 배운 막힘보다도 앞선다
    let many = HashMap::from([("x".to_string(), ExtractStat { tries: 10, fails: 8, blocked: 0 })]);
    assert_eq!(paywall::kind("x", "https://free.example/a", Some(false), false, &meta, &many), None);
    // 맛보기 판정은 무엇보다 앞선다
    assert_eq!(paywall::kind("nyt", "https://www.nytimes.com/a", Some(false), true, &meta, &none), Some(PaywallKind::Teaser));
}

// 피드 표시가 무료 보도 고르기에도 쓰인다: 유료 표시 기사는 권하지 않고, 풀린 기사는 권한다
#[test]
fn alternatives_use_article_mark() {
    let meta: HashMap<String, SourceMeta> = sections::parse_meta(r#"{"sources":[{"id":"nyt","paywall":"hard"},{"id":"stat"}]}"#);
    let me = item("0", "wsj", "https://wsj.example/0", None);
    let story = vec![me.clone(), item("1", "nyt", "https://nyt.example/1", Some(false)), item("2", "stat", "https://stat.example/2", Some(true))];
    let alts = paywall::free_alternatives(&me, &story, &HashSet::new(), &meta, &HashMap::new(), &HashSet::new(), 3);
    assert_eq!(alts.iter().map(|a| a.source_id.as_str()).collect::<Vec<_>>(), vec!["nyt"]);
    let teasers = HashSet::from(["https://nyt.example/1".to_string()]);
    assert!(paywall::free_alternatives(&me, &story, &HashSet::new(), &meta, &HashMap::new(), &teasers, 3).is_empty());
}

#[test]
fn old_record_without_paid_decodes() {
    let old = r#"{"id":"a","title":"T","link":"https://x.example/a","summary":"","sourceId":"s","sourceName":"S","tier":"press"}"#;
    assert_eq!(serde_json::from_str::<NewsItem>(old).unwrap().paid, None);
    let it = item("a", "s", "https://x.example/a", Some(true));
    let back: NewsItem = serde_json::from_str(&serde_json::to_string(&it).unwrap()).unwrap();
    assert_eq!(back.paid, Some(true));
}

#[test]
fn store_round_trip_and_expiry() {
    let d = tempfile::tempdir().unwrap();
    let db = Database::open(d.path());
    let now = Utc::now();
    db.mark_teaser("https://a.example/2", true, now - Duration::days(40));
    db.mark_teaser("https://a.example/1", true, now);
    assert_eq!(db.teaser_links(now), HashSet::from(["https://a.example/1".to_string()]));
    db.mark_teaser("https://a.example/1", false, now);
    assert!(db.teaser_links(now).is_empty());
    db.mark_teaser("https://a.example/3", true, now + Duration::hours(1)); // 미래 시각은 다음 기록 때 버림
    db.mark_teaser("https://a.example/4", true, now);
    assert_eq!(db.teaser_links(now), HashSet::from(["https://a.example/4".to_string()]));
}

// 미리 받기에서 맛보기 → 목록 자물쇠가 '앞부분만'(다른 자물쇠와 구분) · 다시 받아 전문이면 지움 · 다른 앱 실행에서도 남음
#[test]
fn prefetch_teaser_shows_in_list() {
    let d = tempfile::tempdir().unwrap();
    let db = Arc::new(Database::open(d.path()));
    let book = PaywallBook::new(db.clone());
    let it = item("t", "kr-test", "https://kr.example/article/000000000i", None);
    assert_eq!(book.kind(&it), None);
    let teaser = vec![p(&"가".repeat(300)), p(&"나".repeat(250))];
    let judged = paywall::is_teaser(&teaser, Some(true), book.source_kind(&it), None); // 한경 articlePayment="Y" + 짧은 본문
    assert!(judged);
    book.record_teaser(&it, judged);
    assert_eq!(book.kind(&it), Some(PaywallKind::Teaser));
    assert_eq!(book.kind(&it).unwrap().short_text(), Some("앞부분만"));
    assert_eq!(PaywallKind::Teaser.icon(), PaywallKind::Hard.icon()); // 잠긴 자물쇠
    assert!(PaywallKind::Hard.short_text().is_none() && PaywallKind::Metered.short_text().is_none());
    assert_eq!(book.source_kind(&it), None); // 판정에 넘기는 값은 지난 판정에 끌려가지 않음
    assert_eq!(PaywallBook::new(db.clone()).kind(&it), Some(PaywallKind::Teaser));
    book.record_teaser(&it, false);
    assert_eq!(book.kind(&it), None);
    assert_eq!(PaywallBook::new(db.clone()).kind(&it), None);
}

// 길게 받은 본문(전문)은 맛보기가 아니므로 목록에 '앞부분만'이 붙지 않는다
#[test]
fn full_body_not_marked() {
    let d = tempfile::tempdir().unwrap();
    let book = PaywallBook::new(Arc::new(Database::open(d.path())));
    let it = item("v", "kr-test", "https://kr.example/news/1", None);
    let blocks = vec![p(&"a".repeat(1200)), p(&"b".repeat(1200))];
    let judged = paywall::is_teaser(&blocks, Some(true), book.source_kind(&it), None);
    assert!(!judged);
    book.record_teaser(&it, judged);
    assert_ne!(book.kind(&it), Some(PaywallKind::Teaser));
    assert!(book.teasers().is_empty());
}
