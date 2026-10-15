using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace Dropcap.Core;

// 분야별 알림 정책(G-04~G-08, docs/research/COMPETITIVE.md (다)-3 · 맥 NotifyPolicy.swift 와 같은 수치).
// 매거진에는 전부 싣고, 물방울은 분야 모드·중요도 문턱·하루 상한을 모두 지날 때만 떨어뜨린다.
[JsonConverter(typeof(LowerEnum<NotifyMode>))]
public enum NotifyMode { Instant, Bundle, Magazine }

public static class NotifyModes
{
    public static readonly NotifyMode[] All = [NotifyMode.Instant, NotifyMode.Bundle, NotifyMode.Magazine];
    public static string Raw(this NotifyMode m) => m.ToString().ToLowerInvariant();
    public static NotifyMode Parse(string? s) => s switch { "instant" => NotifyMode.Instant, "magazine" => NotifyMode.Magazine, _ => NotifyMode.Bundle };
    public static string Label(this NotifyMode m) => m switch { NotifyMode.Instant => "즉시", NotifyMode.Bundle => "묶음", _ => "매거진만" };
    public static string Help(this NotifyMode m) => m switch
    {
        NotifyMode.Instant => "중요한 소식(여러 곳 보도·공식 발표·꼭 알림 낱말·팔로우한 스토리)만 바로 물방울로",
        NotifyMode.Bundle => "정한 시각에 한 방울로 모아서(예: 경제 7건)",
        _ => "알리지 않고 매거진에만",
    };
}

public sealed record SectionPolicy
{
    public NotifyMode Mode { get; init; } = NotifyMode.Bundle;
    public int BundleHour { get; init; } = 18;    // 묶음을 보내는 시각(시)
    public int DailyCap { get; init; } = 3;       // 이 분야에서 하루에 떨어뜨리는 물방울 수
    public bool Less { get; init; }               // 카드에서 '이 분야 덜 받기'를 누름 → 주요 뉴스 흐름으로도 바로 떨어뜨리지 않음(즉시로 되돌리면 풀림)

    // 예전·깨진 값도 읽힘(모르는 모드는 묶음)
    public static SectionPolicy FromJson(JsonNode? n)
    {
        if (n is not JsonObject o) return new();
        return new SectionPolicy
        {
            Mode = NotifyModes.Parse(Json.Field<string?>(o, "mode", null)),
            BundleHour = Json.Field(o, "bundleHour", 18),
            DailyCap = Json.Field(o, "dailyCap", 3),
            Less = Json.Field(o, "less", false), // 예전 파일엔 없음 · 예전 판은 이 값을 무시
        };
    }
}

// 같은 소식을 다룬 출처 수(국내·해외)
public readonly record struct Coverage(int Kr, int Intl)
{
    public int Total => Kr + Intl;
}

public sealed record PolicyLimits
{
    public int TotalCap { get; init; } = 10;       // 모든 분야를 합친 하루 물방울 수
    public int KrThreshold { get; init; } = 3;     // 국내 n곳 이상이 다루면 중요한 소식
    public int IntlThreshold { get; init; } = 2;   // 해외 n곳 이상
    public int BigThreshold { get; init; } = 8;    // 국내 n곳 이상이면 상한도 넘어 알림
}

public enum NotifyDecision
{
    Drop,   // 지금 물방울
    Pool,   // 고였다가 그 분야 묶음 시각에 한 방울
    Quiet,  // 매거진에만
}

public static class NotifyPolicy
{
    public sealed record Input
    {
        public bool Chosen { get; init; }                   // 사용자가 고른 분야인가
        public SectionPolicy Policy { get; init; } = new();
        public Coverage Coverage { get; init; }
        public bool Lab { get; init; }                      // 공식 발표 등급(tier lab)
        public bool Important { get; init; }                // ★ 꼭 알림 낱말
        public bool Followed { get; init; }                 // 팔로우한 스토리
        public bool Watched { get; init; }                  // 지켜볼 낱말에 걸림(N-27)
        public int SentInSection { get; init; }             // 오늘 이 분야에서 이미 떨어뜨린 수
        public int SentTotal { get; init; }                 // 오늘 전체
    }

    public static bool Crosses(Coverage c, PolicyLimits l) => c.Kr >= l.KrThreshold || c.Intl >= l.IntlThreshold;
    public static bool IsBig(Coverage c, PolicyLimits l) => c.Kr >= l.BigThreshold;

    public static NotifyDecision Decide(Input i, PolicyLimits l)
    {
        // 지켜볼 낱말: 고른 분야·모드와 상관없이 알린다(같은 이야기는 한 번 — 부르는 쪽이 스토리로 기억). 전체 상한이 차면 고임
        if (i.Watched) return i.SentTotal >= l.TotalCap && !IsBig(i.Coverage, l) ? NotifyDecision.Pool : NotifyDecision.Drop;
        if (!i.Chosen) return NotifyDecision.Quiet;
        switch (i.Policy.Mode)
        {
            case NotifyMode.Magazine: return NotifyDecision.Quiet;
            case NotifyMode.Bundle: return NotifyDecision.Pool;
            default:
                var worth = Crosses(i.Coverage, l) || i.Lab || i.Important || i.Followed;
                if (!worth) return NotifyDecision.Quiet;
                var full = i.SentInSection >= i.Policy.DailyCap || i.SentTotal >= l.TotalCap;
                if (full) return IsBig(i.Coverage, l) ? NotifyDecision.Drop : NotifyDecision.Pool;
                return NotifyDecision.Drop;
        }
    }

    // '주요 뉴스' 흐름(G-08): 자기 분야에서 떨어지지 않은 소식이라도 문턱을 넘었으면 주요 뉴스 정책으로 한 번 더 본다
    public static (NotifyDecision Decision, bool ViaTop) DecideWithTop(Input i, Input? top, PolicyLimits l)
    {
        var own = Decide(i, l);
        // '덜 받기'한 분야는 주요 뉴스 흐름으로도 떨어뜨리지 않고 자기 정책(묶음·매거진만)대로 둔다
        if (own == NotifyDecision.Drop || i.Policy.Less || top is null || !Crosses(i.Coverage, l)) return (own, false);
        var t = top with { Coverage = i.Coverage };
        return Decide(t, l) == NotifyDecision.Drop ? (NotifyDecision.Drop, true) : (own, false);
    }

    // 첫 실행 기본값(G-04): 고른 분야 중 앞의 두 개만 즉시, 나머지는 묶음(주요 뉴스 흐름은 즉시)
    public static Dictionary<string, SectionPolicy> Defaults(IEnumerable<string> chosen)
    {
        var o = new Dictionary<string, SectionPolicy>();
        var instant = 0;
        foreach (var id in chosen)
        {
            if (id == Sections.Top) { o[id] = new SectionPolicy { Mode = NotifyMode.Instant }; continue; }
            o[id] = new SectionPolicy { Mode = instant < 2 ? NotifyMode.Instant : NotifyMode.Bundle };
            if (instant < 2) instant++;
        }
        return o;
    }

    // 묶음을 보낼 때인가(G-07): 그 분야 묶음 시각이 지났고 오늘(그 시각 뒤에) 아직 안 보냈으면
    public static bool BundleDue(int hour, DateTimeOffset now, DateTimeOffset? last)
    {
        var n = now.ToLocalTime();
        if (n.Hour < hour) return false;
        if (last is { } l)
        {
            var ll = l.ToLocalTime();
            if (ll.Date == n.Date && ll.Hour >= hour) return false;
        }
        return true;
    }
}
