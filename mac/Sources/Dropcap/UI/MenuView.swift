import SwiftUI

// 상단바 아이콘을 누르면 내려오는 창: 최근 소식(전체·안 읽음·저장) + 몇 가지 동작
struct MenuView: View {
    @ObservedObject var model = AppModel.shared
    @Environment(\.openSettings) private var openSettings
    @State private var tab: Tab = .all
    @State private var query = ""
    @State private var category: NewsCategory?
    @AppStorage("listSort") private var sortRaw = "newest"
    @AppStorage("listStyle2") private var listStyle = "hero" // 기본: 첫 소식 크게(사용자 선택) · compact · cards · timeline 은 시안 비교용으로 남김
    var snapshot = false // 시험용: 스크롤 없이 그려 화면 없이 찍을 수 있게

    enum Tab: String, CaseIterable { case all = "전체", unread = "안 읽음", saved = "저장" }
    static let listHeight: CGFloat = 400

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
        case "important": return Self.byImportance(list, coverage: Magazine.shared.coverage(list))
        case "source": return list.sorted { ($0.sourceName, $1.date ?? .distantPast) < ($1.sourceName, $0.date ?? .distantPast) }
        default: return list.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        }
    }

    // 중요도 점수: 꼭 알림 낱말(★) > 여러 곳이 다룬 정도(스토리 크기·외 N곳) > 공식 발표 > 최근일수록 조금 더
    // (이전에는 ★와 '외 N곳'만 봐서, 둘 다 없는 날엔 최신순과 똑같았다)
    static func byImportance(_ list: [NewsItem], coverage: [String: Int], now: Date = Date()) -> [NewsItem] {
        func score(_ it: NewsItem) -> Double {
            let outlets = max(coverage[it.key] ?? 1, (it.related?.count ?? 0) + 1)
            let hours = max(0, now.timeIntervalSince(it.date ?? now) / 3600)
            return (it.important == true ? 100 : 0) + Double(outlets - 1) * 12 + (it.tier == "lab" ? 8 : 0) + 6 * exp(-hours / 12)
        }
        return list.map { ($0, score($0)) }.sorted { a, b in
            a.1 != b.1 ? a.1 > b.1 : (a.0.date ?? .distantPast) > (b.0.date ?? .distantPast)
        }.map(\.0)
    }

    private var sortLabel: String? {
        switch sortRaw { case "important": return "중요순"; case "source": return "출처별"; default: return nil }
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
                    Picker("분야", selection: $category) {
                        Label("전체 분야", systemImage: "square.grid.2x2").tag(NewsCategory?.none)
                        ForEach(NewsCategory.allCases) { c in Label(c.label, systemImage: c.symbol).tag(NewsCategory?.some(c)) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: category?.symbol ?? "line.3.horizontal.decrease")
                        if let c = category { Text(c.label).lineLimit(1) }
                    }
                    .font(.app(11, category == nil ? .regular : .semibold))
                    .foregroundStyle(category?.color ?? .secondary)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("분야 거르기")
                Menu {
                    Picker("정렬", selection: $sortRaw) {
                        Label("최신순", systemImage: "clock").tag("newest")
                        Label("중요·많이 보도된 순", systemImage: "star").tag("important")
                        Label("출처별", systemImage: "building.2").tag("source")
                    }
                    .pickerStyle(.inline)
                } label: {
                    // 지금 정렬이 무엇인지 보이게(최신순이 아닐 때는 이름까지)
                    HStack(spacing: 3) {
                        Image(systemName: sortRaw == "important" ? "star" : sortRaw == "source" ? "building.2" : "arrow.up.arrow.down")
                        if let l = sortLabel { Text(l).lineLimit(1) }
                    }
                    .font(.app(11, sortLabel == nil ? .regular : .semibold))
                    .foregroundStyle(sortLabel == nil ? Color.secondary : Color.accentColor)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("정렬")
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .padding(.horizontal, 14).padding(.bottom, 10)
            Divider().opacity(0.5)
            // 목록 칸 높이를 고정한다: 상단바 창은 내용이 줄어도 창 크기를 줄이지 않아 아래에 빈 칸이 남는다
            Group {
                if items.isEmpty {
                    empty.frame(maxHeight: .infinity)
                } else {
                    if snapshot {
                        VStack(spacing: 2) {
                            let list = items
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, it in
                                // 출처별일 때는 출처가 바뀌는 곳에 이름표
                                if sortRaw == "source", i == 0 || list[i - 1].sourceName != it.sourceName {
                                    HStack(spacing: 6) {
                                        Text(it.sourceName).font(.app(11, .bold))
                                        Text("\(list.filter { $0.sourceName == it.sourceName }.count)").font(.app(10.5)).foregroundStyle(.tertiary)
                                        Spacer()
                                    }
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8).padding(.top, i == 0 ? 2 : 10).padding(.bottom, 2)
                                }
                                if listStyle != "compact", sortRaw != "source", let label = MenuStyles.timeSection(it, prev: i > 0 ? list[i - 1] : nil), !(listStyle == "hero" && i == 0) {
                                    MenuStyles.SectionLabel(text: label, first: i == 0 || (listStyle == "hero" && i == 1))
                                }
                                Group {
                                    switch listStyle {
                                    case "cards": MenuStyles.CardRow(item: it, read: model.isRead(it), saved: model.isSaved(it)) { model.open(it) }
                                    case "hero" where i == 0: MenuStyles.HeroCard(item: it, read: model.isRead(it)) { model.open(it) }
                                    case "hero": MenuStyles.CardRow(item: it, read: model.isRead(it), saved: model.isSaved(it), compact: true) { model.open(it) }
                                    case "timeline": MenuStyles.TimelineRow(item: it, read: model.isRead(it), last: i == list.count - 1) { model.open(it) }
                                    default: Row(item: it, read: model.isRead(it), saved: model.isSaved(it)) { model.open(it) }
                                    }
                                }
                                .contextMenu { menu(for: it) }
                            }
                        }
                        .padding(6).frame(height: Self.listHeight, alignment: .top).clipped()
                    } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            let list = items
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, it in
                                // 출처별일 때는 출처가 바뀌는 곳에 이름표
                                if sortRaw == "source", i == 0 || list[i - 1].sourceName != it.sourceName {
                                    HStack(spacing: 6) {
                                        Text(it.sourceName).font(.app(11, .bold))
                                        Text("\(list.filter { $0.sourceName == it.sourceName }.count)").font(.app(10.5)).foregroundStyle(.tertiary)
                                        Spacer()
                                    }
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8).padding(.top, i == 0 ? 2 : 10).padding(.bottom, 2)
                                }
                                if listStyle != "compact", sortRaw != "source", let label = MenuStyles.timeSection(it, prev: i > 0 ? list[i - 1] : nil), !(listStyle == "hero" && i == 0) {
                                    MenuStyles.SectionLabel(text: label, first: i == 0 || (listStyle == "hero" && i == 1))
                                }
                                Group {
                                    switch listStyle {
                                    case "cards": MenuStyles.CardRow(item: it, read: model.isRead(it), saved: model.isSaved(it)) { model.open(it) }
                                    case "hero" where i == 0: MenuStyles.HeroCard(item: it, read: model.isRead(it)) { model.open(it) }
                                    case "hero": MenuStyles.CardRow(item: it, read: model.isRead(it), saved: model.isSaved(it), compact: true) { model.open(it) }
                                    case "timeline": MenuStyles.TimelineRow(item: it, read: model.isRead(it), last: i == list.count - 1) { model.open(it) }
                                    default: Row(item: it, read: model.isRead(it), saved: model.isSaved(it)) { model.open(it) }
                                    }
                                }
                                .contextMenu { menu(for: it) }
                            }
                        }
                        .padding(6)
                    }
                    }
                }
            }
            .frame(height: Self.listHeight)
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 370)
        .fixedSize()
        .onAppear {
            model.markRead()
            // 열자마자 검색칸에 입력 커서가 들어가지 않게
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
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
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Dropcap").font(.app(16, .heavy)).tracking(-0.3)
                    if model.isQuietTime {
                        Label("방해 금지", systemImage: "moon.fill").labelStyle(.iconOnly)
                            .font(.app(11)).foregroundStyle(.indigo).help("방해 금지 시간이라 알림을 띄우지 않습니다")
                    }
                }
                Text(model.checking ? "확인하는 중…" : "마지막 확인 \(AppModel.clock(model.state.lastCheck))")
                    .font(.app(11)).foregroundStyle(.secondary).monospacedDigit()
                    .lineLimit(1).fixedSize()
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
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
        HStack(spacing: 4) {
            Button { MagazineController.open() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "book.pages.fill")
                    Text("매거진 열기").font(.app(12.5, .semibold))
                    Text("⌥⌘M").font(.app(11)).foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            Spacer()
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: { Image(systemName: "gearshape").font(.app(13)) }
            .buttonStyle(FooterButton()).help("설정")
            Menu {
                Button("모두 읽음으로 표시") { model.markAllRead() }
                Button("알림 미리 보기") { model.preview() }
                Divider()
                Button("Dropcap 종료") { NSApp.terminate(nil) }
            } label: { Image(systemName: "ellipsis.circle").font(.app(13)) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("더 보기")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
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
                RowThumb(item: item).opacity(read ? 0.6 : 1)
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

// 목록 줄의 작은 사진: 피드 사진, 없으면 매거진이 기사 머리에서 찾아 둔 대표 사진. 사진이 없으면 자리를 차지하지 않는다
struct RowThumb: View {
    let item: NewsItem
    var width: CGFloat = 56
    var height: CGFloat = 42
    var radius: CGFloat = 7
    var placeholder = false     // 사진이 없을 때 분야 색 자리 표시
    @State private var image: NSImage?
    @MainActor static var preloaded: [String: NSImage] = [:] // 시험용: 화면 없이 찍을 때 미리 받아 둔 사진

    var body: some View {
        Group {
            if let image = image ?? Self.preloaded[item.key] {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
                    .transition(.opacity)
            } else if placeholder {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [item.accent.opacity(0.35), item.category.color.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(Text(item.initial).font(.app(height * 0.38, .heavy)).foregroundStyle(.white.opacity(0.85)))
                    .frame(width: width, height: height)
            } else {
                Color.clear.frame(width: 0, height: height)
            }
        }
        .task(id: item.key) {
            let url = [item.image, Magazine.shared.storedImage(item.key)].compactMap { $0 }.first { !ImageKey.isJunk($0) }
            guard let url, let img = await ImageLoader.shared.image(url), !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { image = img }
        }
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
