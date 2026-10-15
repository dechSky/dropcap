using Dropcap.Core;
using SkiaSharp;

namespace Dropcap.Ui;

// 기사 속 사진 다루기(R-20, 맥 ImageTools): 사진 속 글자 번역 · 복사 · 저장.
// 글자 인식·클립보드·저장 대화상자는 운영체제 몫이라 앱(Dropcap.App/ImageTools.cs)이 채워 넣는다. 사진 바이트는 안전 로더(ImageLoader)로만 받는다.
public static class ImageText
{
    // 사진 속 글자 줄(정규화 좌표: 왼쪽 위 원점 0~1)
    public sealed record Line(string Text, double X, double Y, double W, double H);

    // 기기 안에서 글자 읽기(윈도우: Windows.Media.Ocr). 없으면 글자를 찾지 못한 것으로
    public static Func<byte[], Task<IReadOnlyList<Line>>>? Recognize { get; set; }
    // 사진 복사(클립보드에 그림)
    public static Action<byte[]>? Copy { get; set; }
    // 사진 저장 대화상자: (제안 이름, 고른 확장자 → 그 형식의 바이트). 저장했으면 true
    public static Func<string, Func<string, byte[]?>, Task<bool>>? Save { get; set; }

    // 저장 대화상자에 넣을 이름: 주소의 파일 이름(확장자 뺌), 비었거나 80자 넘으면 image(맥과 같음) + .png
    public static string SuggestedName(string url)
    {
        var name = "";
        if (Uri.TryCreate(url, UriKind.Absolute, out var u))
        {
            var last = u.AbsolutePath.TrimEnd('/').Split('/').LastOrDefault() ?? "";
            try { last = Uri.UnescapeDataString(last); } catch { }
            name = Path.GetFileNameWithoutExtension(last);
        }
        foreach (var c in Path.GetInvalidFileNameChars().Concat(['\\', '/', ':', '*', '?', '"', '<', '>', '|'])) name = name.Replace(c, '_');
        if (name.Trim().Length == 0 || name.Length > 80) name = "image";
        return name + ".png";
    }

    // 고른 확장자로 다시 담기: jpg·jpeg 는 JPEG(품질 92), 그 밖은 PNG
    public static byte[]? Encode(byte[] data, string ext)
    {
        try
        {
            using var img = SKImage.FromEncodedData(data);
            if (img is null) return null;
            var jpeg = ext.TrimStart('.').ToLowerInvariant() is "jpg" or "jpeg";
            using var enc = img.Encode(jpeg ? SKEncodedImageFormat.Jpeg : SKEncodedImageFormat.Png, jpeg ? 92 : 100);
            return enc?.ToArray();
        }
        catch { return null; }
    }

    // 글자 상자 바로 바깥(위·아래 띠)의 평균 색 = 글자 뒤 바탕색(글자 자체 색이 섞이지 않게). #rrggbb 와 밝은지
    public static (string Color, bool Light) Background(SKBitmap bmp, Line l)
    {
        double W = bmp.Width, H = bmp.Height;
        var x = l.X * W;
        var w = Math.Max(1, l.W * W);
        var band = Math.Max(2, l.H * H * 0.18);
        var strips = new[] { (Y: l.Y * H - band - 1, Hgt: band), (Y: (l.Y + l.H) * H + 1, Hgt: band) };
        double r = 0, g = 0, b = 0;
        var n = 0;
        foreach (var s in strips)
        {
            int x0 = (int)Math.Max(0, Math.Floor(x)), x1 = (int)Math.Min(W, Math.Ceiling(x + w));
            int y0 = (int)Math.Max(0, Math.Floor(s.Y)), y1 = (int)Math.Min(H, Math.Ceiling(s.Y + s.Hgt));
            if (x1 - x0 < 1 || y1 - y0 < 1) continue;
            // 띠 하나의 평균(최대 40×8 점만 짚어 본다)
            double sr = 0, sg = 0, sb = 0;
            var k = 0;
            var stepX = Math.Max(1, (x1 - x0) / 40);
            var stepY = Math.Max(1, (y1 - y0) / 8);
            for (var yy = y0; yy < y1; yy += stepY)
                for (var xx = x0; xx < x1; xx += stepX)
                {
                    var c = bmp.GetPixel(xx, yy);
                    sr += c.Red; sg += c.Green; sb += c.Blue; k++;
                }
            if (k == 0) continue;
            r += sr / k / 255; g += sg / k / 255; b += sb / k / 255; n++;
        }
        if (n == 0) return ("#ffffff", true);
        r /= n; g /= n; b /= n;
        var lum = 0.299 * r + 0.587 * g + 0.114 * b;
        string Hex(double v) => ((int)Math.Round(Math.Clamp(v, 0, 1) * 255)).ToString("x2");
        return ($"#{Hex(r)}{Hex(g)}{Hex(b)}", lum > 0.55);
    }

    // 읽은 줄마다 바탕색을 붙여 화면에 보낼 모양으로
    public static List<object> Describe(byte[] data, IReadOnlyList<Line> lines)
    {
        SKBitmap? bmp = null;
        try { bmp = SKBitmap.Decode(data); } catch { }
        using (bmp)
            return lines.Select(l =>
            {
                var (bg, light) = bmp is null ? ("#ffffff", true) : Background(bmp, l);
                return (object)new { text = l.Text, x = l.X, y = l.Y, w = l.W, h = l.H, bg, light };
            }).ToList();
    }

    // 외국어 줄만 번역(맥 ImageTranslateModel.run). 번역하지 않은 줄은 null, 외국어 줄이 없으면 Korean=true
    public static async Task<(List<string?> Out, bool Korean)> TranslateAsync(IReadOnlyList<string> texts, Func<IReadOnlyList<string>, Task<List<string>>>? translate = null)
    {
        translate ??= t => Translator.Shared.TranslateManyAsync(t);
        var foreign = Enumerable.Range(0, texts.Count).Where(i => Translator.LooksForeign(texts[i])).ToList();
        var o = texts.Select(_ => (string?)null).ToList();
        if (foreign.Count == 0) return (o, true);
        var got = await translate(foreign.Select(i => texts[i]).ToList());
        for (var k = 0; k < foreign.Count && k < got.Count; k++)
            if (got[k] != texts[foreign[k]]) o[foreign[k]] = got[k];   // 번역되지 않고 그대로 온 줄(실패·번역 안 함)은 번역으로 치지 않음
        return (o, false);
    }
}
