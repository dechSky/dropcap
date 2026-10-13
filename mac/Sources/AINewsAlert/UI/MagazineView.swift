import AppKit
import SwiftUI

// AI 매거진: 오늘 호 · 이번 주 · 스토리 · 저장 · 검색 · 지난 호
struct MagazineView: View {
    enum Page: Hashable {
        case today, week, stories, saved, search
        case issue(Issue)
        case story(String)
    }

    @ObservedObject private var mag = Magazine.shared
    @ObservedObject private var app = AppModel.shared
    @State private var page: Page = .today
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
    }

    @ViewBuilder private var detail: some View {
        switch page {
        case .today: IssueView(issue: mag.liveDaily(), live: true, onStory: openStory).id(mag.revision)
        case .week: IssueView(issue: mag.liveWeekly(), live: true, onStory: openStory).id(mag.revision)
        case .issue(let i): IssueView(issue: i, live: false, onStory: openStory)
        case .stories: StoriesView(onStory: openStory)
        case .story(let id): StoryView(clusterID: id) { go(.stories) }
        case .saved: SavedView()
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
        case .search: return 5
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
    let issue: Issue
    let live: Bool
    let onStory: (String) -> Void
    @ObservedObject private var mag = Magazine.shared
    @State private var appeared = false

    private var cover: Database.StoredItem? { issue.cover.flatMap { mag.stored($0, near: issue) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Masthead(issue: issue, live: live, appeared: appeared)
                    .padding(.horizontal, 36).padding(.top, 28).padding(.bottom, 22)
                if let c = cover {
                    CoverStory(stored: c, issue: issue, onStory: onStory)
                        .padding(.horizontal, 28)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 24)
                        .animation(.spring(response: 0.7, dampingFraction: 0.85).delay(0.15), value: appeared)
                } else {
                    EmptyIssue(live: live).padding(.horizontal, 36)
                }
                ForEach(Array(issue.sections.enumerated()), id: \.element.category) { si, sec in
                    SectionBlock(section: sec, items: mag.items(sec.keys, in: issue), issue: issue, index: si, onStory: onStory)
                        .padding(.top, 38)
                }
                Text("기사 저작권은 각 언론사·기업에 있습니다. 제목·요약·사진은 원문으로 이어 주기 위한 것입니다.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 36).padding(.vertical, 40)
            }
        }
        .onAppear { appeared = true }
    }
}

private struct Masthead: View {
    let issue: Issue
    let live: Bool
    let appeared: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("AI 매거진").font(.system(size: 13, weight: .heavy, design: .serif)).tracking(2.5)
                if live {
                    Text("발행 중").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.red.gradient, in: Capsule())
                        .symbolEffect(.pulse)
                }
            }
            .foregroundStyle(.secondary)
            .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 8)
            .animation(.easeOut(duration: 0.5), value: appeared)
            Text(issue.title)
                .font(.system(size: 38, weight: .bold, design: .serif))
                .tracking(-0.6)
                .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 14)
                .animation(.spring(response: 0.6, dampingFraction: 0.85).delay(0.06), value: appeared)
            Text("소식 \(issue.count)건 · 분야 \(issue.sections.count)개")
                .font(.system(size: 13)).foregroundStyle(.secondary)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "newspaper").font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
            Text(live ? "아직 이번 호에 실을 소식이 없습니다" : "이 호에는 소식이 없습니다").font(.title3.weight(.semibold))
            Text("새 소식이 들어오는 대로 지면이 채워집니다.").foregroundStyle(.secondary)
        }
        .padding(.vertical, 60)
    }
}

// MARK: - 표지 기사
private struct CoverStory: View {
    let stored: Database.StoredItem
    let issue: Issue
    let onStory: (String) -> Void
    @State private var drift = false
    @State private var hover = false
    @State private var frame: CGRect = .zero

    private var item: NewsItem { stored.item }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // 켄 번스: 표지 사진이 아주 천천히 다가오며 흐른다
            RemoteImage(url: item.image, category: item.category, accent: item.accent)
                .scaleEffect(drift ? 1.12 : 1.0)
                .offset(x: drift ? -22 : 8, y: drift ? -10 : 4)
                .frame(height: 400)
                .clipped()
            LinearGradient(stops: [.init(color: .clear, location: 0.25), .init(color: .black.opacity(0.82), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("표지").font(.system(size: 11, weight: .heavy)).tracking(1.5)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.white, in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.black)
                    Label(item.category.label, systemImage: item.category.symbol).font(.system(size: 12, weight: .semibold))
                    Text("\(item.sourceName) · \(RelativeTime.string(item.date))").font(.system(size: 12))
                }
                .foregroundStyle(.white.opacity(0.9))
                Text(item.displayTitle)
                    .font(.system(size: 34, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
                if item.titleKo != nil, item.titleKo != item.title {
                    Text(item.title).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                HStack(spacing: 10) {
                    Button { ReaderController.open(item, from: frame) ; AppModel.shared.markOpened(item) } label: {
                        Label("기사 읽기", systemImage: "book").font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.white, in: Capsule()).foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)
                    if let c = stored.cluster, (Magazine.shared.cluster(c)?.size ?? 1) >= 2 {
                        Button { onStory(c) } label: {
                            Label("여러 시각 \(Magazine.shared.cluster(c)?.size ?? 2)곳", systemImage: "rectangle.split.3x1")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(.white.opacity(0.18), in: Capsule()).foregroundStyle(.white)
                                .overlay(Capsule().strokeBorder(.white.opacity(0.4), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }
            .padding(30)
        }
        .frame(height: 400)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(hover ? 0.28 : 0.16), radius: hover ? 26 : 16, y: hover ? 14 : 8)
        .scaleEffect(hover ? 1.006 : 1)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hover)
        .onHover { hover = $0 }
        .background(ScreenFrame(frame: $frame))
        .onAppear {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: section.category.symbol).foregroundStyle(section.category.color)
                Text(section.category.label).font(.system(size: 20, weight: .bold, design: .serif))
                Text("\(items.count)").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Rectangle().fill(.primary.opacity(0.12)).frame(height: 1).padding(.leading, 6)
            }
            .padding(.horizontal, 36)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 360), spacing: 18)], alignment: .leading, spacing: 22) {
                ForEach(Array(items.enumerated()), id: \.element.key) { i, it in
                    StoryCard(item: it, issue: issue, order: i, onStory: onStory)
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
                // 마우스를 따라 사진이 살짝 움직이는 시차 효과
                RemoteImage(url: item.image, category: item.category, accent: item.accent)
                    .scaleEffect(hover ? 1.08 : 1.0)
                    .offset(x: tilt.width * 8, y: tilt.height * 6)
                    .frame(height: 150)
                    .clipped()
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        if item.important == true { Image(systemName: "star.fill").foregroundStyle(.orange).font(.system(size: 10)) }
                        Text(item.sourceName).font(.system(size: 11.5, weight: .semibold))
                        if let r = item.related, !r.isEmpty { Text("외 \(r.count)곳").font(.system(size: 11)).foregroundStyle(.secondary) }
                        Spacer(minLength: 0)
                        Text(RelativeTime.string(item.date)).font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    Text(item.displayTitle)
                        .font(.system(size: 15, weight: .semibold, design: .serif))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if AppModel.shared.isRead(item) {
                        Label("읽음", systemImage: "checkmark").font(.system(size: 10.5)).foregroundStyle(.tertiary)
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
            if let issue, let c = Magazine.shared.clusterID(of: item.key, near: issue), let onStory {
                Button("여러 시각 보기") { onStory(c) }
            }
            Button("브라우저에서 열기") { if let u = URL(string: item.link) { NSWorkspace.shared.open(u) } }
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

    var body: some View {
        let list = mag.stories()
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("스토리").font(.system(size: 34, weight: .bold, design: .serif)).padding(.top, 28)
                Text("최근 2주 동안 여러 곳이 함께 다룬 소식을 한 줄기로 묶었습니다.").foregroundStyle(.secondary)
                if list.isEmpty {
                    Text("아직 여러 곳이 함께 다룬 소식이 없습니다.").foregroundStyle(.secondary).padding(.vertical, 40)
                }
                ForEach(Array(list.enumerated()), id: \.element.id) { i, c in
                    Button { onStory(c.id) } label: {
                        HStack(alignment: .top, spacing: 14) {
                            VStack(spacing: 2) {
                                Text("\(c.size)").font(.system(size: 22, weight: .bold, design: .rounded))
                                Text("곳").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            .frame(width: 46)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(c.title).font(.system(size: 16, weight: .semibold, design: .serif)).multilineTextAlignment(.leading)
                                Text("\(RelativeTime.string(c.first)) 시작 · 최근 \(RelativeTime.string(c.last))")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .padding(16)
                        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                    .modifier(Stagger(index: i))
                }
            }
            .padding(.horizontal, 36).padding(.bottom, 40)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }
}

// 한 스토리의 타임라인: 선이 그려지며 각 보도가 차례로 나타난다
struct StoryView: View {
    let clusterID: String
    let back: () -> Void
    @State private var progress: CGFloat = 0

    var body: some View {
        let items = Magazine.shared.storyItems(clusterID)
        let cluster = Magazine.shared.cluster(clusterID)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: back) { Label("스토리", systemImage: "chevron.left") }.buttonStyle(.borderless).padding(.top, 24)
                Text(cluster?.title ?? "스토리").font(.system(size: 30, weight: .bold, design: .serif)).padding(.top, 10)
                Text("\(items.count)곳 보도 · 같은 소식, 여러 시각").foregroundStyle(.secondary).padding(.top, 4).padding(.bottom, 26)
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.primary.opacity(0.15)).frame(width: 2)
                        .frame(maxHeight: .infinity)
                        .scaleEffect(x: 1, y: progress, anchor: .top)
                        .padding(.leading, 9)
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(Array(items.enumerated()), id: \.element.key) { i, it in
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
        .onAppear { withAnimation(.easeInOut(duration: 0.4 + 0.18 * Double(items.count))) { progress = 1 } }
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
                    Text(item.sourceName).font(.system(size: 12.5, weight: .semibold))
                    Text(Resources.tierLabel(item.tier)).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("· " + (item.date?.formatted(.dateTime.locale(Locale(identifier: "ko_KR")).month().day().hour().minute()) ?? ""))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    if first { Text("첫 보도").font(.system(size: 10.5, weight: .bold)).foregroundStyle(item.accent) }
                }
                Button {
                    AppModel.shared.markOpened(item)
                    ReaderController.open(item, from: frame)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Text(item.displayTitle).font(.system(size: 16, weight: .semibold, design: .serif))
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if item.image != nil {
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
}

// MARK: - 저장 · 검색
struct SavedView: View {
    @ObservedObject private var app = AppModel.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("저장").font(.system(size: 34, weight: .bold, design: .serif)).padding(.top, 28)
                Text("저장한 기사는 번역까지 이 Mac 에 보관돼 인터넷 없이도 읽을 수 있습니다.").foregroundStyle(.secondary)
                if app.state.saved.isEmpty {
                    Text("아직 저장한 기사가 없습니다. 카드를 오른쪽 클릭해 '나중에 읽기'로 저장하세요.").foregroundStyle(.secondary).padding(.vertical, 40)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 360), spacing: 18)], alignment: .leading, spacing: 22) {
                    ForEach(Array(app.state.saved.enumerated()), id: \.element.key) { i, it in
                        StoryCard(item: it, order: i)
                            .overlay(alignment: .topTrailing) {
                                if ArticleService.shared.cached(it.link) != nil {
                                    Label("보관됨", systemImage: "arrow.down.circle.fill").font(.system(size: 10.5, weight: .semibold))
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
                Text("검색").font(.system(size: 34, weight: .bold, design: .serif)).padding(.top, 28)
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("모든 기록에서 제목·출처·요약 검색", text: $q).textFieldStyle(.plain).font(.system(size: 15))
                        .onSubmit { results = Magazine.shared.search(q) }
                        .onChange(of: q) { _, v in if v.count >= 2 { results = Magazine.shared.search(v) } else if v.isEmpty { results = [] } }
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

    static func open() {
        NSApp.setActivationPolicy(.regular) // 매거진을 여는 동안은 Dock 에 보인다
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentViewController: NSHostingController(rootView: MagazineView()))
        w.title = "AI 매거진"
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
    }
}
