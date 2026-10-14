namespace Dropcap.Core;

// '지금 보여 줄 출처' 판단 한 곳(S-13, 맥 Core/SourceFilter.swift 와 같음): 출처 목록에 있고 · 켜져 있고 · 숨기지 않은 출처의 글만 보인다.
// 구독을 끄거나 해지하거나 분야를 빼면 그 출처 글은 목록·안 읽음 수·매거진·스토리·검색·알림 대기열에서 빠지고(지우지 않음),
// 다시 켜면 그대로 돌아온다. 저장한 기사는 사용자가 고른 것이라 이 판단을 받지 않는다.
public sealed record SourceFilter
{
    public IReadOnlySet<string> Hidden { get; init; } = new HashSet<string>();
    public IReadOnlySet<string>? Active { get; init; }   // null 이면 켜짐 여부를 따지지 않음(시험·예전 호 옮기기)

    public bool Shows(string sourceId) => !Hidden.Contains(sourceId) && (Active?.Contains(sourceId) ?? true);
    public List<NewsItem> Visible(IEnumerable<NewsItem> items) => items.Where(i => Shows(i.SourceId)).ToList();

    // 앱 상태와 출처 목록으로 만든다(순수 함수 — 시험에서 그대로 씀)
    public static SourceFilter Make(AppState state, IEnumerable<Source> sources)
    {
        var hidden = state.HiddenSources.ToHashSet();
        var on = sources.Select(s => s.Id).Where(id => state.Enabled.GetValueOrDefault(id) && !hidden.Contains(id)).ToHashSet();
        return new SourceFilter { Hidden = hidden, Active = on };
    }
}
