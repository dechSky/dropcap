import AppKit
import SwiftUI

@MainActor
final class ReaderModel: ObservableObject {
    enum Phase { case loading, translating, done, failed }
    let item: NewsItem
    @Published var phase: Phase = .loading
    @Published var title: String
    @Published var originalTitle: String
    @Published var blocks: [Block] = []
    @Published var translated = false
    @Published var showOriginal = false
    @Published var summary = ""          // 본문을 못 추렸을 때
    @Published var keyPoints: [String]?  // 3줄 요약
    @Published var summarizing = false
    @Published var engine = ""
    @Published var cover: String?        // 표지 사진(피드 → 매거진 기록 → 기사 머리 대표 사진)
    private var token: UUID?
    var sequence: [NewsItem] = []        // 이 기사를 연 목록(J/K 로 다음·이전)

    init(item: NewsItem, sequence: [NewsItem] = []) {
        self.item = item
        self.sequence = sequence
        title = item.displayTitle
        originalTitle = item.title
    }

    func load() async {
        Task { await findCover() }
        let svc = ArticleService.shared
        if let c = svc.cached(item.link) { apply(c); if !c.summarizing { return } }
        token = svc.observe(item.link) { [weak self] a in self?.apply(a) }
        let a = await svc.prepare(item)
        apply(a)
        if let token { svc.stopObserving(item.link, token) }
    }

    private func apply(_ a: PreparedArticle) {
        title = ArticleService.stripSiteName(a.title, source: item.sourceName, feedTitle: item.title) // 예전에 저장한 기사에도 적용
        originalTitle = ArticleService.stripSiteName(a.originalTitle, source: item.sourceName, feedTitle: item.title)
        translated = a.translated
        engine = a.engine
        keyPoints = a.summary
        summarizing = a.summarizing
        summary = a.fallback
        if !a.blocks.isEmpty { blocks = a.blocks }
        let next: Phase
        switch a.stage {
        case .extracting: next = .loading
        case .original, .translating: next = .translating
        case .done: next = .done
        case .failed: next = .failed
        }
        if next != phase { withAnimation(.easeOut(duration: 0.3)) { phase = next } }
    }

    // 상단바 목록의 기사 정보에는 대표 사진이 비어 있을 수 있다(매거진만 기사 머리에서 찾아 둠).
    // 그때 본문의 첫 그림(기자 프로필 등)을 표지로 쓰던 문제가 있어, 대표 사진을 먼저 찾는다.
    private func findCover() async {
        if let i = item.image, !ImageKey.isJunk(i) { cover = i; return }
        if let s = Magazine.shared.storedImage(item.key), !ImageKey.isJunk(s) { cover = s; return }
        guard !item.link.isEmpty, let og = await FeedService.shared.ogImage(item.link), !ImageKey.isJunk(og) else { return }
        withAnimation(.easeOut(duration: 0.3)) { cover = og }
    }

    var translatedPageURL: URL? {
        guard let u = URL(string: item.link), let host = u.host else { return nil }
        let h = host.replacingOccurrences(of: "-", with: "--").replacingOccurrences(of: ".", with: "-")
        let q = (u.query(percentEncoded: true).map { $0 + "&" } ?? "") + "_x_tr_sl=auto&_x_tr_tl=ko&_x_tr_hl=ko"
        // path 는 퍼센트 인코딩을 풀어 돌려주므로(공백·한글) 인코딩된 그대로 써야 주소가 만들어진다
        return URL(string: "https://\(h).translate.goog\(u.path(percentEncoded: true))?\(q)")
    }
}

struct ReaderView: View {
    @ObservedObject var model: ReaderModel
    @ObservedObject private var app = AppModel.shared
    @Environment(\.openURL) private var openURL
    @AppStorage(ReaderLook.fontSizeKey) private var fs: Double = 17
    @AppStorage(ReaderLook.spacingKey) private var spacingRaw = ReaderLook.Spacing.normal.rawValue
    @AppStorage(ReaderLook.widthKey) private var widthRaw = ReaderLook.Width.normal.rawValue
    @AppStorage(ReaderLook.themeKey) private var themeRaw = ReaderLook.Theme.auto.rawValue
    @AppStorage(ReaderLook.fontKey) private var faceRaw = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorSchemeFallback
    @State private var findOpen = ProcessInfo.processInfo.environment["DROPCAP_TEST_FIND"] != nil // 시험용: 찾기 막대를 연 채로
    @State private var findQuery = ProcessInfo.processInfo.environment["DROPCAP_TEST_FIND"] ?? ""
    @State private var findIndex = 0
    @StateObject private var speaker = Speaker()
    @ObservedObject private var scrapbook = Scrapbook.shared
    @State private var scrapFlash = false
    @State private var linkCopied = false
    @State private var newFolder = false
    @State private var folderName = ""
    @State private var scrapToast: String?

    private var theme: ReaderLook.Theme { ReaderLook.Theme(rawValue: themeRaw) ?? .auto }
    private var face: ReaderLook.Face { ReaderLook.Face.resolve(faceRaw) }
    private var lineFactor: CGFloat { (ReaderLook.Spacing(rawValue: spacingRaw) ?? .normal).factor }
    private func bf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { ReaderLook.font(face, size, weight) }

    var body: some View {
        ScrollViewReader { proxy in
            page
                .onChange(of: findIndex) { _, _ in scrollToMatch(proxy) }
                .onChange(of: findQuery) { _, _ in findIndex = 0; scrollToMatch(proxy) }
        }
        .background(WindowAppearance(scheme: theme.scheme))
    }

    // MARK: 찾기
    // 지금 화면에 보이는 글 조각(제목=-1, 본문 블록 번호) — 번역/원문 중 보이는 쪽
    private var visiblePieces: [(Int, String)] {
        guard model.phase == .translating || model.phase == .done else { return [(-1, shownTitle)] }
        let hidden = hiddenBlocks(model.blocks)
        let body = model.blocks.enumerated().compactMap { i, b -> (Int, String)? in
            guard b.type != .img, !hidden.contains(i) else { return nil }
            let t = (model.showOriginal ? b.original : nil) ?? b.text ?? ""
            return t.isEmpty ? nil : (i, t)
        }
        return [(-1, shownTitle)] + body
    }
    private var shownTitle: String { model.showOriginal ? model.originalTitle : model.title }
    private var findMatches: [ReaderFind.Match] { findOpen ? ReaderFind.matches(visiblePieces, findQuery) : [] }

    private func currentNth(_ id: Int) -> Int? {
        let m = findMatches
        guard findIndex < m.count, m[findIndex].block == id else { return nil }
        return m[findIndex].nth
    }

    private func scrollToMatch(_ proxy: ScrollViewProxy) {
        let m = findMatches
        guard findIndex < m.count else { return }
        let target = m[findIndex].block
        if reduceMotion { proxy.scrollTo(target, anchor: .center) } else { withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(target, anchor: .center) } }
    }

    private func findStep(_ forward: Bool) {
        if !findOpen { findOpen = true; return }
        findIndex = ReaderFind.step(findIndex, count: findMatches.count, forward: forward)
    }

    // 찾는 중이면 일치한 곳을 칠한 글
    private func styled(_ text: String, _ id: Int) -> Text {
        guard findOpen, !findQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return Text(text) }
        return Text(ReaderFind.highlighted(text, findQuery, current: currentNth(id)))
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                cover
                header
                switch model.phase {
                case .loading:
                    Skeleton(label: "기사를 불러오는 중")
                        .padding(.top, 28)
                case .translating, .done:
                    keyPointsBox.padding(.top, 22)
                    if model.phase == .translating {
                        Label("한국어로 바꾸는 중 — 위에서부터 차례로 바뀝니다", systemImage: "character.bubble")
                            .font(.app(12)).foregroundStyle(.secondary)
                            .symbolEffect(.pulse, options: .repeating)
                            .padding(.top, 18)
                    }
                    articleBody(model.blocks)
                        .padding(.top, 24)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                case .failed:
                    failed.padding(.top, 24)
                }
            }
            .frame(maxWidth: (ReaderLook.Width(rawValue: widthRaw) ?? .normal).points, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.top, 20)
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity)
            .foregroundStyle(theme.text.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
        }
        .textSelection(.enabled)
        .background(theme.background)
        .environment(\.colorScheme, theme.scheme ?? colorSchemeFallback)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: themeRaw)
        .overlay(alignment: .top) {
            if findOpen {
                ReaderFindBar(query: $findQuery, count: findMatches.count, index: min(findIndex, max(0, findMatches.count - 1)),
                              next: { findStep(true) }, prev: { findStep(false) },
                              close: { findOpen = false; findQuery = "" })
                    .padding(.top, 10)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if model.translated {
                    Picker("", selection: $model.showOriginal) {
                        Text("번역").tag(false)
                        Text("원문").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .help("번역과 원문 바꿔 보기")
                }
                ReaderLookButton()
                Button {
                    let korean = model.translated ? !model.showOriginal : !Translator.looksForeign(model.title)
                    let paras = model.blocks.filter { $0.type != .pre && $0.type != .img }
                        .compactMap { (model.showOriginal ? $0.original : nil) ?? $0.text }
                    speaker.toggle(title: model.showOriginal ? model.originalTitle : model.title, paragraphs: paras, korean: korean)
                } label: {
                    Label(speaker.speaking ? "읽기 멈춤" : "소리 내어 읽기", systemImage: speaker.speaking ? "stop.circle" : "speaker.wave.2")
                }
                .disabled(model.phase == .loading || model.phase == .failed)
                .help(speaker.speaking ? "읽기 멈춤" : "소리 내어 읽기")
                Menu {
                    ForEach(scrapbook.collections, id: \.self) { c in
                        Button(c) { scrapbook.add(model.item, to: c); scrapFlash.toggle() }
                    }
                    Divider()
                    Button("선택한 부분 스크랩 (⌘⇧S)") { scrapSelection() }
                    Button("새 폴더에 스크랩…") { newFolder = true }
                } label: {
                    Label("스크랩", systemImage: scrapbook.isScrapped(model.item) ? "scissors.circle.fill" : "scissors")
                } primaryAction: {
                    scrapbook.add(model.item); scrapFlash.toggle()
                }
                .help("기사 스크랩 (누르면 마지막 폴더에, 화살표로 폴더 고르기)")
                .symbolEffect(.bounce, value: scrapFlash)
                Button { app.toggleSaved(model.item) } label: {
                    Label(app.isSaved(model.item) ? "저장 취소" : "나중에 읽기", systemImage: app.isSaved(model.item) ? "bookmark.fill" : "bookmark")
                }
                .help(app.isSaved(model.item) ? "저장 취소" : "나중에 읽기로 저장")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.item.link, forType: .string)
                    withAnimation(.spring(response: 0.3)) { linkCopied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation(.easeOut(duration: 0.25)) { linkCopied = false } }
                } label: { Label("기사 주소 복사", systemImage: linkCopied ? "checkmark" : "link") }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .help("기사 주소 복사 (⌘⇧C)")
                Button {
                    ExternalLink.open(model.item.link)
                } label: { Label("브라우저에서 열기", systemImage: "safari") }
                .help("원문을 브라우저에서 열기")
                if let u = URL(string: model.item.link), URLSafety.isPublicHTTP(u) { ShareLink(item: u) } // 주소가 이상하면 공유 단추를 숨김(A-37)
            }
        }
        .task { await model.load() }
        .onDisappear { speaker.stop() }
        .background {
            Button("") { scrapSelection() }.keyboardShortcut("s", modifiers: [.command, .shift]).opacity(0).allowsHitTesting(false)
            // 모양 팝오버가 닫혀 있어도 글자 크기 단축키는 그대로
            Button("") { fs = ReaderLook.clampSize(fs - 1) }.keyboardShortcut("-", modifiers: .command).opacity(0).allowsHitTesting(false)
            Button("") { fs = ReaderLook.clampSize(fs + 1) }.keyboardShortcut("=", modifiers: .command).opacity(0).allowsHitTesting(false)
            Button("") { withAnimation(reduceMotion ? nil : .spring(response: 0.3)) { findOpen = true } }
                .keyboardShortcut("f", modifiers: .command).opacity(0).allowsHitTesting(false)
            if !findOpen { // 찾기 막대가 닫혀 있을 때도 ⌘G 로 다시 열기
                Button("") { findStep(true) }.keyboardShortcut("g", modifiers: .command).opacity(0).allowsHitTesting(false)
                // 같은 목록의 다음·이전 기사(J/K), Esc 로 닫기 — 찾기 칸에 글을 칠 때는 쓰지 않음
                Button("") { ReaderController.step(model, by: 1) }.keyboardShortcut("j", modifiers: []).opacity(0).allowsHitTesting(false)
                Button("") { ReaderController.step(model, by: -1) }.keyboardShortcut("k", modifiers: []).opacity(0).allowsHitTesting(false)
                Button("") { ReaderController.close(model) }.keyboardShortcut(.cancelAction).opacity(0).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if linkCopied {
                Label("기사 주소를 복사했어요", systemImage: "link")
                    .font(.app(12.5, .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if let msg = scrapToast {
                Label(msg, systemImage: "scissors")
                    .font(.app(12.5, .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .alert("새 스크랩 폴더", isPresented: $newFolder) {
            TextField("폴더 이름", text: $folderName)
            Button("스크랩") {
                let n = folderName.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty {
                    scrapbook.createCollection(n)
                    scrapbook.add(model.item, to: n)
                }
                folderName = ""
            }
            Button("취소", role: .cancel) { folderName = "" }
        }
    }

    // 끌어서 고른 글만 스크랩: 고른 글을 잠시 클립보드로 복사해 읽고, 원래 클립보드를 되돌린다
    private func scrapSelection() {
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        } ?? []
        let before = pb.changeCount
        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        let changed = pb.changeCount != before
        let picked = changed ? pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        if changed { // 복사가 일어났을 때만 원래 클립보드로 되돌린다
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
        guard let text = picked, !text.isEmpty else {
            flash("먼저 스크랩할 글을 끌어서 고르세요")
            return
        }
        // 고른 글이 들어 있는 문단의 원문도 함께(번역문을 골랐을 때)
        let original = model.blocks.first { ($0.text ?? "").contains(text) }?.original
        Scrapbook.shared.add(model.item, quote: text, original: original)
        flash("고른 부분을 ‘\(UserDefaults.standard.string(forKey: "lastScrapCollection") ?? Scrapbook.defaultCollection)’에 스크랩했어요")
    }

    private func flash(_ msg: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { scrapToast = msg }
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            withAnimation(.easeOut(duration: 0.25)) { scrapToast = nil }
        }
    }

    // 읽는 시간: 한국어 분당 약 500자, 영어 분당 약 230낱말
    private var readingMinutes: Int? {
        let texts = model.blocks.compactMap { (model.showOriginal ? $0.original : nil) ?? $0.text }
        guard !texts.isEmpty else { return nil }
        let joined = texts.joined(separator: " ")
        let minutes = Translator.looksForeign(joined)
            ? Double(joined.split(whereSeparator: \.isWhitespace).count) / 230
            : Double(joined.filter { !$0.isWhitespace }.count) / 500
        return max(1, Int(minutes.rounded()))
    }

    // 3줄 요약(이 Mac 안의 Apple Intelligence 로 만듦)
    @ViewBuilder private var keyPointsBox: some View {
        if model.keyPoints != nil || model.summarizing {
            VStack(alignment: .leading, spacing: 9) {
                Label("3줄 요약", systemImage: "sparkles")
                    .font(.app(12, .semibold))
                    .foregroundStyle(model.item.accent)
                if let pts = model.keyPoints {
                    ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•").foregroundStyle(model.item.accent)
                            Text(p).font(bf(fs - 1)).lineSpacing(4 * lineFactor)
                        }
                    }
                } else {
                    Text("요약하는 중…").font(.app(13)).foregroundStyle(.secondary)
                        .symbolEffect(.pulse, options: .repeating)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(model.item.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(model.item.accent.opacity(0.15), lineWidth: 0.5))
            .transition(.opacity)
        }
    }

    // 표지: 피드의 대표 사진, 없으면 본문의 첫 사진(본문에서는 그 사진을 다시 싣지 않음)
    private var coverURL: String? { model.cover ?? model.blocks.first { $0.type == .img && !ImageKey.isJunk($0.src) }?.src }

    @ViewBuilder private var cover: some View {
        Group {
            if let url = coverURL {
                CoverImage(url: url, accent: model.item.accent, category: model.item.category, seed: model.item.key, source: model.item.sourceName)
            }
        }
        .padding(.bottom, 22)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Monogram(letter: model.item.initial, color: model.item.accent, size: 22)
                Text(model.item.sourceName).font(.app(13, .semibold))
                Text(Resources.tierLabel(model.item.tier))
                    .font(.app(11, .semibold))
                    .foregroundStyle(model.item.accent)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(model.item.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                if let d = model.item.date {
                    Text(d.formatted(.dateTime.locale(Locale(identifier: "ko_KR")).month().day().hour().minute()))
                        .font(.app(12)).foregroundStyle(.secondary)
                }
                if let m = readingMinutes {
                    Label("약 \(m)분", systemImage: "clock").font(.app(12)).foregroundStyle(.secondary)
                        .help("읽는 시간(한국어 분당 약 500자 기준)")
                }
            }
            styled(shownTitle, -1)
                .font(bf(30, .bold))
                .id(-1)
                .tracking(-0.4)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if !model.showOriginal, model.originalTitle != model.title {
                Text(model.originalTitle).font(.app(14)).foregroundStyle(.secondary)
            }
            if let by = BodyCleanup.analyze(model.blocks).byline {
                Text(by).font(.app(12.5, .medium)).foregroundStyle(.secondary)
            }
            if model.translated, !model.engine.isEmpty {
                Label(model.engine, systemImage: "character.bubble")
                    .font(.app(11)).foregroundStyle(.tertiary)
            }
        }
    }

    private func articleBody(_ blocks: [Block]) -> some View {
        // 표지와 같은 사진(주소가 같거나 크기 표기만 다른 것)은 본문에서 처음 한 번 뺀다
        let hidden = hiddenBlocks(blocks)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, b in
                let text = (model.showOriginal ? b.original : nil) ?? b.text ?? ""
                let prevIsLi = i > 0 && blocks[i - 1].type == .li
                if !hidden.contains(i) {
                blockView(b, text: text, prevIsLi: prevIsLi, id: i)
                    .id(i)
                    .modifier(ScrapHover(item: model.item, text: text,
                                         original: model.showOriginal ? nil : b.original,
                                         enabled: [.p, .li, .quote, .h].contains(b.type) && !text.isEmpty))
                }
            }
        }
    }

    // 본문에서 빼는 블록: 표지와 같은 사진(주소가 같거나 크기 표기만 다른 것) 처음 한 번, 기자 줄·짝 잃은 설명 문구, 잡그림
    private func hiddenBlocks(_ blocks: [Block]) -> Set<Int> {
        var out = BodyCleanup.analyze(blocks).skip
        if let c = coverURL, let dup = blocks.firstIndex(where: { $0.type == .img && ImageKey.same($0.src, c) }) { out.insert(dup) }
        for (i, b) in blocks.enumerated() where b.type == .img && ImageKey.isJunk(b.src) { out.insert(i) } // 기자 프로필·로고 같은 잡그림은 싣지 않음
        return out
    }

    @ViewBuilder private func blockView(_ b: Block, text: String, prevIsLi: Bool, id: Int) -> some View {
        switch b.type {
        case .h:
            styled(text, id).font(bf(fs + 4, .bold)).tracking(-0.2)
                .padding(.top, 26).padding(.bottom, 8)
        case .p:
            styled(text, id).font(bf(fs)).lineSpacing(fs * 0.47 * lineFactor).padding(.bottom, fs + 1)
        case .li:
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle().fill(model.item.accent.opacity(0.8)).frame(width: 5, height: 5).offset(y: -3)
                styled(text, id).font(bf(fs)).lineSpacing(fs * 0.41 * lineFactor)
            }
            .padding(.top, prevIsLi ? 0 : 2).padding(.bottom, 8).padding(.leading, 4)
        case .quote:
            styled(text, id).font(bf(fs)).italic().lineSpacing(fs * 0.41 * lineFactor).foregroundStyle(.secondary)
                .padding(.leading, 16)
                .overlay(alignment: .leading) { Capsule().fill(model.item.accent.opacity(0.6)).frame(width: 3) }
                .padding(.vertical, 6).padding(.bottom, 14)
        case .pre:
            ScrollView(.horizontal) {
                styled(text, id).font(.system(size: 13, design: .monospaced)).padding(14)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.bottom, 18)
        case .img:
            // 기사 속 사진 주소도 믿지 않는다: 안전 검사를 거치는 로더로
            if let src = b.src {
                ArticleImage(url: src).padding(.vertical, 6).padding(.bottom, 12)
            }
        case .cap:
            styled(text, id).font(bf(13)).foregroundStyle(.secondary).padding(.top, -8).padding(.bottom, 18)
        }
    }

    private var failed: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !model.summary.isEmpty {
                Text(model.summary).font(bf(17)).lineSpacing(8 * lineFactor)
            }
            Text("이 기사는 본문을 추리지 못했습니다(유료 기사·차단 등).")
                .font(.app(13)).foregroundStyle(.secondary)
            HStack {
                if let u = model.translatedPageURL {
                    Button("번역된 웹페이지로 보기") { ExternalLink.open(u.absoluteString) }.buttonStyle(.borderedProminent)
                }
                Button("원문 열기") { ExternalLink.open(model.item.link) }
            }
            .controlSize(.large)
        }
    }
}

// 불러오는 동안 글 모양 자리표시 + 은은하게 흐르는 빛
struct Skeleton: View {
    let label: String
    @State private var phase: CGFloat = -1

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(label, systemImage: "ellipsis").font(.app(12)).foregroundStyle(.secondary)
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .padding(.bottom, 8)
            ForEach(0..<3, id: \.self) { para in
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(0..<4, id: \.self) { line in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.quaternary)
                            .frame(height: 13)
                            .frame(maxWidth: line == 3 ? 260 + CGFloat(para * 60) : .infinity, alignment: .leading)
                    }
                }
                .padding(.bottom, 14)
            }
        }
        .mask(alignment: .leading) {
            GeometryReader { g in
                LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0), .init(color: .black, location: 0.5), .init(color: .black.opacity(0.55), location: 1)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: g.size.width * 2)
                    .offset(x: g.size.width * phase)
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 0 }
        }
    }
}

@MainActor
enum ReaderController {
    private static var windows: [NSWindow] = []

    // from: 누른 카드의 화면 위치. 주면 읽기 창이 그 자리에서 커져 나온다.
    private static var hosts: [ObjectIdentifier: NSHostingController<ReaderView>] = [:] // 창 → 화면(J/K 로 내용만 바꿔 끼우려고)

    // 같은 창에서 목록의 다음·이전 기사로(영상·팟캐스트는 건너뜀)
    static func step(_ model: ReaderModel, by d: Int) {
        let list = model.sequence.filter { !$0.itemKind.opensExternally }
        guard let i = list.firstIndex(where: { $0.key == model.item.key }) else { NSSound.beep(); return }
        let j = i + d
        guard list.indices.contains(j), let host = hosts.values.first(where: { $0.rootView.model === model }),
              let w = host.view.window else { NSSound.beep(); return }
        let next = list[j]
        AppModel.shared.markOpened(next)
        host.rootView = ReaderView(model: ReaderModel(item: next, sequence: model.sequence))
        w.title = next.sourceName
    }

    static func close(_ model: ReaderModel) {
        hosts.values.first { $0.rootView.model === model }?.view.window?.performClose(nil)
    }

    static func open(_ item: NewsItem, from: CGRect = .zero, sequence: [NewsItem] = []) {
        // 영상·팟캐스트는 원래 앱(브라우저·YouTube·팟캐스트)으로
        if item.itemKind.opensExternally {
            ExternalLink.open(item.link)
            return
        }
        let model = ReaderModel(item: item, sequence: sequence)
        let host = NSHostingController(rootView: ReaderView(model: model))
        host.sceneBridgingOptions = [.toolbars]
        let w = NSWindow(contentViewController: host)
        w.title = item.sourceName
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.toolbarStyle = .unified
        w.setContentSize(NSSize(width: 760, height: 860))
        w.minSize = NSSize(width: 460, height: 400)
        w.isReleasedWhenClosed = false
        w.center()
        if let last = windows.last(where: \.isVisible) {
            w.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 24, y: last.frame.maxY - 24)) // 겹치지 않게 살짝 비켜서
        }
        windows.append(w)
        hosts[ObjectIdentifier(w)] = host
        // 창을 닫으면 관찰도 끊어 창·화면·기사가 메모리에서 풀리게 한다
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak w] _ in
            MainActor.assumeIsolated {
                windows.removeAll { $0 === w || $0 == nil }
                if let w { hosts.removeValue(forKey: ObjectIdentifier(w)) }
                if let token { NotificationCenter.default.removeObserver(token) }
                w?.contentViewController = nil
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        guard from.width > 10, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            w.makeKeyAndOrderFront(nil)
            return
        }
        // 카드 자리에서 시작해 제자리로 커진다
        let target = w.frame
        w.alphaValue = 0.2
        w.setFrame(from, display: false)
        w.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.38
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            w.animator().setFrame(target, display: true)
            w.animator().alphaValue = 1
        }
    }
}


// 문단에 마우스를 올리면 왼쪽 여백에 가위 단추: 누르면 그 문단을 스크랩(번역문이면 원문도 함께)
private struct ScrapHover: ViewModifier {
    let item: NewsItem
    let text: String
    let original: String?
    let enabled: Bool
    @State private var hover = false
    @State private var hoverToken = 0
    @State private var showSheet = false
    @State private var memo = ""
    private static let gutter: CGFloat = 46 // 가위 단추가 놓이는 왼쪽 여백(마우스 올림 영역에 포함)
    @ObservedObject private var book = Scrapbook.shared

    private var scrap: Scrap? { book.scraps.first { $0.item.key == item.key && $0.quote == text } }

    func body(content: Content) -> some View {
        let scrapped = scrap != nil
        content
            // 마우스를 올린 문단을 옅게 칠해 무엇이 스크랩될지 보이게
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(enabled && hover ? 0.06 : 0))
                    .padding(.horizontal, -8).padding(.vertical, -3)
            }
            .background(alignment: .leading) {
                if scrapped {
                    RoundedRectangle(cornerRadius: 3).fill(Color.yellow.opacity(0.6)).frame(width: 3).offset(x: -14)
                }
            }
            .overlay(alignment: .topLeading) {
                if enabled && (hover || showSheet) {
                    Button {
                        if !scrapped { book.add(item, quote: text, original: original) }
                        memo = scrap?.memo ?? ""
                        showSheet = true
                    } label: {
                        Image(systemName: scrapped ? "scissors.circle.fill" : "scissors")
                            .font(.app(12, .semibold))
                            .frame(width: 26, height: 26)
                            .background(.regularMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
                            .foregroundStyle(scrapped ? Color.orange : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(scrapped ? "스크랩한 문단 — 눌러서 폴더·메모 바꾸기" : "이 문단 스크랩")
                    .offset(x: -38, y: -2)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    .popover(isPresented: $showSheet, arrowEdge: .leading) { sheet.onDisappear { if let s = scrap, s.memo != memo { var n = s; n.memo = memo; book.update(n) } } }
                }
            }
            // 단추가 문단 바깥 왼쪽 여백에 있으므로, 그 여백까지 마우스 올림 영역으로 잡는다(자리 배치는 그대로)
            .padding(.leading, Self.gutter)
            .contentShape(Rectangle())
            .onHover { h in
                hoverToken += 1
                if h {
                    withAnimation(.easeOut(duration: 0.15)) { hover = true }
                } else { // 살짝 벗어났다 돌아와도 단추가 깜빡이지 않게 잠깐 기다렸다 숨김
                    let token = hoverToken
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        guard token == hoverToken else { return }
                        withAnimation(.easeOut(duration: 0.15)) { hover = false }
                    }
                }
            }
            .padding(.leading, -Self.gutter)
            .contextMenu {
                if enabled {
                    if scrapped {
                        Button("스크랩 지우기") { if let s = scrap { book.remove(s) } }
                    } else {
                        Button("이 문단 스크랩") { book.add(item, quote: text, original: original) }
                    }
                    Menu("다른 폴더에 스크랩") {
                        ForEach(book.collections, id: \.self) { c in
                            Button(c) { book.add(item, quote: text, original: original, to: c) }
                        }
                    }
                    Divider()
                    Button("이 문단 복사") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
            }
    }

    // 스크랩한 뒤: 담긴 폴더, 폴더 바꾸기, 메모, 되돌리기
    private var sheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let s = scrap {
                Label("‘\(s.collection)’에 스크랩했어요", systemImage: "checkmark.circle.fill")
                    .font(.app(13, .semibold)).foregroundStyle(.green)
                Picker("폴더", selection: Binding(get: { s.collection }, set: { c in var n = s; n.collection = c; book.update(n) })) {
                    ForEach(book.collections, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                TextField("메모 (선택)", text: $memo, axis: .vertical)
                    .textFieldStyle(.roundedBorder).font(.app(13)).lineLimit(2...4)
                    .onSubmit { save(s) }
                HStack {
                    Button("되돌리기", role: .destructive) { book.remove(s); showSheet = false }
                    Spacer()
                    Button("완료") { save(s) }.keyboardShortcut(.defaultAction)
                }
            } else {
                Text("스크랩을 지웠어요").font(.app(13)).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private func save(_ s: Scrap) {
        var n = s
        n.memo = memo
        book.update(n)
        showSheet = false
    }
}

// 기사 본문 속 사진(안전 로더, 원래 비율 유지)
private struct ArticleImage: View {
    let url: String
    @State private var image: NSImage?
    @State private var failed = false

    // 빈 뷰에는 .task 가 돌지 않으므로, 불러오는 동안에도 자리(옅은 상자)를 둔다
    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .transition(.opacity)
            } else if !failed {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5))
                    .frame(height: 180)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .frame(maxWidth: .infinity)
        .imageActions(image, url: url)
        .task(id: url) {
            let img = await ImageLoader.shared.image(url)
            withAnimation(.easeOut(duration: 0.3)) { image = img; failed = img == nil }
        }
    }
}


// 읽기 창 표지: 사진 비율을 지키되 너무 길면 잘라서 16:9 안팎으로, 불러오는 동안은 분야 색 바탕
private struct CoverImage: View {
    let url: String
    let accent: Color
    let category: NewsCategory
    var seed = ""
    var source: String? = nil
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        if failed { EmptyView() } else { content } // 대체 표지는 컨셉을 정한 뒤 넣는다
    }

    private var content: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                LinearGradient(colors: [accent.opacity(0.35), category.color.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 340)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(0.06), lineWidth: 0.5))
        .imageActions(image, url: url)
        .task(id: url) {
            let img = await ImageLoader.shared.image(url)
            withAnimation(.easeOut(duration: 0.35)) { image = img; failed = img == nil }
        }
    }
}


// 같은 사진인지: 주소의 파일 이름에서 확장자·크기 표기(썸네일·_v150·-1024x576·-scaled 등)·쿼리를 떼고 비교
enum ImageKey {
    static func key(_ url: String) -> String {
        var u = url.lowercased()
        if let q = u.firstIndex(where: { $0 == "?" || $0 == "#" }) { u = String(u[..<q]) }
        var name = u.split(separator: "/").last.map(String.init) ?? u
        if let dot = name.lastIndex(of: "."), name.distance(from: dot, to: name.endIndex) <= 5 { name = String(name[..<dot]) }
        let suffix = try! NSRegularExpression(pattern: "([-_](v?\\d{2,4}(x\\d{2,4})?|thumb(nail)?|small|medium|large|scaled|crop(ped)?|resize[d]?|\\d{2,4}w))+$")
        name = suffix.stringByReplacingMatches(in: name, range: NSRange(name.startIndex..., in: name), withTemplate: "")
        return name
    }
    // 기사 사진이 아닌 잡그림: 기자 프로필·아바타·로고·아이콘·추적용 1픽셀
    static func isJunk(_ url: String?) -> Bool {
        guard let u = url?.lowercased() else { return true }
        let name = u.split(separator: "?").first.map(String.init) ?? u
        return name.range(of: #"(default[-_]?user|avatar|profile|reporter|byline|author|gravatar|/logo|logo[-_.]|favicon|/icons?/|icon[-_.]|spacer|blank\.|1x1|pixel\.|badge|sprite|emoji|/ads?/)"#, options: .regularExpression) != nil
    }

    static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        if a == b { return true }
        let ka = key(a), kb = key(b)
        return ka.count >= 6 && ka == kb
    }
}
