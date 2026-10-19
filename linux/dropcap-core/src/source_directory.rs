// 설정 › 구독의 출처 목록 정리(맥 Core/SourceDirectory.swift): 찾기(이름·주소·분야·국내/해외) · 켠 것/끈 것 거르기 ·
// 매체별/분야별/지역별 묶음 · 켠 출처 요약. 화면 없이 시험한다(tests/source_directory_tests.rs). 세 판이 같은 규칙.
use crate::models::Source;
use crate::sections;
use std::collections::{BTreeMap, HashSet};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Layout {
    #[default]
    Media,
    Section,
    Region,
}

impl Layout {
    pub const ALL: [Layout; 3] = [Layout::Media, Layout::Section, Layout::Region];
    pub fn raw(self) -> &'static str {
        match self {
            Layout::Media => "media",
            Layout::Section => "section",
            Layout::Region => "region",
        }
    }
    pub fn from_raw(s: &str) -> Layout {
        match s {
            "section" => Layout::Section,
            "region" => Layout::Region,
            _ => Layout::Media,
        }
    }
    pub fn label(self) -> &'static str {
        match self {
            Layout::Media => "매체별",
            Layout::Section => "분야별",
            Layout::Region => "지역별",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Status {
    #[default]
    All,
    On,
    Off,
}

impl Status {
    pub const ALL: [Status; 3] = [Status::All, Status::On, Status::Off];
    pub fn label(self) -> &'static str {
        match self {
            Status::All => "전체",
            Status::On => "켠 것",
            Status::Off => "끈 것",
        }
    }
}

// 한 묶음: 보이는 출처(거른 뒤)와 묶음 전체의 켠 수/전체 수
#[derive(Debug, Clone, PartialEq)]
pub struct Group {
    pub id: String,           // media:yna · section:economy · region:kr
    pub title: String,
    pub sources: Vec<Source>, // 거르고 정렬한 것(묶음 동작은 이것에만)
    pub on: usize,            // 묶음 전체에서 켠 수
    pub total: usize,         // 묶음 전체 수
}

pub fn region_label(s: &Source) -> &'static str {
    if s.is_domestic() {
        "국내"
    } else {
        "해외"
    }
}

// 매체 묶음 키: id 의 첫 '-' 앞(yna-market → yna, bbc-world → bbc). 기본 출처 id 가 이 규칙으로 지어져 있다
pub fn media_key(s: &Source) -> &str {
    s.id.split('-').next().unwrap_or(&s.id)
}

// 매체 이름: 모두 같은 이름 → 그 이름, 모두 같은 첫 낱말 → 그 낱말(연합뉴스·BBC), 대표 피드(id == 묶음 키 또는 키-home) 이름(nyt-home → The New York Times), 아니면 가장 짧은 이름
pub fn media_name(members: &[Source]) -> String {
    let Some(first) = members.first() else { return String::new() };
    if members.iter().all(|m| m.name == first.name) {
        return first.name.clone();
    }
    let head = |n: &str| n.split(' ').find(|w| !w.is_empty()).unwrap_or("").to_string();
    let h = head(&first.name);
    if !h.is_empty() && members.iter().all(|m| head(&m.name) == h) {
        return h;
    }
    // 대표 피드(id == 묶음 키, 또는 묶음 키-home)의 이름(nyt-home → The New York Times)
    if let Some(base) = members.iter().find(|m| m.id == media_key(m) || m.id == format!("{}-home", media_key(m))) {
        return base.name.clone();
    }
    members.iter().map(|m| &m.name).min_by(|a, b| (a.chars().count(), a.as_str()).cmp(&(b.chars().count(), b.as_str()))).cloned().unwrap_or_default()
}

// 묶음 안에서 보일 짧은 이름: 매체 이름을 떼고(연합뉴스 경제 → 경제), 떼면 비면 원래 이름
pub fn short_name(s: &Source, media: &str) -> String {
    match s.name.strip_prefix(&format!("{media} ")) {
        Some(rest) if !rest.trim().is_empty() => rest.trim().to_string(),
        _ => s.name.clone(),
    }
}

// 비교용: 소문자·띄어쓰기 없앰
pub fn fold(s: &str) -> String {
    s.to_lowercase().chars().filter(|c| !c.is_whitespace()).collect()
}

pub fn matches(s: &Source, query: &str) -> bool {
    let q = fold(query);
    if q.is_empty() {
        return true;
    }
    let section = sections::name(s.section_id());
    let hay = [s.name.as_str(), s.url.as_str(), s.home.as_deref().unwrap_or(""), section.as_str(), region_label(s)];
    hay.iter().any(|h| fold(h).contains(&q))
}

pub fn filter(sources: &[Source], query: &str, status: Status, enabled: impl Fn(&str) -> bool) -> Vec<Source> {
    sources
        .iter()
        .filter(|s| match status {
            Status::All => true,
            Status::On => enabled(&s.id),
            Status::Off => !enabled(&s.id),
        })
        .filter(|s| matches(s, query))
        .cloned()
        .collect()
}

// 정렬: 국내 먼저(가나다) 그다음 해외(ABC). 같은 이름은 id 순. 유니코드 순서라 세 판이 같다
pub fn sort_key(name: &str, domestic: bool) -> (u8, String) {
    (if domestic { 0 } else { 1 }, name.to_lowercase())
}

pub fn sorted(sources: &[Source]) -> Vec<Source> {
    let mut v = sources.to_vec();
    v.sort_by(|a, b| sort_key(&a.name, a.is_domestic()).cmp(&sort_key(&b.name, b.is_domestic())).then_with(|| a.id.cmp(&b.id)));
    v
}

// 분야 순서: categories.json 순서, 그 밖 분야는 뒤에 id 순
fn section_order<'a>(extra: impl Iterator<Item = &'a str>) -> Vec<String> {
    let mut ids: Vec<String> = sections::ALL.iter().map(|s| s.id.clone()).collect();
    let known: HashSet<String> = ids.iter().cloned().collect();
    let mut rest: Vec<String> = extra.filter(|x| !known.contains(*x)).map(str::to_string).collect::<HashSet<_>>().into_iter().collect();
    rest.sort();
    ids.extend(rest);
    ids
}

// all: 묶음 전체(켠 수 계산), shown: 거른 결과. 보이는 것이 없는 묶음은 뺀다
pub fn groups(all: &[Source], shown: &[Source], layout: Layout, enabled: impl Fn(&str) -> bool) -> Vec<Group> {
    let visible: HashSet<&str> = shown.iter().map(|s| s.id.as_str()).collect();
    let make = |id: String, title: String, members: Vec<Source>| -> Option<Group> {
        let list = sorted(&members.iter().filter(|m| visible.contains(m.id.as_str())).cloned().collect::<Vec<_>>());
        if list.is_empty() {
            return None;
        }
        let on = members.iter().filter(|m| enabled(&m.id)).count();
        Some(Group { id, title, sources: list, on, total: members.len() })
    };
    match layout {
        Layout::Media => {
            let mut by_key: BTreeMap<&str, Vec<Source>> = BTreeMap::new();
            for s in all {
                by_key.entry(media_key(s)).or_default().push(s.clone());
            }
            let mut v: Vec<Group> = by_key.into_iter().filter_map(|(k, m)| make(format!("media:{k}"), media_name(&m), m)).collect();
            v.sort_by(|a, b| {
                sort_key(&a.title, a.sources[0].is_domestic()).cmp(&sort_key(&b.title, b.sources[0].is_domestic())).then_with(|| a.id.cmp(&b.id))
            });
            v
        }
        Layout::Section => section_order(all.iter().map(|s| s.section_id()))
            .into_iter()
            .filter_map(|id| make(format!("section:{id}"), sections::name(&id), all.iter().filter(|s| s.section_id() == id).cloned().collect()))
            .collect(),
        Layout::Region => [
            make("region:kr".into(), "국내".into(), all.iter().filter(|s| s.is_domestic()).cloned().collect()),
            make("region:intl".into(), "해외".into(), all.iter().filter(|s| !s.is_domestic()).cloned().collect()),
        ]
        .into_iter()
        .flatten()
        .collect(),
    }
}

// 맨 위 요약: 켠 출처 수와 분야별 켠 수(분야 순서, 0 인 분야는 뺌) — (분야 id, 이름, 수)
pub fn summary(sources: &[Source], enabled: impl Fn(&str) -> bool) -> (usize, Vec<(String, String, usize)>) {
    let on: Vec<&Source> = sources.iter().filter(|s| enabled(&s.id)).collect();
    let mut counts: BTreeMap<&str, usize> = BTreeMap::new();
    for s in &on {
        *counts.entry(s.section_id()).or_default() += 1;
    }
    let by = section_order(counts.keys().copied())
        .into_iter()
        .filter_map(|id| counts.get(id.as_str()).map(|n| (id.clone(), sections::name(&id), *n)))
        .collect();
    (on.len(), by)
}

pub fn summary_text(sources: &[Source], enabled: impl Fn(&str) -> bool) -> String {
    let (n, by) = summary(sources, enabled);
    if n == 0 {
        return "켠 출처 없음".into();
    }
    let parts: Vec<String> = by.iter().map(|(_, name, c)| format!("{name} {c}")).collect();
    format!("켠 출처 {n}곳 · {}", parts.join(" · "))
}

pub fn count_text(shown: usize, total: usize) -> String {
    if shown == total {
        format!("{total}곳")
    } else {
        format!("{total}곳 중 {shown}곳")
    }
}

// 줄의 유료 자물쇠 설명(sources.json 의 paywall): hard · metered. 없으면 무료
pub fn paywall_note(s: &Source) -> Option<&'static str> {
    match s.paywall.as_deref() {
        Some("hard") => Some("구독해야 읽을 수 있음"),
        Some("metered") => Some("한 달 몇 건 무료"),
        _ => None,
    }
}
