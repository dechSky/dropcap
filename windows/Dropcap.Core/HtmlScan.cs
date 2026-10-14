namespace Dropcap.Core;

// 바깥 HTML(피드 본문·기사 머리)에서 꼬리표 찾기 — 맥 Core/HTMLScan.swift 와 같은 규칙.
// '<meta[^>]+…[^>]+content=' 같은 정규식은 닫히지 않은 꼬리표가 많은 글에서 시작 자리마다 끝까지 되풀이해 훑어
// 시간이 크기의 제곱 이상으로 는다(보안 점검: og:title 20KB 에 20초+). 그래서 "<이름" 을 한 번 훑어 꼬리표를 하나씩
// (길어야 2000자, 그 전에 '<' 가 나오면 거기까지) 떼어 보고, 속성은 그 조각 안에서만 한 번 훑어 읽는다.
public static class HtmlScan
{
    public const int MaxTag = 2000;
    public const int MaxTags = 2000;

    // "<name" 으로 시작하는 꼬리표들의 속성 부분(이름 뒤 ~ '>' 앞). 이름이 더 긴 꼬리표(<metadata · <linkx)는 건너뛴다
    public static List<string> Tags(string name, string html)
    {
        var o = new List<string>();
        var open = "<" + name;
        var i = 0;
        while (o.Count < MaxTags && (i = html.IndexOf(open, i, StringComparison.OrdinalIgnoreCase)) >= 0)
        {
            i += open.Length;
            if (i < html.Length && (char.IsLetterOrDigit(html[i]) || html[i] is '-' or '_' or ':')) continue;
            var limit = Math.Min(html.Length, i + MaxTag);
            var end = i;
            while (end < limit && html[end] != '>' && html[end] != '<') end++;
            o.Add(html[i..end]);
        }
        return o;
    }

    // 꼬리표 안 속성 값(따옴표 " ' 또는 없음). data-src 같은 긴 이름은 src 로 보지 않는다. 닫히지 않은 따옴표면 null
    public static string? Attr(string tag, string name)
    {
        if (name.Length == 0) return null;
        for (var i = 0; i + name.Length <= tag.Length; i++)
        {
            if (i > 0 && !IsSpace(tag[i - 1])) continue;
            if (string.Compare(tag, i, name, 0, name.Length, StringComparison.OrdinalIgnoreCase) != 0) continue;
            var j = i + name.Length;
            while (j < tag.Length && IsSpace(tag[j])) j++;
            if (j >= tag.Length || tag[j] != '=') continue;
            j++;
            while (j < tag.Length && IsSpace(tag[j])) j++;
            if (j >= tag.Length) return null;
            if (tag[j] is '"' or '\'')
            {
                var close = tag.IndexOf(tag[j], j + 1);
                return close < 0 ? null : tag[(j + 1)..close];
            }
            var k = j;
            while (k < tag.Length && !IsSpace(tag[k]) && tag[k] is not ('"' or '\'' or '>')) k++;
            if (k > j) return tag[j..k];
        }
        return null;
    }

    private static bool IsSpace(char c) => c is ' ' or '\t' or '\n' or '\r' or '\f';

    // <meta property|name="키" content="…"> 의 값(속성 순서는 어느 쪽이든). 키 목록 순서대로, 빈 값이 아닌 첫 것
    public static string? Meta(string html, params string[] keys)
    {
        var found = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        foreach (var tag in Tags("meta", html))
        {
            if ((Attr(tag, "property") ?? Attr(tag, "name")) is not { } key || Attr(tag, "content") is not { } content) continue;
            if (!found.TryGetValue(key, out var list)) found[key] = list = new();
            list.Add(content);
        }
        foreach (var k in keys)
            if (found.TryGetValue(k, out var list))
                foreach (var v in list) if (v.Length > 0) return v;
        return null;
    }

    // <title>…</title> 안 글(길어야 2000자, 안에 꼬리표가 있으면 null)
    public static string? Title(string html)
    {
        var i = 0;
        while ((i = html.IndexOf("<title", i, StringComparison.OrdinalIgnoreCase)) >= 0)
        {
            i += 6;
            if (i >= html.Length || !(html[i] == '>' || char.IsWhiteSpace(html[i]))) continue;
            var gt = html.IndexOf('>', i, Math.Min(MaxTag, html.Length - i));
            if (gt < 0) return null;
            var start = gt + 1;
            var span = Math.Min(MaxTag, html.Length - start);
            var end = html.IndexOf("</title", start, span, StringComparison.OrdinalIgnoreCase);
            if (end < 0) return null;
            var t = html[start..end];
            return t.Contains('<') ? null : t;
        }
        return null;
    }
}
