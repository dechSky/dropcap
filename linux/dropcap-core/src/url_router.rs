// dropcap:// 주소와 명령줄(맥 Integrations/URLRouter.swift · Intents.swift).
// - dropcap://open?key=<기사 key> → 그 기사 읽기 창, dropcap://magazine → 매거진, dropcap://save?url=… → 확인 창 뒤 나중에 읽기
// - 맥 단축어(App Intents) 대신 명령줄: dropcap --save <주소> · --magazine · --latest [개수] [--section 분야] [--json]
//   --save·--magazine 은 dropcap:// 주소로 바꿔 이미 떠 있는 Dropcap 에 넘긴다(GApplication open). --latest 는 창 없이 출력만.
use crate::category::NewsCategory;
use crate::models::{resources, NewsItem};
use crate::save_link::{self, percent_encode};
use crate::store::AppState;

pub const SCHEME: &str = "dropcap";
pub const MAGAZINE: &str = "dropcap://magazine";

#[derive(Debug, Clone, PartialEq)]
pub enum Route {
    Open(String),                  // 기사 key
    Magazine,
    Save(String, Option<String>),  // 주소, 제목
    BadSave,                       // save 이지만 주소가 공개 http(s) 가 아님
    Unknown,
}

fn action(link: &str) -> Option<String> {
    let (scheme, rest) = link.split_once(':')?;
    if !scheme.eq_ignore_ascii_case(SCHEME) {
        return None;
    }
    Some(rest.split(['?', '#']).next().unwrap_or("").trim_matches('/').to_lowercase())
}

pub fn route(link: &str) -> Route {
    match action(link).as_deref() {
        Some("open") => key(link).map(Route::Open).unwrap_or(Route::Unknown),
        Some("magazine") => Route::Magazine,
        Some("save") => match save_link::parse_scheme(link) {
            Some((u, t)) => Route::Save(u, t),
            None => Route::BadSave,
        },
        _ => Route::Unknown,
    }
}

// dropcap://open?key=... (기사 key 는 '출처|id' 라 특수 글자를 모두 감싼다)
pub fn open_link(key: &str) -> String {
    format!("{SCHEME}://open?key={}", percent_encode(key))
}

pub fn key(link: &str) -> Option<String> {
    if action(link).as_deref() != Some("open") {
        return None;
    }
    save_link::query_items(link).into_iter().find(|(k, _)| k == "key").map(|(_, v)| v).filter(|v| !v.is_empty())
}

pub fn save_link(url: &str) -> String {
    format!("{SCHEME}://save?url={}", percent_encode(url))
}

// MARK: 명령줄

#[derive(Debug, Clone, PartialEq)]
pub enum Cli {
    Run { uris: Vec<String> },                                   // 앱 실행(넘길 dropcap:// 주소들)
    Latest { section: Option<String>, count: usize, json: bool }, // 최신 소식 출력
    Help,
    Error(String),
}

pub const HELP: &str = "사용법: dropcap [선택]\n\
  --background             창 없이 시작(로그인 자동 실행)\n\
  --save <주소>             주소를 나중에 읽기로 저장(확인 창)\n\
  --magazine               매거진 열기\n\
  --latest [개수]           최신 소식 출력(기본 5, 최대 20)\n\
     --section <분야>       그 분야만(예: 연구, 모델, 투자)\n\
     --json                JSON 으로\n\
  dropcap://…              dropcap 주소 열기(open?key= · magazine · save?url=)\n";

pub fn cli(args: &[String]) -> Cli {
    let mut uris = vec![];
    let mut latest: Option<usize> = None;
    let (mut section, mut json) = (None, false);
    let mut i = 1;
    while i < args.len() {
        let a = args[i].as_str();
        match a {
            "-h" | "--help" => return Cli::Help,
            "--save" => {
                let Some(u) = args.get(i + 1) else { return Cli::Error("--save 뒤에 주소를 넣어 주세요".into()) };
                if save_link::normalize(u).is_none() {
                    return Cli::Error(format!("'{u}' 는 저장할 수 있는 공개 웹 주소가 아닙니다."));
                }
                uris.push(save_link(u));
                i += 1;
            }
            "--magazine" => uris.push(MAGAZINE.into()),
            "--latest" => {
                let n = args.get(i + 1).and_then(|s| s.parse::<i64>().ok());
                if n.is_some() {
                    i += 1;
                }
                latest = Some(count(n));
            }
            "--section" => {
                section = args.get(i + 1).cloned();
                i += 1;
            }
            "--json" => json = true,
            _ if action(a).is_some() => uris.push(a.to_string()),
            _ => {} // --background 등은 앱이 따로 읽는다
        }
        i += 1;
    }
    match latest {
        Some(count) => Cli::Latest { section, count, json },
        None => Cli::Run { uris },
    }
}

// MARK: 최신 소식(맥 IntentLogic)
pub const MAX_COUNT: usize = 20;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum SectionChoice {
    All,
    Only(NewsCategory),
    Unknown,
}

pub fn section_names() -> Vec<&'static str> {
    NewsCategory::all().into_iter().map(|c| c.label()).collect()
}

// 분야: 비우면 전체. 이름(모델·제품) · 영문 값(model) · 앞부분(모델) · 가운뎃점 뒤 낱말(기업)으로 찾는다
pub fn section(text: Option<&str>) -> SectionChoice {
    let t = text.map(|s| s.trim().to_lowercase()).unwrap_or_default();
    if t.is_empty() || t == "전체" {
        return SectionChoice::All;
    }
    let all = NewsCategory::all();
    if let Some(c) = all.iter().find(|c| c.raw() == t || c.label().to_lowercase() == t) {
        return SectionChoice::Only(*c);
    }
    let partial: Vec<_> = all
        .iter()
        .filter(|c| {
            let l = c.label().to_lowercase();
            l.split('·').any(|p| p == t) || l.starts_with(&t)
        })
        .collect();
    if partial.len() == 1 {
        SectionChoice::Only(*partial[0])
    } else {
        SectionChoice::Unknown
    }
}

pub fn count(n: Option<i64>) -> usize {
    n.unwrap_or(5).clamp(1, MAX_COUNT as i64) as usize
}

pub fn latest(items: &[NewsItem], section: Option<NewsCategory>, count: usize) -> Vec<NewsItem> {
    let mut v: Vec<NewsItem> = items.iter().filter(|i| section.map(|s| i.category() == s).unwrap_or(true)).cloned().collect();
    v.sort_by_key(|i| std::cmp::Reverse(i.date_or_past()));
    v.truncate(count);
    v
}

// 상태 파일에서 보이는 최근 소식(꺼진·숨긴 출처와 '알리지 않음' 낱말 글은 뺌 — 상단바와 같음)
pub fn visible_recent(state: &AppState) -> Vec<NewsItem> {
    let sources: Vec<_> = resources::CONFIG.sources.iter().cloned().chain(state.custom_sources.iter().cloned()).collect();
    let f = crate::source_filter::SourceFilter::make(state, &sources);
    crate::app_model::visible(&state.recent, &f, &state.settings.mute_keywords)
}

pub fn format_latest(items: &[NewsItem], json: bool, now: chrono::DateTime<chrono::Utc>) -> String {
    if json {
        let v: Vec<serde_json::Value> = items
            .iter()
            .map(|i| {
                serde_json::json!({
                    "key": i.key(), "title": i.display_title(), "source": i.source_name, "link": i.link,
                    "date": i.date.map(|d| d.to_rfc3339()), "open": open_link(&i.key()),
                })
            })
            .collect();
        return serde_json::to_string_pretty(&v).unwrap_or_default() + "\n";
    }
    if items.is_empty() {
        return "가져올 소식이 없습니다.\n".into();
    }
    items
        .iter()
        .map(|i| format!("{} — {} · {}\n  {}\n", i.display_title(), i.source_name, crate::models::relative_time(i.date, now), i.link))
        .collect()
}
