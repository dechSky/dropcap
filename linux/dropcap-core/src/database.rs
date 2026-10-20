// 매거진 기록 저장소: magazine.sqlite (맥 Core/Database.swift 와 같은 표·열·JSON).
// 이 파일이 없거나 깨져도 알림 기능은 그대로 돈다(지우면 처음부터 다시 쌓임).
use crate::archive::{ArchivedItem, Visibility};
use crate::magazine::Issue;
use crate::models::{ItemKind, NewsItem};
use crate::scrapbook::Scrap;
use chrono::{DateTime, TimeZone, Utc};
use rusqlite::{params, Connection, OptionalExtension};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;

pub const SCHEMA_VERSION: i32 = 1;
pub const KEEP_ITEMS: i64 = 20000;
// 다른 연결이 잠깐 잠갔을 때 바로 실패하지 않고 기다리는 시간(맥 Database.busyTimeoutMs)
pub const BUSY_TIMEOUT_MS: u64 = 3000;

#[derive(Debug, Clone)]
pub struct StoredItem {
    pub item: NewsItem,
    pub first_seen: DateTime<Utc>,
    pub cluster: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Cluster {
    pub id: String,
    pub title: String,
    pub tokens: HashSet<String>,
    pub first: DateTime<Utc>,
    pub last: DateTime<Utc>,
    pub size: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KindFilter {
    All,
    Articles,
    Channels,
}

#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct ExtractStat {
    pub tries: i64,
    pub fails: i64,
    pub blocked: i64,
}

impl ExtractStat {
    pub fn fail_rate(&self) -> f64 {
        if self.tries == 0 {
            0.0
        } else {
            (self.fails + self.blocked) as f64 / self.tries as f64
        }
    }
}

pub struct Database {
    conn: Mutex<Connection>,
    pub file: PathBuf,
    pub recreated: bool,        // 이번 실행에서 깨진 파일을 치우고 새로 만들었는가
    pub salvaged_scraps: usize, // 그때 깨진 파일에서 건진 스크랩 수
    statements: AtomicUsize,    // 시험용: 실행한 읽기 문장 수(화면 하나에 DB 를 몇 번 묻는지)
}

// 스토리 카드에 꺼내는 보도 수: 출처마다 첫 보도 + 최근 이만큼(보도가 수천 건인 스토리도 목록을 만들 때 전부 풀지 않게)
pub const STORY_SAMPLE: i64 = 40;

fn ts(d: DateTime<Utc>) -> f64 {
    d.timestamp_millis() as f64 / 1000.0
}

pub fn from_ts(t: f64) -> DateTime<Utc> {
    Utc.timestamp_millis_opt((t * 1000.0) as i64).single().unwrap_or(DateTime::<Utc>::MIN_UTC)
}

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS items(
  key TEXT PRIMARY KEY, json TEXT NOT NULL, date REAL, first_seen REAL NOT NULL,
  category TEXT, source TEXT, tier TEXT, cluster TEXT, image TEXT);
CREATE INDEX IF NOT EXISTS items_date ON items(date);
CREATE INDEX IF NOT EXISTS items_cluster ON items(cluster);
CREATE TABLE IF NOT EXISTS clusters(
  id TEXT PRIMARY KEY, title TEXT NOT NULL, tokens TEXT NOT NULL, first REAL NOT NULL, last REAL NOT NULL, size INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS clusters_last ON clusters(last);
CREATE TABLE IF NOT EXISTS issues(
  id TEXT PRIMARY KEY, kind TEXT NOT NULL, created REAL NOT NULL, json TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS scraps(
  id TEXT PRIMARY KEY, collection TEXT NOT NULL, created REAL NOT NULL, json TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS scraps_collection ON scraps(collection, created);
CREATE TABLE IF NOT EXISTS extract_stats(
  source TEXT PRIMARY KEY, tries INTEGER NOT NULL, fails INTEGER NOT NULL, blocked INTEGER NOT NULL, updated REAL NOT NULL);
CREATE TABLE IF NOT EXISTS teasers(
  link TEXT PRIMARY KEY, updated REAL NOT NULL);
CREATE TABLE IF NOT EXISTS image_scores(
  url TEXT PRIMARY KEY, score REAL NOT NULL, text REAL NOT NULL, colors REAL NOT NULL, flat REAL NOT NULL, updated REAL NOT NULL);
CREATE TABLE IF NOT EXISTS archive(
  date REAL NOT NULL, title TEXT NOT NULL, title_ko TEXT, link TEXT NOT NULL, source TEXT, source_id TEXT, section TEXT, story TEXT);
";

// 보관 표 손보기: 출처 id 칸이 없던 표에는 더하고(예전 줄은 NULL — 이름으로 거름), 색인은 출처 id 까지 담은 것으로 바꾼다
fn migrate_archive(c: &Connection) -> rusqlite::Result<()> {
    let has_id = {
        let mut st = c.prepare("PRAGMA table_info(archive)")?;
        let cols = st.query_map([], |r| r.get::<_, String>(1))?.collect::<rusqlite::Result<Vec<_>>>()?;
        cols.iter().any(|n| n == "source_id")
    };
    if !has_id {
        c.execute_batch("ALTER TABLE archive ADD COLUMN source_id TEXT;")?;
    }
    c.execute_batch(
        "DROP INDEX IF EXISTS archive_date;
         CREATE INDEX IF NOT EXISTS archive_date_src ON archive(date, section, source, source_id);",
    )
}

const ARCHIVE_COLUMNS: &str = "date, title, title_ko, link, source, section, story, source_id";

// 분야·출처 거르기(None 이면 모두) + 보일 출처(숨긴·끈 출처 빼기)
fn archive_filter(section: Option<&str>, source: Option<&str>, vis: &Visibility) -> (String, Vec<Option<String>>) {
    let (mut sql, mut args) = (String::new(), vec![]);
    if let Some(s) = section {
        sql += " AND section = ?";
        args.push(Some(s.to_string()));
    }
    if let Some(s) = source {
        sql += " AND source = ?";
        args.push(Some(s.to_string()));
    }
    sql += Visibility::SQL;
    args.extend(vis.sql_args());
    (sql, args)
}

pub const TEASER_LIFE_SECS: i64 = 30 * 24 * 3600;
pub const TEASER_LIMIT: usize = 2000;

impl Database {
    pub fn open(dir: &Path) -> Database {
        Self::open_with_busy(dir, BUSY_TIMEOUT_MS)
    }

    // busy_ms 는 시험에서만 줄인다
    pub fn open_with_busy(dir: &Path, busy_ms: u64) -> Database {
        let file = dir.join("magazine.sqlite");
        let mut recreated = false;
        let conn = match Self::try_open(&file) {
            Ok(c) => c,
            Err(e) => {
                recreated = true;
                log::warn!("[DB] 열기 실패, 새로 만듭니다: {e}");
                // 남은 WAL 이 새 파일에 섞이지 않게 -wal·-shm 도 함께 치운다
                for ext in ["", "-wal", "-shm"] {
                    let from = dir.join(format!("magazine.sqlite{ext}"));
                    let broken = dir.join(format!("magazine.broken.sqlite{ext}"));
                    let _ = std::fs::remove_file(&broken);
                    let _ = std::fs::rename(&from, &broken);
                }
                Self::try_open(&file).unwrap_or_else(|_| Connection::open_in_memory().expect("메모리 DB"))
            }
        };
        let _ = conn.execute_batch(SCHEMA);
        if let Err(e) = migrate_archive(&conn) {
            log::warn!("[DB] 보관 표 손보기 실패: {e}");
        }
        let _ = conn.execute_batch(&format!("PRAGMA user_version={SCHEMA_VERSION};"));
        let _ = conn.busy_timeout(std::time::Duration::from_millis(busy_ms));
        let mut db = Database { conn: Mutex::new(conn), file, recreated, salvaged_scraps: 0, statements: AtomicUsize::new(0) };
        if recreated {
            // 스크랩은 사용자가 만든 것이라 다시 쌓이지 않는다 → 치운 파일에서 읽을 수 있는 만큼 옮겨 온다
            db.salvaged_scraps = db.import_scraps(&dir.join("magazine.broken.sqlite"));
            if db.salvaged_scraps > 0 {
                log::warn!("[DB] 깨진 파일에서 스크랩 {}개를 옮겨 왔습니다", db.salvaged_scraps);
            }
        }
        db
    }

    // 다른(깨진·치운) DB 파일의 scraps 표를 읽기 전용으로 열어, 읽히는 줄까지 이 DB 로 옮긴다. 시험·손 복구에도 쓴다.
    pub fn import_scraps(&self, other: &Path) -> usize {
        let Ok(old) = Connection::open_with_flags(other, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY) else { return 0 };
        let Ok(mut st) = old.prepare("SELECT id, collection, created, json FROM scraps") else { return 0 };
        let Ok(mut rows) = st.query([]) else { return 0 };
        let c = self.conn.lock().unwrap();
        let mut n = 0;
        // 중간에 깨진 쪽을 만나면 거기까지
        while let Ok(Some(r)) = rows.next() {
            let (Ok(id), Ok(json)) = (r.get::<_, String>(0), r.get::<_, String>(3)) else { continue };
            if serde_json::from_str::<Scrap>(&json).is_err() {
                continue;
            }
            let col: Option<String> = r.get(1).ok();
            let created: f64 = r.get(2).unwrap_or(0.0);
            let _ = c.execute("INSERT OR IGNORE INTO scraps(id,collection,created,json) VALUES(?,?,?,?)", params![id, col, created, json]);
            n += 1;
        }
        n
    }

    fn try_open(file: &Path) -> rusqlite::Result<Connection> {
        let c = Connection::open(file)?;
        // 깨진 파일은 여기서 걸러진다
        c.query_row("PRAGMA journal_mode=WAL", [], |_| Ok(()))?;
        c.execute_batch("PRAGMA synchronous=NORMAL;")?;
        c.execute_batch(SCHEMA)?;
        Ok(c)
    }

    pub fn in_memory() -> Database {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(SCHEMA).unwrap();
        migrate_archive(&conn).unwrap();
        Database { conn: Mutex::new(conn), file: PathBuf::from(":memory:"), recreated: false, salvaged_scraps: 0, statements: AtomicUsize::new(0) }
    }

    // 시험용: 지금까지 실행한 읽기 문장 수
    pub fn statements(&self) -> usize {
        self.statements.load(Ordering::Relaxed)
    }

    // MARK: 기사
    // 넣었으면 true. 잠김(기다림 상한을 넘김)·디스크 가득 등으로 못 넣으면 false — 부르는 쪽이 다음에 다시 넣게
    pub fn upsert(&self, item: &NewsItem, cluster: Option<&str>, first_seen: DateTime<Utc>) -> bool {
        let Ok(json) = serde_json::to_string(item) else { return false };
        // 논문 피드(arXiv)는 날짜가 발표일 자정이라, 지면에는 받은 때를 기준으로 싣는다
        let when = if item.item_kind() == ItemKind::Paper { Some(first_seen) } else { item.date };
        let c = self.conn.lock().unwrap();
        let r = c.execute(
            "INSERT INTO items(key,json,date,first_seen,category,source,tier,cluster,image) VALUES(?,?,?,?,?,?,?,?,?)
             ON CONFLICT(key) DO UPDATE SET json=excluded.json, date=COALESCE(items.date, excluded.date),
               category=excluded.category, cluster=COALESCE(excluded.cluster, items.cluster), image=COALESCE(excluded.image, items.image)",
            params![item.key(), json, when.map(ts), ts(first_seen), item.category().raw(), item.source_id, item.tier, cluster, item.image],
        );
        if let Err(e) = &r {
            log::warn!("[DB] 기사 넣기 실패: {e}"); // 잠김·디스크 가득 등
        }
        r.is_ok()
    }

    pub fn set_image(&self, key: &str, url: &str) {
        let c = self.conn.lock().unwrap();
        let _ = c.execute("UPDATE items SET image=?, json=json_set(json,'$.image',?) WHERE key=?", params![url, url, key]);
    }

    pub fn exists(&self, key: &str) -> bool {
        let c = self.conn.lock().unwrap();
        c.query_row("SELECT 1 FROM items WHERE key=?", [key], |_| Ok(())).optional().ok().flatten().is_some()
    }

    // 이미 있는 key 들(400개씩 한 번에 — 매거진 채우기 전 거르기)
    pub fn existing(&self, keys: &[String]) -> std::collections::HashSet<String> {
        let mut out = std::collections::HashSet::new();
        let c = self.conn.lock().unwrap();
        for chunk in keys.chunks(400) {
            let q = vec!["?"; chunk.len()].join(",");
            let p: Vec<&dyn rusqlite::ToSql> = chunk.iter().map(|k| k as &dyn rusqlite::ToSql).collect();
            let Ok(mut st) = c.prepare(&format!("SELECT key FROM items WHERE key IN ({q})")) else { continue };
            let found: Vec<String> = match st.query_map(p.as_slice(), |r| r.get::<_, String>(0)) {
                Ok(rows) => rows.flatten().collect(),
                Err(_) => vec![],
            };
            out.extend(found);
        }
        out
    }

    // 기사 날짜(없으면 처음 본 때)가 [from, to) 안인 기사 수(빈 날 호를 엮기 전에 — 기사를 다 꺼내지 않고)
    pub fn article_count(&self, from: DateTime<Utc>, to: DateTime<Utc>) -> i64 {
        let c = self.conn.lock().unwrap();
        c.query_row(
            "SELECT COUNT(*) FROM items WHERE COALESCE(date, first_seen) >= ? AND COALESCE(date, first_seen) < ?
               AND COALESCE(json_extract(json,'$.kind'),'article') = 'article'",
            params![ts(from), ts(to)],
            |r| r.get(0),
        )
        .unwrap_or(0)
    }

    fn stored_rows(&self, sql: &str, p: &[&dyn rusqlite::ToSql]) -> Vec<StoredItem> {
        self.statements.fetch_add(1, Ordering::Relaxed);
        let c = self.conn.lock().unwrap();
        let Ok(mut st) = c.prepare(sql) else { return vec![] };
        let rows = st.query_map(p, |r| Ok((r.get::<_, String>(0)?, r.get::<_, f64>(1)?, r.get::<_, Option<String>>(2)?)));
        let Ok(rows) = rows else { return vec![] };
        rows.flatten()
            .filter_map(|(j, f, cl)| serde_json::from_str::<NewsItem>(&j).ok().map(|item| StoredItem { item, first_seen: from_ts(f), cluster: cl }))
            .collect()
    }

    // 기사 날짜(없으면 처음 본 때)가 [from, to) 안인 것
    pub fn items(&self, from: DateTime<Utc>, to: Option<DateTime<Utc>>, limit: i64) -> Vec<StoredItem> {
        self.items_kind(from, to, limit, KindFilter::All)
    }

    // 기사만(논문·릴리스 등 구독 채널 글 제외) 또는 그 반대
    pub fn items_kind(&self, from: DateTime<Utc>, to: Option<DateTime<Utc>>, limit: i64, kind: KindFilter) -> Vec<StoredItem> {
        let to = to.map(ts).unwrap_or(4e10).min(4e10);
        let k = match kind {
            KindFilter::All => "",
            KindFilter::Articles => "AND COALESCE(json_extract(json,'$.kind'),'article') = 'article'",
            KindFilter::Channels => "AND COALESCE(json_extract(json,'$.kind'),'article') != 'article'",
        };
        self.stored_rows(
            &format!(
                "SELECT json, first_seen, cluster FROM items
                 WHERE COALESCE(date, first_seen) >= ? AND COALESCE(date, first_seen) < ? {k}
                 ORDER BY COALESCE(date, first_seen) DESC LIMIT ?"
            ),
            &[&ts(from), &to, &limit],
        )
    }

    // key 로 바로 꺼내기(호 그리기·표지 찾기)
    pub fn items_by_keys(&self, keys: &[String]) -> Vec<StoredItem> {
        let mut out = vec![];
        for chunk in keys.chunks(400) {
            let q = vec!["?"; chunk.len()].join(",");
            let p: Vec<&dyn rusqlite::ToSql> = chunk.iter().map(|k| k as &dyn rusqlite::ToSql).collect();
            out.extend(self.stored_rows(&format!("SELECT json, first_seen, cluster FROM items WHERE key IN ({q})"), &p));
        }
        out
    }

    // 매거진이 받아 둔 기사 대표 사진(피드에 없어 기사 머리에서 찾은 것 포함)
    pub fn image(&self, key: &str) -> Option<String> {
        let c = self.conn.lock().unwrap();
        c.query_row("SELECT image FROM items WHERE key=?", [key], |r| r.get::<_, Option<String>>(0)).optional().ok().flatten().flatten()
    }

    // 다시 묶기: 이 시각 뒤의 기사들의 스토리를 비우고 그 스토리들을 지운다
    pub fn reset_clusters(&self, since: DateTime<Utc>) {
        let c = self.conn.lock().unwrap();
        let _ = c.execute(
            "DELETE FROM clusters WHERE id IN (SELECT DISTINCT cluster FROM items WHERE cluster IS NOT NULL AND COALESCE(date, first_seen) >= ?)",
            [ts(since)],
        );
        let _ = c.execute("UPDATE items SET cluster=NULL WHERE COALESCE(date, first_seen) >= ?", [ts(since)]);
    }

    pub fn set_cluster(&self, key: &str, cluster: Option<&str>) {
        let c = self.conn.lock().unwrap();
        let _ = c.execute("UPDATE items SET cluster=? WHERE key=?", params![cluster, key]);
    }

    // 기사마다 몇 곳이 다뤘나(스토리 크기)
    pub fn coverage(&self, keys: &[String]) -> std::collections::HashMap<String, i64> {
        let mut out = std::collections::HashMap::new();
        let c = self.conn.lock().unwrap();
        for chunk in keys.chunks(400) {
            let q = vec!["?"; chunk.len()].join(",");
            let sql = format!("SELECT items.key, clusters.size FROM items JOIN clusters ON clusters.id = items.cluster WHERE items.key IN ({q})");
            let Ok(mut st) = c.prepare(&sql) else { continue };
            let p: Vec<&dyn rusqlite::ToSql> = chunk.iter().map(|k| k as &dyn rusqlite::ToSql).collect();
            let rows: Vec<(String, i64)> = match st.query_map(p.as_slice(), |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?))) {
                Ok(rows) => rows.flatten().collect(),
                Err(_) => vec![],
            };
            out.extend(rows);
        }
        out
    }

    pub fn cluster_of(&self, key: &str) -> Option<String> {
        let c = self.conn.lock().unwrap();
        c.query_row("SELECT cluster FROM items WHERE key=?", [key], |r| r.get::<_, Option<String>>(0)).optional().ok().flatten().flatten()
    }

    pub fn items_in_cluster(&self, id: &str) -> Vec<StoredItem> {
        self.stored_rows("SELECT json, first_seen, cluster FROM items WHERE cluster=? ORDER BY COALESCE(date, first_seen) ASC", &[&id])
    }

    pub fn search(&self, q: &str, limit: i64) -> Vec<NewsItem> {
        let pat = format!("%{}%", q.replace('%', "\\%").replace('_', "\\_"));
        let c = self.conn.lock().unwrap();
        // 제목·한국어 제목·출처·요약에서만(JSON 의 필드 이름이나 주소에 걸리지 않게)
        let Ok(mut st) = c.prepare(
            "SELECT json FROM items WHERE
               json_extract(json,'$.title') LIKE ?1 ESCAPE '\\' OR json_extract(json,'$.titleKo') LIKE ?1 ESCAPE '\\'
               OR json_extract(json,'$.sourceName') LIKE ?1 ESCAPE '\\' OR json_extract(json,'$.summary') LIKE ?1 ESCAPE '\\'
             ORDER BY COALESCE(date, first_seen) DESC LIMIT ?2",
        ) else {
            return vec![];
        };
        let Ok(rows) = st.query_map(params![pat, limit], |r| r.get::<_, String>(0)) else { return vec![] };
        rows.flatten().filter_map(|j| serde_json::from_str(&j).ok()).collect()
    }

    pub fn item_count(&self) -> i64 {
        let c = self.conn.lock().unwrap();
        c.query_row("SELECT COUNT(*) FROM items", [], |r| r.get(0)).unwrap_or(0)
    }

    // 오래된 기록 정리(최근 keep 건 유지). 지우는 기사는 같은 트랜잭션에서 보관 표(archive)로 옮긴다 — 날짜·제목·링크·출처·분야만
    // (사진·요약·본문은 버림, 링크로 원문을 연다). 보관 표는 archive_years 년이 지난 달부터 지운다(0 이면 지우지 않음).
    // 옮기지 못하면(잠김·디스크 가득) 아무것도 지우지 않는다. 옮긴 건수를 돌려준다.
    pub fn prune(&self, keep: i64, archive_years: i64, now: DateTime<Utc>, section: &dyn Fn(&NewsItem) -> String) -> i64 {
        self.prune_capped(keep, archive_years, now, section, crate::archive::MAX_ROWS)
    }

    // prune 과 같고 보관 표 상한(max_rows)만 정해 준다(시험용)
    pub fn prune_capped(&self, keep: i64, archive_years: i64, now: DateTime<Utc>, section: &dyn Fn(&NewsItem) -> String, max_rows: i64) -> i64 {
        let mut c = self.conn.lock().unwrap();
        let Ok(tx) = c.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate) else { return 0 };
        type Row = (String, f64, Option<String>, Option<String>, Option<String>, Option<String>, Option<String>, Option<String>, Option<String>, Option<String>);
        let run = |tx: &rusqlite::Transaction| -> rusqlite::Result<i64> {
            let mut moved = 0;
            // 넘친 것이 없으면(확인 대부분) 정렬 질의를 건너뛴다
            let count: i64 = tx.query_row("SELECT COUNT(*) FROM items", [], |r| r.get(0))?;
            if count > keep {
                // 넘친 기사를 칸만 꺼낸다(본문 JSON 을 통째로 풀지 않음). 읽지 못하면 아무것도 지우지 않는다(되돌림)
                let rows: Vec<Row> = {
                    let mut st = tx.prepare(
                        "SELECT i.key, COALESCE(i.date, i.first_seen), json_extract(i.json,'$.title'), json_extract(i.json,'$.titleKo'),
                                json_extract(i.json,'$.link'), json_extract(i.json,'$.sourceName'), COALESCE(json_extract(i.json,'$.sourceId'), i.source),
                                json_extract(i.json,'$.summary'), json_extract(i.json,'$.id'), CASE WHEN c.size >= 2 THEN i.cluster END
                         FROM items i LEFT JOIN clusters c ON c.id = i.cluster
                         WHERE i.key IN (SELECT key FROM items ORDER BY COALESCE(date, first_seen) DESC LIMIT -1 OFFSET ?)",
                    )?;
                    let rows = st.query_map([keep], |r| {
                        Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?, r.get(6)?, r.get(7)?, r.get(8)?, r.get(9)?))
                    })?;
                    rows.collect::<rusqlite::Result<_>>()?
                };
                let mut done: Vec<String> = vec![]; // 보관 표에 넣었거나 이미 있던 기사(이것만 items 에서 지운다)
                let mut broken: Vec<(String, f64)> = vec![]; // 제목·링크를 읽지 못한(없거나 빈) 줄
                {
                    let mut ins = tx.prepare(
                        "INSERT INTO archive(date,title,title_ko,link,source,source_id,section,story) SELECT ?1,?2,?3,?4,?5,?6,?7,?8
                         WHERE NOT EXISTS (SELECT 1 FROM archive WHERE date = ?1 AND link = ?4)",
                    )?;
                    for (key, when, title, title_ko, link, source_name, source_id, summary, id, story) in rows {
                        // 제목·링크가 없는 줄은 옮기지 않는다(아래에서 오래됐거나 많을 때만 지움)
                        let (Some(title), Some(link)) = (title.filter(|t| !t.is_empty()), link.filter(|l| !l.is_empty())) else {
                            broken.push((key, when));
                            continue;
                        };
                        let sid = source_id.unwrap_or_default();
                        let mut it = NewsItem::new(&id.unwrap_or_default(), &title, &link, &sid, &source_name.unwrap_or_default(), "");
                        it.title_ko = title_ko;
                        it.summary = summary.unwrap_or_default();
                        // 같은 날짜·링크가 이미 있으면 다시 넣지 않는다(지운 뒤 다시 받은 기사)
                        let sid = (!sid.is_empty()).then_some(sid);
                        moved += ins.execute(params![when, it.title, it.title_ko, it.link, it.source_name, sid, section(&it), story])? as i64;
                        done.push(key);
                    }
                }
                // 읽지 못한 줄은 남기되 30일이 지났거나 최신 BROKEN_KEEP 건 밖이면 지운다(남은 줄 때문에 매번 정렬 질의가 돌지 않게)
                let stale = ts(now) - crate::archive::BROKEN_LIFE_SECS as f64;
                broken.sort_by(|a, b| b.1.total_cmp(&a.1));
                done.extend(broken.into_iter().enumerate().filter(|(i, (_, w))| *i >= crate::archive::BROKEN_KEEP || *w < stale).map(|(_, (k, _))| k));
                for chunk in done.chunks(400) {
                    let q = vec!["?"; chunk.len()].join(",");
                    tx.execute(&format!("DELETE FROM items WHERE key IN ({q})"), rusqlite::params_from_iter(chunk.iter()))?;
                }
            }
            tx.execute("DELETE FROM clusters WHERE id NOT IN (SELECT DISTINCT cluster FROM items WHERE cluster IS NOT NULL)", [])?;
            if let Some(cut) = crate::archive::cutoff(archive_years, now) {
                tx.execute("DELETE FROM archive WHERE date < ?", [ts(cut)])?;
            }
            // 보관 기간과 상관없는 상한: 넘으면 가장 오래된 것부터(상한 번째 줄의 날짜보다 이른 것을 지워 꼭 상한만큼 남긴다).
            // 큰 표에선 색인을 상한만큼 훑으므로 이번에 옮긴 것이 있을 때만(옮긴 게 없으면 줄 수가 늘지 않았다)
            if moved > 0 {
                tx.execute("DELETE FROM archive WHERE date < (SELECT date FROM archive ORDER BY date DESC LIMIT 1 OFFSET ?)", [max_rows.max(1) - 1])?;
            }
            Ok(moved)
        };
        // 어느 단계든(COMMIT 포함) 실패하면 tx 가 버려지며 모두 되돌린다
        match run(&tx).and_then(|n| tx.commit().map(|_| n)) {
            Ok(n) => n,
            Err(e) => {
                log::warn!("[DB] 정리·보관 실패(되돌림): {e}");
                0
            }
        }
    }

    // MARK: 보관 표(지난 기사)
    fn archived_rows(&self, sql: &str, p: &[&dyn rusqlite::ToSql]) -> Vec<ArchivedItem> {
        self.statements.fetch_add(1, Ordering::Relaxed);
        let c = self.conn.lock().unwrap();
        let Ok(mut st) = c.prepare(sql) else { return vec![] };
        let Ok(rows) = st.query_map(p, |r| {
            Ok(ArchivedItem {
                date: from_ts(r.get(0)?),
                title: r.get::<_, Option<String>>(1)?.unwrap_or_default(),
                title_ko: r.get(2)?,
                link: r.get::<_, Option<String>>(3)?.unwrap_or_default(),
                source: r.get::<_, Option<String>>(4)?.unwrap_or_default(),
                section: r.get::<_, Option<String>>(5)?.unwrap_or_else(|| crate::sections::TOP.into()),
                story: r.get(6)?,
                source_id: r.get(7)?,
            })
        }) else {
            return vec![];
        };
        rows.flatten().collect()
    }

    pub fn archive_count(&self) -> i64 {
        let c = self.conn.lock().unwrap();
        c.query_row("SELECT COUNT(*) FROM archive", [], |r| r.get(0)).unwrap_or(0)
    }

    // 보관 표에서 제목·한국어 제목·출처로 찾기(FTS 없이 LIKE — 검색어는 앞 200 글자), 최신순. 숨긴·끈 출처는 뺀다.
    // '+date': 날짜 색인을 거꾸로 훑으며 줄마다 표를 찾아가면(맞는 것이 적을 때) 느리다 — 표를 한 번 훑고 맞은 것만 정렬한다
    pub fn search_archive(&self, q: &str, limit: i64, offset: i64, vis: &Visibility) -> Vec<ArchivedItem> {
        let q: String = q.chars().take(crate::archive::MAX_QUERY).collect();
        let pat = format!("%{}%", q.replace('\\', "\\\\").replace('%', "\\%").replace('_', "\\_"));
        let v = vis.sql_args();
        let mut p: Vec<&dyn rusqlite::ToSql> = vec![&pat];
        p.extend(v.iter().map(|s| s as &dyn rusqlite::ToSql));
        p.push(&limit);
        p.push(&offset);
        self.archived_rows(
            &format!(
                "SELECT {ARCHIVE_COLUMNS} FROM archive
                 WHERE (title LIKE ?1 ESCAPE '\\' OR title_ko LIKE ?1 ESCAPE '\\' OR source LIKE ?1 ESCAPE '\\'){}
                 ORDER BY +date DESC LIMIT ? OFFSET ?",
                Visibility::SQL
            ),
            &p,
        )
    }

    // [from, to) 의 보관 기사(최신순, 날짜 색인)
    #[allow(clippy::too_many_arguments)]
    pub fn archived(&self, from: DateTime<Utc>, to: DateTime<Utc>, section: Option<&str>, source: Option<&str>, limit: i64, offset: i64, vis: &Visibility) -> Vec<ArchivedItem> {
        let (f, args) = archive_filter(section, source, vis);
        let (a, b) = (ts(from), ts(to));
        let mut p: Vec<&dyn rusqlite::ToSql> = vec![&a, &b];
        p.extend(args.iter().map(|s| s as &dyn rusqlite::ToSql));
        p.push(&limit);
        p.push(&offset);
        self.archived_rows(&format!("SELECT {ARCHIVE_COLUMNS} FROM archive WHERE date >= ? AND date < ?{f} ORDER BY date DESC LIMIT ? OFFSET ?"), &p)
    }

    // [from, to) 보관 기사의 날짜별 건수(이 컴퓨터의 날 기준 'YYYY-MM-DD'). 건수·거르기는 색인(date, section, source, source_id)만 읽는다
    pub fn archive_day_counts(&self, from: DateTime<Utc>, to: DateTime<Utc>, section: Option<&str>, source: Option<&str>, vis: &Visibility) -> HashMap<String, i64> {
        let (f, args) = archive_filter(section, source, vis);
        let (a, b) = (ts(from), ts(to));
        let mut p: Vec<&dyn rusqlite::ToSql> = vec![&a, &b];
        p.extend(args.iter().map(|s| s as &dyn rusqlite::ToSql));
        let c = self.conn.lock().unwrap();
        let sql = format!("SELECT date(date,'unixepoch','localtime') AS d, COUNT(*) FROM archive WHERE date >= ? AND date < ?{f} GROUP BY d");
        let Ok(mut st) = c.prepare(&sql) else { return HashMap::new() };
        st.query_map(p.as_slice(), |r| Ok((r.get::<_, Option<String>>(0)?, r.get::<_, i64>(1)?)))
            .map(|rows| rows.flatten().filter_map(|(d, n)| d.map(|d| (d, n))).collect())
            .unwrap_or_default()
    }

    // [from, to) 보관 기사의 분야별·출처별 건수(거르기 메뉴) — 한 번 묶어 센다
    pub fn archive_facets(&self, from: DateTime<Utc>, to: DateTime<Utc>, vis: &Visibility) -> (HashMap<String, i64>, HashMap<String, i64>) {
        let (mut sections, mut sources) = (HashMap::new(), HashMap::new());
        let (f, args) = archive_filter(None, None, vis);
        let (a, b) = (ts(from), ts(to));
        let mut p: Vec<&dyn rusqlite::ToSql> = vec![&a, &b];
        p.extend(args.iter().map(|s| s as &dyn rusqlite::ToSql));
        let c = self.conn.lock().unwrap();
        let Ok(mut st) = c.prepare(&format!("SELECT section, source, COUNT(*) FROM archive WHERE date >= ? AND date < ?{f} GROUP BY section, source")) else {
            return (sections, sources);
        };
        let rows: Vec<(Option<String>, Option<String>, i64)> = st
            .query_map(p.as_slice(), |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .map(|rows| rows.flatten().collect())
            .unwrap_or_default();
        for (sec, src, n) in rows {
            *sections.entry(sec.unwrap_or_else(|| crate::sections::TOP.into())).or_insert(0) += n;
            *sources.entry(src.unwrap_or_default()).or_insert(0) += n;
        }
        (sections, sources)
    }

    // 기록이 있는 가장 이른 때(보관 표와 최근 기사 중) — 보관함 ◀ 의 끝
    pub fn earliest_record(&self) -> Option<DateTime<Utc>> {
        let c = self.conn.lock().unwrap();
        c.query_row(
            "SELECT MIN(m) FROM (SELECT MIN(date) AS m FROM archive UNION ALL SELECT MIN(COALESCE(date, first_seen)) FROM items)",
            [],
            |r| r.get::<_, Option<f64>>(0),
        )
        .ok()
        .flatten()
        .map(from_ts)
    }

    // 아직 items 에 있는 [from, to) 기사를 보관 표와 같은 가벼운 꼴로(본문 JSON 을 통째로 풀지 않게 칸만 꺼낸다)
    pub fn recent_light(&self, from: DateTime<Utc>, to: DateTime<Utc>, vis: &Visibility, section: &mut dyn FnMut(&NewsItem) -> String) -> Vec<ArchivedItem> {
        self.statements.fetch_add(1, Ordering::Relaxed);
        type Row = (f64, Option<String>, Option<String>, Option<String>, Option<String>, Option<String>, Option<String>, Option<String>, Option<String>);
        let rows: Vec<Row> = {
            let c = self.conn.lock().unwrap();
            let Ok(mut st) = c.prepare(
                "SELECT COALESCE(i.date, i.first_seen), json_extract(i.json,'$.title'), json_extract(i.json,'$.titleKo'), json_extract(i.json,'$.link'),
                        json_extract(i.json,'$.sourceName'), i.source, json_extract(i.json,'$.summary'), json_extract(i.json,'$.id'),
                        CASE WHEN c.size >= 2 THEN i.cluster END
                 FROM items i LEFT JOIN clusters c ON c.id = i.cluster
                 WHERE COALESCE(i.date, i.first_seen) >= ? AND COALESCE(i.date, i.first_seen) < ?
                 ORDER BY COALESCE(i.date, i.first_seen) DESC",
            ) else {
                return vec![];
            };
            st.query_map(params![ts(from), ts(to)], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?, r.get(6)?, r.get(7)?, r.get(8)?))
            })
            .map(|rows| rows.flatten().collect())
            .unwrap_or_default()
        };
        // 분야 가르기는 DB 를 잡지 않은 채로(낱말 규칙이 수만 건이면 오래 걸림)
        // 숨긴·끈 출처 글은 빼고(매거진 검색과 같은 거르기)
        rows.into_iter()
            .filter(|r| vis.shows(r.5.as_deref().unwrap_or("")))
            .map(|(when, title, title_ko, link, source_name, source_id, summary, id, story)| {
                let mut it = NewsItem::new(
                    &id.unwrap_or_default(),
                    &title.unwrap_or_default(),
                    &link.unwrap_or_default(),
                    &source_id.unwrap_or_default(),
                    &source_name.unwrap_or_default(),
                    "",
                );
                it.title_ko = title_ko;
                it.summary = summary.unwrap_or_default();
                let sec = section(&it);
                let source_id = (!it.source_id.is_empty()).then_some(it.source_id);
                ArchivedItem { date: from_ts(when), title: it.title, title_ko: it.title_ko, link: it.link, source: it.source_name, source_id, section: sec, story }
            })
            .collect()
    }

    // MARK: 스토리
    fn cluster_rows(&self, sql: &str, p: &[&dyn rusqlite::ToSql]) -> Vec<Cluster> {
        self.statements.fetch_add(1, Ordering::Relaxed);
        let c = self.conn.lock().unwrap();
        let Ok(mut st) = c.prepare(sql) else { return vec![] };
        let Ok(rows) = st.query_map(p, |r| {
            Ok(Cluster {
                id: r.get(0)?,
                title: r.get(1)?,
                tokens: r.get::<_, String>(2)?.split(' ').filter(|s| !s.is_empty()).map(|s| s.to_string()).collect(),
                first: from_ts(r.get(3)?),
                last: from_ts(r.get(4)?),
                size: r.get(5)?,
            })
        }) else {
            return vec![];
        };
        rows.flatten().collect()
    }

    pub fn recent_clusters(&self, since: DateTime<Utc>) -> Vec<Cluster> {
        self.cluster_rows("SELECT id,title,tokens,first,last,size FROM clusters WHERE last >= ? ORDER BY last DESC", &[&ts(since)])
    }

    // 최근 스토리(보도 2건 이상)의 보도 견본을 한 번에(스토리 목록 — 스토리마다 따로 묻지 않게, 맥 Database.storyMembers).
    // 견본: 출처마다 첫 보도(카드의 출처 줄·대표) + 최근 STORY_SAMPLE 건(분야 다수결). 보도가 그보다 적으면 전부
    pub fn story_members(&self, since: DateTime<Utc>) -> HashMap<String, Vec<StoredItem>> {
        let mut out: HashMap<String, Vec<StoredItem>> = HashMap::new();
        let rows = self.stored_rows(
            "SELECT i.json, i.first_seen, i.cluster FROM items i JOIN (
               SELECT r FROM (
                 SELECT rowid AS r,
                        ROW_NUMBER() OVER (PARTITION BY cluster, source ORDER BY COALESCE(date, first_seen) ASC, rowid ASC) AS rs,
                        ROW_NUMBER() OVER (PARTITION BY cluster ORDER BY COALESCE(date, first_seen) DESC, rowid DESC) AS rn
                 FROM items WHERE cluster IN (SELECT id FROM clusters WHERE last >= ? AND size >= 2)
               ) WHERE rs = 1 OR rn <= ?
             ) s ON i.rowid = s.r
             ORDER BY COALESCE(i.date, i.first_seen) ASC",
            &[&ts(since), &STORY_SAMPLE],
        );
        for s in rows {
            if let Some(c) = s.cluster.clone() {
                out.entry(c).or_default().push(s);
            }
        }
        out
    }

    // 최근 스토리(보도 2건 이상)의 출처별 보도 수(보이는 보도 수·출처 수를 JSON 을 풀지 않고 세게, 맥 Database.storySourceCounts)
    pub fn story_source_counts(&self, since: DateTime<Utc>) -> HashMap<String, HashMap<String, i64>> {
        self.statements.fetch_add(1, Ordering::Relaxed);
        let mut out: HashMap<String, HashMap<String, i64>> = HashMap::new();
        let c = self.conn.lock().unwrap();
        let Ok(mut st) = c.prepare(
            "SELECT cluster, source, COUNT(*) FROM items
             WHERE cluster IN (SELECT id FROM clusters WHERE last >= ? AND size >= 2)
             GROUP BY cluster, source",
        ) else {
            return out;
        };
        let rows = st.query_map([ts(since)], |r| Ok((r.get::<_, String>(0)?, r.get::<_, Option<String>>(1)?, r.get::<_, i64>(2)?)));
        if let Ok(rows) = rows {
            for (cl, src, n) in rows.flatten() {
                *out.entry(cl).or_default().entry(src.unwrap_or_default()).or_default() += n;
            }
        }
        out
    }

    // 남아 있는 스토리 id 전부(상태의 storySeen 정리용). 읽지 못하면 None — 그때는 아무것도 지우지 않는다
    pub fn cluster_ids(&self) -> Option<HashSet<String>> {
        let c = self.conn.lock().unwrap();
        let mut st = c.prepare("SELECT id FROM clusters").ok()?;
        let rows = st.query_map([], |r| r.get::<_, String>(0)).ok()?;
        rows.collect::<rusqlite::Result<HashSet<String>>>().ok()
    }

    pub fn cluster(&self, id: &str) -> Option<Cluster> {
        self.cluster_rows("SELECT id,title,tokens,first,last,size FROM clusters WHERE id=?", &[&id]).into_iter().next()
    }

    pub fn save_cluster(&self, cl: &Cluster) {
        let mut toks: Vec<&String> = cl.tokens.iter().collect();
        toks.sort();
        let toks = toks.into_iter().cloned().collect::<Vec<_>>().join(" ");
        let c = self.conn.lock().unwrap();
        let _ = c.execute(
            "INSERT INTO clusters(id,title,tokens,first,last,size) VALUES(?,?,?,?,?,?)
             ON CONFLICT(id) DO UPDATE SET title=excluded.title, tokens=excluded.tokens, first=MIN(clusters.first, excluded.first),
               last=MAX(clusters.last, excluded.last), size=excluded.size",
            params![cl.id, cl.title, toks, ts(cl.first), ts(cl.last), cl.size],
        );
    }

    // MARK: 본문 추리기 기록(출처별 실패율 → 유료 기사 표시, G-14)
    // 사용자가 연 기사 하나의 결과를 더한다. 50번이 넘으면 반으로 줄여 최근 결과가 더 크게 보이게.
    pub fn record_extract(&self, source: &str, failed: bool, blocked: bool) {
        let c = self.conn.lock().unwrap();
        let _ = c.execute(
            "INSERT INTO extract_stats(source,tries,fails,blocked,updated) VALUES(?,1,?,?,?)
             ON CONFLICT(source) DO UPDATE SET tries=tries+1, fails=fails+excluded.fails, blocked=blocked+excluded.blocked, updated=excluded.updated",
            params![source, failed as i64, blocked as i64, ts(Utc::now())],
        );
        let _ = c.execute("UPDATE extract_stats SET tries=tries/2, fails=fails/2, blocked=blocked/2 WHERE source=? AND tries>50", params![source]);
    }

    pub fn extract_stats(&self) -> HashMap<String, ExtractStat> {
        let c = self.conn.lock().unwrap();
        let Ok(mut st) = c.prepare("SELECT source,tries,fails,blocked FROM extract_stats") else { return HashMap::new() };
        st.query_map([], |r| Ok((r.get::<_, String>(0)?, ExtractStat { tries: r.get(1)?, fails: r.get(2)?, blocked: r.get(3)? })))
            .map(|rows| rows.flatten().collect())
            .unwrap_or_default()
    }

    // MARK: 맛보기로 판정된 기사(미리 받기·읽기 — 목록·카드·물방울에 열기 전부터 '앞부분만', 맥 Database.markTeaser)
    // 다시 받아 맛보기가 아니면 지운다. 30일 지난 것·2,000건 넘는 오래된 것·5분 넘게 미래 시각인 것은 버린다
    pub fn mark_teaser(&self, link: &str, teaser: bool, now: DateTime<Utc>) {
        let c = self.conn.lock().unwrap();
        if teaser {
            let _ = c.execute("INSERT OR REPLACE INTO teasers(link,updated) VALUES(?,?)", params![link, ts(now)]);
            let _ = c.execute(
                "DELETE FROM teasers WHERE updated < ? OR updated > ?",
                params![ts(now - chrono::Duration::seconds(TEASER_LIFE_SECS)), ts(now + chrono::Duration::seconds(300))],
            );
            let _ = c.execute(
                &format!("DELETE FROM teasers WHERE link NOT IN (SELECT link FROM teasers ORDER BY updated DESC LIMIT {TEASER_LIMIT})"),
                [],
            );
        } else {
            let _ = c.execute("DELETE FROM teasers WHERE link=?", params![link]);
        }
    }

    pub fn teaser_links(&self, now: DateTime<Utc>) -> HashSet<String> {
        let c = self.conn.lock().unwrap();
        let Ok(mut st) = c.prepare("SELECT link FROM teasers WHERE updated >= ?") else { return HashSet::new() };
        st.query_map(params![ts(now - chrono::Duration::seconds(TEASER_LIFE_SECS))], |r| r.get::<_, String>(0))
            .map(|rows| rows.flatten().collect())
            .unwrap_or_default()
    }

    // MARK: 사진 점수(분야 대표 사진 고르기, M-24) — 30일 지난 것은 지운다
    pub fn save_image_score(&self, url: &str, s: &crate::photo_quality::Score) {
        let c = self.conn.lock().unwrap();
        let now = Utc::now();
        let _ = c.execute(
            "INSERT OR REPLACE INTO image_scores(url,score,text,colors,flat,updated) VALUES(?,?,?,?,?,?)",
            params![url, s.total, s.text_ratio, s.color_variety, s.flatness, ts(now)],
        );
        let _ = c.execute("DELETE FROM image_scores WHERE updated < ?", params![ts(now - chrono::Duration::days(30))]);
    }

    pub fn image_scores(&self, urls: &[String]) -> HashMap<String, f64> {
        let mut out = HashMap::new();
        let c = self.conn.lock().unwrap();
        for chunk in urls.chunks(400) {
            let q = format!("SELECT url, score FROM image_scores WHERE url IN ({})", vec!["?"; chunk.len()].join(","));
            let Ok(mut st) = c.prepare(&q) else { continue };
            let rows: Vec<(String, f64)> = st
                .query_map(rusqlite::params_from_iter(chunk.iter()), |r| Ok((r.get::<_, String>(0)?, r.get::<_, f64>(1)?)))
                .map(|rows| rows.flatten().collect())
                .unwrap_or_default();
            out.extend(rows);
        }
        out
    }

    // MARK: 스크랩
    pub fn save_scrap(&self, s: &Scrap) {
        let Ok(json) = serde_json::to_string(s) else { return };
        let c = self.conn.lock().unwrap();
        let _ = c.execute(
            "INSERT OR REPLACE INTO scraps(id,collection,created,json) VALUES(?,?,?,?)",
            params![s.id, s.collection, ts(s.created), json],
        );
    }

    pub fn delete_scrap(&self, id: &str) {
        let c = self.conn.lock().unwrap();
        let _ = c.execute("DELETE FROM scraps WHERE id=?", [id]);
    }

    pub fn scraps(&self, collection: Option<&str>) -> Vec<Scrap> {
        let c = self.conn.lock().unwrap();
        let (sql, p): (&str, Vec<&dyn rusqlite::ToSql>) = match &collection {
            None => ("SELECT json FROM scraps ORDER BY created DESC", vec![]),
            Some(col) => ("SELECT json FROM scraps WHERE collection=? ORDER BY created DESC", vec![col as &dyn rusqlite::ToSql]),
        };
        let Ok(mut st) = c.prepare(sql) else { return vec![] };
        let Ok(rows) = st.query_map(p.as_slice(), |r| r.get::<_, String>(0)) else { return vec![] };
        rows.flatten().filter_map(|j| serde_json::from_str(&j).ok()).collect()
    }

    pub fn rename_collection(&self, from: &str, to: &str) {
        for mut s in self.scraps(Some(from)) {
            s.collection = to.to_string();
            self.save_scrap(&s);
        }
    }

    // MARK: 호
    pub fn save_issue(&self, issue: &Issue) {
        let Ok(json) = serde_json::to_string(issue) else { return };
        let kind = match issue.kind {
            crate::magazine::IssueKind::Daily => "daily",
            crate::magazine::IssueKind::Weekly => "weekly",
        };
        let c = self.conn.lock().unwrap();
        // 정렬은 호의 끝 시각
        let _ = c.execute("INSERT OR REPLACE INTO issues(id,kind,created,json) VALUES(?,?,?,?)", params![issue.id, kind, ts(issue.to), json]);
    }

    pub fn issues(&self, limit: i64) -> Vec<Issue> {
        let c = self.conn.lock().unwrap();
        let Ok(mut st) = c.prepare("SELECT json FROM issues ORDER BY created DESC LIMIT ?") else { return vec![] };
        let Ok(rows) = st.query_map([limit], |r| r.get::<_, String>(0)) else { return vec![] };
        rows.flatten().filter_map(|j| serde_json::from_str(&j).ok()).collect()
    }

    pub fn has_issue(&self, id: &str) -> bool {
        let c = self.conn.lock().unwrap();
        c.query_row("SELECT 1 FROM issues WHERE id=?", [id], |_| Ok(())).optional().ok().flatten().is_some()
    }
}

