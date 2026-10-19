// 지난 기사 보관함(맥 ArchiveTests 와 같은 경우): 정리(prune)가 지우는 기사를 보관 표로 옮기기 · 보관 기간 상한 · 보관 검색 · 기간 목록
use chrono::{DateTime, Duration, Local, TimeZone, Utc};
use dropcap_core::archive::{self, ArchiveReader, ArchivedItem, Period, Visibility};
use dropcap_core::source_filter::SourceFilter;
use dropcap_core::database::{Cluster, Database};
use dropcap_core::models::NewsItem;
use dropcap_core::store::Settings;
use std::collections::HashMap;
use std::sync::Arc;

fn item(id: &str, title: Option<&str>, source: &str, date: DateTime<Utc>) -> NewsItem {
    let t = title.map(|s| s.to_string()).unwrap_or_else(|| format!("기사 {id}"));
    let mut it = NewsItem::new(id, &t, &format!("https://{source}.example/{id}"), source, &format!("{source} 이름"), "press");
    it.date = Some(date);
    it.summary = "요약".into();
    it
}

fn put(db: &Database, it: &NewsItem, cluster: Option<&str>) {
    assert!(db.upsert(it, cluster, it.date.unwrap()));
}

fn tech(_: &NewsItem) -> String {
    "tech".into()
}

fn all() -> Visibility {
    Visibility::default()
}

fn local(y: i32, m: u32, d: u32, h: u32) -> DateTime<Utc> {
    Local.with_ymd_and_hms(y, m, d, h, 0, 0).earliest().unwrap().with_timezone(&Utc)
}

// 정리가 지우는 오래된 기사는 보관 표로 옮겨지고(날짜·제목·링크·출처·분야), 최근 keep 건은 items 에 남는다
#[test]
fn prune_moves_to_archive() {
    let db = Database::in_memory();
    let now = Utc::now();
    for i in 0..10 {
        put(&db, &item(&format!("a{i}"), None, "geeknews", now - Duration::hours(i)), None);
    }
    let moved = db.prune(6, archive::DEFAULT_YEARS, now, &tech);
    assert_eq!(moved, 4);
    assert_eq!(db.item_count(), 6);
    assert_eq!(db.archive_count(), 4);
    let old = db.archived(now - Duration::days(1), now + Duration::minutes(1), None, None, 100, 0, &all());
    assert_eq!(old.iter().map(|a| a.link.clone()).collect::<Vec<_>>(), (6..10).map(|i| format!("https://geeknews.example/a{i}")).collect::<Vec<_>>());
    assert_eq!(old[0].source, "geeknews 이름");
    assert_eq!(old[0].section, "tech");
    assert!((old[0].date - (now - Duration::hours(6))).num_milliseconds().abs() < 1000);
    // 다시 정리해도 같은 기사를 두 번 넣지 않는다
    put(&db, &item("a9", None, "geeknews", now - Duration::hours(9)), None);
    db.prune(6, archive::DEFAULT_YEARS, now, &tech);
    assert_eq!(db.archive_count(), 4);
    assert_eq!(db.item_count(), 6);
}

// 여러 곳이 다룬 스토리만 스토리 id 를 남긴다
#[test]
fn prune_keeps_story_only_for_shared_stories() {
    let db = Database::in_memory();
    let now = Utc::now();
    let cl = |id: &str, size| Cluster { id: id.into(), title: id.into(), tokens: Default::default(), first: now, last: now, size };
    db.save_cluster(&cl("big", 2));
    db.save_cluster(&cl("one", 1));
    put(&db, &item("s1", None, "geeknews", now - Duration::hours(3)), Some("big"));
    put(&db, &item("s2", None, "geeknews", now - Duration::hours(4)), Some("one"));
    put(&db, &item("new", None, "geeknews", now), None);
    db.prune(1, archive::DEFAULT_YEARS, now, &tech);
    let old = db.archived(now - Duration::days(1), now, None, None, 100, 0, &all());
    assert_eq!(old.iter().find(|a| a.link.ends_with("s1")).unwrap().story.as_deref(), Some("big"));
    assert_eq!(old.iter().find(|a| a.link.ends_with("s2")).unwrap().story, None);
    // 지운 기사의 스토리도 함께 정리
    assert!(db.cluster("big").is_none());
}

// 보관 기간: years 년 전이 든 달보다 이른 보관 기사는 지운다(달 단위), 0 이면 지우지 않는다
#[test]
fn prune_caps_archive_by_months() {
    let now = local(2026, 10, 19, 12);
    assert_eq!(archive::cutoff(2, now), Some(local(2024, 10, 1, 0)));
    assert_eq!(archive::cutoff(0, now), None);
    let db = Database::in_memory();
    for (i, d) in [local(2024, 9, 30, 9), local(2024, 10, 1, 9), local(2025, 10, 5, 9)].into_iter().enumerate() {
        put(&db, &item(&format!("o{i}"), None, "geeknews", d), None);
    }
    put(&db, &item("keep", None, "geeknews", now), None);
    db.prune(1, 0, now, &tech);
    assert_eq!(db.archive_count(), 3);
    db.prune(1, 2, now, &tech);
    assert_eq!(db.archive_count(), 2); // 2024년 9월은 지워짐, 10월 1일부터 남음
    let left = db.archived(local(2024, 1, 1, 0), now, None, None, 10, 0, &all());
    assert!(left.iter().any(|a| a.link.ends_with("/o1")));
    assert!(!left.iter().any(|a| a.link.ends_with("/o0")));
    db.prune(1, 1, now, &tech);
    assert_eq!(db.archive_count(), 1);
}

// 보관 검색: 제목·출처 LIKE, 최신순, 더 보기(offset), % _ 는 글자 그대로
#[test]
fn search_archive() {
    let db = Database::in_memory();
    let now = Utc::now();
    for i in 0..5 {
        put(&db, &item(&format!("q{i}"), Some(&format!("엔비디아 실적 {i}")), "geeknews", now - Duration::days(i + 1)), None);
    }
    put(&db, &item("pct", Some("금리 50% 인상"), "geeknews", now - Duration::days(10)), None);
    put(&db, &item("keep", None, "geeknews", now), None);
    db.prune(1, archive::DEFAULT_YEARS, now, &|_| "economy".into());
    let hits = db.search_archive("엔비디아", 3, 0, &all());
    assert_eq!(hits.iter().map(|a| a.title.as_str()).collect::<Vec<_>>(), ["엔비디아 실적 0", "엔비디아 실적 1", "엔비디아 실적 2"]);
    assert_eq!(db.search_archive("엔비디아", 3, 3, &all()).len(), 2);
    assert_eq!(db.search_archive("50%", 200, 0, &all()).iter().map(|a| a.title.as_str()).collect::<Vec<_>>(), ["금리 50% 인상"]);
    assert!(db.search_archive("5_%", 200, 0, &all()).is_empty());
    assert!(db.search_archive("\\", 200, 0, &all()).is_empty());
    assert_eq!(db.search_archive("geeknews 이름", 200, 0, &all()).len(), 6);
}

// 기간 목록: 최근 기사(items)와 보관 기사를 합쳐 최신순, 분야·출처 거르기, 날짜별 건수, 더 보기
#[test]
fn archive_period_merges_recent_and_archived() {
    let db = Arc::new(Database::in_memory());
    let day = archive::range(Period::Day, Utc::now() - Duration::days(3)).0;
    let src = |i: i64| if i % 2 == 0 { "aa" } else { "bb" };
    for i in 0..6 {
        put(&db, &item(&format!("p{i}"), None, src(i), day + Duration::hours(10 + i)), None);
    }
    db.prune(3, archive::DEFAULT_YEARS, Utc::now(), &|it| if it.source_id == "aa" { "tech".into() } else { "economy".into() }); // p0~p2 는 보관 표로
    assert_eq!(db.archive_count(), 3);
    let ed = ArchiveReader::new(db.clone());
    let (from, to) = archive::range(Period::Day, day);
    let every = ed.period(from, to, None, None, 100, &all());
    assert_eq!(
        every.items.iter().map(|a| a.link.clone()).collect::<Vec<_>>(),
        (0..6).rev().map(|i| format!("https://{}.example/p{i}", src(i))).collect::<Vec<_>>()
    );
    assert_eq!(every.total, 6);
    assert!(!every.more);
    assert_eq!(every.day_counts, HashMap::from([(archive::day_key(day), 6)]));
    assert_eq!(every.sources, HashMap::from([("aa 이름".to_string(), 3), ("bb 이름".to_string(), 3)]));
    let some = ed.period(from, to, None, Some("aa 이름"), 2, &all());
    assert_eq!(some.items.iter().map(|a| a.link.as_str()).collect::<Vec<_>>(), ["https://aa.example/p4", "https://aa.example/p2"]);
    assert!(some.more);
    assert_eq!(some.total, 3);
    let tech = ed.period(from, to, Some("tech"), None, 100, &all());
    assert!(tech.items.iter().all(|a| a.section == "tech"));
    assert_eq!(tech.items.len() as i64, tech.total);
    let (mf, mt) = archive::range(Period::Month, day);
    assert_eq!(ed.period(mf, mt, None, None, 100, &all()).total, 6);
    assert!(ed.earliest_record().unwrap() <= day + Duration::hours(10));
}

// 같은 링크는 한 번(최근 기사끼리 겹친 것도) — 목록 줄 id 가 겹치지 않게
#[test]
fn merge_dedupes_links() {
    let d = Utc::now();
    let a = |link: &str, s: i64| ArchivedItem {
        date: d + Duration::seconds(s),
        title: link.into(),
        title_ko: None,
        link: link.into(),
        source: "x".into(),
        source_id: None,
        section: "tech".into(),
        story: None,
    };
    let m = archive::merge(&[a("l1", 0), a("l1", 0), a("l2", -10)], &[a("l2", -20), a("l3", -30)]);
    assert_eq!(m.iter().map(|x| x.link.as_str()).collect::<Vec<_>>(), ["l1", "l2", "l3"]);
    let ids: std::collections::HashSet<String> = m.iter().map(|x| x.id()).collect();
    assert_eq!(ids.len(), m.len());
    assert_eq!(archive::filter(&m, None, Some("y")).len(), 0);
    assert_eq!(archive::day_counts(&m).values().sum::<i64>(), 3);
}

// 기간 계산: ◀ ▶ 로 한 기간씩, 일·주·월·연 경계
#[test]
fn periods() {
    let d = local(2026, 3, 15, 13);
    let (mf, mt) = archive::range(Period::Month, d);
    assert_eq!(mf, local(2026, 3, 1, 0));
    assert_eq!(mt, local(2026, 4, 1, 0));
    assert_eq!(archive::range(Period::Year, archive::shift(Period::Year, d, -1)).0, local(2025, 1, 1, 0));
    assert_eq!(archive::range(Period::Day, archive::shift(Period::Day, d, 1)).0, local(2026, 3, 16, 0));
    assert_eq!(archive::shift(Period::Month, local(2026, 1, 31, 12), -1), local(2025, 12, 1, 0));
    assert_eq!(archive::shift(Period::Month, local(2026, 12, 5, 12), 1), local(2027, 1, 1, 0));
    let (wf, wt) = archive::range(Period::Week, d);
    assert_eq!(wt - wf, Duration::days(7));
    assert_eq!(archive::range(Period::Week, archive::shift(Period::Week, d, 1)).0, wt);
    assert_eq!(archive::title(Period::Month, d), "2026년 3월");
    assert_eq!(archive::title(Period::Day, d), "2026년 3월 15일(일)");
    assert_eq!(archive::title(Period::Year, d), "2026년");
    assert_eq!(archive::title(Period::Week, d), "2026년 3월 15일 – 3월 21일");
    assert_eq!(archive::days(mf, mt).len(), 31);
    assert_eq!(archive::day_key(d), "2026-03-15");
    assert_eq!(Period::from_raw("week"), Period::Week);
    assert_eq!(Period::from_raw("??"), Period::Month);
    assert!(Period::Year.shows_bars() && !Period::Day.shows_bars());
}

// 보관 기간 설정: 예전 상태 파일엔 없음 → 2년, 모르는 값도 2년, 같은 키로 저장
#[test]
fn settings_archive_years() {
    let old: Settings = serde_json::from_str("{}").unwrap();
    assert_eq!(old.archive_years, 2);
    let odd: Settings = serde_json::from_str(r#"{"archiveYears":3}"#).unwrap();
    assert_eq!(odd.archive_years, 2);
    let never: Settings = serde_json::from_str(r#"{"archiveYears":0}"#).unwrap();
    assert_eq!(never.archive_years, 0);
    let v = serde_json::to_value(Settings { archive_years: 5, ..Settings::default() }).unwrap();
    assert_eq!(v["archiveYears"], 5);
    assert_eq!(archive::label(0), "끝없이");
    assert_eq!(archive::label(5), "5년");
}

// 숨긴·끈 출처의 글은 보관함(목록·날짜별 건수·거르기 메뉴)·오래된 기사 검색·최근 기사 어디에도 다시 나타나지 않는다
#[test]
fn hidden_sources_stay_hidden() {
    let db = Arc::new(Database::in_memory());
    let day = archive::range(Period::Day, Utc::now() - Duration::days(3)).0;
    for (i, src) in ["aa", "bb", "cc", "aa", "bb", "cc"].iter().enumerate() {
        put(&db, &item(&format!("h{i}"), Some(&format!("공통 낱말 {i}")), src, day + Duration::hours(10 + i as i64)), None);
    }
    db.prune(3, archive::DEFAULT_YEARS, Utc::now(), &tech); // h0~h2 는 보관 표로, h3~h5 는 items 에
    assert_eq!(db.archive_count(), 3);
    // bb 는 숨김, cc 는 꺼짐(켜진 목록에 없음)
    let f = SourceFilter { hidden: ["bb".to_string()].into(), active: Some(["aa".to_string()].into()) };
    let vis = Visibility::new(&f, vec!["bb 이름".into()]);
    assert!(vis.shows("aa") && !vis.shows("bb") && !vis.shows("cc"));
    let ed = ArchiveReader::new(db.clone());
    let (from, to) = archive::range(Period::Day, day);
    let p = ed.period(from, to, None, None, 100, &vis);
    assert!(p.items.iter().all(|a| a.source == "aa 이름"), "{:?}", p.items);
    assert_eq!(p.items.len(), 2);
    assert_eq!(p.total, 2);
    assert_eq!(p.day_counts.values().sum::<i64>(), 2);
    assert_eq!(p.sources, HashMap::from([("aa 이름".to_string(), 2)]));
    assert_eq!(p.sections.values().sum::<i64>(), 2);
    let hits = ed.search("공통 낱말", 200, 0, &vis);
    assert_eq!(hits.iter().map(|a| a.link.as_str()).collect::<Vec<_>>(), ["https://aa.example/h0"]);
    assert_eq!(ed.search("공통 낱말", 200, 0, &all()).len(), 3);
    let recent = db.recent_light(from, to, &vis, &mut |_| "tech".into());
    assert_eq!(recent.iter().map(|a| a.link.as_str()).collect::<Vec<_>>(), ["https://aa.example/h3"]);
    assert_eq!(ed.period(from, to, None, None, 100, &all()).total, 6);
}

// 출처 id 가 없는 예전 줄(source_id NULL)은 숨긴 출처의 이름으로 거른다
#[test]
fn legacy_rows_without_source_id_filtered_by_name() {
    let dir = tempfile::tempdir().unwrap();
    let day = archive::range(Period::Day, Utc::now() - Duration::days(3)).0;
    {
        // source_id 칸이 없던 예전 표를 만든다
        let c = rusqlite::Connection::open(dir.path().join("magazine.sqlite")).unwrap();
        c.execute_batch(
            "CREATE TABLE archive(date REAL NOT NULL, title TEXT NOT NULL, title_ko TEXT, link TEXT NOT NULL, source TEXT, section TEXT, story TEXT);
             CREATE INDEX archive_date ON archive(date, section, source);",
        )
        .unwrap();
        for (i, src) in ["숨긴 곳", "보이는 곳"].iter().enumerate() {
            let t = (day + Duration::hours(10 + i as i64)).timestamp() as f64;
            c.execute("INSERT INTO archive(date,title,link,source,section) VALUES(?,?,?,?,'tech')", rusqlite::params![t, format!("예전 {i}"), format!("https://old.example/{i}"), src]).unwrap();
        }
    }
    let db = Arc::new(Database::open(dir.path()));
    assert_eq!(db.archive_count(), 2);
    let f = SourceFilter { hidden: ["gone".to_string()].into(), active: None };
    let vis = Visibility::new(&f, vec!["숨긴 곳".into()]);
    let (from, to) = archive::range(Period::Day, day);
    let ed = ArchiveReader::new(db.clone());
    let p = ed.period(from, to, None, None, 100, &vis);
    assert_eq!(p.items.iter().map(|a| a.source.as_str()).collect::<Vec<_>>(), ["보이는 곳"]);
    assert_eq!(p.sources, HashMap::from([("보이는 곳".to_string(), 1)]));
    assert_eq!(ed.search("예전", 200, 0, &vis).len(), 1);
    // 손본 뒤 새로 옮긴 줄은 출처 id 를 남긴다
    let now = Utc::now();
    put(&db, &item("n1", None, "gone", now - Duration::hours(2)), None);
    put(&db, &item("n2", None, "gone", now), None);
    db.prune(1, 0, now, &tech);
    let moved = db.archived(now - Duration::days(1), now, None, None, 10, 0, &all());
    assert_eq!(moved[0].source_id.as_deref(), Some("gone"));
    assert!(db.archived(now - Duration::days(1), now, None, None, 10, 0, &vis).is_empty());
}

// 제목이 없는 줄은 보관 표로 옮기지도 items 에서 지우지도 않는다
#[test]
fn bad_rows_are_kept_not_archived() {
    let db = Database::in_memory();
    let now = Utc::now();
    put(&db, &item("ok", None, "geeknews", now - Duration::hours(3)), None);
    put(&db, &item("keep", None, "geeknews", now), None);
    let mut bad = item("bad", None, "geeknews", now - Duration::hours(5));
    bad.title = String::new();
    put(&db, &bad, None);
    let moved = db.prune(1, archive::DEFAULT_YEARS, now, &tech);
    assert_eq!(moved, 1);
    assert_eq!(db.archive_count(), 1);
    assert_eq!(db.item_count(), 2); // keep + 옮기지 못한 bad
    assert!(db.exists(&bad.key()));
}

// 보관 기간과 상관없는 상한: 넘으면 가장 오래된 것부터 지운다
#[test]
fn archive_row_cap() {
    let db = Database::in_memory();
    let now = Utc::now();
    for i in 0..6 {
        put(&db, &item(&format!("c{i}"), None, "geeknews", now - Duration::days(i)), None);
    }
    db.prune_capped(1, 0, now, &tech, 3);
    assert_eq!(db.archive_count(), 3); // 꼭 상한만큼 남는다
    let left: Vec<String> = db.archived(now - Duration::days(30), now, None, None, 10, 0, &all()).into_iter().map(|a| a.link).collect();
    assert_eq!(left, ["https://geeknews.example/c1", "https://geeknews.example/c2", "https://geeknews.example/c3"]);
    assert_eq!(archive::MAX_ROWS, 5_000_000);
}

// 검색어는 앞 200 글자만 쓴다(긴 글을 붙여 넣어도)
#[test]
fn long_query_is_trimmed() {
    let db = Database::in_memory();
    let now = Utc::now();
    let long = "가".repeat(200);
    put(&db, &item("l", Some(&long), "geeknews", now - Duration::days(1)), None);
    put(&db, &item("keep", None, "geeknews", now), None);
    db.prune(1, 2, now, &tech);
    assert_eq!(db.search_archive(&"가".repeat(500), 10, 0, &all()).len(), 1);
}
