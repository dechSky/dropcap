using Dropcap.Core;
using SkiaSharp;

namespace Dropcap.Ui.Toast;

// 알림 창 한 장면을 그린다(투명 바탕 + 카드들 + 떨어지는 물방울). 맥 ToastView·DripView(canvasBody)·WaterFill 과 같은 크기·색·움직임.
// 윈도우 앱은 이 그림을 레이어드 창(UpdateLayeredWindow)에 그대로 올린다(N-21·N-22).
public sealed class ToastRenderer(ToastEngine engine)
{
    public bool Dark { get; set; }
    public Func<string, SKImage?> Image { get; set; } = _ => null;   // 사진(안전 로더가 이미 받아 둔 것)
    public Func<string, string> CategoryOf { get; set; } = _ => "other";

    // MARK: 색
    private static SKColor Hex(string hex) { var (r, g, b) = Dropcap.Core.Hex.Parse(hex); return new SKColor(r, g, b); }
    private static SKColor Mix(SKColor a, SKColor b, float t) => new(
        (byte)(a.Red + (b.Red - a.Red) * t), (byte)(a.Green + (b.Green - a.Green) * t), (byte)(a.Blue + (b.Blue - a.Blue) * t), a.Alpha);
    private static SKColor A(SKColor c, double alpha) => c.WithAlpha((byte)Math.Clamp(alpha * 255, 0, 255));
    private SKColor Primary => Dark ? new SKColor(255, 255, 255, 235) : new SKColor(0, 0, 0, 225);
    private SKColor Secondary => Dark ? new SKColor(235, 235, 245, 153) : new SKColor(60, 60, 67, 153);
    private SKColor Tertiary => Dark ? new SKColor(235, 235, 245, 77) : new SKColor(60, 60, 67, 77);
    private SKColor Glass => Dark ? new SKColor(38, 38, 42, 232) : new SKColor(250, 250, 252, 235);
    private static readonly SKColor Orange = new(255, 149, 0);
    private SKColor CatColor(NewsCategory c) => Hex(c.Color().For(Dark));

    // MARK: 재기
    private const float PadL = 14, PadR = 16, PadT = 14, PadB = 15, Mono = 38, Gap = 12, ThumbSize = 58;
    private const float MetaH = 15, TitleSize = 14.5f, TitleLH = 19.6f, OrigLH = 15.5f;

    private static SKFont Font(float size, int weight, string sample = "") => new(Fonts.ForText(sample, weight), size) { Subpixel = true, Edging = SKFontEdging.Antialias };

    private float TextWidth(ToastCard c) =>
        ToastEngine.CardWidth - PadL - PadR - Mono - Gap - (c.Thumb is not null ? ThumbSize + Gap : 0);

    public float Measure(ToastCard c)
    {
        switch (c.Kind)
        {
            case ToastKind.News:
                var it = c.Item!;
                using (var tf = Font(TitleSize, 600, it.DisplayTitle))
                {
                    var lines = TextLayout.Wrap(it.DisplayTitle, tf, TextWidth(c), 2).Count;
                    var text = MetaH + 3 + lines * TitleLH + (HasOriginal(it) ? 3 + OrigLH : 0);
                    return PadT + Math.Max(Math.Max(Mono, text), c.Thumb is not null ? ThumbSize : 0) + PadB;
                }
            case ToastKind.Info:
                using (var sf = Font(12, 400, c.Sub))
                {
                    var lines = Math.Max(1, TextLayout.Wrap(c.Sub, sf, InfoTextWidth, 2).Count);
                    return 12 + Math.Max(30, 17 + 2 + lines * 15.5f) + 12;
                }
            case ToastKind.Digest: return 12 + Math.Max(30, 17 + 2 + 15.5f) + 12;
            case ToastKind.Bundle or ToastKind.Watch: return 12 + Math.Max(30, 17 + 2 + Math.Min(2, Math.Max(1, c.Items.Count)) * 15.5f) + 12;
            default: return 10 + 16 + 10;
        }
    }

    private const float InfoTextWidth = ToastEngine.CardWidth - 13 - 16 - 30 - 11;
    private static bool HasOriginal(NewsItem it) => it.TitleKo is not null && it.TitleKo != it.Title;

    // MARK: 장면
    public void Render(SKCanvas canvas, double now, float scale)
    {
        canvas.Clear(SKColors.Transparent);
        canvas.Save();
        canvas.Scale(scale);
        // 아래 카드부터 그려 위 카드가 위에 오게
        foreach (var c in engine.Cards.Reverse()) DrawCard(canvas, c, now);
        canvas.Restore();
    }

    public SKBitmap RenderBitmap(double now, float scale)
    {
        var bmp = new SKBitmap(new SKImageInfo((int)Math.Ceiling(ToastEngine.PanelWidth * scale), (int)Math.Ceiling(ToastEngine.PanelHeight * scale),
            SKColorType.Bgra8888, SKAlphaType.Premul));
        using var canvas = new SKCanvas(bmp);
        Render(canvas, now, scale);
        return bmp;
    }

    // 시간에 따른 값들
    private static double EaseOut(double x) { x = Math.Clamp(x, 0, 1); return 1 - Math.Pow(1 - x, 3); }
    private static double EaseIn(double x) { x = Math.Clamp(x, 0, 1); return x * x * x; }
    private static double EaseInOut(double x) { x = Math.Clamp(x, 0, 1); return x < 0.5 ? 4 * x * x * x : 1 - Math.Pow(-2 * x + 2, 3) / 2; }
    private static double SpringIn(double t, double response) { if (t <= 0) return 0; var w = 2 * Math.PI / response; return 1 - (1 + w * t) * Math.Exp(-w * t); }

    private readonly record struct Look(double Alpha, double Shadow, double Scale, double SquashY, double Develop, double LeaveK);

    private Look LookAt(ToastCard c, double now)
    {
        double alpha, shadow, scale = 1, squash = 1, develop, leave = 0;
        if (engine.ReduceMotion)
        {
            alpha = EaseOut((now - c.Born) / 0.2);
            shadow = alpha;
            develop = 1;
        }
        else
        {
            var t0 = c.Born + 0.03;
            alpha = EaseOut((now - t0) / 0.5);
            shadow = 0.6 * EaseOut((now - t0) / 0.5);
            if (now >= c.RevealAt) shadow = 0.6 + 0.4 * EaseOut((now - c.RevealAt) / 0.4);
            develop = now >= c.Land ? EaseInOut((now - c.Land) / 2.0) : 0;
            // 닿는 순간 잔이 살짝 눌렸다 돌아옴(N-04)
            var tau = now - c.Land;
            if (tau >= 0 && tau < 0.09) squash = 1 - 0.015 * Math.Sin(tau / 0.09 * Math.PI / 2);
            else if (tau >= 0.09 && tau < 1) squash = 1 - 0.015 * Math.Exp(-(tau - 0.09) * 9) * Math.Cos((tau - 0.09) * 20);
        }
        if (c.LeaveStart is { } ls)
        {
            // 카드만 조용히 사라진다: 살짝 작아지며 흐려지고 투명해짐(N-09)
            leave = Math.Clamp((now - ls) / engine.LeaveDuration(c), 0, 1);
            var k = engine.ReduceMotion ? EaseOut(leave) : EaseIn(leave);
            alpha *= 1 - k;
            shadow *= 1 - k;
            if (!engine.ReduceMotion) scale = 1 - 0.04 * k;
        }
        return new Look(alpha, shadow, scale, squash, develop, leave);
    }

    // 글자 떠오름(맥 Rise: 0.14 + 0.045·i 뒤 용수철 0.4) — 사라질 때는 0.1초에 빠르게
    private double Rise(ToastCard c, double now, int index)
    {
        if (c.LeaveStart is { } ls) return Math.Max(0, 1 - (now - ls) / (0.12 * (c.LeaveQuick ? 0.6 : 1))) * Rise0(c, ls, index);
        return Rise0(c, now, index);
    }

    private double Rise0(ToastCard c, double now, int index) =>
        engine.ReduceMotion ? EaseOut((now - c.Born) / 0.2) : SpringIn(now - c.RevealAt - 0.14 - index * 0.045, 0.4);

    private void DrawCard(SKCanvas canvas, ToastCard c, double now)
    {
        var look = LookAt(c, now);
        var left = (ToastEngine.PanelWidth - ToastEngine.CardWidth) / 2;
        var top = c.Y;
        var w = ToastEngine.CardWidth;
        var h = c.Height;
        var hover = c.Hover;
        var sx = (float)(look.Scale * (1 + 0.012 * hover));
        var sy = (float)(look.Scale * look.SquashY * (1 + 0.012 * hover));
        var rect = new SKRect(left, top, left + w, top + h);
        var rr = new SKRoundRect(rect, 20);
        var accent = Hex(c.Accent);

        if (look.Alpha > 0.002)
        {
            canvas.Save();
            canvas.Scale(sx, sy, left + w / 2, top);
            using (var layer = new SKPaint { Color = SKColors.White.WithAlpha((byte)(255 * Math.Clamp(look.Alpha, 0, 1))) })
            {
                canvas.SaveLayer(layer);
                // 그림자(마우스를 올리면 짙어짐)
                var sh = (Dark ? 0.5 : 0.2) * look.Shadow * (1 + 0.35 * hover);
                using (var sp = new SKPaint { IsAntialias = true, Color = SKColors.Black.WithAlpha(1) })
                {
                    var r = 16 + 6 * hover;
                    sp.ImageFilter = SKImageFilter.CreateDropShadowOnly(0, 8 + 4 * hover, r / 2, r / 2, A(SKColors.Black, sh));
                    canvas.DrawRoundRect(rr, sp);
                    sp.ImageFilter = SKImageFilter.CreateDropShadowOnly(0, 1, 1, 1, A(SKColors.Black, 0.08 * look.Shadow));
                    canvas.DrawRoundRect(rr, sp);
                }
                canvas.Save();
                canvas.ClipRoundRect(rr, antialias: true);
                using (var gp = new SKPaint { IsAntialias = true, Color = Glass }) canvas.DrawRect(rect, gp);
                // 카드 바탕에 출처 색이 아주 살짝
                using (var tp = new SKPaint { Color = A(accent, 0.05) }) canvas.DrawRect(rect, tp);
                if (!engine.ReduceMotion && now >= c.Land) DrawWater(canvas, rect, accent, now - c.Land, Remaining(c, now));
                DrawContent(canvas, c, rect, now, look.Develop);
                if (c.Kind == ToastKind.News) DrawQuick(canvas, c, rect, hover);
                canvas.Restore();
                // 테두리
                using (var bp = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Stroke, StrokeWidth = 0.5f, Color = Dark ? new SKColor(255, 255, 255, 30) : new SKColor(0, 0, 0, 20) })
                    canvas.DrawRoundRect(rr, bp);
                canvas.Restore();
            }
            canvas.Restore();
        }
        DrawClose(canvas, c, left, top, hover);
        if (!engine.ReduceMotion && now >= c.DripStart && now < c.Land + 0.79)
            DrawDrip(canvas, now - c.DripStart, left + w / 2, top - ToastEngine.Top, c.LandY, Mix(accent, SKColors.White, 0.18f));
    }

    // 남은 시간(가득 찬 뒤 물이 천천히 빠짐)(N-07)
    private static double Remaining(ToastCard c, double now) => Math.Clamp((c.Deadline - now) / ToastEngine.Lifetime, 0, 1);

    // MARK: 물(N-03)
    private static void DrawWater(SKCanvas canvas, SKRect r, SKColor color, double e, double level)
    {
        var w = r.Width;
        var h = r.Height;
        var filling = e < WaterFill.FillTime;
        var fill = WaterFill.FillLevel(e);
        var lvl = (float)(filling ? fill : Math.Min(fill, level));
        var amp = (float)WaterFill.Amplitude(e);
        var tilt = (float)WaterFill.Tilt(e);
        var alpha = WaterFill.Alpha(e);
        canvas.Save();
        canvas.Translate(r.Left, r.Top);

        SKPath Wave(double phase, float length, float ampScale)
        {
            var p = new SKPath();
            var b = h * (1 - lvl);
            p.MoveTo(0, h);
            for (float x = 0; x <= w + 4; x += 4)
                p.LineTo(x, b + amp * ampScale * (float)Math.Sin(x / length * 2 * Math.PI + phase) + tilt * (x - w / 2));
            p.LineTo(w, h);
            p.Close();
            return p;
        }

        // 뒷물결(옅게, 엇박자) + 앞물결
        using (var back = Wave(e * 2.4 + 1.7, w * 0.62f, 0.8f))
        using (var p = new SKPaint { IsAntialias = true, Color = A(color, alpha * 0.5) })
            canvas.DrawPath(back, p);
        using (var front = Wave(e * 3.2, w * 0.48f, 1))
        using (var p = new SKPaint { IsAntialias = true })
        {
            p.Shader = SKShader.CreateLinearGradient(new SKPoint(0, h * (1 - lvl)), new SKPoint(0, h),
                [A(Mix(color, SKColors.White, 0.35f), alpha), A(color, Math.Min(1, alpha * 1.1))], SKShaderTileMode.Clamp);
            canvas.DrawPath(front, p);
        }
        // 물 표면의 반짝이는 선
        if (lvl > 0.02 && lvl < 0.995)
        {
            using var s = new SKPath();
            var b = h * (1 - lvl);
            for (float x = 0; x <= w + 4; x += 4)
            {
                var y = b + amp * (float)Math.Sin(x / (w * 0.48) * 2 * Math.PI + e * 3.2) + tilt * (x - w / 2);
                if (x == 0) s.MoveTo(x, y); else s.LineTo(x, y);
            }
            using var p = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Stroke, StrokeWidth = 1, Color = A(SKColors.White, 0.55 * alpha / 0.5) };
            canvas.DrawPath(s, p);
        }
        // 바닥에 닿을 때 튀어 오르는 작은 물방울
        if (e < 0.42)
        {
            const double g = 900;
            using var p = new SKPaint { IsAntialias = true, Color = A(Mix(color, SKColors.White, 0.3f), 0.75 * (1 - e / 0.42)) };
            foreach (var (vx, vy, rad) in WaterFill.Splashes)
            {
                var x = w / 2 + (float)(vx * e);
                var y = h - (float)(vy * e - 0.5 * g * e * e) - 2;
                if (y < h) canvas.DrawCircle(x, y, rad, p);
            }
        }
        // 물속에서 올라오는 작은 거품
        if (e > 0.12 && e < 1.6)
        {
            var top = h * (1 - lvl);
            using var p = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Stroke, StrokeWidth = 0.8f, Color = A(SKColors.White, 0.6 * (1 - WaterFill.Smooth((e - 1.1) / 0.5))) };
            foreach (var b in WaterFill.Bubbles)
            {
                if (e <= b.Delay) continue;
                var k = e - b.Delay;
                var y = h - 4 - b.Speed * (float)k;
                if (y <= top + 3) continue;
                var x = b.X * w + (float)Math.Sin(k * 9 + b.X * 10) * 2;
                canvas.DrawCircle(x, y, b.R, p);
            }
        }
        canvas.Restore();
    }

    // MARK: 물방울(N-01·N-02): 흐림 + 문턱값 액체 + 반사광 두 점
    private static void DrawDrip(SKCanvas canvas, double t, float cx, float ceiling, float landY, SKColor color)
    {
        var s = Drip.State(t, landY);
        canvas.Save();
        canvas.Translate(cx, ceiling);
        // 흐리게 그린 덩어리를 알파 문턱값(0.5)으로 또렷하게 잘라 서로 가까운 덩어리가 액체처럼 이어지게
        var threshold = SKColorFilter.CreateColorMatrix([
            0, 0, 0, 0, color.Red / 255f,
            0, 0, 0, 0, color.Green / 255f,
            0, 0, 0, 0, color.Blue / 255f,
            0, 0, 0, 24, -12,
        ]);
        using (var layer = new SKPaint { ImageFilter = SKImageFilter.CreateColorFilter(threshold, SKImageFilter.CreateBlur(4.5f, 4.5f)) })
        {
            canvas.SaveLayer(new SKRect(-Drip.Width, -20, Drip.Width, landY + Drip.DropRadius * 3), layer);
            using var blob = new SKPaint { IsAntialias = true, Color = SKColors.Black };
            if (s.Film > 0) canvas.DrawOval(new SKRect(-22 * s.Film, -7, 22 * s.Film, 5), blob);
            if (s.BeadR > 0.5f) canvas.DrawOval(new SKRect(-s.BeadR * 1.15f, -s.BeadR * 0.35f, s.BeadR * 1.15f, s.BeadR * 1.25f), blob);
            if (s.Neck > 0.3f)
            {
                var top = s.BeadR * 0.8f;
                var bottom = s.DropY - s.DropR * 0.6f;
                if (bottom > top) canvas.DrawRoundRect(new SKRect(-s.Neck, top, s.Neck, bottom), s.Neck, s.Neck, blob);
            }
            if (s.DropR > 0.5f)
            {
                var w = s.DropR * 2 / MathF.Sqrt(s.Stretch);
                var h = s.DropR * 2 * s.Stretch;
                canvas.DrawOval(new SKRect(-w / 2, s.DropY - h / 2, w / 2, s.DropY + h / 2), blob);
            }
            if (s.SatR > 0.5f) canvas.DrawCircle(0, s.SatY, s.SatR, blob);
            canvas.Restore();
        }
        threshold.Dispose();
        // 반사광(액체 위에 덧그림)
        if (s.DropR > 6)
        {
            var r = s.DropR;
            var hx = -r * 0.38f / MathF.Sqrt(s.Stretch);
            var hy = s.DropY - r * 0.35f * s.Stretch;
            using var p = new SKPaint { IsAntialias = true, Color = A(SKColors.White, 0.75) };
            canvas.DrawOval(new SKRect(hx - 2.6f, hy - 3.4f, hx + 2.6f, hy + 3.4f), p);
            p.Color = A(SKColors.White, 0.35);
            canvas.DrawCircle(r * 0.3f, s.DropY + r * 0.35f * s.Stretch, 1.2f, p);
        }
        canvas.Restore();
    }

    // MARK: 내용(N-05)
    private void DrawText(SKCanvas c, string text, float x, float baseline, float size, int weight, SKColor color, double rise)
    {
        if (rise <= 0.001) return;
        using var font = Font(size, weight, text);
        using var p = new SKPaint { IsAntialias = true, Color = color.WithAlpha((byte)(color.Alpha * Math.Clamp(rise, 0, 1))) };
        var dy = (float)(5 * (1 - rise));
        if (rise < 0.98) p.ImageFilter = SKImageFilter.CreateBlur((float)(3 * (1 - rise)) / 2, (float)(3 * (1 - rise)) / 2);
        c.DrawText(text, x, baseline + dy, SKTextAlign.Left, font, p);
    }

    private void DrawContent(SKCanvas c, ToastCard card, SKRect r, double now, double develop)
    {
        switch (card.Kind)
        {
            case ToastKind.News: DrawNews(c, card, r, now, develop); break;
            case ToastKind.Info:
                DrawBadge(c, r.Left + 13, r.Top + (r.Height - 30) / 2, "sparkles", new SKColor(50, 173, 230), new SKColor(0, 122, 255), Rise(card, now, 0));
                DrawTwoLines(c, card, r, card.Title, card.Sub, now);
                break;
            case ToastKind.Digest:
                DrawBadge(c, r.Left + 13, r.Top + (r.Height - 30) / 2, "sun.horizon", Orange, new SKColor(255, 45, 85), Rise(card, now, 0));
                DrawTwoLines(c, card, r, Strings.Digest, Strings.DigestSub(card.Count), now);
                break;
            case ToastKind.Bundle:
            {
                var sec = Sections.ById(card.Section);
                var color = Hex(sec?.Color ?? card.Accent);
                DrawBadge(c, r.Left + 13, r.Top + (r.Height - 30) / 2, sec?.Icon ?? "cat.other", Mix(color, SKColors.White, 0.2f), color, Rise(card, now, 0));
                DrawBundleLines(c, card, r, Strings.Bundle(card.Section ?? "", card.Count), card.Items.Take(2).Select(i => i.DisplayTitle).ToList(), now);
                break;
            }
            case ToastKind.Watch:
            {
                var teal = Hex(ToastEngine.WatchAccent);
                DrawBadge(c, r.Left + 13, r.Top + (r.Height - 30) / 2, "eye", Mix(teal, SKColors.White, 0.2f), teal, Rise(card, now, 0));
                DrawBundleLines(c, card, r, Strings.Watch(card.Title, card.Count), card.Items.Take(2).Select(i => i.DisplayTitle).ToList(), now);
                using (var hf = Font(11, 400, Strings.WatchHint))
                    DrawText(c, Strings.WatchHint, r.Right - 16 - hf.MeasureText(Strings.WatchHint), r.Top + 12 + 13, 11, 400, Tertiary, Rise(card, now, 1));
                break;
            }
            default:
                // "○○ 소식 N건 더 · 트레이 아이콘에서 확인"(N건은 강조색)
                var rise = Rise(card, now, 0);
                using (var f = Font(12.5f, 600, "가"))
                {
                    var a = Strings.MoreCard + " "; var b = $"{card.Count}건"; var d = " 더 · " + Strings.TrayHint;
                    var total = f.MeasureText(a) + f.MeasureText(b) + f.MeasureText(d);
                    var x = r.MidX - total / 2;
                    var y = r.Top + 10 + 12.5f;
                    DrawText(c, a, x, y, 12.5f, 600, Primary, rise); x += f.MeasureText(a);
                    DrawText(c, b, x, y, 12.5f, 600, Hex(Dark ? "#0A84FF" : "#007AFF"), rise); x += f.MeasureText(b);
                    DrawText(c, d, x, y, 12.5f, 600, Primary, rise);
                }
                break;
        }
    }

    private void DrawTwoLines(SKCanvas c, ToastCard card, SKRect r, string title, string sub, double now)
    {
        var x = r.Left + 13 + 30 + 11;
        using var sf = Font(12, 400, sub);
        var lines = TextLayout.Wrap(sub, sf, InfoTextWidth, 2);
        var blockH = 17 + 2 + Math.Max(1, lines.Count) * 15.5f;
        var y = r.Top + (r.Height - blockH) / 2;
        DrawText(c, TextLayout.Ellipsize(title, sf, InfoTextWidth + 40), x, y + 13.5f, 13.5f, 600, Primary, Rise(card, now, 1));
        for (var i = 0; i < lines.Count; i++) DrawText(c, lines[i], x, y + 19 + 12 + i * 15.5f, 12, 400, Secondary, Rise(card, now, 2));
    }

    // 묶음 카드: 제목 + 기사 제목 한 줄씩(최대 2줄)
    private void DrawBundleLines(SKCanvas c, ToastCard card, SKRect r, string title, List<string> titles, double now)
    {
        var x = r.Left + 13 + 30 + 11;
        using var sf = Font(12, 400, string.Concat(titles));
        var n = Math.Max(1, titles.Count);
        var blockH = 17 + 2 + n * 15.5f;
        var y = r.Top + (r.Height - blockH) / 2;
        DrawText(c, title, x, y + 13.5f, 13.5f, 600, Primary, Rise(card, now, 1));
        for (var i = 0; i < titles.Count; i++)
            DrawText(c, TextLayout.Ellipsize("· " + titles[i], sf, InfoTextWidth), x, y + 19 + 12 + i * 15.5f, 12, 400, Secondary, Rise(card, now, 2 + i));
    }

    private void DrawBadge(SKCanvas c, float x, float y, string icon, SKColor from, SKColor to, double rise)
    {
        if (rise <= 0.001) return;
        c.Save();
        c.Translate(0, (float)(5 * (1 - rise)));
        using (var bg = new SKPaint { IsAntialias = true, Color = A(to, 0.12 * rise) }) c.DrawCircle(x + 15, y + 15, 15, bg);
        using var shader = SKShader.CreateLinearGradient(new SKPoint(0, 7.5f), new SKPoint(0, 22.5f), [A(from, rise), A(to, rise)], SKShaderTileMode.Clamp);
        Icons.Draw(c, icon, x + 7.5f, y + 7.5f, 15, SKColors.White, 2, shader);
        c.Restore();
    }

    private void DrawNews(SKCanvas c, ToastCard card, SKRect r, double now, double develop)
    {
        var it = card.Item!;
        var accent = Hex(card.Accent);
        var x0 = r.Left + PadL;
        var y0 = r.Top + PadT;
        // 출처 글자 원형(모노그램)
        DrawMonogram(c, x0, y0, Mono, it.Initial, accent, Rise(card, now, 0));
        var tx = x0 + Mono + Gap;
        var tw = TextWidth(card);
        // 머리 줄: ★ · 출처명 · 분야 칩 · 외 N곳 ……… 몇 분 전
        var rise1 = Rise(card, now, 1);
        var mx = tx;
        var by = y0 + 11.5f;
        if (it.Important == true)
        {
            if (rise1 > 0) Icons.Draw(c, "star.fill", mx, by - 9.5f, 10.5f, A(Orange, rise1));
            mx += 10.5f + 6;
        }
        var time = RelativeTime.Format(it.Date);
        using var timeFont = Font(11, 400, time);
        var timeW = timeFont.MeasureText(time);
        // 칩·'외 N곳'은 줄지 않게(좁으면 출처 이름이 먼저 줄어든다 — 예전엔 칩이 밀려 잘렸다, 맥 e2e-fix)
        var chipW = ChipWidth(it.TopicLabel());
        var more = it.Related is { Count: > 0 } rel ? $"외 {rel.Count}곳" : null;
        float moreW = 0;
        if (more is not null) using (var mf = Font(10.5f, 500, more)) moreW = mf.MeasureText(more) + 6;
        // 유료 자물쇠(G-14): 맛보기로 판정되면(미리 받기) 잠긴 자물쇠 + '앞부분만'(주황) — 맥 ToastView 의 PaywallMark
        var pw = it.ItemKind == ItemKind.Article && it.Link.Length > 0 ? PaywallBook.Loaded?.Kind(it) : null;
        var pwText = pw?.ShortText();
        float pwW = 0;
        if (pw is not null)
        {
            pwW = 9 + 4;
            if (pwText is not null) using (var pf = Font(9.5f, 600, pwText)) pwW += 2 + pf.MeasureText(pwText);
        }
        using (var sf = Font(11.5f, 600, it.SourceName))
        {
            var room = tx + tw - timeW - 4 - mx - 6 - chipW - 6 - moreW - pwW;
            var name = TextLayout.Ellipsize(it.SourceName, sf, Math.Max(24, room));
            DrawText(c, name, mx, by, 11.5f, 600, Primary, rise1);
            mx += sf.MeasureText(name) + 4;
        }
        if (pw is { } k)
        {
            var col = k == PaywallKind.Teaser ? Orange : Secondary;
            if (rise1 > 0) Icons.Draw(c, k == PaywallKind.Metered ? "lock.open" : "lock.fill", mx, by - 8.5f, 9, A(col, rise1 * col.Alpha / 255.0));
            mx += 9 + 2;
            if (pwText is not null)
            {
                DrawText(c, pwText, mx, by, 9.5f, 600, col, rise1);
                using var pf = Font(9.5f, 600, pwText);
                mx += pf.MeasureText(pwText);
            }
        }
        mx += 2;
        mx += DrawChip(c, it.TopicLabel(), it.TopicIcon(), Hex(it.TopicColor().For(Dark)), mx, y0, rise1) + 6;
        if (more is not null) DrawText(c, more, mx, by, 10.5f, 500, Secondary, rise1);
        DrawText(c, time, tx + tw - timeW, by, 11, 400, Tertiary, rise1);
        // 한국어 제목(2줄) · 원제목(1줄)
        var ty = y0 + MetaH + 3;
        using (var tf = Font(TitleSize, 600, it.DisplayTitle))
        {
            var lines = TextLayout.Wrap(it.DisplayTitle, tf, tw, 2);
            for (var i = 0; i < lines.Count; i++) DrawText(c, lines[i], tx, ty + 14.5f + i * TitleLH, TitleSize, 600, Primary, Rise(card, now, 2));
            ty += lines.Count * TitleLH;
        }
        if (HasOriginal(it))
            using (var of = Font(12, 400, it.Title))
                DrawText(c, TextLayout.Ellipsize(it.Title, of, tw), tx, ty + 3 + 12, 12, 400, Secondary, Rise(card, now, 3));
        // 사진 인화: 회색·흐림 → 선명한 색(2초)(N-06)
        if (card.Thumb is { } url)
        {
            var rect = SKRect.Create(r.Right - PadR - ThumbSize, y0, ThumbSize, ThumbSize);
            DrawThumb(c, rect, Image(url), it.Category, accent, develop);
        }
    }

    // 분야 칩(N-05): 분야 이름, AI 분야 글은 'AI·모델'처럼 하위 분류까지
    private float ChipWidth(string label)
    {
        using var f = Font(10.5f, 600, label);
        return 6 + 10.5f + 3 + f.MeasureText(label) + 6;
    }

    private float DrawChip(SKCanvas c, string label, string icon, SKColor color, float x, float top, double rise)
    {
        using var f = Font(10.5f, 600, label);
        var w = ChipWidth(label);
        if (rise <= 0.001) return w;
        c.Save();
        c.Translate(0, (float)(5 * (1 - rise)));
        using (var bg = new SKPaint { IsAntialias = true, Color = A(color, 0.13 * rise) })
            c.DrawRoundRect(new SKRect(x, top + 0.5f, x + w, top + 15), 5, 5, bg);
        Icons.Draw(c, icon, x + 6, top + 2.5f, 10.5f, A(color, rise), 2.2f);
        using (var p = new SKPaint { IsAntialias = true, Color = A(color, rise) })
            c.DrawText(label, x + 6 + 10.5f + 3, top + 11.5f, SKTextAlign.Left, f, p);
        c.Restore();
        return w;
    }

    private static void DrawMonogram(SKCanvas c, float x, float y, float size, string letter, SKColor color, double rise)
    {
        if (rise <= 0.001) return;
        c.Save();
        c.Translate(0, (float)(5 * (1 - rise)));
        var rect = SKRect.Create(x, y, size, size);
        var rr = new SKRoundRect(rect, size * 0.29f);
        using (var sp = new SKPaint { IsAntialias = true, ImageFilter = SKImageFilter.CreateDropShadowOnly(0, 2, 1.5f, 1.5f, A(color, 0.35 * rise)) })
            c.DrawRoundRect(rr, sp);
        using (var p = new SKPaint { IsAntialias = true })
        {
            p.Shader = SKShader.CreateLinearGradient(new SKPoint(x, y), new SKPoint(x + size, y + size),
                [A(Mix(color, SKColors.White, 0.18f), rise), A(color, rise), A(Mix(color, SKColors.Black, 0.15f), rise)], [0, 0.5f, 1], SKShaderTileMode.Clamp);
            c.DrawRoundRect(rr, p);
        }
        using (var s = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Stroke, StrokeWidth = 0.5f, Color = A(SKColors.White, 0.22 * rise) })
            c.DrawRoundRect(rr, s);
        using var f = new SKFont(Fonts.Get(700), size * 0.45f) { Subpixel = true };
        using var tp = new SKPaint { IsAntialias = true, Color = A(SKColors.White, rise) };
        f.MeasureText(letter, out var b);
        c.DrawText(letter, x + size / 2, y + size / 2 - b.MidY, SKTextAlign.Center, f, tp);
        c.Restore();
    }

    private void DrawThumb(SKCanvas c, SKRect rect, SKImage? img, NewsCategory cat, SKColor accent, double developed)
    {
        var d = (float)Math.Clamp(developed, 0, 1);
        c.Save();
        var s = 0.94f + 0.06f * d;
        c.Scale(s, s, rect.MidX, rect.MidY);
        var rr = new SKRoundRect(rect, 12);
        c.ClipRoundRect(rr, antialias: true);
        using var layer = new SKPaint { Color = SKColors.White.WithAlpha((byte)(255 * (0.25 + 0.75 * d))) };
        c.SaveLayer(layer);
        // 사진이 오기 전·없을 때: 분야 색의 은은한 그라데이션과 기호(맥 RemoteImage 자리표시)
        using (var g = new SKPaint { IsAntialias = true })
        {
            g.Shader = SKShader.CreateLinearGradient(new SKPoint(rect.Left, rect.Top), new SKPoint(rect.Right, rect.Bottom),
                [A(accent, 0.35), A(CatColor(cat), 0.25), A(accent, 0.12)], SKShaderTileMode.Clamp);
            c.DrawRect(rect, g);
        }
        Icons.Draw(c, cat.Glyph(), rect.MidX - 12, rect.MidY - 12, 24, A(SKColors.White, 0.55), 1.4f);
        if (img is not null)
        {
            // 채도 d, 밝기 +0.22·(1-d), 흐림 5·(1-d)
            var sat = d;
            var lr = 0.2126f * (1 - sat); var lg = 0.7152f * (1 - sat); var lb = 0.0722f * (1 - sat);
            var br = 0.22f * (1 - d);
            using var p = new SKPaint { IsAntialias = true };
            var cf = SKColorFilter.CreateColorMatrix([
                lr + sat, lg, lb, 0, br,
                lr, lg + sat, lb, 0, br,
                lr, lg, lb + sat, 0, br,
                0, 0, 0, 1, 0,
            ]);
            p.ImageFilter = (1 - d) > 0.02
                ? SKImageFilter.CreateColorFilter(cf, SKImageFilter.CreateBlur(5 * (1 - d) / 2, 5 * (1 - d) / 2))
                : SKImageFilter.CreateColorFilter(cf);
            // 칸을 꽉 채우게(가운데 잘라 냄)
            var scale = Math.Max(rect.Width / img.Width, rect.Height / img.Height);
            var dw = img.Width * scale; var dh = img.Height * scale;
            var dst = SKRect.Create(rect.MidX - dw / 2, rect.MidY - dh / 2, dw, dh);
            c.DrawImage(img, dst, new SKSamplingOptions(SKFilterMode.Linear, SKMipmapMode.Linear), p);
        }
        c.Restore();
        c.Restore();
        using var stroke = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Stroke, StrokeWidth = 0.5f, Color = A(SKColors.White, 0.25 * (0.25 + 0.75 * d)) };
        c.DrawRoundRect(rr, stroke);
    }

    // 빠른 단추: 나중에 읽기 · 브라우저(N-08)
    public Func<NewsItem, bool> IsSaved { get; set; } = _ => false;

    private void DrawQuick(SKCanvas c, ToastCard card, SKRect r, float hover)
    {
        if (hover < 0.01) return;
        var dy = 4 * (1 - hover);
        var y = r.Bottom - 8 - 22 + dy;
        var x2 = r.Right - 8 - 24;
        var x1 = x2 - 4 - 24;
        var icons = new[] { (x1, IsSaved(card.Item!) ? "bookmark.fill" : "bookmark"), (x2, "globe") };
        foreach (var (x, icon) in icons)
        {
            using (var bg = new SKPaint { IsAntialias = true, Color = A(Primary, 0.06 * hover) })
                c.DrawRoundRect(SKRect.Create(x, y, 24, 22), 7, 7, bg);
            Icons.Draw(c, icon, x + 6.5f, y + 5.5f, 11, A(Primary, hover), 2.2f);
        }
    }

    // 닫기 단추: 카드 왼쪽 위 바깥, 마우스를 올렸을 때만(N-08)
    private void DrawClose(SKCanvas c, ToastCard card, float left, float top, float hover)
    {
        if (hover < 0.01 || card.Leaving) return;
        var s = 0.6f + 0.4f * hover;
        c.Save();
        c.Scale(s, s, left - 7, top - 7);
        var cx = left - 7 + 10; var cy = top - 7 + 10;
        using (var sh = new SKPaint { IsAntialias = true, ImageFilter = SKImageFilter.CreateDropShadowOnly(0, 1, 1.5f, 1.5f, A(SKColors.Black, 0.15 * hover)) })
            c.DrawCircle(cx, cy, 10, sh);
        using (var bg = new SKPaint { IsAntialias = true, Color = A(Glass, hover) }) c.DrawCircle(cx, cy, 10, bg);
        using (var st = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Stroke, StrokeWidth = 0.5f, Color = A(Primary, 0.1 * hover) }) c.DrawCircle(cx, cy, 9.75f, st);
        Icons.Draw(c, "xmark", cx - 4.5f, cy - 4.5f, 9, A(Secondary, hover * 1.0), 3);
        c.Restore();
    }
}
