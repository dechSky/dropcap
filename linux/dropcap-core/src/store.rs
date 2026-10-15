// 앱 상태(맥 Core/Store.swift 와 같은 항목·이름). $XDG_DATA_HOME/dropcap/native-state.json
// 항목이 없거나 깨져도 나머지는 읽는다(새 항목이 추가돼도 예전 파일이 그대로 읽힘).
use crate::iso;
use crate::models::{resources::CONFIG, NewsItem, Source};
use chrono::{DateTime, Utc};
use once_cell::sync::Lazy;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Style {
    Drop,
    System,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Position {
    Center,
    Right,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Settings {
    pub style: Style,
    pub sound: bool,
    #[serde(rename = "intervalMinutes")]
    pub interval_minutes: i64,
    pub position: Position,
    #[serde(rename = "quietEnabled")]
    pub quiet_enabled: bool, // 방해 금지 시간
    #[serde(rename = "quietStart")]
    pub quiet_start: i64, // 시(0~23)
    #[serde(rename = "quietEnd")]
    pub quiet_end: i64,
    #[serde(rename = "mustKeywords")]
    pub must_keywords: Vec<String>, // 꼭 알림(중요 표시)
    #[serde(rename = "muteKeywords")]
    pub mute_keywords: Vec<String>, // 알리지 않음
    #[serde(rename = "watchKeywords")]
    pub watch_keywords: Vec<String>, // 지켜볼 낱말(회사·인물·법안) — 스토리마다 한 번 알림 + 하루 정리(N-27)
    #[serde(rename = "digestEnabled")]
    pub digest_enabled: bool, // 아침 브리핑
    #[serde(rename = "digestHour")]
    pub digest_hour: i64,
    #[serde(rename = "totalDailyCap")]
    pub total_daily_cap: i64, // 모든 분야를 합친 하루 물방울 수
    #[serde(rename = "krThreshold")]
    pub kr_threshold: i64, // 국내 n곳 이상 보도면 중요
    #[serde(rename = "intlThreshold")]
    pub intl_threshold: i64, // 해외 n곳 이상
    #[serde(rename = "bigThreshold")]
    pub big_threshold: i64, // 국내 n곳 이상이면 상한 무시
    #[serde(rename = "autoQuietFullscreen")]
    pub auto_quiet_fullscreen: bool, // 전체 화면 앱 사용 중에는 조용히(고임, N-25)
    #[serde(rename = "autoQuietSharing")]
    pub auto_quiet_sharing: bool, // 화면 공유·기록 중
    #[serde(rename = "autoQuietCalendar")]
    pub auto_quiet_calendar: bool, // 캘린더 일정 중(리눅스는 감지하지 않음 — 상태 파일 호환용)
    #[serde(rename = "translateEngine")]
    pub translate_engine: String, // 번역 방식 auto·apple·google·off(맥·윈도우와 같은 키·값 — mac/TRANSLATE.md, 리눅스 auto = Google)
}

impl Settings {
    // 범위 밖 값 묶기(상태 파일을 직접 고쳤거나 가져온 기록 — 맥 Settings.clamp 와 같은 범위).
    // 큰 간격은 시간 계산이 넘치고, 0 이하는 쉬지 않고 받는다
    pub fn clamp(&mut self) {
        self.interval_minutes = self.interval_minutes.clamp(1, 24 * 60);
        self.quiet_start = self.quiet_start.clamp(0, 23);
        self.quiet_end = self.quiet_end.clamp(0, 23);
        self.digest_hour = self.digest_hour.clamp(0, 23);
        self.total_daily_cap = self.total_daily_cap.clamp(1, 30);
        self.kr_threshold = self.kr_threshold.clamp(1, 10);
        self.intl_threshold = self.intl_threshold.clamp(1, 10);
        self.big_threshold = self.big_threshold.clamp(2, 20);
        self.translate_engine = crate::translator::normalize_mode(&self.translate_engine).to_string(); // 모르는 값은 자동(맥과 같음)
    }

    pub fn limits(&self) -> crate::notify_policy::PolicyLimits {
        crate::notify_policy::PolicyLimits {
            total_cap: self.total_daily_cap,
            kr_threshold: self.kr_threshold,
            intl_threshold: self.intl_threshold,
            big_threshold: self.big_threshold,
        }
    }
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            style: Style::Drop,
            sound: true,
            interval_minutes: 5,
            position: Position::Center,
            quiet_enabled: false,
            quiet_start: 23,
            quiet_end: 7,
            must_keywords: vec![],
            mute_keywords: vec![],
            watch_keywords: vec![],
            digest_enabled: true,
            digest_hour: 9,
            total_daily_cap: 10,
            kr_threshold: 3,
            intl_threshold: 2,
            big_threshold: 8,
            auto_quiet_fullscreen: true,
            auto_quiet_sharing: true,
            auto_quiet_calendar: false,
            translate_engine: "auto".into(),
        }
    }
}

fn field<T: DeserializeOwned>(m: &Map<String, Value>, k: &str) -> Option<T> {
    m.get(k).and_then(|v| serde_json::from_value(v.clone()).ok())
}

fn date_field(m: &Map<String, Value>, k: &str) -> Option<DateTime<Utc>> {
    m.get(k).and_then(|v| v.as_str()).and_then(iso::parse)
}

// 목록은 하나씩 읽어 깨진 것만 버린다
fn list_field<T: DeserializeOwned>(m: &Map<String, Value>, k: &str) -> Vec<T> {
    match m.get(k) {
        Some(Value::Array(a)) => a.iter().filter_map(|v| serde_json::from_value(v.clone()).ok()).collect(),
        _ => vec![],
    }
}

impl<'de> Deserialize<'de> for Settings {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let v = Value::deserialize(d)?;
        let Some(m) = v.as_object() else { return Ok(Settings::default()) };
        let def = Settings::default();
        let mut s = Settings {
            style: field(m, "style").unwrap_or(def.style),
            sound: field(m, "sound").unwrap_or(def.sound),
            interval_minutes: field(m, "intervalMinutes").unwrap_or(def.interval_minutes),
            position: field(m, "position").unwrap_or(def.position), // 예전 값 "auto" 도 가운데로
            quiet_enabled: field(m, "quietEnabled").unwrap_or(def.quiet_enabled),
            quiet_start: field(m, "quietStart").unwrap_or(def.quiet_start),
            quiet_end: field(m, "quietEnd").unwrap_or(def.quiet_end),
            must_keywords: field(m, "mustKeywords").unwrap_or_default(),
            mute_keywords: field(m, "muteKeywords").unwrap_or_default(),
            watch_keywords: field(m, "watchKeywords").unwrap_or_default(),
            digest_enabled: field(m, "digestEnabled").unwrap_or(def.digest_enabled),
            digest_hour: field(m, "digestHour").unwrap_or(def.digest_hour),
            total_daily_cap: field(m, "totalDailyCap").unwrap_or(def.total_daily_cap),
            kr_threshold: field(m, "krThreshold").unwrap_or(def.kr_threshold),
            intl_threshold: field(m, "intlThreshold").unwrap_or(def.intl_threshold),
            big_threshold: field(m, "bigThreshold").unwrap_or(def.big_threshold),
            auto_quiet_fullscreen: field(m, "autoQuietFullscreen").unwrap_or(def.auto_quiet_fullscreen),
            auto_quiet_sharing: field(m, "autoQuietSharing").unwrap_or(def.auto_quiet_sharing),
            auto_quiet_calendar: field(m, "autoQuietCalendar").unwrap_or(def.auto_quiet_calendar),
            translate_engine: field(m, "translateEngine").unwrap_or(def.translate_engine), // 예전 파일엔 없음 → 자동
        };
        s.clamp();
        Ok(s)
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct AppState {
    pub seen: HashMap<String, f64>,
    pub seeded: Vec<String>,
    pub enabled: HashMap<String, bool>,
    pub recent: Vec<NewsItem>,
    #[serde(rename = "lastCheck", with = "iso::opt", skip_serializing_if = "Option::is_none")]
    pub last_check: Option<DateTime<Utc>>,
    pub errors: HashMap<String, String>,
    pub unread: i64,
    #[serde(rename = "unreadKeys")]
    pub unread_keys: Vec<String>, // 안 읽음 수에 든 소식(출처를 껐다 켜도 수가 맞게 — 예전 파일엔 없음, S-13)
    pub read: HashMap<String, f64>, // 읽은 기사 key → 읽은 시각
    pub saved: Vec<NewsItem>,       // 나중에 읽기
    #[serde(rename = "customSources")]
    pub custom_sources: Vec<Source>, // 직접 추가한 출처
    #[serde(rename = "snoozeUntil", with = "iso::opt", skip_serializing_if = "Option::is_none")]
    pub snooze_until: Option<DateTime<Utc>>, // 알림 잠시 끄기
    #[serde(rename = "lastDigest", with = "iso::opt", skip_serializing_if = "Option::is_none")]
    pub last_digest: Option<DateTime<Utc>>, // 마지막 아침 브리핑
    #[serde(rename = "lastWatchDigest", with = "iso::opt", skip_serializing_if = "Option::is_none")]
    pub last_watch_digest: Option<DateTime<Utc>>, // 마지막 '지켜볼 낱말' 하루 정리
    #[serde(rename = "interestCategory")]
    pub interest_category: HashMap<String, f64>, // 분야별로 연 횟수(관심사)
    #[serde(rename = "interestSource")]
    pub interest_source: HashMap<String, f64>,
    #[serde(rename = "magazineBackfilled")]
    pub magazine_backfilled: bool, // 처음 매거진을 채웠는지
    pub notify: HashMap<String, bool>, // 출처별 알림(없으면 출처 기본값)
    #[serde(rename = "followedStories")]
    pub followed_stories: Vec<String>, // 팔로우한 스토리(새 보도가 붙으면 알림)
    #[serde(rename = "storySeen")]
    pub story_seen: HashMap<String, i64>, // 스토리를 마지막으로 봤을 때의 보도 수('새 보도 N')
    // 일반 뉴스 분야
    #[serde(rename = "sectionsChosen", skip_serializing_if = "Option::is_none")]
    pub sections_chosen: Option<Vec<String>>, // 고른 관심 분야(None = 아직 고르지 않음 → 첫 실행 고르기 화면)
    #[serde(rename = "sectionPolicy")]
    pub section_policy: HashMap<String, crate::notify_policy::SectionPolicy>, // 분야별 알림 모드·묶음 시각·하루 상한
    #[serde(rename = "hiddenSources")]
    pub hidden_sources: Vec<String>, // '이 출처 숨기기'
    pub pending: Vec<PendingItem>, // 고인 소식(묶음 시각에 한 방울로)
    #[serde(rename = "notifyLog")]
    pub notify_log: Vec<NotifyMark>, // 떨어뜨린 물방울 기록(하루 상한 계산)
    #[serde(rename = "notifiedStories")]
    pub notified_stories: HashMap<String, f64>, // 알린 스토리 → 시각(같은 이야기 한 번만)
    #[serde(rename = "lastBundle", with = "iso_map")]
    pub last_bundle: HashMap<String, DateTime<Utc>>, // 분야 → 마지막으로 묶음을 보낸 때
    pub briefs: HashMap<String, crate::brief::SectionBrief>, // 분야 → 마지막 저녁 정리(묶음 시각에 기기 안 요약, N-26)
    pub settings: Settings,
}

impl<'de> Deserialize<'de> for AppState {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let v = Value::deserialize(d)?;
        let Some(m) = v.as_object() else { return Ok(AppState::default()) };
        let read: HashMap<String, f64> = match m.get("read") {
            Some(Value::Object(_)) => field(m, "read").unwrap_or_default(),
            // 예전 형식(목록)
            Some(Value::Array(a)) => a.iter().filter_map(|x| x.as_str()).map(|k| (k.to_string(), 0.0)).collect(),
            _ => HashMap::new(),
        };
        Ok(AppState {
            seen: field(m, "seen").unwrap_or_default(),
            seeded: field(m, "seeded").unwrap_or_default(),
            enabled: field(m, "enabled").unwrap_or_default(),
            recent: list_field(m, "recent"),
            last_check: date_field(m, "lastCheck"),
            errors: field(m, "errors").unwrap_or_default(),
            unread: field(m, "unread").unwrap_or(0),
            unread_keys: field(m, "unreadKeys").unwrap_or_default(),
            read,
            saved: list_field(m, "saved"),
            custom_sources: list_field(m, "customSources"),
            snooze_until: date_field(m, "snoozeUntil"),
            last_digest: date_field(m, "lastDigest"),
            last_watch_digest: date_field(m, "lastWatchDigest"),
            interest_category: field(m, "interestCategory").unwrap_or_default(),
            interest_source: field(m, "interestSource").unwrap_or_default(),
            magazine_backfilled: field(m, "magazineBackfilled").unwrap_or(false),
            notify: field(m, "notify").unwrap_or_default(),
            followed_stories: field(m, "followedStories").unwrap_or_default(),
            story_seen: field(m, "storySeen").unwrap_or_default(),
            sections_chosen: field(m, "sectionsChosen"),
            section_policy: field(m, "sectionPolicy").unwrap_or_default(),
            hidden_sources: field(m, "hiddenSources").unwrap_or_default(),
            pending: list_field(m, "pending"),
            notify_log: list_field(m, "notifyLog"),
            notified_stories: field(m, "notifiedStories").unwrap_or_default(),
            last_bundle: m
                .get("lastBundle")
                .and_then(|v| v.as_object())
                .map(|o| o.iter().filter_map(|(k, v)| v.as_str().and_then(iso::parse).map(|d| (k.clone(), d))).collect())
                .unwrap_or_default(),
            briefs: m
                .get("briefs")
                .and_then(|v| v.as_object())
                .map(|o| o.iter().filter_map(|(k, v)| serde_json::from_value(v.clone()).ok().map(|b| (k.clone(), b))).collect())
                .unwrap_or_default(),
            settings: m.get("settings").and_then(|s| serde_json::from_value(s.clone()).ok()).unwrap_or_default(),
        })
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PendingItem {
    pub item: NewsItem,
    pub section: String,
    pub story: String, // 같은 이야기를 두 번 고이지 않게
    #[serde(with = "iso")]
    pub at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NotifyMark {
    pub section: String,
    #[serde(with = "iso")]
    pub at: DateTime<Utc>,
}

mod iso_map {
    use chrono::{DateTime, Utc};
    use serde::Serializer;
    use std::collections::HashMap;
    pub fn serialize<S: Serializer>(m: &HashMap<String, DateTime<Utc>>, s: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeMap;
        let mut map = s.serialize_map(Some(m.len()))?;
        for (k, v) in m {
            map.serialize_entry(k, &crate::iso::format(v))?;
        }
        map.end()
    }
}

// 읽은 상태를 쓸 수 있게 다듬는다(맥 Store.prepare).
// - 예전(AI 전용) 사용자: 분야를 고른 적이 없으면 'AI' 하나만 고른 것으로 옮기고, AI 는 예전처럼 즉시 알림.
// - 출처 켜기 기본값: 분야가 있는 출처는 그 분야를 골랐을 때만 기본으로 켠다(새로 생긴 국내 언론이 한꺼번에 켜지지 않게).
pub fn prepare(state: AppState, existing: bool, sources: &[Source], meta: &HashMap<String, crate::sections::SourceMeta>) -> AppState {
    use crate::notify_policy::{NotifyMode, SectionPolicy};
    let mut s = state;
    if s.sections_chosen.is_none() && existing {
        s.sections_chosen = Some(vec![crate::sections::AI.into()]);
        s.section_policy.insert(crate::sections::AI.into(), SectionPolicy::mode(NotifyMode::Instant));
    }
    let all: Vec<Source> = sources.iter().cloned().chain(s.custom_sources.clone()).collect();
    for src in all {
        if s.enabled.contains_key(&src.id) {
            continue;
        }
        let has_section = meta.get(&src.id).and_then(|m| m.section.clone());
        let on = match (crate::sections::section_of_source(&src.id, meta), has_section) {
            (Some(sec), Some(_)) => src.default_on && s.sections_chosen.as_ref().map(|c| c.contains(&sec)).unwrap_or(false),
            _ => src.default_on,
        };
        s.enabled.insert(src.id.clone(), on);
    }
    s
}

pub const SEEN_LIMIT: usize = 8000;

// 데이터 폴더: DROPCAP_DATA_DIR(시험용) → $XDG_DATA_HOME/dropcap → ~/.local/share/dropcap
pub static DIR: Lazy<PathBuf> = Lazy::new(|| {
    let d = data_dir_from_env();
    make_private_dir(&d);
    d
});

// 데이터 폴더는 이 사용자만(0700) — 읽은 기록·스크랩·설정이 같은 컴퓨터의 다른 사용자에게 보이지 않게(L7)
pub fn make_private_dir(d: &Path) {
    let _ = std::fs::create_dir_all(d);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(d, std::fs::Permissions::from_mode(0o700));
    }
}

pub fn data_dir_from_env() -> PathBuf {
    if let Ok(custom) = std::env::var("DROPCAP_DATA_DIR") {
        if !custom.is_empty() {
            return PathBuf::from(custom);
        }
    }
    if let Ok(x) = std::env::var("XDG_DATA_HOME") {
        if !x.is_empty() && Path::new(&x).is_absolute() {
            return PathBuf::from(x).join("dropcap");
        }
    }
    home_dir().join(".local/share/dropcap")
}

// 홈 폴더: $HOME, 없으면 운영체제 사용자 정보(공용 /tmp 로 떨어지지 않게)
pub fn home_dir() -> PathBuf {
    if let Ok(h) = std::env::var("HOME") {
        if !h.is_empty() {
            return PathBuf::from(h);
        }
    }
    unsafe {
        let pw = libc::getpwuid(libc::getuid());
        if !pw.is_null() && !(*pw).pw_dir.is_null() {
            return PathBuf::from(std::ffi::CStr::from_ptr((*pw).pw_dir).to_string_lossy().to_string());
        }
    }
    PathBuf::from(".")
}

pub struct Store {
    pub dir: PathBuf,
    backed_up: AtomicBool,
}

impl Store {
    pub fn new(dir: PathBuf) -> Store {
        make_private_dir(&dir);
        Store { dir, backed_up: AtomicBool::new(false) }
    }
    pub fn file(&self) -> PathBuf {
        self.dir.join("native-state.json")
    }
    pub fn exists(&self) -> bool {
        self.file().exists()
    }

    pub fn backup_file(&self) -> PathBuf {
        self.dir.join("native-state.bak.json")
    }

    pub fn load(&self) -> AppState {
        let (mut s, from_backup) = read_state(&self.file(), &self.backup_file());
        // 본 파일이 깨져 .bak 에서 읽었으면, 첫 저장 때 깨진 파일로 .bak 을 덮어쓰지 않게 한다
        if from_backup {
            self.backed_up.store(true, Ordering::SeqCst);
        }
        let existed = self.exists() || from_backup;
        s = prepare(s, existed, &CONFIG.sources, &crate::sections::META);
        s
    }

    pub fn save(&self, state: &AppState) {
        // 실행마다 첫 저장 전에 이전 파일을 .bak 으로 남긴다(형식이 바뀌어 일부를 못 읽었을 때 되살릴 수 있게)
        if self.exists() && !self.backed_up.swap(true, Ordering::SeqCst) {
            let bak = self.backup_file();
            let _ = std::fs::remove_file(&bak);
            let _ = std::fs::copy(self.file(), &bak);
        }
        let mut s = state.clone();
        trim_seen(&mut s.seen, SEEN_LIMIT);
        let Ok(data) = serde_json::to_vec(&s) else { return };
        let _ = write_atomic(&self.file(), &data);
    }
}

// 본 파일을 통째로 못 읽으면(깨짐) .bak 을 읽는다. 깨진 파일은 .broken.json 으로 남긴다. (상태, .bak 에서 읽었나)
pub fn read_state(file: &Path, backup: &Path) -> (AppState, bool) {
    let Ok(data) = std::fs::read(file) else { return (AppState::default(), false) }; // 처음 실행
    if let Ok(s) = serde_json::from_slice::<AppState>(&data) {
        return (s, false);
    }
    let broken = file.with_extension("broken.json");
    let _ = std::fs::remove_file(&broken);
    let _ = std::fs::copy(file, &broken);
    if let Some(s) = std::fs::read(backup).ok().and_then(|b| serde_json::from_slice::<AppState>(&b).ok()) {
        log::warn!("[상태] native-state.json 이 깨져 .bak 에서 되살렸습니다");
        return (s, true);
    }
    log::warn!("[상태] native-state.json 이 깨졌고 .bak 도 읽지 못해 새로 시작합니다");
    (AppState::default(), true)
}

// 본 글 기억은 오래된 것부터 정리해 limit 개만 남긴다(맥 Store.pruned)
pub fn pruned(seen: &HashMap<String, f64>, limit: usize) -> HashMap<String, f64> {
    let mut out = seen.clone();
    trim_seen(&mut out, limit);
    out
}

pub fn trim_seen(seen: &mut HashMap<String, f64>, limit: usize) {
    if seen.len() <= limit {
        return;
    }
    let mut v: Vec<(String, f64)> = seen.iter().map(|(k, v)| (k.clone(), *v)).collect();
    v.sort_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal));
    let drop = v.len() - limit;
    for (k, _) in v.into_iter().take(drop) {
        seen.remove(&k);
    }
}

// 원자적 쓰기: 같은 폴더의 임시 파일에 쓰고 fsync 뒤 이름 바꾸기
pub fn write_atomic(path: &Path, data: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let tmp = path.with_extension(format!("tmp-{}", std::process::id()));
    {
        let mut opts = std::fs::OpenOptions::new();
        opts.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            opts.mode(0o600); // 이 사용자만 읽기·쓰기(L7)
        }
        let mut f = opts.open(&tmp)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            f.set_permissions(std::fs::Permissions::from_mode(0o600))?; // 이미 있던 임시 파일도
        }
        f.write_all(data)?;
        f.sync_all()?;
    }
    std::fs::rename(&tmp, path)
}

// 화면 설정(맥 UserDefaults 에 해당): 글자 크기·정렬·글꼴·스크랩 폴더 등. prefs.json
#[derive(Debug, Clone, Serialize)]
pub struct Prefs {
    #[serde(rename = "readerFontSize")]
    pub reader_font_size: f64,
    #[serde(rename = "listSort")]
    pub list_sort: String,
    #[serde(rename = "magSort")]
    pub mag_sort: String,
    #[serde(rename = "usePretendard")]
    pub use_pretendard: bool,
    #[serde(rename = "scrapCollections")]
    pub scrap_collections: Vec<String>,
    #[serde(rename = "lastScrapCollection", skip_serializing_if = "Option::is_none")]
    pub last_scrap_collection: Option<String>,
    #[serde(rename = "launchAtLogin")]
    pub launch_at_login: bool,
    #[serde(rename = "storyRuleVersion")]
    pub story_rule_version: i64, // 같은 소식 판정 기준 버전(바뀌면 한 번 다시 묶음)
    #[serde(rename = "todayIssueDone", skip_serializing_if = "Option::is_none")]
    pub today_issue_done: Option<String>, // 오늘 호를 다 읽은 날(M-23)
    #[serde(rename = "scrapsCopyOff", skip_serializing_if = "std::ops::Not::not")]
    pub scraps_copy_off: bool, // 스크랩 사본(scraps.json) 끄기(M-17, 맥 scrapsCopyOff)
    #[serde(rename = "magRecentSearches", skip_serializing_if = "Vec::is_empty")]
    pub mag_recent_searches: Vec<String>, // 매거진 빈 검색 화면의 최근 검색어(맥 magRecentSearches, 8개)
}

impl Default for Prefs {
    fn default() -> Self {
        Prefs {
            reader_font_size: 17.0,
            list_sort: "newest".into(),
            mag_sort: "recommended".into(),
            use_pretendard: true,
            scrap_collections: vec![],
            last_scrap_collection: None,
            launch_at_login: false,
            story_rule_version: 0,
            today_issue_done: None,
            scraps_copy_off: false,
            mag_recent_searches: vec![],
        }
    }
}

impl<'de> Deserialize<'de> for Prefs {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let v = Value::deserialize(d)?;
        let Some(m) = v.as_object() else { return Ok(Prefs::default()) };
        let def = Prefs::default();
        Ok(Prefs {
            reader_font_size: field(m, "readerFontSize").unwrap_or(def.reader_font_size),
            list_sort: field(m, "listSort").unwrap_or(def.list_sort),
            mag_sort: field(m, "magSort").unwrap_or(def.mag_sort),
            use_pretendard: field(m, "usePretendard").unwrap_or(def.use_pretendard),
            scrap_collections: field(m, "scrapCollections").unwrap_or_default(),
            last_scrap_collection: field(m, "lastScrapCollection"),
            launch_at_login: field(m, "launchAtLogin").unwrap_or(false),
            story_rule_version: field(m, "storyRuleVersion").unwrap_or(0),
            today_issue_done: field(m, "todayIssueDone"),
            scraps_copy_off: field(m, "scrapsCopyOff").unwrap_or(false),
            mag_recent_searches: field::<Vec<String>>(m, "magRecentSearches").unwrap_or_default().into_iter().take(crate::magazine::RECENT_SEARCHES).collect(),
        })
    }
}

impl Prefs {
    pub fn load(dir: &Path) -> Prefs {
        std::fs::read(dir.join("prefs.json")).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default()
    }
    pub fn save(&self, dir: &Path) {
        if let Ok(d) = serde_json::to_vec_pretty(self) {
            let _ = write_atomic(&dir.join("prefs.json"), &d);
        }
    }
}
