namespace Dropcap.Core.Tests;

using static SourceDirectory;

// 설정 › 구독 목록 정리(SourceDirectory, 맥 SourceDirectoryTests 와 같은 사례):
// 매체 묶음 키·이름 · 찾기(이름·주소·분야·지역·대소문자·띄어쓰기) · 켠 것 거르기 · 정렬 · 켠 수 · 요약
public class SourceDirectoryTests
{
    private static Source Src(string id, string name, string section = "economy", string region = "kr", string? url = null, string? home = null) => new()
    {
        Id = id, Name = name, Tier = region == "kr" ? "kr" : "press", Type = "feed", Url = url ?? $"https://{id}.example/rss",
        Color = "#000000", Home = home, Section = section, Region = region,
    };

    [Fact]
    public void MediaKeyAndName()
    {
        Source[] yna = [Src("yna-politics", "연합뉴스 정치", section: "politics"), Src("yna-market", "연합뉴스 마켓+"), Src("yna-latest", "연합뉴스 최신", section: "top")];
        Assert.Equal(["yna"], yna.Select(MediaKey).Distinct());
        Assert.Equal("연합뉴스", MediaName(yna));
        Assert.Equal("마켓+", ShortName(yna[1], "연합뉴스"));
        // 첫 낱말이 다르면 대표 피드(id == 묶음 키) 이름 — 가장 짧은 이름(NYT Arts)이 아니라 The New York Times
        Source[] nyt = [Src("nyt", "The New York Times", region: "intl"), Src("nyt-politics", "NYT Politics", region: "intl"), Src("nyt-arts", "NYT Arts", region: "intl")];
        Assert.Equal("The New York Times", MediaName(nyt));
        Assert.Equal("NYT", MediaName(nyt[1..]));                         // 대표 피드가 없으면 같은 첫 낱말
        Source[] nytHome = [Src("nyt-home", "The New York Times", region: "intl"), Src("nyt-politics", "NYT Politics", region: "intl"), Src("nyt-arts", "NYT Arts", region: "intl")];
        Assert.Equal("The New York Times", MediaName(nytHome));           // 실제 sources.json 은 nyt-home(키-home 도 대표 피드)
        Assert.Equal("Beta", MediaName([Src("x-a", "Alpha One"), Src("x-b", "Beta")])); // 그것도 아니면 가장 짧은 이름
        Assert.Equal("NYT Politics", ShortName(nyt[1], "The New York Times"));
        // 같은 이름 둘(Ars Technica 두 피드)은 그 이름 그대로, 짧은 이름도 그대로
        Source[] ars = [Src("ars", "Ars Technica", region: "intl"), Src("ars-ai", "Ars Technica", region: "intl")];
        Assert.Equal("Ars Technica", MediaName(ars));
        Assert.Equal("Ars Technica", ShortName(ars[0], "Ars Technica"));
        // 기본 출처: 연합뉴스·BBC 피드가 한 묶음
        var all = Resources.Config.Sources;
        var groups = Groups(all, all, Layout.Media, _ => false);
        Assert.Equal("연합뉴스", groups.First(g => g.Id == "media:yna").Title);
        Assert.True(groups.First(g => g.Id == "media:yna").Total >= 10);
        Assert.Equal("BBC", groups.First(g => g.Id == "media:bbc").Title);
        Assert.Equal("The New York Times", groups.First(g => g.Id == "media:nyt").Title);
        Assert.Equal(all.Count, groups.Sum(g => g.Total)); // 빠짐·겹침 없음
    }

    [Fact]
    public void SearchMatchesNameUrlSectionRegionIgnoringCaseAndSpaces()
    {
        Source[] list = [Src("bbc-world", "BBC World", section: "world", region: "intl", url: "https://feeds.bbci.co.uk/news/world/rss.xml"),
                         Src("hk-it", "한국경제 IT", section: "tech", home: "https://www.hankyung.com/it"),
                         Src("yna-market", "연합뉴스 마켓+")];
        List<string> Q(string s) => Filter(list, s, Status.All, _ => true).Select(x => x.Id).ToList();
        Assert.Equal(["bbc-world"], Q("bbc world"));      // 대소문자·띄어쓰기 무시
        Assert.Equal(["bbc-world"], Q("BBCWORLD"));
        Assert.Equal(["bbc-world"], Q("bbci.co.uk"));     // 주소
        Assert.Equal(["hk-it"], Q("hankyung"));           // 사람이 보는 주소(home)
        Assert.Equal(["bbc-world"], Q("국제"));            // 분야 이름
        Assert.Equal(["bbc-world"], Q("해외"));            // 지역
        Assert.Equal(["hk-it", "yna-market"], Q("국내"));
        Assert.Equal(3, Q("  ").Count);                   // 빈 찾기는 전부
        Assert.Empty(Q("없는출처"));
    }

    [Fact]
    public void StatusFilter()
    {
        Source[] list = [Src("a", "가"), Src("b", "나"), Src("c", "다")];
        var on = new HashSet<string> { "a", "c" };
        Assert.Equal(["a", "c"], Filter(list, "", Status.On, on.Contains).Select(s => s.Id));
        Assert.Equal(["b"], Filter(list, "", Status.Off, on.Contains).Select(s => s.Id));
        Assert.Empty(Filter(list, "나", Status.On, on.Contains));
    }

    [Fact]
    public void SortingDomesticFirstThenAbc()
    {
        Source[] list = [Src("x", "Zeta", region: "intl"), Src("y", "한겨레", region: "kr"), Src("z", "alpha", region: "intl"), Src("w", "경향신문", region: "kr")];
        Assert.Equal(["경향신문", "한겨레", "alpha", "Zeta"], Sorted(list).Select(s => s.Name));
    }

    [Fact]
    public void GroupCountsAndBulkTargetsOnlyShown()
    {
        Source[] all = [Src("yna-a", "연합뉴스 경제"), Src("yna-b", "연합뉴스 정치", section: "politics"), Src("yna-c", "연합뉴스 국제", section: "world"),
                        Src("bbc-a", "BBC World", section: "world", region: "intl")];
        var on = new HashSet<string> { "yna-a", "yna-b" };
        var shown = Filter(all, "국제", Status.All, on.Contains);
        var media = Groups(all, shown, Layout.Media, on.Contains);
        // 국내 먼저, 묶음 켠 수는 묶음 전체(2/3), 보이는 것은 거른 것만(묶음 켜기·끄기는 이것에만)
        Assert.Equal(["media:yna", "media:bbc"], media.Select(g => g.Id));
        Assert.Equal((2, 3), (media[0].On, media[0].Total));
        Assert.Equal(["yna-c"], media[0].Sources.Select(s => s.Id));
        var sections = Groups(all, all, Layout.Section, on.Contains);
        Assert.Equal(["section:politics", "section:economy", "section:world"], sections.Select(g => g.Id)); // categories.json 순서
        Assert.Equal((0, 2), (sections[^1].On, sections[^1].Total));
        var regions = Groups(all, all, Layout.Region, on.Contains);
        Assert.Equal(["국내", "해외"], regions.Select(g => g.Title));
    }

    [Fact]
    public void SummaryAndCount()
    {
        Source[] all = [Src("a", "가"), Src("b", "나", section: "politics"), Src("c", "다"), Src("d", "라", section: "world")];
        var on = new HashSet<string> { "a", "b", "c" };
        Assert.Equal("켠 출처 3곳 · 정치 1 · 경제 2", SummaryText(all, on.Contains));
        Assert.Equal("켠 출처 없음", SummaryText(all, _ => false));
        Assert.Equal("147곳 중 12곳", CountText(12, 147));
        Assert.Equal("147곳", CountText(147, 147));
    }
}
