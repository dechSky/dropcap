// 맥 SidebarRuleTests · SidebarEditorTests(4e27109) 중 리눅스에 없던 것: 지난 호 순서·이번 주 범위·예전 호 다시 엮기·기록 적음·최근 검색·주간 표지.
use chrono::{DateTime, Duration, Local, TimeZone, Utc};
use dropcap_core::category::NewsCategory;
use dropcap_core::database::{Cluster, Database};
use dropcap_core::magazine::{self, Editorial, Issue, IssueKind, Section};
use dropcap_core::models::NewsItem;

fn day(d: u32, h: u32) -> DateTime<Utc> {
    Local.with_ymd_and_hms(2026, 10, d, h, 0, 0).earliest().unwrap().with_timezone(&Utc)
}

fn issue(id: &str, kind: IssueKind, from: DateTime<Utc>, to: DateTime<Utc>, count: i64, sections: Vec<Section>) -> Issue {
    Issue { id: id.into(), kind, date: Utc::now(), from, to, cover: None, sections, count }
}

fn sec(category: &str, keys: &[&str], section: Option<&str>, kind: Option<&str>) -> Section {
    let category = if category == "other" { NewsCategory::other() } else { NewsCategory::id(category) };
    Section { category, keys: keys.iter().map(|s| s.to_string()).collect(), kind: kind.map(Into::into), section: section.map(Into::into) }
}

fn put(db: &Database, id: &str, source: &str, title: &str, date: DateTime<Utc>, tier: &str, cluster: Option<&str>) {
    let mut it = NewsItem::new(id, title, &format!("https://{source}.example/{id}"), source, source, tier);
    it.date = Some(date);
    db.upsert(&it, cluster, date);
}

#[test]
fn archive_is_newest_first_weekly_at_week_end() {
    let list = vec![
        issue("daily-13", IssueKind::Daily, day(12, 18), day(13, 18), 10, vec![]),
        issue("weekly-W40", IssueKind::Weekly, day(4, 0), day(11, 0), 10, vec![]),
        issue("daily-10", IssueKind::Daily, day(9, 18), day(10, 18), 10, vec![]),
        issue("daily-11", IssueKind::Daily, day(10, 18), day(11, 18), 10, vec![]),
        issue("daily-12", IssueKind::Daily, day(11, 18), day(12, 18), 10, vec![]),
        // 끝 시각이 같으면 주간이 위
        issue("daily-x", IssueKind::Daily, day(10, 0), day(11, 0), 10, vec![]),
    ];
    let ids: Vec<String> = magazine::archive_order(list).into_iter().map(|i| i.id).collect();
    assert_eq!(ids, ["daily-13", "daily-12", "daily-11", "weekly-W40", "daily-x", "daily-10"]);
}

#[test]
fn weeks_are_contiguous_seven_days() {
    let (from, to) = magazine::week_range(day(14, 15)); // 2026-10-14 수요일
    assert_eq!(from, day(11, 0)); // 일요일
    assert_eq!(to, day(18, 0));
    let (lfrom, lto) = magazine::week_range(from - Duration::hours(1));
    assert_eq!((lfrom, lto), (day(4, 0), from)); // 지난 주간과 겹치지 않고 이어짐
    // 지난 주간 이름: 끝 날짜는 토요일
    assert!(issue("w", IssueKind::Weekly, lfrom, lto, 10, vec![]).title().ends_with("10월 10일"), "{}", issue("w", IssueKind::Weekly, lfrom, lto, 10, vec![]).title());
}

#[test]
fn live_weekly_starts_at_calendar_week() {
    let db = Database::in_memory();
    let w = magazine::live_weekly(&db, &Editorial::default());
    assert_eq!(w.from, magazine::week_range(Utc::now()).0);
}

#[test]
fn old_layout_issues_are_rebuilt_and_thin() {
    let old = issue("weekly-W40", IssueKind::Weekly, day(4, 0), day(11, 0), 2, vec![sec("model", &["a"], None, None)]);
    assert!(magazine::needs_rebuild(&old));
    assert!(old.is_thin());
    let now = issue(
        "daily-13",
        IssueKind::Daily,
        day(12, 18),
        day(13, 18),
        10,
        vec![sec("other", &["a"], Some("tech"), None), sec("other", &["b"], None, None), sec("other", &["c"], None, Some("video"))],
    );
    assert!(!magazine::needs_rebuild(&now));
    assert!(!now.is_thin());
}

#[test]
fn recent_searches() {
    let mut l: Vec<String> = vec![];
    for q in ["엔비디아", "Apple", " apple ", "a"] {
        l = magazine::remember_search(q, &l);
    }
    assert_eq!(l, ["apple", "엔비디아"]);
    let full: Vec<String> = (0..8).map(|i| format!("w{i}")).collect();
    assert_eq!(magazine::remember_search("x9", &full).len(), 8);
}

#[test]
fn weekly_cover_is_biggest_story() {
    let db = Database::in_memory();
    let now = Utc::now();
    // 점수 높은 공식 발표 하나(혼자) vs 세 곳이 다룬 이야기
    put(&db, "sb-lab", "openai", "Introducing a new model", now - Duration::minutes(10), "lab", None);
    db.save_cluster(&Cluster { id: "big".into(), title: "big".into(), tokens: Default::default(), first: now, last: now, size: 3 });
    for (i, s) in ["geeknews", "bloter-all", "verge-all"].iter().enumerate() {
        put(&db, &format!("sb-b{i}"), s, &format!("같은 이야기 {i}"), now - Duration::hours(i as i64 + 2), "press", Some("big"));
    }
    let ed = Editorial::default();
    let w = magazine::make_issue(&db, IssueKind::Weekly, now - Duration::days(1), now + Duration::seconds(60), "w", &ed);
    assert!(w.cover.as_deref().is_some_and(|c| c.contains("|sb-b")), "{:?}", w.cover);
    let d = magazine::make_issue(&db, IssueKind::Daily, now - Duration::days(1), now + Duration::seconds(60), "d", &ed);
    assert_eq!(d.cover.as_deref(), Some("openai|sb-lab")); // 오늘 호는 점수 순 그대로
}

#[test]
fn publish_due_rebuilds_old_layout() {
    let db = Database::in_memory();
    let d0 = magazine::start_of_day(Utc::now()) - Duration::days(20);
    for i in 0..3 {
        put(&db, &format!("sb-o{i}"), "geeknews", &format!("스마트폰 {i}"), d0 + Duration::hours(i + 1), "press", None);
    }
    let old = issue("daily-old", IssueKind::Daily, d0 - Duration::hours(6), d0 + Duration::hours(18), 1, vec![sec("model", &["geeknews|sb-o0"], None, None)]);
    db.save_issue(&old);
    let list = magazine::publish_due(&db, &Editorial::default(), Utc::now());
    let again = list.iter().find(|i| i.id == "daily-old").expect("다시 엮은 호");
    assert!(!magazine::needs_rebuild(again));
    assert_eq!(again.count, 3);
}
