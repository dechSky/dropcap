import SwiftUI

// MARK: - 보관함(지난 기사)
// 일·주·월·연 단추와 ◀ ▶ 로 기간을 고르고, 그 기간의 기사를 최신순으로 본다(분야·출처 거르기, 100건씩 더 보기).
// 월·연은 날짜별 건수 막대를 먼저 보이고(막대를 누르면 그날로), 그날 지난 호가 있으면 맨 위에 '이 날의 호 보기'.
struct ArchiveView: View {
    let onIssue: (Issue) -> Void
    var start: (period: Archive.Period, anchor: Date)? = nil // 처음 보일 기간(시험 장면)
    @ObservedObject private var mag = Magazine.shared
    @AppStorage("archivePeriod") private var periodRaw = Archive.Period.month.rawValue
    @State private var anchor = Date()
    @State private var section: String?
    @State private var source: String?
    @State private var limit = Self.pageSize
    @State private var page: Archive.Page?
    @State private var earliest: Date?
    static let pageSize = 100

    private var period: Archive.Period { Archive.Period(rawValue: periodRaw) ?? .month }
    private var range: (from: Date, to: Date) { Archive.range(period, containing: anchor) }
    private var canNext: Bool { range.to <= Date() }
    private var canPrev: Bool { earliest.map { range.from > $0 } ?? false }
    private var loadKey: String { "\(periodRaw)|\(range.from.timeIntervalSince1970)|\(section ?? "")|\(source ?? "")|\(limit)|\(mag.revision)" }

    // 고른 날의 지난 호(일 보기에서만)
    private var dayIssue: Issue? {
        guard period == .day else { return nil }
        let id = "daily-" + Magazine.dayID(range.from)
        return mag.archive.first { $0.id == id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                head
                controls
                if let dayIssue {
                    Button { onIssue(dayIssue) } label: {
                        Label("이 날의 호 보기 — \(dayIssue.title)", systemImage: "doc.richtext")
                            .font(.dsBodyStrong).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Space.m)
                            .background(Palette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    }
                    .buttonStyle(.plain).foregroundStyle(Palette.accent)
                }
                if let page {
                    if period.showsBars, page.total > 0 {
                        DayBars(days: Archive.days(range.from, range.to), counts: page.dayCounts, compact: period == .year) { d in
                            anchor = d; periodRaw = Archive.Period.day.rawValue
                        }
                    }
                    if page.items.isEmpty {
                        Text(section == nil && source == nil ? "이 기간에는 모인 기사가 없습니다." : "거른 조건에 맞는 기사가 없습니다.")
                            .font(.dsBody).foregroundStyle(Palette.inkSecondary).padding(.vertical, Space.xxl)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(page.items) { it in
                                ArchiveRow(item: it, showDay: period != .day)
                                Divider().opacity(0.5)
                            }
                        }
                        if page.more {
                            Button("100건 더 보기") { limit += Self.pageSize }.buttonStyle(.link).font(.dsBody)
                        }
                    }
                } else {
                    ProgressView().controlSize(.small).padding(.vertical, Space.xl)
                }
            }
            .padding(.horizontal, Space.xxl).padding(.bottom, Space.xxxl)
        }
        .task {
            if let start { periodRaw = start.period.rawValue; anchor = start.anchor }
            earliest = await mag.earliestRecord()
        }
        .task(id: loadKey) {
            let r = range
            let p = await mag.archivePeriod(from: r.from, to: r.to, section: section, source: source, limit: limit)
            if !Task.isCancelled { page = p }
        }
    }

    private var head: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("보관함").font(.dsChip).foregroundStyle(Palette.inkSecondary).padding(.top, Space.xl)
            Text(Archive.title(period, anchor)).font(.dsTitle)
            Text(page.map { "기사 \($0.total)건" + ($0.more ? " · 최신순 \($0.items.count)건 보는 중" : "") } ?? " ")
                .font(.dsCallout).foregroundStyle(Palette.inkSecondary)
        }
    }

    private var controls: some View {
        HStack(spacing: Space.m) {
            Picker("기간", selection: Binding(get: { period }, set: { periodRaw = $0.rawValue; limit = Self.pageSize })) {
                ForEach(Archive.Period.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 200)
            HStack(spacing: Space.xs) {
                Button { move(-1) } label: { Image(systemName: "chevron.left") }.disabled(!canPrev).help("이전 기간")
                Button { move(1) } label: { Image(systemName: "chevron.right") }.disabled(!canNext).help("다음 기간")
                Button("오늘") { anchor = Date(); limit = Self.pageSize }.disabled(Archive.range(period, containing: Date()).from == range.from)
            }
            Spacer(minLength: 0)
            filterMenu(title: section.map { Sections.name($0) } ?? "모든 분야", counts: page?.sections ?? [:], name: { Sections.name($0) },
                       order: { Sections.order($0) }, pick: { section = $0; limit = Self.pageSize }, current: section)
            filterMenu(title: source ?? "모든 출처", counts: page?.sources ?? [:], name: { $0 }, order: { _ in 0 },
                       pick: { source = $0; limit = Self.pageSize }, current: source)
        }
    }

    private func filterMenu(title: String, counts: [String: Int], name: @escaping (String) -> String, order: @escaping (String) -> Int,
                            pick: @escaping (String?) -> Void, current: String?) -> some View {
        Menu(title) {
            Button("전체") { pick(nil) }
            Divider()
            // 건수 많은 순(분야는 같은 건수면 분야 순서)
            ForEach(counts.sorted { ($0.value, -order($0.key)) > ($1.value, -order($1.key)) }, id: \.key) { k, n in
                Button { pick(k) } label: { Text("\(name(k))  \(n)") + (k == current ? Text("  ✓") : Text("")) }
            }
        }
        .menuStyle(.borderlessButton).fixedSize().font(.dsBody)
    }

    private func move(_ n: Int) { anchor = Archive.shift(period, anchor, by: n); limit = Self.pageSize }
}

// 날짜별 건수 막대(월·연). 막대를 누르면 그날 보기로
private struct DayBars: View {
    let days: [Date]
    let counts: [String: Int]
    let compact: Bool
    let pick: (Date) -> Void

    var body: some View {
        let peak = max(1, counts.values.max() ?? 1)
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .bottom, spacing: compact ? 1 : Space.xxs) {
                ForEach(days, id: \.self) { d in
                    let n = counts[Archive.dayKey(d)] ?? 0
                    Button { pick(d) } label: {
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: compact ? 1 : Radius.xs / 2, style: .continuous)
                                .fill(n == 0 ? Palette.separator : Palette.accent.opacity(0.75))
                                .frame(height: n == 0 ? 2 : max(3, 72 * CGFloat(n) / CGFloat(peak)))
                        }
                        .frame(maxWidth: .infinity).frame(height: 72).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(n == 0)
                    .help("\(Archive.title(.day, d)) · \(n)건")
                }
            }
            HStack {
                Text(Archive.dayKey(days.first ?? Date()).replacingOccurrences(of: "-", with: ". "))
                Spacer()
                Text("하루 많게는 \(peak)건")
                Spacer()
                Text(Archive.dayKey(days.last ?? Date()).replacingOccurrences(of: "-", with: ". "))
            }
            .font(.dsCaption).foregroundStyle(Palette.inkTertiary).monospacedDigit()
        }
        .padding(Space.m)
        .background(Palette.ink.opacity(0.03), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

// 보관 기사 한 줄: 때 · 분야 · 제목 · 출처. 누르면 읽기 창(본문은 링크에서 다시 받음)
struct ArchiveRow: View {
    let item: ArchivedItem
    var showDay = true
    @State private var hover = false

    private var when: String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: item.date)
        let time = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        return showDay ? "\(c.month ?? 0)/\(c.day ?? 0) \(time)" : time
    }

    var body: some View {
        Button { ReaderController.open(item.newsItem) } label: {
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                Text(when).font(.dsCaption).foregroundStyle(Palette.inkTertiary).monospacedDigit().frame(width: showDay ? 76 : 40, alignment: .leading)
                Circle().fill(Palette.section(item.section)).frame(width: 6, height: 6).help(Sections.name(item.section))
                Text(item.displayTitle).font(.dsBody).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                Text(item.source).font(.dsCaption).foregroundStyle(Palette.inkSecondary).lineLimit(1)
            }
            .padding(.vertical, Space.s).padding(.horizontal, Space.xs)
            .background(hover ? Palette.ink.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu {
            Button("브라우저에서 열기") { ExternalLink.open(item.link) }
            if item.titleKo != nil { Text(item.title) }
        }
    }
}
