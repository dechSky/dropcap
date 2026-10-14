// shared/sources.json 과 같은 모양. 상태 파일·DB 에 쓰는 JSON 이름은 맥 앱(Core/Models.swift)과 같다.
use chrono::{DateTime, Utc};
use once_cell::sync::Lazy;
use regex::{Regex, RegexBuilder};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Debug, Clone, Deserialize)]
pub struct SourceConfig {
    pub version: i64,
    pub tiers: HashMap<String, String>,
    #[serde(rename = "aiPattern")]
    pub ai_pattern: String,
    pub sources: Vec<Source>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
pub struct Source {
    pub id: String,
    pub name: String,
    pub tier: String,
    #[serde(rename = "type")]
    pub kind_type: String, // feed | sitemap
    pub url: String,
    #[serde(rename = "match", default, skip_serializing_if = "Option::is_none")]
    pub match_: Option<String>,
    #[serde(rename = "aiOnly", default)]
    pub ai_only: bool,
    #[serde(rename = "defaultOn", default)]
    pub default_on: bool,
    #[serde(default = "default_color")]
    pub color: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>, // article(기본) · video · paper · release · post · podcast
    #[serde(rename = "notifyDefault", default, skip_serializing_if = "Option::is_none")]
    pub notify_default: Option<bool>, // 알림 기본값(양 많은 채널은 false)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group: Option<String>, // 추천 목록의 묶음 이름
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub home: Option<String>, // 사람이 보는 주소(설정 화면 표시용)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub section: Option<String>, // 분야 id(shared/categories.json). 없으면 AI(예전 출처·직접 추가)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lang: Option<String>, // 글의 언어(ko·en …). 없으면 en
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub region: Option<String>, // kr(국내) · intl(해외). 없으면 tier 로 정함
}

fn default_color() -> String {
    "#3B82F6".into()
}

impl Source {
    pub fn item_kind(&self) -> ItemKind {
        ItemKind::from_raw(self.kind.as_deref().unwrap_or("article"))
    }
    pub fn is_sitemap(&self) -> bool {
        self.kind_type == "sitemap"
    }
    pub fn section_id(&self) -> &str {
        self.section.as_deref().unwrap_or("ai")
    }
    pub fn language(&self) -> &str {
        self.lang.as_deref().unwrap_or("en")
    }
    pub fn region_code(&self) -> &str {
        self.region.as_deref().unwrap_or(if self.tier == "kr" { "kr" } else { "intl" })
    }
    pub fn is_domestic(&self) -> bool {
        self.region_code() == "kr"
    }
}

// 글의 종류: 기사 외의 구독 채널(영상·논문·릴리스·커뮤니티·팟캐스트)
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ItemKind {
    Article,
    Video,
    Paper,
    Release,
    Post,
    Podcast,
}

impl ItemKind {
    pub const ALL: [ItemKind; 6] = [Self::Article, Self::Video, Self::Paper, Self::Release, Self::Post, Self::Podcast];

    pub fn from_raw(s: &str) -> ItemKind {
        match s {
            "video" => Self::Video,
            "paper" => Self::Paper,
            "release" => Self::Release,
            "post" => Self::Post,
            "podcast" => Self::Podcast,
            _ => Self::Article,
        }
    }
    pub fn raw(self) -> &'static str {
        match self {
            Self::Article => "article",
            Self::Video => "video",
            Self::Paper => "paper",
            Self::Release => "release",
            Self::Post => "post",
            Self::Podcast => "podcast",
        }
    }
    pub fn label(self) -> &'static str {
        match self {
            Self::Article => "기사",
            Self::Video => "영상",
            Self::Paper => "논문",
            Self::Release => "릴리스",
            Self::Post => "커뮤니티",
            Self::Podcast => "팟캐스트",
        }
    }
    // freedesktop 아이콘 이름(맥 SF Symbols 에 해당)
    pub fn icon(self) -> &'static str {
        match self {
            Self::Article => "text-x-generic-symbolic",
            Self::Video => "media-playback-start-symbolic",
            Self::Paper => "x-office-document-symbolic",
            Self::Release => "package-x-generic-symbolic",
            Self::Post => "user-available-symbolic",
            Self::Podcast => "audio-x-generic-symbolic",
        }
    }
    // 읽기 창 대신 원래 앱·브라우저로 여는 것
    pub fn opens_externally(self) -> bool {
        matches!(self, Self::Video | Self::Podcast)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct NewsItem {
    pub id: String, // 출처 안에서의 고유 값(guid 또는 주소)
    pub title: String,
    #[serde(rename = "titleKo", default, skip_serializing_if = "Option::is_none")]
    pub title_ko: Option<String>,
    pub link: String,
    #[serde(default, with = "crate::iso::opt", skip_serializing_if = "Option::is_none")]
    pub date: Option<DateTime<Utc>>,
    #[serde(default)]
    pub summary: String,
    #[serde(rename = "sourceId")]
    pub source_id: String,
    #[serde(rename = "sourceName")]
    pub source_name: String,
    pub tier: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub related: Option<Vec<String>>, // 같은 소식을 다룬 다른 출처
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image: Option<String>, // 대표 사진 주소
    #[serde(rename = "titleEn", default, skip_serializing_if = "Option::is_none")]
    pub title_en: Option<String>, // 영어 제목(한국어 기사를 다른 기사와 같은 소식인지 비교할 때)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub important: Option<bool>, // '꼭 알림' 낱말에 걸림
}

impl NewsItem {
    pub fn new(id: &str, title: &str, link: &str, source_id: &str, source_name: &str, tier: &str) -> NewsItem {
        NewsItem {
            id: id.into(),
            title: title.into(),
            title_ko: None,
            link: link.into(),
            date: None,
            summary: String::new(),
            source_id: source_id.into(),
            source_name: source_name.into(),
            tier: tier.into(),
            related: None,
            image: None,
            title_en: None,
            kind: None,
            important: None,
        }
    }
    pub fn key(&self) -> String {
        format!("{}|{}", self.source_id, self.id)
    }
    pub fn display_title(&self) -> &str {
        self.title_ko.as_deref().unwrap_or(&self.title)
    }
    pub fn item_kind(&self) -> ItemKind {
        ItemKind::from_raw(self.kind.as_deref().unwrap_or("article"))
    }
    pub fn is_important(&self) -> bool {
        self.important == Some(true)
    }
    pub fn related_count(&self) -> usize {
        self.related.as_ref().map(|r| r.len()).unwrap_or(0)
    }
    // 출처 글자 원형(모노그램)
    pub fn initial(&self) -> String {
        let n = self.source_name.replace("The ", "");
        n.chars().next().map(|c| c.to_uppercase().collect()).unwrap_or_default()
    }
    pub fn date_or_past(&self) -> DateTime<Utc> {
        self.date.unwrap_or(DateTime::<Utc>::MIN_UTC)
    }
}

pub mod resources {
    use super::*;

    // 앱에 담아 배포: shared/sources.json 을 빌드할 때 실행 파일 안에 넣는다
    pub const SOURCES_JSON: &str = include_str!("../../../shared/sources.json");

    pub static CONFIG: Lazy<SourceConfig> =
        Lazy::new(|| serde_json::from_str(SOURCES_JSON).expect("sources.json 을 읽지 못함"));

    pub static AI_REGEX: Lazy<Regex> = Lazy::new(|| {
        RegexBuilder::new(&CONFIG.ai_pattern).case_insensitive(true).build().expect("aiPattern")
    });

    pub fn tier_label(tier: &str) -> String {
        CONFIG.tiers.get(tier).cloned().unwrap_or_else(|| tier.to_string())
    }

    pub fn ai_match(text: &str) -> bool {
        AI_REGEX.is_match(text)
    }
}

pub fn relative_time(date: Option<DateTime<Utc>>, now: DateTime<Utc>) -> String {
    let Some(d) = date else { return "방금".into() };
    let m = (now - d).num_seconds() / 60;
    if m < 1 {
        "방금".into()
    } else if m < 60 {
        format!("{m}분 전")
    } else if m < 60 * 24 {
        format!("{}시간 전", m / 60)
    } else {
        format!("{}일 전", m / 1440)
    }
}

// "#RRGGBB" → (r,g,b) 0~1
pub fn hex_rgb(hex: &str) -> (f64, f64, f64) {
    let s = hex.trim().trim_start_matches('#');
    let v = u32::from_str_radix(s, 16).unwrap_or(0x3B82F6);
    (((v >> 16) & 0xFF) as f64 / 255.0, ((v >> 8) & 0xFF) as f64 / 255.0, (v & 0xFF) as f64 / 255.0)
}
