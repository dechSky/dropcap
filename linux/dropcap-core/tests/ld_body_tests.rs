// 맥 ld-body-match 를 옮긴 것(teaser-ld-port, mac/READER-CUT.md 3단계 'Verge 짧은 기사 맛보기 오판'):
// 사이트 ld+json articleBody 글자 수가 우리 본문과 ±10% 이내면 '유료 표시+1,500자 미만' 규칙을 쓰지 않는다.
// 글·주소는 지어냄
use dropcap_core::article::{ld_body_length, Block};
use dropcap_core::database::Database;
use dropcap_core::models::NewsItem;
use dropcap_core::paywall::{self, PaywallBook, PaywallKind};
use std::sync::Arc;

fn p(t: &str) -> Block {
    serde_json::from_value(serde_json::json!({"type": "p", "text": t})).unwrap()
}

fn len(blocks: &[Block]) -> usize {
    blocks.iter().filter_map(|b| b.text.as_deref()).map(|t| t.chars().count()).sum()
}

// Verge 짧은 기사 꼴: 우리 본문 899자, ld articleBody 902자, 사이트는 늘 isAccessibleForFree=false
#[test]
fn verge_short_story_not_teaser() {
    let blocks = vec![p(&"a".repeat(450)), p(&"b".repeat(449))];
    assert_eq!(len(&blocks), 899);
    assert!(!paywall::is_teaser(&blocks, Some(true), None, Some(902)));
    assert!(paywall::is_teaser(&blocks, Some(true), None, Some(3000))); // 사이트는 전문을 적었는데 우리는 앞부분만 → 맛보기
    assert!(paywall::is_teaser(&blocks, Some(true), None, None)); // ld 가 없으면 예전 그대로
    assert!(paywall::is_teaser(&blocks, Some(true), None, Some(0)));
    // 하드 유료 2,500자 규칙은 ld 와 상관없이 그대로
    assert!(paywall::is_teaser(&blocks, None, Some(PaywallKind::Hard), Some(902)));
}

// 추린 그대로는 기자 이름·소개·'Follow topics…' 까지 붙어 ld 와 10% 넘게 다르지만, 군더더기를 뺀 길이(899)로는 같다
#[test]
fn verge_with_junk_compared_after_cleanup() {
    let blocks = vec![
        p(&"a".repeat(450)),
        p(&"b".repeat(449)),
        p("Jane Example"),
        p("Jane Example is a senior reporter who covers artificial intelligence, chips and the business of big technology firms."),
        p("Follow topics and authors"),
    ];
    assert!(!paywall::matches_site_body(len(&blocks), Some(902)));
    assert!(!paywall::is_teaser(&blocks, Some(true), None, Some(902)));
    assert!(paywall::is_teaser(&blocks, Some(true), None, None));
}

#[test]
fn slack_is_ten_percent() {
    assert!(paywall::matches_site_body(990, Some(900)));
    assert!(paywall::matches_site_body(810, Some(900)));
    assert!(!paywall::matches_site_body(991, Some(900)));
    assert!(!paywall::matches_site_body(809, Some(900)));
    assert!(!paywall::matches_site_body(900, None));
}

// 받은 HTML 에서: 여러 ld+json 중 가장 긴 articleBody, @graph 안까지, 태그·엔티티·빈칸 정리 뒤 글자 수
#[test]
fn ld_body_from_html() {
    let html = r#"<html><head>
<script type="application/ld+json">{"@type":"BreadcrumbList","itemListElement":[]}</script>
<script type="application/ld+json">{"@context":"https://schema.org","@graph":[{"@type":"WebPage"},{"@type":"NewsArticle","isAccessibleForFree":false,"articleBody":"<p>Hello   world</p> &amp; more"}]}</script>
<SCRIPT type="Application/LD+JSON">[{"@type":"NewsArticle","articleBody":"가나다라마바사아자차카타파하 가나다"}]</SCRIPT>
<script type="application/ld+json">{ broken json </script>
</head><body></body></html>"#;
    // "Hello world & more" = 18자, "가나다…하 가나다" = 18자 → 둘 중 큰 값
    assert_eq!(ld_body_length(html), Some(18));
    let one = r#"<script type="application/ld+json">{"mainEntity":{"articleBody":"abc def"}}</script>"#;
    assert_eq!(ld_body_length(one), Some(7));
    assert_eq!(ld_body_length("<html><body>no ld</body></html>"), None);
    assert_eq!(ld_body_length(r#"<script type="application/ld+json">{"articleBody":""}</script>"#), None);
}

// 미리 받기에서 Verge 짧은 기사 → '앞부분만' 표시가 붙지 않는다(전에 잘못 남은 기록도 지움)
#[test]
fn verge_short_story_no_teaser_mark() {
    let d = tempfile::tempdir().unwrap();
    let book = PaywallBook::new(Arc::new(Database::open(d.path())));
    let it = NewsItem::new("v", "Title v", "https://www.theverge.com/news/1/x", "verge-all", "VERGE", "press");
    book.record_teaser(&it, true); // 고치기 전 판정이 남긴 기록
    assert_eq!(book.kind(&it), Some(PaywallKind::Teaser));
    let blocks = vec![p(&"a".repeat(450)), p(&"b".repeat(449))];
    let judged = paywall::is_teaser(&blocks, Some(true), book.source_kind(&it), Some(902));
    assert!(!judged);
    book.record_teaser(&it, judged);
    assert_ne!(book.kind(&it), Some(PaywallKind::Teaser));
    assert!(book.teasers().is_empty());
}
