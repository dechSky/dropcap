// 지난 기사 보관함(맥 Core/Archive.swift): 기사 기록(items)은 최근 2만 건만 남기고, 그보다 오래된 기사는 가벼운 보관 표(archive)로 옮긴다
// (날짜·제목·한국어 제목·링크·출처·분야·스토리 — 사진·요약·본문 없음). 보관 표는 설정의 '보관 기간'이 지난 달부터 지운다.
// 보관함 화면·검색은 아직 items 에 있는 최근 기사와 보관 표를 같은 꼴(ArchivedItem)로 합쳐 보여 준다.
use crate::database::Database;
use crate::magazine::{local_midnight, start_of_day, week_range};
use crate::models::NewsItem;
use chrono::{DateTime, Datelike, Duration, Local, NaiveDate, Utc};
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};

#[derive(Debug, Clone, PartialEq)]
pub struct ArchivedItem {
    pub date: DateTime<Utc>,
    pub title: String,
    pub title_ko: Option<String>,
    pub link: String,
    pub source: String,        // 출처 이름(옮긴 뒤 구독을 끊어도 보이게 이름으로 둔다)
    pub source_id: Option<String>, // 출처 id(숨긴·끈 출처를 거르는 데 — 예전 줄은 None)
    pub section: String,       // 분야 id(sections)
    pub story: Option<String>, // 여러 곳이 다룬 스토리 id(한 곳뿐이면 None)
}

impl ArchivedItem {
    pub fn id(&self) -> String {
        format!("{}|{}", self.link, self.date.timestamp_millis())
    }
    pub fn display_title(&self) -> &str {
        self.title_ko.as_deref().unwrap_or(&self.title)
    }
    // 읽기 창으로 열 때 쓰는 기사(본문은 링크에서 다시 받는다)
    pub fn news_item(&self) -> NewsItem {
        let mut it = NewsItem::new(&self.link, &self.title, &self.link, "archive", &self.source, "");
        it.title_ko = self.title_ko.clone();
        it.date = Some(self.date);
        it
    }
}

// 보관함·오래된 기사 검색에 보일 출처(숨긴·끈 출처의 글은 다시 나타나지 않게 — 매거진 검색과 같은 출처 거르기).
// 출처 id 가 없는 예전 줄은 숨긴 출처의 이름으로 거른다(그런 줄은 source_id 칸을 더하기 전 맥 개발 판에서만 생겨 끈·해지한 출처까지는 거르지 않는다 —
// 이름→id 로 채우려면 시작 때 표 전체를 훑어야 해서 두었다)
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Visibility {
    pub hidden_ids: Vec<String>,
    pub hidden_names: Vec<String>,   // 숨긴 출처의 이름
    pub active: Option<Vec<String>>, // 켜진 출처 id(None 이면 켜짐 여부를 따지지 않음)
}

impl Visibility {
    pub fn new(filter: &crate::source_filter::SourceFilter, hidden_names: Vec<String>) -> Visibility {
        let mut hidden_ids: Vec<String> = filter.hidden.iter().cloned().collect();
        hidden_ids.sort();
        let active = filter.active.as_ref().map(|a| {
            let mut v: Vec<String> = a.iter().cloned().collect();
            v.sort();
            v
        });
        Visibility { hidden_ids, hidden_names, active }
    }

    // items 표의 최근 기사(출처 id 가 늘 있음)
    pub fn shows(&self, source_id: &str) -> bool {
        !self.hidden_ids.iter().any(|h| h == source_id) && self.active.as_ref().map(|a| a.iter().any(|x| x == source_id)).unwrap_or(true)
    }

    // 보관 표 질의에 붙이는 조건과 그 값 넷(JSON 문자열 배열: 숨긴 이름 · 숨긴 id · 켜진 id 또는 NULL 두 번)
    pub const SQL: &'static str = " AND (CASE WHEN source_id IS NULL THEN source NOT IN (SELECT value FROM json_each(?)) \
        ELSE (source_id NOT IN (SELECT value FROM json_each(?)) AND (? IS NULL OR source_id IN (SELECT value FROM json_each(?)))) END)";

    pub fn sql_args(&self) -> [Option<String>; 4] {
        let j = |v: &Vec<String>| serde_json::to_string(v).unwrap_or_else(|_| "[]".into());
        let active = self.active.as_ref().map(j);
        [Some(j(&self.hidden_names)), Some(j(&self.hidden_ids)), active.clone(), active]
    }
}

// 보관 표가 이 수를 넘으면 보관 기간과 상관없이 가장 오래된 것부터 지운다(끝없이 둘 때 디스크·검색이 끝없이 커지지 않게)
pub const MAX_ROWS: i64 = 5_000_000;
// 검색어는 앞 200 글자만
pub const MAX_QUERY: usize = 200;
// 정리 때 제목·링크를 읽지 못해 옮기지 못한 줄: 최신 이만큼까지만, 이 기간이 지나면 지운다
pub const BROKEN_KEEP: usize = 1000;
pub const BROKEN_LIFE_SECS: i64 = 30 * 24 * 3600;

// 설정 '보관 기간'(년). 0 은 끝없이
pub const DEFAULT_YEARS: i64 = 2;
pub const CHOICES: [i64; 4] = [1, 2, 5, 0];

pub fn label(years: i64) -> String {
    if years == 0 {
        "끝없이".into()
    } else {
        format!("{years}년")
    }
}

// 설정 '보관 기간' 아래 안내(세 판 같은 글 — 맥 Archive.settingsNote)
pub fn settings_note(years: i64) -> String {
    const HEAD: &str = "최근 기사 2만 건보다 오래된 기사는 날짜·제목·링크·출처만 남겨 매거진 '보관함'에 옮깁니다(1년에 약 120MB).";
    if years == 0 {
        format!("{HEAD} 끝없이 두면 해마다 약 120MB씩 늘고(500만 건에서 가장 오래된 것부터 지움) 검색도 조금씩 느려집니다.")
    } else {
        format!("{HEAD} 보관 기간이 지나면 가장 오래된 달부터 지웁니다.")
    }
}

pub fn clamp_years(y: i64) -> i64 {
    if CHOICES.contains(&y) {
        y
    } else {
        DEFAULT_YEARS
    }
}

fn first_of_month(y: i32, m: u32) -> DateTime<Utc> {
    local_midnight(NaiveDate::from_ymd_opt(y, m, 1).unwrap_or(NaiveDate::MIN))
}

// (y, m) 에서 n 달 뒤의 첫날
fn add_months(y: i32, m: u32, n: i64) -> DateTime<Utc> {
    let idx = y as i64 * 12 + (m as i64 - 1) + n;
    first_of_month(idx.div_euclid(12) as i32, (idx.rem_euclid(12) + 1) as u32)
}

// 이 때보다 이른 보관 기사는 지운다: years 년 전이 든 달의 첫날(달 단위로 — 오래된 달부터 통째로). 0 이면 None(지우지 않음)
pub fn cutoff(years: i64, now: DateTime<Utc>) -> Option<DateTime<Utc>> {
    if years <= 0 {
        return None;
    }
    let l = now.with_timezone(&Local).date_naive();
    Some(first_of_month(l.year() - years as i32, l.month()))
}

// MARK: 기간
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Period {
    Day,
    Week,
    Month,
    Year,
}

impl Period {
    pub const ALL: [Period; 4] = [Period::Day, Period::Week, Period::Month, Period::Year];
    pub fn raw(self) -> &'static str {
        match self {
            Period::Day => "day",
            Period::Week => "week",
            Period::Month => "month",
            Period::Year => "year",
        }
    }
    // 모르는 값은 월(맥 기본값과 같음)
    pub fn from_raw(s: &str) -> Period {
        Period::ALL.into_iter().find(|p| p.raw() == s).unwrap_or(Period::Month)
    }
    pub fn label(self) -> &'static str {
        match self {
            Period::Day => "일",
            Period::Week => "주",
            Period::Month => "월",
            Period::Year => "연",
        }
    }
    // 날짜별 건수 막대를 목록 앞에 보이는 기간
    pub fn shows_bars(self) -> bool {
        matches!(self, Period::Month | Period::Year)
    }
}

// anchor 가 든 기간 [from, to)
pub fn range(p: Period, anchor: DateTime<Utc>) -> (DateTime<Utc>, DateTime<Utc>) {
    let l = anchor.with_timezone(&Local).date_naive();
    match p {
        Period::Day => (start_of_day(anchor), local_midnight(l + Duration::days(1))),
        Period::Week => week_range(anchor),
        Period::Month => (first_of_month(l.year(), l.month()), add_months(l.year(), l.month(), 1)),
        Period::Year => (first_of_month(l.year(), 1), first_of_month(l.year() + 1, 1)),
    }
}

// ◀ ▶: 한 기간 앞뒤로
pub fn shift(p: Period, anchor: DateTime<Utc>, n: i64) -> DateTime<Utc> {
    let from = range(p, anchor).0;
    let l = from.with_timezone(&Local).date_naive();
    match p {
        Period::Day => local_midnight(l + Duration::days(n)),
        Period::Week => local_midnight(l + Duration::days(7 * n)),
        Period::Month => add_months(l.year(), l.month(), n),
        Period::Year => first_of_month(l.year() + n as i32, 1),
    }
}

const WEEKDAYS: [&str; 7] = ["일", "월", "화", "수", "목", "금", "토"];

// 머리 이름: 2026년 10월 19일(월) · 2026년 10월 18일 – 10월 24일 · 2026년 10월 · 2026년
pub fn title(p: Period, anchor: DateTime<Utc>) -> String {
    let (from, to) = range(p, anchor);
    let f = from.with_timezone(&Local).date_naive();
    let (y, m, d) = (f.year(), f.month(), f.day());
    match p {
        Period::Day => format!("{y}년 {m}월 {d}일({})", WEEKDAYS[f.weekday().num_days_from_sunday() as usize]),
        Period::Week => {
            let last = (to - Duration::seconds(1)).with_timezone(&Local).date_naive();
            format!("{y}년 {m}월 {d}일 – {}월 {}일", last.month(), last.day())
        }
        Period::Month => format!("{y}년 {m}월"),
        Period::Year => format!("{y}년"),
    }
}

// 날 열쇠(이 컴퓨터의 날 'YYYY-MM-DD' — SQLite date(...,'localtime') 와 같은 꼴)
pub fn day_key(d: DateTime<Utc>) -> String {
    d.with_timezone(&Local).format("%Y-%m-%d").to_string()
}

// 기간의 날들(막대 순서)
pub fn days(from: DateTime<Utc>, to: DateTime<Utc>) -> Vec<DateTime<Utc>> {
    let mut out = vec![];
    let mut l = from.with_timezone(&Local).date_naive();
    let mut d = local_midnight(l);
    while d < to && out.len() < 400 {
        out.push(d);
        l += Duration::days(1);
        d = local_midnight(l);
    }
    out
}

// 보관함 한 기간의 화면 재료
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Page {
    pub items: Vec<ArchivedItem>,          // 최신순, 앞 limit 건
    pub more: bool,                        // 더 있음(더 보기)
    pub day_counts: HashMap<String, i64>,  // 날 열쇠 → 건수(거른 뒤)
    pub sections: HashMap<String, i64>,    // 분야 → 건수(거르기 전 — 메뉴)
    pub sources: HashMap<String, i64>,     // 출처 → 건수(거르기 전 — 메뉴)
    pub total: i64,                        // 거른 뒤 전체 건수
}

// 최근 기사와 보관 기사 합치기: 같은 링크는 한 번(최근 쪽 — 한 출처의 두 피드에 같은 기사가 실린 것도), 최신순
pub fn merge(recent: &[ArchivedItem], archived: &[ArchivedItem]) -> Vec<ArchivedItem> {
    let mut seen = HashSet::new();
    let mut out: Vec<ArchivedItem> = recent.iter().chain(archived.iter()).filter(|a| seen.insert(a.link.clone())).cloned().collect();
    out.sort_by(|a, b| b.date.cmp(&a.date));
    out
}

// 분야·출처로 거르기(None 이면 모두)
pub fn filter(items: &[ArchivedItem], section: Option<&str>, source: Option<&str>) -> Vec<ArchivedItem> {
    items
        .iter()
        .filter(|a| section.map(|s| a.section == s).unwrap_or(true) && source.map(|s| a.source == s).unwrap_or(true))
        .cloned()
        .collect()
}

// 날짜별 건수 더하기
pub fn day_counts(items: &[ArchivedItem]) -> HashMap<String, i64> {
    let mut out = HashMap::new();
    for i in items {
        *out.entry(day_key(i.date)).or_insert(0) += 1;
    }
    out
}

// 보관함·오래된 기사 검색 읽기(화면 줄기 밖 — 부르는 쪽이 뒤에서 돌린다)
pub struct ArchiveReader {
    db: Arc<Database>,
    // 최근 기사의 분야(key → 분야): 기간을 넘길 때마다 수만 건을 다시 가르지 않게 기억해 둔다
    memo: Mutex<HashMap<String, String>>,
}

impl ArchiveReader {
    pub fn new(db: Arc<Database>) -> ArchiveReader {
        ArchiveReader { db, memo: Mutex::new(HashMap::new()) }
    }

    // 보관 표 검색(최신순 limit 건씩 — 더 보기는 offset)
    pub fn search(&self, q: &str, limit: i64, offset: i64, vis: &Visibility) -> Vec<ArchivedItem> {
        self.db.search_archive(q, limit, offset, vis)
    }

    // 보관함 한 기간: 아직 items 에 있는 최근 기사(가벼운 꼴) + 보관 표(분야·출처로 거름). limit 은 보관 표에서 꺼낼 수
    pub fn period(&self, from: DateTime<Utc>, to: DateTime<Utc>, section: Option<&str>, source: Option<&str>, limit: usize, vis: &Visibility) -> Page {
        let mut memo = {
            let mut m = self.memo.lock().unwrap();
            if m.len() > 60000 {
                m.clear();
            }
            std::mem::take(&mut *m)
        };
        let recent = self.db.recent_light(from, to, vis, &mut |it: &NewsItem| {
            let k = it.key();
            if let Some(s) = memo.get(&k) {
                return s.clone();
            }
            let s = crate::sections::primary(it);
            memo.insert(k, s.clone());
            s
        });
        {
            let mut m = self.memo.lock().unwrap();
            m.extend(memo);
        }
        let shown = filter(&recent, section, source);
        let mut counts = day_counts(&shown);
        for (d, n) in self.db.archive_day_counts(from, to, section, source, vis) {
            *counts.entry(d).or_insert(0) += n;
        }
        let (mut sections, mut sources) = self.db.archive_facets(from, to, vis);
        for r in &recent {
            *sections.entry(r.section.clone()).or_insert(0) += 1;
            *sources.entry(r.source.clone()).or_insert(0) += 1;
        }
        // 보관 기사는 최근 기사보다 이르므로 limit+1 건만 꺼내 합쳐도 앞 limit 건이 맞다(+1 은 '더 보기'가 있는지)
        let older = if shown.len() > limit { vec![] } else { self.db.archived(from, to, section, source, (limit - shown.len() + 1) as i64, 0, vis) };
        let mut items = merge(&shown, &older);
        let more = items.len() > limit;
        items.truncate(limit);
        let total = counts.values().sum();
        Page { items, more, day_counts: counts, sections, sources, total }
    }

    pub fn earliest_record(&self) -> Option<DateTime<Utc>> {
        self.db.earliest_record()
    }
}
