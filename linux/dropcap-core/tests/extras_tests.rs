// 맥 ExtrasTests.swift 를 옮긴 것: 유료 기사 표시·무료 보도 안내 · 회의 중 조용히 · 오늘 호 완독 · 분야별 저녁 정리 · 분야 대표 사진 점수
// + 기사 읽기 짧은 글 추출(맥 8e9fde9).
use chrono::{Duration, TimeZone, Utc};
use dropcap_core::article::{self, Article, Block, BlockKind};
use dropcap_core::brief::{self, SectionBrief};
use dropcap_core::database::{Database, ExtractStat};
use dropcap_core::focus_guard::{self, EventInfo, FocusReason};
use dropcap_core::magazine::Section;
use dropcap_core::models::{resources, NewsItem, Source};
use dropcap_core::paywall::{self, PaywallKind};
use dropcap_core::photo_quality as pq;
use dropcap_core::sections::{self, SourceMeta};
use dropcap_core::store::{AppState, Settings};
use dropcap_core::today_issue;
use image::{DynamicImage, Rgb, RgbImage};
use std::collections::{HashMap, HashSet};

fn news(id: &str, source: &str, tier: &str, mins_ago: i64) -> NewsItem {
    let mut it = NewsItem::new(id, &format!("Title {id}"), &format!("https://{source}.example/{id}"), source, &source.to_uppercase(), tier);
    it.summary = format!("summary {id}");
    it.date = Some(Utc::now() - Duration::minutes(mins_ago));
    it
}

fn meta() -> HashMap<String, SourceMeta> {
    let json = r#"{"sources":[{"id":"wsj","paywall":"hard"},{"id":"nyt","paywall":"metered"},{"id":"verge"},{"id":"yna"}]}"#;
    sections::parse_meta(json)
}

fn p(t: &str) -> Block {
    serde_json::from_value(serde_json::json!({"type": "p", "text": t})).unwrap()
}

// MARK: 1. 유료 기사(G-14 · G-15)
#[test]
fn declared_beats_domain_and_learning() {
    let m = meta();
    let none = HashMap::new();
    assert_eq!(paywall::kind("wsj", "https://www.wsj.com/a", &m, &none), Some(PaywallKind::Hard));
    assert_eq!(paywall::kind("nyt", "https://www.nytimes.com/a", &m, &none), Some(PaywallKind::Metered));
    assert_eq!(paywall::kind("verge", "https://www.theverge.com/a", &m, &none), None);
}

#[test]
fn custom_sources_use_known_domains_including_subdomains() {
    assert_eq!(paywall::domain_kind("https://www.ft.com/content/1"), Some(PaywallKind::Hard));
    assert_eq!(paywall::domain_kind("https://edition.economist.com/x"), Some(PaywallKind::Hard));
    assert_eq!(paywall::domain_kind("https://cooking.nytimes.com/r"), Some(PaywallKind::Metered));
    assert_eq!(paywall::domain_kind("https://notft.com/x"), None);
    assert_eq!(paywall::domain_kind("https://ft.com.evil.example/x"), None);
    assert_eq!(paywall::kind("custom-1", "https://www.bloomberg.com/news/a", &meta(), &HashMap::new()), Some(PaywallKind::Hard));
}

#[test]
fn learns_from_failure_rate_only_after_enough_tries() {
    let m = meta();
    let st = |t, f, b| HashMap::from([("verge".to_string(), ExtractStat { tries: t, fails: f, blocked: b })]);
    assert_eq!(paywall::kind("verge", "https://www.theverge.com/a", &m, &st(4, 4, 0)), None);
    assert_eq!(paywall::kind("verge", "https://www.theverge.com/a", &m, &st(10, 4, 3)), Some(PaywallKind::Learned));
    assert_eq!(paywall::kind("verge", "https://www.theverge.com/a", &m, &st(10, 2, 1)), None);
}

#[test]
fn teaser_with_subscribe_prompt_looks_blocked() {
    assert!(paywall::looks_blocked(&[p("The central bank surprised markets on Tuesday."), p("Subscribe to continue reading this article.")]));
    assert!(paywall::looks_blocked(&[p("기사 첫 문단입니다."), p("이 기사는 유료 회원만 볼 수 있습니다.")]));
    let mut long: Vec<Block> = (0..8).map(|_| p(&"Full paragraph of the story. ".repeat(10))).collect();
    long.push(p("Subscribe to read more stories like this."));
    assert!(!paywall::looks_blocked(&long)); // 본문이 충분하면 끝의 구독 권유는 무시
    assert!(!paywall::looks_blocked(&[p("Short but free note.")]));
}

#[test]
fn free_alternatives_skip_paywalled_hidden_self_and_channels() {
    let me = news("1", "wsj", "press", 0);
    let mut video = news("7", "tube", "press", 0);
    video.kind = Some("video".into());
    let story = vec![
        me.clone(),
        news("2", "nyt", "press", 0), // metered — 열리지 않을 수 있어 권하지 않음
        news("3", "verge", "press", 1),
        news("4", "yna", "kr", 60),
        news("5", "hidden", "press", 0),
        news("6", "verge", "press", 0), // 같은 출처 두 번은 한 번만
        video,
    ];
    let alts = paywall::free_alternatives(&me, &story, &HashSet::from(["hidden".to_string()]), &meta(), &HashMap::new(), 3);
    assert_eq!(alts.iter().map(|a| a.id.as_str()).collect::<Vec<_>>(), vec!["4", "6"]); // 국내 먼저, 그다음 언론 최신
}

#[test]
fn free_reason_order() {
    assert_eq!(paywall::free_reason(false, true, true, Some(PaywallKind::Hard)), None); // 대안이 없으면 상자 없음
    assert_eq!(paywall::free_reason(true, true, false, None), Some("본문을 열지 못했습니다"));
    assert_eq!(paywall::free_reason(true, false, true, None), Some("구독자만 읽을 수 있는 기사입니다"));
    assert_eq!(paywall::free_reason(true, false, false, Some(PaywallKind::Hard)), Some("유료 기사입니다"));
    assert_eq!(paywall::free_reason(true, false, false, Some(PaywallKind::Learned)), Some("이곳 기사는 자주 막힙니다"));
    assert_eq!(paywall::free_reason(true, false, false, Some(PaywallKind::Metered)), None); // metered 는 먼저 권하지 않음
}

#[test]
fn sources_json_marks_known_paywalls() {
    let all = &resources::CONFIG.sources;
    for s in all.iter().filter(|s| s.paywall.is_some()) {
        assert!(["hard", "metered"].contains(&s.paywall.as_deref().unwrap()), "{}", s.id);
    }
    assert_eq!(all.iter().find(|s| s.id == "wsj-markets").and_then(|s| s.paywall.clone()).as_deref(), Some("hard"));
    assert!(all.iter().filter(|s| s.id.starts_with("nyt-")).all(|s| s.paywall.as_deref() == Some("hard"))); // 앱은 403 으로 못 읽음(sources-audit)
    assert_eq!(all.iter().find(|s| s.id == "verge").and_then(|s| s.paywall.clone()).as_deref(), Some("metered")); // 구독 문·isAccessibleForFree=false
    assert_eq!(sections::META.get("wsj-markets").and_then(|m| m.paywall.clone()).as_deref(), Some("hard"));
}

#[test]
fn old_custom_source_without_paywall_still_decodes() {
    let old = r##"{"id":"custom-x","name":"X","tier":"press","type":"feed","url":"https://x.example/feed","aiOnly":false,"defaultOn":true,"color":"#000"}"##;
    assert_eq!(serde_json::from_str::<Source>(old).unwrap().paywall, None);
}

#[test]
fn extract_stats_accumulate_and_decay() {
    let db = Database::in_memory();
    db.record_extract("a", true, false);
    db.record_extract("a", false, true);
    db.record_extract("a", false, false);
    assert_eq!(db.extract_stats()["a"], ExtractStat { tries: 3, fails: 1, blocked: 1 });
    for _ in 0..60 {
        db.record_extract("b", true, false);
    }
    let b = db.extract_stats()["b"];
    assert!(b.tries <= 50 && b.tries > 20 && b.fail_rate() == 1.0); // 50번이 넘으면 반으로 줄어 최근 결과가 크게
}

// MARK: 2. 회의·발표 중 자동 조용히(N-25)
#[test]
fn sharing_helpers() {
    assert!(focus_guard::sharing(&["bash".into(), "obs".into()]));
    assert!(focus_guard::sharing(&["simplescreenrec".into()]));
    assert!(!focus_guard::sharing(&["zoom".into(), "firefox".into(), "pipewire".into()])); // Zoom 이 켜져 있기만 한 것·PipeWire 는 아님
}

#[test]
fn calendar_events_count_only_busy_timed_ones() {
    let now = Utc::now();
    let ev = |s: i64, e: i64, all_day, free, declined| EventInfo {
        start: now + Duration::seconds(s),
        end: now + Duration::seconds(e),
        all_day,
        free,
        declined,
    };
    assert!(focus_guard::in_event(&[ev(-600, 600, false, false, false)], now));
    assert!(!focus_guard::in_event(&[ev(-600, 600, true, false, false)], now));
    assert!(!focus_guard::in_event(&[ev(-600, 600, false, true, false)], now));
    assert!(!focus_guard::in_event(&[ev(-600, 600, false, false, true)], now));
    assert!(!focus_guard::in_event(&[ev(-1200, -60, false, false, false), ev(60, 1200, false, false, false)], now));
    assert!(!focus_guard::in_event(&[ev(-600, 0, false, false, false)], now)); // 끝나는 순간에는 풀림
}

#[test]
fn settings_defaults_for_old_files() {
    let old: Settings = serde_json::from_str(r#"{"style":"drop","quietEnabled":true}"#).unwrap();
    assert!(old.auto_quiet_fullscreen && old.auto_quiet_sharing && !old.auto_quiet_calendar);
    assert!(old.quiet_enabled);
    let mut s = Settings::default();
    s.auto_quiet_calendar = true;
    s.auto_quiet_sharing = false;
    let back: Settings = serde_json::from_str(&serde_json::to_string(&s).unwrap()).unwrap();
    assert!(back.auto_quiet_calendar && !back.auto_quiet_sharing && back.auto_quiet_fullscreen);
    // 맥 상태 파일과 같은 이름
    let v = serde_json::to_value(&s).unwrap();
    assert!(v.get("autoQuietFullscreen").is_some() && v.get("autoQuietSharing").is_some() && v.get("autoQuietCalendar").is_some());
}

#[test]
fn override_and_probe_silence_like_quiet_hours() {
    let m = &focus_guard::MONITOR;
    m.set_override(Some(Some(FocusReason::Calendar)));
    assert_eq!(m.reason(&Settings::default()), Some(FocusReason::Calendar));
    m.set_override(Some(None));
    assert_eq!(m.reason(&Settings::default()), None);
    m.set_override(None);
    // 전체 화면 감지는 화면 쪽이 넣어 준다. 설정에서 끄면 보지 않는다
    m.set_fullscreen_probe(Box::new(|| true));
    assert_eq!(m.reason(&Settings::default()), Some(FocusReason::Fullscreen));
    let mut off = Settings::default();
    off.auto_quiet_fullscreen = false;
    off.auto_quiet_sharing = false;
    m.invalidate();
    assert_eq!(m.reason(&off), None);
    m.set_fullscreen_probe(Box::new(|| false));
}

// MARK: 3. 오늘 호 완독(M-23)
fn page(section: Option<&str>, ids: &[&str], kind: Option<&str>) -> (Section, Vec<NewsItem>) {
    let sec = Section {
        category: dropcap_core::category::NewsCategory::other(),
        keys: ids.iter().map(|i| format!("s|{i}")).collect(),
        kind: kind.map(|k| k.into()),
        section: section.map(|s| s.into()),
    };
    (sec, ids.iter().map(|i| news(i, "s", "press", 0)).collect())
}

#[test]
fn representative_keys() {
    let pages = vec![
        page(Some("top"), &["t1", "t2", "t3", "t4"], None),
        page(Some("economy"), &["e1", "t1", "e2", "e3", "e4"], None),
        page(Some("sports"), &["s1", "s2"], None), // 고르지 않은 분야
        page(Some("ai"), &["a1"], None),
        page(None, &["o1", "o2"], None),          // 그 밖의 소식
        page(None, &["v1"], Some("video")),       // 구독 채널
    ];
    let chosen: Vec<String> = ["top", "economy", "ai"].iter().map(|s| s.to_string()).collect();
    let keys = today_issue::keys(Some("c"), &pages, &chosen);
    assert_eq!(keys, vec!["c", "s|t1", "s|t2", "s|t3", "s|e1", "s|e2", "s|a1"]); // 경제 첫 줄의 t1 은 주요 뉴스와 겹쳐 한 번만
    assert!(today_issue::keys(None, &[], &["ai".to_string()]).is_empty());
}

#[test]
fn next_issue_text() {
    assert_eq!(today_issue::next_issue_text(true, 9), "다음 호는 내일 오전 9시 브리핑으로 알려 드릴게요");
    assert_eq!(today_issue::next_issue_text(true, 12), "다음 호는 내일 오후 12시 브리핑으로 알려 드릴게요");
    assert_eq!(today_issue::next_issue_text(false, 9), "다음 호는 내일 아침에 엮여요");
}

#[test]
fn done_mark_lasts_only_that_day() {
    let d = tempfile::tempdir().unwrap();
    let today = Utc::now();
    let mut p = dropcap_core::store::Prefs::load(d.path());
    assert!(!today_issue::is_marked_done(&p, today));
    today_issue::mark_done(&mut p, today);
    assert!(today_issue::is_marked_done(&p, today));
    assert!(!today_issue::is_marked_done(&p, today + Duration::hours(24)));
    // 파일로 오가도 그대로(예전 prefs.json 에는 없음)
    p.save(d.path());
    assert!(today_issue::is_marked_done(&dropcap_core::store::Prefs::load(d.path()), today));
}

// MARK: 4. 분야별 저녁 정리(N-26)
#[test]
fn parses_lines_with_evidence() {
    let text = "오늘 경제 소식입니다.\n- 한국은행이 기준금리를 동결했다 [1][3]\n• 코스피가 반도체 강세로 올랐다 [2]\n- 근거 없는 문장은 버린다\n- 범위 밖 번호만 단 줄도 버린다 [9]\n- 환율은 1,380원대에서 움직였다 [4] [4]\n- 네 번째 줄은 잘린다 [1]";
    let lines = brief::parse(text, 4).unwrap();
    assert_eq!(lines.iter().map(|l| l.text.as_str()).collect::<Vec<_>>(), vec!["한국은행이 기준금리를 동결했다", "코스피가 반도체 강세로 올랐다", "환율은 1,380원대에서 움직였다"]);
    assert_eq!(lines.iter().map(|l| l.refs.clone()).collect::<Vec<_>>(), vec![vec![0, 2], vec![1], vec![3]]);
    assert_eq!(brief::parse("- 근거가 없다\n- 역시 없다", 3), None);
}

#[test]
fn prompt_carries_original_titles_and_sources() {
    let mut a = news("1", "yna", "kr", 0);
    a.title = "Fed holds rates".into();
    a.title_ko = Some("연준 금리 동결".into());
    let mut b = news("2", "cnbc", "press", 0);
    b.title = "Stocks rally".into();
    let pr = brief::prompt("경제", &[a, b]);
    assert!(pr.contains("[1] Fed holds rates (연준 금리 동결) — YNA"));
    assert!(pr.contains("[2] Stocks rally — CNBC"));
    assert!(pr.starts_with("분야: 경제"));
}

#[test]
fn brief_survives_state_round_trip_and_old_state_has_none() {
    let at = Utc.timestamp_opt(1_800_000_000, 0).unwrap();
    let mut it = news("1", "yna", "kr", 0);
    it.date = Some(at);
    let mut s = AppState::default();
    s.briefs.insert(
        "economy".into(),
        SectionBrief { section: "economy".into(), at, items: vec![it], lines: Some(vec![brief::Line { text: "금리 동결".into(), refs: vec![0] }]) },
    );
    let back: AppState = serde_json::from_str(&serde_json::to_string(&s).unwrap()).unwrap();
    assert_eq!(back.briefs, s.briefs);
    let old: AppState = serde_json::from_str("{}").unwrap();
    assert!(old.briefs.is_empty());
    // 맥이 쓴 모양(날짜 ISO 글자)도 읽는다
    let mac = r#"{"briefs":{"economy":{"section":"economy","at":"2027-01-15T08:00:00Z","items":[],"lines":[{"text":"x","refs":[0]}]}}}"#;
    let m: AppState = serde_json::from_str(mac).unwrap();
    assert_eq!(m.briefs["economy"].lines.as_ref().unwrap()[0].text, "x");
    // 요약이 없거나 다른 날이면 보이지 않음
    let today = SectionBrief { section: "a".into(), at: Utc::now(), items: vec![], lines: None };
    assert!(!today.shown_on(Utc::now()));
    let old_day = SectionBrief { section: "a".into(), at: Utc::now() - Duration::days(2), items: vec![], lines: Some(vec![]) };
    assert!(!old_day.shown_on(Utc::now()));
}

// MARK: 5. 분야 대표 사진 점수(M-24)
// 사진 같은 그림: 부드러운 색 변화 + 잡음
fn photo() -> DynamicImage {
    let mut seed: u32 = 12345;
    let mut rnd = move || {
        seed = seed.wrapping_mul(1103515245).wrapping_add(12345);
        ((seed >> 16) & 0x7fff) as f64 / 32767.0 * 0.24 - 0.12
    };
    let mut img = RgbImage::new(960, 540);
    for by in (0..540).step_by(6) {
        for bx in (0..960).step_by(6) {
            let n = rnd();
            let (x, y) = (bx as f64, by as f64);
            let c = |v: f64| ((v + n).clamp(0.0, 1.0) * 255.0) as u8;
            let col = Rgb([c(0.2 + 0.6 * x / 960.0), c(0.35 + 0.4 * (y / 80.0).sin()), c(0.5 + 0.3 * ((x + y) / 120.0).cos())]);
            for dy in 0..6 {
                for dx in 0..6 {
                    if bx + dx < 960 && by + dy < 540 {
                        img.put_pixel(bx + dx, by + dy, col);
                    }
                }
            }
        }
    }
    DynamicImage::ImageRgb8(img)
}

// 웹사이트 화면 캡처: 흰 바탕에 글자 줄이 빽빽(글자 = 2px 획으로 그린 작은 칸들)
fn screenshot() -> DynamicImage {
    let mut img = RgbImage::from_pixel(1280, 800, Rgb([255, 255, 255]));
    let mut seed: u32 = 7;
    for i in 0..16u32 {
        let y0 = 24 + i * 48;
        for c in 0..60u32 {
            let x0 = 40 + c * 17;
            seed = seed.wrapping_mul(1103515245).wrapping_add(12345);
            if (seed >> 16) % 7 == 0 {
                continue; // 낱말 사이 빈칸
            }
            for y in y0..y0 + 22 {
                for x in x0..x0 + 13 {
                    let (dx, dy) = (x - x0, y - y0);
                    let stroke = dx < 2 || (dx >= 6 && dx < 8 && (seed >> 20) % 2 == 0) || dy < 2 || (dy >= 10 && dy < 12) || ((seed >> 18) % 3 == 0 && dy >= 20);
                    if stroke {
                        img.put_pixel(x, y, Rgb([25, 25, 25]));
                    }
                }
            }
        }
    }
    DynamicImage::ImageRgb8(img)
}

// 로고: 흰 바탕에 색 원 하나
fn logo() -> DynamicImage {
    let mut img = RgbImage::from_pixel(600, 600, Rgb([255, 255, 255]));
    for y in 0..600i32 {
        for x in 0..600i32 {
            if (x - 300).pow(2) + (y - 300).pow(2) <= 150 * 150 {
                img.put_pixel(x as u32, y as u32, Rgb([230, 26, 51]));
            }
        }
    }
    DynamicImage::ImageRgb8(img)
}

#[test]
fn shape_and_size_scores() {
    assert_eq!(pq::aspect_score(1600.0, 900.0), 1.0);
    assert!(pq::aspect_score(600.0, 600.0) < 0.75);
    assert_eq!(pq::aspect_score(400.0, 800.0), 0.0);
    assert!(pq::aspect_score(2000.0, 300.0) < 0.2);
    assert_eq!(pq::size_score(1200.0, 675.0), 1.0);
    assert_eq!(pq::size_score(120.0, 80.0), 0.0);
    assert!(pq::text_score(0.02) == 1.0 && pq::text_score(0.2) == 0.0);
}

#[test]
fn gates_keep_graphics_and_screenshots_out() {
    assert!(pq::good(Some(pq::combine(1.0, 1.0, 0.0, 1.0, 0.21).total))); // 밤하늘 사진
    assert!(!pq::good(Some(pq::combine(1.0, 1.0, 0.24, 1.0, 0.0).total))); // 큰 글자 그림
    assert!(!pq::good(Some(pq::combine(1.0, 1.0, 0.0, 1.0, 0.4).total))); // 그래픽·여백
    assert!(!pq::good(Some(pq::combine(1.0, 1.0, 0.07, 0.63, 0.3).total))); // 앱 화면 캡처(맥 실측)
}

#[test]
fn photo_passes_screenshot_and_logo_fail_with_estimate() {
    // 글자 인식 없이(tesseract 가 없는 컴퓨터) 단색 바탕·색 다양성만으로도 거른다
    let est = |i: &DynamicImage| pq::score_image(i, pq::estimate_text_ratio(i));
    let (ph, sc, lo) = (est(&photo()), est(&screenshot()), est(&logo()));
    assert!(pq::good(Some(ph.total)), "사진 {ph:?}");
    assert!(ph.text_ratio < 0.03, "사진에 글자 칸 {}", ph.text_ratio);
    assert!(!pq::good(Some(sc.total)), "화면 캡처 {sc:?}");
    assert!(sc.text_ratio > 0.05 && sc.flatness > 0.25, "글자 {} · 단색 {}", sc.text_ratio, sc.flatness); // 단색 바탕 + 글자 = 화면 캡처
    assert!(!pq::good(Some(lo.total)), "로고 {lo:?}");
    assert!(ph.color_variety > lo.color_variety && ph.color_variety > sc.color_variety);
}

#[test]
fn tesseract_tsv_area() {
    let tsv = "level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext\n\
               5\t1\t1\t1\t1\t1\t10\t10\t100\t20\t91.5\tBreaking\n\
               5\t1\t1\t1\t1\t2\t120\t10\t100\t20\t12.0\tnoise\n\
               4\t1\t1\t1\t1\t0\t10\t10\t210\t20\t-1\t\n\
               5\t1\t1\t1\t1\t3\t230\t10\t100\t20\t45\t \n";
    assert!((pq::text_area_from_tsv(tsv, 1000.0, 100.0) - 0.02).abs() < 1e-9); // 신뢰도 30 넘는 낱말 하나만
    assert_eq!(pq::text_area_from_tsv(tsv, 0.0, 0.0), 0.0);
}

fn with_image(id: &str, img: Option<&str>) -> NewsItem {
    let mut it = news(id, "x", "press", 0);
    it.image = img.map(|s| s.to_string());
    it
}

#[test]
fn cover_skips_bad_photos_but_keeps_unmeasured() {
    let a = with_image("a", Some("https://img.example/a.jpg"));
    let b = with_image("b", Some("https://img.example/b.jpg"));
    let c = with_image("c", None);
    let sc = |v: &[(&str, f64)]| v.iter().map(|(k, s)| (k.to_string(), *s)).collect::<HashMap<_, _>>();
    let all = [a.clone(), b.clone(), c.clone()];
    assert_eq!(pq::pick_cover(&all, &HashMap::new()), Some(a.key()));
    assert_eq!(pq::pick_cover(&all, &sc(&[("https://img.example/a.jpg", 0.2)])), Some(b.key()));
    assert_eq!(pq::pick_cover(&all, &sc(&[("https://img.example/a.jpg", 0.2), ("https://img.example/b.jpg", 0.3)])), Some(c.key()));
    assert_eq!(pq::pick_cover(&[a, b], &sc(&[("https://img.example/a.jpg", 0.2), ("https://img.example/b.jpg", 0.3)])), None);
}

#[test]
fn section_photo_prefers_measured_good() {
    let a = with_image("a", Some("https://img.example/a.jpg"));
    let b = with_image("b", Some("https://img.example/b.jpg"));
    let sc = |v: &[(&str, f64)]| v.iter().map(|(k, s)| (k.to_string(), *s)).collect::<HashMap<_, _>>();
    let items = [a.clone(), b.clone()];
    assert_eq!(pq::best(&items, &sc(&[("https://img.example/a.jpg", 0.3), ("https://img.example/b.jpg", 0.9)])).map(|i| i.key()), Some(b.key()));
    assert_eq!(pq::best(&items, &sc(&[("https://img.example/a.jpg", 0.3)])).map(|i| i.key()), Some(b.key()));
    assert_eq!(pq::best(&items, &HashMap::new()).map(|i| i.key()), Some(a.key()));
    assert!(pq::best(&items, &sc(&[("https://img.example/a.jpg", 0.1), ("https://img.example/b.jpg", 0.2)])).is_none());
}

#[test]
fn scores_persist() {
    let db = Database::in_memory();
    db.save_image_score("https://img.example/a.jpg", &pq::combine(1.0, 1.0, 0.3, 0.2, 0.0));
    let got = db.image_scores(&["https://img.example/a.jpg".into(), "https://img.example/none.jpg".into()]);
    assert_eq!(got.len(), 1);
    assert!(!pq::good(got.get("https://img.example/a.jpg").cloned()));
}

// MARK: 6. 짧은 글 추출(맥 8e9fde9: 100자 기준 · 본문 영역 대체 · 글 있는 페이지는 느린 길 건너뜀)
#[test]
fn short_posts_are_accepted_at_100_chars() {
    let art = |t: &str| Article { title: None, byline: None, site_name: None, blocks: vec![p(t)] };
    assert!(art(&"짧은 소개글입니다. ".repeat(10)).acceptable()); // 한 문단 100자 넘음
    assert!(!art("너무 짧음").acceptable());
    assert!(!Article { title: None, byline: None, site_name: None, blocks: vec![] }.acceptable());
}

#[test]
fn content_region_fallback_and_plain_lines() {
    // GeekNews 처럼 문단 태그 없이 줄바꿈으로 든 짧은 소개글
    let html = r#"<html><head><title>짧은 글 - GeekNews</title></head><body>
      <nav><a href="/">홈</a> <a href="/new">새 글</a></nav>
      <div id="topic_contents"><span>오픈소스 에디터가 새 판을 냈다. 플러그인 구조를 다시 짰다고 한다.<br>
      설치는 한 줄이면 된다. 예전 설정 파일도 그대로 읽는다.<br>성능은 두 배 가까이 빨라졌다는 설명.</span>
      <div class="related-topics">관련 글 목록 관련 글 목록</div></div>
      <footer>회사 소개 · 약관 · 개인정보</footer></body></html>"#;
    let art = article::extract_html(html, "https://news.example/topic?id=1").expect("짧은 글도 추림");
    let texts: Vec<&str> = art.blocks.iter().filter_map(|b| b.text.as_deref()).collect();
    assert!(texts.iter().any(|t| t.contains("오픈소스 에디터")), "{texts:?}");
    assert!(!texts.iter().any(|t| t.contains("약관") || t.contains("새 글")), "{texts:?}");
    assert!(art.blocks.iter().all(|b| b.kind != BlockKind::H || b.text.is_some()));
}

#[test]
fn visible_text_length_ignores_scripts() {
    let shell = format!("<html><body><div id=app></div><script>{}</script></body></html>", "var x=1;".repeat(500));
    assert!(article::visible_text_length(&shell) < 50);
    let rich = format!("<html><body><p>{}</p></body></html>", "글이 많은 페이지. ".repeat(80));
    assert!(article::visible_text_length(&rich) > 600);
}

// 손으로 맞춰 보기: DROPCAP_TEST_PHOTO_FILES=<폴더> 의 그림을 앱처럼 줄여(JPEG) 재고 점수를 찍는다(맥 같은 이름의 시험 훅)
#[test]
#[ignore]
fn score_photo_folder() {
    let Ok(dir) = std::env::var("DROPCAP_TEST_PHOTO_FILES") else { return };
    let mut files: Vec<_> = std::fs::read_dir(dir).unwrap().flatten().map(|e| e.path()).collect();
    files.sort();
    let out = tempfile::tempdir().unwrap();
    for f in files {
        let Some(jpg) = std::fs::read(&f).ok().and_then(|d| dropcap_core::images::shrink(&d)) else { continue };
        let p = out.path().join("x.jpg");
        std::fs::write(&p, jpg).unwrap();
        let s = pq::score_file(&p).unwrap();
        println!("{:<14} 점수 {:.2} 글자 {:.2} 색 {:.2} 단색 {:.2} {}", f.file_name().unwrap().to_string_lossy(), s.total, s.text_ratio, s.color_variety, s.flatness, if pq::good(Some(s.total)) { "통과" } else { "뺌" });
    }
}

#[test]
fn only_local_ollama_models_summarize() {
    use dropcap_core::summarizer::local_text_model;
    assert!(local_text_model("qwen2.5:7b"));
    assert!(!local_text_model("nomic-embed-text:latest"));
    assert!(!local_text_model("gpt-oss:120b-cloud")); // 클라우드로 보내는 모델은 '기기 안 요약'이 아님
}
