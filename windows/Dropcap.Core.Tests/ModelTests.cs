using Dropcap.Core;

[assembly: CollectionBehavior(DisableTestParallelization = true)]

namespace Dropcap.Core.Tests;

// 화면 없는 앱 로직(맥 AppModel·Magazine·Database 의 동작)을 이 판에서 따로 확인한다

internal sealed class FakeUi : IAppUi
{
    public List<IReadOnlyList<NewsItem>> Toasts { get; } = new();
    public List<string> Infos { get; } = new();
    public List<int> Digests { get; } = new();
    public List<NewsItem> Opened { get; } = new();
    public void ShowToasts(IReadOnlyList<NewsItem> items, bool sound) => Toasts.Add(items);
    public void ShowInfo(string title, string sub) => Infos.Add(title);
    public void ShowDigest(int count) => Digests.Add(count);
    public void ShowWelcome() { }
    public void PostSystem(IReadOnlyList<NewsItem> items, bool sound) => Toasts.Add(items);
    public void OpenReader(NewsItem item) => Opened.Add(item);
    public List<(string Section, int Count)> Bundles { get; } = new();
    public void ShowBundle(string section, IReadOnlyList<NewsItem> items, bool sound) => Bundles.Add((section, items.Count));
    public void PostBundle(string section, IReadOnlyList<NewsItem> items, bool sound) => Bundles.Add((section, items.Count));
    public List<(string Word, int Count)> Watches { get; } = new();
    public void ShowWatch(string word, IReadOnlyList<NewsItem> items, bool sound) => Watches.Add((word, items.Count));
    public void PostWatch(string word, IReadOnlyList<NewsItem> items, bool sound) => Watches.Add((word, items.Count));
}

public sealed class TempDir : IDisposable
{
    public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "dropcap-test-" + Guid.NewGuid());
    public TempDir() { Directory.CreateDirectory(Path); Store.UseDir(Path); Prefs.Reset(); }
    public void Dispose()
    {
        Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools();
        try { Directory.Delete(Path, true); } catch { }
    }
}

public class AppModelTests : IDisposable
{
    private readonly TempDir tmp = new();
    private readonly Database db;
    private readonly FakeUi ui = new();
    private readonly AppModel model;
    private DateTimeOffset now = new(DateTime.Today.AddHours(10));

    public AppModelTests()
    {
        db = new Database(System.IO.Path.Combine(tmp.Path, "magazine.sqlite"));
        model = new AppModel(ui, new Magazine(db), new AppState(), persist: false) { ShowAllSourcesForTests = true, Now = () => now };
    }

    public void Dispose() { db.Dispose(); tmp.Dispose(); }

    private static NewsItem It(string id, string title, string src = "a", string tier = "press", DateTimeOffset? date = null, string? summary = null) => new()
    {
        Id = id, Title = title, Link = "https://x.com/" + id, Date = date, Summary = summary ?? "", SourceId = src, SourceName = src.ToUpperInvariant(), Tier = tier,
    };

    [Fact]
    public void KeywordsMuteAndMark()
    {
        model.State.Settings.MuteKeywords = [" crypto "];
        model.State.Settings.MustKeywords = ["클로드"];
        var o = model.ApplyKeywords([
            It("1", "Crypto AI coin"),
            new NewsItem { Id = "2", Title = "Anthropic ships Claude 5", TitleKo = "앤트로픽, 클로드 5 출시", SourceId = "a" },
            It("3", "Other"),
        ]);
        Assert.Equal(["2", "3"], o.Select(i => i.Id));
        Assert.True(o[0].Important);
        Assert.Null(o[1].Important);
    }

    [Fact]
    public void GroupsSameStoryLabFirst()
    {
        var items = new[]
        {
            It("p", "OpenAI launches GPT-6 with new reasoning features", "verge", "press", now.AddMinutes(-5)),
            It("l", "GPT-6 launches: OpenAI reveals reasoning features", "openai", "lab", now.AddMinutes(-10)),
            It("k", "Unrelated thing about chips", "kr", "kr", now),
        };
        var o = model.GroupSameStory(items);
        Assert.Equal(2, o.Count);
        var lab = o.Single(i => i.Id == "l");
        Assert.Equal(["VERGE"], lab.Related!);
    }

    [Fact]
    public void AlreadyAnnouncedStoryOnlyAddsSource()
    {
        model.State.Recent.Add(It("old", "OpenAI launches GPT-6 with new reasoning features", "openai", "lab", now.AddHours(-10)));
        var o = model.GroupSameStory([It("new", "GPT-6 launches: OpenAI reveals reasoning features", "verge", "press", now)]);
        Assert.Empty(o);
        Assert.Equal(["VERGE"], model.State.Recent[0].Related!);
        // 36시간보다 오래된 소식과는 묶지 않음
        model.State.Recent[0] = model.State.Recent[0] with { Date = now.AddHours(-40), Related = null };
        Assert.Single(model.GroupSameStory([It("new2", "GPT-6 launches: OpenAI reveals reasoning features", "wired", "press", now)]));
    }

    // 숨긴 출처·'알리지 않음' 낱말 글(지우지 않고 거르기만 함)과 같은 소식이라고 보이는 새 글을 삼키지 않는다
    [Fact]
    public void HiddenRecentDoesNotSwallowSameStory()
    {
        model.State.Recent.Add(It("old", "OpenAI launches GPT-6 with new reasoning features", "openai", "lab", now.AddHours(-10)));
        model.State.HiddenSources.Add("openai");
        var o = model.GroupSameStory([It("new", "GPT-6 launches: OpenAI reveals reasoning features", "verge", "press", now)]);
        Assert.Equal(["new"], o.Select(i => i.Id));
        Assert.Null(model.State.Recent[0].Related);
        model.State.HiddenSources.Clear();
        model.State.Settings.MuteKeywords = ["gpt-6"];
        Assert.Equal(["new2"], model.GroupSameStory([It("new2", "GPT-6 launches: OpenAI reveals reasoning features", "wired", "press", now)]).Select(i => i.Id));
    }

    [Fact]
    public void ReadLimitKeeps2000Newest()
    {
        for (var i = 0; i < 3000; i++) model.State.Read[$"x|{i}"] = i;
        model.SetRead(It("z", "t"), true);
        Assert.Equal(2000, model.State.Read.Count);
        Assert.True(model.State.Read.ContainsKey("a|z"));
        Assert.False(model.State.Read.ContainsKey("x|0"));
    }

    [Fact]
    public void PreviewIsNotARealArticle()
    {
        model.Preview();
        var card = Assert.Single(Assert.Single(ui.Toasts));
        Assert.Equal(Strings.PreviewTitleKo, card.TitleKo);
        model.Open(card);
        Assert.Empty(ui.Opened); // 눌러도 아무 기사도 안 열림(N-15)
    }

    [Fact]
    public void DigestOncePerDayAfterHour()
    {
        model.State.Recent.Add(It("1", "t", date: now.AddHours(-2)));
        now = new DateTimeOffset(DateTime.Today.AddHours(8));
        model.MinuteTick();
        Assert.Empty(ui.Digests); // 9시 전
        now = now.AddHours(1);
        model.State.Recent[0] = model.State.Recent[0] with { Date = now.AddHours(-1) };
        model.MinuteTick();
        model.MinuteTick();
        Assert.Equal([1], ui.Digests);
    }

    [Fact]
    public void SnoozeEndsByItself()
    {
        model.Snooze(now.AddHours(1));
        Assert.True(model.IsSnoozed);
        now = now.AddHours(2);
        model.MinuteTick();
        Assert.Null(model.State.SnoozeUntil);
        var t = AppModel.TomorrowMorning(new DateTimeOffset(2026, 10, 13, 23, 0, 0, TimeSpan.Zero));
        Assert.Equal(8, t.ToLocalTime().Hour);
    }

    [Fact]
    public void NotifyDefaultsFollowSource()
    {
        Assert.True(model.Notifies("openai"));
        model.State.CustomSources.Add(new Source { Id = "c", Url = "https://c.com/feed", NotifyDefault = false });
        Assert.False(model.Notifies("c"));
        model.SetNotify("c", true);
        Assert.True(model.Notifies("c"));
    }

    [Fact]
    public void InterestWeightLog()
    {
        Assert.Equal(0, model.InterestWeight(Categories.Parse("model"), "openai"));
        model.MarkOpened(It("1", "OpenAI launches GPT-6", "openai"));
        Assert.Equal(1.5, model.InterestWeight(Categories.Parse("model"), "openai"), 6);
        Assert.Equal(0, model.InterestWeight(Categories.Parse("policy"), null));
    }

    [Fact]
    public void HashIdMatchesMac()
    {
        // 맥: djb2 & 0x7fffffff → 36진수. 같은 주소는 같은 id(기기를 옮겨도 구독 id 가 같음)
        Assert.Equal(AppModel.HashId("https://a.com/feed"), AppModel.HashId("https://a.com/feed"));
        Assert.Matches("^[0-9a-z]+$", AppModel.HashId("https://www.youtube.com/feeds/videos.xml?channel_id=UC"));
        Assert.Equal("3t3a", AppModel.HashId("a")); // 5381*33+97 = 177670 → 36진수 3t3a
    }
}

public class MagazineTests : IDisposable
{
    private readonly TempDir tmp = new();
    private readonly Database db;
    private readonly Magazine mag;
    private readonly DateTimeOffset now = DateTimeOffset.Now;

    public MagazineTests()
    {
        db = new Database(System.IO.Path.Combine(tmp.Path, "magazine.sqlite"));
        mag = new Magazine(db);
    }

    public void Dispose() { db.Dispose(); tmp.Dispose(); }

    private NewsItem It(string id, string title, string src, string tier = "press", double hoursAgo = 1, string? image = null, string? kind = null) => new()
    {
        Id = id, Title = title, Link = "https://x.com/" + id, Date = now.AddHours(-hoursAgo), SourceId = src, SourceName = src, Tier = tier, Image = image, Kind = kind,
    };

    [Fact]
    public void SchemaMatchesMac()
    {
        using var c = new Microsoft.Data.Sqlite.SqliteConnection($"Data Source={db.FilePath}");
        c.Open();
        using var cmd = c.CreateCommand();
        cmd.CommandText = "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name";
        var names = new List<string>();
        using (var r = cmd.ExecuteReader()) while (r.Read()) names.Add(r.GetString(0));
        Assert.Equal(["archive", "clusters", "extract_stats", "image_scores", "issues", "items", "scraps", "teasers"], names); // 맥과 같은 표(유료 기록·사진 점수·맛보기 기사·지난 기사 보관 포함)
        cmd.CommandText = "PRAGMA user_version";
        Assert.Equal(1L, cmd.ExecuteScalar());
    }

    [Fact]
    public void IngestClustersAndBuildsIssue()
    {
        mag.Ingest([
            It("1", "OpenAI launches GPT-6 with new reasoning features", "openai", "lab", 2, "https://x.com/a.jpg"),
            It("2", "GPT-6 launches: OpenAI reveals reasoning features", "verge", "press", 1),
            It("3", "Anthropic raises $5B at $200B valuation", "tc", "press", 3),
            It("4", "Startup raises funding round for agents", "vb", "press", 4),
            It("5", "Weekend reading list", "blog", "press", 5),
            It("6", "cs.AI paper", "arxiv", "press", 1, kind: "paper"),
        ], enrich: false);
        var stories = mag.Stories();
        Assert.Single(stories);
        Assert.Equal(2, stories[0].Size);
        Assert.Equal("OpenAI launches GPT-6 with new reasoning features", stories[0].Title); // 공식 발표 제목

        var issue = mag.MakeIssue(IssueKind.Daily, now.AddDays(-1), now.AddMinutes(1), "t");
        Assert.Equal("openai|1", issue.Cover); // 사진 있는 1등
        // 분야 지면(G-10): 출처 분야를 모르는 기사(tc·vb·blog)는 낱말로도 분야가 안 정해져 '그 밖의 소식'으로
        var other = issue.Sections.Single(s => s.SectionId is null && s.Kind is null);
        Assert.Equal("그 밖의 소식", other.Label);
        Assert.Equal(["blog|5", "tc|3", "vb|4"], other.Keys.Order(StringComparer.Ordinal));
        Assert.Contains(issue.Sections, s => s.Kind == "paper");
        Assert.DoesNotContain(issue.Sections.SelectMany(s => s.Keys), k => k == "verge|2"); // 같은 스토리는 대표 하나

        var resolved = mag.Resolve(issue);
        Assert.Equal("openai|1", resolved.Cover!.Item.Key);
        Assert.All(resolved.Sections, s => Assert.NotEmpty(s.Items));
    }

    [Fact]
    public void ScoreFormula()
    {
        var s = new Database.StoredItem(It("1", "t", "a", "lab", 0, "img") with { Important = true }, now, null);
        var expected = 2.2 + 1.6 * Math.Log(2) + 2.5 + 0 + 2.0 + 0.4;
        Assert.Equal(expected, mag.Score(s, 1, s.Item.Date!.Value), 6);
    }

    [Fact]
    public void ChannelSectionsLimitFourPerSource()
    {
        mag.Ingest(Enumerable.Range(0, 7).Select(i => It("v" + i, "video " + i, "yt", hoursAgo: i + 1, kind: "video")).ToList(), enrich: false);
        var issue = mag.MakeIssue(IssueKind.Daily, now.AddDays(-1), now.AddMinutes(1), "t");
        Assert.Equal(4, issue.Sections.Single(s => s.Kind == "video").Keys.Count);
    }

    [Fact]
    public void PublishesPastIssuesOnce()
    {
        var yesterday = DateTime.Today.AddDays(-1).AddHours(12);
        mag.Ingest([new NewsItem { Id = "y", Title = "Yesterday news", Link = "https://x.com/y", Date = new DateTimeOffset(yesterday), SourceId = "s", SourceName = "s", Tier = "press" }], enrich: false);
        mag.PublishDue();
        mag.PublishDue();
        Assert.Contains(mag.Archive, i => i.Id == "daily-" + Magazine.DayId(DateTime.Today.AddDays(-1)));
        Assert.Equal(mag.Archive.Count, mag.Archive.Select(i => i.Id).Distinct().Count());
        Assert.EndsWith(" 호", mag.Archive.First(i => i.Kind == IssueKind.Daily).Title);
    }

    [Fact]
    public void SearchAndImageAndPrune()
    {
        mag.Ingest([It("1", "Quantum 50%_off model", "a"), It("2", "Other", "b")], enrich: false);
        Assert.Single(db.Search("50%_off"));
        Assert.Empty(db.Search("5%"));
        db.SetImage("a|1", "https://x.com/i.jpg");
        Assert.Equal("https://x.com/i.jpg", db.Search("Quantum")[0].Image);
        db.Prune(keep: 1);
        Assert.Equal(1, db.ItemCount);
    }

    [Fact]
    public void ScrapbookCollections()
    {
        var book = new Scrapbook(db);
        var it = It("1", "Meta", "verge");
        book.Add(it, quote: "q");
        book.Add(it, quote: "q"); // 같은 문단은 한 번만
        book.Add(it);
        Assert.Equal(2, book.Scraps.Count);
        Assert.Equal(["스크랩"], book.Collections);
        book.CreateCollection("조사");
        book.Rename("스크랩", "보고서");
        Assert.Contains("보고서", book.Collections);
        Assert.Equal("보고서", book.LastCollection);
        Assert.True(book.IsScrapped(it, "q"));
        book.Remove(book.Scraps[0]);
        Assert.Single(book.Scraps);
    }
}

public class ArticleCacheTests : IDisposable
{
    private readonly TempDir tmp = new();
    public void Dispose() => tmp.Dispose();

    private sealed class NoExtract : IArticleExtractor
    {
        public Task<Article?> FromHtmlAsync(string html, Uri baseUri) => Task.FromResult<Article?>(null);
        public Task<Article?> FromLiveAsync(Uri url) => Task.FromResult<Article?>(null);
    }

    [Fact]
    public void DiskCacheKeepsSavedAndLimit()
    {
        var saved = new List<string> { "https://x.com/0" };
        var svc = new ArticleService(new NoExtract(), () => saved);
        var dir = System.IO.Path.Combine(tmp.Path, "articles");
        for (var i = 0; i < ArticleService.DiskLimit + 10; i++)
        {
            var f = svc.FileFor("https://x.com/" + i);
            File.WriteAllText(f, Json.Encode(new PreparedArticle { Stage = Stage.Done, Title = "t" + i }));
            File.SetLastWriteTimeUtc(f, DateTime.UtcNow.AddMinutes(-1000 + i));
        }
        svc.Trim();
        Assert.Equal(ArticleService.DiskLimit, Directory.GetFiles(dir).Length);
        Assert.True(File.Exists(svc.FileFor("https://x.com/0"))); // 저장 기사는 가장 오래돼도 남음
        Assert.False(File.Exists(svc.FileFor("https://x.com/1")));
        Assert.Equal("t50", svc.Cached("https://x.com/50")?.Title);
    }

    [Fact]
    public async Task UnsafeLinkFailsWithoutRequest()
    {
        var svc = new ArticleService(new NoExtract(), () => []);
        var it = new NewsItem { Id = "1", Title = "T", Link = "http://192.168.0.1/a", Summary = "", SourceId = "s" };
        var r = await svc.PrepareAsync(it, interactive: false);
        Assert.Equal(Stage.Failed, r.Stage);
        Assert.Null(svc.Cached(it.Link)); // 실패는 기억하지 않음(R-15)
    }

    [Fact]
    public void PreparedArticleJsonMatchesMac()
    {
        var a = new PreparedArticle { Stage = Stage.Done, Title = "t", Blocks = [new Block { Type = BlockKind.Quote, Text = "x" }] };
        var json = Json.Encode(a);
        Assert.Contains("\"stage\":3", json);
        Assert.Contains("\"type\":\"quote\"", json);
        var back = Json.Decode<PreparedArticle>("""{"stage":3,"title":"t","originalTitle":"o","blocks":[{"type":"li","text":"a"}],"translated":true,"engine":"Google 번역","summarizing":false,"fallback":""}""");
        Assert.Equal(BlockKind.Li, back!.Blocks[0].Type);
    }

    [Fact]
    public void SummaryLines() =>
        Assert.Equal(["첫째", "둘째", "셋째"], Summarizer.ParseLines("요약:\n- 첫째\n• 둘째\n-셋째\n- 넷째")!);
}
