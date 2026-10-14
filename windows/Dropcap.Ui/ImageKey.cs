using System.Text.RegularExpressions;

namespace Dropcap.Ui;

// 사진 주소 판별(맥 ReaderView.ImageKey 와 같은 규칙): 기사 사진이 아닌 잡그림, 크기만 다른 같은 사진
public static class ImageKey
{
    private static readonly Regex Suffix = new(@"([-_](v?\d{2,4}(x\d{2,4})?|thumb(nail)?|small|medium|large|scaled|crop(ped)?|resize[d]?|\d{2,4}w))+$");
    private static readonly Regex Junk = new(@"(default[-_]?user|avatar|profile|reporter|byline|author|gravatar|/logo|logo[-_.]|favicon|/icons?/|icon[-_.]|spacer|blank\.|1x1|pixel\.|badge|sprite|emoji|/ads?/)");

    public static string Key(string url)
    {
        var u = url.ToLowerInvariant();
        var q = u.IndexOfAny(['?', '#']);
        if (q >= 0) u = u[..q];
        var name = u.Split('/', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? u;
        var dot = name.LastIndexOf('.');
        if (dot >= 0 && name.Length - dot <= 5) name = name[..dot];
        return Suffix.Replace(name, "");
    }

    // 기사 사진이 아닌 잡그림: 기자 프로필·아바타·로고·아이콘·추적용 1픽셀
    public static bool IsJunk(string? url)
    {
        if (url is null) return true;
        var name = url.ToLowerInvariant().Split('?')[0];
        return Junk.IsMatch(name);
    }

    public static bool Same(string? a, string? b)
    {
        if (a is null || b is null) return false;
        if (a == b) return true;
        var ka = Key(a);
        return ka.Length >= 6 && ka == Key(b);
    }
}
