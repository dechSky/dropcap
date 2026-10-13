import SwiftUI

// 상단바 아이콘을 누르면 내려오는 창: 최근 소식(전체·안 읽음·저장) + 몇 가지 동작
struct MenuView: View {
    @ObservedObject var model = AppModel.shared
    @Environment(\.openSettings) private var openSettings
    @State private var tab: Tab = .all
    @State private var query = ""
    @State private var category: NewsCategory?
    @AppStorage("listSort") private var sortRaw = "newest"

    enum Tab: String, CaseIterable { case all = "전체", unread = "안 읽음", saved = "저장" }

    private var items: [NewsItem] {
        var list: [NewsItem]
        switch tab {
        case .all: list = model.state.recent
        case .unread: list = model.state.recent.filter { !model.isRead($0) }
        case .saved: list = model.state.saved
        }
        if let c = category { list = list.filter { $0.category == c } }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter { "\($0.title) \($0.titleKo ?? "") \($0.sourceName) \($0.summary)".lowercased().contains(q) }
        }
        switch sortRaw {
        case "important": // 중요 표시 → 여러 곳 보도 → 최신
            return list.sorted { a, b in
                let ia = a.important == true ? 1 : 0, ib = b.important == true ? 1 : 0
                if ia != ib { return ia > ib }
                let ra = a.related?.count ?? 0, rb = b.related?.count ?? 0
                if ra != rb { return ra > rb }
                return (a.date ?? .distantPast) > (b.date ?? .distantPast)
            }
        case "source": return list.sorted { ($0.sourceName, $1.date ?? .distantPast) < ($1.sourceName, $0.date ?? .distantPast) }
        default: return list.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { t in
                    Text(t == .unread ? "안 읽음 \(model.state.recent.filter { !model.isRead($0) }.count)" : t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14).padding(.bottom, 8)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.app(11))
                TextField("제목·출처 검색", text: $query).textFieldStyle(.plain).font(.app(12))
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
                }
                Menu {
                    Picker("정렬", selection: $sortRaw) {
                        Label("최신순", systemImage: "clock").tag("newest")
                        Label("중요·많이 보도된 순", systemImage: "star").tag("important")
                        Label("출처별", systemImage: "building.2").tag("source")
                    }
                    .pickerStyle(.inline)
                } label: { Image(systemName: "arrow.up.arrow.down").font(.app(11)).foregroundStyle(.secondary) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("정렬")
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .padding(.horizontal, 14)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    chip(nil, "전체 분야", "square.grid.2x2")
                    ForEach(NewsCategory.allCases.filter { $0 != .other }) { c in chip(c, c.label, c.symbol) }
                }
                .padding(.horizontal, 14)
            }
            .padding(.vertical, 8)
            Divider().opacity(0.5)
            if items.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(items) { it in
                            Row(item: it, read: model.isRead(it), saved: model.isSaved(it)) { model.open(it) }
                                .contextMenu { menu(for: it) }
                        }
                    }
                    .padding(6)
                }
                .frame(height: min(CGFloat(items.count) * 70 + 12, 440))
            }
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 370)
        .onAppear { model.markRead() }
    }

    private func chip(_ c: NewsCategory?, _ label: String, _ symbol: String) -> some View {
        let on = category == c
        let color = c?.color ?? .accentColor
        return Button { category = c } label: {
            Label(label, systemImage: symbol)
                .font(.system(size: 11, weight: on ? .semibold : .regular))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .foregroundStyle(on ? color : .secondary)
                .background(on ? color.opacity(0.15) : Color.primary.opacity(0.05), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func menu(for it: NewsItem) -> some View {
        Button(model.isSaved(it) ? "저장 취소" : "나중에 읽기") { model.toggleSaved(it) }
        Button(model.isRead(it) ? "안 읽음으로 표시" : "읽음으로 표시") { model.setRead(it, !model.isRead(it)) }
        Divider()
        Button("브라우저에서 열기") { ExternalLink.open(it.link) }
        Button("링크 복사") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(it.link, forType: .string)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("AI 소식").font(.app(15, .bold))
                    if model.isQuietTime {
                        Label("방해 금지", systemImage: "moon.fill").labelStyle(.iconOnly)
                            .font(.app(11)).foregroundStyle(.indigo).help("방해 금지 시간이라 알림을 띄우지 않습니다")
                    }
                }
                Text(model.checking ? "확인하는 중…" : "마지막 확인 \(AppModel.clock(model.state.lastCheck))")
                    .font(.app(11)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Menu {
                if model.isSnoozed {
                    Button("다시 알림 켜기") { model.snooze(nil) }
                } else {
                    Button("1시간 동안") { model.snooze(Date().addingTimeInterval(3600)) }
                    Button("3시간 동안") { model.snooze(Date().addingTimeInterval(3 * 3600)) }
                    Button("내일 아침 8시까지") { model.snooze(AppModel.tomorrowMorning()) }
                }
            } label: {
                Image(systemName: model.isSnoozed ? "bell.slash.fill" : "bell").font(.app(12))
                    .foregroundStyle(model.isSnoozed ? Color.orange : Color.secondary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(model.isSnoozed ? "알림 꺼짐 — \(AppModel.clock(model.state.snoozeUntil))까지" : "알림 잠시 끄기")
            Button { MagazineController.open() } label: { Image(systemName: "book.pages").font(.app(12)) }
                .buttonStyle(.borderless).help("AI 매거진 (⌥⌘M)")
            Button { model.markAllRead() } label: { Image(systemName: "checkmark.circle").font(.app(13)) }
                .buttonStyle(.borderless).help("모두 읽음으로 표시")
            Button {
                Task { await model.checkAll(manual: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.app(12, .semibold))
                    .rotationEffect(.degrees(model.checking ? 360 : 0))
                    .animation(model.checking ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: model.checking)
            }
            .buttonStyle(.borderless)
            .disabled(model.checking)
            .help("지금 확인")
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: tab == .saved ? "bookmark" : "newspaper").font(.app(26, .light)).foregroundStyle(.tertiary)
            Text(!query.isEmpty || category != nil ? "맞는 소식이 없습니다" : tab == .saved ? "저장한 소식이 없습니다" : tab == .unread ? "모두 읽었습니다" : "아직 새 소식이 없습니다")
                .font(.app(13, .medium))
            Text(tab == .saved ? "소식을 오른쪽 클릭해 '나중에 읽기'로 저장할 수 있어요" : "새 글이 올라오면 물방울이 떨어지듯 알려 드려요")
                .font(.app(11.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var footer: some View {
        HStack(spacing: 2) {
            Button { MagazineController.open() } label: { Label("매거진", systemImage: "book.pages") }
            Button { model.preview() } label: { Label("미리 보기", systemImage: "play.circle") }
            Spacer()
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: { Label("설정", systemImage: "gearshape") }
            Button { NSApp.terminate(nil) } label: { Label("종료", systemImage: "power") }
        }
        .buttonStyle(FooterButton())
        .padding(.horizontal, 8).padding(.vertical, 6)
    }
}

private struct Row: View {
    let item: NewsItem
    let read: Bool
    let saved: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Monogram(letter: item.initial, color: item.accent, size: 28)
                    .opacity(read ? 0.55 : 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayTitle)
                        .font(.system(size: 13, weight: read ? .regular : .semibold))
                        .foregroundStyle(read ? .secondary : .primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 4) {
                        if item.important == true { Image(systemName: "star.fill").foregroundStyle(.orange) }
                        Image(systemName: item.category.symbol).foregroundStyle(item.category.color)
                        Text(item.sourceName)
                        if let r = item.related, !r.isEmpty { Text("외 \(r.count)곳") }
                        Text("·")
                        Text(RelativeTime.string(item.date))
                        if saved { Image(systemName: "bookmark.fill").foregroundStyle(item.accent) }
                    }
                    .font(.app(11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if !read {
                    Circle().fill(item.accent).frame(width: 7, height: 7).padding(.top, 6)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(hover ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct FooterButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FooterLabel(configuration: configuration)
    }
    private struct FooterLabel: View {
        let configuration: Configuration
        @State private var hover = false
        var body: some View {
            configuration.label
                .labelStyle(.titleAndIcon)
                .font(.app(12))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.primary.opacity(configuration.isPressed ? 0.12 : hover ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .onHover { hover = $0 }
        }
    }
}
