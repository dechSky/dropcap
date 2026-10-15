// 스크랩 → 노트 폴더(Obsidian 보관소 등) 자동 저장(맥 Core/ScrapExport.swift).
// 켜 두면 스크랩이 바뀔 때마다 폴더별 `<고른 폴더>/<스크랩 폴더 이름>.md` 를 지금의 Markdown 내보내기 형식(scrapbook::render)으로
// 덮어쓴다(원자적 쓰기). 내용이 날짜 줄만 다르면 손대지 않는다(동기화 앱이 덜 바쁘게).
// 설정은 integrations.json(이 컴퓨터에만 — 맥도 폴더 북마크는 기기별). 예전 판은 이 파일을 모르고 지나치고,
// 없거나 깨졌으면 모두 꺼진 기본값(검색 제공자만 켜짐 — 맥 Spotlight 기본값과 같음).
use crate::scrapbook::{self, Scrap, DEFAULT_COLLECTION};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

pub const FILE: &str = "integrations.json";

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Config {
    #[serde(rename = "scrapExportEnabled", default)]
    pub enabled: bool,
    #[serde(rename = "scrapExportPath", default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    // 이 앱이 써 둔 파일 이름(폴더 이름이 바뀌거나 없어지면 예전 파일을 휴지통으로 보내려고)
    #[serde(rename = "scrapExportWritten", default)]
    pub written: Vec<String>,
    // 저장한 기사·스크랩을 데스크톱 검색(GNOME 검색·KRunner)에서 찾기(맥 indexSpotlight, 기본 켬)
    #[serde(rename = "searchProvider", default = "yes")]
    pub search: bool,
}

fn yes() -> bool {
    true
}

impl Default for Config {
    fn default() -> Self {
        Config { enabled: false, path: None, written: vec![], search: true }
    }
}

impl Config {
    pub fn load(dir: &Path) -> Config {
        std::fs::read(dir.join(FILE)).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default()
    }
    pub fn save(&self, dir: &Path) {
        if let Ok(d) = serde_json::to_vec_pretty(self) {
            let _ = crate::store::write_atomic(&dir.join(FILE), &d);
        }
    }
    pub fn folder(&self) -> Option<PathBuf> {
        self.path.as_ref().map(PathBuf::from)
    }
}

// 파일 이름으로 쓸 수 없는 글자(/ : 맨 앞 .)를 바꾸고 너무 길면 자른다
pub fn file_name(collection: &str) -> String {
    let mut n: String = collection.replace('/', "／").replace(':', "：").chars().filter(|c| !c.is_control()).collect();
    n = n.trim_start_matches('.').trim().to_string();
    if n.is_empty() {
        n = DEFAULT_COLLECTION.into();
    }
    n.chars().take(120).collect::<String>() + ".md"
}

// 머리의 날짜 줄만 다르면 같은 내용으로 본다
pub fn same_ignoring_date(a: &str, b: &str) -> bool {
    static DATE: once_cell::sync::Lazy<regex::Regex> =
        once_cell::sync::Lazy::new(|| regex::Regex::new(r"(?m)^_Dropcap 스크랩 · \d{4}-\d{2}-\d{2} · ").unwrap());
    DATE.replace_all(a, "_Dropcap 스크랩 · ") == DATE.replace_all(b, "_Dropcap 스크랩 · ")
}

#[derive(Debug, Default, PartialEq)]
pub struct Outcome {
    pub wrote: Vec<String>,   // 새로 쓰거나 고친 파일
    pub stale: Vec<PathBuf>,  // 이제 맞는 폴더가 없는 예전 파일(부르는 쪽이 휴지통으로)
    pub error: Option<String>,
}

// 폴더 하나에 맞춘다. config.written 을 이번에 쓴 목록으로 고친다(저장은 부르는 쪽).
pub fn sync(dir: &Path, scraps: &[Scrap], collections: &[String], config: &mut Config) -> Outcome {
    let mut out = Outcome::default();
    if !dir.is_dir() {
        out.error = Some("폴더를 찾지 못했습니다 — 다시 골라 주세요".into());
        return out;
    }
    let mut names = vec![];
    for c in collections {
        let list: Vec<Scrap> = scraps.iter().filter(|s| &s.collection == c).cloned().collect();
        let name = file_name(c);
        let file = dir.join(&name);
        // 비어 있는 폴더는, 전에 써 둔 파일이 있을 때만 비운 내용으로 덮는다(새 빈 파일을 만들지 않음)
        if list.is_empty() && !file.exists() {
            continue;
        }
        names.push(name.clone());
        let text = scrapbook::render(&list, c);
        if let Ok(old) = std::fs::read_to_string(&file) {
            if same_ignoring_date(&old, &text) {
                continue; // 바뀐 게 없으면 손대지 않음
            }
        }
        match write_atomic(&file, text.as_bytes()) {
            Ok(()) => out.wrote.push(name),
            Err(e) => out.error = Some(format!("쓰지 못했습니다: {e}")),
        }
    }
    // 이름이 바뀌었거나 없어진 폴더의 예전 파일(이 앱이 쓴 것만)
    for old in &config.written {
        if !names.contains(old) && collections.iter().all(|c| &file_name(c) != old) {
            let f = dir.join(old);
            if f.exists() {
                out.stale.push(f);
            }
        }
    }
    config.written = names;
    out
}

// 노트 파일은 보통 권한(0644 등, umask 따름)으로 — 같은 폴더의 임시 파일에 쓰고 이름 바꾸기
pub fn write_atomic(path: &Path, data: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    let tmp = path.with_file_name(format!(".{name}.tmp-{}", std::process::id()));
    {
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(data)?;
        f.sync_all()?;
    }
    std::fs::rename(&tmp, path).inspect_err(|_| {
        let _ = std::fs::remove_file(&tmp);
    })
}
