using System.Text.RegularExpressions;
using Dropcap.Core;

namespace Dropcap.Core.Tests;

// 맥 mac/Tests/DropcapTests/PivotTests.swift·FeedsTests.swift 를 옮긴 것(Q-01).
// 일반 뉴스 전환: 분야 체계·분야 정하기·분야별 알림 정책. 견본 자료는 맥과 같은 계약 형식(Fixtures/).

internal static class PivotFixtures
{
    public static string Dir => Path.Combine(AppContext.BaseDirectory, "Fixtures");
    public static Dictionary<string, SourceMeta> Meta => Sections.LoadMeta(Path.Combine(Dir, "sources-sample.json"));
    public static readonly Regex Ai = new(@"\b(AI|LLM|GPT)\b|인공지능|생성형", RegexOptions.IgnoreCase);

    public static NewsItem Item(string title, string source, string tier = "kr", string summary = "") => new()
    {
        Id = title, Title = title, Link = "https://a.com/" + Math.Abs(title.GetHashCode()), Date = DateTimeOffset.Now, Summary = summary,
        SourceId = source, SourceName = source, Tier = tier,
    };
}

public class SectionCatalogTests
{
    [Fact]
    public void LoadsContractFile()
    {
        var s = Sections.Load(Path.Combine(PivotFixtures.Dir, "categories.json"))!;
        Assert.Equal(Sections.Builtin.Select(x => x.Id), s.Select(x => x.Id));   // 기본값과 계약 파일이 같은 id·순서
        Assert.True(s.First(x => x.Id == "top").IsFlow);
        Assert.True(s.First(x => x.Id == "climate").IsMore);
        Assert.Null(Sections.Load(Path.Combine(PivotFixtures.Dir, "없음.json")));
    }

    [Fact]
    public void ContractSourcesStillDecodeAsSourceConfig() // 새 필드가 붙어도 기존 Source 해석이 깨지지 않는다
    {
        var c = System.Text.Json.JsonSerializer.Deserialize<SourceConfig>(File.ReadAllText(Path.Combine(PivotFixtures.Dir, "sources-sample.json")), Json.Options)!;
        Assert.Equal(10, c.Sources.Count);
    }

    [Fact]
    public void SourceSectionAndRegion()
    {
        var m = PivotFixtures.Meta;
        Assert.Equal("economy", Sections.SectionOfSource("yna-market", m));
        Assert.Equal("ai", Sections.SectionOfSource("cat-yt-openai", m));   // 추천 채널은 AI 시절 것
        Assert.Null(Sections.SectionOfSource("custom-x1", m));               // 주소로 직접 추가한 출처는 모름
        Assert.Equal("intl", Sections.RegionOf("cnbc", "press", m));
        Assert.Equal("kr", Sections.RegionOf("custom-x1", "kr", m));
    }
}

public class PlacementTests
{
    private static Sections.Placement P(string title, string source) => Sections.Place(PivotFixtures.Item(title, source), PivotFixtures.Meta, PivotFixtures.Ai);

    [Fact]
    public void SourceSectionComesFirst()
    {
        var p = P("국회 예산안 처리", "yna-market");
        Assert.Equal("economy", p.Primary);    // 출처의 분야가 1순위(낱말은 정치여도)
        Assert.Contains("politics", p.Chips);  // 낱말 분야는 칩으로
    }

    [Fact]
    public void GeneralFeedUsesKeywords()
    {
        Assert.Equal("economy", P("코스피 2,900 회복…외국인 순매수", "yna-latest").Primary);
        Assert.Equal("sports", P("프로야구 한국시리즈 7차전", "yna-latest").Primary);
        Assert.Equal("life", P("오늘의 날씨 이야기", "yna-latest").Primary);
        Assert.Equal("top", P("짧은 소식", "yna-latest").Primary);   // 짐작 못 하면 주요
    }

    [Fact]
    public void AiIsPulledFromOtherSections()
    {
        var p = P("은행권, 생성형 AI 상담 도입", "yna-market");
        Assert.True(p.Primary == "economy" && p.Chips.Contains("ai"));   // 대표는 경제, AI 칩도
    }

    [Fact]
    public void EnglishKeywordsUseWordBoundaries()
    {
        Assert.Null(Sections.Classify("The marketing team"));   // 'market' 이 'marketing' 에 걸리지 않게
        Assert.Equal("economy", Sections.Classify("Fed holds interest rate"));
    }
}

public class NotifyPolicyTests
{
    private static readonly PolicyLimits L = new();

    private static NotifyPolicy.Input In(NotifyMode mode, int kr = 1, int intl = 0, bool lab = false, bool star = false, bool followed = false,
        int sec = 0, int total = 0, bool chosen = true, int cap = 3) => new()
    {
        Chosen = chosen, Policy = new SectionPolicy { Mode = mode, DailyCap = cap }, Coverage = new Coverage(kr, intl),
        Lab = lab, Important = star, Followed = followed, SentInSection = sec, SentTotal = total,
    };

    // 결정 표: 분야 모드 × 문턱 × 상한 → 알림/고임/매거진만
    [Theory]
    [InlineData("고르지 않은 분야", NotifyMode.Instant, 9, 0, false, false, false, 0, 0, false, NotifyDecision.Quiet)]
    [InlineData("매거진만", NotifyMode.Magazine, 9, 9, true, true, true, 0, 0, true, NotifyDecision.Quiet)]
    [InlineData("묶음은 늘 고임", NotifyMode.Bundle, 9, 0, true, false, false, 0, 0, true, NotifyDecision.Pool)]
    [InlineData("즉시·한 곳뿐", NotifyMode.Instant, 1, 0, false, false, false, 0, 0, true, NotifyDecision.Quiet)]
    [InlineData("즉시·국내 2곳은 문턱 아래", NotifyMode.Instant, 2, 0, false, false, false, 0, 0, true, NotifyDecision.Quiet)]
    [InlineData("즉시·국내 3곳", NotifyMode.Instant, 3, 0, false, false, false, 0, 0, true, NotifyDecision.Drop)]
    [InlineData("즉시·해외 2곳", NotifyMode.Instant, 0, 2, false, false, false, 0, 0, true, NotifyDecision.Drop)]
    [InlineData("즉시·국내1+해외1 은 문턱 아래", NotifyMode.Instant, 1, 1, false, false, false, 0, 0, true, NotifyDecision.Quiet)]
    [InlineData("즉시·공식 발표", NotifyMode.Instant, 0, 1, true, false, false, 0, 0, true, NotifyDecision.Drop)]
    [InlineData("즉시·꼭 알림 낱말", NotifyMode.Instant, 1, 0, false, true, false, 0, 0, true, NotifyDecision.Drop)]
    [InlineData("즉시·팔로우한 스토리", NotifyMode.Instant, 1, 0, false, false, true, 0, 0, true, NotifyDecision.Drop)]
    [InlineData("분야 상한에 닿으면 고임", NotifyMode.Instant, 3, 0, false, false, false, 3, 3, true, NotifyDecision.Pool)]
    [InlineData("전체 상한에 닿으면 고임", NotifyMode.Instant, 3, 0, false, false, false, 0, 10, true, NotifyDecision.Pool)]
    [InlineData("상한이어도 국내 8곳이면 알림", NotifyMode.Instant, 8, 0, false, false, false, 3, 10, true, NotifyDecision.Drop)]
    [InlineData("상한·공식 발표는 고임", NotifyMode.Instant, 1, 0, true, false, false, 3, 3, true, NotifyDecision.Pool)]
    public void Table(string name, NotifyMode mode, int kr, int intl, bool lab, bool star, bool followed, int sec, int total, bool chosen, NotifyDecision want) =>
        Assert.True(want == NotifyPolicy.Decide(In(mode, kr, intl, lab, star, followed, sec, total, chosen), L), name);

    [Fact]
    public void TopFlowCatchesBigStoriesFromQuietSections()
    {
        // 스포츠는 매거진만이지만 국내 4곳이 다룬 큰 소식 → 주요 뉴스(즉시)로 알림
        var own = In(NotifyMode.Magazine, kr: 4);
        var top = In(NotifyMode.Instant, kr: 0);
        var (d, viaTop) = NotifyPolicy.DecideWithTop(own, top, L);
        Assert.True(d == NotifyDecision.Drop && viaTop);
        Assert.Equal(NotifyDecision.Quiet, NotifyPolicy.DecideWithTop(In(NotifyMode.Magazine, kr: 1), top, L).Decision);   // 문턱 아래
        Assert.Equal(NotifyDecision.Quiet, NotifyPolicy.DecideWithTop(own, null, L).Decision);                                // 주요 뉴스를 안 골랐으면
        // 주요 뉴스도 상한에 닿았으면 자기 분야 결정(묶음이면 고임)
        Assert.Equal(NotifyDecision.Pool, NotifyPolicy.DecideWithTop(In(NotifyMode.Bundle, kr: 4), In(NotifyMode.Instant, sec: 3, total: 3), L).Decision);
    }

    [Fact]
    public void CustomThresholds() =>
        Assert.Equal(NotifyDecision.Drop, NotifyPolicy.Decide(In(NotifyMode.Instant, kr: 2), new PolicyLimits { KrThreshold = 2 }));

    [Fact]
    public void FirstRunDefaultsTwoInstant()
    {
        var d = NotifyPolicy.Defaults(["top", "politics", "economy", "sports", "ai"]);
        Assert.Equal(NotifyMode.Instant, d["top"].Mode);
        Assert.True(d["politics"].Mode == NotifyMode.Instant && d["economy"].Mode == NotifyMode.Instant);
        Assert.True(d["sports"].Mode == NotifyMode.Bundle && d["ai"].Mode == NotifyMode.Bundle);
    }

    [Fact]
    public void BundleTiming()
    {
        var day = new DateTimeOffset(DateTime.Today);
        DateTimeOffset At(int h) => day.AddHours(h).AddMinutes(1);
        Assert.False(NotifyPolicy.BundleDue(18, At(17), null));
        Assert.True(NotifyPolicy.BundleDue(18, At(18), null));
        Assert.False(NotifyPolicy.BundleDue(18, At(20), At(18)));               // 오늘 이미 보냄
        Assert.True(NotifyPolicy.BundleDue(18, At(20), At(9)));                 // 오늘 보낸 건 그 시각 전(다른 시각 설정)
        Assert.True(NotifyPolicy.BundleDue(18, At(19), At(18).AddDays(-1)));    // 어제 보냄
    }

    [Fact]
    public void OldPolicyFileStillReads()
    {
        var p = SectionPolicy.FromJson(System.Text.Json.Nodes.JsonNode.Parse("""{"mode":"instant"}"""));
        Assert.True(p.Mode == NotifyMode.Instant && p.BundleHour == 18 && p.DailyCap == 3);
        Assert.Equal(NotifyMode.Bundle, SectionPolicy.FromJson(System.Text.Json.Nodes.JsonNode.Parse("""{"mode":"weird"}""")).Mode);
    }
}

public class SectionMigrationTests
{
    private static List<Source> Sources() =>
        System.Text.Json.JsonSerializer.Deserialize<SourceConfig>(File.ReadAllText(Path.Combine(PivotFixtures.Dir, "sources-sample.json")), Json.Options)!.Sources;

    [Fact]
    public void ExistingUserBecomesAiOnly()
    {
        var s = new AppState();
        s.Enabled["openai"] = true;
        var p = Store.Prepare(s, existing: true, Sources(), PivotFixtures.Meta);
        Assert.Equal(["ai"], p.SectionsChosen!);
        Assert.Equal(NotifyMode.Instant, p.SectionPolicy["ai"].Mode);   // 예전처럼 AI 는 즉시
        Assert.True(p.Enabled["aitimes"]);                               // AI 분야 기본 출처는 켜짐
        Assert.False(p.Enabled["yna-market"]);                           // 새 국내 언론이 한꺼번에 켜지지 않음
    }

    [Fact]
    public void NewUserWaitsForOnboarding()
    {
        var p = Store.Prepare(new AppState(), existing: false, Sources(), PivotFixtures.Meta);
        Assert.Null(p.SectionsChosen);
        Assert.False(p.Enabled["yna-market"] || p.Enabled["openai"]);
    }

    [Fact]
    public void OldStateFileWithoutSectionFieldsDecodes()
    {
        var s = AppState.FromJson("""{"unread":2,"settings":{"sound":false}}""");
        Assert.True(s.SectionsChosen is null && s.Pending.Count == 0 && s.Settings.TotalDailyCap == 10);
    }

    [Fact]
    public void SectionStateRoundTrips()
    {
        var s = new AppState { SectionsChosen = ["top", "economy"] };
        s.SectionPolicy["economy"] = new SectionPolicy { Mode = NotifyMode.Instant, BundleHour = 7, DailyCap = 5 };
        s.Pending.Add(new AppState.PendingItem(PivotFixtures.Item("t", "yna-market"), "economy", "c1", DateTimeOffset.Now));
        s.LastBundle["economy"] = new DateTimeOffset(2026, 10, 13, 18, 0, 0, TimeSpan.Zero);
        var back = AppState.FromJson(s.ToJson());
        Assert.Equal(["top", "economy"], back.SectionsChosen!);
        Assert.Equal(new SectionPolicy { Mode = NotifyMode.Instant, BundleHour = 7, DailyCap = 5 }, back.SectionPolicy["economy"]);
        Assert.Equal("c1", back.Pending.Single().Story);
        Assert.Contains("\"mode\":\"instant\"", s.ToJson());
    }
}

public class SectionPageTests
{
    private static Database.StoredItem Stored(string title, string source, string? cluster = null, string tier = "kr") =>
        new(PivotFixtures.Item(title, source, tier), DateTimeOffset.Now, cluster);

    [Fact]
    public void TopThenChosenThenOthers()
    {
        var big = new[] { Stored("금리 동결", "yna-market", "c1"), Stored("금리 동결 2", "hk-finance", "c1"), Stored("금리 동결 3", "yna-politics", "c1") };
        var articles = new[] { big[0], Stored("코스닥 상승", "hk-finance"), Stored("환율 하락", "yna-market"), Stored("여야 합의", "yna-politics"), Stored("야구 결승", "yna-sports") };
        var pages = Magazine.SectionPages(articles, articles.Concat(big).ToList(), ["top", "politics", "economy"], new PolicyLimits(), 12, PivotFixtures.Meta);
        Assert.True(pages[0].SectionId == "top" && pages[0].Keys.SequenceEqual([big[0].Item.Key]));   // 국내 3곳 → 주요
        Assert.Equal(["top", "politics", "economy"], pages.Select(p => p.SectionId).OfType<string>());
        Assert.True(pages[^1].SectionId is null && pages[^1].Keys.Count == 1);   // 고르지 않은 스포츠 한 건은 '그 밖의 소식'
    }

    [Fact]
    public void RegionSplit()
    {
        var items = new[] { PivotFixtures.Item("a", "cnbc", "press"), PivotFixtures.Item("b", "yna-market"), PivotFixtures.Item("c", "bbc-world", "press") };
        var (intl, kr) = Magazine.SplitByRegion(items, PivotFixtures.Meta);
        Assert.True(intl.Count == 2 && kr.Count == 1);
    }
}

public class ReduceTests
{
    [Fact]
    public void TitleWordsSkipNoise()
    {
        var w = AppModel.TitleWords(new NewsItem { Id = "1", Title = "The new GPT-6 model from OpenAI", TitleKo = "오픈AI 새 GPT-6 모델 공개", SourceId = "s", SourceName = "S", Tier = "press" });
        Assert.True(w.Contains("GPT-6") && w.Contains("OpenAI") && w.Contains("오픈AI"));
        Assert.False(w.Contains("The") || w.Contains("new"));
    }
}

// MARK: 피드 날짜(맥 FeedsTests)
public class FeedDateTests
{
    private static DateTimeOffset Utc(string s) => DateTimeOffset.Parse(s, System.Globalization.CultureInfo.InvariantCulture);

    [Fact] public void ColonOffsetInRfc822() => Assert.Equal(Utc("2026-10-13T07:29:45Z"), Dates.Parse("Tue, 13 Oct 2026 16:29:45 +09:00"));
    [Fact] public void NumericMonth() => Assert.Equal(Utc("2026-10-13T07:00:47Z"), Dates.Parse("Tue, 13 10 2026 16:00:47 +0900"));

    [Fact]
    public void ZoneNames()
    {
        Assert.Equal(Utc("2026-10-12T10:55:00Z"), Dates.Parse("Mon, 12 Oct 2026 06:55:00 EDT"));
        Assert.Equal(Utc("2026-10-13T07:35:35Z"), Dates.Parse("Tue, 13 Oct 2026 02:35:35 EST"));
        Assert.Equal(Utc("2026-10-09T07:00:00Z"), Dates.Parse("Fri, 09 Oct 2026 07:00:00 GMT"));
        Assert.Equal(Utc("2026-10-13T07:00:00Z"), Dates.Parse("Tue, 13 Oct 2026 16:00:00 KST"));
    }

    [Fact] public void WrongWeekdayStillParses() => Assert.Equal(Utc("2026-10-13T07:00:00Z"), Dates.Parse("Mon, 13 Oct 2026 16:00:00 +0900"));

    [Fact]
    public void StandardFormatsUnchanged()
    {
        Assert.Equal(Utc("2026-09-30T20:01:45Z"), Dates.Parse("Wed, 30 Sep 2026 20:01:45 +0000"));
        Assert.Equal(Utc("2026-10-12T22:17:43Z"), Dates.Parse("Mon, 12 Oct 2026 18:17:43 -0400"));
        Assert.Equal(Utc("2026-10-13T07:41:00Z"), Dates.Parse("2026-10-13T16:41:00+09:00"));
        Assert.Equal(Utc("2026-10-13T07:37:22Z"), Dates.Parse("2026-10-13T07:37:22Z"));
        Assert.Equal(Utc("2026-10-12T11:13:10.123Z"), Dates.Parse("2026-10-12T07:13:10.123-04:00"));
    }

    [Fact]
    public void ZonelessIsSeoulTime()
    {
        Assert.Equal(Utc("2026-10-13T07:15:42Z"), Dates.Parse("2026-10-13 16:15:42"));
        Assert.Equal(Utc("2026-10-13T07:15:00Z"), Dates.Parse("2026.10.13 16:15"));
        Assert.Equal(Utc("2026-10-11T15:00:00Z"), Dates.Parse("2026-10-12"));
        Assert.Equal(Utc("2026-10-13T07:15:42Z"), Dates.Parse("2026-10-13T16:15:42+0900"));
    }

    [Fact]
    public void KoreanWords()
    {
        Assert.Equal(Utc("2024-10-29T14:30:00Z"), Dates.Parse("2024년 10월 29일 화요일 오후 11:30:00"));
        Assert.Equal(Utc("2024-10-28T15:05:00Z"), Dates.Parse("2024년 10월 29일 오전 12:05"));
    }

    [Fact]
    public void GarbageIsNull()
    {
        Assert.Null(Dates.Parse(""));
        Assert.Null(Dates.Parse("어제"));
        Assert.Null(Dates.Parse("not a date"));
    }
}

public class FeedRepairTests
{
    private const string Hani = """
        <?xml version="1.0" encoding="UTF-8"?><rss xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0"><channel>
        <title><![CDATA[전체기사 : 뉴스 : 한겨레]]></title><lastBuildDate>Tue, 13 Oct 2026 07:04:00 GMT</lastBuildDate>
        <item><title><![CDATA[첫 기사]]></title><link>https://www.hani.co.kr/arti/society/1.html</link><guid isPermaLink="false">1</guid><dc:category>사회</dc:category></item>
        <item><title><![CDATA[둘째 기사]]></title><link>https://www.hani.co.kr/arti/society/2.html</link><guid isPermaLink="false">2</guid></item>
        </channel></rss>
        """;

    [Fact]
    public void UndatedGetFirstSeenAndKeepIt()
    {
        var entries = FeedParser.ParseFeed(System.Text.Encoding.UTF8.GetBytes(Hani));
        Assert.All(entries, e => Assert.Null(e.Date));
        var memory = new Dictionary<string, DateTimeOffset>();
        var t0 = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
        FeedDates.Repair(entries, "hani-society", t0, memory);
        Assert.All(entries, e => Assert.Equal(t0, e.Date));
        // 다음 확인: 같은 글은 처음 본 시각 그대로, 새 글만 새 시각
        var again = FeedParser.ParseFeed(System.Text.Encoding.UTF8.GetBytes(Hani));
        again.Insert(0, new FeedParser.Entry("3", "셋째", "https://www.hani.co.kr/arti/3.html", null, ""));
        var t1 = t0.AddSeconds(300);
        FeedDates.Repair(again, "hani-society", t1, memory);
        Assert.Equal(t1, again[0].Date);
        Assert.Equal(t0, again[1].Date);
    }

    [Fact]
    public void FutureIsClampedToFetchTime()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
        var e = new List<FeedParser.Entry>
        {
            new("a", "", "", now.AddHours(1), ""),       // ESPN: EDT 를 EST 로
            new("b", "", "", now.AddMinutes(5), ""),     // 10분 안은 둔다
            new("c", "", "", now.AddHours(-1), ""),
        };
        var memory = new Dictionary<string, DateTimeOffset>();
        FeedDates.Repair(e, "espn", now, memory);
        Assert.Equal(now, e[0].Date);
        Assert.Equal(now.AddMinutes(5), e[1].Date);
        Assert.Equal(now.AddHours(-1), e[2].Date);
        Assert.Empty(memory);
    }

    [Fact]
    public void NocutFeedParses()
    {
        var xml = """
            <?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel><title>노컷뉴스</title>
            <item><title>기사</title><link>https://www.nocutnews.co.kr/news/1</link><pubDate>Tue, 13 10 2026 15:48:32 +0900</pubDate></item>
            </channel></rss>
            """;
        Assert.Equal(DateTimeOffset.Parse("2026-10-13T06:48:32Z"), FeedParser.ParseFeed(System.Text.Encoding.UTF8.GetBytes(xml))[0].Date);
    }

    [Fact]
    public void MemoryIsBounded()
    {
        var memory = new Dictionary<string, DateTimeOffset>();
        for (var i = 0; i <= FeedDates.MemoryLimit; i++) memory[$"s|{i}"] = DateTimeOffset.FromUnixTimeSeconds(i);
        FeedDates.Repair(new List<FeedParser.Entry>(), "s", DateTimeOffset.Now, memory);
        Assert.Equal(FeedDates.MemoryLimit / 2, memory.Count);
        Assert.True(memory.ContainsKey($"s|{FeedDates.MemoryLimit}"));   // 최근 것은 남김
    }
}

// MARK: shared/ 자료 계약(맥 SourceDataTests)
public class SourceDataTests
{
    [Fact]
    public void CategoriesContract()
    {
        var s = Sections.Load(Resources.PathOf("categories.json"))!;
        Assert.Equal(["top", "politics", "economy", "society", "world", "tech", "ai", "science", "life", "culture", "sports", "climate"], s.Select(x => x.Id));
        Assert.True(s.First(x => x.Id == "top").IsFlow);
        Assert.True(s.First(x => x.Id == "climate").IsMore);
        Assert.All(s, x => Assert.NotEqual("cat.other", x.Icon));   // 모든 기호에 이 판의 아이콘이 있음
    }

    [Fact]
    public void EverySourceHasValidFields()
    {
        var ids = Sections.All.Select(x => x.Id).ToHashSet();
        var all = Resources.Config.Sources;
        Assert.Equal(all.Count, all.Select(x => x.Id).Distinct().Count());
        Assert.Equal(all.Count, all.Select(x => x.Url).Distinct().Count());
        foreach (var s in all)
        {
            Assert.True(s.Section is not null && ids.Contains(s.SectionId), $"{s.Id} 분야");
            Assert.True(s.Lang is not null, $"{s.Id} 언어");
            Assert.True(s.Region is "kr" or "intl", $"{s.Id} 지역");
            Assert.True(UrlSafety.IsPublicHttp(s.Url), $"{s.Id} 주소");
            Assert.True(s.Tier != "kr" || s.Region == "kr", $"{s.Id} 국내 등급");
        }
    }

    [Fact]
    public void EverySectionHasDefaultSources()
    {
        foreach (var sec in Sections.All)
        {
            var on = Resources.Config.Sources.Where(s => s.SectionId == sec.Id && s.DefaultOn).ToList();
            Assert.True(on.Count > 0, $"{sec.Id} 에 기본 출처가 없음");
            if (sec.Id is not ("society" or "climate"))   // 사회는 국내만, 기후는 국내 피드를 못 찾음
                Assert.True(on.Any(s => s.IsDomestic) && on.Any(s => !s.IsDomestic), $"{sec.Id} 국내·해외 기본 출처");
        }
    }

    [Fact]
    public void OldAiSourcesKeepIdsAndSection()
    {
        foreach (var id in new[] { "openai", "anthropic", "deepmind", "google-ai", "nvidia", "mit-tr", "ars", "verge", "aitimes", "etnews" })
            Assert.True(Resources.Config.Sources.FirstOrDefault(s => s.Id == id)?.SectionId == "ai", id);
    }

    [Fact]
    public void DefaultsWhenFieldsMissing() // 예전 직접 추가 출처(새 필드 없음)
    {
        var old = """{"id":"custom-x","name":"X","tier":"press","type":"feed","url":"https://x.example/feed","aiOnly":false,"defaultOn":true,"color":"#000"}""";
        var s = System.Text.Json.JsonSerializer.Deserialize<Source>(old, Json.Options)!;
        Assert.True(s.SectionId == "ai" && s.Language == "en" && s.RegionCode == "intl");
        var kr = System.Text.Json.JsonSerializer.Deserialize<Source>(old.Replace("\"press\"", "\"kr\""), Json.Options)!;
        Assert.Equal("kr", kr.RegionCode);
    }
}
