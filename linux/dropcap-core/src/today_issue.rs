// 오늘 호 완독(M-23) — 맥 Core/TodayIssue.swift.
// 오늘 호의 대표 기사(표지 + 주요 뉴스·고른 분야마다 첫 줄)를 다 읽으면 '오늘 호를 다 읽었어요'로 끝을 알리고 더 밀어 넣지 않는다.
use crate::magazine::Section;
use crate::models::NewsItem;
use crate::sections;
use chrono::{DateTime, Utc};
use crate::store::Prefs;

pub const PER_SECTION: usize = 3; // 지면 첫 줄(카드 세 장)

// 대표 기사 key: 표지 → 주요 뉴스 지면 첫 줄 → 고른 분야 지면 첫 줄(분야 순서). 구독 채널 지면은 빼고, 겹치면 한 번만
pub fn keys(cover: Option<&str>, pages: &[(Section, Vec<NewsItem>)], chosen: &[String]) -> Vec<String> {
    let mut out: Vec<String> = cover.map(|c| vec![c.to_string()]).unwrap_or_default();
    let plain: Vec<&(Section, Vec<NewsItem>)> = pages.iter().filter(|p| p.0.kind.is_none()).collect();
    let top = plain.iter().filter(|p| p.0.section.as_deref() == Some(sections::TOP));
    let picked = plain.iter().filter(|p| p.0.section.as_deref().map(|s| s != sections::TOP && chosen.iter().any(|c| c == s)).unwrap_or(false));
    for p in top.chain(picked) {
        for it in p.1.iter().take(PER_SECTION) {
            let k = it.key();
            if !out.contains(&k) {
                out.push(k);
            }
        }
    }
    out
}

// 다음 호 안내: 아침 브리핑을 켰으면 그 시각, 아니면 '내일 아침'
pub fn next_issue_text(digest_enabled: bool, digest_hour: i64) -> String {
    if !digest_enabled {
        return "다음 호는 내일 아침에 엮여요".into();
    }
    let h = if digest_hour % 12 == 0 { 12 } else { digest_hour % 12 };
    format!("다음 호는 내일 {} {h}시 브리핑으로 알려 드릴게요", if digest_hour < 12 { "오전" } else { "오후" })
}

// 오늘 다 읽었다고 한 번 정해지면(사진·표지가 바뀌어 대표 기사가 달라져도) 그날은 끝난 호로 둔다(prefs.json todayIssueDone = 날짜).
// prefs 는 화면 쪽이 들고 저장하므로(덮어쓰지 않게) 그 사본으로 읽고 쓴다
pub fn is_marked_done(prefs: &Prefs, now: DateTime<Utc>) -> bool {
    prefs.today_issue_done.as_deref() == Some(crate::magazine::day_id(now).as_str())
}

pub fn mark_done(prefs: &mut Prefs, now: DateTime<Utc>) {
    prefs.today_issue_done = Some(crate::magazine::day_id(now));
}
