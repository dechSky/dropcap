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

    public Database(string file)
    {
        FilePath = file;
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
        CREATE TABLE IF NOT EXISTS image_scores(
          url TEXT PRIMARY KEY, score REAL NOT NULL, text REAL NOT NULL, colors REAL NOT NULL, flat REAL NOT NULL, updated REAL NOT NULL);
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
            cmd.CommandText = sql;
            try { cmd.ExecuteNonQuery(); } catch (SqliteException) { }
        }
    }

    private void Run(string sql, object?[] args, Action<SqliteDataReader>? row = null)
    {
        lock (gate)
        {
            using var cmd = db.CreateCommand();
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

    // 오래된 기록 정리(최근 20000건 유지)
    public void Prune(int keep = 20000)
    {
        Run("DELETE FROM items WHERE key IN (SELECT key FROM items ORDER BY COALESCE(date, first_seen) DESC LIMIT -1 OFFSET ?)", [keep]);
        Run("DELETE FROM clusters WHERE id NOT IN (SELECT DISTINCT cluster FROM items WHERE cluster IS NOT NULL)", []);
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
