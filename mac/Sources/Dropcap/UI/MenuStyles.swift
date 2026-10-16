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
            HStack(spacing: Space.s) {
                Text(text).font(.dsChip).foregroundStyle(.secondary)
                Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
            }
            .padding(.horizontal, Space.s).padding(.top, first ? 4 : 12).padding(.bottom, Space.xs)
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
                HStack(alignment: .center, spacing: Space.m) {
                    RowThumb(item: item, width: compact ? 54 : 64, height: compact ? 54 : 64, radius: 10, placeholder: true)
                        .opacity(read ? 0.65 : 1)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(item.displayTitle)
                            .font(.app(13, read ? .regular : .semibold))
                            .foregroundStyle(read ? .secondary : .primary)
                            .lineLimit(2).multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: Space.xs) {
                            Text(item.sourceName).fontWeight(.semibold)
                            PaywallMark(item: item)
                            Text(item.topicLabel).foregroundStyle(item.topicColor)
                            if let x = item.extraTopic { Text(Sections.name(x)).foregroundStyle(Sections.byID(x)?.tint ?? .gray) }
                            Text(RelativeTime.string(item.date)).foregroundStyle(.tertiary)
                            if saved { Image(systemName: "bookmark.fill").foregroundStyle(item.accent) }
                        }
                        .font(.dsCaption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if !read { Circle().fill(item.accent).frame(width: 6, height: 6) }
                }
                .padding(Space.s)
                .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(.primary.opacity(hover ? 0.08 : 0.035)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .padding(.vertical, Space.xxs)
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
                        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    VStack(alignment: .leading, spacing: Space.xs) {
                        HStack(spacing: Space.s) {
                            Text(item.topicLabel).font(.dsChip)
                                .padding(.horizontal, Space.s).padding(.vertical, Space.xxs)
                                .background(item.topicColor.opacity(0.85), in: Capsule())
                            if let x = item.extraTopic {
                                Text(Sections.name(x)).font(.dsChip)
                                    .padding(.horizontal, Space.s).padding(.vertical, Space.xxs)
                                    .background((Sections.byID(x)?.tint ?? .gray).opacity(0.85), in: Capsule())
                            }
                            Text("\(item.sourceName) · \(RelativeTime.string(item.date))").font(.dsCaption).opacity(0.85)
                            PaywallMark(item: item)
                        }
                        Text(item.displayTitle).font(.dsHeadline).lineLimit(2).multilineTextAlignment(.leading)
                    }
                    .foregroundStyle(.white)
                    .padding(Space.m)
                }
                .frame(width: 346, height: 168)
                .scaleEffect(hover ? 1.01 : 1)
                .elevation(hover ? Elevation.card : Elevation.low)
            }
            .buttonStyle(.plain)
            .onHover { h in withMotion(Motion.snap) { hover = h } }
            .padding(.vertical, Space.xs)
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
                HStack(alignment: .top, spacing: Space.m) {
                    VStack(spacing: 0) {
                        Text(item.date.map { MenuStyles.hhmm.string(from: $0) } ?? "")
                            .font(.dsChip).monospacedDigit()
                            .foregroundStyle(read ? .tertiary : .secondary)
                        Circle().fill(read ? Color.secondary.opacity(0.4) : item.accent).frame(width: 7, height: 7).padding(.top, Space.xs)
                        if !last { Rectangle().fill(.primary.opacity(0.1)).frame(width: 1).frame(maxHeight: .infinity).padding(.top, Space.xs) }
                    }
                    .frame(width: 38)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(item.displayTitle)
                            .font(.app(13, read ? .regular : .semibold))
                            .foregroundStyle(read ? .secondary : .primary)
                            .lineLimit(3).multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: Space.xs) {
                            Image(systemName: item.topicSymbol).foregroundStyle(item.topicColor)
                            Text(item.sourceName)
                            PaywallMark(item: item)
                        }
                        .font(.dsCaption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    RowThumb(item: item, width: 52, height: 52, radius: 9).padding(.top, Space.xxs)
                }
                .padding(.horizontal, Space.s).padding(.top, Space.s).padding(.bottom, Space.m)
                .background(hover ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
        }
    }
}
