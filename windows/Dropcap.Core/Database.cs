using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace Dropcap.Core;

// 매거진 기록 저장소: %LOCALAPPDATA%\Dropcap\magazine.sqlite — 맥 Database.swift 와 같은 표(M-02)
// 기사 · 스토리(같은 주제 묶음) · 호(발행본) · 스크랩을 둔다. 설정·읽음 기록은 native-state.json 에 남겨,
// 이 파일이 없거나 깨져도 앱의 알림 기능은 그대로 돈다(지우면 처음부터 다시 쌓임).
// 한 연결을 자물쇠로 감싸 한 번에 하나씩(맥의 직렬 큐와 같음). 화면 스레드에서는 Task.Run 으로 부른다(Q-07).
public sealed class Database : IDisposable
{
    private static Database? shared;
    private static readonly object sharedGate = new();
    public static Database Shared { get { lock (sharedGate) return shared ??= new Database(Path.Combine(Store.Dir, "magazine.sqlite")); } }

    public const int SchemaVersion = 1;
    private readonly SqliteConnection db;
    private readonly object gate = new();
    public string FilePath { get; }
    public bool Recreated { get; }        // 이번 실행에서 깨진 파일을 치우고 새로 만들었는가
    public int SalvagedScraps { get; }    // 그때 깨진 파일에서 건진 스크랩 수
    private int statements;
    internal int Statements => Volatile.Read(ref statements);   // 시험용: 실행한 문장 수(화면 하나에 DB 를 몇 번 묻는지)

    // 다른 연결이 잠갔을 때 바로 실패하지 않고 기다리는 시간(맥 busy handler 3초).
    // Microsoft.Data.Sqlite 는 잠김을 CommandTimeout(초) 동안 다시 시도한다(기본 30초 — 한 문장마다 30초를 기다려 받아 넣기가 몇 분씩 묶였다)
    public const int BusyTimeoutMs = 3000;
    private readonly int busySeconds;

    // busyTimeoutMs 는 시험에서만 바꾼다(초 단위로 올림, 적어도 1초 — 0 이면 끝없이 기다리므로)
    public Database(string file, int busyTimeoutMs = BusyTimeoutMs)
    {
        FilePath = file;
        busySeconds = Math.Max(1, (busyTimeoutMs + 999) / 1000);
        (db, Recreated) = OpenOrRecreate(file);
        Exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;");
        Exec("""
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
        """);
        // 출처 id 칸이 없던 보관 표(먼저 만든 판)에는 칸만 더한다(예전 줄은 null — 이름으로 거름)
        var hasSourceId = false;
        Run("SELECT name FROM pragma_table_info('archive')", [], r => { if (r.GetString(0) == "source_id") hasSourceId = true; });
        if (!hasSourceId) Exec("ALTER TABLE archive ADD COLUMN source_id TEXT;");
        Exec("""
        DROP INDEX IF EXISTS archive_date;
        CREATE INDEX IF NOT EXISTS archive_date_src ON archive(date, section, source, source_id);
        """);
        Exec($"PRAGMA user_version={SchemaVersion};");
        if (Recreated)
        {
            // 스크랩은 사용자가 만든 것이라 다시 쌓이지 않는다 → 치운 파일에서 읽을 수 있는 만큼 옮겨 온다
            SalvagedScraps = ImportScraps(BrokenPath(file));
            if (SalvagedScraps > 0) Console.Error.WriteLine($"[DB] 깨진 파일에서 스크랩 {SalvagedScraps}개를 옮겨 왔습니다");
        }
    }

    private static string BrokenPath(string file) => Path.ChangeExtension(file, null) + ".broken.sqlite";

    // 깨진(치운) DB 의 scraps 표를 읽기 전용으로 열어, 읽히는 줄까지 이 DB 로 옮긴다(시험·손 복구에도 씀)
    public int ImportScraps(string other)
    {
        if (!File.Exists(other)) return 0;
        var rows = new List<(string Id, string Collection, double Created, string Json)>();
        try
        {
            using var old = new SqliteConnection($"Data Source={other};Mode=ReadOnly;Pooling=False");
            old.Open();
            using var cmd = old.CreateCommand();
            cmd.CommandText = "SELECT id, collection, created, json FROM scraps";
            using var r = cmd.ExecuteReader();
            while (true)
            {
                try { if (!r.Read()) break; } catch (SqliteException) { break; } // 중간에 깨진 쪽을 만나면 거기까지
                try
                {
                    if (r.IsDBNull(0) || r.IsDBNull(3)) continue;
                    var json = r.GetString(3);
                    if (Json.Decode<Scrap>(json) is null) continue;
                    rows.Add((r.GetString(0), r.IsDBNull(1) ? Scrapbook.DefaultCollection : r.GetString(1), r.IsDBNull(2) ? 0 : r.GetDouble(2), json));
                }
                catch (Exception e) when (e is SqliteException or InvalidCastException or FormatException) { }
            }
        }
        catch (SqliteException) { }
        foreach (var x in rows)
            Run("INSERT OR IGNORE INTO scraps(id,collection,created,json) VALUES(?,?,?,?)", [x.Id, x.Collection, x.Created, x.Json]);
        return rows.Count;
    }

    // SQLite 는 깨진 파일도 열어 준다 — 첫 문장에서 '데이터베이스가 아님(26)/깨짐(11)'이 나오면 그때 옆으로 치운다
    // (그대로 두면 모든 읽기·쓰기가 조용히 실패해 새 스크랩까지 사라졌다 — 맥 감사 A 와 같음)
    private static (SqliteConnection, bool Recreated) OpenOrRecreate(string file)
    {
        var c = new SqliteConnection($"Data Source={file};Pooling=False");
        try
        {
            c.Open();
            using var probe = c.CreateCommand();
            probe.CommandText = "PRAGMA schema_version;";
            probe.ExecuteScalar();
            return (c, false);
        }
        catch (SqliteException e) when (e.SqliteErrorCode is 26 or 11)
        {
            c.Dispose();
            foreach (var ext in new[] { "", "-wal", "-shm" }) // 남은 WAL 이 새 파일에 섞이지 않게 함께 치운다
            {
                var from = file + ext;
                var broken = BrokenPath(file) + ext;
                try { if (File.Exists(from)) { File.Delete(broken); File.Move(from, broken); } } catch { }
            }
            var fresh = new SqliteConnection($"Data Source={file};Pooling=False");
            fresh.Open();
            return (fresh, true);
        }
    }

    public void Dispose() { lock (gate) db.Dispose(); }

    private void Exec(string sql)
    {
        lock (gate)
        {
            using var cmd = db.CreateCommand();
            cmd.CommandTimeout = Math.Max(1, busySeconds);
            cmd.CommandText = sql;
            try { cmd.ExecuteNonQuery(); } catch (SqliteException) { }
        }
    }

    private void Run(string sql, object?[] args, Action<SqliteDataReader>? row = null)
    {
        lock (gate)
        {
            Interlocked.Increment(ref statements);
            using var cmd = db.CreateCommand();
            cmd.CommandTimeout = busySeconds;
            cmd.CommandText = sql;
            for (var i = 0; i < args.Length; i++) cmd.Parameters.AddWithValue("$" + (i + 1), args[i] ?? DBNull.Value);
            // 맥과 같은 ? 자리표시를 $1, $2 … 로
            cmd.CommandText = Numbered(sql);
            using var r = cmd.ExecuteReader();
            while (r.Read()) row?.Invoke(r);
        }
    }

    private static string Numbered(string sql)
    {
        var sb = new System.Text.StringBuilder();
        var n = 0;
        var inQuote = false;
        foreach (var c in sql)
        {
            if (c == '\'') inQuote = !inQuote;
            if (c == '?' && !inQuote) sb.Append('$').Append(++n); else sb.Append(c);
        }
        return sb.ToString();
    }

    private static double Unix(DateTimeOffset d) => d.ToUnixTimeMilliseconds() / 1000.0;
    private static DateTimeOffset FromUnix(double s) => DateTimeOffset.FromUnixTimeMilliseconds((long)(s * 1000));

    // MARK: 기사
    public sealed record StoredItem(NewsItem Item, DateTimeOffset FirstSeen, string? Cluster);

    // 넣었으면 true. 잠김(오래)·디스크 가득 등으로 못 넣으면 false — 부르는 쪽이 다시 시도할 수 있게
    public bool TryUpsert(NewsItem item, string? cluster, DateTimeOffset? firstSeen = null)
    {
        try { Upsert(item, cluster, firstSeen); return true; }
        catch (SqliteException e) { Console.Error.WriteLine($"[DB] 넣기 실패({e.SqliteErrorCode}) {e.Message}"); return false; }
    }

    public void Upsert(NewsItem item, string? cluster, DateTimeOffset? firstSeen = null)
    {
        var seen = firstSeen ?? DateTimeOffset.Now;
        // 논문 피드(arXiv)는 날짜가 발표일 자정이라, 지면에는 받은 때를 기준으로 싣는다
        var when = item.ItemKind == ItemKind.Paper ? seen : item.Date;
        Run("""
            INSERT INTO items(key,json,date,first_seen,category,source,tier,cluster,image) VALUES(?,?,?,?,?,?,?,?,?)
            ON CONFLICT(key) DO UPDATE SET json=excluded.json, date=COALESCE(items.date, excluded.date),
              category=excluded.category, cluster=COALESCE(excluded.cluster, items.cluster), image=COALESCE(excluded.image, items.image)
            """, [item.Key, Json.Encode(item), when is null ? null : Unix(when.Value), Unix(seen), item.Category.Raw(), item.SourceId, item.Tier, cluster, item.Image]);
    }

    public void SetImage(string key, string url) =>
        Run("UPDATE items SET image=?, json=json_set(json,'$.image',?) WHERE key=?", [url, url, key]);

    public bool Exists(string key)
    {
        var found = false;
        Run("SELECT 1 FROM items WHERE key=?", [key], _ => found = true);
        return found;
    }

    // 이미 있는 key 들(400개씩 한 번에 — 매거진 채우기 전 거르기)
    public HashSet<string> Existing(IEnumerable<string> keys)
    {
        var o = new HashSet<string>();
        foreach (var chunk in keys.Distinct().Chunk(400))
        {
            var marks = string.Join(",", chunk.Select(_ => "?"));
            Run($"SELECT key FROM items WHERE key IN ({marks})", chunk.Cast<object?>().ToArray(), r => o.Add(r.GetString(0)));
        }
        return o;
    }

    // 기사 날짜(없으면 처음 본 때)가 [from, to) 안인 기사 수(빈 날 호를 엮기 전에 — 기사를 다 꺼내지 않고)
    public int ArticleCount(DateTimeOffset from, DateTimeOffset to)
    {
        var n = 0;
        Run("""
            SELECT COUNT(*) FROM items WHERE COALESCE(date, first_seen) >= ? AND COALESCE(date, first_seen) < ?
              AND COALESCE(json_extract(json,'$.kind'),'article') = 'article'
            """, [Unix(from), Unix(to)], r => n = (int)r.GetInt64(0));
        return n;
    }

    private static StoredItem? ReadStored(SqliteDataReader r)
    {
        var it = Json.Decode<NewsItem>(r.GetString(0));
        return it is null ? null : new StoredItem(it, FromUnix(r.GetDouble(1)), r.IsDBNull(2) ? null : r.GetString(2));
    }

    // 기사 날짜(없으면 처음 본 때)가 [from, to) 안인 것. articlesOnly 면 기사만(논문·릴리스 등 구독 채널 글 제외), channelsOnly 면 그 반대
    public List<StoredItem> Items(DateTimeOffset from, DateTimeOffset? to = null, int limit = 2000, bool articlesOnly = false, bool channelsOnly = false)
    {
        var o = new List<StoredItem>();
        var kind = articlesOnly ? "AND COALESCE(json_extract(json,'$.kind'),'article') = 'article'"
            : channelsOnly ? "AND COALESCE(json_extract(json,'$.kind'),'article') != 'article'" : "";
        Run($"""
            SELECT json, first_seen, cluster FROM items
            WHERE COALESCE(date, first_seen) >= ? AND COALESCE(date, first_seen) < ? {kind}
            ORDER BY COALESCE(date, first_seen) DESC LIMIT ?
            """, [Unix(from), to is null ? 4e10 : Math.Min(Unix(to.Value), 4e10), limit], r => { if (ReadStored(r) is { } s) o.Add(s); });
        return o;
    }

    // key 로 바로 꺼내기(호 그리기·표지 찾기)
    public List<StoredItem> ItemsByKeys(IReadOnlyList<string> keys)
    {
        var o = new List<StoredItem>();
        foreach (var chunk in keys.Chunk(400))
        {
            var marks = string.Join(",", chunk.Select(_ => "?"));
            Run($"SELECT json, first_seen, cluster FROM items WHERE key IN ({marks})", chunk.Cast<object?>().ToArray(),
                r => { if (ReadStored(r) is { } s) o.Add(s); });
        }
        return o;
    }

    public string? ClusterOf(string key)
    {
        string? c = null;
        Run("SELECT cluster FROM items WHERE key=?", [key], r => c = r.IsDBNull(0) ? null : r.GetString(0));
        return c;
    }

    // 기사마다 '같은 소식을 다룬 출처 수'(스토리 크기). 스토리에 묶이지 않았으면 빠짐
    public Dictionary<string, int> Coverage(IReadOnlyList<string> keys)
    {
        var o = new Dictionary<string, int>();
        foreach (var chunk in keys.Chunk(400))
        {
            var marks = string.Join(",", chunk.Select(_ => "?"));
            Run($"SELECT i.key, c.size FROM items i JOIN clusters c ON c.id = i.cluster WHERE i.key IN ({marks})", chunk.Cast<object?>().ToArray(),
                r => o[r.GetString(0)] = (int)r.GetInt64(1));
        }
        return o;
    }

    // 매거진이 받아 둔 기사 대표 사진(피드에 없어 기사 머리에서 찾은 것 포함)
    public string? Image(string key)
    {
        string? o = null;
        Run("SELECT image FROM items WHERE key=?", [key], r => o = r.IsDBNull(0) ? null : r.GetString(0));
        return o;
    }

    public List<StoredItem> ItemsInCluster(string id)
    {
        var o = new List<StoredItem>();
        Run("SELECT json, first_seen, cluster FROM items WHERE cluster=? ORDER BY COALESCE(date, first_seen) ASC", [id],
            r => { if (ReadStored(r) is { } s) o.Add(s); });
        return o;
    }

    // 스토리 카드에 꺼내는 보도 수: 출처마다 첫 보도 + 최근 이만큼(보도가 수천 건인 스토리도 목록을 만들 때 전부 풀지 않게)
    public const int StorySample = 40;

    // 최근 스토리(보도 2건 이상)의 보도 견본을 한 번에 — 스토리 목록이 스토리마다 따로 묻지 않게.
    // 견본: 출처마다 첫 보도(카드의 출처 줄·대표) + 최근 StorySample 건(분야 다수결). 보도가 그보다 적으면 전부
    public Dictionary<string, List<StoredItem>> StoryMembers(DateTimeOffset since)
    {
        var o = new Dictionary<string, List<StoredItem>>();
        Run("""
            SELECT i.json, i.first_seen, i.cluster FROM items i JOIN (
              SELECT r FROM (
                SELECT rowid AS r,
                       ROW_NUMBER() OVER (PARTITION BY cluster, source ORDER BY COALESCE(date, first_seen) ASC, rowid ASC) AS rs,
                       ROW_NUMBER() OVER (PARTITION BY cluster ORDER BY COALESCE(date, first_seen) DESC, rowid DESC) AS rn
                FROM items WHERE cluster IN (SELECT id FROM clusters WHERE last >= ? AND size >= 2)
              ) WHERE rs = 1 OR rn <= ?
            ) s ON i.rowid = s.r
            ORDER BY COALESCE(i.date, i.first_seen) ASC
            """, [Unix(since), StorySample], r =>
            {
                if (ReadStored(r) is not { Cluster: { } c } s) return;
                if (!o.TryGetValue(c, out var list)) o[c] = list = new();
                list.Add(s);
            });
        return o;
    }

    // 최근 스토리(보도 2건 이상)의 출처별 보도 수(보이는 보도 수·출처 수를 JSON 을 풀지 않고 세게)
    public Dictionary<string, Dictionary<string, int>> StorySourceCounts(DateTimeOffset since)
    {
        var o = new Dictionary<string, Dictionary<string, int>>();
        Run("""
            SELECT cluster, source, COUNT(*) FROM items
            WHERE cluster IN (SELECT id FROM clusters WHERE last >= ? AND size >= 2)
            GROUP BY cluster, source
            """, [Unix(since)], r =>
            {
                if (r.IsDBNull(0)) return;
                var c = r.GetString(0);
                if (!o.TryGetValue(c, out var m)) o[c] = m = new();
                var src = r.IsDBNull(1) ? "" : r.GetString(1);
                m[src] = m.GetValueOrDefault(src) + r.GetInt32(2);
            });
        return o;
    }

    public List<NewsItem> Search(string q, int limit = 200)
    {
        var o = new List<NewsItem>();
        var like = "%" + q.Replace("%", "\\%").Replace("_", "\\_") + "%";
        // 제목·한국어 제목·출처·요약에서만(JSON 의 필드 이름이나 주소에 걸리지 않게)
        Run("""
            SELECT json FROM items WHERE
              json_extract(json,'$.title') LIKE ? ESCAPE '\' OR json_extract(json,'$.titleKo') LIKE ? ESCAPE '\'
              OR json_extract(json,'$.sourceName') LIKE ? ESCAPE '\' OR json_extract(json,'$.summary') LIKE ? ESCAPE '\'
            ORDER BY COALESCE(date, first_seen) DESC LIMIT ?
            """, [like, like, like, like, limit],
            r => { if (Json.Decode<NewsItem>(r.GetString(0)) is { } it) o.Add(it); });
        return o;
    }

    public int ItemCount
    {
        get { var n = 0; Run("SELECT COUNT(*) FROM items", [], r => n = (int)r.GetInt64(0)); return n; }
    }

    // 정리 때 제목·링크를 읽지 못해 옮기지 못한 줄: 최신 이만큼까지만, 이 기간(초)이 지나면 지운다
    public const int BrokenKeep = 1000;
    public const double BrokenLifeSeconds = 30 * 24 * 3600;

    // 오래된 기록 정리(최근 keep 건 유지). 지우는 기사는 같은 트랜잭션에서 보관 표(archive)로 옮긴다 — 날짜·제목·링크·출처·분야만
    // (사진·요약·본문은 버림, 링크로 원문을 연다). 보관 표는 archiveYears 년이 지난 달부터 지우고(0 이면 기간으로는 지우지 않음),
    // 어느 때든 maxArchive 건을 넘으면 가장 오래된 것부터 지운다.
    // 제목·링크가 없는(빈) 줄은 옮기지 않고 남기되, 30일이 지났거나 BrokenKeep 건을 넘으면(오래된 것부터) 지운다 — 남은 줄 때문에 매번 정렬 질의가 돌지 않게.
    // 옮긴(또는 이미 있던) 기사만 지우고, 어디서든 실패하면 아무것도 바꾸지 않는다. 새로 옮긴 건수를 돌려준다.
    public int Prune(int keep = 20000, int archiveYears = Archive.DefaultYears, DateTimeOffset? now = null, Func<NewsItem, string>? section = null,
        int maxArchive = Archive.MaxRows)
    {
        section ??= it => Sections.Primary(it);
        lock (gate)
        {
            try { Raw("BEGIN IMMEDIATE"); }
            catch (SqliteException e) { Console.Error.WriteLine($"[DB] 정리 시작 실패({e.SqliteErrorCode}) {e.Message}"); return 0; }
            try
            {
                var moved = 0;
                // 넘친 것이 없으면(확인 대부분) 정렬 질의를 건너뛴다
                if (ItemCount > keep)
                {
                    // 본문 JSON 을 통째로 풀지 않고 칸만 꺼낸다(깨진 줄 하나가 정리 전체를 막지 않게)
                    var rows = new List<(string Key, double When, NewsItem Item, string? Story)>();
                    var broken = new List<(string Key, double When)>();
                    Run("""
                        SELECT i.key, COALESCE(i.date, i.first_seen), json_extract(i.json,'$.title'), json_extract(i.json,'$.titleKo'), json_extract(i.json,'$.link'),
                               json_extract(i.json,'$.sourceName'), COALESCE(json_extract(i.json,'$.sourceId'), i.source), json_extract(i.json,'$.summary'),
                               json_extract(i.json,'$.id'), CASE WHEN c.size >= 2 THEN i.cluster END
                        FROM items i LEFT JOIN clusters c ON c.id = i.cluster
                        WHERE i.key IN (SELECT key FROM items ORDER BY COALESCE(date, first_seen) DESC LIMIT -1 OFFSET ?)
                        """, [keep], r =>
                        {
                            string? S(int i) => r.IsDBNull(i) ? null : r.GetValue(i)?.ToString();
                            if (S(2) is not { Length: > 0 } title || S(4) is not { Length: > 0 } link) { broken.Add((r.GetString(0), r.GetDouble(1))); return; }   // 옮길 수 없는 줄
                            rows.Add((r.GetString(0), r.GetDouble(1), new NewsItem
                            {
                                Id = S(8) ?? "", Title = title, TitleKo = S(3), Link = link, SourceName = S(5) ?? "", SourceId = S(6) ?? "", Summary = S(7) ?? "", Tier = "",
                            }, S(9)));
                        });
                    var done = new List<string>();
                    foreach (var (key, when, it, story) in rows)
                    {
                        // 같은 날짜·링크가 이미 있으면 다시 넣지 않는다(지운 뒤 다시 받은 기사) — 이미 있으니 items 에서는 지운다
                        Run("""
                            INSERT INTO archive(date,title,title_ko,link,source,source_id,section,story) SELECT ?,?,?,?,?,?,?,?
                            WHERE NOT EXISTS (SELECT 1 FROM archive WHERE date = ? AND link = ?)
                            """, [when, it.Title, it.TitleKo, it.Link, it.SourceName, it.SourceId.Length > 0 ? it.SourceId : null, section(it), story, when, it.Link]);
                        moved += Changes();
                        done.Add(key);
                    }
                    // 읽지 못한 줄: 30일이 지난 것 + 최신 BrokenKeep 건 밖의 것
                    var stale = Unix(now ?? DateTimeOffset.Now) - BrokenLifeSeconds;
                    done.AddRange(broken.OrderByDescending(b => b.When).Where((b, i) => i >= BrokenKeep || b.When < stale).Select(b => b.Key));
                    foreach (var chunk in done.Chunk(400))
                        Run($"DELETE FROM items WHERE key IN ({string.Join(",", chunk.Select(_ => "?"))})", chunk.Cast<object?>().ToArray());
                }
                Run("DELETE FROM clusters WHERE id NOT IN (SELECT DISTINCT cluster FROM items WHERE cluster IS NOT NULL)", []);
                if (Archive.Cutoff(archiveYears, now ?? DateTimeOffset.Now) is { } cutoff)
                    Run("DELETE FROM archive WHERE date < ?", [Unix(cutoff)]);
                // 상한: 최신 maxArchive 건만 남기고 가장 오래된 것부터(모자라면 하위 질의가 null 이라 지우지 않음).
                // 큰 표에선 색인을 상한만큼 훑으므로 이번에 옮긴 것이 있을 때만(옮긴 게 없으면 줄 수가 늘지 않았다)
                if (moved > 0) Run("DELETE FROM archive WHERE date < (SELECT date FROM archive ORDER BY date DESC LIMIT 1 OFFSET ?)", [Math.Max(1, maxArchive) - 1]);
                Raw("COMMIT");
                return moved;
            }
            catch (Exception e) when (e is SqliteException or InvalidOperationException)
            {
                Console.Error.WriteLine($"[DB] 정리 실패 — 되돌림: {e.Message}");
                try { Raw("ROLLBACK"); } catch (SqliteException) { }
                return 0;
            }
        }
    }

    // 실패하면 예외를 던지는 문장(트랜잭션 시작·끝)
    private void Raw(string sql)
    {
        lock (gate)
        {
            using var cmd = db.CreateCommand();
            cmd.CommandTimeout = busySeconds;
            cmd.CommandText = sql;
            cmd.ExecuteNonQuery();
        }
    }

    private int Changes()
    {
        var n = 0;
        Run("SELECT changes()", [], r => n = (int)r.GetInt64(0));
        return n;
    }

    // MARK: 보관 표(지난 기사)
    private const string ArchiveColumns = "date, title, title_ko, link, source, section, story, source_id";
    private static ArchivedItem ReadArchived(SqliteDataReader r) => new(FromUnix(r.GetDouble(0)), r.IsDBNull(1) ? "" : r.GetString(1),
        r.IsDBNull(2) ? null : r.GetString(2), r.IsDBNull(3) ? "" : r.GetString(3), r.IsDBNull(4) ? "" : r.GetString(4),
        r.IsDBNull(5) ? Sections.Top : r.GetString(5), r.IsDBNull(6) ? null : r.GetString(6), r.IsDBNull(7) ? null : r.GetString(7));

    // LIKE 의 % _ \ 는 글자 그대로(ESCAPE '\')
    internal static string LikePattern(string q) => "%" + q.Replace("\\", "\\\\").Replace("%", "\\%").Replace("_", "\\_") + "%";

    // 보이는 출처만(숨긴 출처는 빼고, 켜진 출처 목록이 있으면 그 안만). 출처 id 가 없는 예전 줄은 숨긴 출처 이름으로 거른다
    // (그런 줄은 source_id 칸을 더하기 전 판에서만 생겨 끈·해지한 출처까지는 거르지 않는다 — 이름→id 로 채우려면 시작 때 표 전체를 훑어야 해서 두었다).
    // 모든 보관 표 질의(목록·날짜별 건수·거르기 메뉴·검색)가 같은 조각을 쓴다
    private static (string Sql, List<object?> Args) VisibleSources(SourceFilter? filter)
    {
        if (filter is null) return ("", new());
        string Arr(IEnumerable<string> xs) => JsonSerializer.Serialize(xs.Order(StringComparer.Ordinal).ToList());
        var active = filter.Active is null ? null : Arr(filter.Active);
        return ("""
             AND (CASE WHEN source_id IS NULL THEN source NOT IN (SELECT value FROM json_each(?))
               ELSE (source_id NOT IN (SELECT value FROM json_each(?)) AND (? IS NULL OR source_id IN (SELECT value FROM json_each(?)))) END)
            """, [Arr(filter.HiddenNames), Arr(filter.Hidden), active, active]);
    }

    // 분야·출처 거르기(null 이면 모두) + 보이는 출처
    private static (string Sql, List<object?> Args) ArchiveFilter(string? section, string? source, SourceFilter? filter)
    {
        var (sql, args) = VisibleSources(filter);
        if (section is not null) { sql += " AND section = ?"; args.Add(section); }
        if (source is not null) { sql += " AND source = ?"; args.Add(source); }
        return (sql, args);
    }

    public int ArchiveCount
    {
        get { var n = 0; Run("SELECT COUNT(*) FROM archive", [], r => n = (int)r.GetInt64(0)); return n; }
    }

    // 보관 표에서 제목·한국어 제목·출처로 찾기(FTS 없이 LIKE), 최신순. 검색어는 200글자까지.
    // '+date': 날짜 색인을 거꾸로 훑으며 줄마다 표를 찾아가면(맞는 것이 적을 때) 느리다 — 표를 한 번 훑고 맞은 것만 정렬한다
    public List<ArchivedItem> SearchArchive(string q, int limit = 200, int offset = 0, SourceFilter? filter = null)
    {
        var o = new List<ArchivedItem>();
        var like = LikePattern(Archive.TrimQuery(q));
        var (f, a) = VisibleSources(filter);
        Run($"""
            SELECT {ArchiveColumns} FROM archive
            WHERE (title LIKE ? ESCAPE '\' OR title_ko LIKE ? ESCAPE '\' OR source LIKE ? ESCAPE '\'){f}
            ORDER BY +date DESC LIMIT ? OFFSET ?
            """, [like, like, like, .. a, limit, offset], r => o.Add(ReadArchived(r)));
        return o;
    }

    // [from, to) 의 보관 기사(최신순, 날짜 색인)
    public List<ArchivedItem> Archived(DateTimeOffset from, DateTimeOffset to, string? section = null, string? source = null, int limit = 100, int offset = 0,
        SourceFilter? filter = null)
    {
        var o = new List<ArchivedItem>();
        var (f, a) = ArchiveFilter(section, source, filter);
        Run($"SELECT {ArchiveColumns} FROM archive WHERE date >= ? AND date < ?{f} ORDER BY date DESC LIMIT ? OFFSET ?",
            [Unix(from), Unix(to), .. a, limit, offset], r => o.Add(ReadArchived(r)));
        return o;
    }

    // [from, to) 보관 기사의 날짜별 건수(이 PC 의 날 기준 'yyyy-MM-dd'). 건수·거르기는 색인(date, section, source, source_id)만 읽는다
    public Dictionary<string, int> ArchiveDayCounts(DateTimeOffset from, DateTimeOffset to, string? section = null, string? source = null, SourceFilter? filter = null)
    {
        var o = new Dictionary<string, int>();
        var (f, a) = ArchiveFilter(section, source, filter);
        Run($"SELECT date(date,'unixepoch','localtime') AS d, COUNT(*) FROM archive WHERE date >= ? AND date < ?{f} GROUP BY d",
            [Unix(from), Unix(to), .. a], r => { if (!r.IsDBNull(0)) o[r.GetString(0)] = (int)r.GetInt64(1); });
        return o;
    }

    // [from, to) 보관 기사의 분야별·출처별 건수(거르기 메뉴) — 한 번에 묶어 센다
    public (Dictionary<string, int> Sections, Dictionary<string, int> Sources) ArchiveFacets(DateTimeOffset from, DateTimeOffset to, SourceFilter? filter = null)
    {
        var sections = new Dictionary<string, int>();
        var sources = new Dictionary<string, int>();
        var (f, a) = VisibleSources(filter);
        Run($"SELECT section, source, COUNT(*) FROM archive WHERE date >= ? AND date < ?{f} GROUP BY section, source", [Unix(from), Unix(to), .. a], r =>
        {
            var n = (int)r.GetInt64(2);
            var sec = r.IsDBNull(0) ? Sections.Top : r.GetString(0);
            var src = r.IsDBNull(1) ? "" : r.GetString(1);
            sections[sec] = sections.GetValueOrDefault(sec) + n;
            sources[src] = sources.GetValueOrDefault(src) + n;
        });
        return (sections, sources);
    }

    // 기록이 있는 가장 이른 때(보관 표와 최근 기사 중) — 보관함 ◀ 의 끝
    public DateTimeOffset? EarliestRecord()
    {
        DateTimeOffset? o = null;
        Run("SELECT MIN(m) FROM (SELECT MIN(date) AS m FROM archive UNION ALL SELECT MIN(COALESCE(date, first_seen)) FROM items)", [],
            r => { if (!r.IsDBNull(0)) o = FromUnix(r.GetDouble(0)); });
        return o;
    }

    // 아직 items 에 있는 [from, to) 기사를 보관 표와 같은 가벼운 꼴로(본문 JSON 을 통째로 풀지 않게 칸만 꺼낸다).
    // section: (key, 분야를 가를 만큼만 채운 기사) → 분야
    public List<ArchivedItem> RecentLight(DateTimeOffset from, DateTimeOffset to, Func<string, NewsItem, string>? section = null)
    {
        section ??= (_, it) => Sections.Primary(it);
        var o = new List<ArchivedItem>();
        Run("""
            SELECT COALESCE(i.date, i.first_seen), json_extract(i.json,'$.title'), json_extract(i.json,'$.titleKo'), json_extract(i.json,'$.link'),
                   json_extract(i.json,'$.sourceName'), i.source, json_extract(i.json,'$.summary'), json_extract(i.json,'$.id'),
                   CASE WHEN c.size >= 2 THEN i.cluster END, i.key
            FROM items i LEFT JOIN clusters c ON c.id = i.cluster
            WHERE COALESCE(i.date, i.first_seen) >= ? AND COALESCE(i.date, i.first_seen) < ?
            ORDER BY COALESCE(i.date, i.first_seen) DESC
            """, [Unix(from), Unix(to)], r =>
            {
                string? S(int i) => r.IsDBNull(i) ? null : r.GetValue(i)?.ToString();
                var it = new NewsItem
                {
                    Id = S(7) ?? "", Title = S(1) ?? "", TitleKo = S(2), Link = S(3) ?? "", Summary = S(6) ?? "",
                    SourceId = S(5) ?? "", SourceName = S(4) ?? "", Tier = "",
                };
                o.Add(new ArchivedItem(FromUnix(r.GetDouble(0)), it.Title, it.TitleKo, it.Link, it.SourceName, section(S(9) ?? it.Key, it), S(8), it.SourceId));
            });
        return o;
    }

    // MARK: 스토리
    public sealed record Cluster(string Id, string Title, HashSet<string> Tokens, DateTimeOffset First, DateTimeOffset Last, int Size)
    {
        public string Title { get; set; } = Title;
        public DateTimeOffset First { get; set; } = First;
        public DateTimeOffset Last { get; set; } = Last;
        public int Size { get; set; } = Size;
    }

    private static Cluster ReadCluster(SqliteDataReader r) => new(r.GetString(0), r.GetString(1),
        r.GetString(2).Split(' ', StringSplitOptions.RemoveEmptyEntries).ToHashSet(), FromUnix(r.GetDouble(3)), FromUnix(r.GetDouble(4)), (int)r.GetInt64(5));

    public List<Cluster> RecentClusters(DateTimeOffset since)
    {
        var o = new List<Cluster>();
        Run("SELECT id,title,tokens,first,last,size FROM clusters WHERE last >= ? ORDER BY last DESC", [Unix(since)], r => o.Add(ReadCluster(r)));
        return o;
    }

    public void SaveCluster(Cluster c) => Run("""
        INSERT INTO clusters(id,title,tokens,first,last,size) VALUES(?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET title=excluded.title, tokens=excluded.tokens, first=MIN(clusters.first, excluded.first),
          last=MAX(clusters.last, excluded.last), size=excluded.size
        """, [c.Id, c.Title, string.Join(" ", c.Tokens.Order(StringComparer.Ordinal)), Unix(c.First), Unix(c.Last), c.Size]);

    // DB 에 남은 스토리 id 모두(앱 상태의 스토리 기억 정리용)
    public HashSet<string> ClusterIds()
    {
        var o = new HashSet<string>();
        Run("SELECT id FROM clusters", [], r => o.Add(r.GetString(0)));
        return o;
    }

    public Cluster? GetCluster(string id)
    {
        Cluster? o = null;
        Run("SELECT id,title,tokens,first,last,size FROM clusters WHERE id=?", [id], r => o = ReadCluster(r));
        return o;
    }

    // MARK: 스크랩
    public void SaveScrap(Scrap s) =>
        Run("INSERT OR REPLACE INTO scraps(id,collection,created,json) VALUES(?,?,?,?)", [s.Id, s.Collection, Unix(s.Created), Json.Encode(s)]);

    public void DeleteScrap(string id) => Run("DELETE FROM scraps WHERE id=?", [id]);

    public List<Scrap> Scraps(string? collection = null)
    {
        var o = new List<Scrap>();
        if (collection is null)
            Run("SELECT json FROM scraps ORDER BY created DESC", [], r => { if (Json.Decode<Scrap>(r.GetString(0)) is { } s) o.Add(s); });
        else
            Run("SELECT json FROM scraps WHERE collection=? ORDER BY created DESC", [collection], r => { if (Json.Decode<Scrap>(r.GetString(0)) is { } s) o.Add(s); });
        return o;
    }

    public void RenameCollection(string from, string to)
    {
        foreach (var s in Scraps(from)) SaveScrap(s with { Collection = to });
    }

    // MARK: 호
    public void SaveIssue(Issue issue) =>
        Run("INSERT OR REPLACE INTO issues(id,kind,created,json) VALUES(?,?,?,?)", [issue.Id, issue.Kind.Raw(), Unix(issue.To), Json.Encode(issue)]); // 정렬은 호의 끝 시각

    public List<Issue> Issues(int limit = 120)
    {
        var o = new List<Issue>();
        Run("SELECT json FROM issues ORDER BY created DESC LIMIT ?", [limit], r => { if (Json.Decode<Issue>(r.GetString(0)) is { } i) o.Add(i); });
        return o;
    }

    public bool HasIssue(string id)
    {
        var found = false;
        Run("SELECT 1 FROM issues WHERE id=?", [id], _ => found = true);
        return found;
    }

    // MARK: 본문 추리기 기록(출처별 실패율 → 유료 기사 표시, G-14)
    public sealed record ExtractStat(int Tries = 0, int Fails = 0, int Blocked = 0)
    {
        public double FailRate => Tries == 0 ? 0 : (double)(Fails + Blocked) / Tries;
    }

    // 사용자가 연 기사 하나의 결과를 더한다. 50번이 넘으면 반으로 줄여 최근 결과가 더 크게 보이게.
    public void RecordExtract(string source, bool failed, bool blocked)
    {
        lock (gate)
        {
            Run("""
            INSERT INTO extract_stats(source,tries,fails,blocked,updated) VALUES(?,1,?,?,?)
            ON CONFLICT(source) DO UPDATE SET tries=tries+1, fails=fails+excluded.fails, blocked=blocked+excluded.blocked, updated=excluded.updated
            """, [source, failed ? 1 : 0, blocked ? 1 : 0, Unix(DateTimeOffset.Now)]);
            Run("UPDATE extract_stats SET tries=tries/2, fails=fails/2, blocked=blocked/2 WHERE source=? AND tries>50", [source]);
        }
    }

    public Dictionary<string, ExtractStat> ExtractStats()
    {
        var o = new Dictionary<string, ExtractStat>();
        Run("SELECT source,tries,fails,blocked FROM extract_stats", [], r => o[r.GetString(0)] = new ExtractStat(r.GetInt32(1), r.GetInt32(2), r.GetInt32(3)));
        return o;
    }

    // MARK: 맛보기로 판정된 기사(미리 받기·읽기 — 목록·카드·물방울에 열기 전부터 '앞부분만'). 맥 Database.markTeaser 와 같음
    // 다시 받아 맛보기가 아니면 지운다. 30일 지난 것·2,000건 넘는 오래된 것·5분 넘게 미래 시각인 것은 버린다
    public static readonly TimeSpan TeaserLife = TimeSpan.FromDays(30);
    public const int TeaserLimit = 2000;
    public void MarkTeaser(string link, bool teaser) => MarkTeaser(link, teaser, DateTimeOffset.Now);
    public void MarkTeaser(string link, bool teaser, DateTimeOffset now)
    {
        lock (gate)
        {
            if (teaser)
            {
                Run("INSERT OR REPLACE INTO teasers(link,updated) VALUES(?,?)", [link, Unix(now)]);
                Run("DELETE FROM teasers WHERE updated < ? OR updated > ?", [Unix(now - TeaserLife), Unix(now.AddSeconds(300))]);
                Run($"DELETE FROM teasers WHERE link NOT IN (SELECT link FROM teasers ORDER BY updated DESC LIMIT {TeaserLimit})", []);
            }
            else Run("DELETE FROM teasers WHERE link=?", [link]);
        }
    }

    public HashSet<string> TeaserLinks() => TeaserLinks(DateTimeOffset.Now);
    public HashSet<string> TeaserLinks(DateTimeOffset now)
    {
        var o = new HashSet<string>();
        lock (gate) Run("SELECT link FROM teasers WHERE updated >= ?", [Unix(now - TeaserLife)], r => o.Add(r.GetString(0)));
        return o;
    }

    // MARK: 사진 점수(분야 대표 사진 고르기, M-24)
    public void SaveImageScore(string url, PhotoQuality.Score s)
    {
        lock (gate)
        {
            Run("INSERT OR REPLACE INTO image_scores(url,score,text,colors,flat,updated) VALUES(?,?,?,?,?,?)",
                [url, s.Total, s.TextRatio, s.ColorVariety, s.Flatness, Unix(DateTimeOffset.Now)]);
            Run("DELETE FROM image_scores WHERE updated < ?", [Unix(DateTimeOffset.Now.AddDays(-30))]);
        }
    }

    public Dictionary<string, double> ImageScores(IReadOnlyList<string> urls)
    {
        var o = new Dictionary<string, double>();
        foreach (var chunk in urls.Distinct().Chunk(400))
            Run($"SELECT url, score FROM image_scores WHERE url IN ({string.Join(",", chunk.Select(_ => "?"))})", chunk.Cast<object?>().ToArray(),
                r => o[r.GetString(0)] = r.GetDouble(1));
        return o;
    }
}
