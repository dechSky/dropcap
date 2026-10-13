import SwiftUI

// 아침 브리핑: 지난 하루 소식을 분야별로 모아 보는 창
struct DigestView: View {
    @ObservedObject private var model = AppModel.shared

    private var groups: [(NewsCategory, [NewsItem])] {
        let items = model.digestItems
        return NewsCategory.allCases.compactMap { c in
            let list = items.filter { $0.category == c }
            return list.isEmpty ? nil : (c, list)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Date().formatted(.dateTime.locale(Locale(identifier: "ko_KR")).month().day().weekday(.wide)))
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    Text("오늘의 AI 브리핑").font(.system(size: 28, weight: .bold)).tracking(-0.4)
                    Text("지난 24시간 동안 \(model.digestItems.count)건").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                if groups.isEmpty {
                    Text("지난 하루 동안 새 소식이 없었습니다.").foregroundStyle(.secondary)
                }
                ForEach(groups, id: \.0) { cat, items in
                    VStack(alignment: .leading, spacing: 6) {
                        Label("\(cat.label) \(items.count)", systemImage: cat.symbol)
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(cat.color)
                        ForEach(items) { it in
                            Button { model.open(it) } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Monogram(letter: it.initial, color: it.accent, size: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(it.displayTitle).font(.system(size: 14, weight: .medium))
                                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                                        Text("\(it.sourceName) · \(RelativeTime.string(it.date))")
                                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    if !model.isRead(it) { Circle().fill(it.accent).frame(width: 6, height: 6).padding(.top, 7) }
                                }
                                .padding(.vertical, 6).padding(.horizontal, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

@MainActor
enum DigestController {
    private static var window: NSWindow?

    static func open() {
        if let w = window, w.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentViewController: NSHostingController(rootView: DigestView()))
        w.title = "오늘의 AI 브리핑"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.setContentSize(NSSize(width: 640, height: 760))
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
