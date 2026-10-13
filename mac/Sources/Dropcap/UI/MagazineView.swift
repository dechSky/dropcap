import AppKit
import SwiftUI

// AI 매거진: 오늘 호 · 이번 주 · 스토리 · 저장 · 검색 · 지난 호
struct MagazineView: View {
    enum Page: Hashable {
        case today, week, stories, saved, search, scrapbook
        case issue(Issue)
        case story(String)
    }

    @ObservedObject private var mag = Magazine.shared
    @ObservedObject private var app = AppModel.shared
    @ObservedObject private var book = Scrapbook.shared
    @State private var page: Page = MagazineController.pendingPage ?? (ProcessInfo.processInfo.environment["DROPCAP_TEST_MAG_PAGE"] == "scrapbook" ? .scrapbook
        : ProcessInfo.processInfo.environment["DROPCAP_TEST_MAG_PAGE"] == "stories" ? .stories
        : ProcessInfo.processInfo.environment["DROPCAP_TEST_STORY"].map { .story($0) } ?? .today)
    @State private var turn = 0   // 넘긴 방향(+1 다음, -1 이전) — 책장 넘김 방향

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { page }, set: { go($0) })) {
                Section("이번 호") {
                    Label("오늘", systemImage: "newspaper").tag(Page.today)
                    Label("이번 주", systemImage: "calendar").tag(Page.week)
                }
                Section("모아 보기") {
                    Label("스토리", systemImage: "point.3.connected.trianglepath.dotted").tag(Page.stories)
                    Label("저장 \(app.state.saved.count)", systemImage: "bookmark").tag(Page.saved)
                    Label("스크랩북 \(book.scraps.count)", systemImage: "scissors").tag(Page.scrapbook)
                    Label("검색", systemImage: "magnifyingglass").tag(Page.search)
                }
                if !mag.archive.isEmpty {
                    Section("지난 호") {
                        ForEach(mag.archive) { issue in
                            Label(issue.title, systemImage: issue.kind == .weekly ? "books.vertical" : "doc.richtext")
                                .lineLimit(1)
                                .tag(Page.issue(issue))
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            ZStack {
                Color(nsColor: .textBackgroundColor).ignoresSafeArea()
                detail
                    .id(page)
                    .transition(.pageTurn(forward: turn >= 0))
            }
            .clipped()
        }
        .frame(minWidth: 860, minHeight: 620)
        .onReceive(NotificationCenter.default.publisher(for: .magazineGo)) { n in if let p = n.object as? Page { go(p) } }
        .background {
            Group {
                Button("") { go(.today) }.keyboardShortcut("1", modifiers: .command)
                Button("") { go(.week) }.keyboardShortcut("2", modifiers: .command)
                Button("") { go(.stories) }.keyboardShortcut("3", modifiers: .command)
                Button("") { go(.search) }.keyboardShortcut("f", modifiers: .command)
                Button("") { go(.scrapbook) }.keyboardShortcut("4", modifiers: .command)
                Button("") { Task { await AppModel.shared.checkAll(manual: false) } }.keyboardShortcut("r", modifiers: .command)
            }
            .opacity(0).allowsHitTesting(false)
        }
    }

    @ViewBuilder private var detail: some View {
        switch page {
        case .today: IssueView(source: .today, onStory: openStory)
        case .week: IssueView(source: .week, onStory: openStory)
        case .issue(let i): IssueView(source: .fixed(i), onStory: openStory)
        case .stories: StoriesView(onStory: openStory)
        case .story(let id): StoryView(clusterID: id) { go(.stories) }
        case .saved: SavedView()
        case .scrapbook: ScrapbookView()
        case .search: SearchView()
        }
    }

    private func openStory(_ id: String) { go(.story(id)) }

    private func go(_ p: Page) {
        guard p != page else { return }
        turn = order(p) >= order(page) ? 1 : -1
        withAnimation(.spring(response: 0.62, dampingFraction: 0.9)) { page = p }
    }

    private func order(_ p: Page) -> Int {
        switch p {
        case .today: return 0
        case .week: return 1
        case .stories: return 2
        case .story: return 3
        case .saved: return 4
        case .scrapbook: return 5
        case .search: return 7
        case .issue(let i): return 100 + (mag.archive.firstIndex(of: i) ?? 0)
        }
    }
}

// MARK: - 책장 넘김
private struct PageTurn: ViewModifier {
    let angle: Double
    let opacity: Double
    let leading: Bool
    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), anchor: leading ? .leading : .trailing, perspective: 0.45)
            .opacity(opacity)
    }
}

extension AnyTransition {
    static func pageTurn(forward: Bool) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(active: PageTurn(angle: forward ? 28 : -28, opacity: 0, leading: !forward),
                                 identity: PageTurn(angle: 0, opacity: 1, leading: !forward)),
            removal: .modifier(active: PageTurn(angle: forward ? -70 : 70, opacity: 0, leading: forward),
                               identity: PageTurn(angle: 0, opacity: 1, leading: forward)))
    }
}

// MARK: - 한 호
struct IssueView: View {
    enum Source: Equatable { case today, week, fixed(Issue) }
    let source: Source
    let onStory: (String) -> Void
    @ObservedObject private var mag = Magazine.shared
    @State private var appeared = false
    @State private var data: Magazine.Resolved?
    @State private var seenRevision = 0
    @AppStorage("magSort") private var sortRaw = MagSort.recommended.rawValue

    private var isFixed: Bool { if case .fixed = source { return true }; return false }
    private var newCount: Int { isFixed ? 0 : max(0, mag.revision - seenRevision) }

    private func build() {
        let issue: Issue
        switch source {
        case .today: issue = mag.liveDaily()
        case .week: issue = mag.liveWeekly()
        case .fixed(let i): issue = i
        }
        data = mag.resolve(issue)
        seenRevision = mag.revision
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id("top")
                    if let d = data {
                        Masthead(issue: d.issue, live: !isFixed, appeared: appeared)
                            .padding(.horizontal, 36).padding(.top, 28).padding(.bottom, 22)
                            .overlay(alignment: .bottomTrailing) {
                                Picker("정렬", selection: $sortRaw) {
                                    ForEach(MagSort.allCases, id: \.rawValue) { Label($0.label, systemImage: $0.symbol).tag($0.rawValue) }
                                }
                                .pickerStyle(.menu).fixedSize()
                                .padding(.trailing, 36).padding(.bottom, 34)
                                .help("지면 안의 기사 순서")
                            }
                        if let c = d.cover {
                            CoverStory(stored: c, issue: d.issue, onStory: onStory)
                                .padding(.horizontal, 28)
                                .opacity(appeared ? 1 : 0)
                                .offset(y: appeared ? 0 : 24)
                                .animation(.spring(response: 0.7, dampingFraction: 0.85).delay(0.15), value: appeared)
                        } else {
                            EmptyIssue(live: !isFixed, preparing: mag.preparing).padding(.horizontal, 36)
                        }
                        ForEach(Array(d.sections.enumerated()), id: \.element.section.id) { si, sec in
                            SectionBlock(section: sec.section, items: (MagSort(rawValue: sortRaw) ?? .recommended).apply(sec.items),
                                         issue: d.issue, index: si, onStory: onStory, clusters: d.clusters)
                                .padding(.top, 38)
                        }
                        Text("기사 저작권은 각 언론사·기업에 있습니다. 제목·요약·사진은 원문으로 이어 주기 위한 것입니다.")
                            .font(.app(11)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 36).padding(.vertical, 40)
                    }
                }
            }
            // 보는 동안 새 소식이 오면 지면을 갈아엎지 않고 위에 알림만 띄운다
            .overlay(alignment: .top) {
                if newCount > 0 {
                    Button {
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { build(); proxy.scrollTo("top") }
                    } label: {
                        Label("새 소식이 들어왔어요 · 새로 보기", systemImage: "arrow.up")
                            .font(.app(12.5, .semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.8), value: newCount > 0)
        }
        .onAppear { build(); appeared = true }
        // 빈 지면이면 알림 없이 바로 채운다(처음 켰을 때)
        .onChange(of: mag.revision) { _, _ in
            // 지면이 비었거나 표지가 아직 없으면 알림 없이 바로 채운다(처음 켰을 때 등)
            if !isFixed, data?.cover == nil || (data?.issue.count ?? 0) == 0 || mag.preparing {
                withAnimation(.easeOut(duration: 0.4)) { build() }
            }
        }
        .onChange(of: mag.imageRevision) { _, _ in
            // 사진만 새로 채워졌으면 알림 없이 조용히 반영(새 소식은 그대로 알림으로)
            let pending = mag.revision != seenRevision
            if !pending { build() }
        }
        .onChange(of: mag.preparing) { _, now in
            if !now, !isFixed { withAnimation(.easeOut(duration: 0.4)) { build() } } // 첫 호가 다 엮이면 바로 보여 준다
        }
    }
}

private struct Masthead: View {
    let issue: Issue
    let live: Bool
    let appeared: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // 로고: 잡지 첫 글자를 크게 키우는 '드롭캡'처럼 D 를 크게
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("D").font(.system(size: 22, weight: .black, design: .serif))
                    Text("ROPCAP").font(.system(size: 13, weight: .heavy, design: .serif)).tracking(2.2)
                }
                .foregroundStyle(.primary)
                Text("매거진").font(.app(11.5, .medium)).foregroundStyle(.secondary)
                if live {
                    Text("발행 중").font(.app(10.5, .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.red.gradient, in: Capsule())
                        .symbolEffect(.pulse)
                }
            }
            .foregroundStyle(.secondary)
            .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 8)
            .animation(.easeOut(duration: 0.5), value: appeared)
            Text(issue.title)
                .font(.display(38, .bold))
                .tracking(-0.6)
                .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 14)
                .animation(.spring(response: 0.6, dampingFraction: 0.85).delay(0.06), value: appeared)
            Text("소식 \(issue.count)건 · 분야 \(issue.sections.count)개")
                .font(.app(13)).foregroundStyle(.secondary)
                .opacity(appeared ? 1 : 0)
                .animation(.easeOut(duration: 0.5).delay(0.12), value: appeared)
            Rectangle().fill(.primary.opacity(0.85)).frame(height: 2)
                .scaleEffect(x: appeared ? 1 : 0, anchor: .leading)
                .animation(.spring(response: 0.9, dampingFraction: 0.9).delay(0.1), value: appeared)
                .padding(.top, 10)
        }
    }
}

private struct EmptyIssue: View {
    let live: Bool
    var preparing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if preparing {
                ProgressView().controlSize(.small)
                Text("첫 호를 엮는 중…").font(.display(20, .semibold))
                Text("구독한 출처에서 최근 사흘 소식을 모으고 번역하고 있어요. 잠시면 됩니다.").font(.app(13)).foregroundStyle(.secondary)
            } else {
                Image(systemName: "newspaper").font(.app(34, .light)).foregroundStyle(.tertiary)
                Text(live ? "아직 이번 호에 실을 소식이 없습니다" : "이 호에는 소식이 없습니다").font(.display(20, .semibold))
                Text("새 소식이 들어오는 대로 지면이 채워집니다.").font(.app(13)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 60)
    }
}

// MARK: - 표지 기사
private struct CoverStory: View {
    let stored: Database.StoredItem
    let issue: Issue
    let onStory: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false
    @State private var hover = false
    @State private var frame: CGRect = .zero

    private var item: NewsItem { stored.item }
    // 사진이 없으면 사진 자리를 만들지 않고 글자 표지로(지어낸 그림은 쓰지 않음)
    private var hasPhoto: Bool { item.image != nil && !ImageKey.isJunk(item.image) }
    private var ink: Color { hasPhoto ? .white : .primary }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if hasPhoto {
                // 켄 번스: 표지 사진이 아주 천천히 다가오며 흐른다
                RemoteImage(url: item.image, category: item.category, accent: item.accent)
                    .scaleEffect(drift ? 1.12 : 1.0)
                    .offset(x: drift ? -22 : 8, y: drift ? -10 : 4)
                    .frame(height: 400)
                    .clipped()
                LinearGradient(stops: [.init(color: .clear, location: 0.25), .init(color: .black.opacity(0.82), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            } else {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.primary.opacity(0.045))
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("표지").font(.app(11, .heavy)).tracking(1.5)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(ink, in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(hasPhoto ? Color.black : Color(nsColor: .textBackgroundColor))
                    Label(item.category.label, systemImage: item.category.symbol).font(.app(12, .semibold))
                    Text("\(item.sourceName) · \(RelativeTime.string(item.date))").font(.app(12))
                }
                .foregroundStyle(ink.opacity(0.9))
                Text(item.displayTitle)
                    .font(.display(34, .bold))
                    .foregroundStyle(ink)
                    .lineLimit(3)
                    .shadow(color: .black.opacity(hasPhoto ? 0.3 : 0), radius: 8, y: 2)
                if item.titleKo != nil, item.titleKo != item.title {
                    Text(item.title).font(.app(13)).foregroundStyle(ink.opacity(0.7)).lineLimit(1)
                }
                HStack(spacing: 10) {
                    Button { ReaderController.open(item, from: frame) ; AppModel.shared.markOpened(item) } label: {
                        Label("기사 읽기", systemImage: "book").font(.app(13, .semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(ink, in: Capsule()).foregroundStyle(hasPhoto ? Color.black : Color(nsColor: .textBackgroundColor))
                    }
                    .buttonStyle(.plain)
                    if let c = stored.cluster, (Magazine.shared.cluster(c)?.size ?? 1) >= 2 {
                        Button { onStory(c) } label: {
                            Label("여러 시각 \(Magazine.shared.cluster(c)?.size ?? 2)곳", systemImage: "rectangle.split.3x1")
                                .font(.app(13, .semibold))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(ink.opacity(0.12), in: Capsule()).foregroundStyle(ink)
                                .overlay(Capsule().strokeBorder(ink.opacity(0.35), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }
            .padding(30)
        }
        .frame(height: hasPhoto ? 400 : nil)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(hover ? 0.28 : 0.16), radius: hover ? 26 : 16, y: hover ? 14 : 8)
        .scaleEffect(hover ? 1.006 : 1)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hover)
        .onHover { hover = $0 }
        .background(ScreenFrame(frame: $frame))
        .onAppear {
            // 움직임 줄이기를 켠 사람에게는 끝없이 흐르는 켄 번스를 돌리지 않는다
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 22).repeatForever(autoreverses: true)) { drift = true }
        }
    }
}

// MARK: - 분야 지면
private struct SectionBlock: View {
    let section: Issue.Section
    let items: [NewsItem]
    let issue: Issue
    let index: Int
    let onStory: (String) -> Void
    var clusters: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: section.symbol).foregroundStyle(section.color)
                Text(section.label).font(.display(20, .bold))
                Text("\(items.count)").font(.app(13, .semibold)).foregroundStyle(.secondary)
                Rectangle().fill(.primary.opacity(0.12)).frame(height: 1).padding(.leading, 6)
            }
            .padding(.horizontal, 36)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 360), spacing: 18)], alignment: .leading, spacing: 22) {
                ForEach(Array(items.enumerated()), id: \.element.key) { i, it in
                    StoryCard(item: it, issue: issue, order: i, onStory: onStory, clusterID: clusters[it.key])
                }
            }
            .padding(.horizontal, 28)
        }
    }
}

struct StoryCard: View {
    let item: NewsItem
    var issue: Issue?
    var order: Int = 0
    var onStory: ((String) -> Void)?
    var clusterID: String?
    @State private var hover = false
    @State private var tilt: CGSize = .zero
    @State private var shown = false
    @State private var frame: CGRect = .zero

    var body: some View {
        Button {
            AppModel.shared.markOpened(item)
            ReaderController.open(item, from: frame)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                // 마우스를 따라 사진이 살짝 움직이는 시차 효과(사진이 없으면 사진 자리 없이 글만)
                if item.image != nil && !ImageKey.isJunk(item.image) {
                RemoteImage(url: item.image, category: item.category, accent: item.accent)
                    .scaleEffect(hover ? 1.08 : 1.0)
                    .offset(x: tilt.width * 8, y: tilt.height * 6)
                    .frame(height: 150)
                    .clipped()
                    .overlay {
                        if item.itemKind == .video || item.itemKind == .podcast {
                            Image(systemName: item.itemKind == .video ? "play.fill" : "waveform")
                                .font(.app(18, .bold)).foregroundStyle(.white)
                                .frame(width: 46, height: 46)
                                .background(.black.opacity(0.45), in: Circle())
                                .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
                                .scaleEffect(hover ? 1.12 : 1)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if item.itemKind != .article { KindBadge(kind: item.itemKind).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 5)).padding(8) }
                    }
                }
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        if item.important == true { Image(systemName: "star.fill").foregroundStyle(.orange).font(.app(10)) }
                        Text(item.sourceName).font(.app(11.5, .semibold))
                        if let r = item.related, !r.isEmpty { Text("외 \(r.count)곳").font(.app(11)).foregroundStyle(.secondary) }
                        Spacer(minLength: 0)
                        Text(RelativeTime.string(item.date)).font(.app(11)).foregroundStyle(.tertiary)
                    }
                    Text(item.displayTitle)
                        .font(.display(15, .semibold))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if AppModel.shared.isRead(item) {
                        Label("읽음", systemImage: "checkmark").font(.app(10.5)).foregroundStyle(.tertiary)
                    }
                }
                .padding(14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(hover ? 0.18 : 0.06), radius: hover ? 18 : 6, y: hover ? 10 : 3)
            .scaleEffect(hover ? 1.025 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                tilt = CGSize(width: (p.x / max(frame.width, 1)) - 0.5, height: (p.y / 220) - 0.5)
            case .ended:
                tilt = .zero
            }
        }
        .onHover { h in withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { hover = h } }
        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.8), value: tilt)
        .contextMenu {
            Button(AppModel.shared.isSaved(item) ? "저장 취소" : "나중에 읽기") { AppModel.shared.toggleSaved(item) }
            if let c = clusterID, let onStory {
                Button("여러 시각 보기") { onStory(c) }
            }
            Button("브라우저에서 열기") { ExternalLink.open(item.link) }
        }
        .background(ScreenFrame(frame: $frame))
        // 지면이 차례로 깔리는 느낌: 처음엔 순서대로, 스크롤할 땐 들어오며 또렷해진다
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 18)
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.86).delay(min(Double(order) * 0.05, 0.4))) { shown = true }
        }
        .scrollTransition(.animated(.easeOut(duration: 0.3))) { content, phase in
            content.opacity(phase.isIdentity ? 1 : 0.4).scaleEffect(phase.isIdentity ? 1 : 0.97)
        }
    }
}

// 화면 좌표(창 밖 포함)의 사각형을 알아낸다 — 읽기 창이 이 자리에서 커져 나오게
struct ScreenFrame: NSViewRepresentable {
    @Binding var frame: CGRect
    func makeNSView(context: Context) -> NSView { Probe(target: $frame) }
    func updateNSView(_ v: NSView, context: Context) { (v as? Probe)?.report() }
    final class Probe: NSView {
        @Binding var target: CGRect
        init(target: Binding<CGRect>) { _target = target; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() { super.layout(); report() }
        func report() {
            guard let w = window else { return }
            let r = w.convertToScreen(convert(bounds, to: nil))
            if r != target { DispatchQueue.main.async { self.target = r } }
        }
    }
}

// MARK: - 스토리
struct StoriesView: View {
    let onStory: (String) -> Void
    @ObservedObject private var mag = Magazine.shared
    @ObservedObject private var app = AppModel.shared

    var body: some View {
        let groups = mag.storyGroups()
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("스토리").font(.display(34, .bold)).padding(.top, 28)
                Text("여러 곳이 함께 다룬 소식을 한 줄기로 묶었습니다. 팔로우하면 새 보도가 붙을 때 알려 드립니다.").foregroundStyle(.secondary)
                if groups.live.isEmpty && groups.past.isEmpty {
                    Text("아직 여러 곳이 함께 다룬 소식이 없습니다. 출처를 더 구독하면 스토리가 늘어납니다.").foregroundStyle(.secondary).padding(.vertical, 40)
                }
                if !groups.live.isEmpty {
                    sectionTitle("지금 커지는 스토리", "최근 24시간")
                    ForEach(Array(groups.live.enumerated()), id: \.element.id) { i, c in
                        StoryListCard(cluster: c, big: i == 0, onOpen: { onStory(c.id) }).modifier(Stagger(index: i))
                    }
                }
                if !groups.past.isEmpty {
                    sectionTitle("지난 스토리", "최근 2주")
                    ForEach(Array(groups.past.enumerated()), id: \.element.id) { i, c in
                        StoryListCard(cluster: c, big: false, onOpen: { onStory(c.id) }).modifier(Stagger(index: i + groups.live.count))
                    }
                }
            }
            .padding(.horizontal, 36).padding(.bottom, 40)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }

    private func sectionTitle(_ t: String, _ sub: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(t).font(.app(15, .bold))
            Text(sub).font(.app(12)).foregroundStyle(.tertiary)
        }
        .padding(.top, 14)
    }
}

// 스토리 카드: 대표 사진 · 분야 · 다룬 출처들 · 시작/최근 · 새 보도 · 팔로우 표시
private struct StoryListCard: View {
    let cluster: Database.Cluster
    let big: Bool
    let onOpen: () -> Void
    @ObservedObject private var app = AppModel.shared
    @State private var hover = false

    var body: some View {
        let items = Magazine.shared.storyItems(cluster.id)
        let photo = items.compactMap(\.image).first { !ImageKey.isJunk($0) }
        let lead = items.first { $0.tier == "lab" } ?? items.first
        let sources = Array(NSOrderedSet(array: items.map(\.sourceName)).array as? [String] ?? []).prefix(6)
        let fresh = app.unseenReports(cluster)
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 16) {
                if let photo {
                    RemoteImage(url: photo, category: lead?.category ?? .other, accent: lead?.accent ?? .accentColor)
                        .frame(width: big ? 210 : 120, height: big ? 140 : 80)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        if let lead { Label(lead.category.label, systemImage: lead.category.symbol).font(.app(11.5, .semibold)).foregroundStyle(lead.category.color) }
                        Text("\(cluster.size)곳 보도").font(.app(11.5, .semibold)).foregroundStyle(.secondary)
                        if fresh > 0 {
                            Text("새 보도 \(fresh)").font(.app(10.5, .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2).background(Color.red, in: Capsule())
                        }
                        if app.isFollowing(cluster.id) { Image(systemName: "bell.fill").font(.app(10.5)).foregroundStyle(.orange).help("팔로우 중") }
                    }
                    Text(cluster.title).font(.display(big ? 21 : 16, .semibold)).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: -5) {
                        ForEach(Array(sources.enumerated()), id: \.offset) { _, name in
                            let it = items.first { $0.sourceName == name }
                            Monogram(letter: it?.initial ?? String(name.prefix(1)), color: it?.accent ?? .gray, size: 20)
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .textBackgroundColor), lineWidth: 1.5))
                                .help(name)
                        }
                        Text("  \(sources.joined(separator: " · "))").font(.app(11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text("첫 보도 \(RelativeTime.string(cluster.first)) · 최근 \(RelativeTime.string(cluster.last))")
                        .font(.app(11.5)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(.primary.opacity(hover ? 0.07 : 0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// 한 스토리: 한눈에 요약 → 보도 줄기(간격·날짜·첫 문장) · 팔로우
struct StoryView: View {
    let clusterID: String
    let back: () -> Void
    @ObservedObject private var app = AppModel.shared
    @State private var progress: CGFloat = 0
    @State private var digest: [String]?
    @State private var digesting = false

    var body: some View {
        let items = Magazine.shared.storyItems(clusterID)
        let cluster = Magazine.shared.cluster(clusterID)
        let following = app.isFollowing(clusterID)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: back) { Label("스토리", systemImage: "chevron.left") }.buttonStyle(.borderless).padding(.top, 24)
                Text(cluster?.title ?? "스토리").font(.display(30, .bold)).padding(.top, 10)
                HStack(spacing: 10) {
                    Text("\(items.count)곳 보도 · \(Self.span(items))").foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        app.setFollowing(clusterID, !following, size: items.count)
                    } label: {
                        Label(following ? "팔로우 중" : "이 스토리 팔로우", systemImage: following ? "bell.fill" : "bell")
                            .font(.app(12.5, .semibold))
                    }
                    .buttonStyle(.bordered).tint(following ? .orange : .accentColor)
                    .help("새 보도가 이 스토리에 붙으면 알림")
                }
                .padding(.top, 6).padding(.bottom, 22)
                if digest != nil || digesting {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("한눈에", systemImage: "text.alignleft").font(.app(12.5, .bold)).foregroundStyle(.secondary)
                        if let digest {
                            ForEach(Array(digest.enumerated()), id: \.offset) { _, l in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Circle().fill(.secondary).frame(width: 4, height: 4).offset(y: -3)
                                    Text(l).font(.app(15)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Text("여러 보도를 이 Mac 의 Apple Intelligence 로 합쳐 요약했습니다.").font(.app(11)).foregroundStyle(.tertiary)
                        } else {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("여러 보도를 합쳐 요약하는 중…").font(.app(13)).foregroundStyle(.secondary) }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.bottom, 26)
                }
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.primary.opacity(0.15)).frame(width: 2)
                        .frame(maxHeight: .infinity)
                        .scaleEffect(x: 1, y: progress, anchor: .top)
                        .padding(.leading, 9)
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(items.enumerated()), id: \.element.key) { i, it in
                            if let gap = Self.gap(items, i) {
                                Text(gap).font(.app(11, .semibold)).foregroundStyle(.tertiary).padding(.leading, 36).padding(.top, -6)
                            }
                            TimelineRow(item: it, first: i == 0)
                                .opacity(progress >= CGFloat(i + 1) / CGFloat(max(items.count, 1)) * 0.9 ? 1 : 0)
                                .offset(x: progress >= CGFloat(i + 1) / CGFloat(max(items.count, 1)) * 0.9 ? 0 : 12)
                                .animation(.spring(response: 0.5, dampingFraction: 0.85), value: progress)
                        }
                    }
                }
            }
            .padding(.horizontal, 36).padding(.bottom, 40)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.4 + 0.18 * Double(items.count))) { progress = 1 }
            app.markStorySeen(clusterID, size: items.count)
        }
        .task(id: clusterID) {
            guard Summarizer.available, let c = cluster else { return }
            digesting = true
            let d = await Magazine.shared.storyDigest(c)
            withAnimation(.easeOut(duration: 0.3)) { digest = d; digesting = false }
        }
    }

    static func span(_ items: [NewsItem]) -> String {
        let ds = items.compactMap(\.date)
        guard let a = ds.min(), let b = ds.max() else { return "" }
        let h = b.timeIntervalSince(a) / 3600
        return h < 1 ? "한 시간 안에 이어진 보도" : h < 48 ? "\(Int(h.rounded()))시간에 걸친 보도" : "\(Int((h / 24).rounded()))일에 걸친 보도"
    }

    // 앞 보도와의 간격: 날이 바뀌면 날짜, 아니면 'N시간 뒤'(30분 안이면 표시 안 함)
    static func gap(_ items: [NewsItem], _ i: Int) -> String? {
        guard i > 0, let a = items[i - 1].date, let b = items[i].date else { return nil }
        if !Calendar.current.isDate(a, inSameDayAs: b) { return b.formatted(.dateTime.locale(Locale(identifier: "ko_KR")).month().day().weekday()) }
        let m = b.timeIntervalSince(a) / 60
        if m < 30 { return nil }
        return m < 90 ? "\(Int(m.rounded()))분 뒤" : "\(Int((m / 60).rounded()))시간 뒤"
    }
}

private struct TimelineRow: View {
    let item: NewsItem
    let first: Bool
    @State private var frame: CGRect = .zero

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Circle().fill(first ? item.accent : Color(nsColor: .textBackgroundColor))
                .overlay(Circle().strokeBorder(item.accent, lineWidth: 2))
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Monogram(letter: item.initial, color: item.accent, size: 18)
                    Text(item.sourceName).font(.app(12.5, .semibold))
                    Text(Resources.tierLabel(item.tier)).font(.app(11)).foregroundStyle(.secondary)
                    Text("· " + (item.date?.formatted(.dateTime.locale(Locale(identifier: "ko_KR")).hour().minute()) ?? ""))
                        .font(.app(11.5)).foregroundStyle(.secondary)
                    if first { Text("첫 보도").font(.app(10.5, .bold)).foregroundStyle(item.accent) }
                }
                Button {
                    AppModel.shared.markOpened(item)
                    ReaderController.open(item, from: frame)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.displayTitle).font(.display(16, .semibold))
                                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                            if let lede = Self.lede(item) {
                                Text(lede).font(.app(13)).foregroundStyle(.secondary).lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        Spacer(minLength: 0)
                        if item.image != nil && !ImageKey.isJunk(item.image) {
                            RemoteImage(url: item.image, category: item.category, accent: item.accent)
                                .frame(width: 92, height: 62).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                    }
                    .padding(14)
                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(ScreenFrame(frame: $frame))
            }
        }
    }

    // 요약의 첫 문장(HTML 꼬리표 제거, 제목과 같으면 생략)
    static func lede(_ it: NewsItem) -> String? {
        let t = it.summary.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard t.count > 20, !t.hasPrefix(it.title.prefix(20)) else { return nil }
        return String(t.prefix(220))
    }
}

// MARK: - 저장 · 검색
struct SavedView: View {
    @ObservedObject private var app = AppModel.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("저장").font(.display(34, .bold)).padding(.top, 28)
                Text("저장한 기사는 번역까지 이 Mac 에 보관돼 인터넷 없이도 읽을 수 있습니다.").foregroundStyle(.secondary)
                if app.state.saved.isEmpty {
                    Text("아직 저장한 기사가 없습니다. 카드를 오른쪽 클릭해 '나중에 읽기'로 저장하세요.").foregroundStyle(.secondary).padding(.vertical, 40)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 360), spacing: 18)], alignment: .leading, spacing: 22) {
                    ForEach(Array(app.state.saved.enumerated()), id: \.element.key) { i, it in
                        StoryCard(item: it, order: i)
                            .overlay(alignment: .topTrailing) {
                                if ArticleService.shared.cached(it.link) != nil {
                                    Label("보관됨", systemImage: "arrow.down.circle.fill").font(.app(10.5, .semibold))
                                        .padding(.horizontal, 7).padding(.vertical, 3)
                                        .background(.thinMaterial, in: Capsule()).padding(10)
                                }
                            }
                    }
                }
            }
            .padding(.horizontal, 32).padding(.bottom, 40)
        }
    }
}

struct SearchView: View {
    @State private var q = ""
    @State private var results: [NewsItem] = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("검색").font(.display(34, .bold)).padding(.top, 28)
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("모든 기록에서 제목·출처·요약 검색", text: $q).textFieldStyle(.plain).font(.app(15))
                        .onSubmit { results = Magazine.shared.search(q) }
                        .task(id: q) { // 입력이 멈추면(0.25초) 찾는다
                            guard q.count >= 2 else { if q.isEmpty { results = [] }; return }
                            try? await Task.sleep(for: .milliseconds(250))
                            if !Task.isCancelled { results = Magazine.shared.search(q) }
                        }
                }
                .padding(12)
                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                if !q.isEmpty { Text("\(results.count)건").foregroundStyle(.secondary) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 360), spacing: 18)], alignment: .leading, spacing: 22) {
                    ForEach(Array(results.enumerated()), id: \.element.key) { i, it in StoryCard(item: it, order: i) }
                }
            }
            .padding(.horizontal, 32).padding(.bottom, 40)
        }
    }
}

private struct Stagger: ViewModifier {
    let index: Int
    @State private var on = false
    func body(content: Content) -> some View {
        content.opacity(on ? 1 : 0).offset(y: on ? 0 : 14)
            .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.85).delay(min(Double(index) * 0.05, 0.5))) { on = true } }
    }
}

// MARK: - 창
@MainActor
enum MagazineController {
    private static var window: NSWindow?
    static var pendingPage: MagazineView.Page?

    static func open(page: MagazineView.Page) {
        pendingPage = page
        if window != nil { NotificationCenter.default.post(name: .magazineGo, object: page) }
        open()
    }

    static func open() {
        NSApp.setActivationPolicy(.regular) // 매거진을 여는 동안은 Dock 에 보인다
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentViewController: NSHostingController(rootView: MagazineView()))
        w.title = "Dropcap"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.toolbarStyle = .unified
        w.setContentSize(NSSize(width: 1180, height: 820))
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("AIMagazine")
        if w.frame.origin == .zero { w.center() }
        window = w
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated {
                window = nil
                if let token { NotificationCenter.default.removeObserver(token) }
                NSApp.setActivationPolicy(.accessory) // 닫으면 다시 상단바 앱으로
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        pendingPage = nil
    }
}


// 기사 정렬 기준
enum MagSort: String, CaseIterable {
    case recommended, newest, coverage, source
    var label: String {
        switch self {
        case .recommended: return "추천순"
        case .newest: return "최신순"
        case .coverage: return "많이 보도된 순"
        case .source: return "출처별"
        }
    }
    var symbol: String {
        switch self {
        case .recommended: return "sparkles"
        case .newest: return "clock"
        case .coverage: return "person.3"
        case .source: return "building.2"
        }
    }
    // 추천순은 편집 순서(점수) 그대로
    @MainActor func apply(_ items: [NewsItem]) -> [NewsItem] {
        switch self {
        case .recommended: return items
        case .newest: return items.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        case .coverage: // 같은 소식을 다룬 출처 수(스토리 크기)로. '외 N곳'만 보던 때는 거의 다 0이라 효과가 없었다
            let cov = Magazine.shared.coverage(items)
            return items.enumerated().sorted { a, b in
                let ca = max(cov[a.element.key] ?? 1, (a.element.related?.count ?? 0) + 1)
                let cb = max(cov[b.element.key] ?? 1, (b.element.related?.count ?? 0) + 1)
                return ca != cb ? ca > cb : a.offset < b.offset
            }.map(\.element)
        case .source: return items.sorted { ($0.sourceName, $1.date ?? .distantPast) < ($1.sourceName, $0.date ?? .distantPast) }
        }
    }
}


// MARK: - 스크랩북
struct ScrapbookView: View {
    @ObservedObject private var book = Scrapbook.shared
    @State private var folder = ScrapbookView.initialFolder()

    // 마지막으로 스크랩한 폴더, 없으면 내용이 있는 첫 폴더
    static func initialFolder() -> String {
        let book = Scrapbook.shared
        if let last = UserDefaults.standard.string(forKey: "lastScrapCollection"), book.collections.contains(last) { return last }
        return book.collections.first { c in book.scraps.contains { $0.collection == c } } ?? Scrapbook.defaultCollection
    }
    @State private var renaming = false
    @State private var newName = ""
    @State private var creating = false
    @State private var copied = false

    private var list: [Scrap] { book.scraps.filter { $0.collection == folder } }

    // 기사별로 묶기(최근 스크랩 순)
    private var groups: [(item: NewsItem, scraps: [Scrap])] {
        var order: [String] = []
        var map: [String: [Scrap]] = [:]
        for s in list {
            if map[s.item.key] == nil { order.append(s.item.key) }
            map[s.item.key, default: []].append(s)
        }
        return order.compactMap { k in map[k].map { ($0[0].item, $0.sorted { $0.created < $1.created }) } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text("스크랩북").font(.display(34, .bold))
                    Spacer()
                    Button { book.copyMarkdown(collection: folder); copied = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                    } label: { Label(copied ? "복사됨" : "Markdown 복사", systemImage: copied ? "checkmark" : "doc.on.doc") }
                        .disabled(list.isEmpty)
                    Button { book.saveMarkdown(collection: folder) } label: { Label("파일로 저장", systemImage: "square.and.arrow.down") }
                        .disabled(list.isEmpty)
                }
                .padding(.top, 28)
                Text("읽기 창에서 문단에 마우스를 올려 ✂︎ 를 누르거나, 도구막대의 스크랩으로 기사를 모아 두세요. 폴더째 Markdown 으로 내보낼 수 있습니다.")
                    .font(.app(13)).foregroundStyle(.secondary)

                // 폴더 칩
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(book.collections, id: \.self) { c in
                            let n = book.scraps.filter { $0.collection == c }.count
                            Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { folder = c } } label: {
                                Label("\(c) \(n)", systemImage: c == folder ? "folder.fill" : "folder")
                                    .font(.app(12.5, c == folder ? .semibold : .regular))
                                    .padding(.horizontal, 11).padding(.vertical, 6)
                                    .background(c == folder ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05), in: Capsule())
                                    .foregroundStyle(c == folder ? Color.accentColor : Color.primary)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("이름 바꾸기") { folder = c; newName = c; renaming = true }
                            }
                        }
                        Button { creating = true } label: { Label("새 폴더", systemImage: "plus").font(.app(12.5)) }
                            .buttonStyle(.borderless)
                    }
                }

                if groups.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "scissors").font(.app(30, .light)).foregroundStyle(.tertiary)
                        Text("이 폴더는 비어 있습니다").font(.display(18, .semibold))
                    }
                    .padding(.vertical, 40)
                }

                ForEach(Array(groups.enumerated()), id: \.element.item.key) { i, g in
                    ScrapGroupCard(item: g.item, scraps: g.scraps)
                        .modifier(StaggerIn(index: i))
                }
            }
            .padding(.horizontal, 36).padding(.bottom, 40)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .onChange(of: book.scraps.count) { _, _ in
            // 보고 있는 폴더가 비었고 다른 곳에 새 스크랩이 생기면 그쪽으로
            if list.isEmpty { folder = ScrapbookView.initialFolder() }
        }
        .alert("새 스크랩 폴더", isPresented: $creating) {
            TextField("폴더 이름", text: $newName)
            Button("만들기") { if book.createCollection(newName) { folder = newName.trimmingCharacters(in: .whitespaces) }; newName = "" }
            Button("취소", role: .cancel) { newName = "" }
        }
        .alert("폴더 이름 바꾸기", isPresented: $renaming) {
            TextField("폴더 이름", text: $newName)
            Button("바꾸기") { if book.rename(folder, to: newName) { folder = newName.trimmingCharacters(in: .whitespaces) }; newName = "" }
            Button("취소", role: .cancel) { newName = "" }
        }
    }
}

private struct ScrapGroupCard: View {
    let item: NewsItem
    let scraps: [Scrap]
    @State private var frame: CGRect = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                AppModel.shared.markOpened(item)
                ReaderController.open(item, from: frame)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    if item.image != nil && !ImageKey.isJunk(item.image) {
                        RemoteImage(url: item.image, category: item.category, accent: item.accent)
                            .frame(width: 84, height: 56).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.displayTitle).font(.display(16, .semibold)).multilineTextAlignment(.leading)
                        Text("\(item.sourceName) · \(RelativeTime.string(item.date))").font(.app(12)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(ScreenFrame(frame: $frame))

            ForEach(scraps) { s in ScrapRow(scrap: s) }
        }
        .padding(18)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(0.07), lineWidth: 0.5))
    }
}

private struct ScrapRow: View {
    let scrap: Scrap
    @State private var memo = ""
    @State private var hover = false
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let q = scrap.quote {
                VStack(alignment: .leading, spacing: 6) {
                    Text(q).font(.app(14.5)).lineSpacing(5).textSelection(.enabled)
                    if let o = scrap.quoteOriginal, o != q {
                        Text(o).font(.app(12.5)).foregroundStyle(.secondary).lineSpacing(3).textSelection(.enabled)
                    }
                }
                .padding(.leading, 14)
                .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(Color.yellow.opacity(0.7)).frame(width: 3) }
            } else {
                Label("기사 전체를 스크랩", systemImage: "doc.text").font(.app(12)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: "pencil").font(.app(11)).foregroundStyle(.tertiary)
                TextField("메모 남기기", text: $memo, axis: .vertical)
                    .textFieldStyle(.plain).font(.app(13))
                    .focused($editing)
                    .onSubmit { saveMemo() }
                    .onChange(of: editing) { _, now in if !now { saveMemo() } }
                    .onAppear { memo = scrap.memo }
                    .onChange(of: scrap.memo) { _, v in if !editing { memo = v } }
                Spacer()
                Menu {
                    ForEach(Scrapbook.shared.collections.filter { $0 != scrap.collection }, id: \.self) { c in
                        Button("‘\(c)’로 옮기기") { var n = scrap; n.collection = c; n.memo = memo; Scrapbook.shared.update(n) }
                    }
                    Divider()
                    Button("스크랩 지우기", role: .destructive) { withAnimation { Scrapbook.shared.remove(scrap) } }
                } label: { Image(systemName: "ellipsis.circle").foregroundStyle(.secondary) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .opacity(hover ? 1 : 0.4)
            }
        }
        .padding(.vertical, 4)
        .onHover { hover = $0 }
    }

    private func saveMemo() {
        guard memo != scrap.memo else { return }
        var n = scrap
        n.memo = memo
        Scrapbook.shared.update(n)
    }
}

private struct StaggerIn: ViewModifier {
    let index: Int
    @State private var on = false
    func body(content: Content) -> some View {
        content.opacity(on ? 1 : 0).offset(y: on ? 0 : 12)
            .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.86).delay(min(Double(index) * 0.05, 0.4))) { on = true } }
    }
}


extension Notification.Name { static let magazineGo = Notification.Name("dropcap.magazineGo") }
