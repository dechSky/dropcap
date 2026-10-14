// 소식의 분야. 목록·이름·색·낱말은 코드가 아니라 정의 파일(categories.json)에서 읽는다
// (추가 지시 2: 일반 뉴스로 넓힐 때 자료만 바꾸면 되게). 기본 정의는 맥 Core/Category.swift 와 같다.
// 찾는 순서: DROPCAP_CATEGORIES(시험용 경로) → 실행 파일에 담긴 linux/resources/categories.json
use crate::models::{ItemKind, NewsItem};
use once_cell::sync::Lazy;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

pub const BUNDLED: &str = include_str!("../../resources/categories.json");

#[derive(Debug, Clone, Deserialize)]
pub struct CategoryDef {
    pub id: String,
    pub label: String,
    #[serde(default)]
    pub icon: String,
    pub color: String,
    #[serde(rename = "colorDark", default)]
    pub color_dark: Option<String>,
    #[serde(default)]
    pub words: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CategoryTable {
    pub fallback: String,
    #[serde(rename = "kindCategory", default)]
    pub kind_category: HashMap<String, String>,
    pub order: Vec<String>,
    pub categories: Vec<CategoryDef>, // 위에서부터 먼저 걸리는 분야
}

impl CategoryTable {
    pub fn parse(json: &str) -> Result<CategoryTable, String> {
        let t: CategoryTable = serde_json::from_str(json).map_err(|e| e.to_string())?;
        if !t.categories.iter().any(|c| c.id == t.fallback) {
            return Err("fallback 분야가 목록에 없음".into());
        }
        Ok(t)
    }
}

pub static TABLE: Lazy<CategoryTable> = Lazy::new(|| {
    if let Ok(p) = std::env::var("DROPCAP_CATEGORIES") {
        if let Ok(s) = std::fs::read_to_string(&p) {
            match CategoryTable::parse(&s) {
                Ok(t) => return t,
                Err(e) => log::warn!("[분야] {p} 를 읽지 못해 기본 정의를 씀: {e}"),
            }
        }
    }
    CategoryTable::parse(BUNDLED).expect("categories.json")
});

static COMPILED: Lazy<Vec<(Option<regex::Regex>, Vec<String>)>> = Lazy::new(|| {
    TABLE
        .categories
        .iter()
        .map(|c| {
            let english: Vec<String> = c.words.iter().map(|w| w.trim().to_lowercase()).filter(|w| !w.is_empty() && w.is_ascii()).collect();
            let korean: Vec<String> = c.words.iter().filter(|w| !w.is_ascii()).map(|w| w.trim().to_string()).collect();
            let parts: Vec<String> = english
                .iter()
                .map(|w| {
                    let e = regex::escape(w);
                    if w.chars().count() <= 4 {
                        format!(r"\b{e}\b")
                    } else {
                        format!(r"\b{e}")
                    }
                })
                .collect();
            let re = if parts.is_empty() { None } else { regex::Regex::new(&parts.join("|")).ok() };
            (re, korean)
        })
        .collect()
});

// 정의 표의 한 칸(가볍게 복사되는 번호). JSON 에는 id 글자로 쓴다.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct NewsCategory(u16);

impl NewsCategory {
    fn def(self) -> &'static CategoryDef {
        &TABLE.categories[self.0 as usize]
    }
    pub fn from_raw(s: &str) -> Option<NewsCategory> {
        TABLE.categories.iter().position(|c| c.id == s).map(|i| NewsCategory(i as u16))
    }
    // 이름으로(없으면 그 밖)
    pub fn id(s: &str) -> NewsCategory {
        Self::from_raw(s).unwrap_or_else(Self::other)
    }
    // 어디에도 걸리지 않은 것("그 밖의 소식")
    pub fn other() -> NewsCategory {
        Self::from_raw(&TABLE.fallback).unwrap()
    }
    pub fn is_other(self) -> bool {
        self == Self::other()
    }
    // 화면에 놓는 순서대로 전부
    pub fn all() -> Vec<NewsCategory> {
        let mut v: Vec<NewsCategory> = TABLE.order.iter().filter_map(|id| Self::from_raw(id)).collect();
        for i in 0..TABLE.categories.len() {
            let c = NewsCategory(i as u16);
            if !v.contains(&c) {
                v.push(c);
            }
        }
        v
    }
    pub fn raw(self) -> &'static str {
        &self.def().id
    }
    pub fn label(self) -> &'static str {
        &self.def().label
    }
    pub fn icon(self) -> &'static str {
        let i = &self.def().icon;
        if i.is_empty() {
            "view-app-grid-symbolic"
        } else {
            i
        }
    }
    pub fn color(self, dark: bool) -> &'static str {
        let d = self.def();
        if dark {
            d.color_dark.as_deref().unwrap_or(&d.color)
        } else {
            &d.color
        }
    }
    pub fn sort_order(self) -> usize {
        Self::all().iter().position(|c| *c == self).unwrap_or(99)
    }

    // 먼저 걸리는 분야로 정한다(정의 파일의 위에서부터).
    // 영어는 낱말 경계로(4자 이하는 온전한 낱말만, 긴 어간은 낱말 앞부분) — 'impact'의 act, 'capital'의 api 에 걸리지 않게(맥 A-08).
    // 한국어는 조사가 붙으므로 부분 일치.
    pub fn classify(text: &str) -> NewsCategory {
        let t = text.to_lowercase();
        for (i, (re, korean)) in COMPILED.iter().enumerate() {
            if re.as_ref().map(|r| r.is_match(&t)).unwrap_or(false) || korean.iter().any(|w| t.contains(w.as_str())) {
                return NewsCategory(i as u16);
            }
        }
        Self::other()
    }
}

impl Serialize for NewsCategory {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(self.raw())
    }
}

impl<'de> Deserialize<'de> for NewsCategory {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        Ok(NewsCategory::id(&String::deserialize(d)?)) // 모르는 분야는 그 밖으로(정의가 바뀌어도 읽힘)
    }
}

impl NewsItem {
    pub fn category(&self) -> NewsCategory {
        let kind = self.item_kind();
        if let Some(c) = TABLE.kind_category.get(kind.raw()) {
            return NewsCategory::id(c);
        }
        NewsCategory::classify(&format!("{} {} {}", self.title, self.title_ko.as_deref().unwrap_or(""), self.summary))
    }
}

// 종류 지면의 색(맥 Issue.Section.color)
pub fn kind_color(kind: ItemKind, dark: bool) -> &'static str {
    match (kind, dark) {
        (ItemKind::Video, false) => "#FF3B30",
        (ItemKind::Video, true) => "#FF453A",
        (ItemKind::Paper, _) => "#B31B1B",
        (ItemKind::Release, _) => "#8E8E93",
        (ItemKind::Post, false) => "#FF9500",
        (ItemKind::Post, true) => "#FF9F0A",
        (ItemKind::Podcast, false) => "#AF52DE",
        (ItemKind::Podcast, true) => "#BF5AF2",
        (ItemKind::Article, false) => "#007AFF",
        (ItemKind::Article, true) => "#0A84FF",
    }
}
