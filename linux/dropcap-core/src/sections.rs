// 분야(정치·경제·…·AI). shared/categories.json 을 읽고(앱에 담아 배포), 없거나 깨지면 같은 내용의 기본값(맥 Core/Sections.swift).
// AI 하위 분류(모델·연구·정책·투자·보안)는 category.rs 의 NewsCategory 로 남는다.
use crate::models::{resources, NewsItem};
use once_cell::sync::Lazy;
use regex::Regex;
use serde::Deserialize;
use std::collections::HashMap;
use std::sync::Mutex;

pub const TOP: &str = "top";
pub const AI: &str = "ai";
pub const BUNDLED: &str = include_str!("../../../shared/categories.json");

#[derive(Debug, Clone, PartialEq, Eq, Hash, Deserialize)]
pub struct NewsSection {
    pub id: String,
    pub name: String,
    pub symbol: String, // 맥 SF Symbols 이름(리눅스 아이콘은 icon())
    pub color: String,
    #[serde(default)]
    pub flow: Option<bool>, // 분야가 아니라 흐름(주요 뉴스)
    #[serde(default)]
    pub more: Option<bool>, // 처음 고르기 화면의 '더 보기'
}

impl NewsSection {
    fn new(id: &str, name: &str, symbol: &str, color: &str, flow: bool, more: bool) -> NewsSection {
        NewsSection { id: id.into(), name: name.into(), symbol: symbol.into(), color: color.into(), flow: flow.then_some(true), more: more.then_some(true) }
    }
    pub fn is_flow(&self) -> bool {
        self.flow == Some(true)
    }
    pub fn is_more(&self) -> bool {
        self.more == Some(true)
    }
    // freedesktop 아이콘(맥 기호와 비슷한 것)
    pub fn icon(&self) -> &'static str {
        match self.symbol.as_str() {
            "star.fill" => "starred-symbolic",
            "building.columns" => "document-properties-symbolic",
            "chart.line.uptrend.xyaxis" => "power-profile-performance-symbolic",
            "person.3" => "system-users-symbolic",
            "globe.asia.australia" => "web-browser-symbolic",
            "desktopcomputer" => "computer-symbolic",
            "sparkles" => "starred-symbolic",
            "atom" => "applications-science-symbolic",
            "heart.text.square" => "emoji-people-symbolic",
            "theatermasks" => "applications-multimedia-symbolic",
            "sportscourt" => "applications-games-symbolic",
            "leaf" => "emoji-nature-symbolic",
            _ => "view-app-grid-symbolic",
        }
    }
}

pub fn builtin() -> Vec<NewsSection> {
    vec![
        NewsSection::new("top", "주요 뉴스", "star.fill", "#FF9F0A", true, false),
        NewsSection::new("politics", "정치", "building.columns", "#5E5CE6", false, false),
        NewsSection::new("economy", "경제", "chart.line.uptrend.xyaxis", "#30C759", false, false),
        NewsSection::new("society", "사회", "person.3", "#FF6B35", false, false),
        NewsSection::new("world", "국제", "globe.asia.australia", "#0A84FF", false, false),
        NewsSection::new("tech", "IT", "desktopcomputer", "#64D2FF", false, false),
        NewsSection::new("ai", "AI", "sparkles", "#BF5AF2", false, false),
        NewsSection::new("science", "과학", "atom", "#32ADE6", false, false),
        NewsSection::new("life", "생활·건강", "heart.text.square", "#FF375F", false, false),
        NewsSection::new("culture", "문화·연예", "theatermasks", "#FFD60A", false, false),
        NewsSection::new("sports", "스포츠", "sportscourt", "#34C759", false, false),
        NewsSection::new("climate", "기후·환경", "leaf", "#30D158", false, true),
    ]
}

#[derive(Deserialize)]
struct File {
    sections: Vec<NewsSection>,
}

pub fn parse(json: &str) -> Option<Vec<NewsSection>> {
    let f: File = serde_json::from_str(json).ok()?;
    (!f.sections.is_empty()).then_some(f.sections)
}

// sources.json 출처 항목의 분야 관련 필드
#[derive(Debug, Clone, PartialEq, Eq, Hash, Deserialize)]
pub struct SourceMeta {
    pub id: String,
    #[serde(default)]
    pub section: Option<String>,
    #[serde(default)]
    pub lang: Option<String>,
    #[serde(default)]
    pub region: Option<String>, // kr · intl
    #[serde(default)]
    pub tier: Option<String>,
    #[serde(rename = "defaultOn", default)]
    pub default_on: Option<bool>,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub paywall: Option<String>, // hard · metered(유료 기사 표시, G-14)
}

#[derive(Deserialize)]
struct SourcesFile {
    sources: Vec<SourceMeta>,
}

pub fn parse_meta(json: &str) -> HashMap<String, SourceMeta> {
    let Ok(f) = serde_json::from_str::<SourcesFile>(json) else { return HashMap::new() };
    let mut m = HashMap::new();
    for s in f.sources {
        m.entry(s.id.clone()).or_insert(s);
    }
    m
}

// 찾는 순서: DROPCAP_SECTIONS(시험용 경로) → 실행 파일에 담긴 shared/categories.json → 기본값
pub static ALL: Lazy<Vec<NewsSection>> = Lazy::new(|| {
    if let Some(p) = crate::test_hooks::var("DROPCAP_SECTIONS") {
        if let Some(s) = std::fs::read_to_string(&p).ok().and_then(|j| parse(&j)) {
            return s;
        }
    }
    parse(BUNDLED).unwrap_or_else(builtin)
});
pub static META: Lazy<HashMap<String, SourceMeta>> = Lazy::new(|| parse_meta(resources::SOURCES_JSON));

pub fn by_id(id: &str) -> Option<&'static NewsSection> {
    ALL.iter().find(|s| s.id == id)
}
pub fn name(id: &str) -> String {
    by_id(id).map(|s| s.name.clone()).unwrap_or_else(|| id.to_string())
}
pub fn order(id: &str) -> usize {
    ALL.iter().position(|s| s.id == id).unwrap_or(99)
}
// 처음 고르기 화면에 보이는 분야(흐름 제외)
pub fn pickable() -> Vec<NewsSection> {
    ALL.iter().filter(|s| !s.is_flow()).cloned().collect()
}

// 출처의 분야: sources.json 의 section → 없으면(예전 sources.json·추천 채널) AI 시절 출처이므로 ai.
// 사용자가 주소로 직접 추가한 출처는 모른다(None) → 기사 낱말로 정한다.
pub fn section_of_source(id: &str, meta: &HashMap<String, SourceMeta>) -> Option<String> {
    if let Some(s) = meta.get(id).and_then(|m| m.section.clone()) {
        return Some(s);
    }
    if meta.contains_key(id) || id.starts_with("cat-") {
        return Some(AI.into());
    }
    None
}

pub fn region_of_source(id: &str, tier: &str, meta: &HashMap<String, SourceMeta>) -> String {
    meta.get(id).and_then(|m| m.region.clone()).unwrap_or_else(|| if tier == "kr" { "kr".into() } else { "intl".into() })
}

pub fn sources_in(section: &str, meta: &HashMap<String, SourceMeta>) -> Vec<SourceMeta> {
    let mut v: Vec<SourceMeta> = meta.values().filter(|m| m.section.as_deref() == Some(section)).cloned().collect();
    v.sort_by(|a, b| a.name.clone().unwrap_or_else(|| a.id.clone()).cmp(&b.name.clone().unwrap_or_else(|| b.id.clone())));
    v
}

// 대표 분야 하나 + 칩 여러 개
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Placement {
    pub primary: String,
    pub chips: Vec<String>,
    pub strong: Option<String>, // 출처 분야와 다른데 낱말이 강하게 걸린 분야(목록에 칩을 하나 더 보임)
}

// 출처의 분야가 1순위, 출처가 '주요'·모름이면 낱말 규칙으로 보충. AI 는 다른 분야 글에서도 끌어온다(aiPattern).
pub fn place(it: &NewsItem, meta: &HashMap<String, SourceMeta>, ai_regex: Option<&Regex>) -> Placement {
    let text = format!("{} {} {}", it.title, it.title_ko.as_deref().unwrap_or(""), it.summary);
    let mut primary = section_of_source(&it.source_id, meta);
    if primary.is_none() || primary.as_deref() == Some(TOP) {
        primary = classify(&text).or(primary).or_else(|| Some(TOP.into()));
    }
    let primary = primary.unwrap();
    let mut chips = vec![primary.clone()];
    if primary != AI {
        if let Some(re) = ai_regex {
            if re.is_match(&text) {
                chips.push(AI.into());
            }
        }
    }
    if primary != TOP {
        if let Some(g) = classify(&text) {
            if g != primary && !chips.contains(&g) && g != AI {
                chips.push(g);
            }
        }
    }
    // 출처 분야가 정한 대표와 달리 다른 분야 낱말이 2개 이상(그리고 대표 분야 낱말보다 많이) 걸리면 그 분야를 '강한' 칩으로
    let mut strong = None;
    if primary != TOP {
        let h = hits(&text);
        let best = h.iter().filter(|(k, _)| **k != primary && *k != AI).max_by_key(|(k, v)| (**v, std::cmp::Reverse(order(k))));
        if let Some((k, v)) = best {
            if *v >= 2 && *v > h.get(&primary).copied().unwrap_or(0) {
                strong = Some(k.clone());
                if !chips.contains(k) {
                    chips.push(k.clone());
                }
            }
        }
    }
    Placement { primary, chips, strong }
}

static CACHE: Lazy<Mutex<HashMap<String, Placement>>> = Lazy::new(|| Mutex::new(HashMap::new()));

pub fn cached_place(it: &NewsItem) -> Placement {
    let k = format!("{}\u{1}{}", it.key(), it.title_ko.as_deref().unwrap_or(""));
    if let Some(p) = CACHE.lock().unwrap().get(&k) {
        return p.clone();
    }
    let p = place(it, &META, Some(&resources::AI_REGEX));
    let mut c = CACHE.lock().unwrap();
    if c.len() > 20000 {
        c.clear();
    }
    c.insert(k, p.clone());
    p
}

// '전체'·'주요' 피드에서 온 글의 분야를 낱말로 짐작한다. 앞에 있는 규칙이 먼저(성격이 뚜렷한 것부터).
const RULES: [(&str, &[&str]); 10] = [
    ("sports", &["야구", "축구", "농구", "배구", "골프", "올림픽", "월드컵", "kbo", "k리그", "프로야구", "홈런", "득점", "premier league", "nba", "nfl", "fifa", "olympic", "tournament", "championship"]),
    ("politics", &["대통령", "국회", "여당", "야당", "국민의힘", "민주당", "의원", "장관", "총리", "선거", "탄핵", "청와대", "대통령실", "북한", "국정", "president", "parliament", "congress", "senate", "election", "minister", "lawmakers", "white house"]),
    ("economy", &["증시", "코스피", "코스닥", "주가", "금리", "환율", "물가", "부동산", "아파트값", "수출", "기준금리", "한국은행", "실적", "매출", "영업이익", "stocks", "inflation", "interest rate", "fed", "earnings", "economy", "gdp", "tariff", "market"]),
    ("world", &["미국", "중국", "일본", "러시아", "우크라이나", "이스라엘", "유럽", "트럼프", "시진핑", "푸틴", "ukraine", "israel", "gaza", "china", "russia", "un "]),
    ("science", &["연구진", "우주", "nasa", "위성", "발사체", "유전자", "세포", "물리학", "천문", "scientists", "researchers", "space", "physics", "genome"]),
    ("life", &["건강", "질환", "병원", "환자", "치료", "백신", "다이어트", "여행", "날씨", "health", "disease", "hospital", "vaccine", "cancer"]),
    ("culture", &["영화", "드라마", "가수", "배우", "아이돌", "공연", "전시", "콘서트", "k팝", "케이팝", "film", "movie", "album", "concert", "actor", "box office"]),
    ("climate", &["기후", "탄소", "온실가스", "폭염", "climate", "carbon", "emissions"]),
    ("tech", &["스마트폰", "반도체", "앱 ", "애플", "삼성전자", "구글", "소프트웨어", "해킹", "iphone", "chip", "software", "apple", "google", "microsoft"]),
    ("society", &["경찰", "검찰", "법원", "재판", "사고", "화재", "사망", "교육", "학교", "노조", "police", "court", "trial"]),
];

static HANGUL: Lazy<Regex> = Lazy::new(|| Regex::new("[가-힣]").unwrap());
// 영어는 낱말 경계로, 한국어는 조사가 붙으므로 부분 일치
static COMPILED: Lazy<Vec<(&'static str, Option<Regex>, Vec<&'static str>)>> = Lazy::new(|| {
    RULES
        .iter()
        .map(|(sec, words)| {
            let english: Vec<&str> = words.iter().filter(|w| !HANGUL.is_match(w)).cloned().collect();
            let korean: Vec<&str> = words.iter().filter(|w| HANGUL.is_match(w)).cloned().collect();
            let pat = english.iter().map(|w| format!(r"\b{}\b", regex::escape(w.trim()))).collect::<Vec<_>>().join("|");
            (*sec, if english.is_empty() { None } else { Regex::new(&pat).ok() }, korean)
        })
        .collect()
});

// 분야마다 걸린 낱말 수(서로 다른 낱말)
pub fn hits(text: &str) -> HashMap<String, usize> {
    let t = text.to_lowercase();
    let mut out = HashMap::new();
    for (sec, re, korean) in COMPILED.iter() {
        let mut found = std::collections::HashSet::new();
        if let Some(r) = re {
            for m in r.find_iter(&t) {
                found.insert(m.as_str().to_string());
            }
        }
        for k in korean.iter().filter(|k| t.contains(**k)) {
            found.insert(k.to_string());
        }
        if !found.is_empty() {
            out.insert(sec.to_string(), found.len());
        }
    }
    out
}

pub fn classify(text: &str) -> Option<String> {
    let t = text.to_lowercase();
    for (sec, re, korean) in COMPILED.iter() {
        if re.as_ref().map(|r| r.is_match(&t)).unwrap_or(false) || korean.iter().any(|w| t.contains(w)) {
            return Some(sec.to_string());
        }
    }
    None
}

impl NewsItem {
    // 대표 분야 id
    pub fn section(&self) -> String {
        cached_place(self).primary
    }
    // 이 기사에 다는 분야 칩(대표 포함)
    pub fn section_chips(&self) -> Vec<String> {
        cached_place(self).chips
    }
    // 대표 분야 말고 낱말로 강하게 걸린 분야(목록에 칩을 하나 더)
    pub fn extra_topic(&self) -> Option<String> {
        cached_place(self).strong
    }
    pub fn in_section(&self, id: &str) -> bool {
        self.section_chips().iter().any(|c| c == id)
    }
    // 화면에 보이는 '분야': AI 분야 글은 하위 분류까지('AI·모델·제품'), 나머지는 분야 이름
    pub fn topic_label(&self) -> String {
        let s = self.section();
        if s == AI {
            format!("AI·{}", self.category().label())
        } else {
            name(&s)
        }
    }
    pub fn topic_icon(&self) -> &'static str {
        let s = self.section();
        if s == AI {
            self.category().icon()
        } else {
            by_id(&s).map(|x| x.icon()).unwrap_or("view-app-grid-symbolic")
        }
    }
    pub fn topic_color(&self, dark: bool) -> String {
        let s = self.section();
        if s == AI {
            self.category().color(dark).to_string()
        } else {
            by_id(&s).map(|x| x.color.clone()).unwrap_or_else(|| "#8E8E93".into())
        }
    }
}
