import AppKit
import SwiftUI

// 매거진: 오늘 호 · 이번 주 · 스토리 · 저장 · 검색 · 지난 호
struct MagazineView: View {
    enum Page: Hashable {
        case today, week, stories, saved, search, scrapbook
        case section(String)   // 오늘 호의 한 분야
        case issue(Issue)
        case story(String)
    }

    @ObservedObject private var mag = Magazine.shared
    @ObservedObject private var app = AppModel.shared
    @ObservedObject private var book = Scrapbook.shared
    @Environment(\.openSettings) private var openSettings
    @State private var page: Page = MagazineController.pendingPage ?? (TestEnv.get("MAG_PAGE") == "scrapbook" ? .scrapbook
        : TestEnv.get("MAG_PAGE") == "stories" ? .stories
        : TestEnv.get("STORY").map { .story($0) }
        ?? TestEnv.get("MAG_SECTION").map { .section($0) } ?? .today)
    @State private var turn = 0   // 넘긴 방향(+1 다음, -1 이전) — 책장 넘김 방향
    @State private var scrolled = false // 지면이 머리 밑으로 들어감(머리 아래 구분선)

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { page }, set: { go($0) })) {
                Section("이번 호") {
                    Label("오늘", systemImage: "newspaper").tag(Page.today)
                    Label("이번 주", systemImage: "calendar").tag(Page.week)
                }
                if !app.chosenSections.isEmpty {
                    Section("분야") {
                        ForEach(app.chosenSections, id: \.self) { id in
                            let s = Sections.byID(id)
                            Label { Text(s?.name ?? id) } icon: { Image(systemName: s?.symbol ?? "circle").foregroundStyle(s?.tint ?? .gray) }
                                .tag(Page.section(id))
                        }
                    }
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
                            Label { // 이름은 오른쪽 머리와 같은 issue.title, 기사가 너무 적은 호는 흐리게 '기록 적음'
                                Text(issue.title).lineLimit(1) // 이름이 잘리지 않게 '기록 적음'은 흐림·도움말로(머리에는 글로)
                            } icon: { Image(systemName: issue.kind == .weekly ? "books.vertical" : "doc.richtext") }
                            .opacity(issue.isThin ? 0.55 : 1)
                            .help(issue.isThin ? "기록 적음 — 소식 \(issue.count)건" : issue.title)
                            .tag(Page.issue(issue))
                        }
                    }
                }
            }
            // 맨 아래 '설정' 줄: 지면이 아니라 설정 창(⌘, 와 같은 길). 목록 바닥에 고정 — 지난 호가 길어도 늘 보인다.
            // 목록 안의 줄(고르는 줄·단추 줄 모두)로 두면 눌러도 아무 일이 없었다(클릭 순회 '설정 열기')
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button { SettingsWindow.open(openSettings) } label: {
                    Label("설정", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.horizontal, 18).padding(.vertical, 8)
                .help("설정 열기 (⌘,)")
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            ZStack(alignment: .top) {
                Color(nsColor: .textBackgroundColor).ignoresSafeArea()
                detail
                    .id(page)
                    .transition(Motion.page)
                // 제목줄이 투명이라 스크롤한 본문이 머리에 비쳐 겹쳐 보였다 → 머리 자리에 바탕색(맨 위에선 그대로 보임)
                TitlebarBackdrop(fill: Color(nsColor: .textBackgroundColor), separator: scrolled)
            }
            .clipped()
            .onPreferenceChange(ScrolledPastTopKey.self) { scrolled = $0 }
        }
        .frame(minWidth: 860, minHeight: 620)
        .liveAppearance()
        .onReceive(NotificationCenter.default.publisher(for: .magazineGo)) { n in if let p = n.object as? Page { go(p) } }
        .background {
            Group {
                Button("") { go(.today) }.keyboardShortcut("1", modifiers: .command)
                Button("") { go(.week) }.keyboardShortcut("2", modifiers: .command)
                Button("") { go(.stories) }.keyboardShortcut("3", modifiers: .command)
                Button("") { go(.search) }.keyboardShortcut("f", modifiers: .command)
                Button("") { go(.scrapbook) }.keyboardShortcut("4", modifiers: .command)
                Button("") { Task { await AppModel.shared.checkAll(manual: false) } }.keyboardShortcut("r", modifiers: .command)
                Button("") { flip(-1) }.keyboardShortcut("[", modifiers: .command) // 이전 지면
                Button("") { flip(1) }.keyboardShortcut("]", modifiers: .command)  // 다음 지면
                Button("") { SettingsWindow.open(openSettings) }.keyboardShortcut(",", modifiers: .command) // 앱 메뉴가 없어 창에서 듣는다
            }
            .opacity(0).allowsHitTesting(false)
        }
    }

    @ViewBuilder private var detail: some View {
        switch page {
        case .today: IssueView(source: .today, onStory: openStory)
        case .section(let id): IssueView(source: .section(id), onStory: openStory)
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

    // 옆 목록 순서대로 지면 넘기기(⌘[ · ⌘])
    private var pageOrder: [Page] {
        [.today, .week] + app.chosenSections.map { .section($0) } + [.stories, .saved, .scrapbook, .search] + mag.archive.map { .issue($0) }
    }
    private func flip(_ d: Int) {
        let list = pageOrder
        let here: Page = { if case .story = page { return .stories }; return page }()
        guard let i = list.firstIndex(of: here), list.indices.contains(i + d) else { NSSound.beep(); return }
        go(list[i + d])
    }

    private func go(_ p: Page) {
        TestLog.write("[매거진] 지면 이동 \(p)")
        guard p != page else { return }
        turn = order(p) >= order(page) ? 1 : -1
        withMotion(Motion.settle) { page = p }
    }

    private func order(_ p: Page) -> Int {
        switch p {
        case .today: return 0
        case .section: return 1
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

// MARK: - 한 호
struct IssueView: View {
    enum Source: Equatable { case today, week, section(String), fixed(Issue) }
    let source: Source
    let onStory: (String) -> Void
    @ObservedObject private var mag = Magazine.shared
    @State private var focus: String?          // 분야 칩으로 고른 한 분야
    @State private var sub: NewsCategory?      // AI 안의 하위 칩
    @State private var appeared = false

    init(source: Source, onStory: @escaping (String) -> Void, focus: String? = nil) {
        self.source = source
        self.onStory = onStory
        _focus = State(initialValue: focus)
        // 지난번에 엮은 지면이 있으면 그것부터 보이고, 새로 엮은 것이 오면 바꿔 끼운다(앱을 막 켠 직후 빈 화면 대신)
        let last = IssueCache.get(source)
        _data = State(initialValue: last?.data)
        _seenRevision = State(initialValue: last?.revision ?? 0)
    }

    private var sectionID: String? { if case .section(let id) = source { return id }; return nil }

    // 분야 칩으로 거른 지면(분야 지면에서는 AI 하위 칩만)
    private func shown(_ d: Magazine.Resolved) -> [(section: Issue.Section, items: [NewsItem])] {
        if sectionID != nil {
            guard let sub else { return d.sections }
            return d.sections.compactMap { sec in
                let items = sec.items.filter { $0.category == sub }
                return items.isEmpty ? nil : (sec.section, items)
            }
        }
        guard let f = focus else { return d.sections }
        return d.sections.compactMap { sec in
            guard sec.section.section == f else { return nil }
            let items = f == Sections.ai && sub != nil ? sec.items.filter { $0.category == sub } : sec.items
            return items.isEmpty ? nil : (sec.section, items)
        }
    }
    @State private var data: Magazine.Resolved?
    @State private var seenRevision = 0
    @State private var selected: String?       // 키보드로 고른 카드
    @FocusState private var keyFocus: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // 지면에 보이는 순서(표지 → 지면마다 정렬된 카드)
    private func flat(_ d: Magazine.Resolved) -> [NewsItem] {
        let sort = MagSort(rawValue: sortRaw) ?? .recommended
        return [shownCover(d)?.item].compactMap { $0 } + shown(d).flatMap { sort.apply($0.items) }
    }

    // 표지는 칩으로 거르지 않았을 때만(AI 하위 칩을 고르면 그 분류 기사만)
    private func shownCover(_ d: Magazine.Resolved) -> Database.StoredItem? {
        guard focus == nil else { return nil }
        guard let c = d.cover else { return nil }
        if let sub, c.item.category != sub { return nil }
        return c
    }

    // 머리: 왼쪽 목록에서 고른 것과 같은 이름, 숫자는 지면에 실린 것 기준
    private func headTitle(_ d: Magazine.Resolved) -> String {
        switch source {
        case .section(let id): return Sections.name(id)
        case .week: return d.issue.title.replacingOccurrences(of: "주간 · ", with: "이번 주 · ")
        default: return d.issue.title
        }
    }
    private func kicker(_ d: Magazine.Resolved) -> String {
        switch source {
        case .today: return "오늘"
        case .week: return "이번 주"
        case .section: return "오늘 호의 분야 지면 · " + d.issue.title.replacingOccurrences(of: " 호", with: "")
        case .fixed(let i): return i.isThin ? "지난 호 · 기록 적음" : "지난 호"
        }
    }
    private func subtitle(_ d: Magazine.Resolved) -> String {
        let pages = shown(d)
        let n = (shownCover(d) == nil ? 0 : 1) + pages.reduce(0) { $0 + $1.items.count }
        if let id = sectionID {
            let outlets = Set(([shownCover(d)?.item].compactMap { $0 } + pages.flatMap(\.items)).map(\.sourceId)).count
            return Magazine.subtitle(total: d.issue.count, shown: n, sections: 0, noun: Sections.name(id) + " 소식") + " · 출처 \(outlets)곳"
        }
        return Magazine.subtitle(total: d.issue.count, shown: n, sections: pages.filter { $0.section.kind == nil }.count)
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard let d = data, let k = NavKey.from(press) else { return .ignored }
        let list = flat(d)
        switch k {
        case .next, .prev: selected = NavKey.move(selected, in: list.map(\.key), by: k == .next ? 1 : -1)
        default:
            guard let it = list.first(where: { $0.key == selected }) ?? (k == .open ? list.first : nil) else { return .ignored }
            ItemKeys.perform(k, item: it, sequence: list, fromMagazine: true)
        }
        return .handled
    }
    @AppStorage("magSort") private var sortRaw = MagSort.recommended.rawValue

    private var isFixed: Bool { if case .fixed = source { return true }; return false }
    // 오늘 호를 다 읽었으면 새 소식을 더 밀어 넣지 않는다(M-23)
    @State private var todayDone = TodayIssue.isMarkedDone()
    @State private var built = false // 이 화면에서 한 번이라도 엮었는지(지난 결과만 보이는 동안은 '새 소식' 알림을 띄우지 않음)
    private var newCount: Int { !built || isFixed || (source == .today && todayDone) ? 0 : max(0, mag.revision - seenRevision) }

    @State private var buildGen = 0

    // 호를 엮고 꺼내는 일은 화면 줄기 밖(Editor)에서 하고, 다 되면 바꿔 끼운다(늦게 끝난 옛 요청은 버림)
    private func build(animated: Animation? = nil, then: (() -> Void)? = nil) {
        buildGen += 1
        let gen = buildGen, rev = mag.revision
        Task {
            let r: Magazine.Resolved
            switch source {
            case .today: r = await mag.today()
            case .week: r = await mag.week()
            case .section(let id): r = await mag.section(id)
            case .fixed(let i): r = await mag.resolve(i)
            }
            guard gen == buildGen else { return }
            withMotion(animated) { data = r }
            seenRevision = rev
            built = true
            IssueCache.put(source, r, revision: rev)
            if selected == nil, let n = TestEnv.get("SELECT").flatMap(Int.init) { // 시험용: 선택 테두리 보기
                let list = flat(r); if list.indices.contains(n) { selected = list[n].key }
            }
            then?()
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id("top").reportsScrolledPastTop(in: "issueScroll")
                    if let d = data {
                        Masthead(title: headTitle(d), kicker: kicker(d), subtitle: subtitle(d), live: !isFixed, appeared: appeared)
                            .padding(.horizontal, Space.page).padding(.top, Space.xl).padding(.bottom, Space.xl)
                            .overlay(alignment: .bottomTrailing) {
                                Picker("정렬", selection: $sortRaw) {
                                    ForEach(MagSort.allCases, id: \.rawValue) { Label($0.label, systemImage: $0.symbol).tag($0.rawValue) }
                                }
                                .pickerStyle(.menu).fixedSize()
                                .padding(.trailing, Space.page).padding(.bottom, Space.xxl)
                                .help("지면 안의 기사 순서")
                            }
                        if source == .today, focus == nil {
                            TodayProgressView(keys: TodayIssue.keys(cover: d.cover?.item.key, sections: d.sections, chosen: AppModel.shared.chosenSections)) {
                                todayDone = true
                            }
                            .padding(.horizontal, Space.page).padding(.top, -8).padding(.bottom, Space.l)
                        }
                        let chips = d.sections.compactMap { $0.section.section }
                        let counts = Dictionary(d.sections.compactMap { s in s.section.section.map { ($0, s.items.count) } }, uniquingKeysWith: +)
                        if let id = sectionID {
                            // 분야 지면: '전체'·다른 분야 칩 없이, AI 면 그 안의 하위 칩만
                            if id == Sections.ai { AISubChips(sub: $sub, items: [d.cover?.item].compactMap { $0 } + d.sections.flatMap(\.items)).padding(.horizontal, Space.page).padding(.bottom, Space.l) }
                            if let b = AppModel.shared.brief(id) { EveningBriefBox(brief: b).padding(.horizontal, Space.page).padding(.bottom, Space.l) }
                        } else if source == .today, chips.count > 1 {
                            // 오늘 호의 분야 칩은 왼쪽 목록의 분야 지면으로 간다(칩과 목록 선택이 늘 같게)
                            SectionChipBar(section: Binding(get: { nil }, set: { id in
                                               if let id { NotificationCenter.default.post(name: .magazineGo, object: MagazineView.Page.section(id)) }
                                           }), sub: .constant(nil), sections: chips) // 건수는 가는 곳(분야 지면)과 달라 달지 않는다
                                .padding(.horizontal, Space.page).padding(.bottom, Space.l)
                        } else if chips.count > 1 || focus != nil {
                            SectionChipBar(section: $focus, sub: $sub, sections: chips, counts: counts)
                                .padding(.horizontal, Space.page).padding(.bottom, Space.l)
                        }
                        if let c = shownCover(d) {
                            CoverStory(stored: c, issue: d.issue, onStory: onStory)
                                .padding(.horizontal, Space.xl)
                                .opacity(appeared ? 1 : 0)
                                .offset(y: appeared ? 0 : 24)
                                .motion(Motion.settle.delay(Motion.stagger(4)), value: appeared)
                        } else if shown(d).isEmpty {
                            EmptyIssue(live: !isFixed, preparing: mag.preparing).padding(.horizontal, Space.page)
                        }
                        ForEach(Array(shown(d).enumerated()), id: \.element.section.id) { si, sec in
                            // 분야 지면은 머리가 이미 분야 이름이므로 유리 띠를 다시 달지 않는다
                            SectionBlock(section: sec.section, items: (MagSort(rawValue: sortRaw) ?? .recommended).apply(sec.items),
                                         issue: d.issue, index: si, onStory: onStory, clusters: d.clusters, regions: d.regions, header: sectionID == nil)
                                .padding(.top, si == 0 && shownCover(d) == nil ? 6 : 38)
                        }
                        Text("기사 저작권은 각 언론사·기업에 있습니다. 제목·요약·사진은 원문으로 이어 주기 위한 것입니다.")
                            .font(.dsCaption).foregroundStyle(.tertiary)
                            .padding(.horizontal, Space.page).padding(.vertical, Space.xxxl)
                    } else {
                        IssueBuilding(source: source, preparing: mag.preparing).padding(.horizontal, Space.page)
                    }
                }
            }
            .coordinateSpace(name: "issueScroll")
            // 키보드: 카드 고르기·열기·저장·브라우저·읽음(상단바 목록과 같은 키)
            .environment(\.selectedCard, selected)
            .environment(\.readerSequence, data.map(flat) ?? [])
            .focusable()
            .focusEffectDisabled()
            .focused($keyFocus)
            .onKeyPress(phases: .down) { handle($0) }
            .onChange(of: selected) { _, k in
                guard let k else { return }
                withAnimation(reduceMotion ? nil : Motion.change()) { proxy.scrollTo(k, anchor: .center) }
            }
            // 보는 동안 새 소식이 오면 지면을 갈아엎지 않고 위에 알림만 띄운다
            .overlay(alignment: .top) {
                if newCount > 0 {
                    Button {
                        build(animated: Motion.settle) { withMotion(Motion.change()) { proxy.scrollTo("top") } }
                    } label: {
                        Label("새 소식이 들어왔어요 · 새로 보기", systemImage: "arrow.up")
                            .font(.dsBodyStrong)
                            .padding(.horizontal, Space.l).padding(.vertical, Space.s)
                            .chromeGlass(in: Capsule())
                            .overlay(Capsule().strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
                            .elevation(Elevation.card)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, Space.l)
                    .transition(Motion.drop)
                }
            }
            .motion(Motion.snap, value: newCount > 0)
        }
        .onAppear { build(); appeared = true; keyFocus = true }
        // 빈 지면이면 알림 없이 바로 채운다(처음 켰을 때)
        .onChange(of: mag.revision) { _, _ in
            // 지면이 비었거나 표지가 아직 없으면 알림 없이 바로 채운다(처음 켰을 때 등)
            if !isFixed, data?.cover == nil || (data?.issue.count ?? 0) == 0 || mag.preparing {
                build(animated: Motion.settle)
            }
        }
        .onChange(of: mag.imageRevision) { _, _ in
            // 사진만 새로 채워졌으면 알림 없이 조용히 반영(새 소식은 그대로 알림으로)
            let pending = mag.revision != seenRevision
            if !pending { build() }
        }
        .onChange(of: mag.layoutRevision) { _, _ in build() } // 출처 숨기기·분야 바꾸기는 바로 반영
        .onChange(of: mag.preparing) { _, now in
            if !now, !isFixed { build(animated: Motion.settle) } // 첫 호가 다 엮이면 바로 보여 준다
        }
    }
}

// 분야 지면 'AI' 의 하위 칩(모델·연구…) — 그 분류 기사가 있는 것만, 건수와 함께
private struct AISubChips: View {
    @Binding var sub: NewsCategory?
    let items: [NewsItem]
    var body: some View {
        let counts = Dictionary(grouping: items, by: \.category).mapValues(\.count)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.xs) {
                ForEach(NewsCategory.allCases.filter { (counts[$0] ?? 0) > 0 }) { c in // '기타'까지 — 칩 숫자의 합이 실린 수와 같게
                    SectionChip(label: c.label, symbol: c.symbol, color: c.color, on: sub == c, count: counts[c]) {
                        sub = sub == c ? nil : c
                    }
                }
            }
            .padding(.vertical, 1)
        }
    }
}

private struct Masthead: View {
    let title: String
    var kicker: String? = nil
    let subtitle: String
    let live: Bool
    let appeared: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                // 로고: 잡지 첫 글자를 크게 키우는 '드롭캡'처럼 D 를 크게
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("D").font(.system(size: 22, weight: .black, design: .serif))
                    Text("ROPCAP").font(.system(size: 13, weight: .heavy, design: .serif)).tracking(2.2)
                }
                .foregroundStyle(.primary)
                Text("매거진").font(.dsCaption).foregroundStyle(.secondary)
                if let kicker { Text("· " + kicker).font(.dsCaption).foregroundStyle(.secondary) }
                if live {
                    Text("발행 중").font(.dsChip).foregroundStyle(.white)
                        .padding(.horizontal, Space.s).padding(.vertical, Space.xxs)
                        .background(Color.red.gradient, in: Capsule())
                        .symbolEffect(.pulse)
                }
            }
            .foregroundStyle(.secondary)
            .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 8)
            .motion(Motion.settle, value: appeared)
            Text(title)
                .font(.dsHero)
                .tracking(-0.6)
                .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 14)
                .motion(Motion.settle.delay(Motion.stagger(1)), value: appeared)
            Text(subtitle)
                .font(.dsBody).foregroundStyle(.secondary)
                .opacity(appeared ? 1 : 0)
                .motion(Motion.settle.delay(Motion.stagger(2)), value: appeared)
            Rectangle().fill(.primary.opacity(0.85)).frame(height: 2)
                .scaleEffect(x: appeared ? 1 : 0, anchor: .leading)
                .motion(Motion.settle.delay(Motion.stagger(3)), value: appeared)
                .padding(.top, Space.m)
        }
    }
}

// 지면을 처음 엮는 동안: 빈 화면 대신 머리 자리와 진행 표시(뼈대)
struct IssueBuilding: View {
    let source: IssueView.Source
    var preparing = false

    static func title(_ source: IssueView.Source) -> String {
        switch source {
        case .today: return "오늘"
        case .week: return "이번 주"
        case .section(let id): return Sections.name(id)
        case .fixed(let i): return i.title
        }
    }
    static func message(preparing: Bool) -> String { preparing ? "첫 호를 엮는 중…" : "지면을 엮는 중…" }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text(Self.title(source)).font(.dsTitle).padding(.top, Space.xl)
            HStack(spacing: Space.s) {
                ProgressView().controlSize(.small)
                Text(Self.message(preparing: preparing)).font(.dsBody).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            ForEach(0..<3, id: \.self) { i in // 카드 뼈대
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(.primary.opacity(0.05))
                    .frame(height: i == 0 ? 220 : 96)
            }
            .padding(.top, Space.m)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// 지면마다 마지막으로 엮은 결과(이번 실행 동안만). 지면을 다시 열면 이것부터 보이고 새로 엮은 것으로 바꾼다.
@MainActor
enum IssueCache {
    private static var last: [String: (data: Magazine.Resolved, revision: Int)] = [:]

    static func key(_ source: IssueView.Source) -> String {
        switch source {
        case .today: return "today"
        case .week: return "week"
        case .section(let id): return "section:" + id
        case .fixed(let i): return "fixed:" + i.id
        }
    }
    static func get(_ source: IssueView.Source) -> (data: Magazine.Resolved, revision: Int)? { last[key(source)] }
    static func put(_ source: IssueView.Source, _ data: Magazine.Resolved, revision: Int) { last[key(source)] = (data, revision) }
    static func clear() { last = [:] }
}

private struct EmptyIssue: View {
    let live: Bool
    var preparing = false
    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if preparing {
                ProgressView().controlSize(.small)
                Text("첫 호를 엮는 중…").font(.dsHeading)
                Text("구독한 출처에서 최근 사흘 소식을 모으고 번역하고 있어요. 잠시면 됩니다.").font(.dsBody).foregroundStyle(.secondary)
            } else {
                Image(systemName: "newspaper").font(.app(34, .light)).foregroundStyle(.tertiary)
                Text(live ? "아직 이번 호에 실을 소식이 없습니다" : "이 호에는 소식이 없습니다").font(.dsHeading)
                Text("새 소식이 들어오는 대로 지면이 채워집니다.").font(.dsBody).foregroundStyle(.secondary)
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
    @Environment(\.selectedCard) private var selectedCard
    @Environment(\.readerSequence) private var sequence
    @State private var drift = false
    @State private var hover = false
    @State private var frame: CGRect = .zero

    private var item: NewsItem { stored.item }
    // 사진이 없으면 사진 자리를 만들지 않고 글자 표지로(지어낸 그림은 쓰지 않음)
    private var hasPhoto: Bool { item.image != nil && !ImageKey.isJunk(item.image) }
    private var ink: Color { hasPhoto ? .white : .primary }
    private var storyID: String? {
        guard let c = stored.cluster, (Magazine.shared.cluster(c)?.size ?? 1) >= 2 else { return nil }
        return c
    }

    private func openArticle() {
        TestLog.write("[표지] 눌림 \(item.title.prefix(30))")
        AppModel.shared.markOpened(item)
        ReaderController.open(item, from: frame, sequence: sequence)
    }

    // 카드 전체가 하나의 단추(일반 카드와 같은 방식). 예전엔 카드에 onTapGesture 를 달았는데,
    // 스크롤 지면 안에서 그 제스처가 클릭을 받지 못하고 안쪽 '기사 읽기' 단추까지 막아 표지가 통째로 반응이 없었다.
    // '여러 시각' 단추는 카드 단추 안에 넣으면 눌리지 않으므로 같은 자리에 위로 겹쳐 둔다.
    var body: some View {
        Button { openArticle() } label: { card }
            .buttonStyle(.plain)
            .overlay(alignment: .bottomLeading) {
                if let c = storyID {
                    HStack(spacing: Space.m) {
                        readPill.hidden() // 자리만 맞춘다(누르면 아래 카드 단추로)
                        Button { onStory(c) } label: { storyPill(c) }.buttonStyle(.plain)
                    }
                    .padding(Space.xxl)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
            .onContinuousHover { phase in
                switch phase { case .active: NSCursor.pointingHand.set(); case .ended: NSCursor.arrow.set() }
            }
            .elevation(hover ? Elevation.floating : Elevation.raised)
            .scaleEffect(hover ? 1.006 : 1)
            .motion(Motion.snap, value: hover)
            .onHover { hover = $0 }
            .selectionRing(selectedCard == item.key, radius: Radius.panel)
            .id(item.key)
            .background(ScreenFrame(frame: $frame))
            .onAppear {
                // 움직임 줄이기를 켠 사람에게는 끝없이 흐르는 켄 번스를 돌리지 않는다
                guard !reduceMotion, TestEnv.get("NOKB") == nil else { return }
                withAnimation(.easeInOut(duration: 22).repeatForever(autoreverses: true)) { drift = true }
            }
    }

    private var card: some View {
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
                RoundedRectangle(cornerRadius: Radius.panel, style: .continuous).fill(.primary.opacity(0.045))
            }
            VStack(alignment: .leading, spacing: Space.m) {
                HStack(spacing: Space.s) {
                    Text("표지").font(.app(11, .heavy)).tracking(1.5)
                        .padding(.horizontal, Space.s).padding(.vertical, Space.xs)
                        .background(ink, in: RoundedRectangle(cornerRadius: Radius.xs))
                        .foregroundStyle(hasPhoto ? Color.black : Color(nsColor: .textBackgroundColor))
                    Label(item.topicLabel, systemImage: item.topicSymbol).font(.dsBodyStrong)
                    Text("\(item.sourceName) · \(RelativeTime.string(item.date))").font(.dsCallout)
                    PaywallMark(item: item)
                }
                .foregroundStyle(ink.opacity(0.9))
                Text(item.displayTitle)
                    .font(.dsTitle)
                    .foregroundStyle(ink)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .shadow(color: .black.opacity(hasPhoto ? 0.3 : 0), radius: 8, y: 2)
                if item.titleKo != nil, item.titleKo != item.title {
                    Text(item.title).font(.dsBody).foregroundStyle(ink.opacity(0.7)).lineLimit(1)
                }
                HStack(spacing: Space.m) {
                    readPill
                    if let c = storyID { storyPill(c).hidden() } // 실제 단추는 위에 겹친다
                }
                .padding(.top, Space.xs)
            }
            .padding(Space.xxl)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: hasPhoto ? 400 : nil)
        .contentShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var readPill: some View {
        Label("기사 읽기", systemImage: "book").font(.dsBodyStrong)
            .padding(.horizontal, Space.l).padding(.vertical, Space.s)
            .background(ink, in: Capsule()).foregroundStyle(hasPhoto ? Color.black : Color(nsColor: .textBackgroundColor))
    }

    private func storyPill(_ c: String) -> some View {
        Label("여러 시각 \(Magazine.shared.cluster(c)?.size ?? 2)곳", systemImage: "rectangle.split.3x1")
            .font(.dsBodyStrong)
            .padding(.horizontal, Space.l).padding(.vertical, Space.s)
            .background(ink.opacity(0.12), in: Capsule()).foregroundStyle(ink)
            .overlay(Capsule().strokeBorder(ink.opacity(0.35), lineWidth: 0.5))
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
    var regions: [String: [NewsItem]] = [:]
    var header = true

    @ObservedObject private var photos = SectionPhotos.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            if !header {
                EmptyView()
            } else if let ns = Sections.byID(section.section), section.kind == nil {
                // 분야 지면: 분야 고르기와 같은 유리 띠(오늘의 사진 · 기사 수 · 첫 기사 제목)
                SectionGlassCard(section: ns, photo: photos.images[ns.id], subtitle: "\(items.count)건 · " + (items.first?.displayTitle ?? ""), height: 92, showsCheck: false)
                    .padding(.horizontal, Space.xl)
                    .onAppear { photos.load() }
            } else {
                HStack(spacing: Space.s) {
                    Image(systemName: section.symbol).foregroundStyle(section.color)
                    Text(section.label).font(.dsHeading)
                    Text("\(items.count)").font(.dsBodyStrong).foregroundStyle(.secondary)
                    Rectangle().fill(.primary.opacity(0.12)).frame(height: 1).padding(.leading, Space.s)
                }
                .padding(.horizontal, Space.page)
            }
            BalancedGrid(count: items.count) { cols in
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 200, maximum: 360), spacing: Space.l), count: cols), alignment: .leading, spacing: Space.xl) {
                    ForEach(Array(items.enumerated()), id: \.element.key) { i, it in
                        StoryCard(item: it, issue: issue, order: i, onStory: onStory, clusterID: clusters[it.key],
                                  storyItems: clusters[it.key].flatMap { regions[$0] } ?? [])
                    }
                }
            }
            .padding(.horizontal, Space.xl)
        }
    }
}

struct StoryCard: View {
    let item: NewsItem
    var issue: Issue?
    var order: Int = 0
    var onStory: ((String) -> Void)?
    var clusterID: String?
    var storyItems: [NewsItem] = []   // 같은 스토리 보도(해외·국내가 섞였을 때만 줄로 보임)
    @Environment(\.selectedCard) private var selectedCard
    @Environment(\.readerSequence) private var sequence
    @State private var hover = false
    @State private var tilt: CGSize = .zero
    @State private var shown = false
    @State private var frame: CGRect = .zero

    var body: some View {
        Button {
            AppModel.shared.markOpened(item)
            ReaderController.open(item, from: frame, sequence: sequence)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                // 마우스를 따라 사진이 살짝 움직이는 시차 효과(사진이 없으면 사진 자리 없이 글만)
                if item.image != nil && !ImageKey.isJunk(item.image) {
                // 사진 크기가 칸 너비를 밀어내지 않게 칸에 맞춘 틀 위에 겹친다(칸이 좁은 4열에서 카드가 서로 겹치던 문제)
                Color.clear.frame(maxWidth: .infinity).frame(height: 150)
                    .overlay {
                        RemoteImage(url: item.image, category: item.category, accent: item.accent)
                            .scaleEffect(hover ? 1.08 : 1.0)
                            .offset(x: tilt.width * 8, y: tilt.height * 6)
                    }
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
                        if item.itemKind != .article { KindBadge(kind: item.itemKind).chromeGlass(in: RoundedRectangle(cornerRadius: Radius.xs)).padding(Space.s) }
                    }
                }
                VStack(alignment: .leading, spacing: Space.s) {
                    HStack(spacing: Space.s) {
                        if item.important == true { Image(systemName: "star.fill").foregroundStyle(.orange).font(.dsCaption) }
                        Text(item.sourceName).font(.dsChip)
                        PaywallMark(item: item)
                        if let r = item.related, !r.isEmpty { Text("외 \(r.count)곳").font(.dsCaption).foregroundStyle(.secondary) }
                        Spacer(minLength: 0)
                        Text(RelativeTime.string(item.date)).font(.dsCaption).foregroundStyle(.tertiary)
                    }
                    Text(item.displayTitle)
                        .font(.dsSubheading)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if !storyItems.isEmpty { RegionSplit(items: storyItems, compact: true) }
                    if AppModel.shared.isRead(item) {
                        Label("읽음", systemImage: "checkmark").font(.dsCaption).foregroundStyle(.tertiary)
                    }
                }
                .padding(Space.l)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
            .elevation(hover ? Elevation.raised : Elevation.card)
            .scaleEffect(hover ? 1.025 : 1)
            .contentShape(RoundedRectangle(cornerRadius: Radius.card))
        }
        .buttonStyle(.plain)
        .selectionRing(selectedCard == item.key, radius: Radius.card)
        .id(item.key)
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                tilt = CGSize(width: (p.x / max(frame.width, 1)) - 0.5, height: (p.y / 220) - 0.5)
            case .ended:
                tilt = .zero
            }
        }
        .onHover { h in withMotion(Motion.snap) { hover = h } }
        .motion(Motion.snap, value: tilt)
        .contextMenu {
            Button(AppModel.shared.isSaved(item) ? "저장 취소" : "나중에 읽기") { AppModel.shared.toggleSaved(item) }
            if let c = clusterID, let onStory {
                Button("여러 시각 보기") { onStory(c) }
            }
            Button("브라우저에서 열기") { ExternalLink.open(item.link) }
            ReduceMenu(item: item)
        }
        .background(ScreenFrame(frame: $frame))
        // 지면이 차례로 깔리는 느낌: 처음엔 순서대로, 스크롤할 땐 들어오며 또렷해진다
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 18)
        .onAppear {
            withMotion(Motion.settle.delay(Motion.stagger(order))) { shown = true }
        }
        .scrollTransition(.animated(Motion.enter())) { content, phase in
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
        // 위치만 재는 뷰라 클릭을 받지 않는다. 받으면 그 위의 카드·단추가 눌리지 않는다(매거진 표지 '기사 읽기'가 반응 없던 원인)
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
    // 목록은 화면 줄기 밖에서 한 번에 만든다(예전엔 그릴 때마다 메인에서 스토리마다 DB 를 물어 멈췄다 — STABILITY.md S5)
    @State private var groups = Magazine.shared.lastStoryCards
    @State private var loaded = Magazine.shared.storyCardsLoaded

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.l) {
                Text("스토리").font(.dsTitle).padding(.top, Space.xl)
                Text("여러 곳이 함께 다룬 소식을 한 줄기로 묶었습니다. 팔로우하면 새 보도가 붙을 때 알려 드립니다.").foregroundStyle(.secondary)
                if loaded, groups.live.isEmpty && groups.past.isEmpty {
                    Text("아직 여러 곳이 함께 다룬 소식이 없습니다. 출처를 더 구독하면 스토리가 늘어납니다.").foregroundStyle(.secondary).padding(.vertical, Space.xxxl)
                }
                if !groups.live.isEmpty {
                    sectionTitle("지금 커지는 스토리", "최근 24시간")
                    ForEach(Array(groups.live.enumerated()), id: \.element.id) { i, c in
                        StoryListCard(cluster: c.cluster, items: c.items, topic: c.topic, big: i == 0, onOpen: { onStory(c.id) }).modifier(Stagger(index: i))
                    }
                }
                if !groups.past.isEmpty {
                    sectionTitle("지난 스토리", "최근 2주")
                    ForEach(Array(groups.past.enumerated()), id: \.element.id) { i, c in
                        StoryListCard(cluster: c.cluster, items: c.items, topic: c.topic, big: false, onOpen: { onStory(c.id) }).modifier(Stagger(index: i + groups.live.count))
                    }
                }
            }
            .padding(.horizontal, Space.page).padding(.bottom, Space.xxxl)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .task(id: "\(mag.revision)-\(mag.layoutRevision)") { groups = await mag.storyCards(); loaded = true }
    }

    private func sectionTitle(_ t: String, _ sub: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text(t).font(.dsHeadline)
            Text(sub).font(.dsCallout).foregroundStyle(.tertiary)
        }
        .padding(.top, Space.l)
    }
}

// 스토리 카드: 대표 사진 · 분야 · 다룬 출처들 · 시작/최근 · 새 보도 · 팔로우 표시
private struct StoryListCard: View {
    let cluster: Database.Cluster
    let items: [NewsItem] // 보이는 보도들(목록을 만들 때 함께 꺼냄)
    let topic: (section: String, category: NewsCategory?)? // 분야 다수결(목록을 만들 때 화면 줄기 밖에서 — STABILITY.md S8)
    let big: Bool
    let onOpen: () -> Void
    @ObservedObject private var app = AppModel.shared
    @State private var hover = false

    var body: some View {
        let photo = items.compactMap(\.image).first { !ImageKey.isJunk($0) }
        let lead = items.first { $0.tier == "lab" } ?? items.first
        let sources = Array(NSOrderedSet(array: items.map(\.sourceName)).array as? [String] ?? []).prefix(6)
        let fresh = app.unseenReports(cluster)
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: Space.l) {
                if let photo {
                    RemoteImage(url: photo, category: lead?.category ?? .other, accent: lead?.accent ?? .accentColor)
                        .frame(width: big ? 210 : 120, height: big ? 140 : 80)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                }
                VStack(alignment: .leading, spacing: Space.s) {
                    HStack(spacing: Space.s) {
                        // 분야는 묶인 보도들의 다수결(대표 기사 하나의 AI 하위 분류를 그대로 쓰면 IT 소식이 'AI·모델·제품'이 됐다)
                        if let t = topic {
                            let ns = Sections.byID(t.section)
                            Label(t.category.map { "AI·" + $0.label } ?? Sections.name(t.section), systemImage: t.category?.symbol ?? ns?.symbol ?? "circle")
                                .font(.dsChip).foregroundStyle(t.category?.color ?? ns?.tint ?? .gray)
                        }
                        Text("\(cluster.size)곳 보도").font(.dsChip).foregroundStyle(.secondary)
                        if fresh > 0 {
                            Text("새 보도 \(fresh)").font(.dsChip).foregroundStyle(.white)
                                .padding(.horizontal, Space.s).padding(.vertical, Space.xxs).background(Color.red, in: Capsule())
                        }
                        if app.isFollowing(cluster.id) { Image(systemName: "bell.fill").font(.dsCaption).foregroundStyle(.orange).help("팔로우 중") }
                    }
                    Text(cluster.title).font(.display(big ? 21 : 16, .semibold)).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: -5) {
                        ForEach(Array(sources.enumerated()), id: \.offset) { _, name in
                            let it = items.first { $0.sourceName == name }
                            Monogram(letter: it?.initial ?? String(name.prefix(1)), color: it?.accent ?? .gray, size: 20)
                                .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Color(nsColor: .textBackgroundColor), lineWidth: 1.5))
                                .help(name)
                        }
                        Text("  \(sources.joined(separator: " · "))").font(.dsCaption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text("첫 보도 \(RelativeTime.string(cluster.first)) · 최근 \(RelativeTime.string(cluster.last))")
                        .font(.dsCaption).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(Space.l)
            .background(.primary.opacity(hover ? 0.07 : 0.04), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
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
                Button(action: back) { Label("스토리", systemImage: "chevron.left") }.buttonStyle(.borderless).padding(.top, Space.xl)
                Text(cluster?.title ?? "스토리").font(.dsTitle).padding(.top, Space.m)
                HStack(spacing: Space.m) {
                    Text("\(items.count)곳 보도 · \(Self.span(items))").foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        app.setFollowing(clusterID, !following, size: items.count)
                    } label: {
                        Label(following ? "팔로우 중" : "이 스토리 팔로우", systemImage: following ? "bell.fill" : "bell")
                            .font(.dsBodyStrong)
                    }
                    .buttonStyle(.bordered).tint(following ? .orange : .accentColor)
                    .help("새 보도가 이 스토리에 붙으면 알림")
                }
                .padding(.top, Space.s).padding(.bottom, Space.xl)
                if digest != nil || digesting {
                    VStack(alignment: .leading, spacing: Space.s) {
                        Label("한눈에", systemImage: "text.alignleft").font(.dsBodyStrong).foregroundStyle(.secondary)
                        if let digest {
                            ForEach(Array(digest.enumerated()), id: \.offset) { _, l in
                                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                                    Circle().fill(.secondary).frame(width: 4, height: 4).offset(y: -3)
                                    Text(l).font(.app(15)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Text("여러 보도를 이 Mac 의 Apple Intelligence 로 합쳐 요약했습니다.").font(.dsCaption).foregroundStyle(.tertiary)
                        } else {
                            HStack(spacing: Space.s) { ProgressView().controlSize(.small); Text("여러 보도를 합쳐 요약하는 중…").font(.dsBody).foregroundStyle(.secondary) }
                        }
                    }
                    .padding(Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .padding(.bottom, Space.xl)
                }
                // 같은 이야기를 해외와 국내가 어떻게 다뤘나(둘 다 있을 때만)
                RegionSplit(items: items) { it in AppModel.shared.markOpened(it); ReaderController.open(it) }
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.primary.opacity(0.15)).frame(width: 2)
                        .frame(maxHeight: .infinity)
                        .scaleEffect(x: 1, y: progress, anchor: .top)
                        .padding(.leading, Space.s)
                    VStack(alignment: .leading, spacing: Space.l) {
                        ForEach(Array(items.enumerated()), id: \.element.key) { i, it in
                            if let gap = Self.gap(items, i) {
                                Text(gap).font(.dsChip).foregroundStyle(.tertiary).padding(.leading, Space.page).padding(.top, -6)
                            }
                            TimelineRow(item: it, first: i == 0)
                                .opacity(progress >= CGFloat(i + 1) / CGFloat(max(items.count, 1)) * 0.9 ? 1 : 0)
                                .offset(x: progress >= CGFloat(i + 1) / CGFloat(max(items.count, 1)) * 0.9 ? 0 : 12)
                                .motion(Motion.settle, value: progress)
                        }
                    }
                }
            }
            .padding(.horizontal, Space.page).padding(.bottom, Space.xxxl)
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
            withMotion(Motion.enter()) { digest = d; digesting = false }
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
        HStack(alignment: .top, spacing: Space.l) {
            Circle().fill(first ? item.accent : Color(nsColor: .textBackgroundColor))
                .overlay(Circle().strokeBorder(item.accent, lineWidth: 2))
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.s) {
                    Monogram(letter: item.initial, color: item.accent, size: 18)
                    Text(item.sourceName).font(.dsBodyStrong)
                    Text(Resources.tierLabel(item.tier)).font(.dsCaption).foregroundStyle(.secondary)
                    PaywallMark(item: item)
                    Text("· " + (item.date?.formatted(.dateTime.locale(Locale(identifier: "ko_KR")).hour().minute()) ?? ""))
                        .font(.dsCaption).foregroundStyle(.secondary)
                    if first { Text("첫 보도").font(.dsChip).foregroundStyle(item.accent) }
                }
                Button {
                    AppModel.shared.markOpened(item)
                    ReaderController.open(item, from: frame)
                } label: {
                    HStack(alignment: .top, spacing: Space.m) {
                        VStack(alignment: .leading, spacing: Space.s) {
                            Text(item.displayTitle).font(.dsSubheading)
                                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                            if let lede = Self.lede(item) {
                                Text(lede).font(.dsBody).foregroundStyle(.secondary).lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        Spacer(minLength: 0)
                        if item.image != nil && !ImageKey.isJunk(item.image) {
                            RemoteImage(url: item.image, category: item.category, accent: item.accent)
                                .frame(width: 92, height: 62).clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        }
                    }
                    .padding(Space.l)
                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
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
            VStack(alignment: .leading, spacing: Space.l) {
                HStack(alignment: .firstTextBaseline, spacing: Space.m) { // 왼쪽 목록 '저장 N' 과 같은 수
                    Text("저장").font(.dsTitle)
                    Text("\(app.state.saved.count)건").font(.dsHeadline).foregroundStyle(.secondary)
                }
                .padding(.top, Space.xl)
                Text("저장한 기사는 번역까지 이 Mac 에 보관돼 인터넷 없이도 읽을 수 있습니다.").foregroundStyle(.secondary)
                AddURLBar(compact: false).frame(maxWidth: 560)
                if app.state.saved.isEmpty {
                    Text("아직 저장한 기사가 없습니다. 카드를 오른쪽 클릭해 '나중에 읽기'로 저장하세요.").foregroundStyle(.secondary).padding(.vertical, Space.xxxl)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 360), spacing: Space.l)], alignment: .leading, spacing: Space.xl) {
                    ForEach(Array(app.state.saved.enumerated()), id: \.element.key) { i, it in
                        StoryCard(item: it, order: i)
                            .overlay(alignment: .topTrailing) {
                                if ArticleService.shared.cached(it.link) != nil {
                                    Label("보관됨", systemImage: "arrow.down.circle.fill").font(.dsChip)
                                        .padding(.horizontal, Space.s).padding(.vertical, Space.xs)
                                        .chromeGlass(in: Capsule()).padding(Space.m)
                                }
                            }
                    }
                }
            }
            .padding(.horizontal, Space.xxl).padding(.bottom, Space.xxxl)
        }
    }
}

struct SearchView: View {
    @State private var q = MagazineController.pendingSearch ?? ""
    @State private var results: [NewsItem] = []
    @AppStorage("magRecentSearches") private var recentRaw = ""
    private var recent: [String] { recentRaw.split(separator: "\n").map(String.init) }
    private func remember(_ t: String) { recentRaw = Magazine.rememberSearch(t, in: recent).joined(separator: "\n") }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                Text("검색").font(.dsTitle).padding(.top, Space.xl)
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("모든 기록에서 제목·출처·요약 검색", text: $q).textFieldStyle(.plain).font(.app(15))
                        .onSubmit { remember(q); Task { results = await Magazine.shared.search(q) } }
                        .task(id: q) { // 입력이 멈추면(0.25초) 찾는다
                            guard q.count >= 2 else { if q.isEmpty { results = [] }; return }
                            try? await Task.sleep(for: .milliseconds(250))
                            if !Task.isCancelled { let r = await Magazine.shared.search(q); if !Task.isCancelled { results = r } }
                        }
                }
                .padding(Space.m)
                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .onReceive(NotificationCenter.default.publisher(for: .magazineSearch)) { n in if let w = n.object as? String { q = w } }
                .onDisappear { MagazineController.pendingSearch = nil; if !results.isEmpty { remember(q) } }
                if !q.isEmpty { Text("\(results.count)건").foregroundStyle(.secondary) }
                if q.isEmpty { emptyState }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 360), spacing: Space.l)], alignment: .leading, spacing: Space.xl) {
                    ForEach(Array(results.enumerated()), id: \.element.key) { i, it in StoryCard(item: it, order: i) }
                }
            }
            .padding(.horizontal, Space.xxl).padding(.bottom, Space.xxxl)
        }
    }
}

extension SearchView {
    // 빈 검색 화면: 지켜볼 낱말·최근 검색어를 눌러 바로 찾기, 무엇을 찾는지 안내
    @ViewBuilder var emptyState: some View {
        let watch = AppModel.shared.state.settings.watchKeywords
        VStack(alignment: .leading, spacing: Space.l) {
            if !watch.isEmpty { chipRow("지켜볼 낱말", watch, symbol: "eye") }
            if !recent.isEmpty {
                chipRow("최근 검색", recent, symbol: "clock.arrow.circlepath")
                Button("최근 검색 지우기") { recentRaw = "" }.buttonStyle(.link).font(.dsCallout)
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("이 Mac 에 모인 모든 기사(지난 호 포함)의 제목·출처·요약에서 찾습니다.")
                Text("회사·인물 이름이나 출처 이름(예: 연합뉴스)으로도 찾을 수 있습니다. ⌘F 로 언제든 이 화면을 엽니다.")
                if watch.isEmpty { Text("설정 › 거르기의 '지켜볼 낱말'을 넣으면 여기서 바로 누를 수 있습니다.") }
            }
            .font(.dsBody).foregroundStyle(.secondary)
        }
        .padding(.top, Space.s)
    }

    private func chipRow(_ title: String, _ words: [String], symbol: String) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Label(title, systemImage: symbol).font(.dsBodyStrong).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.s) {
                    ForEach(words, id: \.self) { w in
                        SectionChip(label: w, symbol: symbol, color: .accentColor, on: false) { q = w }
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }
}

private struct Stagger: ViewModifier {
    let index: Int
    @State private var on = false
    func body(content: Content) -> some View {
        content.opacity(on ? 1 : 0).offset(y: on ? 0 : 14)
            .onAppear { withMotion(Motion.settle.delay(Motion.stagger(index))) { on = true } }
    }
}

// MARK: - 창
@MainActor
enum MagazineController {
    private static var window: NSWindow?
    static var pendingPage: MagazineView.Page?
    static var pendingSearch: String?   // 검색 화면을 이 낱말로 열기(지켜볼 낱말 정리 물방울)

    static func search(_ word: String) {
        pendingSearch = word
        NotificationCenter.default.post(name: .magazineSearch, object: word)
        open(page: .search)
    }

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
        WindowMotion.present(w)
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
            VStack(alignment: .leading, spacing: Space.l) {
                HStack(alignment: .firstTextBaseline) {
                    Text("스크랩북").font(.dsTitle)
                    Text("모두 \(book.scraps.count)개").font(.dsHeadline).foregroundStyle(.secondary) // 왼쪽 목록 '스크랩북 N' 과 같은 수(폴더별은 아래 칩)
                    Spacer()
                    Button { book.copyMarkdown(collection: folder); copied = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                    } label: { Label(copied ? "복사됨" : "Markdown 복사", systemImage: copied ? "checkmark" : "doc.on.doc") }
                        .disabled(list.isEmpty)
                    Button { book.saveMarkdown(collection: folder) } label: { Label("파일로 저장", systemImage: "square.and.arrow.down") }
                        .disabled(list.isEmpty)
                }
                .padding(.top, Space.xl)
                Text("읽기 창에서 문단에 마우스를 올려 ✂︎ 를 누르거나, 도구막대의 스크랩으로 기사를 모아 두세요. 폴더째 Markdown 으로 내보낼 수 있습니다.")
                    .font(.dsBody).foregroundStyle(.secondary)
                WeeklyQuotes()

                // 폴더 칩
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.s) {
                        ForEach(book.collections, id: \.self) { c in
                            let n = book.scraps.filter { $0.collection == c }.count
                            Button { withMotion(Motion.snap) { folder = c } } label: {
                                Label("\(c) \(n)", systemImage: c == folder ? "folder.fill" : "folder")
                                    .font(.app(12.5, c == folder ? .semibold : .regular))
                                    .padding(.horizontal, Space.m).padding(.vertical, Space.s)
                                    .background(c == folder ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05), in: Capsule())
                                    .foregroundStyle(c == folder ? Color.accentColor : Color.primary)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("이름 바꾸기") { folder = c; newName = c; renaming = true }
                            }
                        }
                        Button { creating = true } label: { Label("새 폴더", systemImage: "plus").font(.dsCallout) }
                            .buttonStyle(.borderless)
                    }
                }

                if groups.isEmpty {
                    VStack(alignment: .leading, spacing: Space.s) {
                        Image(systemName: "scissors").font(.app(30, .light)).foregroundStyle(.tertiary)
                        Text("이 폴더는 비어 있습니다").font(.dsSubheading)
                    }
                    .padding(.vertical, Space.xxxl)
                }

                ForEach(Array(groups.enumerated()), id: \.element.item.key) { i, g in
                    ScrapGroupCard(item: g.item, scraps: g.scraps)
                        .modifier(StaggerIn(index: i))
                }
            }
            .padding(.horizontal, Space.page).padding(.bottom, Space.xxxl)
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
        VStack(alignment: .leading, spacing: Space.m) {
            Button {
                AppModel.shared.markOpened(item)
                ReaderController.open(item, from: frame)
            } label: {
                HStack(alignment: .top, spacing: Space.m) {
                    if item.image != nil && !ImageKey.isJunk(item.image) {
                        RemoteImage(url: item.image, category: item.category, accent: item.accent)
                            .frame(width: 84, height: 56).clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(item.displayTitle).font(.dsSubheading).multilineTextAlignment(.leading)
                        Text("\(item.sourceName) · \(RelativeTime.string(item.date))").font(.dsCallout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(ScreenFrame(frame: $frame))

            ForEach(scraps) { s in ScrapRow(scrap: s) }
        }
        .padding(Space.l)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(.primary.opacity(0.07), lineWidth: 0.5))
    }
}

private struct ScrapRow: View {
    let scrap: Scrap
    @State private var memo = ""
    @State private var hover = false
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let q = scrap.quote {
                VStack(alignment: .leading, spacing: Space.s) {
                    Text(q).font(.app(14.5)).lineSpacing(5).textSelection(.enabled)
                    if let o = scrap.quoteOriginal, o != q {
                        Text(o).font(.dsCallout).foregroundStyle(.secondary).lineSpacing(3).textSelection(.enabled)
                    }
                }
                .padding(.leading, Space.l)
                .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(Color.yellow.opacity(0.7)).frame(width: 3) }
            } else {
                Label("기사 전체를 스크랩", systemImage: "doc.text").font(.dsCallout).foregroundStyle(.secondary)
            }
            HStack(spacing: Space.s) {
                Image(systemName: "pencil").font(.dsCaption).foregroundStyle(.tertiary)
                TextField("메모 남기기", text: $memo, axis: .vertical)
                    .textFieldStyle(.plain).font(.dsBody)
                    .focused($editing)
                    .onSubmit { saveMemo() }
                    .onChange(of: editing) { _, now in if !now { saveMemo() } }
                    .onAppear { memo = scrap.memo }
                    .onChange(of: scrap.memo) { _, v in if !editing { memo = v } }
                    // 메모 줄 어디를 눌러도 쓰기 시작(예전엔 글자 위만 눌려 줄의 빈 곳을 누르면 아무 일 없었다 — 클릭 시험)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { editing = true }
                Menu {
                    ForEach(Scrapbook.shared.collections.filter { $0 != scrap.collection }, id: \.self) { c in
                        Button("‘\(c)’로 옮기기") { var n = scrap; n.collection = c; n.memo = memo; Scrapbook.shared.update(n) }
                    }
                    Divider()
                    Button("스크랩 지우기", role: .destructive) { withMotion(Motion.snap) { Scrapbook.shared.remove(scrap) } }
                } label: { Image(systemName: "ellipsis.circle").foregroundStyle(.secondary) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .opacity(hover ? 1 : 0.4)
            }
        }
        .padding(.vertical, Space.xs)
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
            .onAppear { withMotion(Motion.settle.delay(Motion.stagger(index))) { on = true } }
    }
}


extension Notification.Name {
    static let magazineGo = Notification.Name("dropcap.magazineGo")
    static let magazineSearch = Notification.Name("dropcap.magazineSearch") // 열린 검색 화면의 낱말 바꾸기
}

// 마지막 줄에 카드 한 장만 남지 않게 칸 수를 고른다(4장이면 2×2, 7장이면 4+3 …). 폭에 들어가는 칸 수가 기준
struct BalancedGrid<Content: View>: View {
    let count: Int
    var minWidth: CGFloat = 230
    var spacing: CGFloat = 18
    @ViewBuilder let content: (Int) -> Content
    @State private var width: CGFloat = 900

    static func columns(fit: Int, count: Int) -> Int {
        let fit = max(1, fit)
        guard count > fit, count % fit == 1 else { return min(fit, max(count, 1)) }
        if fit + 1 <= 4, count % (fit + 1) != 1, count >= fit + 1 { return fit + 1 } // 한 칸 더 넣어도 좁지 않으면
        if fit > 2, count % (fit - 1) != 1 { return fit - 1 }
        return fit
    }

    var body: some View {
        content(Self.columns(fit: Int((width + spacing) / (minWidth + spacing)), count: count))
            .background(GeometryReader { g in Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w } })
    }
}
