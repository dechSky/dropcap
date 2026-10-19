// 매거진 편집국: 기사를 모으고(DB), 스토리로 묶고, 점수를 매겨 호를 엮는다(맥 Core/Magazine.swift 와 같은 수치).
use crate::category::{kind_color, NewsCategory};
use crate::database::{Cluster, Database, KindFilter, StoredItem};
use crate::models::{ItemKind, NewsItem};
use crate::models::resources;
use crate::notify_policy::{crosses, Coverage, PolicyLimits};
use crate::sections::{self, SourceMeta};
use crate::story_match;
use crate::iso;
use chrono::{DateTime, Datelike, Duration, Local, NaiveDate, TimeZone, Timelike, Utc};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum IssueKind {
    Daily,
    Weekly,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Section {
    pub category: NewsCategory,
    pub keys: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>, // 영상·논문 등 구독 채널 지면이면 그 종류
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub section: Option<String>, // 일반 뉴스 분야 지면이면 그 분야 id(예전에 엮은 호에는 없음)
}

impl Section {
    pub fn id(&self) -> String {
        self.kind.clone().or_else(|| self.section.as_ref().map(|s| format!("s-{s}"))).unwrap_or_else(|| self.category.raw().to_string())
    }
    pub fn label(&self) -> String {
        if let Some(k) = &self.kind {
            return ItemKind::from_raw(k).label().to_string();
        }
        if let Some(s) = self.section.as_deref().and_then(sections::by_id) {
            return s.name.clone();
        }
        if self.category.is_other() {
            "그 밖의 소식".into()
        } else {
            self.category.label().into()
        }
    }
    pub fn icon(&self) -> &'static str {
        if let Some(k) = &self.kind {
            return ItemKind::from_raw(k).icon();
        }
        if let Some(s) = self.section.as_deref().and_then(sections::by_id) {
            return s.icon();
        }
        self.category.icon()
    }
    pub fn color(&self, dark: bool) -> String {
        if let Some(k) = &self.kind {
            return kind_color(ItemKind::from_raw(k), dark).to_string();
        }
        if let Some(s) = self.section.as_deref().and_then(sections::by_id) {
            return s.color.clone();
        }
        self.category.color(dark).to_string()
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Issue {
    pub id: String, // daily-2026-10-13 · weekly-2026-W41
    pub kind: IssueKind,
    #[serde(with = "iso")]
    pub date: DateTime<Utc>, // 발행 시각
    #[serde(with = "iso")]
    pub from: DateTime<Utc>,
    #[serde(with = "iso")]
    pub to: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover: Option<String>, // 표지 기사 key
    pub sections: Vec<Section>,
    pub count: i64,
}

pub fn weekday_ko(w: chrono::Weekday) -> &'static str {
    use chrono::Weekday::*;
    match w {
        Mon => "월요일",
        Tue => "화요일",
        Wed => "수요일",
        Thu => "목요일",
        Fri => "금요일",
        Sat => "토요일",
        Sun => "일요일",
    }
}

impl Issue {
    pub fn title(&self) -> String {
        match self.kind {
            IssueKind::Daily => {
                let d = (self.to - Duration::seconds(60)).with_timezone(&Local);
                format!("{}월 {}일 {} 호", d.month(), d.day(), weekday_ko(d.weekday()))
            }
            IssueKind::Weekly => {
                let a = self.from.with_timezone(&Local);
                let b = (self.to - Duration::seconds(1)).with_timezone(&Local);
                format!("주간 · {}월 {}일–{}월 {}일", a.month(), a.day(), b.month(), b.day())
            }
        }
    }
}

// 관심사: 연 기사의 분야·출처 횟수(맥 AppModel.interestWeight)
#[derive(Debug, Clone, Default)]
pub struct Interest {
    pub category: HashMap<String, f64>,
    pub source: HashMap<String, f64>,
}

impl Interest {
    // 0 ~ 1.5 사이. 많이 본 분야·출처일수록 크다(분야 1.0 · 출처 0.5, 로그 비율)
    pub fn weight(&self, category: NewsCategory, source: Option<&str>) -> f64 {
        let cmax = self.category.values().cloned().fold(0.0, f64::max).max(1.0);
        let smax = self.source.values().cloned().fold(0.0, f64::max).max(1.0);
        let c = (1.0 + self.category.get(category.raw()).cloned().unwrap_or(0.0)).ln() / (1.0 + cmax).ln();
        let s = source.map(|s| (1.0 + self.source.get(s).cloned().unwrap_or(0.0)).ln() / (1.0 + smax).ln()).unwrap_or(0.0);
        1.0 * c + 0.5 * s
    }
}

// 공식 발표·여러 곳 보도·중요 낱말·관심 분야는 위로, 오래될수록 아래로
pub fn score(s: &StoredItem, cluster_size: i64, now: DateTime<Utc>, interest: &Interest) -> f64 {
    let it = &s.item;
    let tier = match it.tier.as_str() {
        "lab" => 2.2,
        "press" => 1.2,
        "kr" => 1.0,
        _ => 0.8,
    };
    let coverage = 1.6 * (1.0 + cluster_size.max(1) as f64).ln();
    let important = if it.is_important() { 2.5 } else { 0.0 };
    let interest = interest.weight(it.category(), Some(&it.source_id));
    let hours = ((now - it.date.unwrap_or(s.first_seen)).num_milliseconds() as f64 / 3_600_000.0).max(0.0);
    let fresh = 2.0 * (-hours / 18.0).exp();
    let picture = if it.image.is_none() { 0.0 } else { 0.4 };
    tier + coverage + important + interest + fresh + picture
}

// 호를 엮을 때의 편집 조건: 관심사(점수), 숨긴 출처, 고른 분야, 문턱
#[derive(Debug, Clone)]
pub struct Editorial {
    pub interest: Interest,
    pub hidden: HashSet<String>,
    pub filter: crate::source_filter::SourceFilter, // 꺼진·지운·숨긴 출처를 뺀다(S-13)
    pub chosen: Option<Vec<String>>,
    pub limits: PolicyLimits,
    pub archive_years: i64, // 지난 기사 보관 기간(0 이면 끝없이) — 호를 엮고 정리할 때
}

impl Default for Editorial {
    fn default() -> Self {
        Editorial {
            interest: Default::default(),
            hidden: Default::default(),
            filter: Default::default(),
            chosen: None,
            limits: Default::default(),
            archive_years: crate::archive::DEFAULT_YEARS,
        }
    }
}

pub fn make_issue(db: &Database, kind: IssueKind, from: DateTime<Utc>, to: DateTime<Utc>, id: &str, ed: &Editorial) -> Issue {
    make_issue_in(db, kind, from, to, id, ed, None)
}

// only: 분야 지면(그 분야 칩이 달린 기사만, 구독 채널 지면 없이 — 맥 Editor.makeIssue(only:))
pub fn make_issue_in(db: &Database, kind: IssueKind, from: DateTime<Utc>, to: DateTime<Utc>, id: &str, ed: &Editorial, only: Option<&str>) -> Issue {
    // 기사와 구독 채널 글을 따로(논문이 많아도 기사가 잘리지 않게). 숨긴 출처는 스토리 대표를 고르기 전에 뺀다.
    let mut stored = db.items_kind(from, Some(to), 4000, KindFilter::Articles);
    if only.is_none() {
        stored.extend(db.items_kind(from, Some(to), 800, KindFilter::Channels));
    }
    stored.retain(|s| !ed.hidden.contains(&s.item.source_id) && ed.filter.shows(&s.item.source_id));
    if let Some(sec) = only {
        stored.retain(|s| s.item.in_section(sec));
    }
    // 같은 스토리는 대표 하나만 지면에(점수 높은 것)
    let mut sizes: HashMap<String, i64> = HashMap::new();
    for s in &stored {
        if let Some(c) = &s.cluster {
            *sizes.entry(c.clone()).or_default() += 1;
        }
    }
    let mut best: HashMap<String, (StoredItem, f64)> = HashMap::new();
    let mut loose: Vec<(StoredItem, f64)> = vec![];
    for s in &stored {
        let size = s.cluster.as_ref().and_then(|c| sizes.get(c).cloned()).unwrap_or(1);
        let sc = score(s, size, to, &ed.interest);
        match &s.cluster {
            Some(c) => {
                if best.get(c).map(|b| b.1).unwrap_or(-1.0) < sc {
                    best.insert(c.clone(), (s.clone(), sc));
                }
            }
            None => loose.push((s.clone(), sc)),
        }
    }
    let mut ranked: Vec<(StoredItem, f64)> = best.into_values().chain(loose).collect();
    ranked.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal).then_with(|| a.0.item.key().cmp(&b.0.item.key())));
    let limit = if kind == IssueKind::Weekly { 60 } else { 90 };
    let picked: Vec<&(StoredItem, f64)> = ranked.iter().filter(|r| r.0.item.item_kind() == ItemKind::Article).take(limit).collect();
    // 표지: 사진이 있는 기사 중 점수 1등(없으면 그냥 1등). 화면 캡처·글자 그림·로고로 잰 사진은 건너뛴다(M-24)
    // 주간 표지는 그 주 가장 많이 다룬 이야기(스토리 보도 수 → 점수 순) — 오늘 표지와 같아지지 않게
    let cover_order: Vec<&(StoredItem, f64)> = if kind == IssueKind::Weekly { weekly_cover_order(&picked, &sizes) } else { picked.clone() };
    let photo_scores = db.image_scores(&cover_order.iter().take(30).filter_map(|r| r.0.item.image.clone()).collect::<Vec<_>>());
    let ranked_items: Vec<NewsItem> = cover_order.iter().map(|r| r.0.item.clone()).collect();
    let cover = crate::photo_quality::pick_cover(&ranked_items, &photo_scores).or_else(|| cover_order.first().map(|r| r.0.item.key()));
    let articles: Vec<StoredItem> = picked.iter().filter(|r| Some(r.0.item.key()) != cover).map(|r| r.0.clone()).collect();
    let only_pick: Option<Vec<String>> = only.map(|s| vec![s.to_string()]);
    let chosen = if only.is_some() { only_pick.as_deref() } else { ed.chosen.as_deref() };
    let per_section = if only.is_some() { SECTION_PAGE_LIMIT } else if kind == IssueKind::Weekly { 8 } else { 12 };
    let mut sections = section_pages(&articles, &stored, chosen, ed.limits, per_section, &sections::META);
    // 구독 채널 지면: 종류별, 채널 하나당 4개까지(논문처럼 많은 곳이 지면을 덮지 않게)
    for k in [ItemKind::Video, ItemKind::Release, ItemKind::Paper, ItemKind::Podcast, ItemKind::Post] {
        let mut per: HashMap<String, usize> = HashMap::new();
        let keys: Vec<String> = ranked
            .iter()
            .filter(|r| r.0.item.item_kind() == k)
            .filter_map(|r| {
                let n = per.entry(r.0.item.source_id.clone()).or_default();
                *n += 1;
                (*n <= 4).then(|| r.0.item.key())
            })
            .take(12)
            .collect();
        if !keys.is_empty() {
            sections.push(Section { category: NewsCategory::other(), keys, kind: Some(k.raw().into()), section: None });
        }
    }
    let article_count = stored.iter().filter(|s| s.item.item_kind() == ItemKind::Article).count() as i64;
    Issue { id: id.into(), kind, date: Utc::now(), from, to, cover, sections, count: article_count }
}

// 주간 표지 후보 순서: 스토리 보도 수가 많은 것부터, 같으면 점수 순(맥 Editor.makeIssue coverOrder)
fn weekly_cover_order<'a>(picked: &[&'a (StoredItem, f64)], sizes: &HashMap<String, i64>) -> Vec<&'a (StoredItem, f64)> {
    let size = |r: &(StoredItem, f64)| r.0.cluster.as_ref().and_then(|c| sizes.get(c).cloned()).unwrap_or(1);
    let mut v = picked.to_vec();
    v.sort_by(|a, b| size(b).cmp(&size(a)).then(b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal)));
    v
}

fn coverage_of(s: &StoredItem, outlets: &HashMap<String, HashMap<String, String>>, meta: &HashMap<String, SourceMeta>) -> Coverage {
    let own = || {
        let mut m = HashMap::new();
        m.insert(s.item.source_id.clone(), sections::region_of_source(&s.item.source_id, &s.item.tier, meta));
        m
    };
    let m = s.cluster.as_ref().and_then(|c| outlets.get(c).cloned()).unwrap_or_else(own);
    Coverage { kr: m.values().filter(|r| *r == "kr").count() as i64, intl: m.values().filter(|r| *r != "kr").count() as i64 }
}

// 분야 지면 한 장에 싣는 기사 수(맥 perSection 40)
pub const SECTION_PAGE_LIMIT: usize = 40;

// 분야 지면: 주요 뉴스(국내 n곳·해외 n곳 넘게 보도된 소식) → 고른 분야 → 나머지 분야 → 그 밖의 소식(G-10).
// 기사는 한 지면에만(고른 분야에 걸린 칩이 있으면 그 분야, 없으면 대표 분야).
pub fn section_pages(
    articles: &[StoredItem],
    stored: &[StoredItem],
    chosen: Option<&[String]>,
    limits: PolicyLimits,
    per_section: usize,
    meta: &HashMap<String, SourceMeta>,
) -> Vec<Section> {
    let picks: Vec<String> = chosen.map(|c| c.to_vec()).unwrap_or_else(|| sections::ALL.iter().map(|s| s.id.clone()).collect());
    // 스토리마다 국내·해외 출처 수(이 호의 기간 안에서)
    let mut outlets: HashMap<String, HashMap<String, String>> = HashMap::new();
    for s in stored {
        if let Some(c) = &s.cluster {
            outlets.entry(c.clone()).or_default().insert(s.item.source_id.clone(), sections::region_of_source(&s.item.source_id, &s.item.tier, meta));
        }
    }
    let mut used: HashSet<String> = HashSet::new();
    let mut pages: Vec<Section> = vec![];
    if picks.iter().any(|p| p == sections::TOP) {
        let keys: Vec<String> = articles.iter().filter(|a| crosses(coverage_of(a, &outlets, meta), limits)).map(|a| a.item.key()).take(8).collect();
        if !keys.is_empty() {
            used.extend(keys.iter().cloned());
            pages.push(Section { category: NewsCategory::other(), keys, kind: None, section: Some(sections::TOP.into()) });
        }
    }
    let mut by_section: HashMap<String, Vec<String>> = HashMap::new();
    let mut order_seen: Vec<String> = vec![];
    for a in articles.iter().filter(|a| !used.contains(&a.item.key())) {
        let p = sections::place(&a.item, meta, Some(&resources::AI_REGEX));
        let home = p.chips.iter().find(|c| picks.contains(c)).cloned().unwrap_or(p.primary);
        if !by_section.contains_key(&home) {
            order_seen.push(home.clone());
        }
        by_section.entry(home).or_default().push(a.item.key());
    }
    let mut leftovers: Vec<String> = vec![];
    let order: Vec<String> = sections::ALL.iter().map(|s| s.id.clone()).filter(|s| s != sections::TOP).collect();
    let ordered: Vec<String> = order.iter().filter(|s| picks.contains(s)).chain(order.iter().filter(|s| !picks.contains(s))).cloned().collect();
    for id in ordered {
        let Some(keys) = by_section.remove(&id) else { continue };
        // 고르지 않은 분야에서 한 건뿐이면 지면이 휑하므로 '그 밖의 소식'으로
        if keys.len() >= 2 || picks.contains(&id) {
            pages.push(Section { category: NewsCategory::other(), keys: keys.into_iter().take(per_section).collect(), kind: None, section: Some(id) });
        } else {
            leftovers.extend(keys);
        }
    }
    for id in order_seen {
        if let Some(keys) = by_section.remove(&id) {
            leftovers.extend(keys);
        }
    }
    if !leftovers.is_empty() {
        pages.push(Section { category: NewsCategory::other(), keys: leftovers.into_iter().take(per_section).collect(), kind: None, section: None });
    }
    pages
}

// 스토리 보도를 해외·국내로 나눔(나란히 보기, G-12)
pub fn split_by_region(items: &[NewsItem], meta: &HashMap<String, SourceMeta>) -> (Vec<NewsItem>, Vec<NewsItem>) {
    items.iter().cloned().partition(|i| sections::region_of_source(&i.source_id, &i.tier, meta) != "kr")
}

// 같은 소식을 다룬 출처 수(국내·해외). 스토리에 묶이지 않았으면 자기 하나.
pub fn region_coverage(db: &Database, it: &NewsItem, filter: &crate::source_filter::SourceFilter) -> Coverage {
    let meta = &*sections::META;
    let mut regions: HashMap<String, String> = HashMap::new();
    regions.insert(it.source_id.clone(), sections::region_of_source(&it.source_id, &it.tier, meta));
    if let Some(c) = db.cluster_of(&it.key()) {
        for s in db.items_in_cluster(&c) {
            if filter.shows(&s.item.source_id) {
                regions.insert(s.item.source_id.clone(), sections::region_of_source(&s.item.source_id, &s.item.tier, meta));
            }
        }
    }
    Coverage { kr: regions.values().filter(|r| *r == "kr").count() as i64, intl: regions.values().filter(|r| *r != "kr").count() as i64 }
}

pub fn start_of_day(d: DateTime<Utc>) -> DateTime<Utc> {
    let l = d.with_timezone(&Local).date_naive();
    local_midnight(l)
}

pub fn local_midnight(day: NaiveDate) -> DateTime<Utc> {
    let n = day.and_hms_opt(0, 0, 0).unwrap();
    Local.from_local_datetime(&n).earliest().map(|d| d.with_timezone(&Utc)).unwrap_or_else(|| Utc.from_utc_datetime(&n))
}

// 한국 달력처럼 일요일에 시작하는 주
pub fn week_start(d: DateTime<Utc>) -> DateTime<Utc> {
    let l = d.with_timezone(&Local).date_naive();
    let back = l.weekday().num_days_from_sunday() as i64;
    local_midnight(l - Duration::days(back))
}

pub fn day_id(d: DateTime<Utc>) -> String {
    d.with_timezone(&Local).format("%Y-%m-%d").to_string()
}

pub fn week_id(d: DateTime<Utc>) -> String {
    let w = d.with_timezone(&Local).date_naive().iso_week();
    format!("{:04}-W{:02}", w.year(), w.week())
}

// 오늘 호(전날 18시~지금)·이번 주 호(달력 한 주)
pub fn live_daily(db: &Database, interest: &Editorial) -> Issue {
    let now = Utc::now();
    let start = start_of_day(now);
    make_issue(db, IssueKind::Daily, start - Duration::hours(6), now + Duration::seconds(60), "live-daily", interest)
}

// 분야 지면(옆 목록의 분야, M-25): 오늘 호 기간의 그 분야 칩이 달린 기사만으로 엮은 지면(표지·건수도 그 분야 기준)
pub fn live_section(db: &Database, interest: &Editorial, id: &str) -> Issue {
    let now = Utc::now();
    let start = start_of_day(now);
    make_issue_in(db, IssueKind::Daily, start - Duration::hours(6), now + Duration::seconds(60), &format!("live-section-{id}"), interest, Some(id))
}

// 이번 주: 달력 한 주의 시작(일요일 0시)부터 지금까지(지난 주간과 이어짐 — 예전엔 '지금부터 7일 전'이라 지난 주간과 날이 겹쳤다)
pub fn live_weekly(db: &Database, interest: &Editorial) -> Issue {
    let now = Utc::now();
    make_issue(db, IssueKind::Weekly, week_range(now).0, now + Duration::seconds(60), "live-weekly", interest)
}

// 하루가 지나면 그날 호를, 주가 지나면 그 주 호를 발행해 지난 호에 남긴다.
// 빈 날은 최근 DUE_DAYS 일까지 메운다(매거진 채우기로 넣은 지난 기사도 그날 호가 생기게 — 예전엔 1~3일 전만이라 4일 넘은 날은 호가 없었다).
// 이미 있는 호는 건너뛰고, 4일 넘은 날은 기사 수만 먼저 세어 없으면 엮지 않는다(확인마다 14일을 다시 엮지 않게)
pub const DUE_DAYS: i64 = 14;
pub fn publish_due(db: &Database, interest: &Editorial, now: DateTime<Utc>) -> Vec<Issue> {
    let local_now = now.with_timezone(&Local);
    let today = local_now.date_naive();
    // 일간 호의 기간은 '오늘 호'와 같게: 전날 18시 ~ 그날 18시. 어제 호는 오늘 정오까지는 새 기사가 오면 다시 엮는다.
    for back in (1..=DUE_DAYS).rev() {
        let day = today - Duration::days(back);
        let id = format!("daily-{}", day.format("%Y-%m-%d"));
        let refresh = back == 1 && local_now.hour() < 12;
        if db.has_issue(&id) && !refresh {
            continue;
        }
        let from = local_midnight(day) - Duration::hours(6);
        let to = local_midnight(day) + Duration::hours(18);
        if back > 3 && db.article_count(from, to) == 0 {
            continue;
        }
        let issue = make_issue(db, IssueKind::Daily, from, to, &id, interest);
        if issue.count > 0 {
            db.save_issue(&issue);
        }
    }
    // 주간: 지난주와 지지난주(채운 기사가 지지난주에 걸칠 수 있음)
    let mut ws = week_range(local_midnight(today)).0;
    for n in 0..2 {
        let (last, last_end) = week_range(ws - Duration::hours(1));
        ws = last;
        let id = format!("weekly-{}", week_id(last));
        if db.has_issue(&id) || (n > 0 && db.article_count(last, last_end) == 0) {
            continue;
        }
        let issue = make_issue(db, IssueKind::Weekly, last, last_end, &id, interest);
        if issue.count > 0 {
            db.save_issue(&issue);
        }
    }
    // 분야 개편 전에 엮은 호는 그 기간 기사로 지금 규칙(분야 지면)에 맞춰 다시 엮는다(기사가 지워졌으면 그대로 둠)
    for old in db.issues(120).into_iter().filter(needs_rebuild) {
        let again = make_issue(db, old.kind, old.from, old.to, &old.id, interest);
        if again.count > 0 {
            db.save_issue(&again);
        }
    }
    db.prune(crate::database::KEEP_ITEMS, interest.archive_years, now, &crate::sections::primary);
    archive_order(db.issues(120))
}

// 대표 기사와 같은 소식인 스토리(앞에 있는 것 = 최근에 커진 것 먼저)
fn matching_story(it: &NewsItem, clusters: &[Cluster], reps: &HashMap<String, NewsItem>) -> Option<usize> {
    clusters.iter().position(|c| reps.get(&c.id).map(|r| story_match::same(it, r)).unwrap_or(false))
}

fn grow(db: &Database, c: &mut Cluster, it: &NewsItem, when: DateTime<Utc>) {
    c.size += 1;
    c.last = c.last.max(when);
    c.first = c.first.min(when);
    if it.tier == "lab" {
        c.title = it.display_title().to_string(); // 공식 발표 제목을 스토리 이름으로
    }
    db.save_cluster(c);
}

fn new_story(it: &NewsItem, when: DateTime<Utc>) -> Cluster {
    Cluster {
        id: uuid::Uuid::new_v4().to_string().to_uppercase(),
        title: it.display_title().to_string(),
        tokens: story_match::tokens(&it.title),
        first: when,
        last: when,
        size: 1,
    }
}

// 기사 하나를 스토리에 넣는다: 대표 기사와 같은 소식이면 그 스토리에, 아니면 새 스토리. (스토리 id, 기존 스토리에 붙었는지)
fn assign(db: &Database, it: &NewsItem, when: DateTime<Utc>, clusters: &mut Vec<Cluster>, reps: &mut HashMap<String, NewsItem>) -> (String, bool) {
    if let Some(i) = matching_story(it, clusters, reps) {
        grow(db, &mut clusters[i], it, when);
        return (clusters[i].id.clone(), true);
    }
    let c = new_story(it, when);
    db.save_cluster(&c);
    reps.insert(c.id.clone(), it.clone());
    let id = c.id.clone();
    clusters.push(c);
    (id, false)
}

// 새로 들어온 기사 전부(같은 소식으로 묶여 알림에서 빠진 것도 포함)를 받아 스토리로 묶어 넣는다.
// 돌려주는 것: 팔로우한 스토리에 새로 붙은 보도(스토리, 기사). 못 넣은 기사는 버린다(처음 옮기기 등) — 확인은 ingest_retrying
pub fn ingest(db: &Database, items: &[NewsItem], followed: &[String]) -> Vec<(Cluster, NewsItem)> {
    ingest_retrying(db, &mut Vec::new(), items, followed)
}

// DB 에 넣지 못한 기사(디스크 가득·오래 잠김)를 끝없이 쌓지 않는 상한(맥 Editor.retryLimit)
pub const RETRY_LIMIT: usize = 3000;

// 못 넣은 기사를 앱을 껐다 켜도 남게 두는 파일(자료 폴더, 맥과 같음): NewsItem 배열 JSON, RETRY_LIMIT 건까지
pub const RETRY_FILE: &str = "ingest-retry.json";

// 읽을 파일 크기 상한(RETRY_LIMIT 건이면 수 MB — 넘으면 앱이 쓴 파일이 아니다)
pub const RETRY_FILE_MAX: u64 = 64 << 20;

// 없거나 깨졌거나 너무 크면 빈 것
pub fn load_retry(file: &std::path::Path) -> Vec<NewsItem> {
    if std::fs::metadata(file).map_or(true, |m| m.len() > RETRY_FILE_MAX) {
        return vec![];
    }
    let Ok(data) = std::fs::read(file) else { return vec![] };
    let mut v: Vec<NewsItem> = serde_json::from_slice(&data).unwrap_or_default();
    let cut = v.len().saturating_sub(RETRY_LIMIT);
    v.split_off(cut)
}

// 원자적으로 쓰기(임시 파일 → rename). 비면 파일을 지운다. 쓰기 실패(디스크 가득 등)면 false — 부르는 쪽은 메모리에만 둔다
pub fn save_retry(file: &std::path::Path, items: &[NewsItem]) -> bool {
    if items.is_empty() {
        return match std::fs::remove_file(file) {
            Ok(()) => true,
            Err(e) => e.kind() == std::io::ErrorKind::NotFound,
        };
    }
    let start = items.len().saturating_sub(RETRY_LIMIT);
    let Ok(json) = serde_json::to_vec(&items[start..]) else { return false };
    let tmp = file.with_extension("json.tmp");
    let ok = std::fs::write(&tmp, &json).and_then(|_| std::fs::rename(&tmp, file)).is_ok();
    if !ok {
        let _ = std::fs::remove_file(&tmp);
        log::warn!("[DB] 다시 넣을 기사 {}건을 파일에 남기지 못해 이번 실행 동안만 기억합니다", items.len());
    }
    ok
}

// 받아 넣기(맥 Editor.ingest): 앞서 못 넣은 기사(retry)를 먼저 넣고, 이번에 못 넣은 것은 retry 에 남긴다.
// 앱 상태에는 이미 '본 글'로 남아 피드에서 다시 오지 않으므로, 여기서 버리면 매거진에서 영영 빠진다.
// 한 번 못 넣으면(잠김·가득) 나머지도 못 넣는다 — 기사마다 잠금을 기다리지 않고 바로 다음으로 미룬다.
pub fn ingest_retrying(db: &Database, retry: &mut Vec<NewsItem>, fresh: &[NewsItem], followed: &[String]) -> Vec<(Cluster, NewsItem)> {
    let mut grown = vec![];
    let items: Vec<NewsItem> = std::mem::take(retry).into_iter().chain(fresh.iter().cloned()).collect();
    if items.is_empty() {
        return grown;
    }
    let mut failed: Vec<NewsItem> = vec![];
    let since = Utc::now() - Duration::days(7);
    let mut clusters: Vec<Cluster> = db.recent_clusters(since);
    // 스토리마다 대표 기사 하나(뜻 비교용)
    let mut reps: HashMap<String, NewsItem> = HashMap::new();
    for c in &clusters {
        if let Some(first) = db.items_in_cluster(&c.id).last() {
            reps.insert(c.id.clone(), first.item.clone());
        }
    }
    for it in items {
        if !failed.is_empty() {
            failed.push(it);
            continue;
        }
        let now = Utc::now();
        // 이미 있는 기사는 스토리를 다시 정하지 않는다(대표가 자기 자신이면 '같은 출처'로 보여 새 스토리가 생기던 문제)
        // 기사만 스토리로 묶는다(논문·릴리스·커뮤니티 글은 양이 많고 성격이 달라 제외)
        if db.exists(&it.key()) || (it.item_kind() != ItemKind::Article && it.item_kind() != ItemKind::Video) {
            if !db.upsert(&it, None, now) {
                failed.push(it);
            }
            continue;
        }
        let when = it.date.unwrap_or(now);
        // 기사를 먼저 넣고, 넣었을 때만 스토리를 키운다(못 넣은 기사를 다시 넣을 때 두 번 세지 않게)
        match matching_story(&it, &clusters, &reps) {
            Some(i) => {
                let cid = clusters[i].id.clone();
                if !db.upsert(&it, Some(&cid), now) {
                    failed.push(it);
                    continue;
                }
                grow(db, &mut clusters[i], &it, when);
                if followed.contains(&cid) {
                    grown.push((clusters[i].clone(), it.clone()));
                }
            }
            None => {
                let c = new_story(&it, when);
                if !db.upsert(&it, Some(&c.id), now) {
                    failed.push(it);
                    continue;
                }
                db.save_cluster(&c);
                reps.insert(c.id.clone(), it.clone());
                clusters.push(c);
            }
        }
    }
    if !failed.is_empty() {
        log::warn!("[DB] 기사 {}건을 넣지 못해 다음 받아 넣기 때 다시 넣습니다", failed.len());
    }
    let cut = failed.len().saturating_sub(RETRY_LIMIT);
    *retry = failed.split_off(cut); // 오래된 것부터 버림
    grown
}

// 같은 소식 판정 기준이 바뀌면 최근 2주 스토리를 새 기준으로 다시 묶는다(한 번만 — 버전은 prefs 에). 다시 묶은 기사 수.
pub const STORY_RULE_VERSION: i64 = 2;

pub fn recluster(db: &Database) -> usize {
    let since = Utc::now() - Duration::days(14);
    let mut items: Vec<NewsItem> = db
        .items(since, None, 5000)
        .into_iter()
        .map(|s| s.item)
        .filter(|i| i.item_kind() == ItemKind::Article || i.item_kind() == ItemKind::Video)
        .collect();
    items.sort_by(|a, b| a.date_or_past().cmp(&b.date_or_past()));
    db.reset_clusters(since);
    let mut clusters = vec![];
    let mut reps = HashMap::new();
    for it in &items {
        let (id, _) = assign(db, it, it.date.unwrap_or_else(Utc::now), &mut clusters, &mut reps);
        db.set_cluster(&it.key(), Some(&id));
    }
    log::info!("[스토리] 새 기준으로 {}건을 다시 묶음 → 여러 곳 스토리 {}개", items.len(), clusters.iter().filter(|c| c.size >= 2).count());
    items.len()
}

// 사진 없는 기사 중 아직 찾아보지 않은 것 12개. 이미 찾아본 것을 빼지 않으면 사진이 없는 최신 12건만
// 확인마다(5분) 다시 받고, 그 뒤의 기사는 영영 사진을 찾지 못했다.
pub fn to_enrich(items: Vec<StoredItem>, tried: &std::collections::HashSet<String>) -> Vec<StoredItem> {
    items.into_iter().filter(|s| s.item.image.is_none() && !s.item.link.is_empty() && !tried.contains(&s.item.key())).take(12).collect()
}

pub fn image_todo(db: &Database, tried: &std::collections::HashSet<String>) -> Vec<StoredItem> {
    to_enrich(db.items(Utc::now() - Duration::days(3), None, 300), tried)
}

// 한 호를 화면에 그릴 재료를 한 번에
pub struct Resolved {
    pub issue: Issue,
    pub cover: Option<StoredItem>,
    pub sections: Vec<(Section, Vec<NewsItem>)>,
    pub clusters: HashMap<String, String>, // key → 스토리(카드 메뉴에서 DB 를 다시 읽지 않게)
    pub regions: HashMap<String, Vec<NewsItem>>, // 스토리 → 보도들(해외·국내가 섞인 스토리만)
}

// 지난 호도 지금 보이는 출처로만 그린다(끈 출처 글은 빠지고 다시 켜면 돌아옴, S-13)
pub fn resolve(db: &Database, issue: &Issue, filter: &crate::source_filter::SourceFilter) -> Resolved {
    let keys: Vec<String> = issue.cover.iter().cloned().chain(issue.sections.iter().flat_map(|s| s.keys.clone())).collect();
    let mut map: HashMap<String, StoredItem> = HashMap::new();
    for s in db.items_by_keys(&keys) {
        map.entry(s.item.key()).or_insert(s);
    }
    let clusters: HashMap<String, String> = map.iter().filter_map(|(k, v)| v.cluster.clone().map(|c| (k.clone(), c))).collect();
    let cover = issue.cover.as_ref().and_then(|k| map.get(k).cloned()).filter(|c| filter.shows(&c.item.source_id));
    let sections = issue
        .sections
        .iter()
        .map(|s| (s.clone(), s.keys.iter().filter_map(|k| map.get(k).map(|x| x.item.clone())).filter(|i| filter.shows(&i.source_id)).collect::<Vec<_>>()))
        .filter(|(_, v)| !v.is_empty())
        .collect();
    // 여러 곳이 다룬 스토리만 보도를 꺼내 해외·국내가 섞였는지 본다
    let mut regions: HashMap<String, Vec<NewsItem>> = HashMap::new();
    let sizes = db.coverage(&clusters.keys().cloned().collect::<Vec<_>>());
    for (k, c) in &clusters {
        if sizes.get(k).cloned().unwrap_or(1) < 2 || regions.contains_key(c) {
            continue;
        }
        let items: Vec<NewsItem> = db.items_in_cluster(c).into_iter().map(|s| s.item).filter(|i| filter.shows(&i.source_id)).collect();
        let (intl, kr) = split_by_region(&items, &sections::META);
        if !intl.is_empty() && !kr.is_empty() {
            regions.insert(c.clone(), items);
        }
    }
    Resolved { issue: issue.clone(), cover, sections, clusters, regions }
}

pub fn cluster_of(db: &Database, key: &str) -> Option<String> {
    db.cluster_of(key)
}

// 스토리의 보도 중 지금 보이는 출처 것만(S-13)
pub fn story_items(db: &Database, id: &str, filter: &crate::source_filter::SourceFilter) -> Vec<NewsItem> {
    filter.visible(&db.items_in_cluster(id).into_iter().map(|s| s.item).collect::<Vec<_>>())
}

// 스토리 카드 하나: 스토리와 보이는 보도 견본(카드가 DB 를 다시 묻지 않게 — 출처마다 첫 보도 + 최근 것, 맥 Magazine.StoryCard)
#[derive(Debug, Clone)]
pub struct StoryCard {
    pub cluster: Cluster,
    pub items: Vec<NewsItem>,
    pub topic: Option<(String, Option<NewsCategory>)>, // 보도들의 분야 다수결(만들 때 미리 — 카드를 그릴 때 화면 줄기에서 분야를 가리지 않게)
}

// 스토리: 최근 2주 동안 지금 보이는 출처로만 두 곳 이상이 다룬 것(출처를 끄면 그 스토리의 보도 수도 줄어 목록에서 빠질 수 있음).
// 목록 전체를 문장 세 번(스토리 · 출처별 수 · 보도 견본)으로 — 예전엔 스토리마다 따로 물어 기록이 쌓일수록 느려졌다.
// 보도 수·출처 수는 DB 에서 세고, 분야 다수결은 견본으로(보도가 수천 건인 스토리에서 보도마다 분야를 가리던 것이 몇 초씩 걸렸다)
pub fn story_list(db: &Database, now: DateTime<Utc>, filter: &crate::source_filter::SourceFilter) -> Vec<StoryCard> {
    let since = now - Duration::days(14);
    let counts = db.story_source_counts(since);
    let mut members = db.story_members(since);
    db.recent_clusters(since)
        .into_iter()
        .filter(|c| c.size >= 2)
        .filter_map(|mut c| {
            let shown: Vec<i64> = counts.get(&c.id).map(|m| m.iter().filter(|(s, _)| filter.shows(s)).map(|(_, n)| *n).collect()).unwrap_or_default();
            if shown.len() < 2 {
                return None;
            }
            let items = filter.visible(&members.remove(&c.id).unwrap_or_default().into_iter().map(|s| s.item).collect::<Vec<_>>());
            c.size = shown.iter().sum();
            let topic = story_topic(&items, crate::sections::primary);
            Some(StoryCard { cluster: c, items, topic })
        })
        .collect()
}

pub fn stories(db: &Database, filter: &crate::source_filter::SourceFilter) -> Vec<Cluster> {
    story_list(db, Utc::now(), filter).into_iter().map(|c| c.cluster).collect()
}

// 스토리 목록 화면: 최근 24시간 안에 보도가 붙은 것(지금 커지는 스토리)과 나머지. 큰 것·최근 것이 앞
pub fn story_cards(db: &Database, now: DateTime<Utc>, filter: &crate::source_filter::SourceFilter) -> (Vec<StoryCard>, Vec<StoryCard>) {
    let score = |c: &Cluster| c.size as f64 + (24.0 - (now - c.last).num_seconds() as f64 / 3600.0).max(0.0) / 6.0;
    let mut all = story_list(db, now, filter);
    all.sort_by(|a, b| score(&b.cluster).partial_cmp(&score(&a.cluster)).unwrap_or(std::cmp::Ordering::Equal).then(b.cluster.last.cmp(&a.cluster.last)));
    let cut = now - Duration::hours(24);
    all.into_iter().partition(|c| c.cluster.last >= cut)
}

pub fn story_groups(db: &Database, now: DateTime<Utc>, filter: &crate::source_filter::SourceFilter) -> (Vec<Cluster>, Vec<Cluster>) {
    let (live, past) = story_cards(db, now, filter);
    (live.into_iter().map(|c| c.cluster).collect(), past.into_iter().map(|c| c.cluster).collect())
}

// 분야 사진 고르기용 최근 기사: 한 번 읽어 분야마다 나눈다(예전엔 분야마다 3000건씩 다시 읽음)
pub fn section_recent(db: &Database, ids: &[String], since: DateTime<Utc>) -> HashMap<String, Vec<NewsItem>> {
    let recent: Vec<NewsItem> = db.items(since, None, 3000).into_iter().map(|s| s.item).collect();
    ids.iter().map(|id| (id.clone(), recent.iter().filter(|i| i.in_section(id)).cloned().collect())).collect()
}


// MARK: 지면 규칙(옆 목록과 오른쪽 화면이 같은 기준을 쓰게 — 맥 Magazine · SidebarRuleTests)

// 기사가 너무 적은 호(앱을 막 쓰기 시작한 주 등) — 목록에 '기록 적음'으로 표시
pub const THIN_ISSUE: i64 = 5;

impl Issue {
    pub fn is_thin(&self) -> bool {
        self.count < THIN_ISSUE
    }
}

// 새로 고침 옆 '마지막 확인 n분 전'(맥 Magazine.lastCheckText 와 같은 글)
pub fn last_check_text(d: Option<DateTime<Utc>>, now: DateTime<Utc>) -> String {
    let Some(d) = d else { return "아직 확인 전".into() };
    let s = (now - d).num_seconds().max(0);
    match s {
        0..=59 => "마지막 확인 방금".into(),
        60..=3599 => format!("마지막 확인 {}분 전", s / 60),
        3600..=86399 => format!("마지막 확인 {}시간 전", s / 3600),
        _ => format!("마지막 확인 {}일 전", s / 86400),
    }
}

// 기록 적음 이유(지난 호 머리) — 그날 모인 소식이 적은 까닭(맥 Magazine.thinReason 과 같은 글)
pub fn thin_reason(issue: &Issue) -> Option<String> {
    issue.is_thin().then(|| format!("기록 적음 — 앱을 쓰기 전이거나 켠 출처가 적던 때라 모인 소식이 {}건뿐입니다", issue.count))
}

// 지난 호 목록 묶음: 이번 주 · 지난주 · 그 앞은 달별(접혀 있음). 주간 호는 그 주 묶음 맨 위(archive_order 그대로).
// 빈 날: 묶음 기간 중 첫 기록 날부터 어제까지 일간 호가 없는 날 수(앱을 쓰기 전 날은 세지 않음) — 맥 archiveGroups 와 같은 규칙
#[derive(Debug, Clone)]
pub struct ArchiveGroup {
    pub id: String,
    pub title: String,
    pub issues: Vec<Issue>,
    pub empty_days: i64,
    pub folded: bool,
}
pub fn archive_groups(issues: &[Issue], now: DateTime<Utc>) -> Vec<ArchiveGroup> {
    let (this_from, this_to) = week_range(now);
    let (last_from, last_to) = week_range(this_from - Duration::hours(1));
    let local = |d: DateTime<Utc>| d.with_timezone(&Local).date_naive();
    let today = local(now);
    let anchor = |i: &Issue| if i.kind == IssueKind::Weekly { local(i.from) } else { local(i.to - Duration::seconds(60)) };
    let days: HashSet<NaiveDate> = issues.iter().filter(|i| i.kind == IssueKind::Daily).map(anchor).collect();
    let Some(first) = days.iter().min().copied().or_else(|| issues.iter().map(anchor).min()) else { return vec![] };
    let mut groups: Vec<(ArchiveGroup, NaiveDate, NaiveDate)> = vec![];
    for i in issues {
        let d = anchor(i);
        let (id, title, from, to, folded) = if d >= local(this_from) {
            ("this".to_string(), "이번 주".to_string(), local(this_from), local(this_to), false)
        } else if d >= local(last_from) {
            ("last".to_string(), "지난주".to_string(), local(last_from), local(last_to), false)
        } else {
            let m = NaiveDate::from_ymd_opt(d.year(), d.month(), 1).unwrap();
            let next = if d.month() == 12 { NaiveDate::from_ymd_opt(d.year() + 1, 1, 1) } else { NaiveDate::from_ymd_opt(d.year(), d.month() + 1, 1) }.unwrap();
            // 달 묶음은 지난주 앞까지만(지난주와 같은 날을 두 번 세지 않게)
            (format!("m-{:04}-{:02}", d.year(), d.month()), format!("{}년 {}월", d.year(), d.month()), m, next.min(local(last_from)), true)
        };
        match groups.iter_mut().find(|g| g.0.id == id) {
            Some(g) => g.0.issues.push(i.clone()),
            None => groups.push((ArchiveGroup { id, title, issues: vec![i.clone()], empty_days: 0, folded }, from, to)),
        }
    }
    groups
        .into_iter()
        .map(|(mut g, from, to)| {
            let mut d = from.max(first);
            while d < to.min(today) {
                if !days.contains(&d) {
                    g.empty_days += 1;
                }
                d += Duration::days(1);
            }
            g
        })
        .collect()
}

// 지난 호 목록: 최신부터 호의 끝 시각 순(주간은 그 주 끝 — 토요일 호 바로 위)
pub fn archive_order(mut issues: Vec<Issue>) -> Vec<Issue> {
    issues.sort_by(|a, b| b.to.cmp(&a.to).then_with(|| (b.kind == IssueKind::Weekly).cmp(&(a.kind == IssueKind::Weekly))));
    issues
}

// 주간 범위: 달력 한 주(일요일 0시 ~ 다음 일요일 0시). 이번 주 진행 중 호와 지난 주간이 겹치지 않고 이어짐
pub fn week_range(d: DateTime<Utc>) -> (DateTime<Utc>, DateTime<Utc>) {
    let from = week_start(d);
    let next = from.with_timezone(&Local).date_naive() + Duration::days(7);
    (from, local_midnight(next))
}

// 분야 개편(분야 지면) 전에 엮은 호: 기사 지면에 분야 id 가 없고 예전 AI 분류(모델·제품…)로 나뉨 → 지금 규칙으로 다시 엮는다
pub fn needs_rebuild(issue: &Issue) -> bool {
    issue.sections.iter().any(|s| s.kind.is_none() && s.section.is_none() && !s.category.is_other())
}

// 최근 검색어: 맨 앞에 넣고 같은 것(대소문자 무시)은 하나로, 두 글자 이상, 8개까지
pub const RECENT_SEARCHES: usize = 8;
pub fn remember_search(q: &str, list: &[String]) -> Vec<String> {
    let t = q.trim();
    if t.chars().count() < 2 {
        return list.to_vec();
    }
    std::iter::once(t.to_string()).chain(list.iter().filter(|w| w.to_lowercase() != t.to_lowercase()).cloned()).take(RECENT_SEARCHES).collect()
}

// 머리 아래 숫자: 모은 소식 중 지면에 실은 수(표지 포함). 다 실었으면 한 숫자만
pub fn subtitle(total: i64, shown: i64, sections: usize, noun: &str) -> String {
    let head = if shown >= total { format!("{noun} {total}건") } else { format!("{noun} {total}건 중 {shown}건 실음") };
    if sections > 0 {
        format!("{head} · 분야 {sections}개")
    } else {
        head
    }
}

// 분야 지면 머리: "IT 소식 N건 중 M건 실음 · 출처 K곳"(실린 기사 기준)
pub fn section_subtitle(id: &str, total: i64, shown: &[NewsItem]) -> String {
    let outlets: HashSet<&str> = shown.iter().map(|i| i.source_id.as_str()).collect();
    format!("{} · 출처 {}곳", subtitle(total, shown.len() as i64, 0, &format!("{} 소식", sections::name(id))), outlets.len())
}

// 분야 지면의 AI 하위 칩: 실린 기사에 있는 하위 분류만, 분류 순서대로('기타'까지 — 칩 숫자의 합이 실린 수와 같게)
pub fn sub_chip_counts(items: &[NewsItem]) -> Vec<(NewsCategory, usize)> {
    let mut counts: HashMap<NewsCategory, usize> = HashMap::new();
    for it in items {
        *counts.entry(it.category()).or_default() += 1;
    }
    NewsCategory::all().into_iter().filter_map(|c| counts.get(&c).map(|n| (c, *n))).collect()
}

// 스토리의 분야: 묶인 보도들의 대표 분야 다수결(같으면 분야 순서 앞). AI 면 AI 안 하위 분류도 다수결
pub fn story_topic(items: &[NewsItem], place: impl Fn(&NewsItem) -> String) -> Option<(String, Option<NewsCategory>)> {
    if items.is_empty() {
        return None;
    }
    let secs: Vec<String> = items.iter().map(&place).collect();
    let mut votes: HashMap<&str, usize> = HashMap::new();
    for s in &secs {
        *votes.entry(s.as_str()).or_default() += 1;
    }
    let sec = votes.iter().max_by(|a, b| a.1.cmp(b.1).then_with(|| sections::order(b.0).cmp(&sections::order(a.0)))).map(|(k, _)| k.to_string())?;
    if sec != sections::AI {
        return Some((sec, None));
    }
    let mut cats: HashMap<NewsCategory, usize> = HashMap::new();
    for (it, s) in items.iter().zip(&secs) {
        if s == sections::AI {
            *cats.entry(it.category()).or_default() += 1;
        }
    }
    let cat = cats.into_iter().max_by(|a, b| a.1.cmp(&b.1).then_with(|| b.0.sort_order().cmp(&a.0.sort_order()))).map(|(c, _)| c);
    Some((sec, cat))
}

// 화면에 보이는 스토리 분야(이름·아이콘·색): AI 면 'AI·하위 분류'
pub fn story_topic_label(topic: &(String, Option<NewsCategory>), dark: bool) -> (String, &'static str, String) {
    match topic.1 {
        Some(c) => (format!("AI·{}", c.label()), c.icon(), c.color(dark).to_string()),
        None => {
            let s = sections::by_id(&topic.0);
            (sections::name(&topic.0), s.map(|s| s.icon()).unwrap_or("view-app-grid-symbolic"), s.map(|s| s.color.clone()).unwrap_or_else(|| "#8E8E93".into()))
        }
    }
}

// 스토리의 새 보도 수: 지금 보도 수 − 마지막으로 본 보도 수(본 적 없으면 0)
pub fn unseen_reports(size: i64, seen: Option<i64>) -> i64 {
    (size - seen.unwrap_or(size)).max(0)
}

// MARK: 이번 주 모은 문장(M-27, 맥 UI/WeeklyQuotes.swift)
// 일요일 저녁(17시부터)에만 스크랩북 첫머리에
pub fn is_sunday_evening<Tz: TimeZone>(d: &DateTime<Tz>) -> bool {
    if crate::test_hooks::var("DROPCAP_TEST_WEEKLY").is_some() {
        return true; // 시험용
    }
    d.weekday() == chrono::Weekday::Sun && d.hour() >= 17
}

// 지난 7일 동안 문단으로 스크랩한 글: 최근 것부터, 같은 문장은 한 번만
pub fn pick_weekly_quotes(scraps: &[crate::scrapbook::Scrap], now: DateTime<Utc>, limit: usize) -> Vec<crate::scrapbook::Scrap> {
    let mut seen = HashSet::new();
    let mut v: Vec<crate::scrapbook::Scrap> = scraps
        .iter()
        .filter(|s| {
            let Some(q) = s.quote.as_ref().filter(|q| !q.is_empty()) else { return false };
            (now - s.created).num_seconds() < 7 * 86400 && s.created <= now + Duration::seconds(60) && seen.insert(q.clone())
        })
        .cloned()
        .collect();
    v.sort_by(|a, b| b.created.cmp(&a.created));
    v.truncate(limit);
    v
}

