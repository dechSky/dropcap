// 매거진 기록 저장소: magazine.sqlite (맥 Core/Database.swift 와 같은 표·열·JSON).
// 이 파일이 없거나 깨져도 알림 기능은 그대로 돈다(지우면 처음부터 다시 쌓임).
use crate::magazine::Issue;
use crate::models::{ItemKind, NewsItem};
use crate::scrapbook::Scrap;
use chrono::{DateTime, TimeZone, Utc};
use rusqlite::{params, Connection, OptionalExtension};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

pub const SCHEMA_VERSION: i32 = 1;
pub const KEEP_ITEMS: i64 = 20000;

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
}

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
";

pub const TEASER_LIFE_SECS: i64 = 30 * 24 * 3600;
pub const TEASER_LIMIT: usize = 2000;

impl Database {
    pub fn open(dir: &Path) -> Database {
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
        let _ = conn.execute_batch(&format!("PRAGMA user_version={SCHEMA_VERSION};"));
        let mut db = Database { conn: Mutex::new(conn), file, recreated, salvaged_scraps: 0 };
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
        Database { conn: Mutex::new(conn), file: PathBuf::from(":memory:"), recreated: false, salvaged_scraps: 0 }
    }

    // MARK: 기사
    pub fn upsert(&self, item: &NewsItem, cluster: Option<&str>, first_seen: DateTime<Utc>) {
        let Ok(json) = serde_json::to_string(item) else { return };
        // 논문 피드(arXiv)는 날짜가 발표일 자정이라, 지면에는 받은 때를 기준으로 싣는다
        let when = if item.item_kind() == ItemKind::Paper { Some(first_seen) } else { item.date };
        let c = self.conn.lock().unwrap();
        let _ = c.execute(
            "INSERT INTO items(key,json,date,first_seen,category,source,tier,cluster,image) VALUES(?,?,?,?,?,?,?,?,?)
             ON CONFLICT(key) DO UPDATE SET json=excluded.json, date=COALESCE(items.date, excluded.date),
               category=excluded.category, cluster=COALESCE(excluded.cluster, items.cluster), image=COALESCE(excluded.image, items.image)",
            params![item.key(), json, when.map(ts), ts(first_seen), item.category().raw(), item.source_id, item.tier, cluster, item.image],
        );
    }

    pub fn set_image(&self, key: &str, url: &str) {
        let c = self.conn.lock().unwrap();
        let _ = c.execute("UPDATE items SET image=?, json=json_set(json,'$.image',?) WHERE key=?", params![url, url, key]);
    }

    pub fn exists(&self, key: &str) -> bool {
        let c = self.conn.lock().unwrap();
        c.query_row("SELECT 1 FROM items WHERE key=?", [key], |_| Ok(())).optional().ok().flatten().is_some()
    }

    fn stored_rows(&self, sql: &str, p: &[&dyn rusqlite::ToSql]) -> Vec<StoredItem> {
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

    // 오래된 기록 정리(최근 20000건 유지)
    pub fn prune(&self, keep: i64) {
        let c = self.conn.lock().unwrap();
        let _ = c.execute("DELETE FROM items WHERE key IN (SELECT key FROM items ORDER BY COALESCE(date, first_seen) DESC LIMIT -1 OFFSET ?)", [keep]);
        let _ = c.execute("DELETE FROM clusters WHERE id NOT IN (SELECT DISTINCT cluster FROM items WHERE cluster IS NOT NULL)", []);
    }

    // MARK: 스토리
    fn cluster_rows(&self, sql: &str, p: &[&dyn rusqlite::ToSql]) -> Vec<Cluster> {
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

