using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Dropcap.Core;

// shared/sources.json 과 같은 모양
public sealed class SourceConfig
{
    public int Version { get; set; }
    public Dictionary<string, string> Tiers { get; set; } = new();
    public string AiPattern { get; set; } = "";
    public List<Source> Sources { get; set; } = new();
}

public sealed record Source
{
    public string Id { get; init; } = "";
    public string Name { get; init; } = "";
    public string Tier { get; init; } = "press";
    public string Type { get; init; } = "feed"; // feed | sitemap
    public string Url { get; init; } = "";
    public string? Match { get; init; }
    public bool AiOnly { get; init; }
    public bool DefaultOn { get; init; }
    public string Color { get; init; } = "#3B82F6";
    public string? Kind { get; init; }           // article(기본) · video · paper · release · post · podcast
    public bool? NotifyDefault { get; init; }    // 알림 기본값(양 많은 채널은 false)
    public string? Group { get; init; }          // 추천 목록의 묶음 이름
    public string? Home { get; init; }           // 사람이 보는 주소(설정 화면 표시용)
    public string? Section { get; init; }        // 분야 id(shared/categories.json). 없으면 AI(예전 출처·직접 추가)
    public string? Lang { get; init; }           // 글의 언어(ko·en …). 없으면 en
    public string? Region { get; init; }         // kr(국내) · intl(해외). 없으면 tier 로 정함
    public string? Paywall { get; init; }        // hard(구독해야만) · metered(한 달 몇 건 무료). 없으면 무료로 봄

    [JsonIgnore] public string SectionId => Section ?? "ai";
    [JsonIgnore] public string Language => Lang ?? "en";
    [JsonIgnore] public string RegionCode => Region ?? (Tier == "kr" ? "kr" : "intl");
    [JsonIgnore] public bool IsDomestic => RegionCode == "kr";

    [JsonIgnore] public ItemKind ItemKind => ItemKinds.Parse(Kind);
}

// 글의 종류: 기사 외의 구독 채널(영상·논문·릴리스·커뮤니티·팟캐스트)
public enum ItemKind { Article, Video, Paper, Release, Post, Podcast }

public static class ItemKinds
{
    public static readonly ItemKind[] All = Enum.GetValues<ItemKind>();

    public static ItemKind Parse(string? raw) => raw switch
    {
        "video" => ItemKind.Video,
        "paper" => ItemKind.Paper,
        "release" => ItemKind.Release,
        "post" => ItemKind.Post,
        "podcast" => ItemKind.Podcast,
        _ => ItemKind.Article,
    };

    public static string Raw(this ItemKind k) => k.ToString().ToLowerInvariant();

    public static string Label(this ItemKind k) => k switch
    {
        ItemKind.Article => "기사",
        ItemKind.Video => "영상",
        ItemKind.Paper => "논문",
        ItemKind.Release => "릴리스",
        ItemKind.Post => "커뮤니티",
        _ => "팟캐스트",
    };

    // Segoe Fluent Icons 글리프(맥 SF Symbols 대신)
    public static string Glyph(this ItemKind k) => k switch
    {
        ItemKind.Article => "",  // Document
        ItemKind.Video => "",    // Video
        ItemKind.Paper => "",    // ReadingMode
        ItemKind.Release => "",  // Package
        ItemKind.Post => "",     // Chat
        _ => "",                 // Audio
    };

    // 읽기 창 대신 원래 앱·브라우저로 여는 것
    public static bool OpensExternally(this ItemKind k) => k is ItemKind.Video or ItemKind.Podcast;
}

public sealed record NewsItem
{
    public string Id { get; init; } = "";        // 출처 안에서의 고유 값(guid 또는 주소)
    public string Title { get; init; } = "";
    public string? TitleKo { get; init; }
    public string Link { get; init; } = "";
    public DateTimeOffset? Date { get; init; }
    public string Summary { get; init; } = "";
    public string SourceId { get; init; } = "";
    public string SourceName { get; init; } = "";
    public string Tier { get; init; } = "press";

    public List<string>? Related { get; init; }  // 같은 소식을 다룬 다른 출처
    public string? Image { get; init; }          // 대표 사진 주소
    public string? TitleEn { get; init; }        // 영어 제목(한국어 기사를 다른 기사와 같은 소식인지 비교할 때)
    public string? Kind { get; init; }           // ItemKind
    public bool? Important { get; init; }        // '꼭 알림' 낱말에 걸림
    public string? Watch { get; init; }          // 걸린 '지켜볼 낱말'(★ 와 겹치면 표시는 ★, N-27)

    [JsonIgnore] public ItemKind ItemKind => ItemKinds.Parse(Kind);
    [JsonIgnore] public string Key => $"{SourceId}|{Id}";
    [JsonIgnore] public string DisplayTitle => TitleKo ?? Title;
    [JsonIgnore] public NewsCategory Category => Categories.ForKind(ItemKind) ?? Categories.Classify($"{Title} {TitleKo ?? ""} {Summary}");

    [JsonIgnore]
    public string Initial
    {
        get
        {
            var n = SourceName.Replace("The ", "");
            return n.Length == 0 ? "" : char.ToUpperInvariant(n[0]).ToString();
        }
    }

    // record 의 기본 같음 비교는 목록 필드를 참조로 비교하므로, 맥처럼 값으로 비교한다
    public bool Equals(NewsItem? o) => o is not null && Key == o.Key && Title == o.Title && TitleKo == o.TitleKo && Link == o.Link
        && Date == o.Date && Summary == o.Summary && Image == o.Image && TitleEn == o.TitleEn && Important == o.Important
        && (Related ?? new()).SequenceEqual(o.Related ?? new());
    public override int GetHashCode() => Key.GetHashCode();
}

// 맥 JSONEncoder(.iso8601) 와 같은 날짜 모양: 2026-10-13T01:02:03Z
public sealed class IsoDateConverter : JsonConverter<DateTimeOffset>
{
    public override DateTimeOffset Read(ref Utf8JsonReader r, Type t, JsonSerializerOptions o)
    {
        if (r.TokenType == JsonTokenType.Number) return DateTimeOffset.FromUnixTimeMilliseconds((long)(r.GetDouble() * 1000));
        var s = r.GetString() ?? throw new JsonException("날짜 없음");
        return DateTimeOffset.Parse(s, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal);
    }
    public override void Write(Utf8JsonWriter w, DateTimeOffset v, JsonSerializerOptions o) =>
        w.WriteStringValue(v.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture));
}

public static class Json
{
    public static readonly JsonSerializerOptions Options = Make();

    private static JsonSerializerOptions Make()
    {
        var o = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
            NumberHandling = JsonNumberHandling.AllowReadingFromString,
        };
        o.Converters.Add(new IsoDateConverter());
        return o;
    }

    public static string Encode<T>(T v) => JsonSerializer.Serialize(v, Options);
    public static T? Decode<T>(string s) { try { return JsonSerializer.Deserialize<T>(s, Options); } catch { return default; } }

    // 항목 하나가 깨져도 나머지는 읽히게(새 항목이 늘어도 예전 파일이 그대로 읽힘)
    public static T Field<T>(JsonObject obj, string name, T fallback)
    {
        if (!obj.TryGetPropertyValue(name, out var n) || n is null) return fallback;
        try { return n.Deserialize<T>(Options) ?? fallback; } catch { return fallback; }
    }
}

public static class Resources
{
    // 앱 옆(배포) → 저장소의 shared/ (개발·시험) 순으로 찾는다
    public static string PathOf(string name)
    {
        var here = Path.Combine(AppContext.BaseDirectory, name);
        if (File.Exists(here)) return here;
        var d = new DirectoryInfo(AppContext.BaseDirectory);
        while (d is not null)
        {
            var c = Path.Combine(d.FullName, "shared", name);
            if (File.Exists(c)) return c;
            d = d.Parent;
        }
        return here;
    }

    private static readonly Lazy<SourceConfig> config = new(() =>
    {
        var text = File.ReadAllText(PathOf("sources.json"));
        return JsonSerializer.Deserialize<SourceConfig>(text, Json.Options) ?? throw new InvalidDataException("sources.json 을 읽지 못함");
    });
    public static SourceConfig Config => config.Value;

    private static readonly Lazy<Regex> aiRegex = new(() => new Regex(Config.AiPattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant));
    public static Regex AiRegex => aiRegex.Value;

    public static string TierLabel(string tier) => Config.Tiers.TryGetValue(tier, out var l) ? l : tier;
}

public static class RelativeTime
{
    public static string Format(DateTimeOffset? date, DateTimeOffset? now = null)
    {
        if (date is null) return "방금";
        var m = (int)((now ?? DateTimeOffset.Now) - date.Value).TotalMinutes;
        if (m < 1) return "방금";
        if (m < 60) return $"{m}분 전";
        if (m < 60 * 24) return $"{m / 60}시간 전";
        return $"{m / 1440}일 전";
    }

    // 맥 "a h:mm" (ko_KR) → "오후 3:05"
    public static string Clock(DateTimeOffset? d)
    {
        if (d is null) return "아직 없음";
        var t = d.Value.ToLocalTime();
        var ampm = t.Hour < 12 ? "오전" : "오후";
        var h = t.Hour % 12 == 0 ? 12 : t.Hour % 12;
        return $"{ampm} {h}:{t.Minute:00}";
    }
}

// 색: "#RRGGBB" → (r, g, b). 화면 쪽이 자기 색 형식으로 바꾼다.
public static class Hex
{
    public static (byte R, byte G, byte B) Parse(string? hex)
    {
        var s = (hex ?? "").Trim().TrimStart('#');
        if (!uint.TryParse(s, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var v)) v = 0x3B82F6;
        return ((byte)((v >> 16) & 0xFF), (byte)((v >> 8) & 0xFF), (byte)(v & 0xFF));
    }
}
