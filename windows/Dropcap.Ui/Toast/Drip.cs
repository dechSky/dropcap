namespace Dropcap.Ui.Toast;

// 천장(작업 영역 위쪽 가장자리)에 물이 맺혀 → 부풀고 → 목이 늘어나다 → 톡 끊어져 떨어지는 모습의 계산(맥 DripView.state 와 같은 식·수치).
// 그리기는 ToastRenderer 가 흐림 + 문턱값(맥 canvasBody 와 같은 방식)으로 한다(N-01·N-02·N-21).
public static class Drip
{
    public const float Width = 120;
    public const double Swell = 0.45;        // 맺혀서 부푸는 시간
    public const double Sag = 0.22;          // 무게로 처지며 목이 늘어나는 시간
    public const double Detach = Swell + Sag;
    public const float Gravity = 2600;       // 화면에서 보기 좋게 빠르게 한 중력(pt/s²)
    public const float DropRadius = 15;
    public static float DetachY => 9 + DropRadius + 13;

    // 떨어지기 시작해서 닿을 때까지 걸리는 시간
    public static double FallTime(float y0, float y1) => Math.Sqrt(2 * Math.Max(0, y1 - y0) / Gravity);
    public static double LandingTime(float landY) => Detach + FallTime(DetachY, landY);

    public struct S
    {
        public float Film, BeadR, Neck, DropR, DropY, Stretch, SatR, SatY;
    }

    public static S State(double t, float landY)
    {
        var s = new S { Stretch = 1 };
        var R = DropRadius;
        static float Ease(double x) => (float)(1 - Math.Pow(1 - Math.Clamp(x, 0, 1), 3));
        static float Smooth(double a, double b, double x)
        {
            var u = Math.Clamp((x - a) / (b - a), 0, 1);
            return (float)(u * u * (3 - 2 * u));
        }

        if (t < Detach)
        {
            // 맺힘 → 부풂
            var g = Ease(t / Swell);
            s.Film = (float)Math.Min(1, t / 0.18);
            s.BeadR = 4 + 6 * g;
            s.DropR = 3 + (R - 3) * g;
            // 숨 쉬듯 살짝 떨림
            var wobble = (float)(Math.Sin(t * 26) * 0.6) * (1 - Smooth(0, Swell, t)) * g;
            s.DropR += wobble;
            // 처짐: 아래로 늘어나며 목이 생기고 가늘어진다
            var sag = Smooth(Swell * 0.7, Detach, t);
            s.DropY = 9 + s.DropR * 0.85f + 13 * sag;
            s.Neck = (3.6f - 2.4f * sag) * g;
            s.Stretch = 1 + 0.08f * sag;
        }
        else
        {
            // 떨어짐: 점점 빨라지고, 속도만큼 길어진다
            var dt = t - Detach;
            var v = Gravity * (float)dt;
            s.DropR = R;
            s.DropY = DetachY + 0.5f * Gravity * (float)(dt * dt);
            s.Stretch = 1 + Math.Min(0.32f, v / 1500);
            if (s.DropY >= landY) s.DropR = 0; // 닿는 순간부터는 카드의 물이 이어받는다
            // 천장에 남은 물: 위로 튕겼다가 출렁이며 사라짐
            var k = dt;
            s.Film = Math.Max(0, 1 - (float)(k / 0.5));
            s.BeadR = Math.Max(0, (7 + 3 * (float)(Math.Exp(-k * 7) * Math.Cos(k * 34))) * (1 - (float)(k / 0.55)));
            // 작은 물방울: 끊어진 목에서 생겨 뒤따라 떨어지다 사라짐
            if (k < 0.22)
            {
                s.SatR = 4.6f * (1 - (float)(k / 0.22));
                s.SatY = 20 + 0.5f * Gravity * 0.55f * (float)(k * k);
            }
        }
        return s;
    }
}

// 카드 안에 물이 차오르는 모습의 수치(맥 WaterFill 과 같음)(N-03)
public static class WaterFill
{
    public const double FillTime = 0.75;

    public static double Smooth(double x)
    {
        var u = Math.Clamp(x, 0, 1);
        return u * u * (3 - 2 * u);
    }

    public static double FillLevel(double e) => 1 - Math.Pow(1 - Math.Clamp(e / FillTime, 0, 1), 3); // 처음엔 빠르게, 끝에서 천천히
    public static double Amplitude(double e) => 4.5 * Math.Exp(-2.2 * e) + 0.9;
    public static double Tilt(double e) => 0.05 * Math.Sin(e * 7.5) * Math.Exp(-1.6 * e);        // 좌우로 기우뚱
    // 글자가 물과 함께 떠오르므로 물빛은 옅게 시작하고, 다 차면 더 맑게
    public static double Alpha(double e) => 0.4 - 0.27 * Smooth((e - FillTime * 0.6) / 0.45);

    // 바닥에 닿을 때 튀어 오르는 작은 물방울 4개(vx, vy, r)
    public static readonly (double Vx, double Vy, float R)[] Splashes = [(-70, 210, 2.2f), (55, 240, 1.8f), (10, 270, 1.5f), (-25, 180, 1.4f)];
    // 물속에서 올라오는 작은 거품 5개
    public static readonly (float X, double Delay, float R, float Speed)[] Bubbles =
        [(0.18f, 0.12, 1.6f, 70), (0.33f, 0.30, 2.4f, 60), (0.52f, 0.18, 1.3f, 85), (0.68f, 0.40, 2.0f, 65), (0.84f, 0.25, 1.5f, 75)];
}
