using System.Text.Json;
using System.Text.Json.Serialization;
using SkiaSharp;

namespace Dropcap.Ui.Toast;

// 앱 아이콘(③ 매거진 표지, D-03)과 트레이 아이콘(표지 상징, U-01)을 shared/icon.json(세 판 공통 도형)으로 그린다.
// 맥 IconArt.swift·리눅스 SVG 와 같은 도형. 좌표는 y 아래로, 패스는 절대 M L H V C Z.
public static class AppIcon
{
    public sealed record Gradient(double[] From, double[] To, string[] Stops);
    public sealed record Layer(string D, string? Fill, double? Opacity, Gradient? Gradient, bool? Evenodd, double[]? Rotate);
    public sealed record Shadow(double Dy, double Sigma, double Opacity);
    public sealed record Variant(string? Tile, Shadow? Shadow, Layer[] Layers);
    public sealed record Symbol(double Size, Layer[] Read, Layer[] Unread);
    public sealed record Doc(Variant App, Variant Small, int SmallMax, Symbol Symbol);

    // 앱 안에 넣은 shared/icon.json(Dropcap.Ui.csproj 의 EmbeddedResource)
    public static Doc Art => art ??= Load();
    private static Doc? art;
    private static Doc Load()
    {
        using var s = typeof(AppIcon).Assembly.GetManifestResourceStream("Dropcap.icon.json") ?? throw new InvalidDataException("icon.json 이 없음");
        return JsonSerializer.Deserialize<Doc>(s, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase })
            ?? throw new InvalidDataException("icon.json 을 읽지 못함");
    }

    // 앱 아이콘 한 장: SmallMax(32) 이하는 단순화 판(기울기·그림자·제호 띠 없이 D 를 크게)
    public static SKBitmap Render(int size)
    {
        var bmp = new SKBitmap(new SKImageInfo(size, size, SKColorType.Rgba8888, SKAlphaType.Premul));
        using var c = new SKCanvas(bmp);
        c.Clear(SKColors.Transparent);
        var v = size <= Art.SmallMax ? Art.Small : Art.App;
        Draw(c, v.Layers, v.Tile, v.Shadow, size / 1024f, null);
        return bmp;
    }

    // 트레이 아이콘: 표지 윤곽 안 D + 글줄, 안 읽은 소식이 있으면 채워진 표지에서 글자가 빠짐(U-01). 작업 표시줄 색에 맞춰 흰색·검은색.
    public static SKBitmap Tray(int size, bool filled, SKColor color)
    {
        var bmp = new SKBitmap(new SKImageInfo(size, size, SKColorType.Bgra8888, SKAlphaType.Unpremul));
        using var c = new SKCanvas(bmp);
        c.Clear(SKColors.Transparent);
        Draw(c, filled ? Art.Symbol.Unread : Art.Symbol.Read, null, null, size / (float)Art.Symbol.Size, color);
        return bmp;
    }

    public static SKColor Color(string hex, double alpha = 1)
    {
        var v = Convert.ToUInt32(hex.TrimStart('#'), 16);
        return new SKColor((byte)(v >> 16), (byte)(v >> 8), (byte)v, (byte)Math.Round(alpha * 255));
    }

    private static void Draw(SKCanvas c, Layer[] layers, string? tile, Shadow? shadow, float scale, SKColor? tint)
    {
        c.Save();
        c.Scale(scale);
        using var tilePath = tile is null ? null : SKPath.ParseSvgPathData(tile);
        if (tilePath is not null && shadow is not null)
        {
            using var sh = new SKPaint { IsAntialias = true, ImageFilter = SKImageFilter.CreateDropShadowOnly(0, (float)shadow.Dy, (float)shadow.Sigma, (float)shadow.Sigma, new SKColor(0, 0, 0, (byte)Math.Round(shadow.Opacity * 255))) };
            c.DrawPath(tilePath, sh);
        }
        c.Save();
        if (tilePath is not null) c.ClipPath(tilePath, antialias: true);
        foreach (var l in layers)
        {
            using var p = SKPath.ParseSvgPathData(l.D);
            p.FillType = l.Evenodd == true ? SKPathFillType.EvenOdd : SKPathFillType.Winding;
            using var paint = new SKPaint { IsAntialias = true };
            if (l.Gradient is { } g && tint is null)
                paint.Shader = SKShader.CreateLinearGradient(new SKPoint((float)g.From[0], (float)g.From[1]), new SKPoint((float)g.To[0], (float)g.To[1]),
                    g.Stops.Select(x => Color(x)).ToArray(), SKShaderTileMode.Clamp);
            else
                paint.Color = tint ?? Color(l.Fill ?? "#000000", l.Opacity ?? 1);
            c.Save();
            if (l.Rotate is { Length: 3 } r) c.RotateDegrees((float)r[0], (float)r[1], (float)r[2]);
            c.DrawPath(p, paint);
            c.Restore();
        }
        c.Restore();
        c.Restore();
    }

    // .ico 파일(PNG 를 담은 여러 크기)
    public static byte[] Ico(params int[] sizes)
    {
        var pngs = sizes.Select(s =>
        {
            using var b = Render(s);
            using var img = SKImage.FromBitmap(b);
            using var d = img.Encode(SKEncodedImageFormat.Png, 100);
            return d.ToArray();
        }).ToList();
        using var ms = new MemoryStream();
        using var w = new BinaryWriter(ms);
        w.Write((short)0); w.Write((short)1); w.Write((short)sizes.Length);
        var offset = 6 + 16 * sizes.Length;
        for (var i = 0; i < sizes.Length; i++)
        {
            w.Write((byte)(sizes[i] >= 256 ? 0 : sizes[i])); w.Write((byte)(sizes[i] >= 256 ? 0 : sizes[i]));
            w.Write((byte)0); w.Write((byte)0); w.Write((short)1); w.Write((short)32);
            w.Write(pngs[i].Length); w.Write(offset);
            offset += pngs[i].Length;
        }
        foreach (var p in pngs) w.Write(p);
        w.Flush();
        return ms.ToArray();
    }
}
