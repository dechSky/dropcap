import SwiftUI

// 목록 줄·매거진 카드·스토리·물방울에 붙는 작은 자물쇠(G-14). 맛보기로 판정된 기사는 잠긴 자물쇠 + '앞부분만'(주황)으로 따로
struct PaywallMark: View {
    let item: NewsItem
    @ObservedObject private var book = PaywallBook.shared
    var body: some View {
        if let k = book.kind(item) {
            HStack(spacing: Space.xxs) {
                Image(systemName: k.symbol)
                if let t = k.shortText { Text(t).font(.system(size: 9.5, weight: .semibold)).fixedSize() }
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(k == .teaser ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            .help(Self.help(k))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(k.label)
        }
    }
    static func help(_ k: PaywallKind) -> String {
        if k == .teaser { return "미리 받아 보니 사이트가 앞부분만 공개한 기사예요 — 열면 같은 소식의 무료 보도를 먼저 권합니다" }
        return k.label + (k.blocks ? " — 열면 같은 소식의 무료 보도를 먼저 권합니다" : "")
    }
}

// 읽기 창: 막힌 기사면 같은 스토리의 열리는 보도를 먼저 권한다(D-9). 원문 링크는 그대로 남는다.
struct FreeAlternativesBox: View {
    let item: NewsItem
    let alternatives: [NewsItem]
    let reason: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s) {
                Image(systemName: "lock.fill").font(.dsChip)
                Text(reason).font(.dsBodyStrong)
            }
            .foregroundStyle(.secondary)
            Text("같은 소식을 무료로 읽기: " + alternatives.map(\.sourceName).joined(separator: "·"))
                .font(.dsBodyStrong)
            VStack(alignment: .leading, spacing: Space.s) {
                ForEach(alternatives, id: \.key) { alt in
                    Button {
                        AppModel.shared.markOpened(alt)
                        ReaderController.open(alt)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                            Text(alt.sourceName).font(.dsBodyStrong).foregroundStyle(alt.accent)
                            Text(alt.displayTitle).font(.dsBody).lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right").font(.dsChip).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("원문 그대로 열기") { ExternalLink.open(item.link) }
                .buttonStyle(.link).font(.dsCallout)
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
    }
}

// 읽기 창: 맛보기(유료벽 앞부분)만 받은 기사 — 본문 바로 위에, 무료 보도가 없어도 늘. 무료 보도 상자와 따로
struct TeaserBanner: View {
    let link: String
    var body: some View {
        HStack(alignment: .center, spacing: Space.m) {
            Image(systemName: "lock.fill").font(.dsHeadline).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("구독자만 전체를 볼 수 있는 기사예요").font(.dsBodyStrong)
                Text("아래는 사이트가 공개한 앞부분입니다.").font(.dsCallout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("원문 열기") { ExternalLink.open(link) }
                .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, Space.l).padding(.vertical, Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.orange.opacity(0.28), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

// 본문 끝 한 줄: 맛보기가 끝난 자리, 또는 일부만 가져왔을 수 있음
struct CutEndNote: View {
    let teaser: Bool
    let link: String
    let reload: () -> Void
    var body: some View {
        HStack(spacing: Space.s) {
            Text(teaser ? "— 여기까지가 공개된 부분입니다" : "본문 일부만 가져왔을 수 있어요")
            Text("·")
            Button(teaser ? "원문에서 이어 읽기" : "원문 열기") { ExternalLink.open(link) }.buttonStyle(.plain).foregroundStyle(.tint)
            Text("·")
            Button("다시 받기", action: reload).buttonStyle(.plain).foregroundStyle(.tint)
        }
        .font(.dsCallout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
