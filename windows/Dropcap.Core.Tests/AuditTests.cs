using Dropcap.Core;
using Dropcap.Ui;

namespace Dropcap.Core.Tests;

// 맥 mac/Tests/DropcapTests/AuditTests.swift 와 CoreTests.swift 에 새로 더해진 사례를 옮긴 것(Q-01).
// 모두 바깥 서버·실제 사용자 기록 없이 돈다.

public class EntityDecodeTests
{
    [Fact]
    public void DecodesCommonAndNumericEntities() =>
        Assert.Equal("Sam’s “agent” ’ ’ … —", Plain.Clean("Sam&rsquo;s &ldquo;agent&rdquo; &#x2019; &#8217; &hellip; &mdash;"));

    [Fact]
    public void DecodesOnlyOnce() // &amp;lt; 는 '&lt;' 글자 그대로여야 한다
    {
        Assert.Equal("a &lt;b&gt; c", Plain.Clean("a &amp;lt;b&amp;gt; c"));
        Assert.Equal("AT&T", Plain.Clean("AT&amp;T"));
    }

    [Fact]
    public void LeavesUnknownAndBareAmpersands() =>
        Assert.Equal("R&D &unknownthing; &#0; x & y", Plain.Clean("R&D &unknownthing; &#0; x & y"));
}

public class TranslatorCacheTests
{
    [Fact]
    public void CacheStaysUnderLimit() // 기사 본문 번역(TranslateMany)도 상한을 지켜야 한다
    {
        var t = new Translator();
        for (var i = 0; i <= Translator.CacheLimit + 10; i++) t.Remember($"text {i}", $"번역 {i}");
        Assert.True(t.CacheCount <= Translator.CacheLimit);
        Assert.True(t.CacheCount > 0);
    }
}

public class SiteLocalIPv6Tests
{
    [Fact]
    public void BlocksSiteLocal()
    {
        Assert.False(UrlSafety.IsPublicHttp("http://[fec0::1]/"));
        Assert.False(UrlSafety.IsPublicHttp("http://[feff::1]/"));
        Assert.True(UrlSafety.IsPublicHttp("https://[2606:4700::1111]/"));
    }
}

public class StateRecoveryTests : IDisposable
{
    private readonly string d = Path.Combine(Path.GetTempPath(), "dropcap-audit-" + Guid.NewGuid());
    public StateRecoveryTests() => Directory.CreateDirectory(d);
    public void Dispose() { try { Directory.Delete(d, true); } catch { } }

    [Fact]
    public void CorruptFileFallsBackToBackup()
    {
        var main = Path.Combine(d, "native-state.json");
        var bak = Path.Combine(d, "native-state.bak.json");
        File.WriteAllText(main, "{\"seen\": {\"a|1\": 1");   // 중간에 잘린 파일
        File.WriteAllText(bak, """{"seen":{"a|1":1},"unread":3,"seeded":["a"]}""");
        var (s, fromBackup) = Store.Read(main, bak);
        Assert.True(fromBackup);
        Assert.Equal(3, s.Unread);
        Assert.Equal(["a"], s.Seeded);
        Assert.True(File.Exists(Path.Combine(d, "native-state.broken.json")));
    }

    [Fact]
    public void CorruptWithoutBackupStartsFresh()
    {
        var main = Path.Combine(d, "native-state.json");
        File.WriteAllText(main, "not json");
        var (s, fromBackup) = Store.Read(main, Path.Combine(d, "native-state.bak.json"));
        Assert.True(fromBackup);   // .bak 을 덮어쓰지 않게 표시
        Assert.Empty(s.Seen);
    }

    [Fact]
    public void HealthyFileReadsNormally()
    {
        var main = Path.Combine(d, "native-state.json");
        File.WriteAllText(main, """{"unread":5}""");
        var (s, fromBackup) = Store.Read(main, Path.Combine(d, "x.json"));
        Assert.False(fromBackup);
        Assert.Equal(5, s.Unread);
        var (_, missing) = Store.Read(Path.Combine(d, "none.json"), Path.Combine(d, "x.json"));
        Assert.False(missing);   // 처음 실행은 복구가 아니다
    }

    [Fact]
    public void SeenIsPrunedOldestFirst()
    {
        var seen = Enumerable.Range(0, 10).ToDictionary(i => $"k{i}", i => (double)i);
        var p = Store.Pruned(seen, 6);
        Assert.Equal(6, p.Count);
        Assert.False(p.ContainsKey("k0") || p.ContainsKey("k3"));
        Assert.True(p.ContainsKey("k4") && p.ContainsKey("k9"));
        Assert.Equal(10, Store.Pruned(seen, 20).Count);
    }
}

public class DatabaseRecoveryTests : IDisposable
{
    private readonly string d = Path.Combine(Path.GetTempPath(), "dropcap-db-" + Guid.NewGuid());
    public DatabaseRecoveryTests() => Directory.CreateDirectory(d);
    public void Dispose() { Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools(); try { Directory.Delete(d, true); } catch { } }

    private static NewsItem It() => new() { Id = "1", Title = "OpenAI ships a model", Link = "https://openai.com/a", Date = DateTimeOffset.Now, SourceId = "openai", SourceName = "OpenAI", Tier = "lab" };

    [Fact]
    public void GarbageFileIsMovedAsideAndRecreated()
    {
        var f = Path.Combine(d, "magazine.sqlite");
        File.WriteAllBytes(f, Enumerable.Repeat((byte)0x41, 4096).ToArray());   // SQLite 파일이 아님
        using var db = new Database(f);
        db.Upsert(It(), null);
        Assert.Equal(1, db.ItemCount);   // 예전에는 모든 쓰기가 조용히 실패했다
        Assert.True(File.Exists(Path.Combine(d, "magazine.broken.sqlite")));
    }

    [Fact]
    public void HealthyFileIsKept()
    {
        var f = Path.Combine(d, "magazine.sqlite");
        using (var db = new Database(f)) db.Upsert(It(), null);
        using (var db2 = new Database(f)) Assert.Equal(1, db2.ItemCount);
        Assert.False(File.Exists(Path.Combine(d, "magazine.broken.sqlite")));
    }
}

public class EnrichPickTests
{
    private static Database.StoredItem Stored(string id, string? image = null) =>
        new(new NewsItem { Id = id, Title = id, Link = $"https://a.com/{id}", Date = DateTimeOffset.Now, SourceId = "s", SourceName = "S", Tier = "press", Image = image }, DateTimeOffset.Now, null);

    [Fact]
    public void SkipsAlreadyTried() // 사진을 못 찾은 최신 12건만 계속 다시 받던 문제
    {
        var items = Enumerable.Range(0, 20).Select(i => Stored($"{i}")).Append(Stored("img", "https://a.com/x.jpg")).ToList();
        var first = Magazine.ToEnrich(items, new HashSet<string>());
        Assert.Equal(12, first.Count);
        Assert.Equal("0", first[0].Item.Id);
        var next = Magazine.ToEnrich(items, first.Select(s => s.Item.Key).ToHashSet());
        Assert.Equal(Enumerable.Range(12, 8).Select(i => $"{i}"), next.Select(s => s.Item.Id));
    }
}

public class TranslatedPageTests
{
    [Fact]
    public void KeepsEncodedPath() => // 공백·한글이 든 주소도 '번역된 웹페이지로 보기'가 사라지지 않게
        Assert.Equal("https://www-ai--news-co-kr.translate.goog/news/AI%20%ED%95%9C%EA%B8%80?id=3&_x_tr_sl=auto&_x_tr_tl=ko&_x_tr_hl=ko",
            ReaderPage.TranslatedPageUrl("https://www.ai-news.co.kr/news/AI%20%ED%95%9C%EA%B8%80?id=3"));
}

public class EntityRuleTests
{
    private static NewsItem Item(string title, string? en = null) => new()
    {
        Id = title, Title = title, Link = "https://x.com/" + FeedParser.Prefix(title, 8), SourceId = Guid.NewGuid().ToString(), SourceName = "S", Tier = "press", TitleEn = en,
    };

    [Fact]
    public void EntitiesSkipTitleCaseWords()
    {
        var e = StoryMatch.Entities("OCP Global Summit: Amid Ecosystem Adoption, NVIDIA Opens Vera Rubin Architecture");
        Assert.True(e.Contains("nvidia") && e.Contains("ocp") && !e.Contains("global") && !e.Contains("summit"));
        Assert.Superset(new HashSet<string> { "openai", "gpt-6", "iphone" }, StoryMatch.Entities("OpenAI launches GPT-6 for iPhone").ToHashSet());
    }

    [Fact]
    public void TitleCaseCommonWordDoesNotMerge() => // Title Case 의 흔한 말('Global')을 고유명사로 오인해 묶이던 사례
        Assert.False(StoryMatch.Same(Item("OCP Global Summit: Amid Ecosystem Adoption, NVIDIA Opens Vera Rubin Architecture to Help Scale AI Factories Worldwide"),
            Item("AI 업무 플랫폼 '팔레트 에이전트' 글로벌 출시", "Global launch of AI business platform ‘Palette Agent’… “Integrated support from planning to app production”")));
}

public class ImageKeyTests
{
    [Fact]
    public void JunkImages()
    {
        Assert.True(ImageKey.IsJunk("https://cdn.aitimes.com/image/newsroom/default-user.png"));
        Assert.True(ImageKey.IsJunk("https://x.com/assets/logo.svg"));
        Assert.True(ImageKey.IsJunk("https://secure.gravatar.com/avatar/abc?s=96"));
        Assert.False(ImageKey.IsJunk("https://cdn.aitimes.com/news/photo/202610/216198_220220_302.jpg"));
        Assert.False(ImageKey.IsJunk("https://x.com/wp-content/uploads/2026/10/catalog-hero.jpg"));
    }

    [Fact]
    public void SameImageDifferentSizes()
    {
        Assert.True(ImageKey.Same("https://cdn.aitimes.com/news/photo/202610/216199_220221_5549.jpg", "https://cdn.aitimes.com/news/thumbnail/202610/216199_220221_5549_v150.jpg"));
        Assert.True(ImageKey.Same("https://x.com/wp-content/uploads/2026/10/gpt6-hero-1024x576.png", "https://x.com/wp-content/uploads/2026/10/gpt6-hero.png?w=1200"));
        Assert.True(ImageKey.Same("https://x.com/a/launch-photo-scaled.jpg", "https://x.com/a/launch-photo.jpg"));
    }

    [Fact]
    public void DifferentImages()
    {
        Assert.False(ImageKey.Same("https://cdn.aitimes.com/news/photo/202610/216199_220221_5549.jpg", "https://cdn.aitimes.com/news/photo/202610/216199_220222_5550.jpg"));
        Assert.False(ImageKey.Same("https://x.com/img/1.jpg", "https://y.com/img/1.jpg"));   // 짧은 이름은 주소가 같을 때만 같은 사진
        Assert.False(ImageKey.Same("https://x.com/img/a.jpg", "https://x.com/other/a.jpg"));
    }
}

public class SiteNameTests
{
    [Fact]
    public void Strips()
    {
        Assert.Equal("AI 업무 플랫폼 '팔레트 에이전트' 글로벌 출시", ArticleService.StripSiteName("AI 업무 플랫폼 '팔레트 에이전트' 글로벌 출시 - AI타임스", "AI타임스", "x"));
        Assert.Equal("OpenAI ships GPT-6", ArticleService.StripSiteName("OpenAI ships GPT-6 | The Verge", "The Verge", "x"));
    }

    [Fact]
    public void KeepsRealDashes() => Assert.Equal("GPT-6 - what changed", ArticleService.StripSiteName("GPT-6 - what changed", "The Verge", "x"));
}

public class CategoryBoundaryTests
{
    [Fact]
    public void NoPartialWordMatches() // A-08
    {
        Assert.True(Categories.Classify("The impact of rapid growth in capital markets").IsOther());
        Assert.True(Categories.Classify("A flaw that may happen in urban areas").IsOther());
        Assert.Equal("policy", Categories.Classify("EU passes the AI Act").Raw());
        Assert.Equal("business", Categories.Classify("OpenAI raises funding at new valuation").Raw());
        Assert.Equal("model", Categories.Classify("새 모델 출시").Raw());
    }
}

public class BodyCleanupTests
{
    [Fact]
    public void Bylines()
    {
        Assert.Equal("김가람 기자", BodyCleanup.BylineOf("김가람 기자 reporter@example.com"));
        Assert.Equal("이나래 기자", BodyCleanup.BylineOf("이나래 기자 desk@example.com Powered by AI"));
        Assert.Equal("이나래 기자", BodyCleanup.BylineOf("이나래 기자 desk@example.com Powered by Example AI Solution"));
        Assert.Equal("By Jane Doe", BodyCleanup.BylineOf("By Jane Doe"));
        Assert.Null(BodyCleanup.BylineOf("김가람 기자는 이날 현장에서 다음과 같이 말했다."));
    }

    [Fact]
    public void OrphanCaptions()
    {
        Assert.True(BodyCleanup.IsOrphanCaption("AI 생성 영상", nextIsImage: false));
        Assert.True(BodyCleanup.IsOrphanCaption("사진=연합뉴스", nextIsImage: false));
        Assert.False(BodyCleanup.IsOrphanCaption("사진=연합뉴스", nextIsImage: true));
        Assert.False(BodyCleanup.IsOrphanCaption("여수시 여문문화의거리가 정원과 공연을 결합한 축제 공간으로 활용되고 있다.", nextIsImage: false));
    }
}
