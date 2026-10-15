import SwiftUI

// 투명 제목줄(fullSizeContentView + titlebarAppearsTransparent) 창의 머리 겹침 막기.
// 머리 높이(위쪽 safe area)만큼 바탕색을 깐다 — 맨 위에서는 바탕과 같은 색이라 지금처럼 투명해 보이고,
// 본문이 머리 밑으로 들어가면 글이 비쳐 겹쳐 보이지 않는다. 내용이 머리 밑으로 들어간 동안만 아래 얇은 구분선.
struct TitlebarBackdrop: View {
    var fill: Color
    var separator: Bool

    var body: some View {
        GeometryReader { g in
            VStack(spacing: 0) {
                fill.frame(height: g.safeAreaInsets.top)
                Divider().opacity(separator ? 1 : 0)
                Spacer(minLength: 0)
            }
            .ignoresSafeArea(edges: .top)
            .animation(.easeOut(duration: 0.15), value: separator)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// 스크롤 내용이 맨 위를 지나 머리 밑으로 들어갔는지(macOS 14 — onScrollGeometryChange 없음).
// 스크롤 내용 맨 위에 .reportsScrolledPastTop(in:) 를 달고, 바깥에서 onPreferenceChange(ScrolledPastTopKey.self) 로 받는다.
struct ScrolledPastTopKey: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

extension View {
    func reportsScrolledPastTop(in space: String) -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: ScrolledPastTopKey.self, value: g.frame(in: .named(space)).minY < -1)
        })
    }
}
