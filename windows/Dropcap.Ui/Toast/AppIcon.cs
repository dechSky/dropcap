using SkiaSharp;

namespace Dropcap.Ui.Toast;

// 앱 아이콘(물방울, D-03)과 트레이 아이콘(신문, U-01)을 코드로 그린다. 맥 scripts/make-icon.swift 와 같은 그림.
public static class AppIcon
{
    // 1024 기준 좌표를 size 로 줄여 그린다(맥과 달리 y 는 아래로)
    public static SKBitmap Render(int size)
    {
        var bmp = new SKBitmap(new SKImageInfo(size, size, SKColorType.Rgba8888, SKAlphaType.Premul));
        using var c = new SKCanvas(bmp);
        c.Clear(SKColors.Transparent);
        c.Scale(size / 1024f);
        // 바탕: 둥근 사각형 + 깊은 남색 그라데이션
        var tile = new SKRect(100, 100, 924, 924);
        var rr = new SKRoundRect(tile, 185);
        using (var sh = new SKPaint { IsAntialias = true, ImageFilter = SKImageFilter.CreateDropShadowOnly(0, 12, 14, 14, new SKColor(0, 0, 0, 89)) })
            c.DrawRoundRect(rr, sh);
        c.Save();
        c.ClipRoundRect(rr, antialias: true);
        using (var bg = new SKPaint { IsAntialias = true })
        {
            bg.Shader = SKShader.CreateLinearGradient(new SKPoint(0, tile.Top), new SKPoint(0, tile.Bottom),
                [new SKColor(26, 33, 77), new SKColor(10, 13, 33)], SKShaderTileMode.Clamp);
            c.DrawRect(tile, bg);
        }
        // 물결 고리(맥 y=330 은 아래에서 → 위에서 694)
        foreach (var (r, a) in new[] { (300f, 0.10f), (225f, 0.16f) })
        {
            using var p = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Stroke, StrokeWidth = 10, Color = new SKColor(115, 191, 255, (byte)(a * 255)) };
            c.DrawOval(new SKRect(512 - r, 694 - r * 0.32f, 512 + r, 694 + r * 0.32f), p);
        }
        // 물방울: 아래는 원, 위는 뾰족(맥 cy=420 → 604, 꼭짓점 cy+R·2.25 → 604-393.75)
        const float cx = 512, cy = 604, R = 175;
        using var drop = new SKPath();
        drop.MoveTo(cx, cy - R * 2.25f);
        drop.CubicTo(cx + R * 0.35f, cy - R * 1.55f, cx + R, cy - R * 0.85f, cx + R, cy);
        drop.ArcTo(new SKRect(cx - R, cy - R, cx + R, cy + R), 0, 180, false);
        drop.CubicTo(cx - R, cy - R * 0.85f, cx - R * 0.35f, cy - R * 1.55f, cx, cy - R * 2.25f);
        drop.Close();
        using (var glow = new SKPaint { IsAntialias = true, Color = SKColors.White, ImageFilter = SKImageFilter.CreateDropShadow(0, 10, 20, 20, new SKColor(51, 153, 255, 153)) })
            c.DrawPath(drop, glow);
        c.Save();
        c.ClipPath(drop, antialias: true);
        using (var water = new SKPaint { IsAntialias = true })
        {
            water.Shader = SKShader.CreateLinearGradient(new SKPoint(cx - 120, cy - R * 2.2f), new SKPoint(cx + 120, cy + R),
                [new SKColor(140, 224, 255), new SKColor(41, 133, 255), new SKColor(46, 64, 242)], [0, 0.55f, 1], SKShaderTileMode.Clamp);
            c.DrawRect(new SKRect(0, 0, 1024, 1024), water);
        }
        // 반사광
        using (var hl = new SKPaint { IsAntialias = true, Color = new SKColor(255, 255, 255, 217) })
            c.DrawOval(SKRect.Create(cx - 105, 1024 - (420 + 40) - 78, 48, 78), hl);
        using (var hl2 = new SKPaint { IsAntialias = true, Color = new SKColor(255, 255, 255, 128) })
            c.DrawOval(SKRect.Create(cx - 92, 1024 - (420 - 18) - 22, 22, 22), hl2);
        c.Restore();
        // 위쪽 유리 반사
        using (var gloss = new SKPaint { IsAntialias = true })
        {
            gloss.Shader = SKShader.CreateLinearGradient(new SKPoint(0, tile.Top), new SKPoint(0, tile.MidY),
                [new SKColor(255, 255, 255, 26), new SKColor(255, 255, 255, 0)], SKShaderTileMode.Clamp);
            c.DrawRect(tile, gloss);
        }
        c.Restore();
        return bmp;
    }

    // 트레이 아이콘: 신문 모양, 안 읽은 소식이 있으면 채워진 모양(U-01). 작업 표시줄 색에 맞춰 흰색·검은색.
    public static SKBitmap Tray(int size, bool filled, SKColor color)
    {
        var bmp = new SKBitmap(new SKImageInfo(size, size, SKColorType.Bgra8888, SKAlphaType.Unpremul));
        using var c = new SKCanvas(bmp);
        c.Clear(SKColors.Transparent);
        c.Scale(size / 24f);
        using var body = SKPath.ParseSvgPathData("M4 5h12v14H6a2 2 0 0 1-2-2z");
        using var side = SKPath.ParseSvgPathData("M16 9h4v8a2 2 0 0 1-4 0");
        using var lines = SKPath.ParseSvgPathData("M7 8h6M7 11h6M7 14h4");
        using var stroke = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Stroke, StrokeWidth = 1.9f, StrokeCap = SKStrokeCap.Round, StrokeJoin = SKStrokeJoin.Round, Color = color };
        if (filled)
        {
            using var fill = new SKPaint { IsAntialias = true, Color = color };
            c.DrawPath(body, fill);
            c.DrawPath(body, stroke);
            c.DrawPath(side, stroke);
            using var clear = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Stroke, StrokeWidth = 1.7f, StrokeCap = SKStrokeCap.Round, BlendMode = SKBlendMode.Clear };
            c.DrawPath(lines, clear);
        }
        else
        {
            c.DrawPath(body, stroke);
            c.DrawPath(side, stroke);
            c.DrawPath(lines, stroke);
        }
        return bmp;
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
