using System.Text.Json.Nodes;
using Dropcap.Core;

namespace Dropcap.Ui;

// 상단바 창 대신 트레이를 누르면 뜨는 작은 창(U 절). 맥 MenuView 와 같은 내용·문구.
public sealed class MenuPage(AppModel model, IPlatform platform) : IPage
{
    public string Name => "menu";

    // 지금 보이는 목록(읽기 창 J·K 가 이 순서로 넘김, H-05)
    private List<NewsItem> shown = new();

    public enum Tab { All, Unread, Saved }

    // 목록 거르기·정렬(맥 MenuView.items 와 같은 규칙). section: 분야 칩(주요 뉴스는 여러 곳이 다룬 소식·공식 발표·꼭 알림 낱말),
    // topic: AI 칩을 눌렀을 때만 그 안의 하위 칩(모델·연구…)
    public static List<NewsItem> Items(AppModel m, Tab tab, string query, string? section, NewsCategory? topic, string sort)
    {
        IEnumerable<NewsItem> list = tab switch
        {
            Tab.Unread => m.VisibleRecent.Where(i => !m.IsRead(i)),   // 꺼진·해지한·숨긴 출처 글은 빠짐(S-13)
            Tab.Saved => m.State.Saved,                               // 저장한 기사는 사용자가 고른 것이라 그대로
            _ => m.VisibleRecent,
        };
        if (section is { } s)
            list = s == Sections.Top
                ? list.Where(i => (i.Related?.Count ?? 0) >= 1 || i.Tier == "lab" || i.Important == true)
                : list.Where(i => i.InSection(s));
        if (section == Sections.Ai && topic is { } c) list = list.Where(i => i.Category == c);
        var q = query.Trim().ToLowerInvariant();
        if (q.Length > 0) list = list.Where(i => $"{i.Title} {i.TitleKo ?? ""} {i.SourceName} {i.Summary}".ToLowerInvariant().Contains(q));
        var d = (NewsItem i) => i.Date ?? DateTimeOffset.MinValue;
        var all = list.ToList();
        return sort switch
        {
            "important" => ByImportance(all, m.Magazine.Coverage(all), m.Now()),
            "source" => all.OrderBy(i => i.SourceName, StringComparer.Ordinal).ThenByDescending(d).ToList(),
            _ => all.OrderByDescending(d).ToList(),
        };
    }

    // 분야 칩 한 개(맥 SectionChip). 색은 라이트·다크 두 가지(#RRGGBB 만)
    public sealed record Chip(string Id, string Label, string Icon, string Light, string Dark);

    // 분야 칩 줄(G-09, 맥 SectionChipBar): '전체'(화면이 그림) + 고른 분야. AI 를 고르면 AI 하위 칩 한 줄 더('기타'는 뺌)
    public static List<Chip> SectionChips(AppModel m) =>
        m.ChosenSections.Select(Sections.ById).OfType<NewsSection>()
            .Select(s => new Chip(s.Id, s.Name, s.Icon, ItemView.SafeColor(s.Color), ItemView.SafeColor(s.Color))).ToList();

    public static List<Chip> TopicChips() =>
        Categories.All.Where(c => !c.IsOther())
            .Select(c => { var col = c.Color(); return new Chip(c.Raw(), c.Label(), c.Glyph(), ItemView.SafeColor(col.Light), ItemView.SafeColor(col.Dark)); }).ToList();

    // 중요도 점수(맥 MenuView.byImportance 와 같은 식): 꼭 알림 낱말(★) > 여러 곳이 다룬 정도(스토리 크기·외 N곳) > 공식 발표 > 최근일수록 조금 더
    public static List<NewsItem> ByImportance(IReadOnlyList<NewsItem> list, IReadOnlyDictionary<string, int> coverage, DateTimeOffset now)
    {
        double Score(NewsItem it)
        {
            var outlets = Math.Max(coverage.GetValueOrDefault(it.Key, 1), (it.Related?.Count ?? 0) + 1);
            var hours = Math.Max(0, (now - (it.Date ?? now)).TotalHours);
            return (it.Important == true ? 100 : 0) + (outlets - 1) * 12.0 + (it.Tier == "lab" ? 8 : 0) + 6 * Math.Exp(-hours / 12);
        }
        return list.Select(i => (Item: i, Score: Score(i)))
            .OrderByDescending(x => x.Score).ThenByDescending(x => x.Item.Date ?? DateTimeOffset.MinValue)
            .Select(x => x.Item).ToList();
    }

    // 시간 묶음 이름표(맥 MenuStyles.timeSection): 방금(1시간 안) · 오늘 · 어제 · 이전 — 앞 기사와 묶음이 바뀔 때만
    public static string? TimeSection(NewsItem it, NewsItem? prev, DateTimeOffset now)
    {
        string Bucket(DateTimeOffset? d)
        {
            if (d is null) return "이전";
            if ((now - d.Value).TotalSeconds < 3600) return "방금";
            var day = d.Value.ToLocalTime().Date;
            var today = now.ToLocalTime().Date;
            if (day == today) return "오늘";
            if (day == today.AddDays(-1)) return "어제";
            return "이전";
        }
        var b = Bucket(it.Date);
        return prev is not null && Bucket(prev.Date) == b ? null : b;
    }

    // 줄의 작은 사진(맥 RowThumb): 피드 사진, 없으면 매거진이 기사 머리에서 찾아 둔 대표 사진. 잡그림(프로필·로고 등)은 뺀다
    public static string? Thumb(NewsItem it, Func<string, string?> stored)
    {
        if (it.Image is { } img && !ImageKey.IsJunk(img)) return img;
        return stored(it.Key) is { } s && !ImageKey.IsJunk(s) ? s : null;
    }

    // 목록 한 줄과 그 위에 붙는 이름표(맥 MenuView 의 listStyle2 = "hero": 첫 소식 크게, 나머지는 작은 카드)
    public sealed record Row
    {
        public ItemView Item { get; init; } = new();
        public string? Thumb { get; init; }
        public bool Hero { get; init; }            // 첫 소식 크게
        public string? Section { get; init; }      // 시간 묶음 이름표
        public bool SectionFirst { get; init; }    // 위 여백을 좁게
        public string? SourceHead { get; init; }   // 출처별일 때 출처가 바뀌는 곳의 이름표
        public int SourceCount { get; init; }
        public bool SourceFirst { get; init; }
        // 줄의 분야 표시(U-05·N-05): 분야 이름, AI 글은 'AI·모델'처럼 하위 분류까지
        public string TopicLabel { get; init; } = "";
        public string TopicIcon { get; init; } = "";
        public string TopicLight { get; init; } = "";
        public string TopicDark { get; init; } = "";
    }

    public static List<Row> Rows(AppModel m, IReadOnlyList<NewsItem> list, string sort, DateTimeOffset now)
    {
        var counts = list.GroupBy(i => i.SourceName).ToDictionary(g => g.Key, g => g.Count());
        var rows = new List<Row>(list.Count);
        for (var i = 0; i < list.Count; i++)
        {
            var it = list[i];
            var prev = i > 0 ? list[i - 1] : null;
            var head = sort == "source" && (prev is null || prev.SourceName != it.SourceName);
            var section = sort != "source" && i > 0 ? TimeSection(it, prev, now) : null;
            var tc = it.TopicColor();
            rows.Add(new Row
            {
                Item = ItemView.From(it, m, now),
                Thumb = Thumb(it, m.Magazine.StoredImage),
                Hero = i == 0,
                Section = section,
                SectionFirst = i == 1,
                SourceHead = head ? it.SourceName : null,
                SourceCount = head ? counts[it.SourceName] : 0,
                SourceFirst = i == 0,
                TopicLabel = it.TopicLabel(),
                TopicIcon = it.TopicIcon(),
                TopicLight = ItemView.SafeColor(tc.Light),
                TopicDark = ItemView.SafeColor(tc.Dark),
            });
        }
        return rows;
    }

    // U-06: 빈 화면 문구
    public static (string Icon, string Title, string Sub) Empty(Tab tab, bool filtered) => (
        tab == Tab.Saved ? "bookmark" : "newspaper",
        filtered ? "맞는 소식이 없습니다" : tab == Tab.Saved ? "저장한 소식이 없습니다" : tab == Tab.Unread ? "모두 읽었습니다" : "아직 새 소식이 없습니다",
        tab == Tab.Saved ? "소식을 오른쪽 클릭해 '나중에 읽기'로 저장할 수 있어요" : "새 글이 올라오면 물방울이 떨어지듯 알려 드려요");

    // 바로 줄이기(G-11, 맥 ReduceMenu): 오른쪽 클릭 메뉴에 보일 출처명·분야명·지금 모드→다음 모드·제목 낱말
    public object ReduceInfo(NewsItem it)
    {
        var sec = model.NotifySection(it);
        var mode = model.Policy(sec).Mode;
        var canLess = model.ChosenSections.Contains(sec) && mode != NotifyMode.Magazine;
        var next = mode == NotifyMode.Instant ? NotifyMode.Bundle : NotifyMode.Magazine;
        return new
        {
            source = it.SourceName,
            section = sec,
            sectionName = Sections.Name(sec),
            mode = mode.Raw(),
            modeLabel = mode.Label(),
            canLess,
            next = canLess ? next.Raw() : null,
            lessLabel = canLess ? $"{Sections.Name(sec)} 덜 받기 — {(mode == NotifyMode.Instant ? "묶음으로" : "매거진에만")}" : null,
            hideLabel = $"이 출처 숨기기 — {it.SourceName}",
            words = AppModel.TitleWords(it),
        };
    }

    public object View(JsonObject a)
    {
        var tab = a.Str("tab") switch { "unread" => Tab.Unread, "saved" => Tab.Saved, _ => Tab.All };
        // 분야 칩: 고른 분야만(고른 분야가 바뀌어 칩이 사라졌으면 '전체'로 — 화면은 돌려받은 section 을 따른다)
        var section = a.StrOrNull("section") is { Length: > 0 } sid && model.ChosenSections.Contains(sid) ? sid : null;
        var topic = section == Sections.Ai && a.StrOrNull("topic") is { Length: > 0 } ts && Categories.All.Any(c => c.Raw() == ts)
            ? Categories.Parse(ts) : (NewsCategory?)null;
        var query = a.Str("query");
        var sort = a.StrOrNull("sort") ?? Prefs.Get("listSort", "newest");
        if (a.StrOrNull("sort") is { } s) Prefs.Set("listSort", s);
        var items = Items(model, tab, query, section, topic, sort);
        shown = items;
        var empty = Empty(tab, query.Trim().Length > 0 || section is not null || topic is not null);
        var now = model.Now();
        return new
        {
            header = new
            {
                title = "Dropcap",
                checking = model.Checking,
                status = model.Checking ? "확인하는 중…" : $"마지막 확인 {RelativeTime.Clock(model.State.LastCheck)}",
                quiet = model.IsQuietTime,
                // 회의·발표 중 자동 조용히(N-25): 방해 금지 달 자리에 이유
                autoQuiet = model.AutoQuietReason?.Label(),
                autoQuietHelp = model.AutoQuietReason is { } why ? $"{why.Label()}이라 알림을 띄우지 않고 모아 둡니다" : null,
                snoozed = model.IsSnoozed,
                snoozeHelp = model.IsSnoozed ? $"알림 꺼짐 — {RelativeTime.Clock(model.State.SnoozeUntil)}까지" : "알림 잠시 끄기",
            },
            unread = model.VisibleRecent.Count(i => !model.IsRead(i)),
            sort,
            sortLabel = sort switch { "important" => "중요순", "source" => "출처별", _ => null },
            rows = Rows(model, items, sort, now),
            empty = new { icon = empty.Icon, title = empty.Title, sub = empty.Sub },
            section,
            topic = topic?.Raw(),
            chips = SectionChips(model),
            topics = section == Sections.Ai ? TopicChips() : new List<Chip>(),
            hotkey = "Ctrl+Alt+M",
        };
    }

    public async Task<object?> Handle(string cmd, JsonObject a)
    {
        NewsItem Item() => Lookup.Find(model, a.Str("key")) ?? throw new KeyNotFoundException("기사를 찾지 못함");
        switch (cmd)
        {
            case "ready":
                model.MarkRead(); // U-08: 창을 열면 안 읽음 수 초기화
                return View(a);
            case "view": return View(a);
            case "open":
            {
                var it = Item();
                ReadingList.Remember(it, shown);
                model.Open(it);
                platform.CloseWindow(Name);
                return null;
            }
            case "toggleSaved": model.ToggleSaved(Item()); return null;
            case "setRead": model.SetRead(Item(), a.Bool("on")); return null;
            case "browser":
            {
                var it = Item();
                ExternalLink.Open(it.Link);
                if (a.Bool("read")) model.SetRead(it, true); // 키보드 O(H-03): 브라우저로 열고 읽음 처리
                return null;
            }
            case "copyLink": platform.CopyText(Item().Link); return null;
            // 바로 줄이기(G-11)
            case "reduceInfo": return ReduceInfo(Item());
            case "hideSource": model.HideSource(Item().SourceId); return null;
            case "lessOf":
            {
                var sec = model.NotifySection(Item());
                if (!model.ChosenSections.Contains(sec)) throw new InvalidOperationException("고른 분야가 아님");
                model.LessOf(sec);
                return null;
            }
            case "muteWord":
            {
                var w = a.Str("word").Trim();
                if (w.Length is 0 or > 40) throw new ArgumentException("낱말");
                model.MuteWord(w);
                return null;
            }
            case "snooze":
                model.Snooze(a.Str("mode") switch
                {
                    "1h" => model.Now().AddHours(1),
                    "3h" => model.Now().AddHours(3),
                    "morning" => AppModel.TomorrowMorning(model.Now()),
                    _ => null,
                });
                return null;
            case "check": await model.CheckAllAsync(manual: true); return null;
            case "magazine": platform.OpenMagazine(a.StrOrNull("page")); platform.CloseWindow(Name); return null;
            case "settings": platform.OpenSettings(); platform.CloseWindow(Name); return null;
            case "markAllRead": model.MarkAllRead(); return null;
            case "preview": platform.CloseWindow(Name); model.Preview(); return null;
            case "quit": platform.Quit(); return null;
            case "close": platform.CloseWindow(Name); return null;
            default: throw new InvalidOperationException("모르는 명령 " + cmd);
        }
    }
}
