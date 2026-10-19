// 맥 SettingsQATests: 설정이 실제 동작에 반영되는지
use chrono::Utc;
use dropcap_core::app_model::{prune_pending, words};
use dropcap_core::models::NewsItem;
use dropcap_core::store::PendingItem;

fn pend(id: &str, title: &str, src: &str, sec: &str) -> PendingItem {
    let mut item = NewsItem::new(id, title, "", src, src, "media");
    item.date = Some(Utc::now());
    PendingItem { item, section: sec.into(), story: id.into(), at: Utc::now() }
}

// 고인 소식(묶음 대기열)도 설정을 따른다: '알리지 않음' 낱말 · 알림 끈 출처 · '매거진만' 분야는 묶음 시각에 나가지 않음
#[test]
fn pending_follows_mute_bell_and_magazine_only() {
    let all = vec![
        pend("a", "Chip prices rise", "s1", "economy"),
        pend("b", "주식 시장 마감", "s1", "economy"),
        pend("c", "Rate decision", "s2", "economy"),
        pend("d", "Election news", "s1", "politics"),
    ];
    let kept = prune_pending(&all, &words(&["주식".into()]), |s| s != "s2", |sec| sec == "politics");
    assert_eq!(kept.iter().map(|p| p.item.id.as_str()).collect::<Vec<_>>(), ["a"]);
    assert_eq!(prune_pending(&all, &[], |_| true, |_| false).len(), 4);
}
