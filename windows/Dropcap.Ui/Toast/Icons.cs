using SkiaSharp;

namespace Dropcap.Ui.Toast;

// 알림 카드·트레이·앱 아이콘에 쓰는 선 아이콘(24×24 좌표, web/ui.js 와 같은 모양)
public static class Icons
{
    private static string Circle(float cx, float cy, float r) => FormattableString.Invariant($"M{cx - r} {cy}a{r} {r} 0 1 0 {2 * r} 0a{r} {r} 0 1 0 {-2 * r} 0");

    // (선, 채움)
    private static readonly Dictionary<string, (string? Stroke, string? Fill)> Paths = new()
    {
        ["star.fill"] = (null, "M12 3.5l2.6 5.4 5.9.8-4.3 4.1 1 5.8L12 16.8l-5.2 2.8 1-5.8-4.3-4.1 5.9-.8z"),
        ["sparkles"] = (null, "M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8zM18.5 15.5l.7 2 2 .7-2 .7-.7 2-.7-2-2-.7 2-.7z"),
        ["sun.horizon"] = ("M3 18h18M7 18a5 5 0 0 1 10 0M12 6.5v2M5.6 9.6l1.4 1.4M18.4 9.6L17 11M3.5 14.5h1.8M18.7 14.5h1.8", "M7 18a5 5 0 0 1 10 0z"),
        ["bookmark"] = ("M7 3.5h10v17l-5-3.5-5 3.5z", null),
        ["bookmark.fill"] = (null, "M7 3.5h10v17l-5-3.5-5 3.5z"),
        ["globe"] = (Circle(12, 12, 8.5f) + "M3.5 12h17M12 3.5c2.5 2.5 3.5 5.5 3.5 8.5s-1 6-3.5 8.5c-2.5-2.5-3.5-5.5-3.5-8.5s1-6 3.5-8.5z", null),
        ["xmark"] = ("M6 6l12 12M18 6L6 18", null),
        ["cat.model"] = ("M12 3l8 4.5v9L12 21l-8-4.5v-9zM4 7.5l8 4.5 8-4.5M12 12v9", null),
        ["cat.research"] = ("M9.5 3.5h5M10.5 3.5v6L5 19a1.3 1.3 0 0 0 1.1 2h11.8a1.3 1.3 0 0 0 1.1-2l-5.5-9.5v-6M7.5 15h9", null),
        ["cat.policy"] = ("M3.5 9.5L12 4l8.5 5.5zM5.5 10v8M9.5 10v8M14.5 10v8M18.5 10v8M3.5 20h17", null),
        ["cat.business"] = ("M4 19l5-6 4 3 7-9M15 7h5v5", null),
        ["cat.security"] = ("M12 3.5l7.5 3v5.5c0 4.5-3.2 7.8-7.5 9-4.3-1.2-7.5-4.5-7.5-9V6.5zM9 11h6v5H9zM10 11V9.5a2 2 0 0 1 4 0V11", null),
        ["cat.other"] = (Circle(8, 8, 2.5f) + Circle(16, 8, 2.5f) + Circle(8, 16, 2.5f) + Circle(16, 16, 2.5f), null),
        ["people"] = (Circle(12, 8, 3) + Circle(5.5f, 10, 2.2f) + Circle(18.5f, 10, 2.2f) + "M6.5 19a5.5 5.5 0 0 1 11 0M2 18a3.6 3.6 0 0 1 4.5-3.4M22 18a3.6 3.6 0 0 0-4.5-3.4", null),
        ["desktop"] = ("M5 4.5h14a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-8a2 2 0 0 1 2-2zM9 20h6M12 16.5V20", null),
        ["atom"] = ("M3 12a9 3.6 0 1 0 18 0a9 3.6 0 1 0-18 0M7.5 4.2a3.6 9 30 1 0 9 15.6a3.6 9 30 1 0-9-15.6", Circle(12, 12, 1.6f)),
        ["heart"] = ("M6.5 3.5h11a3 3 0 0 1 3 3v11a3 3 0 0 1-3 3h-11a3 3 0 0 1-3-3v-11a3 3 0 0 1 3-3zM12 16.5s-4-2.6-4-5.2a2.2 2.2 0 0 1 4-1.2 2.2 2.2 0 0 1 4 1.2c0 2.6-4 5.2-4 5.2z", null),
        ["masks"] = ("M3.5 5.5c3-1.3 6-1.3 9 0v5c0 3-2 5.5-4.5 5.5S3.5 13.5 3.5 10.5zM11.5 9.5c3-1.3 6-1.3 9 0v5c0 3-2 5.5-4.5 5.5-1.5 0-2.9-.9-3.7-2.3M6.2 12.5c1 .8 2.6.8 3.6 0", null),
        ["sport"] = ("M4.5 5h15A1.5 1.5 0 0 1 21 6.5v11a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 17.5v-11A1.5 1.5 0 0 1 4.5 5zM12 5v14M3 9.5h2.5v5H3M21 9.5h-2.5v5H21" + Circle(12, 12, 2.6f), null),
        ["leaf"] = ("M5 19c0-8 5-13 15-14-1 10-6 15-14 15M5 19c3-4 6-7 10-9", null),
        ["newspaper"] = ("M4 5h12v14H6a2 2 0 0 1-2-2zM16 9h4v8a2 2 0 0 1-4 0M7 8h6M7 11h6M7 14h4", null),
    };

    private static readonly Dictionary<string, (SKPath? S, SKPath? F)> parsed = new();

    private static (SKPath? S, SKPath? F) Get(string name)
    {
        lock (parsed)
        {
            if (parsed.TryGetValue(name, out var p)) return p;
            var (s, f) = Paths.TryGetValue(name, out var d) ? d : Paths["cat.other"];
            p = (s is null ? null : SKPath.ParseSvgPathData(s), f is null ? null : SKPath.ParseSvgPathData(f));
            parsed[name] = p;
            return p;
        }
    }

    // (x, y) 왼쪽 위에 size 크기로
    public static void Draw(SKCanvas c, string name, float x, float y, float size, SKColor color, float strokeWidth = 1.9f, SKShader? shader = null)
    {
        var (s, f) = Get(name);
        c.Save();
        c.Translate(x, y);
        c.Scale(size / 24f);
        using var paint = new SKPaint { IsAntialias = true, Color = color, Shader = shader };
        if (f is not null) { paint.Style = SKPaintStyle.Fill; c.DrawPath(f, paint); }
        if (s is not null)
        {
            paint.Style = SKPaintStyle.Stroke;
            paint.StrokeWidth = strokeWidth;
            paint.StrokeCap = SKStrokeCap.Round;
            paint.StrokeJoin = SKStrokeJoin.Round;
            c.DrawPath(s, paint);
        }
        c.Restore();
    }
}
