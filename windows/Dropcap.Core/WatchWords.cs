using System.Text.RegularExpressions;

namespace Dropcap.Core;

// 지켜볼 낱말(N-27 · D-6): 회사·인물·법안 이름을 적어 두면 그 낱말이 든 소식은 스토리마다 한 번 알리고,
// 하루 한 번(아침 브리핑 시각) "오늘 ○○ 소식 3건" 정리 물방울을 띄운다. 누르면 매거진 검색 결과. 맥 Core/WatchWords.swift 와 같음.
// 영어 낱말은 낱말 경계로(Apple 이 pineapple 에 걸리지 않게), 한국어·일본어·중국어는 조사가 붙으므로 부분 일치.
public static class WatchWords
{
    // 앞뒤 빈칸을 지우고, 빈 것·대소문자만 다른 같은 낱말은 뺀다(적은 순서 유지)
    public static List<string> Normalized(IEnumerable<string> list)
    {
        var o = new List<string>();
        foreach (var w in list.Select(x => x.Trim()))
            if (w.Length > 0 && !o.Any(x => string.Equals(x, w, StringComparison.OrdinalIgnoreCase))) o.Add(w);
        return o;
    }

    private static readonly Regex Cjk = new("[가-힣ぁ-んァ-ン一-龥]");

    public static bool Matches(string word, string text)
    {
        var w = word.ToLowerInvariant();
        var t = text.ToLowerInvariant();
        if (Cjk.IsMatch(w)) return t.Contains(w, StringComparison.Ordinal);
        return Regex.IsMatch(t, @"(?<![\p{L}\p{N}])" + Regex.Escape(w) + @"(?![\p{L}\p{N}])", RegexOptions.None, TimeSpan.FromMilliseconds(200));
    }

    private static string Text(NewsItem it) => $"{it.Title} {it.TitleKo ?? ""} {it.Summary}";

    // 걸린 첫 낱말(적은 순서)
    public static string? Match(NewsItem it, IReadOnlyList<string> words)
    {
        var text = Text(it);
        return words.FirstOrDefault(w => Matches(w, text));
    }

    // 하루 정리: 낱말마다 걸린 기사(같은 기사는 한 번, 최신 순). 걸린 것이 없는 낱말은 뺀다
    public static List<(string Word, List<NewsItem> Items)> Digest(IEnumerable<NewsItem> items, IReadOnlyList<string> words)
    {
        var sorted = items.OrderByDescending(i => i.Date ?? DateTimeOffset.MinValue).ToList();
        var o = new List<(string, List<NewsItem>)>();
        foreach (var w in words)
        {
            var seen = new HashSet<string>();
            var hit = sorted.Where(i => Matches(w, Text(i)) && seen.Add(i.Key)).ToList();
            if (hit.Count > 0) o.Add((w, hit));
        }
        return o;
    }
}
