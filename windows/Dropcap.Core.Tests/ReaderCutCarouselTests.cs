namespace Dropcap.Core.Tests;

// 캐러셀·슬라이드 속 본문 글(규칙 carousel-slides) — 맥 CarouselTests 와 같은 꼴.
// 실제 꼴은 Google 블로그 큰 발표 기사(맥 Fixtures/reader-cut/carousel-cards — 글·주소를 바꾸고 표지 낱말만 원래 자리에), 나머지는 지어낸 HTML.
public class ReaderCutCarouselTests
{
    private static string Para(int n) => ReaderCutText.Para(n);
    private static string SlideText(int n) => $"Slide {n} shows the new pier at dawn while crews lift the last steel beam into place above the water.";
    private static List<Block> Blocks(Article? a) => a?.Blocks.ToList() ?? new();
    private static int At(List<Block> b, string s) => b.FindIndex(x => (x.Text ?? x.Src ?? "").Contains(s));
    private static int Count(List<Block> b, string s) => b.Count(x => (x.Text ?? x.Src ?? "").Contains(s));
    private static string Page(string middle, string after = "") =>
        "<html><body><main><article><h1>Harbor plan</h1>" + string.Concat(Enumerable.Range(1, 4).Select(n => $"<p>{Para(n)}</p>"))
        + middle + string.Concat(Enumerable.Range(5, 4).Select(n => $"<p>{Para(n)}</p>")) + "</article>" + after + "</main></body></html>";

    // 영상 카드 설명 · 속성에만 글이 든 인용 카드 · 영상 카드가 본문 사이에, 관련 기사 캐러셀은 본문 밖
    [JsFact]
    public async Task RealGoogleCards()
    {
        var b = Blocks(await ExtractJs.OneAsync(ReaderCutText.Fixture("carousel-cards")));
        int before = At(b, "BEFORECAR"), after = At(b, "AFTERCAR"), first = At(b, "CARCAPA"), quote = At(b, "CARQUOTE");
        Assert.True(before >= 0 && after >= 0 && first >= 0, "앞 글·뒤 소제목·첫 칸");
        Assert.True(before < first && first < after, "본문 순서대로");
        Assert.Equal(BlockKind.P, b[first].Type);
        Assert.True(quote >= 0, "속성 quote= 의 인용");
        Assert.Equal(BlockKind.Quote, b[quote].Type);
        Assert.Contains("CARWHO", b[quote + 1].Text);
        Assert.True(At(b, "CARCAPZ") >= 0, "마지막 캐러셀 마지막 칸");
        Assert.Equal(1, Count(b, "CARCAPA"));
        Assert.Equal(1, Count(b, "CARQUOTE"));
        Assert.True(At(b, "RELCAR") < 0, "본문 밖 관련 기사 캐러셀");
        Assert.Equal(12, b.Count(x => x.Type == BlockKind.Quote));
    }

    // swiper 무한 돌기: 화면 밖 칸(aria-hidden)·복제 칸·돌려 놓은 차례(data-swiper-slide-index)
    [JsFact]
    public async Task SwiperOffscreenClonesAndOrder()
    {
        string Slide(int i, string extra) =>
            $"<div class=\"swiper-slide{extra}\" data-swiper-slide-index=\"{i}\" aria-hidden=\"{(i == 1 ? "false" : "true")}\"><img src=\"https://img.example.com/s{i}.jpg\"><div class=\"swiper-caption\"><p>{SlideText(i)}</p></div></div>";
        var html = Page($"<div class=\"swiper gallery-swiper\"><div class=\"swiper-wrapper\">{Slide(2, " swiper-slide-duplicate")}{Slide(1, "")}{Slide(2, "")}{Slide(0, "")}{Slide(1, " swiper-slide-duplicate")}</div>"
                        + "<div class=\"swiper-pagination\"><span>1</span><span>2</span><span>3</span></div><button class=\"swiper-button-next\">Next</button></div>");
        var b = Blocks(await ExtractJs.OneAsync(html));
        var idx = Enumerable.Range(0, 3).Select(i => At(b, SlideText(i))).ToList();
        Assert.All(idx, i => Assert.True(i >= 0, "화면 밖 칸도"));
        Assert.True(idx[0] < idx[1] && idx[1] < idx[2], "칸 차례");
        Assert.All(Enumerable.Range(0, 3), i => Assert.Equal(1, Count(b, SlideText(i))));
        Assert.All(Enumerable.Range(0, 3), i => Assert.Equal(1, b.Count(x => x.Type == BlockKind.Img && (x.Src ?? "").EndsWith($"s{i}.jpg"))));
        Assert.True(At(b, Para(4)) < idx[0] && idx[0] < At(b, Para(5)), "본문 순서");
        Assert.DoesNotContain(b, x => x.Text is "Next" or "1 2 3");
    }

    // slick 복제 칸 · aria-roledescription 캐러셀의 li 칸
    [JsFact]
    public async Task SlickClonesAndAriaSlides()
    {
        var html = Page($"<div class=\"slick-slider\"><div class=\"slick-track\"><div class=\"slick-slide slick-cloned\"><p>{SlideText(4)}</p></div>"
                        + $"<div class=\"slick-slide\"><p>{SlideText(3)}</p></div><div class=\"slick-slide\"><p>{SlideText(4)}</p></div></div></div><p>{Para(41)}</p>"
                        + $"<section aria-roledescription=\"carousel\"><ul><li aria-roledescription=\"slide\"><figure><img src=\"https://img.example.com/a1.jpg\"></figure><p>{SlideText(5)}</p></li>"
                        + $"<li aria-roledescription=\"slide\" aria-hidden=\"true\"><figure><img src=\"https://img.example.com/a2.jpg\"></figure><p>{SlideText(6)}</p></li></ul></section>");
        var b = Blocks(await ExtractJs.OneAsync(html));
        Assert.Equal(1, Count(b, SlideText(4)));
        Assert.True(At(b, SlideText(3)) >= 0 && At(b, SlideText(3)) < At(b, SlideText(4)), "복제 칸이 앞에 와도 차례대로");
        int s5 = At(b, SlideText(5)), s6 = At(b, SlideText(6));
        Assert.True(s5 >= 0 && s6 >= 0, "li 칸이 한 줄로 뭉치지 않고 글로");
        Assert.Contains(b, x => x.Type == BlockKind.Img && (x.Src ?? "").EndsWith("a2.jpg"));
        Assert.True(At(b, Para(41)) < s5 && s5 < s6 && s6 < At(b, Para(5)));
    }

    // 본문 사이에 있어도 칸 글이 거의 링크인 추천 줄 · 본문 뒤 캐러셀 · aside 안 캐러셀은 넣지 않는다
    [JsFact]
    public async Task RecommendCarouselsStayOut()
    {
        string Card(int i) => $"<div class=\"swiper-slide\"><a href=\"/s{i}\"><img src=\"https://img.example.com/r{i}.jpg\"><span>Recommended headline number {i} about the city budget</span></a></div>";
        var html = Page("<div class=\"swiper\"><div class=\"swiper-wrapper\">" + string.Concat(Enumerable.Range(1, 4).Select(Card)) + "</div></div>",
            "<div class=\"owl-carousel\"><div class=\"owl-item\"><p>Gallery card seven</p></div><div class=\"owl-item\"><p>Gallery card eight</p></div></div>"
            + "<aside><div aria-roledescription=\"carousel\"><div aria-roledescription=\"slide\"><p>Sidebar card ten</p></div></div></aside>");
        var b = Blocks(await ExtractJs.OneAsync(html));
        Assert.True(At(b, "Recommended headline") < 0);
        Assert.True(At(b, "Gallery card") < 0, "본문 뒤 캐러셀");
        Assert.True(At(b, "Sidebar card") < 0, "aside 안 캐러셀");
        Assert.True(At(b, Para(8)) >= 0);
    }

    // 보안 낮음 L2: 추천 머리말이 캐러셀 바깥 바로 앞 형제(또는 한 겹 감싼 상자의 앞 형제)이고 칸에 링크가 없어도(onclick 카드) 화면 밖 칸을 넣지 않는다
    [JsFact]
    public async Task RecommendHeadOutsideRoot()
    {
        string Card(int i) => $"<div class=\"swiper-slide\" aria-hidden=\"true\" onclick=\"go({i})\"><p>Related card {i} follows the council debate on the new harbor budget.</p></div>";
        var html = Page("<h2>Related stories</h2><div class=\"swiper\"><div class=\"swiper-wrapper\">" + string.Concat(Enumerable.Range(1, 3).Select(Card)) + $"</div></div><p>{Para(41)}</p>"
            + "<div class=\"section-head\"><h3>You may also like</h3></div><div class=\"box\"><div class=\"glide\"><div class=\"glide__slide\" aria-hidden=\"true\"><p>Wrapped card nine follows the council debate on the harbor.</p></div></div></div>"
            + $"<p>{Para(42)}</p><h2>Building the pier</h2><div class=\"swiper\"><div class=\"swiper-slide\" aria-hidden=\"true\"><p>{SlideText(7)}</p></div></div>");
        var b = Blocks(await ExtractJs.OneAsync(html));
        Assert.True(At(b, "Related card") < 0, "바로 앞 형제 제목");
        Assert.True(At(b, "Wrapped card") < 0, "감싼 상자의 앞 형제 제목");
        Assert.True(At(b, SlideText(7)) >= 0, "추천이 아닌 앞 제목은 그대로");
    }

    // 보안 낮음 L3: 칸 수(50)·칸 글 양(본문 글자 2배, 적어도 3000자) 상한
    [JsFact]
    public async Task SlideCap()
    {
        var photos = string.Concat(Enumerable.Range(0, 80).Select(i => $"<div class=\"swiper-slide\"><img src=\"https://img.example.com/g{i}.jpg\"></div>"));
        var b1 = Blocks(await ExtractJs.OneAsync(Page($"<div class=\"swiper\">{photos}</div>")));
        Assert.Equal(50, b1.Count(x => x.Type == BlockKind.Img && (x.Src ?? "").Contains("/g")));
        Assert.Contains(b1, x => (x.Src ?? "").EndsWith("/g0.jpg"));
        var texts = string.Concat(Enumerable.Range(0, 80).Select(i => $"<div class=\"swiper-slide\"><p>{SlideText(i)}</p></div>"));
        var b2 = Blocks(await ExtractJs.OneAsync(Page($"<div class=\"swiper\">{texts}</div>")));
        var n = Enumerable.Range(0, 80).Count(i => At(b2, SlideText(i)) >= 0);
        Assert.True(At(b2, SlideText(0)) >= 0 && n >= 20 && n <= 35, $"글 양 상한({n}칸)");
        Assert.True(At(b2, Para(5)) >= 0);
    }

    // 칸이 없는 'carousel' 상자는 그대로
    [JsFact]
    public async Task NoCarouselUnchanged()
    {
        var b = Blocks(await ExtractJs.OneAsync(Page($"<div class=\"carousel-note\"><p>{Para(40)}</p></div>")));
        Assert.Equal(1, Count(b, Para(40)));
        Assert.Equal(9, b.Count(x => x.Type == BlockKind.P));
    }
}
