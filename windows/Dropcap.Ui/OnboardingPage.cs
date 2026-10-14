using System.Text.Json.Nodes;
using Dropcap.Core;

namespace Dropcap.Ui;

// 첫 실행 관심 분야 고르기(G-03, 맥 OnboardingView). 처음 실행 때 열리고, 설정 › 분야에서 다시 연다.
// 화면은 카드를 그리고 고른 것을 들고만 있다. 고르기를 마치면 여기서 model.ChooseSections.
// 카드는 분야 유리 카드(맥 SectionGlassCard): 분야마다 오늘의 사진(SectionPhotos — 처음 실행이면 피드를 바로 받아 옴).
public sealed class OnboardingPage : IPage
{
    public string Name => "onboarding";
    private readonly AppModel model;
    private readonly IPlatform platform;

    // 분야 사진. 시험에서는 바꿔 끼운다(바깥 피드를 받지 않게)
    public Action<IEnumerable<string>> LoadPhotos { get; set; } = ids => SectionPhotos.Shared.Load(ids);
    public Func<string, string?> PhotoUrl { get; set; } = id => SectionPhotos.Shared.Url(id);

    // bridge 가 있으면 사진을 찾는 대로 화면에 'photos' 로 알린다. 없으면 화면이 잠깐씩 'photos' 를 물어본다
    public OnboardingPage(AppModel model, IPlatform platform, Bridge? bridge = null)
    {
        this.model = model;
        this.platform = platform;
        if (bridge is not null) SectionPhotos.Shared.Changed += () => bridge.Emit(Name, "photos", Photos());
    }

    public const string TopHelp = "어느 분야든 여러 곳이 함께 크게 다룬 소식만 골라 알려 드려요";

    // 유리 카드 아래 줄: 대표 출처 2~3곳(처음 고르면 켜질 곳 먼저 — 맥 SectionCard 와 같음). 없으면 AI 는 예시, 나머지는 줄 없음
    public static string? SourceLine(string sectionId, Dictionary<string, SourceMeta>? meta = null)
    {
        var names = Sections.SourcesIn(sectionId, meta)
            .OrderBy(s => s.DefaultOn == true ? 0 : 1)   // 안정 정렬이라 같은 무리 안은 이름순 그대로
            .Take(3).Select(s => s.Name ?? s.Id).ToList();
        if (names.Count > 0) return string.Join(" · ", names);
        return sectionId == Sections.Ai ? "OpenAI · Anthropic · AI타임스" : null;
    }

    // 분야 → 사진 주소(찾은 것만)
    public Dictionary<string, string> Photos()
    {
        var o = new Dictionary<string, string>();
        foreach (var s in Sections.Pickable) if (PhotoUrl(s.Id) is { } u) o[s.Id] = u;
        return o;
    }

    public object View()
    {
        var chosen = model.State.SectionsChosen;
        var top = Sections.ById(Sections.Top);
        var picked = (chosen ?? new()).Where(id => id != Sections.Top && Sections.ById(id) is { IsFlow: false }).ToList();
        LoadPhotos(Sections.Pickable.Select(s => s.Id));   // 아직 없는 분야만 찾는다
        return new
        {
            first = chosen is null,
            // 주요 뉴스 흐름 스위치: 처음에는 켬, 다시 열면 지금 고른 대로
            top = top is null ? null : new
            {
                id = top.Id, label = top.Name, icon = top.Icon, color = ItemView.SafeColor(top.Color), help = TopHelp,
                on = chosen is null || chosen.Contains(top.Id),
            },
            cards = Sections.Pickable.Select(s => new
            {
                id = s.Id, label = s.Name, icon = s.Icon, color = ItemView.SafeColor(s.Color), more = s.IsMore,
                sources = SourceLine(s.Id), english = SectionPhotos.English(s.Id), photo = PhotoUrl(s.Id),
            }).ToList(),
            picked,
            // '더 보기' 분야를 이미 골랐으면 처음부터 펼쳐 둔다
            showMore = picked.Any(id => Sections.ById(id)?.IsMore == true),
        };
    }

    // 고른 분야(카드) + 주요 뉴스 스위치 → 저장할 목록. 모르는 id·흐름은 버리고, 카드가 하나도 없으면 거절
    public static List<string> Picks(IEnumerable<string> ids, bool top)
    {
        var pickable = Sections.Pickable.Select(s => s.Id).ToHashSet();
        var o = ids.Where(pickable.Contains).Distinct().ToList();
        if (o.Count == 0) throw new InvalidOperationException("분야를 하나 이상 골라 주세요");
        if (top && Sections.ById(Sections.Top) is not null) o.Insert(0, Sections.Top);
        return o;
    }

    public Task<object?> Handle(string cmd, JsonObject a)
    {
        switch (cmd)
        {
            case "ready":
            case "view":
                return Task.FromResult<object?>(View());
            case "choose":
                var ids = (a["ids"] as JsonArray ?? new JsonArray())
                    .Select(n => n is JsonValue v && v.TryGetValue<string>(out var s) ? s : null).OfType<string>();
                model.ChooseSections(Picks(ids, a.Bool("top", true)));
                platform.CloseWindow(Name);
                return Task.FromResult<object?>(null);
            case "photos":
                return Task.FromResult<object?>(Photos());
            case "close":
                platform.CloseWindow(Name);
                return Task.FromResult<object?>(null);
            default: throw new InvalidOperationException("모르는 명령 " + cmd);
        }
    }
}
