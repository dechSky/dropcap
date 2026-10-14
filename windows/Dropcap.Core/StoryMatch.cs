namespace Dropcap.Core;

// 제목 낱말이 많이 겹치면 같은 소식으로 본다(C-15)
public static class StoryMatch
{
    private static readonly HashSet<string> Stop = ["the", "and", "for", "with", "its", "new", "into", "from", "that", "this", "are", "has", "how", "what", "why", "will", "your", "you", "our", "says", "after", "over", "more", "than", "about", "now"];

    private static bool HasHangul(string s) => s.Any(c => c >= '가' && c <= '힣');

    private static IEnumerable<string> Split(string s, Func<char, bool> keep)
    {
        var cur = new System.Text.StringBuilder();
        foreach (var ch in s)
        {
            if (keep(ch)) cur.Append(ch);
            else { if (cur.Length > 0) yield return cur.ToString(); cur.Clear(); }
        }
        if (cur.Length > 0) yield return cur.ToString();
    }

    public static HashSet<string> Tokens(string title) =>
        Split(title.ToLowerInvariant(), char.IsLetterOrDigit)
            .Where(p => (p.Length >= 3 && !Stop.Contains(p)) || (p.Length >= 2 && HasHangul(p)))
            .ToHashSet();

    // 같은 소식인가: 낱말이 많이 겹치거나, 영어 제목의 고유명사가 함께 쓰이면 같다고 본다.
    // 한국어 기사는 영어 제목(titleEn)으로 비교한다.
    // 맥은 여기서 기기 내 문장 임베딩(뜻 거리)을 쓰지만 윈도우에는 같은 기능이 기본으로 없어(C-15 ~),
    // 고유명사 두 개 이상(그리고 적은 쪽의 절반 이상)을 함께 쓰면 같다고 본다 — 맥 시험 사례를 모두 같은 결과로 통과.
    public static bool Same(NewsItem a, NewsItem b)
    {
        if (a.SourceId == b.SourceId) return false; // 한 곳이 같은 소식을 두 번 내는 일은 드물다
        if (Similar(Tokens(a.Title), Tokens(b.Title))) return true;
        if (Similar(Tokens(a.TitleKo ?? a.Title), Tokens(b.TitleKo ?? b.Title))) return true;
        var ea = a.TitleEn ?? (Translator.LooksForeign(a.Title) ? a.Title : null);
        var eb = b.TitleEn ?? (Translator.LooksForeign(b.Title) ? b.Title : null);
        if (ea is null || eb is null) return false;
        var na = Entities(ea).ToHashSet();
        var nb = Entities(eb).ToHashSet();
        // 문장 첫 낱말은 대문자라 고유명사인지 알 수 없다 — 다른 제목에도 대문자로 나오면 고유명사로 친다(맥은 문장 분석기가 판단)
        if (FirstCapital(ea) is { } fa && Capitals(eb).Contains(fa)) { na.Add(fa); nb.Add(fa); }
        if (FirstCapital(eb) is { } fb && Capitals(ea).Contains(fb)) { na.Add(fb); nb.Add(fb); }
        return SharesEntities(na, nb);
    }

    public static bool SharesEntities(HashSet<string> a, HashSet<string> b)
    {
        if (a.Count == 0 || b.Count == 0) return false;
        var inter = a.Intersect(b).Count();
        return inter >= 2 && (double)inter / Math.Min(a.Count, b.Count) >= 0.5;
    }

    private static readonly HashSet<string> Common = ["ai", "si", "the", "a", "an", "new", "how", "why", "what", "its", "it", "this", "that", "in", "on", "for", "with", "and", "is", "are", "to", "of", "by", "use", "ceo", "us", "uk", "eu"];

    // 낱말(글자·숫자·'-')
    private static List<string> Words(string s) => Split(s, c => char.IsLetterOrDigit(c) || c == '-').Select(w => w.Trim('-')).Where(w => w.Length > 0).ToList();

    // 제목마다 한 번만 계산해 기억한다(쌍마다 다시 계산하면 기사 수의 제곱만큼 느려진다 — 추가 지시 2)
    private static readonly System.Collections.Concurrent.ConcurrentDictionary<string, IReadOnlySet<string>> entityCache = new();

    // 고유명사: 영어 제목은 낱말마다 첫 글자를 대문자로 쓰는 일이 많아(Title Case) '대문자로 시작'만으로는 'Global' 같은 흔한 말까지 잡힌다.
    // 그래서 ① NVIDIA·OpenAI·GPT-6·iPhone 처럼 대문자 약어·대소문자 섞임·숫자가 든 낱말 ② Title Case 가 아닌 제목에서 문장 중간의 대문자 낱말만(맥과 같은 규칙, 맥의 문장 분석기 이름 찾기는 윈도우에 없음).
    public static IReadOnlySet<string> Entities(string s)
    {
        if (entityCache.TryGetValue(s, out var e)) return e;
        var found = FindEntities(s);
        if (entityCache.Count > 5000) entityCache.Clear();
        entityCache[s] = found;
        return found;
    }

    private static HashSet<string> FindEntities(string s)
    {
        var o = new HashSet<string>();
        var words = Words(s);
        foreach (var w in words)
        {
            var letters = w.Where(char.IsLetter).ToList();
            var caps = letters.Count(char.IsUpper);
            var acronym = letters.Count >= 2 && caps == letters.Count;
            var mixed = (caps >= 2 && caps < letters.Count && char.IsUpper(w[0])) || (char.IsLower(w[0]) && caps >= 1);
            var digits = w.Any(char.IsDigit) && w.Any(char.IsLetter);
            if (acronym || mixed || digits) o.Add(w.ToLowerInvariant());
        }
        if (!TitleCase(words))
            foreach (var w in words.Skip(1))
                if (w.Length >= 3 && char.IsUpper(w[0])) o.Add(w.ToLowerInvariant());
        o.ExceptWith(Common);
        return o;
    }

    private static bool TitleCase(List<string> words)
    {
        var lng = words.Where(w => w.Length >= 3 && char.IsLetter(w[0])).ToList();
        return lng.Count > 0 && (double)lng.Count(w => char.IsUpper(w[0])) / lng.Count > 0.6;
    }

    private static string? FirstCapital(string s)
    {
        var w = Words(s).FirstOrDefault();
        return w is { Length: >= 3 } && char.IsUpper(w[0]) && !Common.Contains(w.ToLowerInvariant()) ? w.ToLowerInvariant() : null;
    }

    private static HashSet<string> Capitals(string s) =>
        Words(s).Where(w => w.Length >= 3 && char.IsUpper(w[0])).Select(w => w.ToLowerInvariant()).ToHashSet();

    public static bool Similar(HashSet<string> a, HashSet<string> b)
    {
        if (a.Count < 3 || b.Count < 3) return false;
        var inter = a.Intersect(b).Count();
        return (double)inter / Math.Min(a.Count, b.Count) >= 0.6 && inter >= 3;
    }
}
