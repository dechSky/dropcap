import Foundation

// '지금 보여 줄 출처' 판단 한 곳: 출처 목록에 있고 · 켜져 있고 · 숨기지 않은 출처의 글만 보인다.
// 구독을 끄거나 해지하거나 분야를 빼면 그 출처 글은 목록·매거진·스토리·검색·알림 대기열·위젯에서 빠지고(지우지 않음),
// 다시 켜면 그대로 돌아온다. 저장한 기사는 사용자가 고른 것이라 이 판단을 받지 않는다.
struct SourceFilter: Sendable, Equatable {
    var hidden: Set<String> = []
    var active: Set<String>? = nil   // nil 이면 켜짐 여부를 따지지 않음(시험·예전 호 옮기기)

    func shows(_ sourceId: String) -> Bool {
        !hidden.contains(sourceId) && (active?.contains(sourceId) ?? true)
    }
    func visible(_ items: [NewsItem]) -> [NewsItem] { items.filter { shows($0.sourceId) } }

    // 앱 상태와 출처 목록으로 만든다(순수 함수 — 시험에서 그대로 씀)
    static func make(state: AppState, sources: [Source]) -> SourceFilter {
        let hidden = Set(state.hiddenSources)
        let on = Set(sources.map(\.id).filter { state.enabled[$0] == true })
        return SourceFilter(hidden: hidden, active: on.subtracting(hidden))
    }
}
