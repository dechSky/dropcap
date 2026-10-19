using System.Globalization;

namespace Dropcap.Core;

// 설정 › 구독의 출처 목록 정리: 찾기(이름·주소·분야·국내/해외) · 켠 것/끈 것 거르기 · 매체별/분야별/지역별 묶음 · 켠 출처 요약.
// 화면 없이 시험한다(SourceDirectoryTests). 맥 Core/SourceDirectory.swift 가 기준, 리눅스도 같은 규칙.
public static class SourceDirectory
{
    public enum Layout { Media, Section, Region }
    public enum Status { All, On, Off }

    public static readonly Layout[] Layouts = [Layout.Media, Layout.Section, Layout.Region];
    public static readonly Status[] Statuses = [Status.All, Status.On, Status.Off];

    public static string Raw(this Layout l) => l switch { Layout.Section => "section", Layout.Region => "region", _ => "media" };
    public static string Label(this Layout l) => l switch { Layout.Section => "분야별", Layout.Region => "지역별", _ => "매체별" };
    public static Layout? ParseLayout(string? raw) => Layouts.Where(l => l.Raw() == raw).Cast<Layout?>().FirstOrDefault();

    public static string Raw(this Status s) => s switch { Status.On => "on", Status.Off => "off", _ => "all" };
    public static string Label(this Status s) => s switch { Status.On => "켠 것", Status.Off => "끈 것", _ => "전체" };
    public static Status? ParseStatus(string? raw) => Statuses.Where(s => s.Raw() == raw).Cast<Status?>().FirstOrDefault();

    // 한 묶음: 보이는 출처(거른 뒤)와 묶음 전체의 켠 수/전체 수
    public sealed record Group(string Id, string Title, List<Source> Sources, int On, int Total);

    public static string RegionLabel(Source s) => s.IsDomestic ? "국내" : "해외";

    // 매체 묶음 키: id 의 첫 '-' 앞(yna-market → yna, bbc-world → bbc)
    public static string MediaKey(Source s)
    {
        var i = s.Id.IndexOf('-');
        return i <= 0 ? s.Id : s.Id[..i];
    }

    // 글자 수(맥 String.count 처럼 보이는 글자 단위)
    private static int Chars(string s) => new StringInfo(s).LengthInTextElements;

    // 매체 이름: 모두 같은 이름 → 그 이름, 모두 같은 첫 낱말 → 그 낱말(연합뉴스·BBC), 대표 피드(id == 묶음 키 또는 키-home) 이름, 아니면 가장 짧은 이름
    public static string MediaName(IReadOnlyList<Source> members)
    {
        if (members.Count == 0) return "";
        var names = members.Select(m => m.Name).ToList();
        if (names.Distinct(StringComparer.Ordinal).Count() == 1) return names[0];
        var heads = names.Select(n => n.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? "").ToList();
        if (heads[0].Length > 0 && heads.All(h => h == heads[0])) return heads[0];
        var bas = members.FirstOrDefault(m => m.Id == MediaKey(m) || m.Id == MediaKey(m) + "-home"); // 대표 피드(id == 묶음 키 또는 키-home) 이름(nyt-home → The New York Times)
        if (bas is not null) return bas.Name;
        return names.OrderBy(Chars).ThenBy(n => n, StringComparer.Ordinal).First();
    }

    // 묶음 안에서 보일 짧은 이름: 매체 이름을 떼고(연합뉴스 경제 → 경제), 떼면 비면 원래 이름
    public static string ShortName(Source s, string media)
    {
        if (!s.Name.StartsWith(media + " ", StringComparison.Ordinal)) return s.Name;
        var rest = s.Name[media.Length..].Trim();
        return rest.Length == 0 ? s.Name : rest;
    }

    // 비교용: 소문자·띄어쓰기 없앰
    public static string Fold(string s) => string.Concat(s.ToLowerInvariant().Where(c => !char.IsWhiteSpace(c)));

    public static bool Matches(Source s, string query)
    {
        var q = Fold(query);
        if (q.Length == 0) return true;
        string[] hay = [s.Name, s.Url, s.Home ?? "", Sections.Name(s.SectionId), RegionLabel(s)];
        return hay.Any(h => Fold(h).Contains(q, StringComparison.Ordinal));
    }

    public static List<Source> Filter(IEnumerable<Source> sources, string query, Status status, Func<string, bool> enabled) =>
        sources.Where(s => status switch
        {
            Status.On => enabled(s.Id),
            Status.Off => !enabled(s.Id),
            _ => true,
        } && Matches(s, query)).ToList();

    // 정렬: 국내 먼저(가나다) 그다음 해외(ABC). 같은 이름은 id 순. 유니코드 순서라 세 판이 같다
    private static int CompareKey(string an, bool ad, string bn, bool bd)
    {
        var c = (ad ? 0 : 1).CompareTo(bd ? 0 : 1);
        return c != 0 ? c : string.CompareOrdinal(an.ToLowerInvariant(), bn.ToLowerInvariant());
    }

    public static List<Source> Sorted(IEnumerable<Source> sources)
    {
        var list = sources.ToList();
        list.Sort((a, b) =>
        {
            var c = CompareKey(a.Name, a.IsDomestic, b.Name, b.IsDomestic);
            return c != 0 ? c : string.CompareOrdinal(a.Id, b.Id);
        });
        return list;
    }

    // all: 묶음 전체(켠 수 계산), shown: 거른 결과. 보이는 것이 없는 묶음은 뺀다
    public static List<Group> Groups(IReadOnlyList<Source> all, IEnumerable<Source> shown, Layout layout, Func<string, bool> enabled)
    {
        var visible = shown.Select(s => s.Id).ToHashSet();
        Group? Make(string id, string title, List<Source> members)
        {
            var list = Sorted(members.Where(m => visible.Contains(m.Id)));
            return list.Count == 0 ? null : new Group(id, title, list, members.Count(m => enabled(m.Id)), members.Count);
        }
        switch (layout)
        {
            case Layout.Section:
            {
                var known = Sections.All.Select(s => s.Id).ToList();
                var extra = all.Select(s => s.SectionId).Distinct().Where(id => !known.Contains(id)).OrderBy(id => id, StringComparer.Ordinal);
                return known.Concat(extra)
                    .Select(id => Make("section:" + id, Sections.Name(id), all.Where(s => s.SectionId == id).ToList()))
                    .OfType<Group>().ToList();
            }
            case Layout.Region:
                return new[] { Make("region:kr", "국내", all.Where(s => s.IsDomestic).ToList()), Make("region:intl", "해외", all.Where(s => !s.IsDomestic).ToList()) }
                    .OfType<Group>().ToList();
            default:
            {
                var groups = all.GroupBy(MediaKey)
                    .Select(g => Make("media:" + g.Key, MediaName(g.ToList()), g.ToList()))
                    .OfType<Group>().ToList();
                groups.Sort((a, b) =>
                {
                    var c = CompareKey(a.Title, a.Sources[0].IsDomestic, b.Title, b.Sources[0].IsDomestic);
                    return c != 0 ? c : string.CompareOrdinal(a.Id, b.Id);
                });
                return groups;
            }
        }
    }

    // 맨 위 요약: 켠 출처 수와 분야별 켠 수(분야 순서, 0 인 분야는 뺌)
    public sealed record SectionCount(string Id, string Name, int Count);
    public static (int Count, List<SectionCount> BySection) Summary(IEnumerable<Source> sources, Func<string, bool> enabled)
    {
        var on = sources.Where(s => enabled(s.Id)).ToList();
        var counts = on.GroupBy(s => s.SectionId).ToDictionary(g => g.Key, g => g.Count());
        var known = Sections.All.Select(s => s.Id).ToList();
        var order = known.Concat(counts.Keys.Where(k => !known.Contains(k)).OrderBy(k => k, StringComparer.Ordinal));
        return (on.Count, order.Where(counts.ContainsKey).Select(id => new SectionCount(id, Sections.Name(id), counts[id])).ToList());
    }

    public static string SummaryText(IEnumerable<Source> sources, Func<string, bool> enabled)
    {
        var (count, by) = Summary(sources, enabled);
        if (count == 0) return "켠 출처 없음";
        return $"켠 출처 {count}곳 · " + string.Join(" · ", by.Select(b => $"{b.Name} {b.Count}"));
    }

    public static string CountText(int shown, int total) => shown == total ? $"{total}곳" : $"{total}곳 중 {shown}곳";
}
