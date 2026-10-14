import SwiftUI

// 상단바 목록의 모양 시안들(카드 · 첫 소식 크게 · 시간 줄기). 고른 것만 남기고 정리할 예정.
enum MenuStyles {
    static let hhmm: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

    // 시간 묶음 이름표: 방금(1시간 안) · 오늘 · 어제 · 이전 — 앞 기사와 묶음이 바뀔 때만
    static func timeSection(_ it: NewsItem, prev: NewsItem?) -> String? {
        func bucket(_ d: Date?) -> String {
            guard let d else { return "이전" }
            if Date().timeIntervalSince(d) < 3600 { return "방금" }
            if Calendar.current.isDateInToday(d) { return "오늘" }
            if Calendar.current.isDateInYesterday(d) { return "어제" }
            return "이전"
        }
        let b = bucket(it.date)
        return prev.map { bucket($0.date) } == b ? nil : b
    }

    struct SectionLabel: View {
        let text: String
        var first = false
        var body: some View {
            HStack(spacing: 8) {
                Text(text).font(.app(11, .bold)).foregroundStyle(.secondary)
                Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
            }
            .padding(.horizontal, 8).padding(.top, first ? 4 : 12).padding(.bottom, 4)
        }
    }

    // 카드: 왼쪽 사진(없으면 출처 색 자리), 오른쪽 제목 두 줄 + 출처·분야·시각
    struct CardRow: View {
        let item: NewsItem
        let read: Bool
        let saved: Bool
        var compact = false
        let action: () -> Void
        @State private var hover = false
        var body: some View {
            Button(action: action) {
                HStack(alignment: .center, spacing: 11) {
                    RowThumb(item: item, width: compact ? 54 : 64, height: compact ? 54 : 64, radius: 10, placeholder: true)
                        .opacity(read ? 0.65 : 1)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.displayTitle)
                            .font(.app(13, read ? .regular : .semibold))
                            .foregroundStyle(read ? .secondary : .primary)
                            .lineLimit(2).multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 5) {
                            Text(item.sourceName).fontWeight(.semibold)
                            PaywallMark(item: item)
                            Text(item.topicLabel).foregroundStyle(item.topicColor)
                            Text(RelativeTime.string(item.date)).foregroundStyle(.tertiary)
                            if saved { Image(systemName: "bookmark.fill").foregroundStyle(item.accent) }
                        }
                        .font(.app(10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if !read { Circle().fill(item.accent).frame(width: 6, height: 6) }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(hover ? 0.08 : 0.035)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .padding(.vertical, 2)
        }
    }

    // 첫 소식 크게: 사진 위에 제목(아래 어둡게), 사진이 없으면 출처 색 바탕
    struct HeroCard: View {
        let item: NewsItem
        let read: Bool
        let action: () -> Void
        @State private var hover = false
        var body: some View {
            Button(action: action) {
                ZStack(alignment: .bottomLeading) {
                    RowThumb(item: item, width: 346, height: 168, radius: 14, placeholder: true)
                    LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(item.topicLabel).font(.app(10.5, .bold))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(item.topicColor.opacity(0.85), in: Capsule())
                            Text("\(item.sourceName) · \(RelativeTime.string(item.date))").font(.app(11, .medium)).opacity(0.85)
                            PaywallMark(item: item)
                        }
                        Text(item.displayTitle).font(.app(15.5, .bold)).lineLimit(2).multilineTextAlignment(.leading)
                    }
                    .foregroundStyle(.white)
                    .padding(13)
                }
                .frame(width: 346, height: 168)
                .scaleEffect(hover ? 1.01 : 1)
                .shadow(color: .black.opacity(hover ? 0.25 : 0.12), radius: hover ? 10 : 5, y: 3)
            }
            .buttonStyle(.plain)
            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
            .padding(.vertical, 4)
        }
    }

    // 시간 줄기: 왼쪽 시각과 세로 줄, 오른쪽 제목과 작은 사진
    struct TimelineRow: View {
        let item: NewsItem
        let read: Bool
        let last: Bool
        let action: () -> Void
        @State private var hover = false
        var body: some View {
            Button(action: action) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 0) {
                        Text(item.date.map { MenuStyles.hhmm.string(from: $0) } ?? "")
                            .font(.app(10.5, .semibold)).monospacedDigit()
                            .foregroundStyle(read ? .tertiary : .secondary)
                        Circle().fill(read ? Color.secondary.opacity(0.4) : item.accent).frame(width: 7, height: 7).padding(.top, 5)
                        if !last { Rectangle().fill(.primary.opacity(0.1)).frame(width: 1).frame(maxHeight: .infinity).padding(.top, 3) }
                    }
                    .frame(width: 38)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.displayTitle)
                            .font(.app(13, read ? .regular : .semibold))
                            .foregroundStyle(read ? .secondary : .primary)
                            .lineLimit(3).multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 5) {
                            Image(systemName: item.topicSymbol).foregroundStyle(item.topicColor)
                            Text(item.sourceName)
                            PaywallMark(item: item)
                        }
                        .font(.app(10.5)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    RowThumb(item: item, width: 52, height: 52, radius: 9).padding(.top, 2)
                }
                .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 10)
                .background(hover ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
        }
    }
}
