using System.Globalization;
using System.Text;

namespace Dropcap.Core;

// 스크랩: 기사 전체 또는 문단 하나를 메모와 함께 폴더(컬렉션)에 모아 둔다.
public sealed record Scrap
{
    public string Id { get; init; } = Guid.NewGuid().ToString().ToUpperInvariant();
    public NewsItem Item { get; init; } = new();
    public string? Quote { get; init; }          // 문단 스크랩이면 그 문단(보이던 언어)
    public string? QuoteOriginal { get; init; }  // 번역문을 스크랩했으면 원문
    public string Memo { get; init; } = "";
    public string Collection { get; init; } = Scrapbook.DefaultCollection;
    public DateTimeOffset Created { get; init; } = DateTimeOffset.Now;
}

public sealed class Scrapbook
{
    private static Scrapbook? shared;
    public static Scrapbook Shared => shared ??= new Scrapbook(Database.Shared);

    public const string DefaultCollection = "스크랩";
    private readonly Database db;

    public IReadOnlyList<Scrap> Scraps { get; private set; } = [];
    public IReadOnlyList<string> Collections { get; private set; } = [];
    public event Action? Changed;

    public Scrapbook(Database db) { this.db = db; Reload(); }

    public void Reload()
    {
        Scraps = db.Scraps();
        var used = Scraps.Select(s => s.Collection).ToHashSet();
        var extra = Prefs.Get("scrapCollections", new List<string>()).Where(c => !used.Contains(c));
        var all = new List<string>();
        foreach (var c in new[] { DefaultCollection }.Concat(used.Order(StringComparer.Ordinal)).Concat(extra))
            if (!all.Contains(c)) all.Add(c);
        Collections = all;
        Changed?.Invoke();
    }

    public string LastCollection => Prefs.Get<string?>("lastScrapCollection", null) ?? DefaultCollection;

    public void Add(NewsItem item, string? quote = null, string? original = null, string memo = "", string? collection = null)
    {
        var c = (collection ?? LastCollection).Trim();
        if (c.Length == 0) c = DefaultCollection; // 이름 없는 폴더는 만들지 않음
        // 같은 문단을 두 번 스크랩하지 않게
        if (quote is not null && Scraps.Any(s => s.Item.Key == item.Key && s.Quote == quote && s.Collection == c)) return;
        if (quote is null && Scraps.Any(s => s.Item.Key == item.Key && s.Quote is null && s.Collection == c)) return;
        db.SaveScrap(new Scrap { Item = item, Quote = quote, QuoteOriginal = original, Memo = memo, Collection = c });
        Prefs.Set("lastScrapCollection", c);
        Reload();
    }

    public void Update(Scrap s) { db.SaveScrap(s); Reload(); }
    public void Remove(Scrap s) { db.DeleteScrap(s.Id); Reload(); }

    public bool CreateCollection(string name)
    {
        var n = name.Trim();
        if (n.Length == 0 || Collections.Contains(n)) return false;
        Prefs.Set("scrapCollections", Prefs.Get("scrapCollections", new List<string>()).Append(n).ToList());
        Reload();
        return true;
    }

    public bool Rename(string from, string to)
    {
        var n = to.Trim();
        if (n.Length == 0 || n == from || Collections.Contains(n)) return false;
        db.RenameCollection(from, n);
        Prefs.Set("scrapCollections", Prefs.Get("scrapCollections", new List<string>()).Select(c => c == from ? n : c).ToList());
        if (LastCollection == from) Prefs.Set("lastScrapCollection", n);
        Reload();
        return true;
    }

    public bool IsScrapped(NewsItem item, string? quote = null) =>
        Scraps.Any(s => s.Item.Key == item.Key && (quote is null || s.Quote == quote));

    // MARK: 내보내기(Markdown)(M-18)
    public string Markdown(string collection) => Render(Scraps.Where(s => s.Collection == collection).ToList(), collection);

    // 스크랩 목록(최근 것이 앞)을 Markdown 으로. 기사별로 묶고, 인용·원문·메모를 함께. 맥 Scrapbook.render 와 같은 형식.
    public static string Render(IReadOnlyList<Scrap> list, string collection, DateTimeOffset? today = null)
    {
        static string Day(DateTimeOffset d) => d.ToLocalTime().ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        var o = new StringBuilder();
        o.Append($"# {collection}\n\n");
        o.Append($"_Dropcap 스크랩 · {Day(today ?? DateTimeOffset.Now)} · {list.Count}건_\n\n");
        // 기사별로 묶어서
        var order = new List<string>();
        var groups = new Dictionary<string, List<Scrap>>();
        foreach (var s in list.Reverse())
        {
            if (!groups.ContainsKey(s.Item.Key)) { order.Add(s.Item.Key); groups[s.Item.Key] = new(); }
            groups[s.Item.Key].Add(s);
        }
        foreach (var key in order)
        {
            var g = groups[key];
            var it = g[0].Item;
            o.Append($"## [{it.DisplayTitle}]({it.Link})\n\n");
            var meta = it.SourceName;
            if (it.Date is { } d) meta += $" · {Day(d)}";
            if (it.TitleKo is not null && it.TitleKo != it.Title) meta += $" · 원제: {it.Title}";
            o.Append($"{meta}\n\n");
            foreach (var s in g)
            {
                if (s.Quote is { } q)
                {
                    o.Append($"> {q.Replace("\n", "\n> ")}\n");
                    if (s.QuoteOriginal is { } orig && orig != q) o.Append($">\n> _{orig}_\n");
                    o.Append('\n');
                }
                if (s.Memo.Length > 0) o.Append($"- 메모: {s.Memo}\n\n");
            }
        }
        return o.ToString();
    }
}
