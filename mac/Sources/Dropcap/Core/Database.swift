import Foundation
import SQLite3

// 매거진 기록 저장소: ~/Library/Application Support/AI News Alert/magazine.sqlite
// 기사 · 스토리(같은 주제 묶음) · 호(발행본)를 둔다. 설정·읽음 기록은 예전처럼 native-state.json 에 남겨,
// 이 파일이 없거나 깨져도 앱의 알림 기능은 그대로 돈다(지우면 처음부터 다시 쌓임).
final class Database: @unchecked Sendable {
    static let shared = Database()
    static let schemaVersion: Int32 = 1

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "magazine.db")
    let file: URL
    private(set) var recreated = false   // 이번 실행에서 깨진 파일을 치우고 새로 만들었는가
    private(set) var salvagedScraps = 0  // 그때 깨진 파일에서 건진 스크랩 수

    // file 은 시험에서만 바꾼다
    init(file: URL = Store.dir.appendingPathComponent("magazine.sqlite")) {
        self.file = file
        queue.sync { open() }
    }

    private func open() {
        // sqlite3_open 은 깨진 파일도 열어 준다 — 첫 문장에서 '데이터베이스가 아님/깨짐'이 나오면 그때 옆으로 치운다.
        // (그대로 두면 모든 읽기·쓰기가 조용히 실패해 새 스크랩까지 사라졌다)
        let opened = sqlite3_open(file.path, &db) == SQLITE_OK
        if !opened || (!createSchema() && [SQLITE_NOTADB, SQLITE_CORRUPT].contains(sqlite3_errcode(db))) {
            NSLog("[DB] 열기 실패, 새로 만듭니다: %@", String(cString: sqlite3_errmsg(db)))
            sqlite3_close(db)
            db = nil
            let fm = FileManager.default
            for ext in ["", "-wal", "-shm"] { // 남은 WAL 이 새 파일에 섞이지 않게 함께 치운다
                let from = URL(fileURLWithPath: file.path + ext)
                let broken = URL(fileURLWithPath: file.deletingPathExtension().path + ".broken.sqlite" + ext)
                try? fm.removeItem(at: broken)
                try? fm.moveItem(at: from, to: broken)
            }
            sqlite3_open(file.path, &db)
            createSchema()
            recreated = true
            // 스크랩은 사용자가 만든 것이라 다시 쌓이지 않는다 → 치운 파일에서 읽을 수 있는 만큼 옮겨 온다
            salvagedScraps = salvageScraps(from: URL(fileURLWithPath: file.deletingPathExtension().path + ".broken.sqlite"))
            if salvagedScraps > 0 { NSLog("[DB] 깨진 파일에서 스크랩 %d개를 옮겨 왔습니다", salvagedScraps) }
        }
    }

    // 시험·손 복구용: 다른 DB 파일의 스크랩을 이 DB 로 옮긴다
    func importScraps(from other: URL) -> Int { queue.sync { salvageScraps(from: other) } }

    // 깨진(치운) DB 의 scraps 표를 읽기 전용으로 열어, 읽히는 줄까지 새 DB 로 옮긴다. 큐 안에서만 부른다.
    private func salvageScraps(from broken: URL) -> Int {
        var old: OpaquePointer?
        defer { sqlite3_close(old) }
        guard sqlite3_open_v2(broken.path, &old, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return 0 }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(old, "SELECT id, collection, created, json FROM scraps", -1, &st, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(st) }
        var n = 0
        while sqlite3_step(st) == SQLITE_ROW { // 중간에 깨진 쪽을 만나면 거기까지
            guard let id = Self.text(st!, 0), let json = Self.text(st!, 3),
                  (try? Self.decoder.decode(Scrap.self, from: Data(json.utf8))) != nil else { continue }
            run("INSERT OR IGNORE INTO scraps(id,collection,created,json) VALUES(?,?,?,?)",
                [.text(id), .text(Self.text(st!, 1)), .real(sqlite3_column_double(st, 2)), .text(json)])
            n += 1
        }
        return n
    }

    @discardableResult
    private func createSchema() -> Bool {
        exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        && exec("""
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
        CREATE TABLE IF NOT EXISTS image_scores(
          url TEXT PRIMARY KEY, score REAL NOT NULL, text REAL NOT NULL, colors REAL NOT NULL, flat REAL NOT NULL, updated REAL NOT NULL);
        """)
        && exec("PRAGMA user_version=\(Self.schemaVersion);")
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        var err: UnsafeMutablePointer<CChar>?
        let ok = sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK
        if !ok { NSLog("[DB] %@", err.map { String(cString: $0) } ?? "?"); sqlite3_free(err) }
        return ok
    }

    // MARK: 문장 실행 도우미
    enum Value { case text(String?), real(Double?), int(Int?) }

    private func run(_ sql: String, _ args: [Value], row: ((OpaquePointer) -> Void)? = nil) {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            NSLog("[DB] 준비 실패 %@", String(cString: sqlite3_errmsg(db))); return
        }
        defer { sqlite3_finalize(st) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case .text(let s): if let s { sqlite3_bind_text(st, idx, s, -1, transient) } else { sqlite3_bind_null(st, idx) }
            case .real(let d): if let d { sqlite3_bind_double(st, idx, d) } else { sqlite3_bind_null(st, idx) }
            case .int(let n): if let n { sqlite3_bind_int64(st, idx, Int64(n)) } else { sqlite3_bind_null(st, idx) }
            }
        }
        while true {
            let r = sqlite3_step(st)
            if r == SQLITE_ROW { row?(st!); continue }
            if r != SQLITE_DONE { NSLog("[DB] 실행 실패(%d) %@", r, String(cString: sqlite3_errmsg(db))) } // 잠김·디스크 가득 등(A-33)
            break
        }
    }

    private static func text(_ st: OpaquePointer, _ i: Int32) -> String? {
        sqlite3_column_text(st, i).map { String(cString: $0) }
    }

    // MARK: 기사
    struct StoredItem {
        var item: NewsItem
        var firstSeen: Date
        var cluster: String?
    }

    func upsert(_ item: NewsItem, cluster: String?, firstSeen: Date = Date()) {
        guard let json = try? Self.encoder.encode(item) else { return }
        // 논문 피드(arXiv)는 날짜가 발표일 자정이라, 지면에는 받은 때를 기준으로 싣는다
        let when = item.itemKind == .paper ? firstSeen : item.date
        queue.sync {
            run("""
            INSERT INTO items(key,json,date,first_seen,category,source,tier,cluster,image) VALUES(?,?,?,?,?,?,?,?,?)
            ON CONFLICT(key) DO UPDATE SET json=excluded.json, date=COALESCE(items.date, excluded.date),
              category=excluded.category, cluster=COALESCE(excluded.cluster, items.cluster), image=COALESCE(excluded.image, items.image)
            """, [.text(item.key), .text(String(decoding: json, as: UTF8.self)), .real(when?.timeIntervalSince1970),
                  .real(firstSeen.timeIntervalSince1970), .text(item.category.rawValue), .text(item.sourceId), .text(item.tier),
                  .text(cluster), .text(item.image)])
        }
    }

    func setImage(_ key: String, _ url: String) {
        queue.sync {
            run("UPDATE items SET image=?, json=json_set(json,'$.image',?) WHERE key=?", [.text(url), .text(url), .text(key)])
        }
    }

    func exists(_ key: String) -> Bool {
        var found = false
        queue.sync { run("SELECT 1 FROM items WHERE key=?", [.text(key)]) { _ in found = true } }
        return found
    }

    // 기사 날짜(없으면 처음 본 때)가 [from, to) 안인 것. articlesOnly 면 기사만(논문·릴리스 등 구독 채널 글 제외), channelsOnly 면 그 반대
    func items(from: Date, to: Date = .distantFuture, limit: Int = 2000, articlesOnly: Bool = false, channelsOnly: Bool = false) -> [StoredItem] {
        var out: [StoredItem] = []
        let kind = articlesOnly ? "AND COALESCE(json_extract(json,'$.kind'),'article') = 'article'"
            : channelsOnly ? "AND COALESCE(json_extract(json,'$.kind'),'article') != 'article'" : ""
        queue.sync {
            run("""
            SELECT json, first_seen, cluster FROM items
            WHERE COALESCE(date, first_seen) >= ? AND COALESCE(date, first_seen) < ? \(kind)
            ORDER BY COALESCE(date, first_seen) DESC LIMIT ?
            """, [.real(from.timeIntervalSince1970), .real(min(to.timeIntervalSince1970, 4e10)), .int(limit)]) { st in
                guard let j = Self.text(st, 0), let it = try? Self.decoder.decode(NewsItem.self, from: Data(j.utf8)) else { return }
                out.append(StoredItem(item: it, firstSeen: Date(timeIntervalSince1970: sqlite3_column_double(st, 1)), cluster: Self.text(st, 2)))
            }
        }
        return out
    }

    // key 로 바로 꺼내기(호 그리기·표지 찾기)
    func items(keys: [String]) -> [StoredItem] {
        guard !keys.isEmpty else { return [] }
        var out: [StoredItem] = []
        for chunk in stride(from: 0, to: keys.count, by: 400).map({ Array(keys[$0..<min($0 + 400, keys.count)]) }) {
            queue.sync {
                run("SELECT json, first_seen, cluster FROM items WHERE key IN (\(Array(repeating: "?", count: chunk.count).joined(separator: ",")))",
                    chunk.map { .text($0) }) { st in
                    guard let j = Self.text(st, 0), let it = try? Self.decoder.decode(NewsItem.self, from: Data(j.utf8)) else { return }
                    out.append(StoredItem(item: it, firstSeen: Date(timeIntervalSince1970: sqlite3_column_double(st, 1)), cluster: Self.text(st, 2)))
                }
            }
        }
        return out
    }

    func clusterOf(_ key: String) -> String? {
        var c: String?
        queue.sync { run("SELECT cluster FROM items WHERE key=?", [.text(key)]) { st in c = Self.text(st, 0) } }
        return c
    }

    // 기사마다 '같은 소식을 다룬 출처 수'(스토리 크기). 스토리에 묶이지 않았으면 빠짐
    func coverage(_ keys: [String]) -> [String: Int] {
        var out: [String: Int] = [:]
        guard !keys.isEmpty else { return out }
        let marks = Array(repeating: "?", count: keys.count).joined(separator: ",")
        queue.sync {
            run("SELECT i.key, c.size FROM items i JOIN clusters c ON c.id = i.cluster WHERE i.key IN (\(marks))", keys.map { .text($0) }) { st in
                if let k = Self.text(st, 0) { out[k] = Int(sqlite3_column_int64(st, 1)) }
            }
        }
        return out
    }

    // 매거진이 받아 둔 기사 대표 사진(피드에 없어 기사 머리에서 찾은 것 포함)
    func image(_ key: String) -> String? {
        var out: String?
        queue.sync { run("SELECT image FROM items WHERE key=?", [.text(key)]) { st in out = Self.text(st, 0) } }
        return out
    }

    // 최근 스토리마다 대표 기사(가장 최근 보도) 하나 — 스토리마다 따로 묻지 않고 한 번에
    func representatives(since: Date) -> [String: StoredItem] {
        var out: [String: StoredItem] = [:]
        queue.sync {
            run("""
            SELECT cluster, json, first_seen FROM (
              SELECT cluster, json, first_seen,
                     ROW_NUMBER() OVER (PARTITION BY cluster ORDER BY COALESCE(date, first_seen) DESC, rowid DESC) AS rn
              FROM items WHERE cluster IN (SELECT id FROM clusters WHERE last >= ?)
            ) WHERE rn = 1
            """, [.real(since.timeIntervalSince1970)]) { st in
                guard let c = Self.text(st, 0), let j = Self.text(st, 1), let it = try? Self.decoder.decode(NewsItem.self, from: Data(j.utf8)) else { return }
                out[c] = StoredItem(item: it, firstSeen: Date(timeIntervalSince1970: sqlite3_column_double(st, 2)), cluster: c)
            }
        }
        return out
    }

    // 여러 기사의 스토리 id 를 한 번에
    func clusters(of keys: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for chunk in stride(from: 0, to: keys.count, by: 400).map({ Array(keys[$0..<min($0 + 400, keys.count)]) }) {
            queue.sync {
                run("SELECT key, cluster FROM items WHERE cluster IS NOT NULL AND key IN (\(Array(repeating: "?", count: chunk.count).joined(separator: ",")))",
                    chunk.map { .text($0) }) { st in
                    if let k = Self.text(st, 0), let c = Self.text(st, 1) { out[k] = c }
                }
            }
        }
        return out
    }

    func items(inCluster id: String) -> [StoredItem] {
        var out: [StoredItem] = []
        queue.sync {
            run("SELECT json, first_seen, cluster FROM items WHERE cluster=? ORDER BY COALESCE(date, first_seen) ASC", [.text(id)]) { st in
                guard let j = Self.text(st, 0), let it = try? Self.decoder.decode(NewsItem.self, from: Data(j.utf8)) else { return }
                out.append(StoredItem(item: it, firstSeen: Date(timeIntervalSince1970: sqlite3_column_double(st, 1)), cluster: Self.text(st, 2)))
            }
        }
        return out
    }

    func search(_ q: String, limit: Int = 200) -> [NewsItem] {
        var out: [NewsItem] = []
        queue.sync {
            // 제목·한국어 제목·출처·요약에서만(JSON 의 필드 이름이나 주소에 걸리지 않게)
            let pat = "%" + q.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
            run("""
            SELECT json FROM items WHERE
              json_extract(json,'$.title') LIKE ?1 ESCAPE '\\' OR json_extract(json,'$.titleKo') LIKE ?1 ESCAPE '\\'
              OR json_extract(json,'$.sourceName') LIKE ?1 ESCAPE '\\' OR json_extract(json,'$.summary') LIKE ?1 ESCAPE '\\'
            ORDER BY COALESCE(date, first_seen) DESC LIMIT ?2
            """, [.text(pat), .int(limit)]) { st in
                if let j = Self.text(st, 0), let it = try? Self.decoder.decode(NewsItem.self, from: Data(j.utf8)) { out.append(it) }
            }
        }
        return out
    }

    var itemCount: Int {
        var n = 0
        queue.sync { run("SELECT COUNT(*) FROM items", []) { st in n = Int(sqlite3_column_int64(st, 0)) } }
        return n
    }

    // 오래된 기록 정리(최근 20000건 유지)
    func prune(keep: Int = 20000) {
        queue.sync {
            run("""
            DELETE FROM items WHERE key IN (SELECT key FROM items ORDER BY COALESCE(date, first_seen) DESC LIMIT -1 OFFSET ?)
            """, [.int(keep)])
            run("DELETE FROM clusters WHERE id NOT IN (SELECT DISTINCT cluster FROM items WHERE cluster IS NOT NULL)", [])
        }
    }

    // MARK: 스토리
    struct Cluster: Identifiable, Hashable {
        var id: String
        var title: String
        var tokens: Set<String>
        var first: Date
        var last: Date
        var size: Int
    }

    func recentClusters(since: Date) -> [Cluster] {
        var out: [Cluster] = []
        queue.sync {
            run("SELECT id,title,tokens,first,last,size FROM clusters WHERE last >= ? ORDER BY last DESC", [.real(since.timeIntervalSince1970)]) { st in
                out.append(Cluster(id: Self.text(st, 0) ?? "", title: Self.text(st, 1) ?? "",
                                   tokens: Set((Self.text(st, 2) ?? "").split(separator: " ").map(String.init)),
                                   first: Date(timeIntervalSince1970: sqlite3_column_double(st, 3)),
                                   last: Date(timeIntervalSince1970: sqlite3_column_double(st, 4)),
                                   size: Int(sqlite3_column_int64(st, 5))))
            }
        }
        return out
    }

    // 다시 묶기: 이 시각 뒤의 기사들의 스토리를 비우고 그 스토리들을 지운다
    func resetClusters(since: Date) {
        queue.sync {
            run("DELETE FROM clusters WHERE id IN (SELECT DISTINCT cluster FROM items WHERE cluster IS NOT NULL AND COALESCE(date, first_seen) >= ?)", [.real(since.timeIntervalSince1970)])
            run("UPDATE items SET cluster=NULL WHERE COALESCE(date, first_seen) >= ?", [.real(since.timeIntervalSince1970)])
        }
    }
    func setCluster(_ key: String, _ cluster: String?) {
        queue.sync { run("UPDATE items SET cluster=? WHERE key=?", [.text(cluster), .text(key)]) }
    }

    func saveCluster(_ c: Cluster) {
        queue.sync {
            run("""
            INSERT INTO clusters(id,title,tokens,first,last,size) VALUES(?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET title=excluded.title, tokens=excluded.tokens, first=MIN(clusters.first, excluded.first),
              last=MAX(clusters.last, excluded.last), size=excluded.size
            """, [.text(c.id), .text(c.title), .text(c.tokens.sorted().joined(separator: " ")), .real(c.first.timeIntervalSince1970),
                  .real(c.last.timeIntervalSince1970), .int(c.size)])
        }
    }

    func cluster(_ id: String) -> Cluster? {
        var out: Cluster?
        queue.sync {
            run("SELECT id,title,tokens,first,last,size FROM clusters WHERE id=?", [.text(id)]) { st in
                out = Cluster(id: Self.text(st, 0) ?? "", title: Self.text(st, 1) ?? "",
                              tokens: Set((Self.text(st, 2) ?? "").split(separator: " ").map(String.init)),
                              first: Date(timeIntervalSince1970: sqlite3_column_double(st, 3)),
                              last: Date(timeIntervalSince1970: sqlite3_column_double(st, 4)),
                              size: Int(sqlite3_column_int64(st, 5)))
            }
        }
        return out
    }

    // MARK: 스크랩
    func saveScrap(_ s: Scrap) {
        guard let json = try? Self.encoder.encode(s) else { return }
        queue.sync {
            run("INSERT OR REPLACE INTO scraps(id,collection,created,json) VALUES(?,?,?,?)",
                [.text(s.id), .text(s.collection), .real(s.created.timeIntervalSince1970), .text(String(decoding: json, as: UTF8.self))])
        }
    }

    func deleteScrap(_ id: String) { queue.sync { run("DELETE FROM scraps WHERE id=?", [.text(id)]) } }

    func scraps(collection: String? = nil) -> [Scrap] {
        var out: [Scrap] = []
        queue.sync {
            let sql = collection == nil ? "SELECT json FROM scraps ORDER BY created DESC" : "SELECT json FROM scraps WHERE collection=? ORDER BY created DESC"
            run(sql, collection.map { [.text($0)] } ?? []) { st in
                if let j = Self.text(st, 0), let s = try? Self.decoder.decode(Scrap.self, from: Data(j.utf8)) { out.append(s) }
            }
        }
        return out
    }

    func renameCollection(_ from: String, to: String) {
        let list = scraps(collection: from)
        for var s in list { s.collection = to; saveScrap(s) }
    }

    // MARK: 호
    func saveIssue(_ issue: Issue) {
        guard let json = try? Self.encoder.encode(issue) else { return }
        queue.sync {
            run("INSERT OR REPLACE INTO issues(id,kind,created,json) VALUES(?,?,?,?)",
                [.text(issue.id), .text(issue.kind.rawValue), .real(issue.to.timeIntervalSince1970), .text(String(decoding: json, as: UTF8.self))]) // 정렬은 호의 끝 시각
        }
    }

    func issues(limit: Int = 120) -> [Issue] {
        var out: [Issue] = []
        queue.sync {
            run("SELECT json FROM issues ORDER BY created DESC LIMIT ?", [.int(limit)]) { st in
                if let j = Self.text(st, 0), let i = try? Self.decoder.decode(Issue.self, from: Data(j.utf8)) { out.append(i) }
            }
        }
        return out
    }

    func issue(_ id: String) -> Issue? {
        var out: Issue?
        queue.sync { run("SELECT json FROM issues WHERE id=?", [.text(id)]) { st in
            if let j = Self.text(st, 0) { out = try? Self.decoder.decode(Issue.self, from: Data(j.utf8)) }
        } }
        return out
    }

    func hasIssue(_ id: String) -> Bool {
        var found = false
        queue.sync { run("SELECT 1 FROM issues WHERE id=?", [.text(id)]) { _ in found = true } }
        return found
    }

    // MARK: 본문 추리기 기록(출처별 실패율 → 유료 기사 표시)
    struct ExtractStat: Equatable, Sendable {
        var tries = 0, fails = 0, blocked = 0
        var failRate: Double { tries == 0 ? 0 : Double(fails + blocked) / Double(tries) }
    }

    // 사용자가 연 기사 하나의 결과를 더한다. 50번이 넘으면 반으로 줄여 최근 결과가 더 크게 보이게.
    func recordExtract(source: String, failed: Bool, blocked: Bool) {
        queue.sync {
            run("""
            INSERT INTO extract_stats(source,tries,fails,blocked,updated) VALUES(?,1,?,?,?)
            ON CONFLICT(source) DO UPDATE SET tries=tries+1, fails=fails+excluded.fails, blocked=blocked+excluded.blocked, updated=excluded.updated
            """, [.text(source), .int(failed ? 1 : 0), .int(blocked ? 1 : 0), .real(Date().timeIntervalSince1970)])
            run("UPDATE extract_stats SET tries=tries/2, fails=fails/2, blocked=blocked/2 WHERE source=? AND tries>50", [.text(source)])
        }
    }

    func extractStats() -> [String: ExtractStat] {
        var out: [String: ExtractStat] = [:]
        queue.sync {
            run("SELECT source,tries,fails,blocked FROM extract_stats", []) { st in
                guard let s = Self.text(st, 0) else { return }
                out[s] = ExtractStat(tries: Int(sqlite3_column_int64(st, 1)), fails: Int(sqlite3_column_int64(st, 2)), blocked: Int(sqlite3_column_int64(st, 3)))
            }
        }
        return out
    }

    // MARK: 사진 점수(분야 대표 사진 고르기)
    func saveImageScore(_ url: String, _ s: PhotoQuality.Score) {
        queue.sync {
            run("INSERT OR REPLACE INTO image_scores(url,score,text,colors,flat,updated) VALUES(?,?,?,?,?,?)",
                [.text(url), .real(s.total), .real(s.textRatio), .real(s.colorVariety), .real(s.flatness), .real(Date().timeIntervalSince1970)])
            run("DELETE FROM image_scores WHERE updated < ?", [.real(Date().addingTimeInterval(-30 * 24 * 3600).timeIntervalSince1970)])
        }
    }

    func imageScores(_ urls: [String]) -> [String: Double] {
        var out: [String: Double] = [:]
        for chunk in stride(from: 0, to: urls.count, by: 400).map({ Array(urls[$0..<min($0 + 400, urls.count)]) }) {
            queue.sync {
                run("SELECT url, score FROM image_scores WHERE url IN (\(Array(repeating: "?", count: chunk.count).joined(separator: ",")))",
                    chunk.map { .text($0) }) { st in
                    if let u = Self.text(st, 0) { out[u] = sqlite3_column_double(st, 1) }
                }
            }
        }
        return out
    }

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
