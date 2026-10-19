import Foundation
import SQLite3

// 매거진 기록 저장소: ~/Library/Application Support/AI News Alert/magazine.sqlite
// 기사 · 스토리(같은 주제 묶음) · 호(발행본)를 둔다. 설정·읽음 기록은 예전처럼 native-state.json 에 남겨,
// 이 파일이 없거나 깨져도 앱의 알림 기능은 그대로 돈다(지우면 처음부터 다시 쌓임).
final class Database: @unchecked Sendable {
    static let shared = Database()
    static let schemaVersion: Int32 = 1
    static let busyTimeoutMs: Int32 = 3000

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "magazine.db")
    let file: URL
    private(set) var recreated = false   // 이번 실행에서 깨진 파일을 치우고 새로 만들었는가
    private(set) var salvagedScraps = 0  // 그때 깨진 파일에서 건진 스크랩 수
    private(set) var statements = 0      // 시험용: 실행한 문장 수(화면 하나에 DB 를 몇 번 묻는지)

    private let busyMs: Int32

    // file·busyTimeoutMs 는 시험에서만 바꾼다
    init(file: URL = Store.dir.appendingPathComponent("magazine.sqlite"), busyTimeoutMs: Int32 = Database.busyTimeoutMs) {
        self.file = file
        busyMs = busyTimeoutMs
        queue.sync { open() }
    }

    private func open() {
        // sqlite3_open 은 깨진 파일도 열어 준다 — 첫 문장에서 '데이터베이스가 아님/깨짐'이 나오면 그때 옆으로 치운다.
        // (그대로 두면 모든 읽기·쓰기가 조용히 실패해 새 스크랩까지 사라졌다)
        let opened = sqlite3_open(file.path, &db) == SQLITE_OK
        installBusyHandler()
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
            installBusyHandler()
            createSchema()
            recreated = true
            // 스크랩은 사용자가 만든 것이라 다시 쌓이지 않는다 → 치운 파일에서 읽을 수 있는 만큼 옮겨 온다
            salvagedScraps = salvageScraps(from: URL(fileURLWithPath: file.deletingPathExtension().path + ".broken.sqlite"))
            if salvagedScraps > 0 { NSLog("[DB] 깨진 파일에서 스크랩 %d개를 옮겨 왔습니다", salvagedScraps) }
        }
    }

    // 다른 연결이 잠깐 잠갔을 때 바로 실패하지 않고 기다린다. 뒤 스레드는 busyMs 까지,
    // 메인 스레드(화면)는 0.1초까지만 — queue.sync 는 부른 스레드에서 돌므로 메인에서 부른 쓰기가 화면을 멈추지 않게
    private func installBusyHandler() {
        sqlite3_busy_handler(db, { ctx, count in
            guard let ctx else { return 0 }
            let me = Unmanaged<Database>.fromOpaque(ctx).takeUnretainedValue()
            let limit = Thread.isMainThread ? min(me.busyMs, 100) : me.busyMs
            guard Int32(count) * 10 < limit else { return 0 }
            usleep(10_000)
            return 1
        }, Unmanaged.passUnretained(self).toOpaque())
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
        CREATE TABLE IF NOT EXISTS teasers(
          link TEXT PRIMARY KEY, updated REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS image_scores(
          url TEXT PRIMARY KEY, score REAL NOT NULL, text REAL NOT NULL, colors REAL NOT NULL, flat REAL NOT NULL, updated REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS archive(
          date REAL NOT NULL, title TEXT NOT NULL, title_ko TEXT, link TEXT NOT NULL, source TEXT, source_id TEXT, section TEXT, story TEXT);
        """)
        && addArchiveSourceID()
        && exec("""
        DROP INDEX IF EXISTS archive_date;
        CREATE INDEX IF NOT EXISTS archive_date_src ON archive(date, section, source, source_id);
        """)
        && exec("PRAGMA user_version=\(Self.schemaVersion);")
    }

    // source_id 칸이 없던 보관 표(먼저 만든 판)에 칸을 더한다 — 그때 줄은 NULL(출처 이름으로 거른다)
    private func addArchiveSourceID() -> Bool {
        var has = false
        run("SELECT 1 FROM pragma_table_info('archive') WHERE name='source_id'", []) { _ in has = true }
        return has || exec("ALTER TABLE archive ADD COLUMN source_id TEXT")
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        var err: UnsafeMutablePointer<CChar>?
        let ok = sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK
        if !ok { NSLog("[DB] %@", err.map { String(cString: $0) } ?? "?"); sqlite3_free(err) }
        return ok
    }

    // 시험용: 줄을 일부러 망가뜨리기
    func execForTests(_ sql: String) { queue.sync { _ = exec(sql) } }

    // MARK: 문장 실행 도우미
    enum Value { case text(String?), real(Double?), int(Int?) }

    // 성공하면 true(잠김·디스크 가득 등으로 실패하면 false — 부르는 쪽이 다시 시도할 수 있게)
    @discardableResult
    private func run(_ sql: String, _ args: [Value], row: ((OpaquePointer) -> Void)? = nil) -> Bool {
        statements += 1
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            NSLog("[DB] 준비 실패 %@", String(cString: sqlite3_errmsg(db))); return false
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
            if r != SQLITE_DONE { NSLog("[DB] 실행 실패(%d) %@", r, String(cString: sqlite3_errmsg(db))); return false } // 잠김·디스크 가득 등(A-33)
            return true
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

    @discardableResult
    func upsert(_ item: NewsItem, cluster: String?, firstSeen: Date = Date()) -> Bool {
        guard let json = try? Self.itemEncoder.encode(item) else { return false }
        // 피드 본문이 빠진 사본(앱 상태·스크랩에서 온 것)으로 다시 넣어도 DB 에 둔 피드 본문은 지우지 않는다(ON CONFLICT 의 CASE)
        // 논문 피드(arXiv)는 날짜가 발표일 자정이라, 지면에는 받은 때를 기준으로 싣는다
        let when = item.itemKind == .paper ? firstSeen : item.date
        return queue.sync {
            run("""
            INSERT INTO items(key,json,date,first_seen,category,source,tier,cluster,image) VALUES(?,?,?,?,?,?,?,?,?)
            ON CONFLICT(key) DO UPDATE SET
              json=CASE WHEN json_extract(excluded.json,'$.feedBody') IS NULL AND json_extract(items.json,'$.feedBody') IS NOT NULL
                        THEN json_set(excluded.json,'$.feedBody',json_extract(items.json,'$.feedBody')) ELSE excluded.json END,
              date=COALESCE(items.date, excluded.date),
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

    // 이미 있는 key 들(400개씩 한 번에 — 채우기 전 거르기)
    func existing(_ keys: [String]) -> Set<String> {
        var out = Set<String>()
        for chunk in stride(from: 0, to: keys.count, by: 400).map({ Array(keys[$0..<min($0 + 400, keys.count)]) }) {
            queue.sync {
                run("SELECT key FROM items WHERE key IN (\(Array(repeating: "?", count: chunk.count).joined(separator: ",")))",
                    chunk.map { .text($0) }) { st in if let k = Self.text(st, 0) { out.insert(k) } }
            }
        }
        return out
    }

    // 기사 날짜(없으면 처음 본 때)가 [from, to) 안인 기사 수(빈 날 호를 엮기 전에 — 기사를 다 꺼내지 않고)
    func articleCount(from: Date, to: Date) -> Int {
        var n = 0
        queue.sync {
            run("""
            SELECT COUNT(*) FROM items WHERE COALESCE(date, first_seen) >= ? AND COALESCE(date, first_seen) < ?
              AND COALESCE(json_extract(json,'$.kind'),'article') = 'article'
            """, [.real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970)]) { st in n = Int(sqlite3_column_int64(st, 0)) }
        }
        return n
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

    // 스토리 카드에 꺼내는 보도 수: 출처마다 첫 보도 + 최근 이만큼(보도가 수천 건인 스토리도 목록을 만들 때 전부 풀지 않게)
    static let storySample = 40

    // 최근 스토리(보도 2건 이상)의 보도 견본을 한 번에(스토리 목록 — 스토리마다 따로 묻지 않게).
    // 견본: 출처마다 첫 보도(카드의 출처 줄·대표) + 최근 storySample 건(분야 다수결). 보도가 그보다 적으면 전부
    func storyMembers(since: Date) -> [String: [StoredItem]] {
        var out: [String: [StoredItem]] = [:]
        queue.sync {
            run("""
            SELECT i.json, i.first_seen, i.cluster FROM items i JOIN (
              SELECT r FROM (
                SELECT rowid AS r,
                       ROW_NUMBER() OVER (PARTITION BY cluster, source ORDER BY COALESCE(date, first_seen) ASC, rowid ASC) AS rs,
                       ROW_NUMBER() OVER (PARTITION BY cluster ORDER BY COALESCE(date, first_seen) DESC, rowid DESC) AS rn
                FROM items WHERE cluster IN (SELECT id FROM clusters WHERE last >= ? AND size >= 2)
              ) WHERE rs = 1 OR rn <= ?
            ) s ON i.rowid = s.r
            ORDER BY COALESCE(i.date, i.first_seen) ASC
            """, [.real(since.timeIntervalSince1970), .int(Self.storySample)]) { st in
                guard let c = Self.text(st, 2), let j = Self.text(st, 0), let it = try? Self.decoder.decode(NewsItem.self, from: Data(j.utf8)) else { return }
                out[c, default: []].append(StoredItem(item: it, firstSeen: Date(timeIntervalSince1970: sqlite3_column_double(st, 1)), cluster: c))
            }
        }
        return out
    }

    // 최근 스토리(보도 2건 이상)의 출처별 보도 수(보이는 보도 수·출처 수를 JSON 을 풀지 않고 세게)
    func storySourceCounts(since: Date) -> [String: [String: Int]] {
        var out: [String: [String: Int]] = [:]
        queue.sync {
            run("""
            SELECT cluster, source, COUNT(*) FROM items
            WHERE cluster IN (SELECT id FROM clusters WHERE last >= ? AND size >= 2)
            GROUP BY cluster, source
            """, [.real(since.timeIntervalSince1970)]) { st in
                guard let c = Self.text(st, 0) else { return }
                out[c, default: [:]][Self.text(st, 1) ?? "", default: 0] += Int(sqlite3_column_int64(st, 2))
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

    // 오래된 기록 정리(최근 keep 건 유지). 지우는 기사는 같은 트랜잭션에서 보관 표(archive)로 옮긴다 — 날짜·제목·링크·출처·분야만
    // (사진·요약·본문은 버림, 링크로 원문을 연다). 보관 표는 archiveYears 년이 지난 달부터 지운다(0 이면 달로는 지우지 않음),
    // 어느 경우든 archiveRowCap 건을 넘으면 가장 오래된 것부터 지운다.
    // 옮긴 기사만 지운다 — 고르기가 실패하면 아무것도 지우지 않고, 제목·링크를 읽지 못한 줄은 남긴다. 옮긴 건수를 돌려준다.
    static let archiveRowCap = 5_000_000
    @discardableResult
    func prune(keep: Int = 20000, archiveYears: Int = Archive.defaultYears, now: Date = Date(), rowCap: Int = Database.archiveRowCap,
               section: (NewsItem) -> String = { Sections.primary($0) }) -> Int {
        queue.sync {
            guard exec("BEGIN IMMEDIATE") else { return 0 }
            var moved = 0, ok = true, count = 0
            var rows: [(key: String, item: NewsItem, when: Double, story: String?)] = []
            ok = run("SELECT COUNT(*) FROM items", []) { st in count = Int(sqlite3_column_int64(st, 0)) }
            // 넘친 것이 없으면(확인 대부분) 정렬 질의를 건너뛴다. 본문 JSON 을 통째로 풀지 않고 칸만 꺼낸다
            if ok, count > keep {
                ok = run("""
                SELECT i.key, COALESCE(i.date, i.first_seen), CASE WHEN c.size >= 2 THEN i.cluster END,
                       json_extract(i.json,'$.title'), json_extract(i.json,'$.titleKo'), json_extract(i.json,'$.link'),
                       json_extract(i.json,'$.sourceName'), i.source, json_extract(i.json,'$.summary'), json_extract(i.json,'$.id')
                FROM items i LEFT JOIN clusters c ON c.id = i.cluster
                WHERE i.key IN (SELECT key FROM items ORDER BY COALESCE(date, first_seen) DESC LIMIT -1 OFFSET ?)
                """, [.int(keep)]) { st in
                    guard let key = Self.text(st, 0), let title = Self.text(st, 3), let link = Self.text(st, 5) else { return }
                    let it = NewsItem(id: Self.text(st, 9) ?? "", title: title, titleKo: Self.text(st, 4), link: link, date: nil,
                                      summary: Self.text(st, 8) ?? "", sourceId: Self.text(st, 7) ?? "", sourceName: Self.text(st, 6) ?? "", tier: "")
                    rows.append((key, it, sqlite3_column_double(st, 1), Self.text(st, 2)))
                }
            }
            var done: [String] = []
            for r in rows where ok {
                // 같은 날짜·링크가 이미 있으면 다시 넣지 않는다(지운 뒤 다시 받은 기사) — 이미 보관된 것이므로 items 에선 지운다
                ok = run("""
                INSERT INTO archive(date,title,title_ko,link,source,source_id,section,story) SELECT ?1,?2,?3,?4,?5,?6,?7,?8
                WHERE NOT EXISTS (SELECT 1 FROM archive WHERE date = ?1 AND link = ?4)
                """, [.real(r.when), .text(r.item.title), .text(r.item.titleKo), .text(r.item.link), .text(r.item.sourceName),
                      .text(r.item.sourceId), .text(section(r.item)), .text(r.story)])
                if ok { moved += Int(sqlite3_changes(db)); done.append(r.key) }
            }
            for chunk in stride(from: 0, to: done.count, by: 400).map({ Array(done[$0..<min($0 + 400, done.count)]) }) where ok {
                ok = run("DELETE FROM items WHERE key IN (\(Array(repeating: "?", count: chunk.count).joined(separator: ",")))", chunk.map { .text($0) })
            }
            ok = ok && run("DELETE FROM clusters WHERE id NOT IN (SELECT DISTINCT cluster FROM items WHERE cluster IS NOT NULL)", [])
            if let cutoff = Archive.cutoff(years: archiveYears, now: now) {
                ok = ok && run("DELETE FROM archive WHERE date < ?", [.real(cutoff.timeIntervalSince1970)])
            }
            // 줄 수 안전 상한('끝없이'여도) — 날짜 색인으로 rowCap 번째 날짜를 찾아 그보다 이른 것을 지운다
            ok = ok && run("DELETE FROM archive WHERE date < (SELECT date FROM archive ORDER BY date DESC LIMIT 1 OFFSET ?)", [.int(max(rowCap - 1, 0))]) // rowCap 번째 줄의 날짜보다 이른 것
            guard ok, exec("COMMIT") else { exec("ROLLBACK"); return 0 }
            return moved
        }
    }

    // MARK: 보관 표(지난 기사)
    private static let archiveColumns = "date, title, title_ko, link, source, section, story, source_id"
    private static func archived(_ st: OpaquePointer) -> ArchivedItem {
        ArchivedItem(date: Date(timeIntervalSince1970: sqlite3_column_double(st, 0)), title: text(st, 1) ?? "", titleKo: text(st, 2),
                     link: text(st, 3) ?? "", source: text(st, 4) ?? "", section: text(st, 5) ?? Sections.top, story: text(st, 6),
                     sourceId: text(st, 7))
    }
    private static func likePattern(_ q: String) -> String {
        "%" + q.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
    }
    private static func json(_ list: some Sequence<String>) -> String {
        String(decoding: (try? JSONEncoder().encode(Array(list).sorted())) ?? Data("[]".utf8), as: UTF8.self)
    }
    // 숨긴·끈·해지한 출처 빼기(기존 매거진 검색과 같은 기준 — SourceFilter). 출처 id 가 없는 줄은 숨긴 출처 이름으로
    private static func hideFilter(_ hide: Archive.Hide) -> (String, [Value]) {
        let active = hide.filter.active.map { json($0) }
        return ("""
         AND (CASE WHEN source_id IS NULL THEN source NOT IN (SELECT value FROM json_each(?))
              ELSE (source_id NOT IN (SELECT value FROM json_each(?)) AND (? IS NULL OR source_id IN (SELECT value FROM json_each(?)))) END)
        """, [.text(json(hide.hiddenNames)), .text(json(hide.filter.hidden)), .text(active), .text(active)])
    }
    // 분야·출처 거르기(nil 이면 모두) + 숨긴 출처 빼기
    private static func archiveFilter(_ section: String?, _ source: String?, _ hide: Archive.Hide) -> (String, [Value]) {
        var (sql, args) = hideFilter(hide)
        if let section { sql += " AND section = ?"; args.append(.text(section)) }
        if let source { sql += " AND source = ?"; args.append(.text(source)) }
        return (sql, args)
    }

    var archiveCount: Int {
        var n = 0
        queue.sync { run("SELECT COUNT(*) FROM archive", []) { st in n = Int(sqlite3_column_int64(st, 0)) } }
        return n
    }

    // 보관 표에서 제목·한국어 제목·출처로 찾기(FTS 없이 LIKE — 1년치 약 0.2초), 최신순. 검색어는 Archive.queryLimit 자까지.
    // '+date': 날짜 색인을 거꾸로 훑으며 줄마다 표를 찾아가면(맞는 것이 적을 때) 1년치 2초 — 표를 한 번 훑고 맞은 것만 정렬한다
    func searchArchive(_ q: String, limit: Int = 200, offset: Int = 0, hide: Archive.Hide = .init()) -> [ArchivedItem] {
        var out: [ArchivedItem] = []
        let (f, a) = Self.hideFilter(hide)
        queue.sync {
            run("""
            SELECT \(Self.archiveColumns) FROM archive
            WHERE (title LIKE ? ESCAPE '\\' OR title_ko LIKE ? ESCAPE '\\' OR source LIKE ? ESCAPE '\\')\(f)
            ORDER BY +date DESC LIMIT ? OFFSET ?
            """, Array(repeating: .text(Self.likePattern(Archive.trimQuery(q))), count: 3) + a + [.int(limit), .int(offset)]) { st in
                out.append(Self.archived(st))
            }
        }
        return out
    }

    // [from, to) 의 보관 기사(최신순, 날짜 색인)
    func archived(from: Date, to: Date, section: String? = nil, source: String? = nil, hide: Archive.Hide = .init(),
                  limit: Int = 100, offset: Int = 0) -> [ArchivedItem] {
        var out: [ArchivedItem] = []
        let (f, a) = Self.archiveFilter(section, source, hide)
        queue.sync {
            run("SELECT \(Self.archiveColumns) FROM archive WHERE date >= ? AND date < ?\(f) ORDER BY date DESC LIMIT ? OFFSET ?",
                [.real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970)] + a + [.int(limit), .int(offset)]) { st in out.append(Self.archived(st)) }
        }
        return out
    }

    // [from, to) 보관 기사의 날짜별 건수(이 Mac 의 날 기준 'YYYY-MM-DD'). 건수·거르기는 색인(date, section, source, source_id)만 읽는다
    func archiveDayCounts(from: Date, to: Date, section: String? = nil, source: String? = nil, hide: Archive.Hide = .init()) -> [String: Int] {
        var out: [String: Int] = [:]
        let (f, a) = Self.archiveFilter(section, source, hide)
        queue.sync {
            run("SELECT date(date,'unixepoch','localtime') AS d, COUNT(*) FROM archive WHERE date >= ? AND date < ?\(f) GROUP BY d",
                [.real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970)] + a) { st in
                if let d = Self.text(st, 0) { out[d] = Int(sqlite3_column_int64(st, 1)) }
            }
        }
        return out
    }

    // [from, to) 보관 기사의 분야별·출처별 건수(거르기 메뉴)
    func archiveFacets(from: Date, to: Date, hide: Archive.Hide = .init()) -> (sections: [String: Int], sources: [String: Int]) {
        var sections: [String: Int] = [:], sources: [String: Int] = [:]
        let (f, a) = Self.hideFilter(hide)
        queue.sync {
            run("SELECT section, source, COUNT(*) FROM archive WHERE date >= ? AND date < ?\(f) GROUP BY section, source",
                [.real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970)] + a) { st in
                let n = Int(sqlite3_column_int64(st, 2))
                sections[Self.text(st, 0) ?? Sections.top, default: 0] += n
                sources[Self.text(st, 1) ?? "", default: 0] += n
            }
        }
        return (sections, sources)
    }

    // 기록이 있는 가장 이른 때(보관 표와 최근 기사 중) — 보관함 ◀ 의 끝
    func earliestRecord() -> Date? {
        var out: Double?
        queue.sync {
            run("SELECT MIN(m) FROM (SELECT MIN(date) AS m FROM archive UNION ALL SELECT MIN(COALESCE(date, first_seen)) FROM items)", []) { st in
                if sqlite3_column_type(st, 0) != SQLITE_NULL { out = sqlite3_column_double(st, 0) }
            }
        }
        return out.map { Date(timeIntervalSince1970: $0) }
    }

    // 아직 items 에 있는 [from, to) 기사를 보관 표와 같은 가벼운 꼴로(본문 JSON 을 통째로 풀지 않게 칸만 꺼낸다). 숨긴 출처는 뺀다
    func recentLight(from: Date, to: Date, filter: SourceFilter = SourceFilter(),
                     section: @escaping (NewsItem) -> String = { Sections.primary($0) }) -> [ArchivedItem] {
        var out: [ArchivedItem] = []
        queue.sync {
            run("""
            SELECT COALESCE(i.date, i.first_seen), json_extract(i.json,'$.title'), json_extract(i.json,'$.titleKo'), json_extract(i.json,'$.link'),
                   json_extract(i.json,'$.sourceName'), i.source, json_extract(i.json,'$.summary'), json_extract(i.json,'$.id'),
                   CASE WHEN c.size >= 2 THEN i.cluster END
            FROM items i LEFT JOIN clusters c ON c.id = i.cluster
            WHERE COALESCE(i.date, i.first_seen) >= ? AND COALESCE(i.date, i.first_seen) < ?
            ORDER BY COALESCE(i.date, i.first_seen) DESC
            """, [.real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970)]) { st in
                let sid = Self.text(st, 5) ?? ""
                guard filter.shows(sid) else { return }
                let it = NewsItem(id: Self.text(st, 7) ?? "", title: Self.text(st, 1) ?? "", titleKo: Self.text(st, 2), link: Self.text(st, 3) ?? "",
                                  date: nil, summary: Self.text(st, 6) ?? "", sourceId: sid, sourceName: Self.text(st, 4) ?? "", tier: "")
                out.append(ArchivedItem(date: Date(timeIntervalSince1970: sqlite3_column_double(st, 0)), title: it.title, titleKo: it.titleKo,
                                        link: it.link, source: it.sourceName, section: section(it), story: Self.text(st, 8), sourceId: sid))
            }
        }
        return out
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

    // 주어진 스토리 id 가운데 아직 DB 에 있는 것(정리로 지워진 스토리의 기억을 치울 때)
    func existingClusters(_ ids: [String]) -> Set<String> {
        var out = Set<String>()
        queue.sync {
            for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
                let marks = chunk.map { _ in "?" }.joined(separator: ",")
                run("SELECT id FROM clusters WHERE id IN (\(marks))", chunk.map { .text($0) }) { st in
                    if let id = Self.text(st, 0) { out.insert(id) }
                }
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

    // MARK: 맛보기로 판정된 기사(미리 받기·읽기 — 목록·카드·물방울에 열기 전부터 '앞부분만')
    // 다시 받아 맛보기가 아니면 지운다. 30일 지난 것·2,000건 넘는 오래된 것은 버린다
    static let teaserLife: TimeInterval = 30 * 24 * 3600
    static let teaserLimit = 2000
    func markTeaser(_ link: String, _ teaser: Bool, now: Date = Date()) {
        queue.sync {
            if teaser {
                run("INSERT OR REPLACE INTO teasers(link,updated) VALUES(?,?)", [.text(link), .real(now.timeIntervalSince1970)])
                run("DELETE FROM teasers WHERE updated < ? OR updated > ?",
                    [.real(now.addingTimeInterval(-Self.teaserLife).timeIntervalSince1970), .real(now.addingTimeInterval(300).timeIntervalSince1970)])
                run("DELETE FROM teasers WHERE link NOT IN (SELECT link FROM teasers ORDER BY updated DESC LIMIT \(Self.teaserLimit))", [])
            } else {
                run("DELETE FROM teasers WHERE link=?", [.text(link)])
            }
        }
    }

    func teaserLinks(now: Date = Date()) -> Set<String> {
        var out: Set<String> = []
        queue.sync {
            run("SELECT link FROM teasers WHERE updated >= ?", [.real(now.addingTimeInterval(-Self.teaserLife).timeIntervalSince1970)]) { st in
                if let l = Self.text(st, 0) { out.insert(l) }
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
    // items 줄만: 피드 본문 전문(NewsItem.feedBody)까지 남긴다 — 다른 저장(스크랩 등)은 빼는 기본 인코더
    static let itemEncoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.userInfo[NewsItem.keepFeedBody] = true; return e }()
    // 피드 본문 전문(feedBody)도 읽는다(items 줄에만 있음)
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; d.userInfo[NewsItem.keepFeedBody] = true; return d }()
}
