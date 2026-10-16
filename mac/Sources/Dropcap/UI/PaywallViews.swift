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

// 읽기 창: 맛보기(유료벽 앞부분)만 받은 기사 — 본문 바로 위에, 무료 보도가 없어도 늘(READER-CUT.md C②). 무료 보도 상자와 따로
struct TeaserBanner: View {
    let link: String
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "lock.fill").font(.app(14, .semibold)).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("구독자만 전체를 볼 수 있는 기사예요").font(.app(13.5, .semibold))
                Text("아래는 사이트가 공개한 앞부분입니다.").font(.app(12.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("원문 열기") { ExternalLink.open(link) }
                .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.orange.opacity(0.28), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

// 본문 끝 한 줄: 맛보기가 끝난 자리, 또는 일부만 가져왔을 수 있음(READER-CUT.md A②·C②)
struct CutEndNote: View {
    let teaser: Bool
    let link: String
    let reload: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            Text(teaser ? "— 여기까지가 공개된 부분입니다" : "본문 일부만 가져왔을 수 있어요")
            Text("·")
            Button(teaser ? "원문에서 이어 읽기" : "원문 열기") { ExternalLink.open(link) }.buttonStyle(.plain).foregroundStyle(.tint)
            Text("·")
            Button("다시 받기", action: reload).buttonStyle(.plain).foregroundStyle(.tint)
        }
        .font(.app(12.5))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
