// 매거진 지난 호(맥 MagIssuesTests): 설치 전 기사 채우기 · 빈 날 호 발행 · 지난 호 목록 날짜 묶음
use chrono::{DateTime, Duration, Local, TimeZone, Utc};
use dropcap_core::app_model::magazine_fill;
use dropcap_core::database::Database;
use dropcap_core::magazine::{self, Editorial, Issue, IssueKind};
use dropcap_core::models::NewsItem;

fn item(id: &str, date: Option<DateTime<Utc>>) -> NewsItem {
    let mut it = NewsItem::new(id, &format!("기사 {id}"), &format!("https://geeknews.example/{id}"), "geeknews", "geeknews", "press");
    it.date = date;
    it
}

fn put(db: &Database, id: &str, date: DateTime<Utc>) {
    db.upsert(&item(id, Some(date)), None, date);
}

fn local(y: i32, m: u32, d: u32, h: u32) -> DateTime<Utc> {
    Local.with_ymd_and_hms(y, m, d, h, 0, 0).earliest().unwrap().with_timezone(&Utc)
}

fn daily(y: i32, m: u32, d: u32, count: i64) -> Issue {
    let day = local(y, m, d, 0);
    Issue { id: format!("daily-{y:04}-{m:02}-{d:02}"), kind: IssueKind::Daily, date: day, from: day - Duration::hours(6), to: day + Duration::hours(18), cover: None, sections: vec![], count }
}

// 채운 지난 날 기사도 그날 호가 생긴다(예전엔 1~3일 전만 엮어 4일 넘은 날은 영영 호가 없었다). 14일보다 앞은 엮지 않는다
#[test]
fn publish_due_fills_empty_days() {
    let db = Database::in_memory();
    let today = magazine::start_of_day(Utc::now());
    for back in [6, 10, 20] {
        let day = today - Duration::days(back);
        for i in 0..3 {
            put(&db, &format!("d{back}-{i}"), day + Duration::hours(10 + i));
        }
    }
    let ids: Vec<String> = magazine::publish_due(&db, &Editorial::default(), Utc::now()).into_iter().map(|i| i.id).collect();
    let id = |back: i64| format!("daily-{}", magazine::day_id(today - Duration::days(back) + Duration::hours(12)));
    assert!(ids.contains(&id(6)) && ids.contains(&id(10)), "{ids:?}");
    assert!(!ids.contains(&id(20)));
}

// 지지난주 기사도 주간 호가 생긴다(예전엔 지난주만)
#[test]
fn publish_due_fills_week_before_last() {
    let db = Database::in_memory();
    let this = magazine::week_range(Utc::now()).0;
    let last = magazine::week_range(this - Duration::hours(1)).0;
    let before = magazine::week_range(last - Duration::hours(1)).0;
    for i in 0..3 {
        put(&db, &format!("w{i}"), before + Duration::hours(30 + i));
    }
    let ids: Vec<String> = magazine::publish_due(&db, &Editorial::default(), Utc::now()).into_iter().map(|i| i.id).collect();
    assert!(ids.contains(&format!("weekly-{}", magazine::week_id(before))), "{ids:?}");
}

// 채우기: 7일 안 · 새것부터 상한까지 · 날짜 없는 글·앞날 글 뺌(예전엔 3일·25건)
#[test]
fn magazine_fill_window_and_cap() {
    let now = Utc::now();
    let mut items: Vec<NewsItem> = (0..200).map(|h| item(&format!("f{h}"), Some(now - Duration::hours(h)))).collect();
    items.push(item("nodate", None));
    items.push(item("future", Some(now + Duration::days(1))));
    let all = magazine_fill(&items, now, 500, 7);
    assert_eq!(all.len(), 168);
    assert!(!all.iter().any(|i| i.id == "nodate" || i.id == "future"));
    let capped = magazine_fill(&items, now, 120, 7);
    assert_eq!(capped.len(), 120);
    assert_eq!(capped[0].id, "f0");
}

#[test]
fn existing_keys_and_count() {
    let db = Database::in_memory();
    put(&db, "e1", Utc::now());
    let got = db.existing(&["geeknews|e1".to_string(), "geeknews|e2".to_string()]);
    assert_eq!(got.into_iter().collect::<Vec<_>>(), vec!["geeknews|e1".to_string()]);
    assert_eq!(db.article_count(Utc::now() - Duration::hours(1), Utc::now() + Duration::hours(1)), 1);
}

// 지난 호 목록: 이번 주 · 지난주 · 그 앞은 달별(접힘). 주간 호는 그 주 묶음 맨 위, 빈 날 수(맥과 같은 예)
#[test]
fn archive_groups_by_week_and_month() {
    let now = local(2026, 10, 22, 9); // 목요일 · 이번 주 10-18(일)~
    let weekly = Issue { id: "weekly-x".into(), kind: IssueKind::Weekly, date: local(2026, 10, 18, 0), from: local(2026, 10, 11, 0), to: local(2026, 10, 18, 0), cover: None, sections: vec![], count: 50 };
    let issues = magazine::archive_order(vec![
        daily(2026, 10, 21, 10), daily(2026, 10, 19, 10),
        weekly, daily(2026, 10, 16, 10), daily(2026, 10, 12, 10),
        daily(2026, 9, 30, 2), daily(2026, 9, 28, 10),
    ]);
    let g = magazine::archive_groups(&issues, now);
    assert_eq!(g.iter().map(|g| g.title.as_str()).collect::<Vec<_>>(), ["이번 주", "지난주", "2026년 9월"]);
    assert_eq!(g[0].issues.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(), ["daily-2026-10-21", "daily-2026-10-19"]);
    assert_eq!(g[0].empty_days, 2); // 18·20
    assert_eq!(g[1].issues[0].id, "weekly-x");
    assert_eq!(g[1].empty_days, 5); // 11·13·14·15·17
    assert!(!g[0].folded && !g[1].folded && g[2].folded);
    assert_eq!(g[2].empty_days, 1); // 9-29
}

#[test]
fn thin_reason_and_last_check() {
    assert!(magazine::thin_reason(&daily(2026, 10, 1, 2)).unwrap().contains("2건"));
    assert!(magazine::thin_reason(&daily(2026, 10, 1, 40)).is_none());
    let now = Utc::now();
    assert_eq!(magazine::last_check_text(None, now), "아직 확인 전");
    assert_eq!(magazine::last_check_text(Some(now - Duration::seconds(20)), now), "마지막 확인 방금");
    assert_eq!(magazine::last_check_text(Some(now - Duration::minutes(7)), now), "마지막 확인 7분 전");
}
