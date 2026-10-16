namespace Dropcap.App;

// 디자인 시스템 움직임 토큰(docs/DESIGN.md · 맥 UI/DesignSystem.swift 의 Motion 과 같은 값). 화면(웹) 쪽은 web/base.css 의 --dur-*·--ease-*.
public static class Motion
{
    public const double Quick = 0.15, Standard = 0.25, Slow = 0.4;
    public const double StartScale = 0.96; // 창 열기 시작 배율

    // 들어옴 곡선 cubic-bezier(0.2, 0.9, 0.25, 1)
    public static double Enter(double x) => Bezier(0.2, 0.9, 0.25, 1, x);

    // CSS cubic-bezier 와 같은 곡선(x 로 t 를 찾아 y)
    public static double Bezier(double x1, double y1, double x2, double y2, double x)
    {
        double Bx(double t) => 3 * (1 - t) * (1 - t) * t * x1 + 3 * (1 - t) * t * t * x2 + t * t * t;
        double By(double t) => 3 * (1 - t) * (1 - t) * t * y1 + 3 * (1 - t) * t * t * y2 + t * t * t;
        double lo = 0, hi = 1;
        for (var i = 0; i < 30; i++) { var m = (lo + hi) / 2; if (Bx(m) < x) lo = m; else hi = m; }
        return By((lo + hi) / 2);
    }
}
