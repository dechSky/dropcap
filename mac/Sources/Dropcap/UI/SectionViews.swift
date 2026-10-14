import AppKit
import SwiftUI

// MARK: - 분야 칩 줄(상단바 목록·매거진 공통)
// '전체' + 고른 분야. AI 를 고르면 그 아래에 AI 안의 하위 칩(모델·연구·정책·투자·보안)이 한 줄 더 나온다.
struct SectionChipBar: View {
    @Binding var section: String?
    @Binding var sub: NewsCategory?
    var sections: [String]
    var counts: [String: Int] = [:]
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    SectionChip(label: "전체", symbol: "square.grid.2x2", color: .accentColor, on: section == nil, compact: compact) {
                        section = nil; sub = nil
                    }
                    ForEach(sections, id: \.self) { id in
                        let s = Sections.byID(id)
                        SectionChip(label: s?.name ?? id, symbol: s?.symbol ?? "circle", color: s?.tint ?? .gray, on: section == id,
                                    count: counts[id], compact: compact) {
                            section = section == id ? nil : id
                            sub = nil
                        }
                    }
                }
                .padding(.vertical, 1)
            }
            if section == Sections.ai {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(NewsCategory.allCases.filter { $0 != .other }) { c in
                            SectionChip(label: c.label, symbol: c.symbol, color: c.color, on: sub == c, compact: true, small: true) {
                                sub = sub == c ? nil : c
                            }
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: section)
    }
}

struct SectionChip: View {
    let label: String
    let symbol: String
    let color: Color
    let on: Bool
    var count: Int? = nil
    var compact = false
    var small = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.app(small ? 9.5 : 10.5, .semibold))
                Text(label).font(.app(small ? 11 : (compact ? 11.5 : 12.5), on ? .semibold : .medium)).lineLimit(1)
                if let count, count > 0 { Text("\(count)").font(.app(10.5, .semibold)).opacity(0.7).monospacedDigit() }
            }
            .padding(.horizontal, small ? 7 : 9).padding(.vertical, small ? 3 : 4.5)
            .foregroundStyle(on ? Color.white : color)
            .background(on ? AnyShapeStyle(color.gradient) : AnyShapeStyle(color.opacity(hover ? 0.18 : 0.11)), in: Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - 카드·알림에서 바로 줄이기(G-3)
struct ReduceMenu: View {
    let item: NewsItem

    var body: some View {
        let app = AppModel.shared
        let sec = app.notifySection(item)
        let mode = app.policy(sec).mode
        Divider()
        Button("이 출처 숨기기 — \(item.sourceName)") { app.hideSource(item.sourceId) }
        if app.chosenSections.contains(sec), mode != .magazine {
            Button("\(Sections.name(sec)) 덜 받기 — \(mode == .instant ? "묶음으로" : "매거진에만")") { app.lessOf(sec) }
        }
        Menu("이 낱말 알리지 않기") {
            ForEach(AppModel.titleWords(item), id: \.self) { w in
                Button(w) { app.muteWord(w) }
            }
        }
    }
}

// MARK: - 해외·국내 나란히(D-3)
struct RegionSplit: View {
    let items: [NewsItem]
    var compact = false
    var onOpen: ((NewsItem) -> Void)? = nil

    var body: some View {
        let split = Magazine.splitByRegion(items)
        if !split.intl.isEmpty && !split.kr.isEmpty {
            if compact {
                VStack(alignment: .leading, spacing: 3) {
                    line("해외에서는", split.intl)
                    line("국내에서는", split.kr)
                }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    column("해외에서는", "globe", split.intl)
                    column("국내에서는", "house", split.kr)
                }
                .padding(.bottom, 26)
            }
        }
    }

    private func line(_ title: String, _ list: [NewsItem]) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.app(10.5, .bold)).foregroundStyle(.secondary)
            Text(Array(NSOrderedSet(array: list.map(\.sourceName))).compactMap { $0 as? String }.prefix(3).joined(separator: " · "))
                .font(.app(10.5)).foregroundStyle(.tertiary).lineLimit(1)
        }
    }

    private func column(_ title: String, _ symbol: String, _ list: [NewsItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(title) \(list.count)곳", systemImage: symbol).font(.app(12.5, .bold)).foregroundStyle(.secondary)
            ForEach(list, id: \.key) { it in
                Button { onOpen?(it) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(it.sourceName).font(.app(11, .semibold)).foregroundStyle(it.accent)
                        Text(it.displayTitle).font(.app(13)).multilineTextAlignment(.leading).lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        if it.titleKo != nil, it.titleKo != it.title {
                            Text(it.title).font(.app(11)).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - 첫 실행: 관심 분야 고르기(G-1)
struct OnboardingView: View {
    @ObservedObject private var app = AppModel.shared
    @State private var picked: Set<String>
    @State private var showMore = false
    var onDone: () -> Void = {}

    init(onDone: @escaping () -> Void = {}) {
        self.onDone = onDone
        let now = AppModel.shared.state.sectionsChosen
        _picked = State(initialValue: Set(now ?? [Sections.top]))
        _showMore = State(initialValue: (now ?? []).contains { Sections.byID($0)?.isMore == true })
    }

    private var cards: [NewsSection] { Sections.pickable.filter { !$0.isMore || showMore } }
    private var count: Int { picked.filter { $0 != Sections.top }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("D").font(.system(size: 30, weight: .black, design: .serif))
                    Text("ROPCAP").font(.system(size: 17, weight: .heavy, design: .serif)).tracking(2.4)
                }
                Text("어떤 소식을 받아 볼까요?").font(.display(28, .bold))
                Text("고른 분야의 언론사 피드가 켜지고, 매거진 지면도 그 분야로 엮입니다. 알림은 처음엔 고른 분야 중 두 개만 바로 오고, 나머지는 정한 시각에 한 방울로 모아 옵니다.")
                    .font(.app(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 30).padding(.top, 26).padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let top = Sections.byID(Sections.top) {
                        Toggle(isOn: Binding(get: { picked.contains(top.id) }, set: { if $0 { picked.insert(top.id) } else { picked.remove(top.id) } })) {
                            HStack(spacing: 10) {
                                Image(systemName: top.symbol).foregroundStyle(top.tint).font(.app(15, .semibold))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(top.name).font(.app(14, .semibold))
                                    Text("어느 분야든 여러 곳이 함께 크게 다룬 소식만 골라 알려 드려요").font(.app(12)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.switch)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(top.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 14)], spacing: 14) {
                        ForEach(cards) { s in
                            SectionCard(section: s, on: picked.contains(s.id)) {
                                if picked.contains(s.id) { picked.remove(s.id) } else { picked.insert(s.id) }
                            }
                        }
                    }
                    if !showMore, Sections.pickable.contains(where: \.isMore) {
                        Button { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { showMore = true } } label: {
                            Label("더 보기", systemImage: "chevron.down").font(.app(12.5, .semibold))
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 30).padding(.bottom, 16)
            }

            Divider()
            HStack {
                Text(count == 0 ? "분야를 하나 이상 골라 주세요" : "\(count)개 분야 · 설정 › 분야에서 언제든 바꿀 수 있어요")
                    .font(.app(12)).foregroundStyle(.secondary)
                Spacer()
                Button(app.state.sectionsChosen == nil ? "시작하기" : "저장") {
                    app.chooseSections(Array(picked))
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(count == 0)
            }
            .padding(.horizontal, 30).padding(.vertical, 14)
        }
        .frame(width: 680, height: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { SectionPhotos.shared.load() } // 분야마다 오늘의 사진(처음 실행이면 피드를 바로 받아 옴)
    }
}

private struct SectionCard: View {
    let section: NewsSection
    let on: Bool
    let toggle: () -> Void
    @ObservedObject private var photos = SectionPhotos.shared

    var body: some View {
        // 대표 출처 2~3곳(처음 고르면 켜질 곳 먼저)
        let srcs = Sections.sources(in: section.id).sorted { ($0.defaultOn == true ? 0 : 1) < ($1.defaultOn == true ? 0 : 1) }
        let names = srcs.prefix(3).map { $0.name ?? $0.id }
        Button(action: toggle) {
            SectionGlassCard(section: section, photo: photos.images[section.id], selected: on,
                             subtitle: names.isEmpty ? (section.id == Sections.ai ? "OpenAI · Anthropic · AI타임스" : nil) : names.joined(separator: " · "))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(section.name)\(on ? ", 고름" : "")")
    }
}

@MainActor
enum OnboardingController {
    private static var window: NSWindow?

    static func open() {
        if let w = window { NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentViewController: NSHostingController(rootView: OnboardingView(onDone: { close() })))
        w.title = "관심 분야 고르기"
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { window = nil }
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    static func close() { window?.close() }

    // 시험용: 화면 없이 그려 저장
    static func snapshot(to path: String) {
        guard let v = window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}


// MARK: - 시작할 때: 첫 실행 분야 고르기 + 시험 훅(App.swift 는 한 줄만 부르도록 여기에 둠)
@MainActor
enum SectionStartup {
    static func run() {
        let env0 = ProcessInfo.processInfo.environment
        if let d = env0["DROPCAP_TEST_PERF"] { PerfHarness.run(dir: d) } // 시험용: 메인 막힘 측정
        if let picks = env0["DROPCAP_TEST_SECTIONS"] { // 시험용: 고르기 화면 없이 분야를 고른 것으로
            AppModel.shared.chooseSections(picks.split(separator: ",").map(String.init))
        }
        // 처음 실행이면 관심 분야부터 고른다(시험 폴더 실행은 DROPCAP_TEST_ONBOARD 일 때만 띄움)
        if AppModel.shared.needsOnboarding, env0["DROPCAP_DATA_DIR"] == nil || env0["DROPCAP_TEST_ONBOARD"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { OnboardingController.open() }
            if let dir = env0["DROPCAP_TEST_SHOT_DIR"], env0["DROPCAP_TEST_ONBOARD"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { OnboardingController.snapshot(to: "\(dir)/onboarding.png") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) { OnboardingController.snapshot(to: "\(dir)/onboarding-15s.png") } // 사진이 채워진 뒤
            }
        }
        if let sec = env0["DROPCAP_TEST_BUNDLE"] { // 시험용: 묶음 알림 견본
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let items = (1...7).map { i in
                    NewsItem(id: AppModel.previewID, title: "Sample \(i)", titleKo: ["기준금리 동결, 시장은 연내 인하 기대", "코스피 2,900 회복… 외국인 순매수", "환율 1,380원대로 내려와", "수출 석 달째 늘어", "부동산 거래 다시 줄어", "물가 상승률 2%대 유지", "반도체 실적 개선"][i - 1],
                             link: "", date: Date(), summary: "", sourceId: "openai", sourceName: "견본", tier: "kr")
                }
                ToastCenter.shared.showBundle(section: sec, items: items)
            }
            if let dir = env0["DROPCAP_TEST_SHOT_DIR"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { ToastCenter.shared.snapshot(to: "\(dir)/bundle.png") }
            }
        }
    }
}
