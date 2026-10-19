using System.Globalization;

namespace Dropcap.Core;

// 지난 기사 보관함: 기사 기록(items)은 최근 2만 건만 남기고, 그보다 오래된 기사는 가벼운 보관 표(archive)로 옮긴다
// (날짜·제목·한국어 제목·링크·출처·분야·스토리 — 사진·요약·본문 없음). 보관 표는 설정의 '보관 기간'이 지난 달부터 지운다.
// 보관함 화면·검색은 아직 items 에 있는 최근 기사와 보관 표를 같은 꼴(ArchivedItem)로 합쳐 보여 준다(맥 Archive.swift 와 같음).
public sealed record ArchivedItem(DateTimeOffset Date, string Title, string? TitleKo, string Link, string Source, string Section, string? Story = null, string? SourceId = null)
{
    // Source: 출처 이름(옮긴 뒤 구독을 끊어도 보이게 이름으로 둔다), Section: 분야 id, Story: 여러 곳이 다룬 스토리 id(한 곳뿐이면 null)
    // SourceId: 출처 id(숨긴·꺼진 출처를 거를 때 — 예전 줄에는 없어 이름으로 거름)
    public string Id => Link + "|" + Date.ToUnixTimeMilliseconds().ToString(CultureInfo.InvariantCulture);
    public string DisplayTitle => TitleKo ?? Title;

    // 읽기 창으로 열 때 쓰는 기사(본문은 링크에서 다시 받는다)
    public const string ReaderSource = "archive";
    public NewsItem ToNewsItem() => new()
    {
        Id = Link, Title = Title, TitleKo = TitleKo, Link = Link, Date = Date, Summary = "", SourceId = ReaderSource, SourceName = Source, Tier = "",
    };
}

public static class Archive
{
    // 설정 '보관 기간'(년). 0 은 끝없이
    public const int DefaultYears = 2;
    public static readonly int[] Choices = [1, 2, 5, 0];
    public static string Label(int years) => years == 0 ? "끝없이" : $"{years}년";
    public static int ClampYears(int y) => Choices.Contains(y) ? y : DefaultYears;
    // 보관 기간과 관계없이 지키는 상한(끝없이여도 이보다 많으면 가장 오래된 것부터 지움)
    public const int MaxRows = 5_000_000;
    // 검색어 길이 상한
    public const int MaxQuery = 200;
    public static string TrimQuery(string q) => q.Length > MaxQuery ? q[..MaxQuery] : q;

    // 이 때보다 이른 보관 기사는 지운다: years 년 전이 든 달의 첫날(달 단위로 — 오래된 달부터 통째로). 0 이면 null(지우지 않음)
    public static DateTimeOffset? Cutoff(int years, DateTimeOffset now)
    {
        if (years <= 0) return null;
        var back = now.LocalDateTime.AddYears(-years);
        return new DateTimeOffset(new DateTime(back.Year, back.Month, 1, 0, 0, 0, DateTimeKind.Local));
    }

    // MARK: 기간
    public enum Period { Day, Week, Month, Year }
    public static readonly Period[] Periods = [Period.Day, Period.Week, Period.Month, Period.Year];
    public static string Raw(this Period p) => p switch { Period.Day => "day", Period.Week => "week", Period.Year => "year", _ => "month" };
    public static Period ParsePeriod(string? s) => s switch { "day" => Period.Day, "week" => Period.Week, "year" => Period.Year, _ => Period.Month };
    public static string Label(this Period p) => p switch { Period.Day => "일", Period.Week => "주", Period.Year => "연", _ => "월" };
    // 날짜별 건수 막대를 목록 앞에 보이는 기간
    public static bool ShowsBars(this Period p) => p is Period.Month or Period.Year;

    // anchor(이 PC 의 시각)가 든 기간 [from, to)
    public static (DateTime From, DateTime To) Range(Period p, DateTime anchor)
    {
        var d = anchor.Date;
        return p switch
        {
            Period.Day => (d, d.AddDays(1)),
            Period.Week => Magazine.WeekRange(d),
            Period.Year => (new DateTime(d.Year, 1, 1), new DateTime(d.Year + 1, 1, 1)),
            _ => (new DateTime(d.Year, d.Month, 1), new DateTime(d.Year, d.Month, 1).AddMonths(1)),
        };
    }

    // ◀ ▶: 한 기간 앞뒤로
    public static DateTime Shift(Period p, DateTime anchor, int n)
    {
        var from = Range(p, anchor).From;
        return p switch
        {
            Period.Day => from.AddDays(n),
            Period.Week => from.AddDays(7 * n),
            Period.Year => from.AddYears(n),
            _ => from.AddMonths(n),
        };
    }

    private static readonly string[] Weekdays = ["일", "월", "화", "수", "목", "금", "토"];

    // 머리 이름: 2026년 10월 19일(월) · 2026년 10월 18일 – 10월 24일 · 2026년 10월 · 2026년
    public static string Title(Period p, DateTime anchor)
    {
        var (from, to) = Range(p, anchor);
        return p switch
        {
            Period.Day => $"{from.Year}년 {from.Month}월 {from.Day}일({Weekdays[(int)from.DayOfWeek]})",
            Period.Week => $"{from.Year}년 {from.Month}월 {from.Day}일 – {to.AddDays(-1).Month}월 {to.AddDays(-1).Day}일",
            Period.Year => $"{from.Year}년",
            _ => $"{from.Year}년 {from.Month}월",
        };
    }

    // 날 열쇠(이 PC 의 날 'yyyy-MM-dd' — SQLite date(...,'localtime') 와 같은 꼴)
    public static string DayKey(DateTime local) => local.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
    public static string DayKey(DateTimeOffset d) => DayKey(d.LocalDateTime);
    public static DateTime? ParseDay(string? key) =>
        DateTime.TryParseExact(key, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d) ? d : null;

    // 기간의 날들(막대 순서)
    public static List<DateTime> Days(DateTime from, DateTime to)
    {
        var o = new List<DateTime>();
        for (var d = from.Date; d < to; d = d.AddDays(1)) o.Add(d);
        return o;
    }

    // 보관함 한 기간의 화면 재료
    // Items: 최신순 앞 limit 건, More: 더 있음, DayCounts: 날 열쇠 → 건수(거른 뒤), Sections·Sources: 거르기 전 건수(메뉴), Total: 거른 뒤 전체
    public sealed record Page(List<ArchivedItem> Items, bool More, Dictionary<string, int> DayCounts, Dictionary<string, int> Sections,
        Dictionary<string, int> Sources, int Total);

    // 최근 기사와 보관 기사 합치기: 같은 링크는 한 번(최근 쪽 — 한 출처의 두 피드에 같은 기사가 실린 것도), 최신순
    public static List<ArchivedItem> Merge(IEnumerable<ArchivedItem> recent, IEnumerable<ArchivedItem> archived)
    {
        var seen = new HashSet<string>();
        return recent.Concat(archived).Where(a => seen.Add(a.Link)).OrderByDescending(a => a.Date).ToList();
    }

    // 분야·출처로 거르기(null 이면 모두)
    public static List<ArchivedItem> Filter(IEnumerable<ArchivedItem> items, string? section, string? source) =>
        items.Where(i => (section is null || i.Section == section) && (source is null || i.Source == source)).ToList();

    // 날짜별 건수 더하기
    public static Dictionary<string, int> DayCounts(IEnumerable<ArchivedItem> items)
    {
        var o = new Dictionary<string, int>();
        foreach (var i in items) { var k = DayKey(i.Date); o[k] = o.GetValueOrDefault(k) + 1; }
        return o;
    }
}

// 보관함·오래된 기사 검색 읽기. DB 는 문장마다 자물쇠로 지켜지므로 기사를 받아 넣는 중에도 사이사이 읽힌다(화면에서는 Task.Run 으로)
public sealed class ArchiveReader(Database db)
{
    private readonly object gate = new();
    // 최근 기사의 분야(key → 분야): 기간을 넘길 때마다 수만 건을 다시 가르지 않게 기억해 둔다
    private Dictionary<string, string> sectionMemo = new();

    // 보관 표 검색(최신순 limit 건씩 — 더 보기는 offset). filter: 숨긴·꺼진 출처는 빼고(null 이면 거르지 않음)
    public List<ArchivedItem> Search(string q, int limit = 200, int offset = 0, SourceFilter? filter = null) => db.SearchArchive(q, limit, offset, filter);

    // 보관함 한 기간: 아직 items 에 있는 최근 기사(가벼운 꼴) + 보관 표(분야·출처로 거름). limit 은 보여 줄 수.
    // filter: 숨긴·꺼진 출처는 목록·건수·거르기 메뉴 어디에도 다시 나오지 않게(null 이면 거르지 않음)
    public Archive.Page Period(DateTimeOffset from, DateTimeOffset to, string? section, string? source, int limit, SourceFilter? filter = null)
    {
        Dictionary<string, string> memo;
        lock (gate) memo = sectionMemo.Count > 60000 ? new() : new(sectionMemo);
        var recent = db.RecentLight(from, to, (key, it) =>
        {
            if (memo.TryGetValue(key, out var s)) return s;
            return memo[key] = Sections.Primary(it);
        });
        lock (gate) sectionMemo = memo;
        if (filter is not null) recent = recent.Where(r => filter.Shows(r.SourceId ?? "")).ToList();
        var shown = Archive.Filter(recent, section, source);
        var counts = Archive.DayCounts(shown);
        foreach (var (d, n) in db.ArchiveDayCounts(from, to, section, source, filter)) counts[d] = counts.GetValueOrDefault(d) + n;
        var (sections, sources) = db.ArchiveFacets(from, to, filter);
        foreach (var r in recent)
        {
            sections[r.Section] = sections.GetValueOrDefault(r.Section) + 1;
            sources[r.Source] = sources.GetValueOrDefault(r.Source) + 1;
        }
        // 보관 기사는 최근 기사보다 이르므로 limit+1 건만 꺼내 합쳐도 앞 limit 건이 맞다(+1 은 '더 보기'가 있는지)
        var older = shown.Count > limit ? new() : db.Archived(from, to, section, source, limit - shown.Count + 1, filter: filter);
        var items = Archive.Merge(shown, older);
        return new Archive.Page(items.Take(limit).ToList(), items.Count > limit, counts, sections, sources, counts.Values.Sum());
    }

    public DateTimeOffset? EarliestRecord() => db.EarliestRecord();
}
