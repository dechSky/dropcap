// 캐러셀·슬라이드 속 본문 글(mac/READER-CUT.md '5단계 결과', 규칙 carousel-slides) — 맥 CarouselTests 와 같은 꼴(웹 엔진 없는 빠른 길).
// 실제 꼴은 Google 블로그 큰 발표 기사(fixtures/reader-cut/carousel-cards — 맥 것 그대로, 글·주소를 바꾸고 표지 낱말만 원래 자리에), 나머지는 지어낸 HTML.
use dropcap_core::article::{extract_html, Block, BlockKind};

const BASE: &str = "https://example.com/2026/10/story";

fn para(n: usize) -> String {
    format!("Paragraph {n} explains how the harbor authority weighed the proposal, listened to residents and set out a schedule for the work.")
}
fn slide_text(n: usize) -> String {
    format!("Slide {n} shows the new pier at dawn while crews lift the last steel beam into place above the water.")
}
fn fixture(name: &str) -> String {
    std::fs::read_to_string(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/reader-cut").join(format!("{name}.html"))).unwrap()
}
fn blocks(html: &str) -> Vec<Block> {
    extract_html(html, BASE).map(|a| a.blocks).unwrap_or_default()
}
fn body(b: &Block) -> String {
    b.text.clone().or_else(|| b.src.clone()).unwrap_or_default()
}
fn at(b: &[Block], s: &str) -> Option<usize> {
    b.iter().position(|x| body(x).contains(s))
}
fn count(b: &[Block], s: &str) -> usize {
    b.iter().filter(|x| body(x).contains(s)).count()
}
fn page(middle: &str, after: &str) -> String {
    let a: String = (1..=4).map(|n| format!("<p>{}</p>", para(n))).collect();
    let z: String = (5..=8).map(|n| format!("<p>{}</p>", para(n))).collect();
    format!("<html><body><main><article><h1>Harbor plan</h1>{a}{middle}{z}</article>{after}</main></body></html>")
}

// 영상 카드 설명 · 속성에만 글이 든 인용 카드 · 영상 카드가 본문 사이에, 관련 기사 캐러셀은 본문 밖
#[test]
fn real_google_cards() {
    let b = blocks(&fixture("carousel-cards"));
    let before = at(&b, "BEFORECAR").expect("앞 글");
    let after = at(&b, "AFTERCAR").expect("뒤 소제목");
    let first = at(&b, "CARCAPA").expect("첫 캐러셀 첫 칸 설명");
    assert!(before < first && first < after, "본문 순서대로");
    assert_eq!(b[first].kind, BlockKind::P);
    let quote = at(&b, "CARQUOTE").expect("속성 quote= 의 인용");
    assert_eq!(b[quote].kind, BlockKind::Quote);
    assert!(body(&b[quote + 1]).contains("CARWHO"), "인용 바로 뒤 말한 사람");
    assert!(at(&b, "CARCAPZ").is_some(), "마지막 캐러셀 마지막 칸");
    assert_eq!((count(&b, "CARCAPA"), count(&b, "CARQUOTE")), (1, 1));
    assert!(at(&b, "RELCAR").is_none(), "본문 밖 관련 기사 캐러셀");
    assert_eq!(b.iter().filter(|x| x.kind == BlockKind::Quote).count(), 12);
}

// swiper 무한 돌기: 화면 밖 칸(aria-hidden)·복제 칸·돌려 놓은 차례(data-swiper-slide-index)
#[test]
fn swiper_offscreen_clones_and_order() {
    let slide = |i: usize, extra: &str| {
        format!(
            r#"<div class="swiper-slide{extra}" data-swiper-slide-index="{i}" aria-hidden="{}"><img src="https://img.example.com/s{i}.jpg"><div class="swiper-caption"><p>{}</p></div></div>"#,
            i != 1,
            slide_text(i)
        )
    };
    let html = page(
        &format!(
            r#"<div class="swiper gallery-swiper"><div class="swiper-wrapper">{}{}{}{}{}</div><div class="swiper-pagination"><span>1</span><span>2</span><span>3</span></div><button class="swiper-button-next">Next</button></div>"#,
            slide(2, " swiper-slide-duplicate"),
            slide(1, ""),
            slide(2, ""),
            slide(0, ""),
            slide(1, " swiper-slide-duplicate")
        ),
        "",
    );
    let b = blocks(&html);
    let idx: Vec<usize> = (0..3).map(|i| at(&b, &slide_text(i)).expect("화면 밖 칸도")).collect();
    assert!(idx[0] < idx[1] && idx[1] < idx[2], "칸 차례: {idx:?}");
    assert!((0..3).all(|i| count(&b, &slide_text(i)) == 1), "복제 칸 빼기");
    assert!((0..3).all(|i| b.iter().filter(|x| x.kind == BlockKind::Img && body(x).ends_with(&format!("s{i}.jpg"))).count() == 1), "칸 사진 한 번씩");
    assert!(at(&b, &para(4)).unwrap() < idx[0] && idx[0] < at(&b, &para(5)).unwrap(), "본문 순서");
    assert!(!b.iter().any(|x| matches!(x.text.as_deref(), Some("Next") | Some("1 2 3"))));
}

// slick 복제 칸 · aria-roledescription 캐러셀의 li 칸
#[test]
fn slick_clones_and_aria_slides() {
    let html = page(
        &format!(
            r#"<div class="slick-slider"><div class="slick-track"><div class="slick-slide slick-cloned"><p>{s4}</p></div><div class="slick-slide"><p>{s3}</p></div><div class="slick-slide"><p>{s4}</p></div></div></div><p>{p41}</p>
<section aria-roledescription="carousel"><ul><li aria-roledescription="slide"><figure><img src="https://img.example.com/a1.jpg"></figure><p>{s5}</p></li>
<li aria-roledescription="slide" aria-hidden="true"><figure><img src="https://img.example.com/a2.jpg"></figure><p>{s6}</p></li></ul></section>"#,
            s3 = slide_text(3),
            s4 = slide_text(4),
            s5 = slide_text(5),
            s6 = slide_text(6),
            p41 = para(41)
        ),
        "",
    );
    let b = blocks(&html);
    assert_eq!(count(&b, &slide_text(4)), 1, "slick 복제 칸");
    assert!(at(&b, &slide_text(3)).unwrap() < at(&b, &slide_text(4)).unwrap(), "복제 칸이 앞에 와도 차례대로");
    let (s5, s6) = (at(&b, &slide_text(5)).expect("li 칸 글"), at(&b, &slide_text(6)).expect("화면 밖 li 칸 글"));
    assert!(b.iter().any(|x| x.kind == BlockKind::Img && body(x).ends_with("a2.jpg")), "화면 밖 칸 사진");
    assert!(at(&b, &para(41)).unwrap() < s5 && s5 < s6 && s6 < at(&b, &para(5)).unwrap());
}

// 본문 사이에 있어도 칸 글이 거의 링크인 추천 줄 · 본문 뒤 캐러셀 · aside 안 캐러셀은 넣지 않는다
#[test]
fn recommend_carousels_stay_out() {
    let cards: String = (1..=4)
        .map(|i| format!(r#"<div class="swiper-slide"><a href="/s{i}"><img src="https://img.example.com/r{i}.jpg"><span>Recommended headline number {i} about the city budget</span></a></div>"#))
        .collect();
    let html = page(
        &format!(r#"<div class="swiper"><div class="swiper-wrapper">{cards}</div></div>"#),
        r#"<div class="owl-carousel"><div class="owl-item"><p>Gallery card seven</p></div><div class="owl-item"><p>Gallery card eight</p></div></div>
<aside><div aria-roledescription="carousel"><div aria-roledescription="slide"><p>Sidebar card ten</p></div></div></aside>"#,
    );
    let b = blocks(&html);
    assert!(at(&b, "Recommended headline").is_none());
    assert!(at(&b, "Gallery card").is_none(), "본문 뒤 캐러셀");
    assert!(at(&b, "Sidebar card").is_none(), "aside 안 캐러셀");
    assert!(at(&b, &para(8)).is_some());
}

// 칸이 없는 'carousel' 상자는 그대로
#[test]
fn no_carousel_unchanged() {
    let b = blocks(&page(&format!(r#"<div class="carousel-note"><p>{}</p></div>"#, para(40)), ""));
    assert_eq!(count(&b, &para(40)), 1);
    assert_eq!(b.iter().filter(|x| x.kind == BlockKind::P).count(), 9);
}
