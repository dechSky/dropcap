// 스크랩: 기사 전체 또는 문단 하나를 메모와 함께 폴더(컬렉션)에 모아 둔다(맥 Core/Scrapbook.swift).
use crate::database::Database;
use crate::iso;
use crate::models::NewsItem;
use crate::store::Prefs;
use chrono::{DateTime, Local, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

pub const DEFAULT_COLLECTION: &str = "스크랩";

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Scrap {
    pub id: String,
    pub item: NewsItem,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub quote: Option<String>, // 문단 스크랩이면 그 문단(보이던 언어)
    #[serde(rename = "quoteOriginal", default, skip_serializing_if = "Option::is_none")]
    pub quote_original: Option<String>, // 번역문을 스크랩했으면 원문
    #[serde(default)]
    pub memo: String,
    pub collection: String,
    #[serde(with = "iso")]
    pub created: DateTime<Utc>,
}

impl Scrap {
    pub fn new(item: NewsItem, quote: Option<String>, original: Option<String>, memo: &str, collection: &str) -> Scrap {
        Scrap {
            id: uuid::Uuid::new_v4().to_string().to_uppercase(),
            item,
            quote,
            quote_original: original,
            memo: memo.into(),
            collection: collection.into(),
            created: Utc::now(),
        }
    }
}

// 스크랩 목록(최근 것이 앞)을 Markdown 으로. 기사별로 묶고, 인용·원문·메모를 함께.
pub fn render(list: &[Scrap], collection: &str) -> String {
    render_at(list, collection, Utc::now())
}

pub fn render_at(list: &[Scrap], collection: &str, now: DateTime<Utc>) -> String {
    let day = |d: DateTime<Utc>| d.with_timezone(&Local).format("%Y-%m-%d").to_string();
    let mut out = format!("# {collection}\n\n");
    out += &format!("_Dropcap 스크랩 · {} · {}건_\n\n", day(now), list.len());
    // 기사별로 묶어서(오래된 것부터)
    let mut order: Vec<String> = vec![];
    let mut groups: HashMap<String, Vec<&Scrap>> = HashMap::new();
    for s in list.iter().rev() {
        let k = s.item.key();
        if !groups.contains_key(&k) {
            order.push(k.clone());
        }
        groups.entry(k).or_default().push(s);
    }
    for key in order {
        let Some(g) = groups.get(&key) else { continue };
        let it = &g[0].item;
        out += &format!("## [{}]({})\n\n", it.display_title(), it.link);
        let mut meta = it.source_name.clone();
        if let Some(d) = it.date {
            meta += &format!(" · {}", day(d));
        }
        if it.title_ko.is_some() && it.title_ko.as_deref() != Some(it.title.as_str()) {
            meta += &format!(" · 원제: {}", it.title);
        }
        out += &format!("{meta}\n\n");
        for s in g {
            if let Some(q) = &s.quote {
                out += &format!("> {}\n", q.replace('\n', "\n> "));
                if let Some(o) = &s.quote_original {
                    if o != q {
                        out += &format!(">\n> _{o}_\n");
                    }
                }
                out += "\n";
            }
            if !s.memo.is_empty() {
                out += &format!("- 메모: {}\n\n", s.memo);
            }
        }
    }
    out
}

// MARK: JSON 사본(scraps.json) — 맥 Scrapbook.writeCopy 와 같은 모양
// 스크랩은 매거진 DB 안에 있어, DB 가 통째로 못 읽히면 함께 사라졌다(맥 E2E 12-다). 바뀔 때마다 전부를 사본으로 원자적으로 쓴다.
// - 예전 판(사본 없음): 첫 실행의 reload 가 DB 내용으로 사본을 만든다.
// - 되돌리기: 예전 판은 이 파일을 모르고 무시한다. 끄기: prefs.json 의 scrapsCopyOff = true.
// - 기기 이동: 데이터 폴더에 함께 있어 폴더째 옮기면 따라간다.
#[derive(Serialize, Deserialize)]
struct Copy {
    version: i64,
    scraps: Vec<Scrap>,
}

pub fn copy_file(dir: &std::path::Path) -> PathBuf {
    dir.join("scraps.json")
}

pub fn read_copy(file: &std::path::Path) -> Option<Vec<Scrap>> {
    let d = std::fs::read(file).ok()?;
    serde_json::from_slice::<Copy>(&d).ok().map(|c| c.scraps)
}

pub fn write_copy(list: &[Scrap], file: &std::path::Path) {
    if let Ok(d) = serde_json::to_vec(&Copy { version: 1, scraps: list.to_vec() }) {
        let _ = crate::store::write_atomic(file, &d);
    }
}

// 사본에 있고 DB 에 없는 스크랩(같은 id 는 DB 쪽을 그대로 둠)
pub fn restore_list(db: &[Scrap], copy: &[Scrap]) -> Vec<Scrap> {
    let have: std::collections::HashSet<&str> = db.iter().map(|s| s.id.as_str()).collect();
    copy.iter().filter(|s| !have.contains(s.id.as_str())).cloned().collect()
}

// 화면이 쓰는 스크랩북(폴더 목록·마지막 폴더는 prefs.json 에)
pub struct Scrapbook {
    db: Arc<Database>,
    dir: PathBuf,
    pub scraps: Vec<Scrap>,
    pub collections: Vec<String>,
}

impl Scrapbook {
    pub fn new(db: Arc<Database>, dir: PathBuf) -> Scrapbook {
        let mut s = Scrapbook { db, dir, scraps: vec![], collections: vec![] };
        s.restore_from_copy_if_needed();
        s.reload();
        s
    }

    // DB 를 새로 만들었거나(깨짐·삭제) 기사도 하나 없는 빈 DB 인데 사본에 있으면 사본에서 되살린다.
    // 평소에 사용자가 다 지운 것은 되살리지 않는다.
    fn restore_from_copy_if_needed(&mut self) {
        if Prefs::load(&self.dir).scraps_copy_off {
            return;
        }
        let Some(copy) = read_copy(&copy_file(&self.dir)).filter(|c| !c.is_empty()) else { return };
        let in_db = self.db.scraps(None);
        if !(self.db.recreated || (in_db.is_empty() && self.db.item_count() == 0)) {
            return;
        }
        let missing = restore_list(&in_db, &copy);
        for s in &missing {
            self.db.save_scrap(s);
        }
        if !missing.is_empty() {
            log::warn!("[스크랩] 사본(scraps.json)에서 {}개를 되살렸습니다", missing.len());
        }
    }

    fn write_copy(&self) {
        if Prefs::load(&self.dir).scraps_copy_off {
            return;
        }
        // DB 가 깨져 새로 만들었는데 아무것도 못 건졌으면, 그 빈 목록으로 사본을 덮지 않는다
        if self.scraps.is_empty() && self.db.recreated {
            return;
        }
        write_copy(&self.scraps, &copy_file(&self.dir));
    }

    pub fn reload(&mut self) {
        self.scraps = self.db.scraps(None);
        self.write_copy();
        let prefs = Prefs::load(&self.dir);
        let mut used: Vec<String> = self.scraps.iter().map(|s| s.collection.clone()).collect();
        used.sort();
        used.dedup();
        let extra: Vec<String> = prefs.scrap_collections.into_iter().filter(|c| !used.contains(c)).collect();
        let mut out: Vec<String> = vec![];
        for c in std::iter::once(DEFAULT_COLLECTION.to_string()).chain(used).chain(extra) {
            if !out.contains(&c) {
                out.push(c);
            }
        }
        self.collections = out;
    }

    pub fn last_collection(&self) -> String {
        Prefs::load(&self.dir).last_scrap_collection.unwrap_or_else(|| DEFAULT_COLLECTION.into())
    }

    // 새로 넣었으면 true(지식 물병 2방울은 부르는 쪽이 더한다)
    pub fn add(&mut self, item: &NewsItem, quote: Option<String>, original: Option<String>, memo: &str, collection: Option<&str>) -> bool {
        let mut c = collection.map(|s| s.to_string()).unwrap_or_else(|| self.last_collection()).trim().to_string();
        if c.is_empty() {
            c = DEFAULT_COLLECTION.into(); // 이름 없는 폴더는 만들지 않음
        }
        // 같은 문단을 두 번 스크랩하지 않게
        let key = item.key();
        if self.scraps.iter().any(|s| s.item.key() == key && s.quote == quote && s.collection == c) {
            return false;
        }
        self.db.save_scrap(&Scrap::new(item.clone(), quote, original, memo, &c));
        let mut p = Prefs::load(&self.dir);
        p.last_scrap_collection = Some(c);
        p.save(&self.dir);
        self.reload();
        true
    }

    pub fn update(&mut self, s: &Scrap) {
        self.db.save_scrap(s);
        self.reload();
    }

    pub fn remove(&mut self, id: &str) {
        self.db.delete_scrap(id);
        self.reload();
    }

    pub fn create_collection(&mut self, name: &str) -> bool {
        let n = name.trim();
        if n.is_empty() || self.collections.iter().any(|c| c == n) {
            return false;
        }
        let mut p = Prefs::load(&self.dir);
        p.scrap_collections.push(n.to_string());
        p.save(&self.dir);
        self.reload();
        true
    }

    pub fn rename(&mut self, from: &str, to: &str) -> bool {
        let n = to.trim();
        if n.is_empty() || n == from || self.collections.iter().any(|c| c == n) {
            return false;
        }
        self.db.rename_collection(from, n);
        let mut p = Prefs::load(&self.dir);
        p.scrap_collections = p.scrap_collections.into_iter().map(|c| if c == from { n.to_string() } else { c }).collect();
        if p.last_scrap_collection.as_deref() == Some(from) {
            p.last_scrap_collection = Some(n.to_string());
        }
        p.save(&self.dir);
        self.reload();
        true
    }

    pub fn is_scrapped(&self, item: &NewsItem, quote: Option<&str>) -> bool {
        let key = item.key();
        self.scraps.iter().any(|s| s.item.key() == key && (quote.is_none() || s.quote.as_deref() == quote))
    }

    pub fn markdown(&self, collection: &str) -> String {
        let list: Vec<Scrap> = self.scraps.iter().filter(|s| s.collection == collection).cloned().collect();
        render(&list, collection)
    }
}
