import AppKit
import Combine
import DropcapShared
import SwiftUI

// 위젯 · Spotlight 연결을 켠다(App.swift 에서 한 줄). 앱 상태를 지켜보다가 바뀌면 다시 쓴다.
@MainActor
enum Integrations {
    private static var bag: Set<AnyCancellable> = []

    static func start() {
        guard bag.isEmpty else { return }
        AppModel.shared.$state
            // 위젯이 보이는 목록(꺼진·해지한·숨긴 출처를 뺀 앞쪽)이 바뀌어도 다시 쓴다 — 예전엔 맨 앞 key 만 봐서 출처를 꺼도 위젯에 남았다(E2E 13)
            .map { st in WidgetTrigger(lastCheck: st.lastCheck, unread: st.unread,
                                       top: SourceFilter.make(state: st, sources: Resources.config.sources + st.customSources)
                                           .visible(st.recent).prefix(WidgetExporter.latestCount + 1).map(\.key).joined(separator: "\n")) }
            .removeDuplicates()
            .sink { _ in WidgetExporter.shared.scheduleExport() }
            .store(in: &bag)
        AppModel.shared.$state
            .map { $0.saved.map(\.key) }
            .removeDuplicates()
            .sink { _ in SpotlightIndexer.shared.scheduleSync() }
            .store(in: &bag)
        Scrapbook.shared.$scraps
            .dropFirst()
            .sink { _ in SpotlightIndexer.shared.scheduleSync() }
            .store(in: &bag)
        runTestHooks()
    }

    private struct WidgetTrigger: Equatable { var lastCheck: Date?; var unread: Int; var top: String? }

    // 시험용: DROPCAP_TEST_WIDGET=1 + DROPCAP_TEST_SHOT_DIR 이면 스냅숏을 쓰고 위젯 화면(소·중)을 그림 파일로 찍는다
    private static func runTestHooks() {
        let env = ProcessInfo.processInfo.environment
        guard env["DROPCAP_TEST_WIDGET"] != nil, let shots = env["DROPCAP_TEST_SHOT_DIR"] else { return }
        let wait = Double(env["DROPCAP_TEST_WIDGET"] ?? "") ?? 30
        Task {
            try? await Task.sleep(for: .seconds(wait))
            await WidgetExporter.shared.export()
            let content = WidgetContent.load(from: WidgetExporter.shared.dir)
            NSLog("[위젯 시험] 표지=%@ 최신=%d 안읽음=%d 사진=%d", content.snapshot.cover?.title ?? "-",
                  content.snapshot.latest.count, content.snapshot.unread, content.images.count)
            for (name, size, view) in [("widget-small", CGSize(width: 170, height: 170), AnyView(DropcapSmallView(content, preview: true))),
                                       ("widget-medium", CGSize(width: 364, height: 170), AnyView(DropcapMediumView(content, preview: true)))] {
                for dark in [false, true] {
                    let r = ImageRenderer(content: view.frame(width: size.width, height: size.height)
                        .background(Color(nsColor: dark ? NSColor(white: 0.18, alpha: 1) : .white))
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .environment(\.colorScheme, dark ? .dark : .light))
                    r.scale = 2
                    if let cg = r.cgImage {
                        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                            .write(to: URL(fileURLWithPath: "\(shots)/\(name)\(dark ? "-dark" : "").png"))
                    }
                }
            }
            if env["DROPCAP_TEST_SPOTLIGHT"] != nil { await SpotlightIndexer.shared.sync() }
        }
    }
}

// 설정 > 일반 에 들어가는 한 묶음
struct IntegrationsSettingsSection: View {
    @AppStorage(WidgetExporter.enabledKey) private var widget = true
    @AppStorage(SpotlightIndexer.enabledKey) private var spotlight = true

    var body: some View {
        Section {
            Toggle("위젯에 오늘의 표지·최신 소식 보내기", isOn: $widget)
                .onChange(of: widget) { _, on in on ? WidgetExporter.shared.scheduleExport() : WidgetExporter.shared.clear() }
            Toggle("저장한 기사·스크랩을 Spotlight 에서 찾기", isOn: $spotlight)
                .onChange(of: spotlight) { _, on in
                    if on { SpotlightIndexer.shared.scheduleSync() } else { Task { await SpotlightIndexer.shared.clear() } }
                }
        } header: {
            Text("위젯 · 단축어 · Spotlight")
        } footer: {
            Text("위젯은 알림 센터에서, 단축어는 단축어 앱에서 'Dropcap' 으로 찾습니다. 끄면 위젯용 사본과 Spotlight 색인을 지웁니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
