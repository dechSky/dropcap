using System.Text.Json;
using System.Text.RegularExpressions;
using System.Text.Json.Serialization;

namespace Dropcap.Core;

// AI 분야 안의 하위 분류(C-16: 모델·연구·정책·투자·보안). 목록·이름·색·낱말 규칙은 자료(ai-topics.json)에서 읽는다.
// 일반 뉴스 분야(정치·경제·…·AI)는 Sections.cs(shared/categories.json).
[JsonConverter(typeof(NewsCategoryConverter))]
public readonly record struct NewsCategory(string Id)
{
    public override string ToString() => Id ?? Categories.Fallback;
}

// 라이트/다크 색
public readonly record struct DualColor(string Light, string Dark)
{
    public string For(bool dark) => dark ? Dark : Light;

    public static readonly DualColor Red = new("#FF3B30", "#FF453A");
    public static readonly DualColor Gray = new("#8E8E93", "#8E8E93");
    public static readonly DualColor Orange = new("#FF9500", "#FF9F0A");
    public static readonly DualColor Purple = new("#AF52DE", "#BF5AF2");
    public static DualColor Fixed(string hex) => new(hex, hex);
}

public static class Categories
{
    public sealed record Def(string Id, string Label, string Icon, string Light, string Dark, List<string> Words)
    {
        private Regex? english;
        private List<string>? korean;
        // 영어는 낱말 경계로 — 'impact'의 act, 'capital'의 api 에 걸리지 않게. 한국어는 조사가 붙으므로 부분 일치
        public bool Matches(string lower)
        {
            if (english is null)
            {
                var en = Words.Select(w => w.Trim()).Where(w => w.Length > 0 && w.All(char.IsAscii)).ToList();
                english = en.Count == 0 ? new Regex("(?!)") : new Regex(string.Join("|", en.Select(w => w.Length <= 4 ? $@"\b{Regex.Escape(w)}\b" : $@"\b{Regex.Escape(w)}")), RegexOptions.CultureInvariant);
                korean = Words.Where(w => !w.All(char.IsAscii)).ToList();
            }
            return english.IsMatch(lower) || korean!.Any(w => lower.Contains(w, StringComparison.Ordinal));
        }
    }

    private sealed record FileShape(string Fallback, List<string> ClassifyOrder, Dictionary<string, string> KindCategory, List<Def> Categories);

    private sealed record Data(List<Def> Defs, Dictionary<string, Def> ById, List<Def> Order, string Fallback, Dictionary<string, string> KindCategory);

    private static Data data = Load(Resources.PathOf("ai-topics.json"));

    private static Data Load(string path)
    {
        var f = JsonSerializer.Deserialize<FileShape>(File.ReadAllText(path), Json.Options) ?? throw new InvalidDataException("categories.json 을 읽지 못함");
        var byId = f.Categories.ToDictionary(c => c.Id);
        if (!byId.ContainsKey(f.Fallback)) throw new InvalidDataException("fallback 분야가 목록에 없음");
        var order = f.ClassifyOrder.Where(byId.ContainsKey).Select(id => byId[id]).ToList();
        return new Data(f.Categories, byId, order, f.Fallback, f.KindCategory ?? new());
    }

    // 시험·다른 정의 파일로 바꿀 때
    public static void Reload(string path) => data = Load(path);

    public static IReadOnlyList<NewsCategory> All => data.Defs.Select(d => new NewsCategory(d.Id)).ToList();
    public static string Fallback => data.Fallback;
    public static NewsCategory Other => new(data.Fallback);   // '그 밖의 소식'(규칙에 안 걸린 것)

    private static Def Of(NewsCategory c) => data.ById.TryGetValue(c.Id ?? data.Fallback, out var d) ? d : data.ById[data.Fallback];

    public static string Raw(this NewsCategory c) => Of(c).Id;
    public static NewsCategory Parse(string? raw) => raw is not null && data.ById.ContainsKey(raw) ? new(raw) : Other;
    public static string Label(this NewsCategory c) => Of(c).Label;
    public static string Glyph(this NewsCategory c) => Of(c).Icon;   // 아이콘 이름(ui.js·Icons.cs 와 같은 이름)
    public static DualColor Color(this NewsCategory c) { var d = Of(c); return new(d.Light, d.Dark); }
    public static int SortOrder(this NewsCategory c) => data.Defs.IndexOf(Of(c));
    public static bool IsOther(this NewsCategory c) => Of(c).Id == data.Fallback;

    // 먼저 걸리는 분야로 정한다(자료의 classifyOrder 순서 — 보안·정책처럼 성격이 뚜렷한 것부터)
    [ThreadStatic] internal static int ClassifyCalls;   // 시험용: 낱말 분류를 몇 번 했는지(이 스레드)
    public static NewsCategory Classify(string text)
    {
        ClassifyCalls++;
        var t = text.ToLowerInvariant();
        foreach (var d in data.Order)
            if (d.Matches(t)) return new(d.Id);
        return Other;
    }

    // 글 종류가 분야를 정하는 경우(논문=연구, 릴리스=모델 — 자료의 kindCategory)
    public static NewsCategory? ForKind(ItemKind k) => data.KindCategory.TryGetValue(k.Raw(), out var id) ? Parse(id) : null;

    // 종류 지면의 색(매거진)
    public static DualColor KindColor(string? kind, NewsCategory fallback) => kind switch
    {
        "video" => DualColor.Red,
        "paper" => DualColor.Fixed("#B31B1B"),
        "release" => DualColor.Gray,
        "post" => DualColor.Orange,
        "podcast" => DualColor.Purple,
        _ => fallback.Color(),
    };
}

public sealed class NewsCategoryConverter : JsonConverter<NewsCategory>
{
    public override NewsCategory Read(ref Utf8JsonReader r, Type t, JsonSerializerOptions o) => Categories.Parse(r.GetString());
    public override void Write(Utf8JsonWriter w, NewsCategory v, JsonSerializerOptions o) => w.WriteStringValue(v.Raw());
}
