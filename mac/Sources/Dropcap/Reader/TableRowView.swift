import SwiftUI

// 읽기 창의 표 한 줄(Block.row): 셀을 같은 폭으로 나란히, 머리행은 굵게·옅은 바탕. 줄 사이 가는 선, 표 끝에는 아래 여백
struct TableRowView: View {
    let cells: [String]
    let head: Bool
    let font: Font
    let first: Bool
    let last: Bool

    var body: some View {
        VStack(spacing: 0) {
            if first { Divider() }
            HStack(alignment: .top, spacing: 12) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, c in
                    Text(c).font(font).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 7).padding(.horizontal, 8)
            .background(head ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear))
            Divider()
        }
        .padding(.top, first ? 4 : 0).padding(.bottom, last ? 20 : 0)
    }
}
