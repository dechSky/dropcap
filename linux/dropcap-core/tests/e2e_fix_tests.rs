// 맥 E2EScenarioTests.swift 의 E2EFixTests·덜 받기 시험을 옮긴 것(맥 e2e-fix, efdeb13):
// 스크랩 사본·깨진 DB 에서 건지기, 이 분야 덜 받기, 강한 낱말 칩.
use dropcap_core::app_model::notify_section_of;
use dropcap_core::database::Database;
use dropcap_core::models::NewsItem;
use dropcap_core::notify_policy::{self as np, Coverage, Decision, Input, NotifyMode, PolicyLimits, SectionPolicy};
use dropcap_core::scrapbook::{self, Scrap, Scrapbook};
use dropcap_core::sections;
use dropcap_core::store::Prefs;
use std::collections::HashSet;
use std::sync::Arc;

fn scrap(id: &str, c: &str) -> Scrap {
    let it = NewsItem::new(id, &format!("제목 {id}"), &format!("https://a.com/{id}"), "s", "s", "kr");
    let mut s = Scrap::new(it, None, None, "메모", c);
    s.id = id.into();
    s
}

// 1) 스크랩 사본: 원자적으로 쓰고 그대로 읽힘, DB 에 없는 것만 되살림
#[test]
fn scrap_copy_round_trip_and_restore_list() {
    let d = tempfile::tempdir().unwrap();
    let f = d.path().join("scraps.json");
    let list = vec![scrap("a", "모음"), scrap("b", "다른 모음")];
    scrapbook::write_copy(&list, &f);
    let back = scrapbook::read_copy(&f).unwrap();
    assert_eq!(back.iter().map(|s| s.id.as_str()).collect::<Vec<_>>(), ["a", "b"]);
    assert_eq!(back.iter().map(|s| s.collection.as_str()).collect::<Vec<_>>(), ["모음", "다른 모음"]);
    assert_eq!(scrapbook::restore_list(&[scrap("a", "모음")], &list).iter().map(|s| s.id.as_str()).collect::<Vec<_>>(), ["b"]);
    assert!(scrapbook::read_copy(&d.path().join("none.json")).is_none());
    // 맥이 쓴 사본 모양(version·scraps)
    let v: serde_json::Value = serde_json::from_slice(&std::fs::read(&f).unwrap()).unwrap();
    assert_eq!(v["version"], 1);
}

// 1) 깨져서 새로 만든 DB 는 치운 파일의 스크랩을 읽히는 만큼 옮겨 온다
#[test]
fn salvage_scraps_from_other_file() {
    let d = tempfile::tempdir().unwrap();
    let (a, b) = (d.path().join("old"), d.path().join("new"));
    std::fs::create_dir_all(&a).unwrap();
    std::fs::create_dir_all(&b).unwrap();
    {
        let old = Database::open(&a);
        old.save_scrap(&scrap("x", "모음"));
        old.save_scrap(&scrap("y", "폴더"));
    }
    let fresh = Database::open(&b);
    assert_eq!(fresh.import_scraps(&a.join("magazine.sqlite")), 2);
    let ids: HashSet<String> = fresh.scraps(None).into_iter().map(|s| s.id).collect();
    assert_eq!(ids, HashSet::from(["x".to_string(), "y".to_string()]));
    assert_eq!(fresh.import_scraps(&d.path().join("missing.sqlite")), 0);
}

// 1) 통째로 깨진 파일: 새로 만들었다고 표시(사본에서 되살릴 조건)
#[test]
fn corrupt_db_is_marked_recreated() {
    let d = tempfile::tempdir().unwrap();
    std::fs::write(d.path().join("magazine.sqlite"), vec![0x5Au8; 8192]).unwrap();
    let db = Database::open(d.path());
    assert!(db.recreated);
    assert_eq!(db.salvaged_scraps, 0);
    assert!(d.path().join("magazine.broken.sqlite").exists());
    let ok = tempfile::tempdir().unwrap();
    assert!(!Database::open(ok.path()).recreated);
}

// 1) 시나리오 12-다: DB 가 깨져도 사본에서 스크랩이 돌아오고, 평소에 다 지운 것은 되살리지 않는다
#[test]
fn scrapbook_restores_from_copy_after_corruption() {
    let d = tempfile::tempdir().unwrap();
    {
        let mut sb = Scrapbook::new(Arc::new(Database::open(d.path())), d.path().to_path_buf());
        let it = NewsItem::new("k1", "제목", "https://a.com/k1", "s", "s", "kr");
        assert!(sb.add(&it, None, None, "", Some("모음")));
        assert!(sb.add(&it, Some("문단".into()), None, "", Some("모음")));
    }
    assert_eq!(scrapbook::read_copy(&scrapbook::copy_file(d.path())).unwrap().len(), 2);
    // 통째로 깨뜨림(WAL 까지)
    for ext in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(d.path().join(format!("magazine.sqlite{ext}")));
    }
    std::fs::write(d.path().join("magazine.sqlite"), vec![0x5Au8; 8192]).unwrap();
    let sb = Scrapbook::new(Arc::new(Database::open(d.path())), d.path().to_path_buf());
    assert_eq!(sb.scraps.len(), 2);

    // 평소에 다 지운 것(DB 에 기사가 있음)은 되살리지 않음
    let e = tempfile::tempdir().unwrap();
    let db = Arc::new(Database::open(e.path()));
    db.upsert(&NewsItem::new("n", "제목", "https://a.com/n", "s", "s", "kr"), None, chrono::Utc::now());
    scrapbook::write_copy(&[scrap("gone", "모음")], &scrapbook::copy_file(e.path()));
    let sb = Scrapbook::new(db, e.path().to_path_buf());
    assert!(sb.scraps.is_empty());
}

// 1) 끄기 스위치(prefs.json scrapsCopyOff): 사본을 쓰지 않음 · 예전 prefs 는 꺼지지 않음
#[test]
fn scraps_copy_off_switch() {
    let d = tempfile::tempdir().unwrap();
    let mut p = Prefs::load(d.path());
    assert!(!p.scraps_copy_off);
    p.scraps_copy_off = true;
    p.save(d.path());
    let mut sb = Scrapbook::new(Arc::new(Database::open(d.path())), d.path().to_path_buf());
    sb.add(&NewsItem::new("k", "제목", "https://a.com/k", "s", "s", "kr"), None, None, "", None);
    assert!(!scrapbook::copy_file(d.path()).exists());
    assert!(Prefs::load(d.path()).scraps_copy_off);
}

fn input(policy: SectionPolicy, kr: i64, intl: i64) -> Input {
    Input { chosen: true, policy, coverage: Coverage { kr, intl }, lab: false, important: false, followed: false, watched: false, sent_in_section: 0, sent_total: 0 }
}

// 3) '이 분야 덜 받기'한 분야는 주요 뉴스 흐름으로도 떨어뜨리지 않는다(시나리오 11-나)
#[test]
fn less_of_stays_out_of_top_flow() {
    let l = PolicyLimits::default();
    let top = input(SectionPolicy::mode(NotifyMode::Instant), 0, 0);
    let mut world = SectionPolicy::mode(NotifyMode::Bundle);
    world.less = true;
    assert_eq!(np::decide_with_top(&input(world, 0, 2), Some(&top), l), (Decision::Pool, false));
    // 국내 8곳짜리 큰 소식도 덜 받기 분야면 묶음으로
    assert_eq!(np::decide_with_top(&input(world, 8, 2), Some(&top), l), (Decision::Pool, false));
    // 그냥 묶음 분야(덜 받기 아님)는 예전처럼 주요 뉴스 흐름이 받는다
    world.less = false;
    assert_eq!(np::decide_with_top(&input(world, 0, 2), Some(&top), l), (Decision::Drop, true));
}

#[test]
fn less_flag_survives_old_and_new_files() {
    let old: SectionPolicy = serde_json::from_str(r#"{"mode":"bundle","bundleHour":18,"dailyCap":3}"#).unwrap();
    assert!(!old.less);
    let mut p = SectionPolicy::mode(NotifyMode::Bundle);
    p.less = true;
    let back: SectionPolicy = serde_json::from_str(&serde_json::to_string(&p).unwrap()).unwrap();
    assert!(back.less);
    assert!(serde_json::to_string(&p).unwrap().contains(r#""less":true"#)); // 맥과 같은 이름
}

// 4) 출처 분야(정치)와 달리 경제 낱말이 강하게 걸리면 경제 칩을 더하고, 알림 분야는 고른 분야 칩을 먼저 쓴다
#[test]
fn strong_keyword_chip() {
    let it = NewsItem::new("p1", "한국은행 기준금리 인하 결정 가계대출 부담 사흘째", "https://a.com/p1", "yna-politics", "연합뉴스 정치", "kr");
    let p = sections::place(&it, &sections::META, None);
    assert_eq!(p.primary, "politics");
    assert_eq!(p.strong.as_deref(), Some("economy"));
    assert!(p.chips.contains(&"economy".to_string()));
    let chosen = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    assert_eq!(notify_section_of(&it, &chosen(&["top", "economy", "world", "ai"])), "economy");
    assert_eq!(notify_section_of(&it, &chosen(&["politics", "economy"])), "politics"); // 둘 다 고르면 대표 분야
    assert_eq!(it.extra_topic().as_deref(), Some("economy"));
    // 낱말 하나만 걸리면 강한 칩 아님
    let weak = NewsItem::new("p2", "국회 본회의 일정 합의 금리", "https://a.com/p2", "yna-politics", "연합뉴스 정치", "kr");
    assert_eq!(sections::place(&weak, &sections::META, None).strong, None);
}
