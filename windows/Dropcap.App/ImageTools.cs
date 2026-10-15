using System.Runtime.InteropServices.WindowsRuntime;
using Dropcap.Ui;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Storage.Streams;

namespace Dropcap.App;

// 기사 속 사진 도구(R-20)의 윈도우 몫: 글자 인식(Windows.Media.Ocr)·클립보드·저장 대화상자를 읽기 창(ImageText)에 채워 넣는다.
internal static class ImageTools
{
    public static void Attach(Platform platform)
    {
        ImageText.Recognize = ImageOcr.LinesAsync;
        ImageText.Copy = platform.CopyImage;
        ImageText.Save = platform.SaveImageFile;
    }
}

// 기기 안에서 글자 읽기. 맥 Vision 은 언어를 스스로 알아보지만 윈도우 OCR 은 언어를 정해야 해서,
// 사용자 언어 엔진과(있으면) 영어 엔진으로 각각 읽고 글자를 더 많이 읽은 쪽을 쓴다(사진 속 글자는 대개 외국어).
internal static class ImageOcr
{
    private static List<OcrEngine>? engines;
    private static readonly SemaphoreSlim gate = new(1, 1);

    private static List<OcrEngine> Engines()
    {
        if (engines is not null) return engines;
        var o = new List<OcrEngine>();
        try
        {
            if (OcrEngine.TryCreateFromUserProfileLanguages() is { } user) o.Add(user);
            var en = OcrEngine.AvailableRecognizerLanguages.FirstOrDefault(l => l.LanguageTag.StartsWith("en", StringComparison.OrdinalIgnoreCase));
            if (en is not null && !o.Any(x => x.RecognizerLanguage.LanguageTag == en.LanguageTag) && OcrEngine.TryCreateFromLanguage(en) is { } e) o.Add(e);
        }
        catch { }
        return engines = o;
    }

    public static async Task<IReadOnlyList<ImageText.Line>> LinesAsync(byte[] jpeg)
    {
        await gate.WaitAsync();   // 엔진을 차례로
        try
        {
            using var ms = new InMemoryRandomAccessStream();
            await ms.WriteAsync(jpeg.AsBuffer());
            ms.Seek(0);
            var dec = await BitmapDecoder.CreateAsync(ms);
            using var bmp = await dec.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
            if (bmp.PixelWidth > OcrEngine.MaxImageDimension || bmp.PixelHeight > OcrEngine.MaxImageDimension) return [];
            double W = bmp.PixelWidth, H = bmp.PixelHeight;
            List<ImageText.Line> best = [];
            var bestLetters = 0;
            foreach (var engine in Engines())
            {
                var res = await engine.RecognizeAsync(bmp);
                var lines = new List<ImageText.Line>();
                foreach (var line in res.Lines)
                {
                    if (line.Words.Count == 0 || line.Text.Trim().Length == 0) continue;
                    // 줄 상자 = 낱말 상자를 합친 사각형
                    var l = line.Words.Min(w => w.BoundingRect.X);
                    var t = line.Words.Min(w => w.BoundingRect.Y);
                    var r = line.Words.Max(w => w.BoundingRect.X + w.BoundingRect.Width);
                    var b = line.Words.Max(w => w.BoundingRect.Y + w.BoundingRect.Height);
                    lines.Add(new ImageText.Line(line.Text.Trim(), l / W, t / H, Math.Max(0, r - l) / W, Math.Max(0, b - t) / H));
                }
                var letters = lines.Sum(x => x.Text.Count(char.IsLetterOrDigit));
                if (letters > bestLetters) { best = lines; bestLetters = letters; }
            }
            return best;
        }
        catch { return []; }
        finally { gate.Release(); }
    }
}
