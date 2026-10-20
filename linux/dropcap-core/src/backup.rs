// 내 기록 내보내기·가져오기(P-08 · 맥 Core/Backup.swift 와 같은 파일): 기기 사이를 옮길 때. 계정도 서버도 없이 JSON 파일 하나로.
// 맥·윈도우·리눅스가 같은 형식(`format: "dropcap-backup"`, `version: 1`, 같은 키 이름)이라 서로 옮길 수 있다.
// 담는 것: 저장(나중에 읽기) · 스크랩과 스크랩 폴더 · 구독(직접 추가한 출처·켜고 끈 출처·출처별 알림) · 고른 분야와 분야별 알림 ·
// 알림 설정·낱말(꼭 알림·알리지 않음·지켜볼 낱말) · 숨긴 출처 · 팔로우한 스토리.
// 담지 않는 것: 기사 본문·번역 캐시, 사진, 매거진 기사 기록(다시 받으면 생김), 읽음 기록·본 글 기억.
use crate::models::{NewsItem, Source};
use crate::notify_policy::SectionPolicy;
use crate::scrapbook::{Scrap, DEFAULT_COLLECTION};
use crate::store::{AppState, Settings};
use chrono::{DateTime, Utc};
use serde::Serialize;
use serde_json::{Map, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

pub const FORMAT_NAME: &str = "dropcap-backup";
pub const CURRENT_VERSION: i64 = 1;
pub const KEEP_BEFORE_IMPORT: usize = 5;
pub const MAX_FILE_BYTES: usize = 50 * 1024 * 1024;

// 파일에서 읽기: 50MB 가 넘으면 읽지 않는다(맥과 같은 상한)
pub fn read_file(path: &Path) -> Result<BackupFile, Failure> {
    let size = std::fs::metadata(path).map_err(|_| Failure::NotBackup)?.len();
    if size > MAX_FILE_BYTES as u64 {
        return Err(Failure::TooLarge);
    }
    let data = std::fs::read(path).map_err(|_| Failure::NotBackup)?;
    decode(&data)
}

// 낱말: 빈 것 빼고 40자까지, 200개까지(설정 화면에서 넣을 수 있는 정도), 대소문자만 다른 것은 한 번
fn clean_words(list: &[String]) -> Vec<String> {
    let mut out: Vec<String> = vec![];
    for w in list.iter().map(|w| w.trim()) {
        if !w.is_empty() && w.chars().count() <= 40 && !out.iter().any(|o| o.to_lowercase() == w.to_lowercase()) {
            out.push(w.to_string());
            if out.len() == 200 {
                break;
            }
        }
    }
    out
}

fn clean_ids(list: &[String], max: usize) -> Vec<String> {
    let mut out: Vec<String> = vec![];
    for x in list {
        if !x.is_empty() && x.chars().count() <= 64 && !out.contains(x) {
            out.push(x.clone());
            if out.len() == max {
                break;
            }
        }
    }
    out
}

fn hex_color(c: &str) -> bool {
    (4..=9).contains(&c.len()) && c.starts_with('#') && c[1..].chars().all(|x| x.is_ascii_hexdigit())
}

fn clip(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

// 가져온 기록 정리(맥 BackupFile.sanitize · 윈도우 Sanitize 와 같은 규칙): 범위 밖 수치를 묶고,
// 직접 추가한 출처는 custom- id·공개 주소·#색(CSS 에 그대로 들어가지 않게)·피드 형식만, 기본 출처를 흉내 낸 것은 버림,
// 저장·스크랩은 공개 http(s) 링크만, 폴더 이름은 60자까지
pub fn sanitize(b: &mut BackupFile) {
    use crate::url_safety::is_public_http;
    b.settings.clamp();
    if ![2, 5, 10, 15, 30].contains(&b.settings.interval_minutes) {
        b.settings.interval_minutes = 5;
    }
    b.settings.digest_hour = b.settings.digest_hour.clamp(5, 12);
    b.settings.must_keywords = clean_words(&b.settings.must_keywords);
    b.settings.mute_keywords = clean_words(&b.settings.mute_keywords);
    b.settings.watch_keywords = clean_words(&b.settings.watch_keywords);
    b.section_policy.retain(|k, _| crate::sections::by_id(k).is_some());
    for p in b.section_policy.values_mut() {
        p.bundle_hour = p.bundle_hour.clamp(6, 23);
        p.daily_cap = p.daily_cap.clamp(1, 10);
    }
    if let Some(ids) = &b.sections_chosen {
        let mut out: Vec<String> = vec![];
        for id in ids {
            if crate::sections::by_id(id).is_some() && !out.contains(id) {
                out.push(id.clone());
            }
        }
        b.sections_chosen = Some(out);
    }
    b.custom_sources = b
        .custom_sources
        .iter()
        .filter(|s| s.id.starts_with("custom-") && s.id.chars().count() <= 64 && is_public_http(&s.url))
        .take(500)
        .map(|s| {
            let mut c = s.clone();
            c.name = clip(&s.name, 80);
            if !["lab", "press", "kr"].contains(&s.tier.as_str()) {
                c.tier = "press".into();
            }
            c.kind_type = "feed".into();
            c.match_ = None;
            c.ai_only = false;
            if !hex_color(&s.color) {
                c.color = "#3B82F6".into();
            }
            c.kind = s.kind.as_deref().filter(|k| ["article", "video", "paper", "release", "post", "podcast"].contains(k)).map(|k| k.to_string());
            c.group = s.group.as_deref().map(|g| clip(g, 80));
            c.home = s.home.clone().filter(|h| is_public_http(h));
            c.section = s.section.as_deref().and_then(crate::sections::by_id).map(|x| x.id.clone());
            c.lang = s.lang.as_deref().map(|l| clip(l, 8));
            c.region = s.region.clone().filter(|r| r == "kr" || r == "intl");
            c.paywall = s.paywall.clone().filter(|p| p == "hard" || p == "metered");
            c
        })
        .collect();
    b.hidden_sources = clean_ids(&b.hidden_sources, 500);
    b.followed_stories = clean_ids(&b.followed_stories, 1000);
    b.enabled.retain(|k, _| k.chars().count() <= 64);
    b.notify.retain(|k, _| k.chars().count() <= 64);
    b.saved.retain(|i| is_public_http(&i.link));
    b.saved.truncate(5000);
    b.scraps.retain(|s| is_public_http(&s.item.link));
    b.scraps.truncate(5000);
    for s in b.scraps.iter_mut() {
        let c = s.collection.trim().to_string();
        s.collection = if c.is_empty() || c.chars().count() > 60 { DEFAULT_COLLECTION.to_string() } else { c };
    }
    let mut folders: Vec<String> = vec![];
    for f in b.scrap_folders.iter().map(|f| f.trim().to_string()) {
        if !f.is_empty() && f.chars().count() <= 60 && !folders.contains(&f) {
            folders.push(f);
        }
    }
    folders.truncate(200);
    b.scrap_folders = folders;
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct BackupFile {
    pub format: String,
    pub version: i64,
    #[serde(with = "crate::iso")]
    pub exported: DateTime<Utc>,
    pub app: String,
    pub settings: Settings,
    #[serde(rename = "sectionsChosen", skip_serializing_if = "Option::is_none")]
    pub sections_chosen: Option<Vec<String>>,
    #[serde(rename = "sectionPolicy")]
    pub section_policy: HashMap<String, SectionPolicy>,
    pub enabled: HashMap<String, bool>,
    pub notify: HashMap<String, bool>,
    #[serde(rename = "customSources")]
    pub custom_sources: Vec<Source>,
    #[serde(rename = "hiddenSources")]
    pub hidden_sources: Vec<String>,
    #[serde(rename = "followedStories")]
    pub followed_stories: Vec<String>,
    pub saved: Vec<NewsItem>,
    pub scraps: Vec<Scrap>,
    #[serde(rename = "scrapFolders")]
    pub scrap_folders: Vec<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Failure {
    NotBackup,
    NewerVersion(i64),
    TooLarge,
}

impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Failure::NotBackup => write!(f, "Dropcap 기록 파일이 아닙니다"),
            Failure::TooLarge => write!(f, "기록 파일이 너무 큽니다(50MB 까지)"),
            Failure::NewerVersion(v) => write!(f, "더 새 판 Dropcap 이 만든 기록입니다(형식 {v}). 앱을 업데이트한 뒤 가져오세요"),
        }
    }
}

pub fn make(s: &AppState, scraps: &[Scrap], folders: &[String], now: DateTime<Utc>) -> BackupFile {
    BackupFile {
        format: FORMAT_NAME.into(),
        version: CURRENT_VERSION,
        exported: now,
        app: "linux".into(),
        settings: s.settings.clone(),
        sections_chosen: s.sections_chosen.clone(),
        section_policy: s.section_policy.clone(),
        enabled: s.enabled.clone(),
        notify: s.notify.clone(),
        custom_sources: s.custom_sources.clone(),
        hidden_sources: s.hidden_sources.clone(),
        followed_stories: s.followed_stories.clone(),
        saved: s.saved.clone(),
        scraps: scraps.to_vec(),
        scrap_folders: folders.to_vec(),
    }
}

// 보기 좋게·키 정렬(맥 .prettyPrinted · .sortedKeys 와 같은 내용)
pub fn encode(b: &BackupFile) -> Vec<u8> {
    let v = serde_json::to_value(b).unwrap_or(Value::Null); // serde_json 의 Map 은 키 순서로 정렬된다
    serde_json::to_vec_pretty(&v).unwrap_or_default()
}

fn field<T: serde::de::DeserializeOwned>(m: &Map<String, Value>, k: &str) -> Option<T> {
    m.get(k).and_then(|v| serde_json::from_value(v.clone()).ok())
}

// 목록은 하나씩 읽어 깨진 것만 버린다
fn list<T: serde::de::DeserializeOwned>(m: &Map<String, Value>, k: &str) -> Vec<T> {
    match m.get(k) {
        Some(Value::Array(a)) => a.iter().filter_map(|v| serde_json::from_value(v.clone()).ok()).collect(),
        _ => vec![],
    }
}

// 형식 이름·판을 먼저 본다(다른 JSON 이거나 새 판이면 알아듣게). 항목이 빠졌거나 일부가 깨져도 나머지는 읽는다
pub fn decode(data: &[u8]) -> Result<BackupFile, Failure> {
    let v: Value = serde_json::from_slice(data).map_err(|_| Failure::NotBackup)?;
    let m = v.as_object().ok_or(Failure::NotBackup)?;
    if m.get("format").and_then(|f| f.as_str()) != Some(FORMAT_NAME) {
        return Err(Failure::NotBackup);
    }
    let version = m.get("version").and_then(|x| x.as_i64()).unwrap_or(1);
    if version > CURRENT_VERSION {
        return Err(Failure::NewerVersion(version));
    }
    let mut b = BackupFile {
        format: FORMAT_NAME.into(),
        version,
        exported: m.get("exported").and_then(|x| x.as_str()).and_then(crate::iso::parse).unwrap_or(DateTime::<Utc>::UNIX_EPOCH),
        app: field(m, "app").unwrap_or_else(|| "?".into()),
        settings: field(m, "settings").unwrap_or_default(),
        sections_chosen: field(m, "sectionsChosen"),
        section_policy: field(m, "sectionPolicy").unwrap_or_default(),
        enabled: field(m, "enabled").unwrap_or_default(),
        notify: field(m, "notify").unwrap_or_default(),
        custom_sources: list(m, "customSources"),
        hidden_sources: field(m, "hiddenSources").unwrap_or_default(),
        followed_stories: field(m, "followedStories").unwrap_or_default(),
        saved: list(m, "saved"),
        scraps: list(m, "scraps"),
        scrap_folders: field(m, "scrapFolders").unwrap_or_default(),
    };
    sanitize(&mut b);
    Ok(b)
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Summary {
    pub saved: usize,
    pub scraps: usize,
    pub folders: usize,
    pub sources: usize,
    pub sections: usize,
    pub words: usize,
    pub hidden: usize,
    pub followed: usize,
    pub settings_taken: bool,
}

impl Summary {
    pub fn text(&self) -> String {
        let mut parts = vec![];
        for (n, label) in [
            (self.saved, "저장"),
            (self.scraps, "스크랩"),
            (self.folders, "폴더"),
            (self.sources, "구독"),
            (self.sections, "분야"),
            (self.words, "낱말"),
            (self.hidden, "숨긴 출처"),
            (self.followed, "팔로우"),
        ] {
            if n > 0 {
                parts.push(format!("{label} {n}"));
            }
        }
        if self.settings_taken {
            parts.push("알림 설정".into());
        }
        if parts.is_empty() {
            "새로 더할 것이 없었습니다(모두 이미 있음)".into()
        } else {
            parts.join(" · ") + " 더함"
        }
    }
}

pub struct Merged {
    pub state: AppState,
    pub new_scraps: Vec<Scrap>,
    pub folders: Vec<String>,
    pub summary: Summary,
}

fn union(a: &[String], b: &[String], count: &mut usize) -> Vec<String> {
    let mut out = a.to_vec();
    for x in b {
        if !out.iter().any(|o| o.to_lowercase() == x.to_lowercase()) {
            out.push(x.clone());
            *count += 1;
        }
    }
    out
}

// 합치기: 이 기기에 없는 것만 더하고 같은 것은 건너뛴다. 이 기기의 값을 지우거나 끄지 않는다.
// 알림 설정(시각·상한 등 낱개 값)은 이 기기가 아직 처음 그대로일 때만 가져온 값을 쓴다(새 기기로 옮길 때). 낱말 목록은 늘 합친다.
pub fn merge(b: &BackupFile, s0: &AppState, scraps: &[Scrap], folders: &[String]) -> Merged {
    let mut s = s0.clone();
    let mut sum = Summary::default();
    let mut bare = s.settings.clone();
    bare.must_keywords.clear();
    bare.mute_keywords.clear();
    bare.watch_keywords.clear();
    if bare == Settings::default() {
        let mut taken = b.settings.clone();
        taken.must_keywords = s.settings.must_keywords.clone();
        taken.mute_keywords = s.settings.mute_keywords.clone();
        taken.watch_keywords = s.settings.watch_keywords.clone();
        if taken != s.settings {
            sum.settings_taken = true;
        }
        s.settings = taken;
    }
    s.settings.must_keywords = union(&s.settings.must_keywords, &b.settings.must_keywords, &mut sum.words);
    s.settings.mute_keywords = union(&s.settings.mute_keywords, &b.settings.mute_keywords, &mut sum.words);
    s.settings.watch_keywords = union(&s.settings.watch_keywords, &b.settings.watch_keywords, &mut sum.words);
    // 분야
    if let Some(theirs) = &b.sections_chosen {
        let mine = s.sections_chosen.clone().unwrap_or_default();
        let add: Vec<String> = theirs.iter().filter(|x| !mine.contains(x)).cloned().collect();
        sum.sections = add.len();
        if s.sections_chosen.is_none() || !add.is_empty() {
            let mut all: Vec<String> = mine.into_iter().chain(add).collect();
            all.sort_by_key(|x| crate::sections::order(x));
            s.sections_chosen = Some(all);
        }
    }
    for (k, v) in &b.section_policy {
        s.section_policy.entry(k.clone()).or_insert(*v);
    }
    // 구독: 직접 추가한 출처(같은 id·주소는 건너뜀), 켜 둔 출처는 켬(끄지는 않음), 출처별 알림은 없는 것만
    for src in &b.custom_sources {
        if !s.custom_sources.iter().any(|x| x.id == src.id || x.url == src.url) {
            s.custom_sources.push(src.clone());
            sum.sources += 1;
        }
    }
    for (k, v) in &b.enabled {
        if *v && s.enabled.get(k) != Some(&true) {
            s.enabled.insert(k.clone(), true);
        }
    }
    for (k, v) in &b.notify {
        s.notify.entry(k.clone()).or_insert(*v);
    }
    s.hidden_sources = union(&s.hidden_sources, &b.hidden_sources, &mut sum.hidden);
    s.followed_stories = union(&s.followed_stories, &b.followed_stories, &mut sum.followed);
    // 저장(같은 기사는 건너뜀, 가져온 것은 뒤에)
    for it in &b.saved {
        if !s.saved.iter().any(|x| x.key() == it.key()) {
            s.saved.push(it.clone());
            sum.saved += 1;
        }
    }
    // 스크랩(같은 id, 또는 같은 기사·같은 문단·같은 폴더면 건너뜀)
    let mut new_scraps: Vec<Scrap> = vec![];
    for sc in &b.scraps {
        let dup = scraps
            .iter()
            .chain(new_scraps.iter())
            .any(|x| x.id == sc.id || (x.item.key() == sc.item.key() && x.quote == sc.quote && x.collection == sc.collection));
        if !dup {
            new_scraps.push(sc.clone());
        }
    }
    sum.scraps = new_scraps.len();
    let mut fs = folders.to_vec();
    for f in b.scrap_folders.iter().chain(new_scraps.iter().map(|x| &x.collection)) {
        if !fs.contains(f) {
            fs.push(f.clone());
            sum.folders += 1;
        }
    }
    Merged { state: s, new_scraps, folders: fs, summary: sum }
}

// 되돌리기: 가져오기 전에 남긴 파일의 값으로 그 항목들을 그대로 바꾼다(가져오기로 더해진 것이 빠진다)
pub fn restore(b: &BackupFile, s0: &AppState) -> AppState {
    let mut s = s0.clone();
    s.settings = b.settings.clone();
    s.sections_chosen = b.sections_chosen.clone();
    s.section_policy = b.section_policy.clone();
    s.enabled = b.enabled.clone();
    s.notify = b.notify.clone();
    s.custom_sources = b.custom_sources.clone();
    s.hidden_sources = b.hidden_sources.clone();
    s.followed_stories = b.followed_stories.clone();
    s.saved = b.saved.clone();
    s
}

// 스크랩 폴더 목록 중 prefs 에 따로 적어 둘 것(스크랩이 든 폴더·기본 폴더는 빼고)
pub fn extra_folders(folders: &[String], scraps: &[Scrap]) -> Vec<String> {
    folders.iter().filter(|f| f.as_str() != DEFAULT_COLLECTION && !scraps.iter().any(|s| &s.collection == *f)).cloned().collect()
}

// MARK: 가져오기 전 자동 백업 파일(<데이터 폴더>/backups/before-import-날짜.json, 최근 5개)
pub fn backups_dir(data_dir: &Path) -> PathBuf {
    data_dir.join("backups")
}

pub fn stamp(now: DateTime<Utc>) -> String {
    now.with_timezone(&chrono::Local).format("%Y%m%d-%H%M%S").to_string()
}

fn before_import_files(dir: &Path) -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = std::fs::read_dir(dir)
        .map(|rd| rd.flatten().map(|e| e.path()).filter(|p| p.file_name().map(|n| n.to_string_lossy().starts_with("before-import-")).unwrap_or(false)).collect())
        .unwrap_or_default();
    v.sort();
    v
}

pub fn latest_before_import(dir: &Path) -> Option<PathBuf> {
    before_import_files(dir).pop()
}

// 지금 기록을 남기고(최근 5개만) 그 파일 경로를 돌려준다
pub fn write_before_import(dir: &Path, current: &BackupFile, now: DateTime<Utc>) -> std::io::Result<PathBuf> {
    std::fs::create_dir_all(dir)?;
    // 1초 안에 두 번 가져와도 이름이 겹치지 않고 이름순 = 시간순이게 밀리초까지
    let f = dir.join(format!("before-import-{}-{}.json", stamp(now), now.format("%3f")));
    crate::store::write_atomic(&f, &encode(current))?;
    let files = before_import_files(dir);
    if files.len() > KEEP_BEFORE_IMPORT {
        for old in &files[..files.len() - KEEP_BEFORE_IMPORT] {
            let _ = std::fs::remove_file(old);
        }
    }
    Ok(f)
}
