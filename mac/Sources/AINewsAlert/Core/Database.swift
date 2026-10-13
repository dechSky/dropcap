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
    let file = Store.dir.appendingPathComponent("magazine.sqlite")

    private init() {
        queue.sync { open() }
    }

    private func open() {
        if sqlite3_open(file.path, &db) != SQLITE_OK {
            NSLog("[DB] 열기 실패, 새로 만듭니다: %@", String(cString: sqlite3_errmsg(db)))
            sqlite3_close(db)
            let broken = file.deletingPathExtension().appendingPathExtension("broken.sqlite")
            try? FileManager.default.removeItem(at: broken)
            try? FileManager.default.moveItem(at: file, to: broken)
            sqlite3_open(file.path, &db)
        }
        exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        exec("""
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
        """)
        exec("PRAGMA user_version=\(Self.schemaVersion);")
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
            if r == SQLITE_ROW { row?(st!) } else { break }
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
        queue.sync {
            run("""
            INSERT INTO items(key,json,date,first_seen,category,source,tier,cluster,image) VALUES(?,?,?,?,?,?,?,?,?)
            ON CONFLICT(key) DO UPDATE SET json=excluded.json, date=COALESCE(excluded.date, items.date),
              category=excluded.category, cluster=COALESCE(excluded.cluster, items.cluster), image=COALESCE(excluded.image, items.image)
            """, [.text(item.key), .text(String(decoding: json, as: UTF8.self)), .real(item.date?.timeIntervalSince1970),
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

    // 기사 날짜(없으면 처음 본 때)가 [from, to) 안인 것
    func items(from: Date, to: Date = .distantFuture, limit: Int = 2000) -> [StoredItem] {
        var out: [StoredItem] = []
        queue.sync {
            run("""
            SELECT json, first_seen, cluster FROM items
            WHERE COALESCE(date, first_seen) >= ? AND COALESCE(date, first_seen) < ?
            ORDER BY COALESCE(date, first_seen) DESC LIMIT ?
            """, [.real(from.timeIntervalSince1970), .real(min(to.timeIntervalSince1970, 4e10)), .int(limit)]) { st in
                guard let j = Self.text(st, 0), let it = try? Self.decoder.decode(NewsItem.self, from: Data(j.utf8)) else { return }
                out.append(StoredItem(item: it, firstSeen: Date(timeIntervalSince1970: sqlite3_column_double(st, 1)), cluster: Self.text(st, 2)))
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
            run("SELECT json FROM items WHERE json LIKE ? ESCAPE '\\' ORDER BY COALESCE(date, first_seen) DESC LIMIT ?",
                [.text("%" + q.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"), .int(limit)]) { st in
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

    // MARK: 호
    func saveIssue(_ issue: Issue) {
        guard let json = try? Self.encoder.encode(issue) else { return }
        queue.sync {
            run("INSERT OR REPLACE INTO issues(id,kind,created,json) VALUES(?,?,?,?)",
                [.text(issue.id), .text(issue.kind.rawValue), .real(issue.date.timeIntervalSince1970), .text(String(decoding: json, as: UTF8.self))])
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

    func hasIssue(_ id: String) -> Bool {
        var found = false
        queue.sync { run("SELECT 1 FROM issues WHERE id=?", [.text(id)]) { _ in found = true } }
        return found
    }

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
