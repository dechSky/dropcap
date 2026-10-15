namespace Dropcap.Core;

// 일요일 저녁(17시부터) 스크랩북 첫머리에 '이번 주 모은 문장'(M-27) — 지난 7일 동안 문단으로 스크랩한 글. 맥 UI/WeeklyQuotes.swift 와 같은 규칙.
public static class WeeklyQuotes
{
    public const int Limit = 6;

    public static bool IsSundayEvening(DateTimeOffset d) => IsSundayEvening(d.LocalDateTime);

    public static bool IsSundayEvening(DateTime local)
    {
        if (Environment.GetEnvironmentVariable("DROPCAP_TEST_WEEKLY") is not null) return true; // 시험용
        return local.DayOfWeek == DayOfWeek.Sunday && local.Hour >= 17;
    }

    // 최근 것부터, 같은 문장은 한 번만
    public static List<Scrap> Pick(IEnumerable<Scrap> scraps, DateTimeOffset now, int limit = Limit)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        return scraps.Where(s => s.Quote is { Length: > 0 } q && (now - s.Created).TotalSeconds < 7 * 86400 && s.Created <= now.AddSeconds(60) && seen.Add(q))
            .OrderByDescending(s => s.Created)
            .Take(limit)
            .ToList();
    }
}
