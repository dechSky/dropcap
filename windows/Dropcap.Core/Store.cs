using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using Dropcap.Core;

namespace Dropcap.Core;

public enum ToastStyle { Drop, System }
public enum ToastPosition { Center, Right }

// 앱 상태. %LOCALAPPDATA%\Dropcap\native-state.json — 맥과 같은 항목·같은 이름
public sealed class AppState
{
    public Dictionary<string, double> Seen { get; set; } = new();
    public List<string> Seeded { get; set; } = new();
    public Dictionary<string, bool> Enabled { get; set; } = new();
    public List<NewsItem> Recent { get; set; } = new();
    public DateTimeOffset? LastCheck { get; set; }
    public Dictionary<string, string> Errors { get; set; } = new();
    public int Unread { get; set; }
    public Dictionary<string, double> Read { get; set; } = new();     // 읽은 기사 key → 읽은 시각
    public List<NewsItem> Saved { get; set; } = new();                // 나중에 읽기
    public List<Source> CustomSources { get; set; } = new();          // 직접 추가한 출처
    public DateTimeOffset? SnoozeUntil { get; set; }                  // 알림 잠시 끄기
    public DateTimeOffset? LastDigest { get; set; }                   // 마지막 아침 브리핑
    public Dictionary<string, double> InterestCategory { get; set; } = new(); // 분야별로 연 횟수(관심사)
    public Dictionary<string, double> InterestSource { get; set; } = new();
    public bool MagazineBackfilled { get; set; }                      // 처음 매거진을 채웠는지
    public Dictionary<string, bool> Notify { get; set; } = new();     // 출처별 알림(없으면 출처 기본값)
    public List<string> FollowedStories { get; set; } = new();        // 팔로우한 스토리(맥과 같은 항목 — 매거진 단계에서 씀)
    public Dictionary<string, int> StorySeen { get; set; } = new();   // 스토리를 마지막으로 봤을 때의 보도 수
    // 일반 뉴스 분야(G 절)
    public List<string>? SectionsChosen { get; set; }                           // 고른 관심 분야(null = 아직 고르지 않음 → 첫 실행 고르기 화면)
    public Dictionary<string, SectionPolicy> SectionPolicy { get; set; } = new(); // 분야별 알림 모드·묶음 시각·하루 상한
    public List<string> HiddenSources { get; set; } = new();                    // '이 출처 숨기기'(목록·매거진·알림 모두에서 뺌)
    public List<PendingItem> Pending { get; set; } = new();                     // 고인 소식(묶음 시각에 한 방울로)
    public List<NotifyMark> NotifyLog { get; set; } = new();                    // 떨어뜨린 물방울 기록(하루 상한 계산)
    public Dictionary<string, double> NotifiedStories { get; set; } = new();    // 알린 스토리 → 시각(같은 이야기 한 번만)
    public Dictionary<string, DateTimeOffset> LastBundle { get; set; } = new(); // 분야 → 마지막으로 묶음을 보낸 때
    public Dictionary<string, SectionBrief> Briefs { get; set; } = new();       // 분야 → 마지막 저녁 정리(묶음 시각에 기기 안 요약, N-26)
    public StateSettings Settings { get; set; } = new();

    public sealed record PendingItem(NewsItem Item, string Section, string Story, DateTimeOffset At);
    public sealed record NotifyMark(string Section, DateTimeOffset At);

    // 새 항목이 추가돼도 예전 파일을 그대로 읽는다(없거나 깨진 값은 기본값)
    public static AppState FromJson(string text) => TryFromJson(text) ?? new AppState();

    // 파일 전체가 JSON 이 아니면(중간에 잘림 등) null — 그때는 .bak 에서 되살린다
    public static AppState? TryFromJson(string text)
    {
        var s = new AppState();
        JsonObject? o;
        try { o = JsonNode.Parse(text) as JsonObject; } catch { o = null; }
        if (o is null) return null;
        s.Seen = Json.Field(o, "seen", s.Seen);
        s.Seeded = Json.Field(o, "seeded", s.Seeded);
        s.Enabled = Json.Field(o, "enabled", s.Enabled);
        s.Recent = Json.Field(o, "recent", s.Recent);
        s.LastCheck = Json.Field<DateTimeOffset?>(o, "lastCheck", null);
        s.Errors = Json.Field(o, "errors", s.Errors);
        s.Unread = Json.Field(o, "unread", 0);
        if (o["read"] is JsonArray old)
            s.Read = old.Select(n => n?.GetValue<string>()).OfType<string>().Distinct().ToDictionary(k => k, _ => 0.0); // 예전 형식(목록)
        else
            s.Read = Json.Field(o, "read", s.Read);
        s.Saved = Json.Field(o, "saved", s.Saved);
        s.CustomSources = Json.Field(o, "customSources", s.CustomSources);
        s.SnoozeUntil = Json.Field<DateTimeOffset?>(o, "snoozeUntil", null);
        s.LastDigest = Json.Field<DateTimeOffset?>(o, "lastDigest", null);
        s.InterestCategory = Json.Field(o, "interestCategory", s.InterestCategory);
        s.InterestSource = Json.Field(o, "interestSource", s.InterestSource);
        s.MagazineBackfilled = Json.Field(o, "magazineBackfilled", false);
        s.Notify = Json.Field(o, "notify", s.Notify);
        s.FollowedStories = Json.Field(o, "followedStories", s.FollowedStories);
        s.StorySeen = Json.Field(o, "storySeen", s.StorySeen);
        s.SectionsChosen = o["sectionsChosen"] is JsonArray ? Json.Field<List<string>?>(o, "sectionsChosen", null) : null;
        if (o["sectionPolicy"] is JsonObject sp)
            foreach (var (k, v) in sp) s.SectionPolicy[k] = Core.SectionPolicy.FromJson(v);
        s.HiddenSources = Json.Field(o, "hiddenSources", s.HiddenSources);
        s.Pending = Json.Field(o, "pending", s.Pending);
        s.NotifyLog = Json.Field(o, "notifyLog", s.NotifyLog);
        s.NotifiedStories = Json.Field(o, "notifiedStories", s.NotifiedStories);
        s.LastBundle = Json.Field(o, "lastBundle", s.LastBundle);
        s.Briefs = Json.Field(o, "briefs", s.Briefs);
        s.Settings = o["settings"] is JsonObject so ? StateSettings.FromJson(so) : new();
        return s;
    }

    public string ToJson() => JsonSerializer.Serialize(this, Json.Options);

    public AppState Clone() => FromJson(ToJson());
}

public sealed class StateSettings
{
    [JsonConverter(typeof(LowerEnum<ToastStyle>))] public ToastStyle Style { get; set; } = ToastStyle.Drop;
    public bool Sound { get; set; } = true;
    public int IntervalMinutes { get; set; } = 5;
    [JsonConverter(typeof(LowerEnum<ToastPosition>))] public ToastPosition Position { get; set; } = ToastPosition.Center;
    public bool QuietEnabled { get; set; }          // 방해 금지 시간
    public int QuietStart { get; set; } = 23;       // 시(0~23)
    public int QuietEnd { get; set; } = 7;
    public List<string> MustKeywords { get; set; } = new(); // 꼭 알림(중요 표시)
    public List<string> MuteKeywords { get; set; } = new(); // 알리지 않음
    public bool DigestEnabled { get; set; } = true;  // 아침 브리핑
    public int DigestHour { get; set; } = 9;
    public int TotalDailyCap { get; set; } = 10;    // 모든 분야를 합친 하루 물방울 수(G-06)
    public int KrThreshold { get; set; } = 3;       // 국내 n곳 이상 보도면 중요(G-05)
    public int IntlThreshold { get; set; } = 2;     // 해외 n곳 이상
    public int BigThreshold { get; set; } = 8;      // 국내 n곳 이상이면 상한 무시
    public bool AutoQuietFullscreen { get; set; } = true;  // 전체 화면 앱 사용 중에는 조용히(고임, N-25)
    public bool AutoQuietSharing { get; set; } = true;     // 화면 공유·기록 중
    public bool AutoQuietCalendar { get; set; }            // 캘린더 일정 중(윈도우는 지원하지 않음 — 패키지 없는 배포)

    [JsonIgnore] public PolicyLimits Limits => new() { TotalCap = TotalDailyCap, KrThreshold = KrThreshold, IntlThreshold = IntlThreshold, BigThreshold = BigThreshold };

    public static readonly int[] Intervals = [2, 5, 10, 15, 30];

    public static StateSettings FromJson(JsonObject o)
    {
        var d = new StateSettings();
        d.Style = Json.Field<string?>(o, "style", null) == "system" ? ToastStyle.System : ToastStyle.Drop;
        d.Sound = Json.Field(o, "sound", true);
        d.IntervalMinutes = Json.Field(o, "intervalMinutes", 5);
        d.Position = Json.Field<string?>(o, "position", null) == "right" ? ToastPosition.Right : ToastPosition.Center; // 예전 값 "auto" 도 가운데로
        d.QuietEnabled = Json.Field(o, "quietEnabled", false);
        d.QuietStart = Json.Field(o, "quietStart", 23);
        d.QuietEnd = Json.Field(o, "quietEnd", 7);
        d.MustKeywords = Json.Field(o, "mustKeywords", new List<string>());
        d.MuteKeywords = Json.Field(o, "muteKeywords", new List<string>());
        d.DigestEnabled = Json.Field(o, "digestEnabled", true);
        d.DigestHour = Json.Field(o, "digestHour", 9);
        d.TotalDailyCap = Json.Field(o, "totalDailyCap", 10);
        d.KrThreshold = Json.Field(o, "krThreshold", 3);
        d.IntlThreshold = Json.Field(o, "intlThreshold", 2);
        d.BigThreshold = Json.Field(o, "bigThreshold", 8);
        d.AutoQuietFullscreen = Json.Field(o, "autoQuietFullscreen", true);
        d.AutoQuietSharing = Json.Field(o, "autoQuietSharing", true);
        d.AutoQuietCalendar = Json.Field(o, "autoQuietCalendar", false);
        return d;
    }

    public StateSettings Copy()
    {
        var c = (StateSettings)MemberwiseClone();
        c.MustKeywords = MustKeywords.ToList();
        c.MuteKeywords = MuteKeywords.ToList();
        return c;
    }
}

// 맥 Codable 처럼 enum 을 소문자 글자로("drop", "center")
public sealed class LowerEnum<T> : JsonConverter<T> where T : struct, Enum
{
    public override T Read(ref Utf8JsonReader r, Type t, JsonSerializerOptions o) =>
        Enum.TryParse<T>(r.GetString(), ignoreCase: true, out var v) ? v : default;
    public override void Write(Utf8JsonWriter w, T v, JsonSerializerOptions o) => w.WriteStringValue(v.ToString().ToLowerInvariant());
}

public static class Store
{
    private static string? dir;

    // 시험용: DROPCAP_DATA_DIR 로 다른 폴더를 쓰면 실제 기록·구독을 건드리지 않는다(C-13)
    public static string Dir
    {
        get
        {
            if (dir is not null) return dir;
            var custom = Environment.GetEnvironmentVariable("DROPCAP_DATA_DIR");
            var d = !string.IsNullOrEmpty(custom)
                ? custom
                : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Dropcap");
            Directory.CreateDirectory(d);
            return dir = d;
        }
    }

    // 시험에서 폴더를 바꿀 때
    internal static void UseDir(string d) { Flush(); Directory.CreateDirectory(d); dir = d; backedUp = false; }

    public static string FilePath => Path.Combine(Dir, "native-state.json");
    public const int SeenLimit = 8000;

    public static bool Exists => File.Exists(FilePath);

    public static string BackupPath => Path.Combine(Dir, "native-state.bak.json");

    public static AppState Load()
    {
        var (s, fromBackup) = Read(FilePath, BackupPath);
        // 본 파일이 깨져 .bak 에서 읽었으면, 첫 저장 때 깨진 파일로 .bak 을 덮어쓰지 않게 한다
        if (fromBackup) backedUp = true;
        return Prepare(s, existing: File.Exists(FilePath) || fromBackup, Resources.Config.Sources);
    }

    // 읽은 상태를 쓸 수 있게 다듬는다(G-03, 맥 Store.prepare 와 같음).
    // - 예전(AI 전용) 사용자: 분야를 고른 적이 없으면 'AI' 하나만 고른 것으로 옮기고, AI 는 예전처럼 즉시 알림.
    // - 출처 켜기 기본값: 분야가 있는 출처는 그 분야를 골랐을 때만 기본으로 켠다(새로 생긴 국내 언론이 한꺼번에 켜지지 않게).
    public static AppState Prepare(AppState s, bool existing, IEnumerable<Source> sources, Dictionary<string, SourceMeta>? meta = null)
    {
        meta ??= Sections.Meta;
        if (s.SectionsChosen is null && existing)
        {
            s.SectionsChosen = [Sections.Ai];
            s.SectionPolicy[Sections.Ai] = new SectionPolicy { Mode = NotifyMode.Instant };
        }
        foreach (var src in sources.Concat(s.CustomSources))
        {
            if (s.Enabled.ContainsKey(src.Id)) continue;
            if (Sections.SectionOfSource(src.Id, meta) is { } sec && meta.TryGetValue(src.Id, out var m) && m.Section is not null)
                s.Enabled[src.Id] = src.DefaultOn && (s.SectionsChosen?.Contains(sec) ?? false);
            else
                s.Enabled[src.Id] = src.DefaultOn;
        }
        return s;
    }

    // 본 파일을 통째로 못 읽으면(깨짐) .bak 을 읽는다. 깨진 파일은 .broken.json 으로 남겨 둔다(맥 Store.read 와 같음).
    public static (AppState State, bool FromBackup) Read(string file, string backup)
    {
        string text;
        try { text = File.ReadAllText(file); } catch { return (new AppState(), false); }   // 처음 실행
        if (AppState.TryFromJson(text) is { } s) return (s, false);
        try { File.Copy(file, Path.ChangeExtension(file, "broken.json"), overwrite: true); } catch { }
        try { if (AppState.TryFromJson(File.ReadAllText(backup)) is { } b) return (b, true); } catch { }
        return (new AppState(), true);   // .bak 도 못 읽으면 새로 — 깨진 파일로 .bak 을 덮지 않게 표시
    }

    // 본 글 기억은 오래된 것부터 정리해 limit 개만 남긴다
    public static Dictionary<string, double> Pruned(Dictionary<string, double> seen, int limit = SeenLimit)
    {
        if (seen.Count <= limit) return seen;
        var o = new Dictionary<string, double>(seen);
        foreach (var (k, _) in seen.OrderBy(p => p.Value).Take(seen.Count - limit)) o.Remove(k);
        return o;
    }

    private static bool backedUp;
    private static readonly object writeLock = new();

    private static string? pending;   // 아직 쓰지 않은 마지막 상태(JSON)
    private static Timer? saveTimer;
    public static readonly TimeSpan SaveDelay = TimeSpan.FromSeconds(0.5);

    // 저장 묶기(C-13, 맥 StateSaver): 0.5초 안의 저장 요청은 마지막 것 하나만 뒤 스레드에서 쓴다.
    // 상태는 부르는 쪽(화면 스레드)에서 글자로 바꿔 두어, 쓰는 동안 상태가 바뀌어도 섞이지 않는다. 끝낼 때·잠들기 전에는 Flush.
    public static void Save(AppState state)
    {
        state.Seen = Pruned(state.Seen);
        var json = state.ToJson();
        lock (writeLock)
        {
            pending = json;
            saveTimer ??= new Timer(_ => Flush(), null, SaveDelay, Timeout.InfiniteTimeSpan);
        }
    }

    // 묶어 둔 저장을 지금 쓴다(끝낼 때·잠들기 전·시험)
    public static void Flush()
    {
        lock (writeLock)
        {
            saveTimer?.Dispose();
            saveTimer = null;
            if (pending is not { } json) return;
            pending = null;
            // 실행마다 첫 쓰기 전에 이전 파일을 .bak 으로 남긴다(형식이 바뀌어 일부를 못 읽었을 때 되살릴 수 있게)
            if (!backedUp && Exists)
            {
                backedUp = true;
                try { File.Copy(FilePath, BackupPath, overwrite: true); } catch { }
            }
            try { AtomicWrite(FilePath, json); } catch { }
        }
    }

    // 원자적 쓰기: 같은 폴더의 임시 파일에 쓴 뒤 바꿔 끼운다(쓰다 꺼져도 이전 파일이 남음)
    public static void AtomicWrite(string path, string text)
    {
        var tmp = path + ".tmp";
        File.WriteAllText(tmp, text);
        File.Move(tmp, path, overwrite: true);
    }
}

// 화면 설정(맥 UserDefaults 자리): 글꼴·글자 크기·정렬·스크랩 폴더 등. prefs.json
public static class Prefs
{
    private static readonly object gate = new();
    private static JsonObject? data;
    private static string FilePath => Path.Combine(Store.Dir, "prefs.json");

    private static JsonObject Data
    {
        get
        {
            if (data is not null) return data;
            try { data = File.Exists(FilePath) ? JsonNode.Parse(File.ReadAllText(FilePath)) as JsonObject : null; } catch { data = null; }
            return data ??= new JsonObject();
        }
    }

    public static T Get<T>(string key, T fallback) { lock (gate) return Json.Field(Data, key, fallback); }

    public static void Set<T>(string key, T value)
    {
        lock (gate)
        {
            Data[key] = JsonSerializer.SerializeToNode(value, Json.Options);
            try { Store.AtomicWrite(FilePath, Data.ToJsonString()); } catch { }
        }
    }

    internal static void Reset() { lock (gate) data = null; }
}
