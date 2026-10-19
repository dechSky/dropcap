using Dropcap.Core;
using Dropcap.Ui;
using Dropcap.Ui.Toast;
using SkiaSharp;

namespace Dropcap.Core.Tests;

// 물방울 알림(N 절)의 시간표·쌓기·마우스·그리기. DROPCAP_TOAST_FRAMES=<폴더> 면 장면을 PNG 로 남긴다(맥에서 눈으로 확인).
public class ToastTests
{
    private static NewsItem News(string id, string ko = "새 AI 소식은 이렇게 떨어집니다", string? image = null) => new()
    {
        Id = id, Title = "This is how new AI news will drop in", TitleKo = ko, Link = "", Date = DateTimeOffset.Now.AddMinutes(-3),
        SourceId = "openai", SourceName = "OpenAI", Tier = "lab", Related = ["The Verge"], Important = true, Image = image,
    };

    private static (ToastEngine E, ToastRenderer R) Make(bool reduce = false)
    {
        var e = new ToastEngine { ReduceMotion = reduce };
        var r = new ToastRenderer(e);
        e.Measure = r.Measure;
        return (e, r);
    }

    [Fact]
    public void DripNumbersMatchMac()
    {
        Assert.Equal(0.67, Drip.Detach, 6);
        Assert.Equal(37, Drip.DetachY);
        // 맺힘 → 떨어짐: 떨어지기 전엔 물방울이 천천히 부풀고, 뒤엔 중력으로
        var landY = ToastEngine.Top + 80 - Drip.DropRadius * 0.6f;
        Assert.Equal(Drip.Detach + Math.Sqrt(2 * (landY - 37) / 2600.0), Drip.LandingTime(landY), 6);
        var s0 = Drip.State(0.1, landY);
        Assert.True(s0.DropR > 3 && s0.DropR < 15);
        var s1 = Drip.State(Drip.LandingTime(landY) + 0.01, landY);
        Assert.Equal(0, s1.DropR); // 닿은 뒤에는 카드의 물이 이어받음
        Assert.Equal(1, WaterFill.FillLevel(0.75), 6);
    }

    [Fact]
    public void ScheduleFollowsMacRunOrder()
    {
        var (e, _) = Make();
        e.Show([News("a"), News("b"), News("c"), News("d"), News("e")], sound: true, now: 0);
        Assert.Single(e.Cards); // 0.32초 간격
        e.Tick(0.33);
        e.Tick(0.65);
        e.Tick(0.97);
        Assert.Equal(4, e.Cards.Count); // 3건 + "N건 더"
        var more = e.Cards[0];
        Assert.Equal(ToastKind.More, more.Kind);
        Assert.Equal(2, more.Count);
        var first = e.Cards[^1];
        Assert.True(first.PlaySound);
        Assert.False(first.QuickDrop);
        Assert.True(e.Cards[^2].QuickDrop); // 두 번째부터 바로 떨어짐
        // 두 번째 카드는 맺히는 단계를 거의 건너뛴다
        Assert.True(e.Cards[^2].Land - e.Cards[^2].Born < first.Land - first.Born - 0.5);
        Assert.Equal(first.Land + WaterFill.FillTime * 0.3, first.RevealAt, 6);
        Assert.Equal(first.Land + WaterFill.FillTime + ToastEngine.Lifetime, first.Deadline, 6);
    }

    [Fact]
    public void StackMaxFourAndLeaves()
    {
        var (e, _) = Make();
        for (var i = 0; i < 5; i++) e.ShowInfo("t" + i, "s", i * 0.01);
        Assert.Equal(ToastEngine.MaxVisible, e.Cards.Count);
        Assert.Equal("t4", e.Cards[0].Title);
        var emptied = false;
        e.Emptied += () => emptied = true;
        e.Tick(30);   // 머무름이 끝나면 사라지기 시작
        Assert.All(e.Cards, c => Assert.True(c.Leaving));
        e.Tick(31);
        Assert.Empty(e.Cards);
        Assert.True(emptied);
    }

    [Fact]
    public void HoverDelaysDeadline()
    {
        var (e, _) = Make();
        e.ShowInfo("t", "s", 0);
        var c = e.Cards[0];
        var before = c.Deadline;
        e.SetHover(c);
        for (var t = 0.1; t <= 2; t += 0.1) e.Tick(t);
        Assert.True(c.Deadline > before + 1.8); // 올려 둔 만큼 미뤄짐(N-07)
        Assert.True(c.Hover > 0.9);
    }

    [Fact]
    public void HitTestUsesCardRect()
    {
        var (e, _) = Make();
        e.Show([News("a")], false, 0);
        var c = e.Cards[0];
        Assert.Equal(HitPart.None, e.HitTest(2, 2).Part);                       // 카드 밖은 통과(N-13)
        Assert.Equal(HitPart.Card, e.HitTest(200, c.Y + 20).Part);
        e.SetHover(c);
        e.Tick(1);
        Assert.Equal(HitPart.Close, e.HitTest(20, c.Y).Part);                   // 왼쪽 위 닫기
        Assert.Equal(HitPart.Browser, e.HitTest(20 + 360 - 8 - 12, c.Y + c.Height - 8 - 11).Part);
        Assert.Equal(HitPart.Save, e.HitTest(20 + 360 - 8 - 24 - 4 - 12, c.Y + c.Height - 8 - 11).Part);
        ToastCard? opened = null;
        e.Opened += k => opened = k;
        e.Click(e.HitTest(200, c.Y + 20), 1);
        Assert.Same(c, opened);
        Assert.True(c.Leaving && c.LeaveQuick);
    }

    [Fact]
    public void ReduceMotionHasNoDrip()
    {
        var (e, _) = Make(reduce: true);
        e.ShowInfo("t", "s", 0);
        var c = e.Cards[0];
        Assert.Equal(c.Born, c.Land);
        Assert.Equal(0.15, e.LeaveDuration(c), 6);
    }

    [Fact]
    public void RendersFrames()
    {
        var (e, r) = Make();
        e.Show([News("a"), News("b", "두 번째 소식은 맺히지 않고 바로 떨어집니다")], sound: false, now: 0);
        e.ShowWelcome(0.05);
        var dir = Environment.GetEnvironmentVariable("DROPCAP_TOAST_FRAMES");
        foreach (var t in new[] { 0.2, 0.5, 0.75, 0.9, 1.1, 1.4, 2.0, 3.5 })
        {
            e.Tick(t);
            if (Math.Abs(t - 2.0) < 1e-6) e.SetHover(e.Cards[0]);
            using var bmp = r.RenderBitmap(t, 2);
            Assert.Equal(800, bmp.Width);
            // 카드가 있는 곳은 그려지고, 카드 밖 아래쪽은 투명(클릭 통과 영역)
            Assert.Equal(0, bmp.GetPixel(10, 1150).Alpha);
            if (dir is not null)
            {
                Directory.CreateDirectory(dir);
                using var img = SKImage.FromBitmap(bmp);
                using var png = img.Encode(SKEncodedImageFormat.Png, 100);
                File.WriteAllBytes(Path.Combine(dir, $"toast-{(int)(t * 1000):0000}.png"), png.ToArray());
            }
        }
        // 다 찬 뒤 카드 가운데는 불투명하게 그려짐
        using var last = r.RenderBitmap(3.5, 1);
        var top = e.Cards[^1];
        Assert.True(last.GetPixel(200, (int)(top.Y + top.Height / 2)).Alpha > 200);
    }

    // 묶음 한 방울(G-07): "경제 7건" + 제목 2줄, 누를 수 있음
    [Fact]
    public void BundleCard()
    {
        var (e, r) = Make();
        var items = Enumerable.Range(0, 7).Select(i => News("b" + i, $"경제 소식 {i}번째 제목입니다")).ToList();
        e.ShowBundle("economy", items, sound: true, now: 0);
        var c = e.Cards.Single();
        Assert.Equal(ToastKind.Bundle, c.Kind);
        Assert.True(c.Clickable && c.PlaySound);
        Assert.Equal(7, c.Count);
        Assert.Equal("경제 7건", Strings.Bundle("economy", 7));
        Assert.True(c.Height > 60 && c.Height < 100);
        e.Tick(2);
        using var bmp = r.RenderBitmap(2, 2);
        Assert.True(bmp.GetPixel(400, (int)((c.Y + c.Height / 2) * 2)).Alpha > 200);
        var dir = Environment.GetEnvironmentVariable("DROPCAP_TOAST_FRAMES");
        if (dir is not null)
        {
            Directory.CreateDirectory(dir);
            using var img = SKImage.FromBitmap(bmp);
            File.WriteAllBytes(Path.Combine(dir, "bundle.png"), img.Encode(SKEncodedImageFormat.Png, 100).ToArray());
        }
    }

    [Fact]
    public void SoundAndIcons()
    {
        var wav = DropSound.Wav;
        Assert.Equal("RIFF", System.Text.Encoding.ASCII.GetString(wav, 0, 4));
        Assert.Equal(44 + (int)(44100 * 0.2) * 2, wav.Length);
        var ico = AppIcon.Ico(16, 32, 256);
        Assert.Equal(new byte[] { 0, 0, 1, 0, 3, 0 }, ico[..6]);
        using var tray = AppIcon.Tray(32, true, SKColors.White);
        Assert.True(tray.Pixels.Any(p => p.Alpha > 0));
        var dir = Environment.GetEnvironmentVariable("DROPCAP_TOAST_FRAMES");
        if (dir is not null)
        {
            Directory.CreateDirectory(dir);
            using var b = AppIcon.Render(512);
            using var img = SKImage.FromBitmap(b);
            File.WriteAllBytes(Path.Combine(dir, "app-icon.png"), img.Encode(SKEncodedImageFormat.Png, 100).ToArray());
        }
    }

    // 앱 아이콘·트레이 상징은 shared/icon.json 으로 그린다: 32px 이하는 단순화 판, 트레이는 평소/새 소식이 다른 모양
    [Fact]
    public void IconArtFromSharedJson()
    {
        Assert.Equal(32, AppIcon.Art.SmallMax);
        using var big = AppIcon.Render(64);
        using var small = AppIcon.Render(32);
        // 표지 가운데는 종이색(밝음), 단순화 판은 표지를 크게 그려 D 와 글줄 사이(20,19)도 종이
        Assert.True(big.GetPixel(32, 32).Red > 200);
        Assert.True(small.GetPixel(20, 19).Red > 200 && small.GetPixel(20, 19).Green > 180);
        using var read = AppIcon.Tray(32, false, SKColors.White);
        using var unread = AppIcon.Tray(32, true, SKColors.White);
        Assert.Equal(0, read.GetPixel(16, 25).Alpha); // 평소: 표지 속은 비어 있음
        Assert.True(unread.GetPixel(16, 25).Alpha > 200); // 새 소식: 표지가 채워짐
        Assert.True(unread.GetPixel(4 * 2 + 1, 4 * 2 + 1).Alpha < 60); // 채운 표지에서 D 가 빠짐
        var dir = Environment.GetEnvironmentVariable("DROPCAP_TOAST_FRAMES");
        if (dir is not null)
        {
            Directory.CreateDirectory(dir);
            foreach (var (name, bmp) in new[] { ("icon-1024", AppIcon.Render(1024)), ("icon-32", AppIcon.Render(32)), ("icon-16", AppIcon.Render(16)),
                         ("tray-read-32", AppIcon.Tray(32, false, SKColors.Black)), ("tray-unread-32", AppIcon.Tray(32, true, SKColors.Black)) })
            {
                using (bmp)
                using (var img = SKImage.FromBitmap(bmp))
                    File.WriteAllBytes(Path.Combine(dir, name + ".png"), img.Encode(SKEncodedImageFormat.Png, 100).ToArray());
            }
        }
    }

    [Fact]
    public void ImageShrinkCapsSize()
    {
        using var big = new SKBitmap(3000, 1500);
        using (var c = new SKCanvas(big)) c.Clear(SKColors.CornflowerBlue);
        using var img = SKImage.FromBitmap(big);
        var png = img.Encode(SKEncodedImageFormat.Png, 100).ToArray();
        var jpg = ImageLoader.Shrink(png)!;
        using var back = SKBitmap.Decode(jpg);
        Assert.Equal(1400, back.Width);
        Assert.Equal(700, back.Height);
        Assert.Null(ImageLoader.Shrink("not an image"u8.ToArray()));
    }

    [Fact]
    public void TextWrapsAndEllipsizes()
    {
        using var f = new SKFont(Fonts.Get(600), 14.5f);
        var lines = TextLayout.Wrap("오픈AI, 추론 기능을 크게 강화한 새 모델 GPT-6 를 공개하고 개발자용 API 가격을 절반으로 낮췄다고 밝혔다", f, 200, 2);
        Assert.Equal(2, lines.Count);
        Assert.EndsWith("…", lines[1]);
        Assert.All(lines, l => Assert.True(f.MeasureText(l) <= 200.5f));
    }

    // 알림 위치를 바꾸면 떠 있는 창도 다음 알림에서 다시 놓는다(맥 SettingsQATests 와 같은 표)
    [Fact]
    public void PositionChangeReplacesShownWindow()
    {
        Assert.True(ToastEngine.NeedsPlace(true, ToastPosition.Center, ToastPosition.Right));
        Assert.True(ToastEngine.NeedsPlace(true, ToastPosition.Right, ToastPosition.Center));
        Assert.False(ToastEngine.NeedsPlace(true, ToastPosition.Right, ToastPosition.Right)); // 커서가 다른 모니터여도 그대로
        Assert.True(ToastEngine.NeedsPlace(false, ToastPosition.Right, ToastPosition.Right));
        Assert.True(ToastEngine.NeedsPlace(true, null, ToastPosition.Center));
    }
}
