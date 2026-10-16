// 읽기 창 본문 잘림·군더더기(mac/READER-CUT.md 2단계, 맥 ReaderCutTests 와 같은 꼴).
// 고정 HTML 은 실제 사이트의 꼴만 본뜬 것이고 글은 지어낸 것(fixtures/reader-cut 은 맥 Fixtures/reader-cut 그대로 — 글·주소를 바꾼 것).
use dropcap_core::article::body_cleanup;
use dropcap_core::article::{extract_html, image_fit, paid_flag, Article, Block, BlockKind, PreparedArticle, Stage};
use dropcap_core::paywall::{self, PaywallKind};

const BASE: &str = "https://example.com/2026/10/story";

fn para(n: usize, topic: &str) -> String {
    format!("Paragraph {n} explains how the {topic} committee reviewed the plan, heard from residents and agreed to publish a timeline.")
}
fn p_(n: usize) -> String {
    para(n, "city budget")
}
fn kpara(n: usize) -> String {
    format!("{n}번째 문단에서는 시 예산 위원회가 계획을 검토하고 주민 의견을 들은 뒤 일정표를 공개하기로 한 과정을 설명한다.")
}
fn prefix(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}
fn texts(a: &Option<Article>) -> Vec<String> {
    a.as_ref().map(|a| a.blocks.iter().filter_map(|b| b.text.clone()).collect()).unwrap_or_default()
}
fn fixture(name: &str) -> String {
    std::fs::read_to_string(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/reader-cut").join(format!("{name}.html"))).unwrap()
}
fn imgs(a: &Option<Article>) -> usize {
    a.as_ref().map(|a| a.blocks.iter().filter(|b| b.kind == BlockKind::Img).count()).unwrap_or(0)
}

// A: 광고 칸을 사이에 둔 본문 덩어리 두 개(Ars .post-content 꼴) — 둘 다 와야 하고, 기자 소개 상자·댓글 수는 빠져야
#[test]
fn split_body_merged() {
    let first: String = (1..=3).map(|n| format!("<p>{}</p>", p_(n))).collect();
    let second: String = (4..=9).map(|n| format!("<p>{}</p>", p_(n))).collect();
    let html = format!(
        r##"<html><head><title>Story</title></head><body><header><nav><a href="/">Home</a> <a href="/science">Science</a></nav></header>
<main><article><h1>Story</h1><div class="grid"><div class="col">
<div class="post-content post-content-double">{first}</div>
<div class="ad-wrapper"><div class="ad ad--mid">Advertisement</div></div>
<div class="post-content post-content-double">{second}</div>
<div class="author-mini-bio"><a href="https://news.example.com/author/pat/"><img src="https://cdn.example.com/uploads/2018/08/pic300.jpg"></a>
<div>Pat Example <span>Senior Writer</span></div><div itemprop="description">Pat is a senior writer at Example News with a particular focus on science and culture.</div></div>
<div class="story-tools"><a class="view-comments" href="#comments">42 Comments</a></div>
</div><div class="rail"><div class="ad-wrapper is-rail"></div></div></div></article></main>
<footer><p>Example News is part of a media group. All rights reserved worldwide since forever and ever.</p></footer></body></html>"##
    );
    let t = texts(&extract_html(&html, BASE));
    assert!(t.contains(&p_(1)), "리드: {t:?}");
    assert!(t.contains(&p_(9)), "끝: {t:?}");
    assert!(!t.iter().any(|x| x.contains("senior writer at Example")), "기자 소개: {t:?}");
    assert!(!t.iter().any(|x| x.contains("Comments")), "댓글 수: {t:?}");
}

// A: data-component 블록이 줄지어 선 꼴(BBC) — 앞 덩어리(리드)와 사진 뒤 덩어리 모두, 관련 링크 블록은 빼고
#[test]
fn component_blocks_merged() {
    let text = |r: std::ops::RangeInclusive<usize>| -> String {
        r.map(|n| format!(r#"<div data-component="text-block" class="ssr-tb"><p class="ssr-p">{}</p></div>"#, para(n, "river"))).collect()
    };
    let html = format!(
        r#"<html><head><title>River</title></head><body><div id="main-wrapper"><main><article>
<div data-component="headline-block" class="ssr-h"><h1>River</h1></div>
<div data-component="byline-block" class="ssr-b"><span>By Sam Example</span></div>
{}
<div data-component="image-block" class="ssr-ib"><figure><img src="https://ichef.example.com/news/976/photo-a.jpg"><figcaption>A river at dawn</figcaption></figure></div>
{}
<div data-component="image-block" class="ssr-ib"><figure><img src="https://ichef.example.com/news/976/photo-b.jpg"><figcaption>A boat</figcaption></figure></div>
{}
<div data-component="links-block" class="ssr-l"><h2>More on this story</h2><ul><li><a href="/a">Another story about something else entirely</a></li></ul></div>
</article></main></div></body></html>"#,
        text(1..=2),
        text(3..=4),
        text(5..=9)
    );
    let a = extract_html(&html, BASE);
    let t = texts(&a);
    assert!(t.contains(&para(1, "river")), "리드: {t:?}");
    assert!(t.contains(&para(9, "river")), "끝: {t:?}");
    assert!(!t.iter().any(|x| x.contains("Another story")), "관련 링크: {t:?}");
    assert!(imgs(&a) >= 1);
}

// 실제 꼴(글은 바꿈): Ars 본문 두 덩어리 · BBC data-component 줄 · 매경 본문 대 AI 상자 · 동아 맨 글자+<br><br>
// 매경: 맥 시험의 끝 표지 BODYMID 는 본문 바로 뒤 'AI 종목 이야기' 상자 글에 붙어 있다. 맥 Readability.js 는 본문+상자를 함께 고르고,
// Rust 판(dom_smoothie)은 상자만 골라(1단계의 잘림 그대로) articleBody 우선 규칙이 본문으로 바꾼다 — 그래서 여기선 본문 끝 문단(73더0519러머)이
// 오고 상자 글(BODYMID)은 섞이지 않는지 본다. WebKit 길은 맥 스크립트 그대로라 맥과 같다.
#[test]
fn real_shapes() {
    for (name, end) in [("split-post-content", "BODYEND"), ("component-blocks", "BODYEND"), ("articlebody-vs-widget", "73더0519러머"), ("bare-text-br", "BODYEND")] {
        let a = extract_html(&fixture(name), BASE);
        let t = texts(&a);
        assert!(t.iter().any(|x| x.contains("LEDESTART")), "{name}: 리드");
        assert!(t.iter().any(|x| x.contains(end)), "{name}: 끝");
        assert!(!t.iter().any(|x| x.contains("LEDESTART") && x.contains(end)), "{name}: 한 덩어리로 붙음");
        if name == "articlebody-vs-widget" {
            assert!(!t.iter().any(|x| x.contains("BODYMID")), "매경: AI 상자 섞임");
        }
        if name == "component-blocks" {
            assert!(imgs(&a) >= 10, "BBC 사진 블록 {}", imgs(&a));
        }
    }
}

// B: 본문은 itemprop=articleBody 안 맨 글자(<br>로 나눔), 옆에는 문단이 많은 'AI 요약' 상자(매경 꼴) — 본문을 골라야
#[test]
fn article_body_preferred() {
    let body = (1..=6).map(kpara).collect::<Vec<_>>().join("<br><br>");
    let widget: String = (1..=5)
        .map(|n| format!(r#"<p class="ai-txt">AI 해설 {n}: 이 종목은 최근 거래량이 늘었고 외국인 매수가 이어졌으며 기관은 관망하는 흐름을 보였다는 분석이 나왔다.</p>"#))
        .collect();
    let html = format!(
        r#"<html><head><title>증시</title></head><body><div class="news_detail_wrap"><h2 class="news_ttl">증시</h2>
<div class="news_cnt_detail_wrap" itemprop="articleBody">{body}</div>
<div class="ai_box"><h3>기사 속 종목 이야기</h3>{widget}<p>주의사항 : 본 서비스는 AI의 구조적 한계로 인해 오류가 발생할 수 있습니다.</p></div>
</div></body></html>"#
    );
    let t = texts(&extract_html(&html, BASE));
    assert!(t.iter().any(|x| x.contains(&prefix(&kpara(1), 20))), "{t:?}");
    assert!(t.iter().any(|x| x.contains(&prefix(&kpara(6), 20))), "{t:?}");
    assert!(!t.iter().any(|x| x.starts_with("AI 해설")), "{t:?}");
}

// 동아 꼴: 맨 글자 문단이 <br><br> 와 광고 div 사이에 — 리드를 버리지 않아야
#[test]
fn bare_text_paragraphs() {
    let html = format!(
        r#"<html><head><title>사회</title></head><body><section class="news_view"><div class="article_txt">
{}<br><br>{}
<div class="adwrap"><div class="ad">광고</div></div>
{}<br><br><strong>◇ 소제목</strong><br><br>{}<br><br>{}
<figure><img src="https://image.example.com/photo.jpg"><figcaption>사진 설명</figcaption></figure>
{}</div></section></body></html>"#,
        kpara(1),
        kpara(2),
        kpara(3),
        kpara(4),
        kpara(5),
        kpara(6)
    );
    let t = texts(&extract_html(&html, BASE));
    for n in 1..=6 {
        assert!(t.iter().any(|x| x.contains(&prefix(&kpara(n), 15))), "문단 {n}: {t:?}");
    }
    assert!(!t.iter().any(|x| x.contains(&kpara(1)) && x.contains(&kpara(2))), "두 문단이 한 덩어리: {t:?}");
}

// C: ld+json isAccessibleForFree=false 와 한경 articlePayment="Y" 를 기사에 표시
#[test]
fn paid_flags() {
    let paras: String = (1..=4).map(|n| format!("<p>{}</p>", p_(n))).collect();
    let ld = format!(
        r#"<html><head><title>Deal</title><script type="application/ld+json">{{"@type":"NewsArticle","isAccessibleForFree":false}}</script></head>
<body><article>{paras}<p>Subscribe</p></article></body></html>"#
    );
    assert_eq!(extract_html(&ld, BASE).and_then(|a| a.paid), Some(true));
    let kp: String = (1..=4).map(|n| format!("<p>{}</p>", kpara(n))).collect();
    let hk = format!(r#"<html><head><title>증권</title><script>var articlePayment = "Y";</script></head><body><div id="articletxt">{kp}</div></body></html>"#);
    assert_eq!(extract_html(&hk, BASE).and_then(|a| a.paid), Some(true));
    let free = format!("<html><head><title>Free</title></head><body><article>{paras}</article></body></html>");
    assert_ne!(extract_html(&free, BASE).and_then(|a| a.paid), Some(true));
    assert_eq!(paid_flag(r#"{"isAccessibleForFree": "True"}"#), Some(false));
    assert_eq!(paid_flag("<html></html>"), None);
}

// 연합 [속보] 꼴: 기사는 사진+설명뿐, 페이지에는 메뉴 목록 — 메뉴를 본문으로 내지 말고 실패(글 거의 없음)로
#[test]
fn photo_only_is_no_text() {
    let menu: String = (1..=40).map(|n| format!(r#"<li><a href="/c{n}">분야 메뉴 {n}</a></li>"#)).collect();
    let html = format!(
        r#"<html><head><title>[속보] 제목</title></head><body><nav><ul>{menu}</ul></nav>
<article class="story-news"><figure><img src="https://img.example.com/flash.jpg"><figcaption>[속보] 사진 설명 한 줄</figcaption></figure></article>
<footer><ul>{menu}</ul></footer></body></html>"#
    );
    assert!(extract_html(&html, BASE).is_none());
}

// 화면 크기별로 기사를 세 벌 싣는 페이지(Politico 꼴) — 모아도 한 벌만
#[test]
fn layout_copies_once() {
    let story = format!(r#"<div class="story-text">{}</div>"#, (1..=4).map(|n| format!("<p>{}</p>", para(n, "senate"))).collect::<String>());
    let html = format!(
        r#"<html><head><title>S</title></head><body><main><div class="layout"><section class="story-wrap desktop">{story}</section><section class="story-wrap tablet">{story}</section><section class="story-wrap mobile">{story}</section></div></main></body></html>"#
    );
    let t = texts(&extract_html(&html, BASE));
    assert_eq!(t.iter().filter(|x| **x == para(1, "senate")).count(), 1, "{t:?}");
    assert!(t.contains(&para(4, "senate")));
}

// 번역 인계: 각주 sup 번호는 낱말에 붙지 않고, <br> 은 빈칸, 사진 단추 글은 빠짐
#[test]
fn footnotes_breaks_buttons() {
    let rest: String = (2..=5).map(|n| format!("<p>{}</p>", p_(n))).collect();
    let html = format!(
        r##"<html><head><title>Notes</title></head><body><article>
<p>{}<sup><a href="#fn1">1</a></sup> More text follows here after the footnote marker in this sentence.</p>
<p>Contact office<br>Room 12<br>Main street, and more words so that this paragraph is long enough to keep.</p>
<figure><img src="https://img.example.com/a.jpg"><figcaption>A crowd gathers <b class="hide-caption">hide caption</b></figcaption></figure>
{rest}</article></body></html>"##,
        p_(1)
    );
    let t = texts(&extract_html(&html, BASE));
    assert!(t.iter().any(|x| x.starts_with(&format!("{} More text", p_(1)))), "각주: {t:?}");
    assert!(t.iter().any(|x| x.starts_with("Contact office Room 12 Main street")), "br: {t:?}");
    assert!(!t.iter().any(|x| x.to_lowercase().contains("hide caption")), "단추 글: {t:?}");
}

fn p(s: &str) -> Block {
    Block { kind: BlockKind::P, text: Some(s.into()), src: None, original: None }
}
fn li(s: &str) -> Block {
    Block { kind: BlockKind::Li, text: Some(s.into()), src: None, original: None }
}

// C: 맛보기 판정 — 지금(문구·1,500자)에 더해 isAccessibleForFree=false + 짧은 본문, 하드 유료 + 짧은 본문, 강한 문구는 길이와 무관
#[test]
fn teaser() {
    let short: Vec<Block> = (1..=8).map(|n| p(&p_(n))).collect(); // 약 1,000자
    let long: Vec<Block> = (1..=30).map(|n| p(&p_(n))).collect(); // 약 3,800자
    assert!(!paywall::is_teaser(&short, None, None, None));
    assert!(paywall::is_teaser(&short, Some(true), None, None));
    assert!(!paywall::is_teaser(&long, Some(true), None, None)); // 무료 건수 제한 사이트가 전문을 준 경우(Verge)
    assert!(paywall::is_teaser(&short, None, Some(PaywallKind::Hard), None));
    assert!(!paywall::is_teaser(&short, None, Some(PaywallKind::Metered), None));
    let mut stat = long.clone();
    stat.push(p("This article is exclusive to STAT+ subscribers. Unlock this article by subscribing."));
    assert!(paywall::is_teaser(&stat, None, None, None));
    let mut hk = short.clone();
    hk.push(p("한경 프리미엄9의 모든 콘텐츠는 한국경제신문의 저작물로 저작권법의 보호를 받습니다."));
    assert!(paywall::is_teaser(&hk, None, None, None));
}

// 군더더기: 줄 단위 규칙과 끝부분 자르기, 본문을 지우지 않는 안전장치
#[test]
fn junk_lines() {
    let mut blocks = vec![p("Pat Example"), p("is a news writer who covers streaming, consumer tech and social media.")];
    blocks.extend((1..=8).map(|n| p(&p_(n))));
    blocks.extend([
        p("reporter@example.co.kr"),
        p("좋아요 3 슬퍼요 0 화나요 1"),
        p("입력 2026.10.14 11:42 수정 2026.10.14 11:45"),
        p("Follow topics and authors from this story to see more like this in your personalized homepage feed."),
        p("Email (required)"),
        p("42 Comments"),
        p("Your browser does not support the audio element."),
        li(r#"Embed <iframe src="https://example.com/embed" width="100%"></iframe>"#),
        p("Copyright © 2026 Example News. All rights reserved."),
        p("Most read: another story headline that is not part of this article"),
        li("기사 스크랩"),
        li("공유"),
        li("프린트"),
    ]);
    let junk = body_cleanup::junk(&blocks);
    for i in 0..2 {
        assert!(junk.contains(&i), "머리 기자 소개 {i}");
    }
    for i in 2..10 {
        assert!(!junk.contains(&i), "본문 {i}");
    }
    for (i, b) in blocks.iter().enumerate().skip(10) {
        assert!(junk.contains(&i), "꼬리 {i}: {:?}", b.text);
    }
    // 번역 전에 빼기
    assert_eq!(body_cleanup::drop_junk(&blocks).len(), 8);
}

#[test]
fn junk_safety() {
    use std::collections::HashSet;
    // 저작권 줄 뒤가 본문의 절반을 넘으면(잘못 놓인 줄) 끝 자르기를 하지 않는다
    let mut blocks = vec![p(&p_(1)), p("ⓒ Example News")];
    blocks.extend((2..=10).map(|n| p(&p_(n))));
    assert_eq!(body_cleanup::junk(&blocks), HashSet::from([1]));
    // 긴 문단은 줄 규칙에 걸리지 않는다
    let mut long = vec![p(&format!("Copyright law {}", p_(1)))];
    long.extend((2..=5).map(|n| p(&p_(n))));
    assert!(body_cleanup::junk(&long).is_empty());
    // 같은 블록이 잇달아 두 번(부제·사진 설명 중복) — 뒤 것을 뺀다
    assert_eq!(body_cleanup::junk(&[p(&p_(1)), p(&p_(1)), p(&p_(2))]), HashSet::from([1]));
}

// 작은 그림(기자 사진 등)은 본래 크기보다 키우지 않는다
#[test]
fn small_images_not_upscaled() {
    assert_eq!(image_fit::max_width(96, 96), Some(96));
    assert_eq!(image_fit::max_width(300, 200), Some(300));
    assert_eq!(image_fit::max_width(1200, 800), None);
    assert_eq!(image_fit::max_width(0, 0), None);
}

// M: 맛보기·일부만 기사는 6시간 뒤 다시 받는다(그 밖은 그대로)
#[test]
fn short_cache_for_cut() {
    let now = chrono::Utc::now();
    let mut a = PreparedArticle::new("t", "t");
    a.stage = Stage::Done;
    a.saved_at = Some(now - chrono::Duration::hours(7));
    assert!(!dropcap_core::article::is_stale(&a, now));
    a.paywalled = Some(true);
    assert!(dropcap_core::article::is_stale(&a, now));
    a.saved_at = Some(now - chrono::Duration::hours(1));
    assert!(!dropcap_core::article::is_stale(&a, now));
    a.paywalled = None;
    a.partial = Some(true);
    a.saved_at = None; // 예전 기록(저장 시각 없음)도 다시
    assert!(dropcap_core::article::is_stale(&a, now));
    a.saved_at = Some(now + chrono::Duration::days(30)); // 미래 시각도 다시
    assert!(dropcap_core::article::is_stale(&a, now));
}

// '다시 받기': 맛보기 기사는 6시간이 지나면 캐시에서 꺼내지 않고 파일도 지운다. 예전 파일(새 칸 없음)도 읽힌다
#[test]
fn stale_cut_article_not_served_from_cache() {
    let dir = tempfile::tempdir().unwrap();
    let svc = dropcap_core::article::ArticleService::new(dir.path().to_path_buf());
    let link = "https://example.com/teaser";
    let path = dir.path().join("articles").join(dropcap_core::article::file_name(link));
    let old = r#"{"stage":3,"title":"t","originalTitle":"t","blocks":[],"paywalled":true}"#;
    std::fs::write(&path, old).unwrap();
    assert!(svc.cached(link).is_none());
    assert!(!path.exists());
    let normal = r#"{"stage":3,"title":"t","originalTitle":"t","blocks":[]}"#;
    std::fs::write(&path, normal).unwrap();
    assert!(svc.cached(link).is_some());
    svc.forget_cached(link);
    assert!(svc.cached(link).is_none() && !path.exists());
}
