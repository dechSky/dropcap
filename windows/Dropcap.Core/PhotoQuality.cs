namespace Dropcap.Core;

// 분야 대표 사진 고르기(M-24): 웹사이트 화면 캡처·글자 위주 그림·로고가 표지·분야 카드에 뽑히지 않게
// 사진 비율·크기·글자 면적·색 다양성·단색 바탕으로 점수를 매긴다. 맥 Core/PhotoQuality.swift 와 같은 식·수치.
// 화소 계산은 줄인 RGBA 바이트로 받고(그림 풀기는 Dropcap.Ui 의 PhotoScorer, 글자 면적은 앱의 윈도우 글자 인식), 여기는 계산만 한다.
// 기사 본문 사진·카드의 기사 사진에는 쓰지 않는다.
public static class PhotoQuality
{
    public sealed record Score(double Aspect, double Size, double TextRatio, double ColorVariety, double Flatness, double Total);

    // 이 점수보다 낮으면 대표 사진으로 쓰지 않는다
    public const double Threshold = 0.55;
    public const int ColorSide = 48, FlatSide = 96;

    public static double AspectScore(double w, double h)
    {
        if (w <= 0 || h <= 0) return 0;
        var r = w / h;
        if (r >= 1.2 && r <= 2.1) return 1;
        if (r < 1.2) return Math.Max(0, (r - 0.6) / 0.6);   // 세로·정사각에 가까울수록(로고·인물 사진) 낮게
        return Math.Max(0, 1 - (r - 2.1) / 1.5);             // 띠처럼 긴 배너
    }

    public static double SizeScore(double w, double h) => Math.Max(0, Math.Min(1, (Math.Min(w, h) - 150) / 250));

    // 글자 면적 → 점수: 사진 귀퉁이의 작은 글자(2~3%)는 거의 깎지 않고, 15% 넘으면 0
    public static double TextScore(double ratio) => Math.Max(0, Math.Min(1, 1 - (ratio - 0.03) / 0.12));

    public static Score Combine(double aspect, double size, double textRatio, double colorVariety, double flatness = 0)
    {
        var total = 0.15 * aspect + 0.15 * size + 0.4 * TextScore(textRatio) + 0.3 * colorVariety;
        // 글자가 5분의 1 넘게 덮음(글자 그림) · 단색 바탕이 넓음(그래픽·여백) · 단색 바탕에 글자(화면 캡처)면 반으로
        if (textRatio >= 0.2 || flatness >= 0.35 || (flatness >= 0.25 && textRatio >= 0.05)) total *= 0.5;
        return new Score(aspect, size, textRatio, colorVariety, flatness, total);
    }

    // 48×48 RGBA 에서 4비트씩 나눈 색 칸 중 가장 넓은 4칸이 차지하는 몫. 사진은 작고, 흰 바탕 화면 캡처·로고는 크다.
    public static double ColorVariety(ReadOnlySpan<byte> rgba, int side = ColorSide)
    {
        var n = side * side;
        if (rgba.Length < n * 4) return 0.5;
        var bins = new Dictionary<int, int>();
        for (var i = 0; i < n * 4; i += 4)
        {
            var k = (rgba[i] >> 4) << 8 | (rgba[i + 1] >> 4) << 4 | (rgba[i + 2] >> 4);
            bins[k] = bins.GetValueOrDefault(k) + 1;
        }
        var top4 = bins.Values.OrderDescending().Take(4).Sum();
        var share = (double)top4 / n;
        return Math.Max(0, Math.Min(1, (1 - share) * 1.3));
    }

    // 96×96 RGBA 에서 오른쪽·아래 이웃과 색이 똑같은 칸의 몫. 화면 캡처·그래픽은 넓은 단색 바탕이 남고, 사진은 거의 0.
    public static double Flatness(ReadOnlySpan<byte> rgba, int side = FlatSide)
    {
        if (rgba.Length < side * side * 4) return 0;
        bool Same(ReadOnlySpan<byte> px, int a, int b) => px[a] == px[b] && px[a + 1] == px[b + 1] && px[a + 2] == px[b + 2];
        var flat = 0;
        for (var y = 0; y < side - 1; y++)
            for (var x = 0; x < side - 1; x++)
            {
                var i = (y * side + x) * 4;
                if (Same(rgba, i, i + 4) && Same(rgba, i, i + side * 4)) flat++;
            }
        return (double)flat / ((side - 1) * (side - 1));
    }

    public static bool Good(double? score) => (score ?? 1) >= Threshold; // 아직 재지 않은 사진은 막지 않는다

    // 대표 사진으로 쓸 만한 주소인가(잡그림·없음 제외)
    public static bool Usable(string? url) => url is not null && !ImageKey.IsJunk(url);

    // 표지 기사: 사진이 좋은(또는 아직 재지 않은) 것 중 앞, 없으면 사진 없는 것 중 앞(좋지 않은 사진을 표지에 크게 띄우지 않게)
    public static string? PickCover(IEnumerable<NewsItem> ranked, IReadOnlyDictionary<string, double> scores)
    {
        var list = ranked.ToList();
        return (list.FirstOrDefault(it => Usable(it.Image) && Good(scores.TryGetValue(it.Image!, out var s) ? s : null))
                ?? list.FirstOrDefault(it => !Usable(it.Image)))?.Key;
    }

    // 분야 대표 사진: 잰 점수만으로 고르기(즉시). 기준을 넘은 잰 사진 → 아직 재지 않은 사진 순.
    public static NewsItem? Best(IEnumerable<NewsItem> items, IReadOnlyDictionary<string, double> scores)
    {
        var withPhoto = items.Where(i => Usable(i.Image)).ToList();
        return withPhoto.FirstOrDefault(i => scores.TryGetValue(i.Image!, out var s) && Good(s))
            ?? withPhoto.FirstOrDefault(i => !scores.ContainsKey(i.Image!));
    }
}
