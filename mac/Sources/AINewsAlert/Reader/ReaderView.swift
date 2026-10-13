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
    private var token: UUID?

    init(item: NewsItem) {
        self.item = item
        title = item.displayTitle
        originalTitle = item.title
    }

    func load() async {
        let svc = ArticleService.shared
        if let c = svc.cached(item.link) { apply(c); return }
        token = svc.observe(item.link) { [weak self] a in self?.apply(a) }
        let a = await svc.prepare(item)
        apply(a)
        if let token { svc.stopObserving(item.link, token) }
    }

    private func apply(_ a: PreparedArticle) {
        title = a.title
        originalTitle = a.originalTitle
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

    var translatedPageURL: URL? {
        guard let u = URL(string: item.link), let host = u.host else { return nil }
        let h = host.replacingOccurrences(of: "-", with: "--").replacingOccurrences(of: ".", with: "-")
        let q = (u.query.map { $0 + "&" } ?? "") + "_x_tr_sl=auto&_x_tr_tl=ko&_x_tr_hl=ko"
        return URL(string: "https://\(h).translate.goog\(u.path)?\(q)")
    }
}

struct ReaderView: View {
    @ObservedObject var model: ReaderModel
    @ObservedObject private var app = AppModel.shared
    @Environment(\.openURL) private var openURL
    @AppStorage("readerFontSize") private var fs: Double = 17
    @StateObject private var speaker = Speaker()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
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
            .frame(maxWidth: 660, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.top, 20)
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity)
        }
        .textSelection(.enabled)
        .background(Color(nsColor: .textBackgroundColor))
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
                ControlGroup {
                    Button { fs = max(13, fs - 1) } label: { Label("글자 작게", systemImage: "textformat.size.smaller") }
                        .keyboardShortcut("-", modifiers: .command)
                    Button { fs = min(26, fs + 1) } label: { Label("글자 크게", systemImage: "textformat.size.larger") }
                        .keyboardShortcut("=", modifiers: .command)
                }
                .help("글자 크기 (⌘- / ⌘=)")
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
                Button { app.toggleSaved(model.item) } label: {
                    Label(app.isSaved(model.item) ? "저장 취소" : "나중에 읽기", systemImage: app.isSaved(model.item) ? "bookmark.fill" : "bookmark")
                }
                .help(app.isSaved(model.item) ? "저장 취소" : "나중에 읽기로 저장")
                Button {
                    if let u = URL(string: model.item.link) { openURL(u) }
                } label: { Label("브라우저에서 열기", systemImage: "safari") }
                .help("원문을 브라우저에서 열기")
                ShareLink(item: URL(string: model.item.link) ?? URL(string: "https://example.com")!)
            }
        }
        .task { await model.load() }
        .onDisappear { speaker.stop() }
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
                            Text(p).font(.app(fs - 1)).lineSpacing(4)
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
            Text(model.showOriginal ? model.originalTitle : model.title)
                .font(.app(30, .bold))
                .tracking(-0.4)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if !model.showOriginal, model.originalTitle != model.title {
                Text(model.originalTitle).font(.app(14)).foregroundStyle(.secondary)
            }
            if model.translated, !model.engine.isEmpty {
                Label(model.engine, systemImage: "character.bubble")
                    .font(.app(11)).foregroundStyle(.tertiary)
            }
        }
    }

    private func articleBody(_ blocks: [Block]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, b in
                let text = (model.showOriginal ? b.original : nil) ?? b.text ?? ""
                let prevIsLi = i > 0 && blocks[i - 1].type == .li
                switch b.type {
                case .h:
                    Text(text).font(.app(fs + 4, .bold)).tracking(-0.2)
                        .padding(.top, 26).padding(.bottom, 8)
                case .p:
                    Text(text).font(.app(fs)).lineSpacing(fs * 0.47).padding(.bottom, fs + 1)
                case .li:
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle().fill(model.item.accent.opacity(0.8)).frame(width: 5, height: 5).offset(y: -3)
                        Text(text).font(.app(fs)).lineSpacing(fs * 0.41)
                    }
                    .padding(.top, prevIsLi ? 0 : 2).padding(.bottom, 8).padding(.leading, 4)
                case .quote:
                    Text(text).font(.app(fs)).italic().lineSpacing(fs * 0.41).foregroundStyle(.secondary)
                        .padding(.leading, 16)
                        .overlay(alignment: .leading) { Capsule().fill(model.item.accent.opacity(0.6)).frame(width: 3) }
                        .padding(.vertical, 6).padding(.bottom, 14)
                case .pre:
                    ScrollView(.horizontal) {
                        Text(text).font(.system(size: 13, design: .monospaced)).padding(14)
                    }
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.bottom, 18)
                case .img:
                    if let s = b.src, let u = URL(string: s) {
                        AsyncImage(url: u) { phase in
                            if let img = phase.image {
                                img.resizable().aspectRatio(contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .padding(.vertical, 6).padding(.bottom, 12)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                case .cap:
                    Text(text).font(.app(13)).foregroundStyle(.secondary).padding(.top, -8).padding(.bottom, 18)
                }
            }
        }
    }

    private var failed: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !model.summary.isEmpty {
                Text(model.summary).font(.app(17)).lineSpacing(8)
            }
            Text("이 기사는 본문을 추리지 못했습니다(유료 기사·차단 등).")
                .font(.app(13)).foregroundStyle(.secondary)
            HStack {
                if let u = model.translatedPageURL {
                    Button("번역된 웹페이지로 보기") { openURL(u) }.buttonStyle(.borderedProminent)
                }
                Button("원문 열기") { if let u = URL(string: model.item.link) { openURL(u) } }
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
    static func open(_ item: NewsItem, from: CGRect = .zero) {
        // 영상·팟캐스트는 원래 앱(브라우저·YouTube·팟캐스트)으로
        if item.itemKind.opensExternally {
            if let u = URL(string: item.link), URLSafety.isPublicHTTP(u) { NSWorkspace.shared.open(u) }
            return
        }
        let model = ReaderModel(item: item)
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
        // 창을 닫으면 관찰도 끊어 창·화면·기사가 메모리에서 풀리게 한다
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak w] _ in
            MainActor.assumeIsolated {
                windows.removeAll { $0 === w || $0 == nil }
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
