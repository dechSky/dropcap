using System.Collections.Concurrent;
using System.IO.Compression;
using System.Net.Http.Headers;
using System.Text.RegularExpressions;

namespace Dropcap.Core;

// 출처 하나를 받아 와서 NewsItem 목록으로 바꾼다. ETag·Last-Modified 로 바뀐 것이 없으면 null.
public sealed class FeedService
{
    public static readonly FeedService Shared = new();

    private readonly ConcurrentDictionary<string, (string? ETag, string? Modified)> validators = new();
    private readonly Dictionary<string, DateTimeOffset> firstSeen = new();   // 날짜 없는 글을 처음 본 시각(FeedDates.Repair)
    private readonly ConcurrentDictionary<string, (string? ETag, string? Modified)> pending = new(); // 해석이 성공해야 확정

    public async Task<byte[]?> FetchAsync(string url, bool conditional = false, CancellationToken ct = default, long limit = FetchLimit.Feed) =>
        (await FetchWithEncodingAsync(url, conditional, ct, limit))?.Data;

    // 본문과 함께 문자 인코딩 이름(헤더 기준)을 돌려준다
    // 잠깐의 서버 오류(5xx·429, YouTube 피드의 간헐적 404)는 한 번 더 시도한다(C-07)
    public async Task<(byte[] Data, string? Encoding)?> FetchWithEncodingAsync(string url, bool conditional = false, CancellationToken ct = default, long limit = FetchLimit.Feed)
    {
        var youtube = url.Contains("youtube.com/feeds", StringComparison.Ordinal);
        var attempt = 0;
        while (true)
        {
            try
            {
                return await FetchOnceAsync(url, conditional, ct, limit);
            }
            catch (HttpStatusException e) when (e.Code == 429 || e.Code is >= 500 and <= 504 || (e.Code == 404 && youtube))
            {
                attempt++;
                if (attempt > (youtube ? 2 : 1)) throw;
                await Task.Delay(e.Code == 429 ? 3000 : 1500 * attempt, ct);
            }
        }
    }

    private async Task<(byte[] Data, string? Encoding)?> FetchOnceAsync(string url, bool conditional, CancellationToken ct, long limit)
    {
        SafeHttp.Response r;
        try
        {
            r = await SafeHttp.GetAsync(url, req =>
            {
                req.Headers.Accept.ParseAdd("application/rss+xml, application/atom+xml, application/xml, text/xml, text/html;q=0.8");
                if (conditional && validators.TryGetValue(url, out var v))
                {
                    if (v.ETag is not null) req.Headers.TryAddWithoutValidation("If-None-Match", v.ETag);
                    if (v.Modified is not null) req.Headers.TryAddWithoutValidation("If-Modified-Since", v.Modified);
                }
            }, maxBody: limit, ct: ct);
        }
        catch (HttpRequestException e) when (e.InnerException is BlockedException b) { throw b; }
        catch (HttpRequestException e) when (e.InnerException?.InnerException is BlockedException b) { throw b; }
        if (r.Status == 304) return null;
        if (r.Status is < 200 or >= 300) throw new HttpStatusException(r.Status);
        if (conditional)
            pending[url] = (r.Headers.ETag?.ToString(), r.ContentHeaders?.LastModified?.ToString("R"));
        return (Gzip.InflateIfNeeded(r.Body), r.Charset);
    }

    public async Task<List<NewsItem>?> ItemsAsync(Source source, bool conditional = true, CancellationToken ct = default)
    {
        var data = await FetchAsync(source.Url, conditional, ct);
        if (data is null) return null;
        List<FeedParser.Entry> entries;
        if (source.Type == "sitemap" && source.Match is { } m)
            entries = FeedParser.ParseSitemap(data, new Regex(m, RegexOptions.None, TimeSpan.FromMilliseconds(250))); // 시간 제한(정규식 폭주 막기)
        else
            entries = FeedParser.ParseFeed(data);
        // 해석에 성공했을 때만 "바뀐 것 없음" 표시를 확정한다(실패한 피드가 304 로 가려지지 않게)
        if (pending.TryRemove(source.Url, out var v)) validators[source.Url] = v;
        lock (firstSeen) FeedDates.Repair(entries, source.Id, DateTimeOffset.Now, firstSeen);   // 날짜 없는 글·미래 날짜 다듬기
        // http(s) 링크만: file:// · smb:// 같은 주소는 열지 않는다
        return entries.Where(e => UrlSafety.IsPublicHttp(e.Link)).Select(e => new NewsItem
        {
            Id = e.Id, Title = e.Title, Link = e.Link, Date = e.Date, Summary = e.Summary,
            SourceId = source.Id, SourceName = source.Name, Tier = source.Tier,
            Image = e.Image is not null && Uri.TryCreate(e.Link, UriKind.Absolute, out var baseUri) && Uri.TryCreate(baseUri, e.Image, out var img) ? img.AbsoluteUri : null,
            Kind = source.Kind,
        }).ToList();
    }

    private static string? Meta(string html, string pattern)
    {
        var m = Regex.Match(html, pattern, RegexOptions.IgnoreCase);
        return m.Success ? m.Groups[1].Value : null;
    }

    // 사이트맵에서 찾은 새 글은 본문을 받아 제목·설명을 채운다(C-03)
    public async Task<NewsItem> FillTitleAsync(NewsItem item, CancellationToken ct = default)
    {
        byte[]? data;
        try { data = await FetchAsync(item.Link, ct: ct, limit: FetchLimit.Page); } catch { data = null; }
        if (data is null) return item with { Title = Plain.TitleFromSlug(item.Link) };
        var html = System.Text.Encoding.UTF8.GetString(data);
        var title = Meta(html, "<meta[^>]+property=[\"']og:title[\"'][^>]+content=[\"']([^\"']+)") ?? Meta(html, "<title[^>]*>([^<]+)</title>");
        var t = title is null ? null : FeedParser.NonEmpty(Regex.Replace(Plain.Clean(title), @"\s*[|\\-]\s*Anthropic\s*$", ""));
        var it = item with { Title = t ?? Plain.TitleFromSlug(item.Link) };
        if (Meta(html, "<meta[^>]+name=[\"']description[\"'][^>]+content=[\"']([^\"']+)") is { } d) it = it with { Summary = FeedParser.Prefix(Plain.Clean(d), 300) };
        if (it.Image is null && Meta(html, "<meta[^>]+property=[\"']og:image[\"'][^>]+content=[\"']([^\"']+)") is { } img) it = it with { Image = img };
        return it;
    }

    // 대표 사진이 없는 기사는 페이지 머리의 og:image 를 찾아 채운다(공개 주소만, 앞 64KB 만 읽음)(C-04)
    public async Task<string?> OgImageAsync(string link, CancellationToken ct = default)
    {
        byte[]? data;
        try { data = await FetchAsync(link, ct: ct, limit: FetchLimit.Page); } catch { return null; }
        if (data is null) return null;
        var head = System.Text.Encoding.UTF8.GetString(data, 0, Math.Min(data.Length, 65536));
        foreach (var pattern in new[] {
                     """<meta[^>]+property=["']og:image(?::url)?["'][^>]+content=["']([^"']+)""",
                     """<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image""",
                     """<meta[^>]+name=["']twitter:image["'][^>]+content=["']([^"']+)""" })
        {
            if (Meta(head, pattern) is { } raw)
            {
                raw = raw.Replace("&amp;", "&");
                return Uri.TryCreate(new Uri(link), raw, out var u) ? u.AbsoluteUri : null;
            }
        }
        return null;
    }
}

// Content-Encoding 없이 gzip 본문을 보내는 서버(DeepMind 등) 대비(C-05)
public static class Gzip
{
    public static byte[] InflateIfNeeded(byte[] data)
    {
        if (data.Length <= 18 || data[0] != 0x1F || data[1] != 0x8B) return data;
        var flags = data[3];
        var i = 10;
        if ((flags & 0x04) != 0) i += 2 + data[i] + (data[i + 1] << 8);
        if ((flags & 0x08) != 0) { while (i < data.Length && data[i] != 0) i++; i++; }
        if ((flags & 0x10) != 0) { while (i < data.Length && data[i] != 0) i++; i++; }
        if ((flags & 0x02) != 0) i += 2;
        if (i >= data.Length - 8) return data;
        var deflatedLength = data.Length - 8 - i;
        var isize = BitConverter.ToUInt32(data, data.Length - 4);
        // 크기 값은 믿지 않고 32MB 로 상한(깨지거나 악의적인 응답 대비)(S-09)
        var capacity = (int)Math.Min(Math.Max((long)isize, (long)deflatedLength * 8) + 1024, 32L << 20);
        try
        {
            using var src = new DeflateStream(new MemoryStream(data, i, deflatedLength), CompressionMode.Decompress);
            var out_ = new byte[capacity];
            var n = 0;
            int got;
            while (n < capacity && (got = src.Read(out_, n, capacity - n)) > 0) n += got;
            return n > 0 ? out_[..n] : data;
        }
        catch (InvalidDataException) { return data; }
    }
}
