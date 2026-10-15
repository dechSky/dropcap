// 읽기 창 따라잡기(R-08 · R-19 · R-20 · R-21 · R-22): 맥 ReaderSaveTests(ReaderFind) · CoreTests(BodyCleanup) ·
// ReadSweepTests(CoverPick.ogImage) · E2EScenarioTests(translationLabel) 를 옮기고, 리눅스 쪽 셈(표지 판단·사진 글자 줄)을 더한 것
use dropcap_core::article::{body_cleanup, engine_label, merge_translated, Block, BlockKind};
use dropcap_core::cover_pick::{self, CoverChoice};
use dropcap_core::image_text;
use dropcap_core::reader_find::{self, Match};

fn p(t: &str) -> Block {
    Block { kind: BlockKind::P, text: Some(t.into()), src: None, original: None }
}
fn img(u: &str) -> Block {
    Block { kind: BlockKind::Img, text: None, src: Some(u.into()), original: None }
}
fn cap(t: &str) -> Block {
    Block { kind: BlockKind::Cap, text: Some(t.into()), src: None, original: None }
}

// MARK: R-19 찾기
#[test]
fn find_case_and_accent_insensitive() {
    assert_eq!(reader_find::ranges("OpenAI and openai and Café", "OPENAI").len(), 2);
    assert_eq!(reader_find::ranges("Café cafe", "cafe").len(), 2);
    assert_eq!(reader_find::ranges("cafe", "CAFÉ").len(), 1);
    assert_eq!(reader_find::ranges("모델 모델모델", "모델").len(), 3);
    assert_eq!(reader_find::ranges("aaa", "aa").len(), 1); // 겹치지 않게
    assert!(reader_find::ranges("abc", "  ").is_empty());
    // 전각 영문(맥 widthInsensitive)
    assert_eq!(reader_find::ranges("ＡＩ 시대", "ai").len(), 1);
    // 조합용 악센트(e + U+0301)도 같은 글자로, 범위는 악센트까지
    let t = "cafe\u{301} 메뉴";
    let r = reader_find::ranges(t, "café");
    assert_eq!(r.len(), 1);
    assert_eq!(&t[r[0].0..r[0].1], "cafe\u{301}");
    // 바이트 범위(pango 속성)
    assert_eq!(reader_find::ranges("Ünïcode ünicode", "unicode"), vec![(0, 9), (10, 18)]);
    let s = "새 모델 공개, 모델";
    let r = reader_find::ranges(s, "모델");
    assert_eq!(&s[r[1].0..r[1].1], "모델");
}

#[test]
fn find_matches_across_pieces_in_order() {
    let pieces: Vec<String> = ["GPT 소식", "GPT-6 와 GPT-5", "없음", "gpt"].iter().map(|s| s.to_string()).collect();
    let m = reader_find::matches(&pieces, "gpt");
    assert_eq!(
        m,
        vec![Match { piece: 0, nth: 0 }, Match { piece: 1, nth: 0 }, Match { piece: 1, nth: 1 }, Match { piece: 3, nth: 0 }]
    );
}

#[test]
fn find_steps_wrap_around_and_count() {
    assert_eq!(reader_find::step(3, 4, true), 0);
    assert_eq!(reader_find::step(0, 4, false), 3);
    assert_eq!(reader_find::step(0, 0, true), 0);
    assert_eq!(reader_find::count_text("", 0, 0), "");
    assert_eq!(reader_find::count_text("x", 0, 0), "없음");
    assert_eq!(reader_find::count_text("x", 3, 1), "2/3");
}

// MARK: R-21 본문 다듬기
#[test]
fn bylines() {
    assert_eq!(body_cleanup::byline("김가람 기자 reporter@example.com").as_deref(), Some("김가람 기자"));
    assert_eq!(body_cleanup::byline("이나래 기자 desk@example.com Powered by AI").as_deref(), Some("이나래 기자"));
    assert_eq!(body_cleanup::byline("이나래 기자 desk@example.com Powered by Example AI Solution").as_deref(), Some("이나래 기자"));
    assert_eq!(body_cleanup::byline("By Jane Doe").as_deref(), Some("By Jane Doe"));
    assert_eq!(body_cleanup::byline("김가람 기자는 이날 현장에서 다음과 같이 말했다."), None);
}

#[test]
fn orphan_captions() {
    assert!(body_cleanup::is_orphan_caption("AI 생성 영상", false));
    assert!(body_cleanup::is_orphan_caption("사진=연합뉴스", false));
    assert!(!body_cleanup::is_orphan_caption("사진=연합뉴스", true));
    assert!(!body_cleanup::is_orphan_caption("여수시 여문문화의거리가 정원과 공연을 결합한 축제 공간으로 활용되고 있다.", false));
}

#[test]
fn hidden_blocks_byline_cover_and_its_caption() {
    let blocks = vec![
        img("https://img.example.com/news/photo01-1200x800.jpg"), // 0 표지와 같은 사진(크기 표기만 다름)
        cap("행사장 모습"),                                       // 1 그 설명도 뺌
        p("김가람 기자 reporter@example.com"),                   // 2 바이라인으로
        p("사진=예시통신"),                                       // 3 사진 없이 남은 설명
        p("본문 첫 문단입니다."),                                // 4
        img("https://img.example.com/news/other.jpg"),          // 5 다른 사진은 둠
        cap("다른 사진 설명"),                                    // 6
        img("https://img.example.com/reporter/avatar.png"),     // 7 잡그림
        cap("프로필"),                                            // 8 잡그림의 설명도
        p("사진=예시통신"),                                       // 9 바로 뒤가 사진이면 둠
        img("https://img.example.com/news/third.jpg"),          // 10
    ];
    let hidden = body_cleanup::hidden(&blocks, Some("https://img.example.com/news/photo01.jpg"));
    let mut h: Vec<usize> = hidden.into_iter().collect();
    h.sort();
    assert_eq!(h, vec![0, 1, 2, 3, 7, 8]);
    assert_eq!(body_cleanup::analyze(&blocks).1.as_deref(), Some("김가람 기자"));
    // 표지가 없으면 사진은 그대로
    let h2 = body_cleanup::hidden(&blocks[..2], None);
    assert!(h2.is_empty());
}

#[test]
fn byline_from_original_when_translated_and_joined() {
    let mut b = p("Reporter Kim");
    b.original = Some("김가람 기자".into());
    let blocks = vec![b, p("이나래 특파원"), p("김가람 기자")];
    let (skip, by) = body_cleanup::analyze(&blocks);
    assert_eq!(skip.len(), 3);
    assert_eq!(by.as_deref(), Some("김가람 기자 · 이나래 특파원"));
}

// MARK: R-22 표지 사진
#[test]
fn og_image_parsing() {
    let base = Some("https://www.dw.com/en/a/a-1");
    // DW: og:image:type 이 og:image 보다 앞에 있고 content 가 먼저 — 예전 정규식은 'image/jpeg' 를 주소로 잡았다
    let dw = r#"<meta content="image/jpeg" property="og:image:type"><meta content="https://static.dw.com/image/1_6.jpg" property="og:image">"#;
    assert_eq!(cover_pick::og_image(dw, base).as_deref(), Some("https://static.dw.com/image/1_6.jpg"));
    assert_eq!(
        cover_pick::og_image(r#"<meta property="og:image" content="/img/a.jpg?x=1&amp;y=2">"#, base).as_deref(),
        Some("https://www.dw.com/img/a.jpg?x=1&y=2")
    );
    assert_eq!(cover_pick::og_image(r#"<meta name="twitter:image" content="https://t.co/p.png">"#, base).as_deref(), Some("https://t.co/p.png"));
    assert_eq!(cover_pick::og_image(r#"<meta property="og:image:type" content="image/png"><meta property="og:image:width" content="1200">"#, base), None);
    assert_eq!(cover_pick::og_image(r#"<meta property="og:image" content="javascript:alert(1)">"#, base), None);
    assert_eq!(cover_pick::og_image(r#"<META NAME='twitter:image' CONTENT=https://t.co/q.jpg>"#, base).as_deref(), Some("https://t.co/q.jpg"));
    assert_eq!(
        cover_pick::og_image(r#"<meta data-content="x" property="og:image" content="https://a.com/1.jpg">"#, base).as_deref(),
        Some("https://a.com/1.jpg")
    );
    // <metadata> 는 meta 가 아님, og:image 가 secure_url 보다 먼저
    let both = r#"<metadata property="og:image" content="https://x.com/no.jpg"><meta property="og:image:secure_url" content="https://a.com/s.jpg"><meta property="og:image" content="https://a.com/o.jpg">"#;
    assert_eq!(cover_pick::og_image(both, base).as_deref(), Some("https://a.com/o.jpg"));
    // 닫히지 않은 <meta 가 수만 개여도 금방 끝난다
    let t0 = std::time::Instant::now();
    let _ = cover_pick::og_image(&"<meta property=og:image content=".repeat(6000), base);
    assert!(t0.elapsed().as_secs_f64() < 2.0);
}

#[test]
fn cover_choice() {
    let junk = |u: &str| u.contains("logo");
    let feed = Some("https://a.com/feed.jpg");
    let og = Some("https://a.com/og.jpg");
    // 피드 사진이 400px 이상이면 그대로(기사 머리는 보지 않음)
    assert!(!cover_pick::needs_og(feed, Some(400)));
    assert_eq!(cover_pick::choose(feed, Some(800), og, Some(1200), junk), CoverChoice::Keep);
    // 작은 미리보기(280px) → 큰 og:image 로, og 도 작으면 그대로
    assert!(cover_pick::needs_og(feed, Some(280)));
    assert_eq!(cover_pick::choose(feed, Some(280), og, Some(1200), junk), CoverChoice::Use("https://a.com/og.jpg".into()));
    assert_eq!(cover_pick::choose(feed, Some(280), og, Some(300), junk), CoverChoice::Keep);
    // 피드 사진을 못 받으면 og 는 크기와 상관없이, og 도 없으면 깨진 자리를 지움
    assert_eq!(cover_pick::choose(feed, None, og, Some(300), junk), CoverChoice::Use("https://a.com/og.jpg".into()));
    assert_eq!(cover_pick::choose(feed, None, None, None, junk), CoverChoice::Remove);
    assert_eq!(cover_pick::choose(feed, None, og, None, junk), CoverChoice::Remove); // og 도 못 받음
    // 아는 사진이 없으면 og 를 그대로, 잡그림·같은 주소는 쓰지 않음
    assert_eq!(cover_pick::choose(None, None, og, Some(200), junk), CoverChoice::Use("https://a.com/og.jpg".into()));
    assert_eq!(cover_pick::choose(None, None, Some("https://a.com/logo.png"), Some(900), junk), CoverChoice::Keep);
    assert_eq!(cover_pick::choose(feed, Some(100), feed, Some(100), junk), CoverChoice::Keep);
    assert!(cover_pick::big_enough(cover_pick::MIN_WIDTH) && !cover_pick::big_enough(399));
}

// MARK: R-08 번역 표시
#[test]
fn translation_label() {
    assert_eq!(engine_label(0, 5, "Google 번역"), "");
    assert_eq!(engine_label(2, 5, "Google 번역"), "Google 번역 · 일부 번역");
    assert_eq!(engine_label(5, 5, "Google 번역"), "Google 번역");
}

#[test]
fn merge_counts_only_changed_foreign_paragraphs() {
    let src = vec![
        p("The model was released today."),      // 0 번역됨
        p("이미 한국어 문단입니다."),              // 1 외국어 아님 — 세지 않음
        p("Translation failed for this one."),   // 2 번역 실패(원문 그대로) — 원문 보기 대상 아님
        img("https://a.com/x.jpg"),
    ];
    let mut blocks = src.clone();
    let out: Vec<String> =
        vec!["모델이 오늘 공개됐다.".into(), "이미 한국어 문단입니다.".into(), "Translation failed for this one.".into()];
    let (done, total) = merge_translated(&mut blocks, &src, &[0, 1, 2], &out);
    assert_eq!((done, total), (1, 2));
    assert_eq!(blocks[0].text.as_deref(), Some("모델이 오늘 공개됐다."));
    assert_eq!(blocks[0].original.as_deref(), Some("The model was released today."));
    assert_eq!(blocks[1].original, None);
    assert_eq!(blocks[2].original, None);
    assert_eq!(blocks[2].text.as_deref(), Some("Translation failed for this one."));
    assert_eq!(engine_label(done, total, "Google 번역"), "Google 번역 · 일부 번역");
    // 모두 실패(오프라인) → 표시 없음
    let mut b2 = src.clone();
    let same: Vec<String> = src[..3].iter().map(|b| b.text.clone().unwrap()).collect();
    let (d, t) = merge_translated(&mut b2, &src, &[0, 1, 2], &same);
    assert_eq!((d, t), (0, 2));
    assert_eq!(engine_label(d, t, "Google 번역"), "");
    assert_eq!(b2, src);
}

// MARK: R-20 사진 속 글자
#[test]
fn ocr_lines_from_tsv() {
    let tsv = "level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext\n\
1\t1\t0\t0\t0\t0\t0\t0\t200\t100\t-1\t\n\
5\t1\t1\t1\t1\t1\t10\t10\t40\t20\t91\tHello\n\
5\t1\t1\t1\t1\t2\t60\t12\t50\t20\t88\tworld\n\
5\t1\t1\t1\t1\t3\t120\t12\t10\t20\t12\t~~\n\
5\t1\t2\t1\t1\t1\t20\t60\t20\t20\t90\t안\n\
5\t1\t2\t1\t1\t2\t40\t60\t20\t20\t90\t녕\n";
    let lines = image_text::lines_from_tsv(tsv, 200.0, 100.0);
    assert_eq!(lines.len(), 2);
    assert_eq!(lines[0].text, "Hello world"); // 신뢰도 30 밑(~~)은 뺌
    assert!((lines[0].x - 0.05).abs() < 1e-9 && (lines[0].y - 0.10).abs() < 1e-9);
    assert!((lines[0].w - 0.50).abs() < 1e-9 && (lines[0].h - 0.22).abs() < 1e-9);
    assert_eq!(lines[1].text, "안녕"); // 한글 낱자는 붙인다
    assert_eq!(image_text::foreign_lines(&lines), vec![0]);
    assert!(image_text::lines_from_tsv(tsv, 0.0, 100.0).is_empty());
}

#[test]
fn ocr_background_and_texts() {
    // 흰 바탕에 검은 글자 띠: 바탕색은 띠 바깥(흰색)
    let mut im = image::RgbImage::from_pixel(100, 100, image::Rgb([250, 250, 250]));
    for y in 40..60 {
        for x in 10..90 {
            im.put_pixel(x, y, image::Rgb([0, 0, 0]));
        }
    }
    let dynimg = image::DynamicImage::ImageRgb8(im);
    let l = image_text::lines_from_tsv(
        "h\n5\t1\t1\t1\t1\t1\t10\t40\t80\t20\t95\tTEXT\n",
        100.0,
        100.0,
    );
    let bg = image_text::average_color(&dynimg, &l[0]);
    assert_eq!(bg, (250, 250, 250));
    assert!(image_text::dark_text_on(bg));
    assert!(!image_text::dark_text_on((20, 30, 40)));
    assert_eq!(image_text::stage_text(image_text::Stage::Done, 3), "3줄 번역");
    assert_eq!(image_text::stage_text(image_text::Stage::NoText, 0), "사진에서 글자를 찾지 못했습니다");
    assert!(image_text::stage_text(image_text::Stage::NoTool, 0).contains("tesseract"));
    assert_eq!(image_text::save_name("https://img.example.com/a/b/photo%20one.jpg?w=1"), "photo one.png");
    assert_eq!(image_text::save_name("https://img.example.com/"), "image.png");
    assert_eq!(image_text::save_name(&format!("https://img.example.com/{}.jpg", "x".repeat(90))), "image.png");
}
