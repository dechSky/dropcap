using System.Collections.Concurrent;
using SkiaSharp;

namespace Dropcap.Ui.Toast;

// 알림 카드의 글꼴: 함께 담긴 Pretendard(가변 글꼴, 굵기 지정) 또는 시스템 글꼴(P-03·D-01)
public static class Fonts
{
    private static readonly ConcurrentDictionary<(bool, int), SKTypeface> cache = new();
    private static SKTypeface? pretendard;
    private static bool loaded;

    public static bool UsePretendard { get; set; } = true;

    public static string PretendardPath => Path.Combine(AppContext.BaseDirectory, "web", "fonts", "PretendardVariable.ttf");

    private static SKTypeface? Base()
    {
        if (loaded) return pretendard;
        loaded = true;
        try { if (File.Exists(PretendardPath)) pretendard = SKTypeface.FromFile(PretendardPath); } catch { pretendard = null; }
        return pretendard;
    }

    // 굵기: 400 보통 · 500 중간 · 600 조금 굵게 · 700 굵게
    public static SKTypeface Get(int weight)
    {
        var usePre = UsePretendard && Base() is not null;
        return cache.GetOrAdd((usePre, weight), k =>
        {
            if (k.Item1)
            {
                var wght = ('w' << 24) | ('g' << 16) | ('h' << 8) | 't';
                try
                {
                    var args = new SKFontArguments { VariationDesignPosition = [new SKFontVariationPositionCoordinate { Axis = (uint)wght, Value = k.Item2 }] };
                    return pretendard!.Clone(args) ?? pretendard!;
                }
                catch { return pretendard!; }
            }
            // 시스템 글꼴: 윈도우 11 Segoe UI Variable(한글은 맑은 고딕으로 대체)
            var style = new SKFontStyle(k.Item2, (int)SKFontStyleWidth.Normal, SKFontStyleSlant.Upright);
            return SKFontManager.Default.MatchFamily("Segoe UI Variable Text", style)
                ?? SKFontManager.Default.MatchFamily("Segoe UI", style)
                ?? SKTypeface.FromFamilyName(null, style);
        });
    }

    // 한글 글자가 시스템 글꼴에 없으면 맑은 고딕 등으로
    public static SKTypeface ForText(string text, int weight)
    {
        var tf = Get(weight);
        if (UsePretendard && pretendard is not null) return tf;
        var cp = text.EnumerateRunes().FirstOrDefault(r => r.Value >= 0xAC00 && r.Value <= 0xD7A3).Value;
        if (cp == 0 || tf.ContainsGlyph(cp)) return tf;
        var style = new SKFontStyle(weight, (int)SKFontStyleWidth.Normal, SKFontStyleSlant.Upright);
        return SKFontManager.Default.MatchCharacter(null, style, ["ko-KR"], cp) ?? tf;
    }

    public static void Reset() => cache.Clear();
}

// 글자 줄바꿈(낱말 단위, 긴 낱말은 글자 단위)과 말줄임
public static class TextLayout
{
    public static List<string> Wrap(string text, SKFont font, float width, int maxLines)
    {
        var lines = new List<string>();
        var words = text.Replace('\n', ' ').Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var cur = "";
        var i = 0;
        while (i < words.Length)
        {
            var w = words[i];
            var tryLine = cur.Length == 0 ? w : cur + " " + w;
            if (font.MeasureText(tryLine) <= width) { cur = tryLine; i++; continue; }
            if (cur.Length == 0)
            {
                // 낱말 하나가 줄보다 길면 글자 단위로 자른다
                var n = Fit(w, font, width);
                lines.Add(w[..n]);
                words[i] = w[n..];
            }
            else
            {
                lines.Add(cur);
                cur = "";
            }
            if (lines.Count == maxLines) break;
        }
        if (lines.Count < maxLines && cur.Length > 0) { lines.Add(cur); cur = ""; }
        // 남은 글자가 있으면 마지막 줄을 말줄임
        var rest = cur.Length > 0 || i < words.Length;
        if (rest && lines.Count > 0)
        {
            var last = lines[^1];
            var remaining = cur.Length > 0 ? cur : string.Join(' ', words[i..]);
            lines[^1] = Ellipsize(last + " " + remaining, font, width);
        }
        return lines;
    }

    private static int Fit(string s, SKFont font, float width)
    {
        var n = 1;
        while (n < s.Length && font.MeasureText(s[..(n + 1)]) <= width) n++;
        if (char.IsHighSurrogate(s[n - 1]) && n < s.Length) n++;
        return n;
    }

    public static string Ellipsize(string s, SKFont font, float width)
    {
        if (font.MeasureText(s) <= width) return s;
        var lo = 0;
        var hi = s.Length;
        while (lo < hi)
        {
            var mid = (lo + hi + 1) / 2;
            if (font.MeasureText(s[..mid].TrimEnd() + "…") <= width) lo = mid; else hi = mid - 1;
        }
        return s[..lo].TrimEnd() + "…";
    }
}
