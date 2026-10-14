namespace Dropcap.Core;

// 오늘 호 완독(M-23 · D-11): 오늘 호의 대표 기사(표지 + 주요 뉴스·고른 분야마다 첫 줄)를 다 읽으면
// '오늘 호를 다 읽었어요'로 끝을 알리고 더 밀어 넣지 않는다. 맥 Core/TodayIssue.swift 와 같음.
public static class TodayIssue
{
    public const int PerSection = 3; // 지면 첫 줄(카드 세 장)

    // 대표 기사 key: 표지 → 주요 뉴스 지면 첫 줄 → 고른 분야 지면 첫 줄(분야 순서). 구독 채널 지면은 빼고, 겹치면 한 번만
    public static List<string> Keys(string? cover, IEnumerable<(Issue.Section Section, List<NewsItem> Items)> sections, IReadOnlyCollection<string> chosen)
    {
        var o = cover is null ? new List<string>() : [cover];
        var pages = sections.Where(s => s.Section.Kind is null).ToList();
        var top = pages.Where(s => s.Section.SectionId == Sections.Top);
        var picked = pages.Where(s => s.Section.SectionId is { } id && id != Sections.Top && chosen.Contains(id));
        foreach (var p in top.Concat(picked))
            foreach (var it in p.Items.Take(PerSection))
                if (!o.Contains(it.Key)) o.Add(it.Key);
        return o;
    }

    // 다음 호 안내: 아침 브리핑을 켰으면 그 시각, 아니면 '내일 아침'
    public static string NextIssueText(bool digestEnabled, int digestHour)
    {
        if (!digestEnabled) return "다음 호는 내일 아침에 엮여요";
        var h = digestHour % 12 == 0 ? 12 : digestHour % 12;
        return $"다음 호는 내일 {(digestHour < 12 ? "오전" : "오후")} {h}시 브리핑으로 알려 드릴게요";
    }

    // 오늘 다 읽었다고 한 번 정해지면(사진·표지가 바뀌어 대표 기사가 달라져도) 그날은 끝난 호로 둔다(prefs.json)
    public const string DoneKey = "todayIssueDone";
    public static bool IsMarkedDone(DateTimeOffset now) => Prefs.Get<string?>(DoneKey, null) == Magazine.DayId(now.ToLocalTime().Date);
    public static void MarkDone(DateTimeOffset now) => Prefs.Set(DoneKey, Magazine.DayId(now.ToLocalTime().Date));
}
