namespace Dropcap.Core;

// 읽기 창 표지 사진 고르기(맥 CoverPick · ReaderModel.findCover 와 같은 규칙, READSWEEP 에서 찾은 것):
// - 피드 사진이 작은 미리보기(가디언 280px)거나 못 받는 사진(8MB 넘는 원본 — Politico·NPR)이면 기사 머리 대표 사진으로 바꾼다
// - 기사 머리 대표 사진을 찾을 때 og:image:type("image/jpeg")을 사진 주소로 잡던 문제를 막는다(DW) — <meta> 를 하나씩 떼어 읽는 HtmlScan
public static class CoverPick
{
    public const int MinWidth = 400;

    public static bool BigEnough(int? width) => width >= MinWidth;

    // 피드 사진 → 매거진 기록(잡그림은 빼고). 없으면 null
    public static string? Known(string? feedImage, string? stored) =>
        new[] { feedImage, stored }.FirstOrDefault(u => u is not null && !ImageKey.IsJunk(u));

    // 페이지 머리에서 대표 사진 주소: og:image(:url) → og:image:secure_url → twitter:image, 속성 순서는 어느 쪽이든(앞 200KB 만)
    public static string? OgImage(string html, string link) =>
        FeedService.OgImageFrom(html.Length > 200_000 ? html[..200_000] : html, link);

    public static async Task<string?> OgImageAsync(string link)
    {
        byte[]? data;
        try { data = await FeedService.Shared.FetchAsync(link, limit: FetchLimit.Page); } catch { return null; }
        if (data is null) return null;
        return OgImage(System.Text.Encoding.UTF8.GetString(data, 0, Math.Min(data.Length, 200_000)), link);
    }

    // 표지 고르기. width: 사진을 받아 본 가로 크기(못 받으면 null), ogImage: 기사 머리 대표 사진 주소 찾기.
    // 돌려주는 값: 쓸 표지(null 이면 표지 없음 — 깨진 사진 자리를 남기지 않는다. 그때 화면은 본문 첫 사진을 표지로)
    public static async Task<string?> FindAsync(string? known, string link, Func<string, Task<int?>> width, Func<string, Task<string?>> ogImage)
    {
        var knownLoads = false;
        if (known is not null)
        {
            var w = await width(known);
            if (BigEnough(w)) return known;
            knownLoads = w is not null;
        }
        if (link.Length > 0 && await ogImage(link) is { } og && !ImageKey.IsJunk(og) && og != known
            && await width(og) is { } ow && (!knownLoads || BigEnough(ow)))
            return og;
        return knownLoads ? known : null;
    }
}
