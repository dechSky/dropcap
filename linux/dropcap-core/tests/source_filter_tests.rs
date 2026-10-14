// 맥 SourceFilterTests.swift 를 옮긴 것 + 끄기·숨기기·지우기가 목록·안 읽음 수·매거진·스토리·검색에 바로 반영되는지(S-13)
use chrono::{Duration, Utc};
use dropcap_core::app_model::{recount_unread, AppModel};
use dropcap_core::database::Cluster;
use dropcap_core::magazine;
use dropcap_core::models::{resources, NewsItem, Source};
use dropcap_core::source_filter::SourceFilter;
use dropcap_core::store::{AppState, Store};
use std::sync::Arc;

fn sources() -> Vec<Source> {
    resources::CONFIG.sources.iter().take(3).cloned().collect()
}

fn item(src: &str, id: &str) -> NewsItem {
    let mut it = NewsItem::new(id, &format!("t-{id}"), &format!("https://x.com/{id}"), src, src, "press");
    it.date = Some(Utc::now());
    it
}

fn state(on: &[&str], hidden: &[&str]) -> AppState {
    let mut s = AppState::default();
    for id in on {
        s.enabled.insert(id.to_string(), true);
    }
    s.hidden_sources = hidden.iter().map(|h| h.to_string()).collect();
    s
}

fn ids(v: &[NewsItem]) -> Vec<String> {
    v.iter().map(|i| i.id.clone()).collect()
}

#[test]
fn turning_off_hides_and_turning_on_restores() {
    let src = sources();
    let (a, b) = (src[0].id.as_str(), src[1].id.as_str());
    let items = vec![item(a, "1"), item(b, "2"), item(a, "3")];
    let mut st = state(&[a, b], &[]);
    assert_eq!(SourceFilter::make(&st, &src).visible(&items).len(), 3);
    st.enabled.insert(a.into(), false); // 구독 끄기
    assert_eq!(ids(&SourceFilter::make(&st, &src).visible(&items)), vec!["2"]);
    st.enabled.insert(a.into(), true); // 다시 켜기 → 지우지 않았으므로 그대로 돌아옴
    assert_eq!(SourceFilter::make(&st, &src).visible(&items).len(), 3);
}

#[test]
fn removed_custom_source_is_hidden() {
    let src = sources();
    let a = src[0].id.as_str();
    let gone = "custom-removed-channel"; // 지워서 출처 목록에 없는 채널
    let st = state(&[a, gone], &[]);
    assert_eq!(ids(&SourceFilter::make(&st, &src).visible(&[item(a, "1"), item(gone, "2")])), vec!["1"]);
}

#[test]
fn section_deselect_turns_sources_off_so_they_hide() {
    // 분야를 빼면 그 분야 출처의 enabled 가 false 가 되므로(choose_sections) 같은 판단으로 빠진다
    let src = sources();
    let (a, b) = (src[0].id.as_str(), src[1].id.as_str());
    let mut st = state(&[a, b], &[]);
    st.enabled.insert(b.into(), false);
    assert!(SourceFilter::make(&st, &src).shows(a));
    assert!(!SourceFilter::make(&st, &src).shows(b));
}

#[test]
fn hidden_wins_even_when_enabled() {
    let src = sources();
    let a = src[0].id.as_str();
    assert!(!SourceFilter::make(&state(&[a], &[a]), &src).shows(a));
}

#[test]
fn never_enabled_source_is_hidden() {
    let src = sources();
    assert!(!SourceFilter::make(&state(&[], &[]), &src).shows(&src[0].id));
}

#[test]
fn no_active_set_means_only_hidden_applies() {
    let f = SourceFilter::hidden_only(["x".to_string()]);
    assert!(f.shows("y") && !f.shows("x"));
}

#[test]
fn unread_recount() {
    let a = item("a", "1");
    let b = item("b", "2");
    // 어떤 소식이 들었는지 알면 보이는 것만 센다
    assert_eq!(recount_unread(5, &[a.key(), b.key()], std::slice::from_ref(&a)), 1);
    assert_eq!(recount_unread(5, &[a.key(), b.key()], &[a.clone(), b.clone()]), 2);
    // 예전 파일(모름)이면 줄이기만
    assert_eq!(recount_unread(5, &[], std::slice::from_ref(&a)), 1);
    assert_eq!(recount_unread(0, &[], &[a, b]), 0);
}

// 앱 핵심 전체: 끄기·숨기기·지우기 → 목록·안 읽음 수·매거진(오늘 호·지난 호)·스토리·검색, 다시 켜면 돌아옴
#[test]
fn turning_off_updates_every_view() {
    let rt = tokio::runtime::Runtime::new().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let core = AppModel::new(Store::new(dir.path().to_path_buf()), rt.handle().clone());
    let src = sources();
    let (a, b) = (src[0].id.clone(), src[1].id.clone());
    let now = Utc::now();
    let mut ia = item(&a, "a1");
    ia.title = "Zephyrine launches new chip".into();
    let mut ib = item(&b, "b1");
    ib.title = "Zephyrine chip reviewed".into();
    // 두 출처가 함께 다룬 스토리
    core.db.save_cluster(&Cluster { id: "c1".into(), title: "Zephyrine chip".into(), tokens: Default::default(), first: now, last: now, size: 2 });
    core.db.upsert(&ia, Some("c1"), now);
    core.db.upsert(&ib, Some("c1"), now);
    // 스토리 밖 기사(지면에는 스토리마다 대표 하나만 실리므로 출처마다 하나씩 더)
    core.db.upsert(&item(&a, "a2"), None, now);
    core.db.upsert(&item(&b, "b2"), None, now);
    let (ia2, ib2) = (ia.clone(), ib.clone());
    let (a2, b2) = (a.clone(), b.clone());
    core.replace_state(move |s| {
        let mut s = s.clone();
        s.enabled.insert(a2, true);
        s.enabled.insert(b2, true);
        s.sections_chosen = Some(vec!["ai".into()]);
        s.recent = vec![ia2.clone(), ib2.clone()];
        s.unread = 2;
        s.unread_keys = vec![ia2.key(), ib2.key()];
        s
    });
    let issue_ids = |c: &Arc<AppModel>| {
        let ed = c.editorial();
        let issue = magazine::make_issue(&c.db, magazine::IssueKind::Daily, now - Duration::hours(1), now + Duration::hours(1), "t", &ed);
        let r = magazine::resolve(&c.db, &issue, &ed.filter);
        let mut v: Vec<String> = r.cover.iter().map(|x| x.item.id.clone()).chain(r.sections.iter().flat_map(|(_, i)| i.iter().map(|x| x.id.clone()))).collect();
        v.sort();
        (v, issue)
    };
    let (before, old_issue) = issue_ids(&core);
    assert!(before.contains(&"a2".to_string()) && before.contains(&"b2".to_string()));
    assert_eq!(magazine::stories(&core.db, &core.source_filter()).len(), 1);
    assert_eq!(core.search("Zephyrine", 50).len(), 2);

    // 끄기
    core.set_enabled(&a, false);
    assert_eq!(ids(&core.visible_recent()), vec!["b1"]);
    assert_eq!(core.state().unread, 1); // 안 읽음 수도 줄어든다
    let off = issue_ids(&core).0;
    assert!(off.contains(&"b2".to_string()) && !off.iter().any(|i| i.starts_with('a')), "{off:?}");
    let old = magazine::resolve(&core.db, &old_issue, &core.editorial().filter); // 지난 호도
    assert!(old.cover.iter().all(|c| !c.item.id.starts_with('a')) && old.sections.iter().all(|(_, i)| i.iter().all(|x| !x.id.starts_with('a'))));
    assert!(magazine::stories(&core.db, &core.source_filter()).is_empty()); // 한 곳만 남으면 스토리 목록에서 빠짐
    assert_eq!(ids(&core.story_items("c1")), vec!["b1"]);
    assert_eq!(ids(&core.search("Zephyrine", 50)), vec!["b1"]);
    assert_eq!(core.state().recent.len(), 2); // 지우지는 않음

    // 다시 켜기 → 그대로 돌아옴(안 읽음 수 포함). set_enabled(true) 는 확인을 돌리므로 시험에서는 상태로 켠다
    let a3 = a.clone();
    core.replace_state(move |s| {
        let mut s = s.clone();
        s.enabled.insert(a3, true);
        s
    });
    assert_eq!(core.visible_recent().len(), 2);
    assert_eq!(core.state().unread, 2);
    assert!(issue_ids(&core).0.contains(&"a2".to_string()));
    assert_eq!(magazine::stories(&core.db, &core.source_filter()).len(), 1);

    // 숨기기 · 숨김 풀기
    core.hide_source(&b);
    assert_eq!(ids(&core.visible_recent()), vec!["a1"]);
    assert_eq!(ids(&core.search("Zephyrine", 50)), vec!["a1"]);
    core.unhide_source(&b);
    assert_eq!(core.visible_recent().len(), 2);

    // '알리지 않음' 낱말도 지우지 않고 거르기만
    core.update(|s| s.mute_keywords = vec!["reviewed".into()]);
    core.reapply_keywords();
    assert_eq!(ids(&core.visible_recent()), vec!["a1"]);
    core.update(|s| s.mute_keywords.clear());
    core.reapply_keywords();
    assert_eq!(core.visible_recent().len(), 2);
}
