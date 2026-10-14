import SwiftUI

// 일요일 저녁(17시부터) 스크랩북 첫머리에 '이번 주 모은 문장' — 지난 7일 동안 문단으로 스크랩한 글
struct WeeklyQuotes: View {
    @ObservedObject private var book = Scrapbook.shared
    var now = Date()

    nonisolated static func isSundayEvening(_ d: Date, calendar: Calendar = .current) -> Bool {
        if ProcessInfo.processInfo.environment["DROPCAP_TEST_WEEKLY"] != nil { return true } // 시험용
        let c = calendar.dateComponents([.weekday, .hour], from: d)
        return c.weekday == 1 && (c.hour ?? 0) >= 17
    }

    // 최근 것부터, 같은 문장은 한 번만
    nonisolated static func pick(_ scraps: [Scrap], now: Date, limit: Int = 6) -> [Scrap] {
        var seen = Set<String>()
        return scraps.filter { s in
            guard let q = s.quote, !q.isEmpty, now.timeIntervalSince(s.created) < 7 * 86400, s.created <= now.addingTimeInterval(60) else { return false }
            return seen.insert(q).inserted
        }
        .sorted { $0.created > $1.created }
        .prefix(limit).map { $0 }
    }

    var body: some View {
        let list = Self.pick(book.scraps, now: now)
        if Self.isSundayEvening(now), !list.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Label("이번 주 모은 문장", systemImage: "text.quote").font(.display(20, .bold))
                    Spacer()
                    Text("\(list.count)개 · 지난 7일").font(.app(12)).foregroundStyle(.secondary)
                }
                ForEach(list) { s in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("“\(s.quote ?? "")”").font(.app(14.5)).lineSpacing(4).lineLimit(5)
                            .textSelection(.enabled)
                        HStack(spacing: 6) {
                            Text(s.item.sourceName).font(.app(11.5, .semibold)).foregroundStyle(s.item.accent)
                            Text(s.item.displayTitle).font(.app(11.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Capsule().fill(s.item.accent.opacity(0.55)).frame(width: 3) }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { ReaderController.open(s.item) }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.yellow.opacity(0.25), lineWidth: 0.5))
        }
    }
}
