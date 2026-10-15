// 맥 SidebarRuleTests(subtitle · storyTopic)·WeeklyQuotesTests 를 옮긴 것과 분야 지면(M-25)·스토리 팔로우(M-26)·이번 주 모은 문장(M-27) 규칙.
use chrono::{Duration, FixedOffset, TimeZone, Utc};
use dropcap_core::category::NewsCategory;
use dropcap_core::database::Database;
use dropcap_core::magazine::{self, Editorial, IssueKind};
use dropcap_core::models::NewsItem;
use dropcap_core::scrapbook::Scrap;
use dropcap_core::sections;

fn item(id: &str, source: &str, title: &str) -> NewsItem {
    NewsItem::new(id, title, &format!("https://{source}.example/{id}"), source, source, "press")
}

fn put(db: &Database, title: &str, src: &str, minutes_ago: i64, kind: Option<&str>) -> NewsItem {
    let mut it = NewsItem::new(title, title, &format!("https://e.example/{}", title.replace(' ', "-")), src, src, "press");
    it.date = Some(Utc::now() - Duration::minutes(minutes_ago));
    it.kind = kind.map(|s| s.into());
    db.upsert(&it, None, Utc::now());
    it
}

// MARK: 머리 숫자(맥 subtitleMatchesWhatIsShown)
#[test]
fn subtitle_matches_what_is_shown() {
    assert_eq!(magazine::subtitle(192, 17, 2, "소식"), "소식 192건 중 17건 실음 · 분야 2개");
    assert_eq!(magazine::subtitle(12, 12, 1, "소식"), "소식 12건 · 분야 1개");
    assert_eq!(magazine::subtitle(40, 13, 0, "IT 소식"), "IT 소식 40건 중 13건 실음");
    // 분야 지면 머리: 분야 이름 + 실린 것 기준 출처 수
    let shown = vec![item("1", "a", "x"), item("2", "b", "y"), item("3", "a", "z")];
    assert_eq!(magazine::section_subtitle("tech", 10, &shown), "IT 소식 10건 중 3건 실음 · 출처 2곳");
    assert_eq!(magazine::section_subtitle("tech", 3, &shown), "IT 소식 3건 · 출처 2곳");
}

// MARK: 분야 지면(M-25): 그 분야 칩이 달린 기사만, 구독 채널 지면 없이, 40건까지
#[test]
fn section_page_holds_only_that_section() {
    let db = Database::in_memory();
    for i in 0..50 {
        put(&db, &format!("OpenAI GPT model update number {i}"), "openai", 30 + i, None);
    }
    put(&db, &format!("Paper on GPT attention {}", 1), "arxiv", 20, Some("paper"));
    let others = [
        put(&db, "Football club wins league final", "bbc-top", 25, None),
        put(&db, "Parliament passes budget bill", "yna-latest", 25, None),
        put(&db, "Heavy rain expected this weekend", "sbs-top", 25, None),
    ];
    let probe = item("p", "openai", "OpenAI GPT model update number 0");
    let id = sections::AI;
    assert!(probe.in_section(id));
    let issue = magazine::live_section(&db, &Editorial::default(), id);
    assert_eq!(issue.id, "live-section-ai");
    assert_eq!(issue.kind, IssueKind::Daily);
    // 구독 채널(논문) 지면은 없고, 기사 지면 하나 = 그 분야
    assert!(issue.sections.iter().all(|s| s.kind.is_none()));
    assert_eq!(issue.sections.len(), 1);
    assert_eq!(issue.sections[0].section.as_deref(), Some(id));
    assert_eq!(issue.sections[0].keys.len(), magazine::SECTION_PAGE_LIMIT); // 표지 1 + 나머지 49 중 40
    // 건수도 그 분야 기준
    let outside = others.iter().filter(|o| !o.in_section(id)).count();
    assert!(outside > 0, "일반 뉴스 기사 중 AI 칩이 없는 것이 있어야 한다");
    assert_eq!(issue.count, 50 + (others.len() - outside) as i64);
    let keys: Vec<&String> = issue.cover.iter().chain(issue.sections.iter().flat_map(|s| s.keys.iter())).collect();
    for o in others.iter().filter(|o| !o.in_section(id)) {
        assert!(!keys.contains(&&o.key()), "다른 분야 기사가 실림: {}", o.title);
    }
    // 오늘 호(분야 지면이 아닌 것)는 채널 지면이 그대로 있다
    let today = magazine::live_daily(&db, &Editorial::default());
    assert!(today.sections.iter().any(|s| s.kind.as_deref() == Some("paper")));
}

// AI 분야 지면의 하위 칩: 실린 기사에 있는 분류만, '기타'까지 — 칩 숫자의 합 = 실린 수
#[test]
fn ai_sub_chips_sum_to_shown() {
    let items = vec![
        item("1", "a", "Startup raises funding round"),
        item("2", "b", "OpenAI raises funding at new valuation"),
        item("3", "c", "Weekend reading list"),
    ];
    let chips = magazine::sub_chip_counts(&items);
    assert_eq!(chips.iter().map(|c| c.1).sum::<usize>(), items.len());
    assert!(chips.iter().any(|(c, n)| *c == NewsCategory::id("business") && *n == 2));
    assert!(chips.iter().any(|(c, _)| c.is_other())); // 기타 포함
    // 분류 순서대로
    let order: Vec<usize> = chips.iter().map(|c| c.0.sort_order()).collect();
    let mut sorted = order.clone();
    sorted.sort();
    assert_eq!(order, sorted);
    assert!(magazine::sub_chip_counts(&[]).is_empty());
}

// MARK: 스토리(M-26): 분야 다수결(맥 storyTopicIsMajority)
#[test]
fn story_topic_is_majority() {
    // 대표 기사 하나가 AI 낱말에 걸려도 묶인 보도 다수가 IT 면 IT
    let items = vec![item("1", "a", "Example HomeView ad"), item("2", "b", "Example HomeView"), item("3", "c", "AI model in HomeView")];
    let t = magazine::story_topic(&items, |i| if i.id == "3" { sections::AI.to_string() } else { "tech".to_string() }).unwrap();
    assert_eq!(t, ("tech".to_string(), None));
    assert_eq!(magazine::story_topic_label(&t, false).0, "IT");
    // AI 다수면 그 안의 하위 분류도 다수결
    let ai = vec![
        item("1", "a", "Startup raises funding"),
        item("2", "b", "Investors back startup in funding round"),
        item("3", "c", "New model launch"),
    ];
    let t2 = magazine::story_topic(&ai, |_| sections::AI.to_string()).unwrap();
    assert_eq!(t2.0, sections::AI);
    assert_eq!(t2.1, Some(NewsCategory::id("business")));
    assert_eq!(magazine::story_topic_label(&t2, false).0, format!("AI·{}", NewsCategory::id("business").label()));
    assert!(magazine::story_topic(&[], |i| i.section()).is_none());
    // 표가 같으면 분야 순서 앞(정치가 IT 보다 앞)
    let tie = vec![item("1", "a", "x"), item("2", "b", "y")];
    let t3 = magazine::story_topic(&tie, |i| if i.id == "1" { "tech".to_string() } else { "politics".to_string() }).unwrap();
    assert_eq!(t3.0, "politics");
}

// 새 보도 수: 지금 보도 수 − 마지막으로 본 수(맥 unseenReports)
#[test]
fn unseen_reports_count() {
    assert_eq!(magazine::unseen_reports(5, Some(3)), 2);
    assert_eq!(magazine::unseen_reports(5, None), 0); // 본 적 없으면 새 보도로 세지 않음
    assert_eq!(magazine::unseen_reports(3, Some(5)), 0); // 출처를 꺼 줄었으면 0
}

// MARK: 이번 주 모은 문장(M-27, 맥 WeeklyQuotesTests)
fn scrap(it: &NewsItem, quote: Option<&str>, created: chrono::DateTime<Utc>) -> Scrap {
    Scrap {
        id: uuid_like(quote, created),
        item: it.clone(),
        quote: quote.map(|s| s.to_string()),
        quote_original: None,
        memo: String::new(),
        collection: "c".into(),
        created,
    }
}
fn uuid_like(q: Option<&str>, t: chrono::DateTime<Utc>) -> String {
    format!("{}-{}", q.unwrap_or("-"), t.timestamp())
}

#[test]
fn picks_this_weeks_quotes_once() {
    let now = Utc.timestamp_opt(1_792_000_000, 0).unwrap();
    let it = item("1", "x", "t");
    let ago = |d: f64| now - Duration::seconds((d * 86400.0) as i64);
    let list = vec![
        scrap(&it, Some("오래된 문장"), ago(9.0)),
        scrap(&it, Some("이번 주 문장"), ago(2.0)),
        scrap(&it, Some("이번 주 문장"), ago(1.0)),
        scrap(&it, None, ago(1.0)),
        scrap(&it, Some("어제 문장"), ago(0.5)),
    ];
    let picked: Vec<Option<String>> = magazine::pick_weekly_quotes(&list, now, 6).into_iter().map(|s| s.quote).collect();
    assert_eq!(picked, vec![Some("어제 문장".to_string()), Some("이번 주 문장".to_string())]);
    // 앞으로 만든 것(시계 어긋남 1분 넘게)과 개수 제한
    let future = vec![scrap(&it, Some("미래"), now + Duration::minutes(5))];
    assert!(magazine::pick_weekly_quotes(&future, now, 6).is_empty());
    let many: Vec<Scrap> = (0..10).map(|i| scrap(&it, Some(&format!("문장 {i}")), ago(i as f64 * 0.1))).collect();
    assert_eq!(magazine::pick_weekly_quotes(&many, now, 6).len(), 6);
}

#[test]
fn sunday_evening_only() {
    if std::env::var("DROPCAP_TEST_WEEKLY").is_ok() {
        return;
    }
    let kst = FixedOffset::east_opt(9 * 3600).unwrap();
    let at = |d: u32, h: u32| kst.with_ymd_and_hms(2026, 10, d, h, 0, 0).unwrap(); // 2026-10-11 은 일요일
    assert!(magazine::is_sunday_evening(&at(11, 18)));
    assert!(magazine::is_sunday_evening(&at(11, 17)));
    assert!(!magazine::is_sunday_evening(&at(11, 16)));
    assert!(!magazine::is_sunday_evening(&at(11, 10)));
    assert!(!magazine::is_sunday_evening(&at(12, 19)));
}
