import SwiftUI

// 목록 줄·매거진 카드·스토리에 붙는 작은 자물쇠(G-14)
struct PaywallMark: View {
    let item: NewsItem
    var body: some View {
        if let k = PaywallBook.shared.kind(item) {
            Image(systemName: k.symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .help(k.label + (k.blocks ? " — 열면 같은 소식의 무료 보도를 먼저 권합니다" : ""))
                .accessibilityLabel(k.label)
        }
    }
}

// 읽기 창: 막힌 기사면 같은 스토리의 열리는 보도를 먼저 권한다(D-9). 원문 링크는 그대로 남는다.
struct FreeAlternativesBox: View {
    let item: NewsItem
    let alternatives: [NewsItem]
    let reason: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill").font(.app(11, .semibold))
                Text(reason).font(.app(12.5, .semibold))
            }
            .foregroundStyle(.secondary)
            Text("같은 소식을 무료로 읽기: " + alternatives.map(\.sourceName).joined(separator: "·"))
                .font(.app(13.5, .semibold))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(alternatives, id: \.key) { alt in
                    Button {
                        AppModel.shared.markOpened(alt)
                        ReaderController.open(alt)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(alt.sourceName).font(.app(12, .bold)).foregroundStyle(alt.accent)
                            Text(alt.displayTitle).font(.app(13)).lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right").font(.app(10, .semibold)).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("원문 그대로 열기") { ExternalLink.open(item.link) }
                .buttonStyle(.link).font(.app(12))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
    }
}
