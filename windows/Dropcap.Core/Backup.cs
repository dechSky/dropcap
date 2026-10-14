using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Dropcap.Core;

// 내 기록 내보내기·가져오기(P-08 · D-14): 집·회사 PC(또는 Mac) 사이를 옮길 때. 계정도 서버도 없이 JSON 파일 하나로.
// 맥 Core/Backup.swift 와 같은 파일: 같은 형식 이름·판·키 이름·날짜 모양(초까지 ISO-8601, Z). 맥에서 내보낸 파일을 그대로 가져오고 그 반대도 된다.
// 담는 것: 저장(나중에 읽기) · 스크랩과 스크랩 폴더 · 구독(직접 추가한 출처·켜고 끈 출처·출처별 알림) · 고른 분야와 분야별 알림 ·
// 알림 설정·낱말(꼭 알림·알리지 않음·지켜볼 낱말) · 숨긴 출처 · 팔로우한 스토리.
// 담지 않는 것: 기사 본문·번역 캐시, 사진, 매거진 기사 기록(다시 받으면 생김), 읽음 기록·본 글 기억.
public sealed class BackupFile
{
    public const string FormatName = "dropcap-backup";
    public const int CurrentVersion = 1;

    public string Format { get; set; } = FormatName;
    public int Version { get; set; } = CurrentVersion;
    public DateTimeOffset Exported { get; set; } = DateTimeOffset.UnixEpoch;
    public string App { get; set; } = "windows";
    public StateSettings Settings { get; set; } = new();
    public List<string>? SectionsChosen { get; set; }                         // null 이면 파일에서 빠진다(맥 Optional 과 같음)
    public Dictionary<string, SectionPolicy> SectionPolicy { get; set; } = new();
    public Dictionary<string, bool> Enabled { get; set; } = new();
    public Dictionary<string, bool> Notify { get; set; } = new();
    public List<Source> CustomSources { get; set; } = new();
    public List<string> HiddenSources { get; set; } = new();
    public List<string> FollowedStories { get; set; } = new();
    public List<NewsItem> Saved { get; set; } = new();
    public List<Scrap> Scraps { get; set; } = new();
    public List<string> ScrapFolders { get; set; } = new();

    // 항목이 빠졌거나(예전·다른 앱이 만든 파일) 일부가 깨져도 나머지는 읽는다. 모르는 키는 건너뜀
    public static BackupFile FromJson(JsonObject o)
    {
        var b = new BackupFile
        {
            Format = Json.Field<string?>(o, "format", null) ?? FormatName,
            Version = Json.Field(o, "version", 1),
            Exported = Json.Field(o, "exported", DateTimeOffset.UnixEpoch),
            App = Json.Field<string?>(o, "app", null) ?? "?",
            Settings = o["settings"] is JsonObject so ? StateSettings.FromJson(so) : new(),
            SectionsChosen = o["sectionsChosen"] is JsonArray ? Json.Field<List<string>?>(o, "sectionsChosen", null) : null,
            Enabled = Json.Field(o, "enabled", new Dictionary<string, bool>()),
            Notify = Json.Field(o, "notify", new Dictionary<string, bool>()),
            CustomSources = Json.Field(o, "customSources", new List<Source>()),
            HiddenSources = Json.Field(o, "hiddenSources", new List<string>()),
            FollowedStories = Json.Field(o, "followedStories", new List<string>()),
            Saved = Json.Field(o, "saved", new List<NewsItem>()),
            Scraps = Json.Field(o, "scraps", new List<Scrap>()),
            ScrapFolders = Json.Field(o, "scrapFolders", new List<string>()),
        };
        if (o["sectionPolicy"] is JsonObject sp)
            foreach (var (k, v) in sp) b.SectionPolicy[k] = Core.SectionPolicy.FromJson(v);
        b.Sanitize();
        return b;
    }

    // 바깥에서 온 파일이므로 설정 화면이 고를 수 있는 값만 남긴다(보안 검토: 가져오기가 설정 화면의 검사를 건너뛰지 않게).
    // 범위 밖 수치는 가장 가까운 허용값으로, 직접 추가 출처는 공개 http(s) 피드만(사이트맵·정규식은 앱에 든 기본 출처만 씀), 낱말은 개수·길이 제한.
    public void Sanitize()
    {
        var st = Settings;
        st.IntervalMinutes = StateSettings.Intervals.Contains(st.IntervalMinutes) ? st.IntervalMinutes : 5;
        st.QuietStart = Math.Clamp(st.QuietStart, 0, 23);
        st.QuietEnd = Math.Clamp(st.QuietEnd, 0, 23);
        st.DigestHour = Math.Clamp(st.DigestHour, SettingsBounds.DigestFrom, SettingsBounds.DigestTo);
        st.TotalDailyCap = Math.Clamp(st.TotalDailyCap, 1, 30);
        st.KrThreshold = Math.Clamp(st.KrThreshold, 1, 10);
        st.IntlThreshold = Math.Clamp(st.IntlThreshold, 1, 10);
        st.BigThreshold = Math.Clamp(st.BigThreshold, 2, 20);
        st.MustKeywords = Words(st.MustKeywords);
        st.MuteKeywords = Words(st.MuteKeywords);
        st.WatchKeywords = Words(st.WatchKeywords);
        foreach (var k in SectionPolicy.Keys.ToList())
        {
            if (Sections.ById(k) is null) { SectionPolicy.Remove(k); continue; }
            var p = SectionPolicy[k];
            SectionPolicy[k] = p with { BundleHour = Math.Clamp(p.BundleHour, SettingsBounds.BundleFrom, SettingsBounds.BundleTo), DailyCap = Math.Clamp(p.DailyCap, SettingsBounds.CapMin, SettingsBounds.CapMax) };
        }
        SectionsChosen = SectionsChosen?.Where(id => Sections.ById(id) is not null).Distinct().ToList();
        CustomSources = CustomSources
            .Where(s => s.Id.StartsWith("custom-", StringComparison.Ordinal) && s.Id.Length <= 64 && UrlSafety.IsPublicHttp(s.Url))
            .Select(s => s with
            {
                Type = "feed", Match = null, AiOnly = false,
                Name = s.Name.Length > 80 ? s.Name[..80] : s.Name,
                Color = s.Color is { Length: >= 4 and <= 9 } c && c[0] == '#' && c.Skip(1).All(Uri.IsHexDigit) ? c : "#3B82F6", // 화면에서는 SafeColor 를 한 번 더 거침
                Tier = s.Tier is "lab" or "press" or "kr" ? s.Tier : "press",
                Home = s.Home is { } h && UrlSafety.IsPublicHttp(h) ? h : null,
            })
            .Take(500).ToList();
        HiddenSources = HiddenSources.Where(x => x.Length is > 0 and <= 64).Distinct().Take(500).ToList();
        FollowedStories = FollowedStories.Where(x => x.Length is > 0 and <= 64).Distinct().Take(1000).ToList();
        ScrapFolders = ScrapFolders.Where(x => x.Trim().Length is > 0 and <= 60).Distinct().Take(200).ToList();
    }

    // 낱말: 빈 것 빼고 40자까지, 200개까지(설정 화면에서 넣을 수 있는 정도)
    private static List<string> Words(List<string> list) =>
        list.Select(w => w.Trim()).Where(w => w.Length is > 0 and <= 40).Distinct(StringComparer.OrdinalIgnoreCase).Take(200).ToList();
}

// 가져오기·되돌리기가 안 될 때(맥 Backup.Failure 와 같은 글)
public sealed class BackupException(string message) : Exception(message)
{
    public static BackupException NotBackup() => new("Dropcap 기록 파일이 아닙니다");
    public static BackupException NewerVersion(int v) => new($"더 새 판 Dropcap 이 만든 기록입니다(형식 {v}). 앱을 업데이트한 뒤 가져오세요");
}

// 설정 화면에 보일 결과 한 줄(Ok 가 false 면 Message 가 까닭)
public sealed record BackupResult(bool Ok, string Message, Backup.Summary? Summary = null);

public static class Backup
{
    public static BackupFile Make(AppState s, IEnumerable<Scrap> scraps, IEnumerable<string> folders, DateTimeOffset? now = null) => new()
    {
        Exported = now ?? DateTimeOffset.Now,
        Settings = s.Settings.Copy(),
        SectionsChosen = s.SectionsChosen?.ToList(),
        SectionPolicy = new(s.SectionPolicy),
        Enabled = new(s.Enabled),
        Notify = new(s.Notify),
        CustomSources = s.CustomSources.ToList(),
        HiddenSources = s.HiddenSources.ToList(),
        FollowedStories = s.FollowedStories.ToList(),
        Saved = s.Saved.ToList(),
        Scraps = scraps.ToList(),
        ScrapFolders = folders.ToList(),
    };

    // 맥 JSONEncoder(.prettyPrinted, .sortedKeys, 날짜 .iso8601) 와 같은 글자 모양으로 쓴다(두 판에서 내보낸 파일을 나란히 견줄 수 있게)
    public static string Encode(BackupFile b)
    {
        var node = JsonSerializer.SerializeToNode(b, Json.Options);
        var o = new StringBuilder();
        WriteMac(o, node, 0);
        return o.ToString();
    }

    public static BackupFile Decode(string text)
    {
        JsonObject? o;
        try { o = JsonNode.Parse(text.TrimStart('﻿')) as JsonObject; } catch { o = null; }
        // 형식 이름·판을 먼저 본다(다른 JSON 이거나 새 판이면 알아듣게)
        if (o is null || !TryString(o["format"], out var format) || format != BackupFile.FormatName) throw BackupException.NotBackup();
        if (o["version"] is { } vn)
        {
            if (vn.GetValueKind() == JsonValueKind.Null) { }
            else if (vn.GetValueKind() != JsonValueKind.Number || !vn.AsValue().TryGetValue<int>(out var v)) throw BackupException.NotBackup();
            else if (v > BackupFile.CurrentVersion) throw BackupException.NewerVersion(v);
        }
        return BackupFile.FromJson(o);
    }

    private static bool TryString(JsonNode? n, out string s)
    {
        s = "";
        if (n is null || n.GetValueKind() != JsonValueKind.String) return false;
        s = n.GetValue<string>();
        return true;
    }

    public sealed record Summary
    {
        public int Saved { get; set; }
        public int Scraps { get; set; }
        public int Folders { get; set; }
        public int Sources { get; set; }
        public int Sections { get; set; }
        public int Words { get; set; }
        public int Hidden { get; set; }
        public int Followed { get; set; }
        public bool SettingsTaken { get; set; }

        public string Text
        {
            get
            {
                var parts = new List<string>();
                if (Saved > 0) parts.Add($"저장 {Saved}");
                if (Scraps > 0) parts.Add($"스크랩 {Scraps}");
                if (Folders > 0) parts.Add($"폴더 {Folders}");
                if (Sources > 0) parts.Add($"구독 {Sources}");
                if (Sections > 0) parts.Add($"분야 {Sections}");
                if (Words > 0) parts.Add($"낱말 {Words}");
                if (Hidden > 0) parts.Add($"숨긴 출처 {Hidden}");
                if (Followed > 0) parts.Add($"팔로우 {Followed}");
                if (SettingsTaken) parts.Add("알림 설정");
                return parts.Count == 0 ? "새로 더할 것이 없었습니다(모두 이미 있음)" : string.Join(" · ", parts) + " 더함";
            }
        }
    }

    public sealed record Merged(AppState State, List<Scrap> NewScraps, List<string> Folders, Summary Summary);

    // 합치기: 이 기기에 없는 것만 더하고 같은 것은 건너뛴다. 이 기기의 값을 지우거나 끄지 않는다.
    // 알림 설정(시각·상한 등 낱개 값)은 이 기기가 아직 처음 그대로일 때만 가져온 값을 쓴다(새 PC 로 옮길 때). 낱말 목록은 늘 합친다.
    public static Merged Merge(BackupFile b, AppState s0, IReadOnlyList<Scrap> scraps, IReadOnlyList<string> folders)
    {
        var s = s0.Clone();
        var sum = new Summary();
        static List<string> Union(List<string> a, List<string> b, ref int count)
        {
            var o = a.ToList();
            foreach (var x in b)
                if (!o.Any(y => y.ToLowerInvariant() == x.ToLowerInvariant())) { o.Add(x); count++; }
            return o;
        }
        // 알림 설정
        var bare = s.Settings.Copy();
        bare.MustKeywords = []; bare.MuteKeywords = []; bare.WatchKeywords = [];
        if (SameSettings(bare, new StateSettings()))
        {
            var taken = b.Settings.Copy();
            taken.MustKeywords = s.Settings.MustKeywords.ToList();
            taken.MuteKeywords = s.Settings.MuteKeywords.ToList();
            taken.WatchKeywords = s.Settings.WatchKeywords.ToList();
            if (!SameSettings(taken, s.Settings)) sum.SettingsTaken = true;
            s.Settings = taken;
        }
        int words = 0, hidden = 0, followed = 0;
        s.Settings.MustKeywords = Union(s.Settings.MustKeywords, b.Settings.MustKeywords, ref words);
        s.Settings.MuteKeywords = Union(s.Settings.MuteKeywords, b.Settings.MuteKeywords, ref words);
        s.Settings.WatchKeywords = Union(s.Settings.WatchKeywords, b.Settings.WatchKeywords, ref words);
        sum.Words = words;
        // 분야
        if (b.SectionsChosen is { } theirs)
        {
            var mine = s.SectionsChosen ?? [];
            var add = theirs.Where(x => !mine.Contains(x)).ToList();
            sum.Sections = add.Count;
            if (s.SectionsChosen is null || add.Count > 0) s.SectionsChosen = mine.Concat(add).OrderBy(Sections.Order).ToList();
        }
        foreach (var (k, v) in b.SectionPolicy) if (!s.SectionPolicy.ContainsKey(k)) s.SectionPolicy[k] = v;
        // 구독: 직접 추가한 출처(같은 id·주소는 건너뜀), 켜 둔 출처는 켬(끄지는 않음), 출처별 알림은 없는 것만
        foreach (var src in b.CustomSources)
        {
            if (s.CustomSources.Any(x => x.Id == src.Id || x.Url == src.Url)) continue;
            s.CustomSources.Add(src); sum.Sources++;
        }
        foreach (var (k, v) in b.Enabled) if (v && !(s.Enabled.TryGetValue(k, out var on) && on)) s.Enabled[k] = true;
        foreach (var (k, v) in b.Notify) if (!s.Notify.ContainsKey(k)) s.Notify[k] = v;
        s.HiddenSources = Union(s.HiddenSources, b.HiddenSources, ref hidden);
        s.FollowedStories = Union(s.FollowedStories, b.FollowedStories, ref followed);
        sum.Hidden = hidden; sum.Followed = followed;
        // 저장(같은 기사는 건너뜀, 가져온 것은 뒤에)
        foreach (var it in b.Saved)
        {
            if (s.Saved.Any(x => x.Key == it.Key)) continue;
            s.Saved.Add(it); sum.Saved++;
        }
        // 스크랩(같은 id, 또는 같은 기사·같은 문단·같은 폴더면 건너뜀)
        var newScraps = new List<Scrap>();
        foreach (var sc in b.Scraps)
            if (!scraps.Concat(newScraps).Any(x => x.Id == sc.Id || (x.Item.Key == sc.Item.Key && x.Quote == sc.Quote && x.Collection == sc.Collection)))
                newScraps.Add(sc);
        sum.Scraps = newScraps.Count;
        var fs = folders.ToList();
        foreach (var f in b.ScrapFolders.Concat(newScraps.Select(x => x.Collection)))
            if (!fs.Contains(f)) { fs.Add(f); sum.Folders++; }
        return new Merged(s, newScraps, fs, sum);
    }

    // 되돌리기: 가져오기 전에 남긴 파일의 값으로 그 항목들을 그대로 바꾼다(가져오기로 더해진 것이 빠진다)
    public static AppState Restore(BackupFile b, AppState s0)
    {
        var s = s0.Clone();
        s.Settings = b.Settings.Copy();
        s.SectionsChosen = b.SectionsChosen?.ToList();
        s.SectionPolicy = new(b.SectionPolicy);
        s.Enabled = new(b.Enabled);
        s.Notify = new(b.Notify);
        s.CustomSources = b.CustomSources.ToList();
        s.HiddenSources = b.HiddenSources.ToList();
        s.FollowedStories = b.FollowedStories.ToList();
        s.Saved = b.Saved.ToList();
        return s;
    }

    public static bool SameSettings(StateSettings a, StateSettings b) => Json.Encode(a) == Json.Encode(b);

    // MARK: 앱 안에서: 가져오기 전 자동 백업 · 되돌리기(맥 BackupManager)
    // 설정 화면은 Export/ExportTo 로 내보내고, Import/ImportFrom 으로 합치고, CanUndo 일 때 UndoLastImport 를 보인다.

    public static string Dir => Path.Combine(Store.Dir, "backups");
    public const int KeepBeforeImport = 5;
    internal static Func<DateTimeOffset> Now { get; set; } = () => DateTimeOffset.Now;

    public static string Stamp(DateTimeOffset d) => d.ToLocalTime().ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture);

    // 저장 창에 넣어 줄 이름(맥과 같은 'Dropcap-기록-20261014.json')
    public static string SuggestedFileName => $"Dropcap-기록-{Stamp(Now())[..8]}.json";

    // 마지막 가져오기 전에 남긴 파일(되돌리기)
    public static string? LatestBeforeImport()
    {
        try
        {
            if (!Directory.Exists(Dir)) return null;
            return Directory.GetFiles(Dir, "before-import-*").OrderBy(Path.GetFileName, StringComparer.Ordinal).LastOrDefault();
        }
        catch { return null; }
    }

    public static bool CanUndo => LatestBeforeImport() is not null;

    public static BackupFile Current(AppModel model, Scrapbook book) => Make(model.State, book.Scraps, book.Collections, Now());

    public static string Export(AppModel model, Scrapbook book) => Encode(Current(model, book));

    public static BackupResult ExportTo(string path, AppModel model, Scrapbook book)
    {
        try
        {
            Store.AtomicWrite(path, Export(model, book));
            return new(true, $"내보냈습니다: {Path.GetFileName(path)}");
        }
        catch (Exception e) { return new(false, $"내보내지 못했습니다: {e.Message}"); }
    }

    public static BackupResult ImportFrom(string path, AppModel model, Scrapbook book)
    {
        string text;
        try { text = File.ReadAllText(path); }
        catch (Exception e) { return new(false, $"가져오지 못했습니다: {e.Message}"); }
        return Import(text, model, book);
    }

    // 가져오기 전 지금 기록을 backups/ 에 남기고(최근 5개만), 합친다
    public static BackupResult Import(string json, AppModel model, Scrapbook book)
    {
        try
        {
            var b = Decode(json);
            Directory.CreateDirectory(Dir);
            var before = Path.Combine(Dir, $"before-import-{Stamp(Now())}.json");
            Store.AtomicWrite(before, Export(model, book));
            Prune();
            var m = Merge(b, model.State, book.Scraps, book.Collections);
            Apply(model, book, m);
            return new(true, "가져왔습니다 — " + m.Summary.Text, m.Summary);
        }
        catch (Exception e) { return new(false, $"가져오지 못했습니다: {e.Message}"); }
    }

    public static BackupResult UndoLastImport(AppModel model, Scrapbook book)
    {
        if (LatestBeforeImport() is not { } f) return new(false, "되돌리지 못했습니다: 되돌릴 가져오기가 없습니다");
        try
        {
            var b = Decode(File.ReadAllText(f));
            var keep = b.Scraps.Select(x => x.Id).ToHashSet();
            foreach (var s in book.Scraps.ToList()) if (!keep.Contains(s.Id)) book.Remove(s);   // 가져온 뒤 더해진 스크랩은 뺀다
            var have = book.Scraps.Select(x => x.Id).ToHashSet();
            foreach (var s in b.Scraps) if (!have.Contains(s.Id)) book.Update(s);
            Prefs.Set("scrapCollections", b.ScrapFolders.Where(c => c != Scrapbook.DefaultCollection).ToList());
            model.ReplaceState(s => Restore(b, s));
            book.Reload();
            try { File.Delete(f); } catch { }
            return new(true, "가져오기 전으로 되돌렸습니다");
        }
        catch (Exception e) { return new(false, $"되돌리지 못했습니다: {e.Message}"); }
    }

    private static void Apply(AppModel model, Scrapbook book, Merged m)
    {
        foreach (var s in m.NewScraps) book.Update(s);
        var used = book.Scraps.Select(x => x.Collection).ToHashSet();
        Prefs.Set("scrapCollections", m.Folders.Where(c => !used.Contains(c) && c != Scrapbook.DefaultCollection).ToList());
        model.ReplaceState(_ => m.State);
        book.Reload();
    }

    private static void Prune()
    {
        try
        {
            var files = Directory.GetFiles(Dir, "before-import-*").OrderBy(Path.GetFileName, StringComparer.Ordinal).ToList();
            foreach (var f in files.Take(Math.Max(0, files.Count - KeepBeforeImport))) { try { File.Delete(f); } catch { } }
        }
        catch { }
    }

    // MARK: 맥 JSONEncoder 글자 모양
    // 들여쓰기 2칸, 키와 값 사이 " : ", 키는 글자 순(서수), 빈 목록은 "[\n\n  ]", '/' 는 "\/", 제어 문자는 \u00xx.
    private static void WriteMac(StringBuilder o, JsonNode? n, int level)
    {
        var pad = new string(' ', level * 2);
        var inner = new string(' ', (level + 1) * 2);
        switch (n)
        {
            case null:
                o.Append("null");
                break;
            case JsonObject obj:
                if (obj.Count == 0) { o.Append("{\n\n").Append(pad).Append('}'); break; }
                o.Append("{\n");
                var first = true;
                foreach (var (k, v) in obj.OrderBy(p => p.Key, StringComparer.Ordinal))
                {
                    if (!first) o.Append(",\n");
                    first = false;
                    o.Append(inner);
                    Quote(o, k);
                    o.Append(" : ");
                    WriteMac(o, v, level + 1);
                }
                o.Append('\n').Append(pad).Append('}');
                break;
            case JsonArray arr:
                if (arr.Count == 0) { o.Append("[\n\n").Append(pad).Append(']'); break; }
                o.Append("[\n");
                for (var i = 0; i < arr.Count; i++)
                {
                    if (i > 0) o.Append(",\n");
                    o.Append(inner);
                    WriteMac(o, arr[i], level + 1);
                }
                o.Append('\n').Append(pad).Append(']');
                break;
            default:
                switch (n.GetValueKind())
                {
                    case JsonValueKind.String: Quote(o, n.GetValue<string>()); break;
                    case JsonValueKind.True: o.Append("true"); break;
                    case JsonValueKind.False: o.Append("false"); break;
                    case JsonValueKind.Null: o.Append("null"); break;
                    default: o.Append(n.ToJsonString()); break;   // 수(이 파일에는 정수만)
                }
                break;
        }
    }

    private static void Quote(StringBuilder o, string s)
    {
        o.Append('"');
        foreach (var c in s)
        {
            switch (c)
            {
                case '"': o.Append("\\\""); break;
                case '\\': o.Append("\\\\"); break;
                case '/': o.Append("\\/"); break;
                case '\b': o.Append("\\b"); break;
                case '\f': o.Append("\\f"); break;
                case '\n': o.Append("\\n"); break;
                case '\r': o.Append("\\r"); break;
                case '\t': o.Append("\\t"); break;
                default:
                    if (c < 0x20) o.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    else o.Append(c);
                    break;
            }
        }
        o.Append('"');
    }
}

// 설정 화면의 고를 수 있는 범위(가져오기 검사와 설정 화면이 같이 씀)
public static class SettingsBounds
{
    public const int DigestFrom = 5, DigestTo = 12;            // 아침 브리핑 오전 5시~낮 12시(C-21)
    public const int BundleFrom = 6, BundleTo = 23;            // 분야 묶음 시각(G-13)
    public const int CapMin = 1, CapMax = 10;                  // 분야 하루 상한
}
