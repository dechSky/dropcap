using Dropcap.Core;

namespace Dropcap.Ui.Toast;

public enum ToastKind { News, Info, More, Digest, Bundle, Watch }

// 알림 카드 하나와 그 시간표. 시각은 모두 엔진 시계(초) 기준.
public sealed class ToastCard
{
    public Guid Id { get; } = Guid.NewGuid();
    public ToastKind Kind { get; init; }
    public NewsItem? Item { get; init; }
    public string Title { get; init; } = "";
    public string Sub { get; init; } = "";
    public int Count { get; init; }
    public string? Section { get; init; }                  // 묶음 카드의 분야(G-07)
    public IReadOnlyList<NewsItem> Items { get; init; } = [];
    public bool PlaySound { get; set; }
    public bool QuickDrop { get; set; }   // 여러 건일 때 두 번째부터: 맺히는 단계를 건너뛰고 바로 떨어짐(N-10)

    public string Accent { get; set; } = "#007AFF";
    public float Height { get; set; } = 80;
    public string? Thumb { get; set; }    // 사진 주소(피드에 없으면 og:image 를 찾아 채움)

    // 시간표(ToastEngine.Schedule 이 정함)
    public double Born, DripStart, Land, RevealAt, CalmAt, Deadline;
    public double? LeaveStart;
    public bool LeaveQuick;
    public bool Sounded;
    public double LastTick;

    // 움직임 값
    public float Y, Vy, TargetY; // 쌓기 위치(용수철)
    public float Hover;          // 0~1 (마우스 올림)
    public bool Hovered;

    public bool Clickable => Kind is ToastKind.News or ToastKind.Digest or ToastKind.Bundle or ToastKind.Watch;
    public bool Leaving => LeaveStart is not null;
    public float LandY => ToastEngine.Top + Height - Drip.DropRadius * 0.6f;
}

// 무엇을 눌렀나
public enum HitPart { None, Card, Close, Save, Browser }
public readonly record struct Hit(ToastCard? Card, HitPart Part);

// 알림 쌓기·시간표·마우스 올림·사라짐(맥 ToastCenter.show/push/remove + ToastView.run/leave 와 같은 순서·수치).
// 시계를 밖에서 넣어 주므로(Tick(now)) 맥에서도 어느 순간의 모습이든 다시 그려 볼 수 있다.
public sealed class ToastEngine
{
    public const float PanelWidth = 400, PanelHeight = 600, Top = 46, CardWidth = 360, Spacing = 10;
    public const double Lifetime = 9;       // 머무름(N-07)
    public const int MaxVisible = 4;        // 최대 4장(N-10)
    public const double Stagger = 0.32;     // 여러 건 간격

    public bool ReduceMotion { get; set; }  // N-17·N-24
    public Func<ToastCard, float> Measure { get; set; } = _ => 80;   // 카드 높이(그리는 쪽이 잰다)
    public Func<string, string> AccentOf { get; set; } = _ => "#007AFF";
    public string DefaultAccent { get; set; } = "#007AFF";

    public event Action<ToastCard>? Sound;      // 닿는 순간 "똑"(N-04)
    public event Action<ToastCard>? Opened;     // 카드를 누름(N-14)
    public event Action<ToastCard>? NeedsThumb; // 사진이 없으면 og:image 찾기(N-06)
    public event Action? Emptied;               // 다 사라짐(창 숨김)

    private readonly List<ToastCard> cards = new();       // 위(새것)부터
    private readonly List<(double At, ToastCard Card)> queue = new();
    public IReadOnlyList<ToastCard> Cards => cards;
    public bool Visible => cards.Count > 0 || queue.Count > 0;

    // MARK: 넣기
    public void Show(IReadOnlyList<NewsItem> items, bool sound, double now)
    {
        var list = items.Take(3).Select(i => new ToastCard { Kind = ToastKind.News, Item = i, Accent = AccentOf(i.SourceId), Thumb = i.Image }).ToList();
        if (items.Count > 3) list.Add(new ToastCard { Kind = ToastKind.More, Count = items.Count - 3, Accent = DefaultAccent });
        if (list.Count > 0 && sound) list[0].PlaySound = true;
        for (var i = 1; i < list.Count; i++) list[i].QuickDrop = true;
        // 여러 건이면 조금씩 시간차를 두고 하나씩 떨어뜨린다
        for (var i = 0; i < list.Count; i++) queue.Add((now + i * Stagger, list[i]));
        Tick(now);
    }

    public void ShowInfo(string title, string sub, double now) =>
        Push(new ToastCard { Kind = ToastKind.Info, Title = title, Sub = sub, Accent = DefaultAccent }, now);

    public void ShowDigest(int count, bool sound, double now) =>
        Push(new ToastCard { Kind = ToastKind.Digest, Count = count, PlaySound = sound, Accent = DefaultAccent }, now);

    // 묶음 한 방울(G-07): "경제 7건" + 제목 2줄, 누르면 매거진의 그 분야 지면
    public void ShowBundle(string section, IReadOnlyList<NewsItem> items, bool sound, double now) =>
        Push(new ToastCard { Kind = ToastKind.Bundle, Section = section, Items = items, Count = items.Count, PlaySound = sound,
            Accent = Sections.ById(section)?.Color ?? DefaultAccent }, now);

    // 지켜볼 낱말 하루 정리(N-27): "오늘 ○○ 소식 3건" + 제목 2줄, 누르면 매거진 검색(Title = 낱말)
    public void ShowWatch(string word, IReadOnlyList<NewsItem> items, bool sound, double now)
    {
        if (items.Count == 0) return;
        Push(new ToastCard { Kind = ToastKind.Watch, Title = word, Items = items, Count = items.Count, PlaySound = sound, Accent = WatchAccent }, now);
    }
    public const string WatchAccent = "#30B0C7";   // 맥 teal

    // N-16: 첫 실행 안내
    public void ShowWelcome(double now) => ShowInfo(Strings.WelcomeTitle, Strings.WelcomeSub, now);

    private void Push(ToastCard c, double now)
    {
        c.Height = Measure(c);
        Schedule(c, now);
        cards.Insert(0, c);
        Restack(now, initial: c);
        while (cards.Count > MaxVisible) Remove(cards[^1]);
        if (c.Kind == ToastKind.News && c.Thumb is null && c.Item is { Id: not AppModel.PreviewId, Link.Length: > 0 }) NeedsThumb?.Invoke(c);
    }

    // 맥 ToastView.run 의 순서: 30ms 뒤 맺힘 시작 → 닿으면 소리·물 차오름·사진 인화 → 30% 차면 글자 떠오름 → 다 차고 0.9초 뒤 잔잔 → 9초 머무름
    private void Schedule(ToastCard c, double now)
    {
        c.Born = now;
        c.LastTick = now;
        if (ReduceMotion)
        {
            c.DripStart = c.Land = now;
            c.RevealAt = now;
            c.CalmAt = now;
            c.Deadline = now + Lifetime;
            return;
        }
        var skip = c.QuickDrop ? Drip.Detach - 0.12 : 0;
        c.DripStart = now + 0.03 - skip;
        c.Land = now + 0.03 + (Drip.LandingTime(c.LandY) - skip) - 0.025;
        c.RevealAt = c.Land + WaterFill.FillTime * 0.3;
        c.CalmAt = c.Land + WaterFill.FillTime + 0.9;
        c.Deadline = c.Land + WaterFill.FillTime + Lifetime;
    }

    // 쌓기 위치(N-10). 새 카드는 제자리에서 시작하고, 나머지는 용수철로 밀려 내려간다.
    private void Restack(double now, ToastCard? initial = null)
    {
        var y = Top;
        foreach (var c in cards)
        {
            if (c == initial) { c.Y = y; c.Vy = 0; }
            c.TargetY = y;
            y += c.Height + Spacing;
        }
    }

    public void Remove(ToastCard c)
    {
        if (!cards.Remove(c)) return;
        Restack(0);
        if (cards.Count == 0 && queue.Count == 0) Emptied?.Invoke();
    }

    // MARK: 시계
    public void Tick(double now)
    {
        for (var i = 0; i < queue.Count;)
        {
            if (queue[i].At <= now) { var c = queue[i].Card; queue.RemoveAt(i); Push(c, now); }
            else i++;
        }
        foreach (var c in cards.ToList())
        {
            var dt = Math.Clamp(now - c.LastTick, 0, 0.1);
            c.LastTick = now;
            // 닿는 순간 "똑"
            if (!c.Sounded && now >= c.Land)
            {
                c.Sounded = true;
                if (c.PlaySound) Sound?.Invoke(c);
            }
            // 마우스를 올린 동안은 마감을 미룬다(N-07)
            if (c.Hovered && !c.Leaving) c.Deadline += dt;
            if (!c.Leaving && now >= c.Deadline) Leave(c, quick: false, now);
            // 마우스 올림 값(용수철 0.3/0.75 를 지수 따라가기로)
            var target = c.Hovered && !c.Leaving ? 1f : 0f;
            c.Hover += (target - c.Hover) * (float)(1 - Math.Exp(-dt * 14));
            // 쌓기 위치 용수철(응답 0.5초, 감쇠 0.82)
            Spring(ref c.Y, ref c.Vy, c.TargetY, dt, 0.5, 0.82);
            if (c.LeaveStart is { } ls && now - ls >= LeaveDuration(c)) Remove(c);
        }
    }

    // 창을 다시 놓을지(맥 ToastCenter.needsPlace): 숨어 있었거나 위치 설정이 놓을 때와 달라졌으면.
    // 예전엔 위치 설정을 보지 않아 알림이 떠 있는 동안 '오른쪽 위'로 바꾸면 다음 알림도 가운데에 떨어졌다.
    // 커서가 다른 모니터로 가도 이미 뜬 알림은 옮기지 않는다(모니터 구성이 바뀔 때만 Replace).
    public static bool NeedsPlace(bool shown, ToastPosition? placedAt, ToastPosition wanted) =>
        !shown || placedAt != wanted;

    public static void Spring(ref float x, ref float v, float target, double dt, double response, double damping)
    {
        var w = 2 * Math.PI / response;
        var steps = Math.Max(1, (int)Math.Ceiling(dt / 0.004));
        var h = dt / steps;
        for (var i = 0; i < steps; i++)
        {
            var a = -w * w * (x - target) - 2 * damping * w * v;
            v += (float)(a * h);
            x += (float)(v * h);
        }
        if (Math.Abs(x - target) < 0.05 && Math.Abs(v) < 0.05) { x = target; v = 0; }
    }

    public double LeaveDuration(ToastCard c) => ReduceMotion ? 0.15 : 0.28 * (c.LeaveQuick ? 0.6 : 1);

    public void Leave(ToastCard c, bool quick, double now)
    {
        if (c.Leaving) return;
        c.LeaveStart = now;
        c.LeaveQuick = quick;
        c.Hovered = false;
    }

    // 다시 그려야 하는 빠르기: 움직이는 중이면 초당 60, 잔잔하면 12(N-03), 없으면 0
    public int FramesPerSecond(double now)
    {
        if (cards.Count == 0) return queue.Count > 0 ? 12 : 0;
        foreach (var c in cards)
        {
            if (c.Leaving || now < c.CalmAt || Math.Abs(c.Y - c.TargetY) > 0.05 || Math.Abs(c.Hover - (c.Hovered ? 1 : 0)) > 0.01) return 60;
        }
        return 12;
    }

    // MARK: 마우스(N-08·N-13): 카드 영역은 카드 자체 크기(+10 여유)로
    public Hit HitTest(float x, float y)
    {
        foreach (var c in cards)
        {
            if (c.Leaving) continue;
            var left = (PanelWidth - CardWidth) / 2;
            var top = c.Y;
            // 닫기 단추(왼쪽 위 -7,-7, 20×20) — 마우스를 올렸을 때만 보임
            if (c.Hover > 0.5 && x >= left - 7 && x <= left + 13 && y >= top - 7 && y <= top + 13) return new(c, HitPart.Close);
            if (x < left - 10 || x > left + CardWidth + 10 || y < top - 10 || y > top + c.Height + 10) continue;
            // 빠른 단추(오른쪽 아래, 24×22 두 개, 간격 4, 안쪽 여백 8)
            if (c.Kind == ToastKind.News && c.Hover > 0.5)
            {
                var by = top + c.Height - 8 - 22;
                var bx2 = left + CardWidth - 8 - 24;
                var bx1 = bx2 - 4 - 24;
                if (y >= by && y <= by + 22)
                {
                    if (x >= bx1 && x <= bx1 + 24) return new(c, HitPart.Save);
                    if (x >= bx2 && x <= bx2 + 24) return new(c, HitPart.Browser);
                }
            }
            return new(c, HitPart.Card);
        }
        return new(null, HitPart.None);
    }

    public void SetHover(ToastCard? c)
    {
        foreach (var k in cards) k.Hovered = k == c && !k.Leaving;
    }

    // 누름: 카드는 열고(뉴스·브리핑) 빠르게 사라짐, 닫기는 천천히 사라짐
    public void Click(Hit hit, double now)
    {
        if (hit.Card is not { Leaving: false } c) return;
        switch (hit.Part)
        {
            case HitPart.Card:
                if (c.Clickable) Opened?.Invoke(c);
                Leave(c, quick: true, now);
                break;
            case HitPart.Close:
                Leave(c, quick: false, now);
                break;
        }
    }
}
