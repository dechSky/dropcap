// 저장한 기사·스크랩을 데스크톱 검색에서 찾기(맥 Integrations/SpotlightIndexer.swift 에 해당).
// 리눅스는 색인을 넘겨 두는 대신 GNOME 검색(SearchProvider2)·KDE KRunner 가 물을 때마다 지금 목록에서 찾는다 —
// 지운 기사는 그 즉시 결과에서 빠지고, 따로 남겨 둘 색인 파일이 없다.
use crate::models::NewsItem;
use crate::scrapbook::Scrap;
use chrono::{DateTime, Utc};

pub const SAVED_PREFIX: &str = "saved:";
pub const SCRAP_PREFIX: &str = "scrap:";
pub const MAX_RESULTS: usize = 20;

#[derive(Debug, Clone, PartialEq)]
pub struct Doc {
    pub id: String,
    pub domain: &'static str, // saved · scrap
    pub title: String,
    pub detail: String,
    pub keywords: Vec<String>,
    pub date: Option<DateTime<Utc>>,
}

pub fn docs(saved: &[NewsItem], scraps: &[Scrap]) -> Vec<Doc> {
    let a = saved.iter().map(|it| {
        let mut keywords = vec!["Dropcap".to_string(), "나중에 읽기".into(), it.source_name.clone()];
        if it.title_ko.is_some() && it.title_ko.as_deref() != Some(it.title.as_str()) {
            keywords.push(it.title.clone());
        }
        Doc {
            id: format!("{SAVED_PREFIX}{}", it.key()),
            domain: "saved",
            title: it.display_title().to_string(),
            detail: [it.source_name.as_str(), it.summary.as_str()].iter().filter(|s| !s.is_empty()).cloned().collect::<Vec<_>>().join(" — "),
            keywords,
            date: it.date,
        }
    });
    let b = scraps.iter().map(|s| {
        let memo = (!s.memo.is_empty()).then(|| format!("메모: {}", s.memo));
        Doc {
            id: format!("{SCRAP_PREFIX}{}", s.id),
            domain: "scrap",
            title: s.item.display_title().to_string(),
            detail: [s.quote.clone(), memo, Some(s.item.source_name.clone())].into_iter().flatten().collect::<Vec<_>>().join(" — "),
            keywords: vec!["Dropcap".into(), "스크랩".into(), s.collection.clone(), s.item.source_name.clone()],
            date: Some(s.created),
        }
    });
    a.chain(b).collect()
}

// 낱말이 모두(대소문자 무시) 제목·설명·꼬리말 어딘가에 있는 것. 제목에 걸린 것이 앞, 그다음 최근 순.
pub fn search(docs: &[Doc], terms: &[String]) -> Vec<String> {
    let terms: Vec<String> = terms.iter().map(|t| t.trim().to_lowercase()).filter(|t| !t.is_empty()).collect();
    if terms.is_empty() || terms.iter().map(|t| t.chars().count()).sum::<usize>() < 2 {
        return vec![]; // 한 글자로는 찾지 않음(검색창에 칠 때마다 쏟아지지 않게)
    }
    let mut hits: Vec<(bool, Option<DateTime<Utc>>, &Doc)> = docs
        .iter()
        .filter_map(|d| {
            let title = d.title.to_lowercase();
            let all = format!("{title}\n{}\n{}", d.detail.to_lowercase(), d.keywords.join(" ").to_lowercase());
            terms.iter().all(|t| all.contains(t.as_str())).then(|| (terms.iter().all(|t| title.contains(t.as_str())), d.date, d))
        })
        .collect();
    hits.sort_by(|a, b| b.0.cmp(&a.0).then(b.1.cmp(&a.1)));
    let mut seen = std::collections::HashSet::new();
    hits.into_iter().map(|h| h.2.id.clone()).filter(|id| seen.insert(id.clone())).take(MAX_RESULTS).collect()
}

// 결과를 눌렀을 때 열 기사
pub fn item_for(id: &str, saved: &[NewsItem], scraps: &[Scrap]) -> Option<NewsItem> {
    if let Some(key) = id.strip_prefix(SAVED_PREFIX) {
        saved.iter().find(|i| i.key() == key).cloned()
    } else if let Some(sid) = id.strip_prefix(SCRAP_PREFIX) {
        scraps.iter().find(|s| s.id == sid).map(|s| s.item.clone())
    } else {
        None
    }
}

// 결과 한 줄 아래에 보일 설명(길면 자름)
pub fn description(d: &Doc) -> String {
    let label = if d.domain == "scrap" { "스크랩" } else { "나중에 읽기" };
    let s = format!("{label} · {}", d.detail);
    if s.chars().count() > 140 {
        s.chars().take(139).collect::<String>() + "…"
    } else {
        s
    }
}
