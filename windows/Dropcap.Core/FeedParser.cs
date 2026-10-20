using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml;

namespace Dropcap.Core;

// XmlReader 로 간단한 나무를 만든 뒤 RSS·Atom·RDF·사이트맵을 해석한다(맥 XMLParser 판과 같은 방식).
public sealed class XNode(string name, Dictionary<string, string> attrs)
{
    public string Name { get; } = name;
    public Dictionary<string, string> Attrs { get; } = attrs;
    public List<XNode> Children { get; } = new();
    public StringBuilder Text { get; } = new();

    public XNode? Child(string n) => Children.FirstOrDefault(c => c.Name == n);
    public IEnumerable<XNode> All(string n) => Children.Where(c => c.Name == n);
    public string Value(string n) => Child(n)?.Text.ToString().Trim() ?? "";
    public string? Attr(string n) => Attrs.TryGetValue(n, out var v) ? v : null;

    // 아래 요소 수(자신 빼고) — 깨진 피드를 두 번 읽었을 때 더 많이 읽은 쪽 고르기(재귀 대신 스택)
    public int Count()
    {
        var n = 0;
        var stack = new Stack<XNode>(Children);
        while (stack.TryPop(out var c)) { n++; foreach (var x in c.Children) stack.Push(x); }
        return n;
    }
}

public class FeedException(string message) : Exception(message)
{
    public static FeedException BadFormat() => new("RSS/Atom 형식을 알아볼 수 없음");
}

public sealed class HttpStatusException(int code) : FeedException($"HTTP {code}")
{
    public int Code { get; } = code;
}

public sealed class BlockedException(string why) : FeedException($"안전하지 않은 주소라 막음: {why}");

public static class FeedParser
{
    public sealed record Entry(string Id, string Title, string Link, DateTimeOffset? Date, string Summary, string? Image = null, bool? Paid = null);

    // 피드가 기사마다 적은 유료 표시(feed-paid-mark — 출처의 paywall 값보다 앞선다). 맥 FeedParser.paidMark 와 같은 규칙:
    // STAT 'STAT+:' 제목 머리·'STAT+' 분류, MIT TR 'Subscriber-Only Stories' 분류 → 유료(true) · NYT 'internal-paywall-exempt' 분류 → 무료로 풀림(false, 먼저 봄).
    // 한경은 피드에 표시가 없다 — 미리 받기 판정(맛보기)으로 알린다
    public static readonly IReadOnlySet<string> PaidCategories = new HashSet<string> { "stat+", "subscriber-only stories" };
    public static readonly IReadOnlySet<string> FreeCategories = new HashSet<string> { "internal-paywall-exempt" };
    public static readonly string[] PaidTitlePrefixes = ["STAT+:"];
    public static bool? PaidMark(XNode it)
    {
        var cats = it.All("category").Concat(it.All("dc:subject"))
            .Select(c => Plain.Clean(c.Attr("term") ?? c.Text.ToString()).ToLowerInvariant()).ToHashSet();
        if (cats.Overlaps(FreeCategories)) return false;
        if (cats.Overlaps(PaidCategories)) return true;
        var title = Plain.Clean(it.Value("title"));
        if (PaidTitlePrefixes.Any(p => title.StartsWith(p, StringComparison.Ordinal))) return true;
        return null;
    }

    static FeedParser()
    {
        // euc-kr 같은 옛 인코딩의 국내 피드
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
    }

    // 대표 사진: media:content / media:thumbnail / 그림 enclosure / 본문의 첫 <img>
    public static string? Image(XNode it)
    {
        foreach (var n in it.Children)
        {
            switch (n.Name)
            {
                case "media:thumbnail":
                    if (n.Attr("url") is { } u0) return u0;
                    break;
                case "media:content":
                    if (n.Attr("url") is { } u1 && IsImage(n)) return u1;
                    if (n.Child("media:thumbnail")?.Attr("url") is { } t1) return t1;
                    break;
                case "media:group":
                    if (n.Child("media:thumbnail")?.Attr("url") is { } t2) return t2;
                    if (n.All("media:content").FirstOrDefault(IsImage)?.Attr("url") is { } u2) return u2;
                    break;
                case "enclosure":
                    if (n.Attr("type")?.StartsWith("image", StringComparison.Ordinal) == true && n.Attr("url") is { } u3) return u3;
                    break;
            }
        }
        foreach (var field in new[] { "content:encoded", "content", "description", "summary" })
        {
            // <img …> 를 하나씩 떼어 본다(HtmlScan — 정규식 되풀이 훑기로 큰 본문에서 멈추지 않게, 보안 점검)
            var html = it.Value(field);
            foreach (var tag in HtmlScan.Tags("img", html.Length > 512_000 ? html[..512_000] : html))
                if ((HtmlScan.Attr(tag, "src") ?? HtmlScan.Attr(tag, "data-src")) is { Length: > 0 } u) return u;
        }
        return null;
    }

    private static bool IsImage(XNode n)
    {
        if (n.Attr("medium") == "image" || n.Attr("type")?.StartsWith("image", StringComparison.Ordinal) == true) return true;
        var u = (n.Attr("url") ?? "").ToLowerInvariant();
        return n.Attr("medium") is null && n.Attr("type") is null && new[] { ".jpg", ".jpeg", ".png", ".webp", ".gif" }.Any(u.Contains);
    }

    // 피드 자체의 이름(구독할 때 기본 이름으로)
    public static string? FeedTitle(byte[] data)
    {
        XNode root;
        try { root = Tree(data); } catch { return null; }
        var t = NonEmpty(root.Child("rss")?.Child("channel")?.Value("title")) ?? NonEmpty(root.Child("feed")?.Value("title"))
            ?? NonEmpty(root.Child("rdf:RDF")?.Child("channel")?.Value("title"));
        return t is null ? null : Plain.Clean(t);
    }

    public static XNode Tree(byte[] data)
    {
        var (root, ok) = TreeOnce(data);
        // 해석이 깨지면 엔티티가 아닌 & 만 &amp; 로 고쳐 한 번 더(Rest of World: 사진 주소의 '?width=380&dpr=2').
        // 다시도 깨지면 둘 중 더 많이 읽은 쪽(고친 & 뒤 다른 곳에서 깨져도 그 앞까지는 고친 쪽이 더 읽음)
        if (!ok && RepairAmpersands(data) is { } repaired)
        {
            var (again, ok2) = TreeOnce(repaired);
            if (ok2) return again;
            if (again.Count() > root.Count()) root = again;
        }
        // 중간에 깨진 문서라도 읽은 데까지는 쓴다(맥: parse() 실패해도 나무가 있으면 사용)
        if (!ok && root.Children.Count == 0) throw FeedException.BadFormat();
        return root;
    }

    // 고친 결과가 받는 상한(SafeHttp.MaxBody 와 같은 32MB)을 넘으면 고치지 않는다
    public const int RepairMaxBytes = 32 << 20;

    // 엔티티(이름; · #숫자; · #x16진수;)가 아닌 & 를 &amp; 로. CDATA·주석 안은 그대로.
    // 고칠 것이 없거나 UTF-16 문서거나 상한을 넘으면 null
    public static byte[]? RepairAmpersands(byte[] s)
    {
        var n = s.Length;
        if (n >= 2 && (s[0] == 0 || s[1] == 0 || (s[0] == 0xFE && s[1] == 0xFF) || (s[0] == 0xFF && s[1] == 0xFE))) return null;
        bool At(int i, byte[] lit) => i + lit.Length <= n && s.AsSpan(i, lit.Length).SequenceEqual(lit);
        static bool Alpha(byte c) => (c | 0x20) is >= (byte)'a' and <= (byte)'z';
        static bool Digit(byte c) => c is >= (byte)'0' and <= (byte)'9';
        bool IsRef(int i)
        {
            var j = i + 1;
            if (j < n && s[j] == (byte)'#')
            {
                j++;
                var hex = j < n && (s[j] | 0x20) == 'x';
                if (hex) j++;
                var st = j;
                while (j < n && (Digit(s[j]) || (hex && (s[j] | 0x20) is >= 'a' and <= 'f'))) j++;
                if (j == st) return false;
            }
            else
            {
                if (!(j < n && (Alpha(s[j]) || s[j] is (byte)'_' or (byte)':'))) return false;
                while (j < n && (Alpha(s[j]) || Digit(s[j]) || s[j] is (byte)'_' or (byte)':' or (byte)'.' or (byte)'-')) j++;
            }
            return j < n && s[j] == (byte)';' && j - i <= 32;
        }
        (byte[] Open, byte[] Close)[] skips = [("<![CDATA["u8.ToArray(), "]]>"u8.ToArray()), ("<!--"u8.ToArray(), "-->"u8.ToArray())];
        var amp = "&amp;"u8;
        using var buf = new MemoryStream(n + 1024);
        var changed = false;
        var k = 0;
        while (k < n)
        {
            if (s[k] == (byte)'<' && Array.Find(skips, p => At(k, p.Open)) is { Open: not null } skip)
            {
                var j = k + skip.Open.Length;
                while (j < n && !At(j, skip.Close)) j++;
                var stop = Math.Min(n, j + skip.Close.Length);
                buf.Write(s, k, stop - k);
                k = stop;
                continue;
            }
            if (s[k] == (byte)'&' && !IsRef(k))
            {
                buf.Write(amp);
                changed = true;
                if (buf.Length > RepairMaxBytes) return null;
            }
            else buf.WriteByte(s[k]);
            k++;
        }
        return changed && buf.Length <= RepairMaxBytes ? buf.ToArray() : null;
    }

    // 한 번 읽기: (나무, 끝까지 읽었는지)
    private static (XNode Root, bool Ok) TreeOnce(byte[] data)
    {
        var root = new XNode("#root", new());
        var stack = new Stack<XNode>();
        stack.Push(root);
        // 앞의 공백·BOM 때문에 형식 오류가 나지 않게
        var start = 0;
        while (start < data.Length && (data[start] is (byte)' ' or (byte)'\t' or (byte)'\r' or (byte)'\n')) start++;
        var settings = new XmlReaderSettings
        {
            DtdProcessing = DtdProcessing.Ignore,   // 바깥 엔티티·DTD 를 따라가지 않는다
            XmlResolver = null,
            IgnoreComments = true,
            IgnoreProcessingInstructions = true,
            CheckCharacters = false,
        };
        try
        {
            using var ms = new MemoryStream(data, start, data.Length - start);
            using var r = XmlReader.Create(ms, settings);
            while (r.Read())
            {
                switch (r.NodeType)
                {
                    case XmlNodeType.Element:
                        var attrs = new Dictionary<string, string>();
                        if (r.HasAttributes)
                        {
                            while (r.MoveToNextAttribute()) attrs[r.Name] = r.Value;
                            r.MoveToElement();
                        }
                        var n = new XNode(r.Name, attrs);
                        stack.Peek().Children.Add(n);
                        if (!r.IsEmptyElement) stack.Push(n);
                        break;
                    case XmlNodeType.EndElement:
                        if (stack.Count > 1) stack.Pop();
                        break;
                    case XmlNodeType.Text:
                    case XmlNodeType.CDATA:
                    case XmlNodeType.Whitespace:
                    case XmlNodeType.SignificantWhitespace:
                        stack.Peek().Text.Append(r.Value);
                        break;
                }
            }
        }
        catch (XmlException)
        {
            return (root, false);
        }
        return (root, true);
    }

    public static List<Entry> ParseFeed(byte[] data)
    {
        var root = Tree(data);
        if (root.Child("rss")?.Child("channel") is { } channel)
        {
            return channel.All("item").Select(it =>
            {
                var link = it.Value("link");
                return new Entry(NonEmpty(it.Value("guid")) ?? link, Plain.Clean(it.Value("title")), link,
                    Dates.Parse(NonEmpty(it.Value("pubDate")) ?? it.Value("dc:date")),
                    Prefix(Plain.Clean(it.Value("description")), 300), Image(it), PaidMark(it));
            }).ToList();
        }
        if (root.Child("feed") is { } feed)
        {
            return feed.All("entry").Select(it =>
            {
                var links = it.All("link").ToList();
                var alt = links.FirstOrDefault(l => (l.Attr("rel") ?? "alternate") == "alternate") ?? links.FirstOrDefault();
                var link = alt?.Attr("href") ?? alt?.Text.ToString() ?? "";
                return new Entry(NonEmpty(it.Value("id")) ?? link, Plain.Clean(it.Value("title")), link,
                    Dates.Parse(NonEmpty(it.Value("published")) ?? it.Value("updated")),
                    Prefix(Plain.Clean(NonEmpty(it.Value("summary")) ?? it.Value("content")), 300), Image(it), PaidMark(it));
            }).ToList();
        }
        if (root.Child("rdf:RDF") is { } rdf)
        {
            return rdf.All("item").Select(it => new Entry(it.Value("link"), Plain.Clean(it.Value("title")), it.Value("link"),
                Dates.Parse(it.Value("dc:date")), Prefix(Plain.Clean(it.Value("description")), 300))).ToList();
        }
        throw FeedException.BadFormat();
    }

    public static List<Entry> ParseSitemap(byte[] data, Regex match)
    {
        var root = Tree(data);
        var set = root.Child("urlset") ?? throw FeedException.BadFormat();
        return set.All("url").Select(u => (Loc: u.Value("loc"), Node: u))
            .Where(p => match.IsMatch(p.Loc))
            // 뉴스 사이트맵의 발행 시각(news:publication_date)을 먼저, 없으면 lastmod — 한국일보·문화일보는 발행 시각만 있다
            .Select(p => new Entry(p.Loc, "", p.Loc,
                Dates.Parse(NonEmpty(p.Node.Child("news:news")?.Value("news:publication_date")) ?? p.Node.Value("lastmod")), "")).ToList();
    }

    internal static string? NonEmpty(string? s) => string.IsNullOrEmpty(s) ? null : s;

    // 맥 String.prefix 와 같게(글자 단위로 자르되 짝 문자를 쪼개지 않음)
    public static string Prefix(string s, int n)
    {
        var info = new StringInfo(s);
        return info.LengthInTextElements <= n ? s : info.SubstringByTextElements(0, n);
    }
}

public static class Dates
{
    private static readonly Regex Iso = new(@"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d+)?(Z|[+-]\d{2}:?\d{2})$", RegexOptions.IgnoreCase);
    // 요일을 뗀 뒤: 'd MMM yyyy HH:mm(:ss) 시간대' 또는 월을 숫자로('13 10 2026 16:00:47 +0900', 노컷뉴스)
    private static readonly Regex Rfc = new(@"^(\d{1,2})\s+([A-Za-z]{3,9}|\d{1,2})\s+(\d{4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([A-Za-z]{1,4}|[+-]\d{2}:?\d{2})?$");
    private static readonly Regex Weekday = new(@"^[A-Za-z]{2,9}\.?,?\s+");
    // 시간대 없는 국내 표기(AI타임스 'yyyy-MM-dd HH:mm:ss', 점·빗금 구분, 날짜만)는 한국 시각으로 읽는다
    private static readonly Regex Local = new(@"^(\d{4})[-./](\d{1,2})[-./](\d{1,2})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?$");
    private static readonly Regex Korean = new(@"(\d{4})년\s*(\d{1,2})월\s*(\d{1,2})일(?:\s*\S+요일)?(?:\s*(오전|오후))?(?:\s*(\d{1,2}):(\d{2})(?::(\d{2}))?)?");
    private static readonly string[] Months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
    private static readonly Dictionary<string, int> Zones = new(StringComparer.OrdinalIgnoreCase)
    {
        ["GMT"] = 0, ["UT"] = 0, ["UTC"] = 0, ["Z"] = 0,
        ["EST"] = -5, ["EDT"] = -4, ["CST"] = -6, ["CDT"] = -5, ["MST"] = -7, ["MDT"] = -6, ["PST"] = -8, ["PDT"] = -7,
        ["KST"] = 9, ["JST"] = 9, ["CET"] = 1, ["CEST"] = 2, ["BST"] = 1,
    };
    public static readonly TimeSpan Seoul = TimeSpan.FromHours(9);

    private static TimeSpan? Offset(string z)
    {
        if (z.Length == 0) return null;
        if (z[0] is '+' or '-')
        {
            var d = z.Replace(":", "");
            var sign = d[0] == '-' ? -1 : 1;
            return new TimeSpan(sign * int.Parse(d.Substring(1, 2)), sign * int.Parse(d.Substring(3, 2)), 0);
        }
        return Zones.TryGetValue(z, out var h) ? TimeSpan.FromHours(h) : null;
    }

    private static DateTimeOffset? Make(int y, int mo, int d, int h, int mi, int s, TimeSpan off, double frac = 0)
    {
        try { return new DateTimeOffset(y, mo, d, h, mi, s, off).AddTicks((long)(frac * TimeSpan.TicksPerSecond)); } catch { return null; }
    }

    public static DateTimeOffset? Parse(string? s)
    {
        var t = (s ?? "").Trim();
        if (t.Length == 0) return null;
        var m = Iso.Match(t);
        if (m.Success)
        {
            var off = Offset(m.Groups[8].Value.ToUpperInvariant() == "Z" ? "Z" : m.Groups[8].Value);
            var frac = m.Groups[7].Success ? double.Parse("0" + m.Groups[7].Value, CultureInfo.InvariantCulture) : 0;
            return off is { } o ? Make(I(m, 1), I(m, 2), I(m, 3), I(m, 4), I(m, 5), I(m, 6), o, frac) : null;
        }
        if (KoreanWords(t) is { } k) return k;
        var n = Regex.Replace(Weekday.Replace(t, ""), @"\s+", " ");   // 요일 떼기(틀린 요일도 읽힘)
        m = Rfc.Match(n);
        if (m.Success)
        {
            var mon = m.Groups[2].Value;
            var month = char.IsDigit(mon[0]) ? int.Parse(mon) : Array.IndexOf(Months, mon[..3].ToLowerInvariant()) + 1;
            if (month <= 0) return null;
            var off = Offset(m.Groups[7].Value);
            if (off is null) return null;   // 시간대 이름을 모르면 읽지 않음
            return Make(I(m, 3), month, I(m, 1), I(m, 4), I(m, 5), m.Groups[6].Success ? I(m, 6) : 0, off.Value);
        }
        m = Local.Match(n);
        if (m.Success) return Make(I(m, 1), I(m, 2), I(m, 3), m.Groups[4].Success ? I(m, 4) : 0, m.Groups[5].Success ? I(m, 5) : 0, m.Groups[6].Success ? I(m, 6) : 0, Seoul);
        return null;
    }

    // '2024년 10월 29일 화요일 오후 11:30:00' 같은 한국어 표기(한국 시각)
    private static DateTimeOffset? KoreanWords(string t)
    {
        if (!t.Contains('년')) return null;
        var m = Korean.Match(t);
        if (!m.Success) return null;
        var hour = m.Groups[5].Success ? I(m, 5) : 0;
        if (m.Groups[4].Value == "오후" && hour < 12) hour += 12;
        if (m.Groups[4].Value == "오전" && hour == 12) hour = 0;
        return Make(I(m, 1), I(m, 2), I(m, 3), hour, m.Groups[6].Success ? I(m, 6) : 0, m.Groups[7].Success ? I(m, 7) : 0, Seoul);
    }

    private static int I(Match m, int g) => int.Parse(m.Groups[g].Value, CultureInfo.InvariantCulture);
}

// 피드 날짜 다듬기(맥 FeedDates 와 같음): 받은 뒤 한 번에 적용한다.
// - 날짜가 없는 글(한겨레 RSS 등)은 처음 본 시각을 날짜로(같은 실행 동안 바뀌지 않게 기억)
// - 지금보다 10분 넘게 앞선 시각(시간대를 잘못 찍은 피드, 예약 글)은 받은 시각으로 자른다
public static class FeedDates
{
    public static readonly TimeSpan FutureSlack = TimeSpan.FromMinutes(10);
    public const int MemoryLimit = 20000;

    public static void Repair(List<FeedParser.Entry> entries, string sourceId, DateTimeOffset now, Dictionary<string, DateTimeOffset> firstSeen)
    {
        for (var i = 0; i < entries.Count; i++)
        {
            var e = entries[i];
            if (e.Date is { } d)
            {
                if (d - now > FutureSlack) entries[i] = e with { Date = now };
            }
            else
            {
                var key = $"{sourceId}|{e.Id}";
                if (!firstSeen.TryGetValue(key, out var seen)) firstSeen[key] = seen = now;
                entries[i] = e with { Date = seen };
            }
        }
        if (firstSeen.Count > MemoryLimit)
            foreach (var (k, _) in firstSeen.OrderBy(p => p.Value).Take(firstSeen.Count - MemoryLimit / 2).ToList()) firstSeen.Remove(k);
    }
}

public static class Plain
{
    private static readonly Dictionary<string, string> Named = new()
    {
        ["nbsp"] = " ", ["amp"] = "&", ["lt"] = "<", ["gt"] = ">", ["quot"] = "\"", ["apos"] = "'",
        ["rsquo"] = "’", ["lsquo"] = "‘", ["ldquo"] = "“", ["rdquo"] = "”", ["hellip"] = "…", ["ndash"] = "–", ["mdash"] = "—",
        ["middot"] = "·", ["bull"] = "•", ["laquo"] = "«", ["raquo"] = "»", ["copy"] = "©", ["reg"] = "®", ["trade"] = "™",
    };
    private static readonly Regex Entity = new("&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z]{2,8});");
    private static readonly Regex Spaces = new(@"\s+");

    public static string Clean(string s)
    {
        var o = DecodeEntities(StripTags(s));
        return Spaces.Replace(o, " ").Trim(' ', '\t');
    }

    // 꼬리표를 빈칸으로(정규식 "<[^>]*>" 와 같음). 한 번 훑는다 — 닫히지 않은 '<' 가 많은 글에서 정규식은 크기의 제곱으로 느려진다(보안 점검)
    public static string StripTags(string s)
    {
        if (!s.Contains('<')) return s;
        var o = new System.Text.StringBuilder(s.Length);
        var i = 0;
        while (i < s.Length)
        {
            var lt = s.IndexOf('<', i);
            if (lt < 0) break;
            var gt = s.IndexOf('>', lt + 1);
            if (gt < 0) break;   // 뒤에 '>' 가 없으면 남은 '<' 도 꼬리표가 아니다
            o.Append(s, i, lt - i).Append(' ');
            i = gt + 1;
        }
        return o.Append(s, i, s.Length - i).ToString();
    }

    // 한 번에 훑어 푼다(&amp;lt; 가 '<' 로 두 번 풀리지 않게). 숫자 표기(&#8217; · &#x2019;)는 모두, 이름 표기는 흔한 것만.
    public static string DecodeEntities(string s)
    {
        if (!s.Contains('&')) return s;
        return Entity.Replace(s, m =>
        {
            var body = m.Groups[1].Value;
            if (body[0] == '#')
            {
                var hex = body.Length > 1 && (body[1] == 'x' || body[1] == 'X');
                var digits = hex ? body[2..] : body[1..];
                if (int.TryParse(digits, hex ? System.Globalization.NumberStyles.HexNumber : System.Globalization.NumberStyles.None,
                        System.Globalization.CultureInfo.InvariantCulture, out var v) && v != 0 && v <= 0x10FFFF && (v < 0xD800 || v > 0xDFFF))
                    return char.ConvertFromUtf32(v);
                return m.Value;
            }
            return Named.TryGetValue(body, out var r) || Named.TryGetValue(body.ToLowerInvariant(), out r) ? r : m.Value;
        });
    }

    public static string TitleFromSlug(string url)
    {
        var slug = url.Split('/', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? url;
        var t = Regex.Replace(slug, "[-_]+", " ");
        return t.Length == 0 ? t : t[..1].ToUpperInvariant() + t[1..];
    }
}
