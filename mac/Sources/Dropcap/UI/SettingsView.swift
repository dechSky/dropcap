import AppKit
import SwiftUI
import Translation

struct SettingsView: View {
    @ObservedObject var model = AppModel.shared
    @State private var appleReady = false
    @State private var preparing = false
    @State private var newURL = ""
    @State private var adding = false
    @State private var addError: String?
    @State private var mustText = ""
    @State private var muteText = ""
    @State private var watchText = ""
    @ObservedObject private var backup = BackupManager.shared

    var body: some View {
        TabView {
            general.tabItem { Label("일반", systemImage: "gearshape") }
            sectionsTab.tabItem { Label("분야", systemImage: "square.grid.2x2") }
            sources.tabItem { Label("구독", systemImage: "antenna.radiowaves.left.and.right") }
            filters.tabItem { Label("거르기", systemImage: "line.3.horizontal.decrease.circle") }
            ScrapbookSettingsView().tabItem { Label("스크랩북", systemImage: "scissors") }
        }
        .frame(width: 600, height: 640)
        .liveAppearance()
        .task {
            appleReady = await Translator.appleReady()
            mustText = model.state.settings.mustKeywords.joined(separator: ", ")
            muteText = model.state.settings.muteKeywords.joined(separator: ", ")
            watchText = model.state.settings.watchKeywords.joined(separator: ", ")
        }
    }

    private var general: some View {
        Form {
            Section("알림") {
                Picker("알림 모양", selection: Binding(get: { model.state.settings.style }, set: { v in model.update { $0.style = v } })) {
                    Text("물방울 (앱이 직접 그림)").tag(AppState.Settings.Style.drop)
                    Text("시스템 알림 센터").tag(AppState.Settings.Style.system)
                }
                Picker("알림 위치", selection: Binding(get: { model.state.settings.position }, set: { v in model.update { $0.position = v } })) {
                    Text("위쪽 가운데").tag(AppState.Settings.Position.center)
                    Text("오른쪽 위").tag(AppState.Settings.Position.right)
                }
                Toggle("알림 소리", isOn: Binding(get: { model.state.settings.sound }, set: { v in model.update { $0.sound = v } }))
                Picker("확인 간격", selection: Binding(get: { model.state.settings.intervalMinutes }, set: { v in model.update { $0.intervalMinutes = v } })) {
                    ForEach([2, 5, 10, 15, 30], id: \.self) { Text("\($0)분").tag($0) }
                }
                Button("알림 미리 보기") { model.preview() }
            }
            Section("내 기록") {
                Text("계정도 서버도 없습니다. 모든 기록은 이 Mac 안에만 있습니다.").font(.callout)
                HStack {
                    Button("내 기록 내보내기…") { BackupManager.shared.chooseExport() }
                    Button("가져오기…") { BackupManager.shared.chooseImport() }
                    if backup.undoFile != nil {
                        Button("마지막 가져오기 되돌리기") { BackupManager.shared.undoImport() }
                            .help("가져오기 전에 자동으로 남긴 기록으로 되돌립니다")
                    }
                }
                Text("다른 Mac 으로 옮길 때: 저장·스크랩과 폴더·구독·분야·알림 설정·낱말·숨긴 출처를 JSON 파일 하나로 내보내고, 다른 Mac 에서 가져오면 없는 것만 더합니다(같은 것은 건너뜀). 기사 캐시·사진은 담지 않습니다. 가져오기 전 기록은 자동으로 남겨 되돌릴 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                if let m = backup.lastMessage { Text(m).font(.caption).foregroundStyle(.secondary) }
            }
            Section("회의·발표 중에는 조용히") {
                Toggle("전체 화면 앱을 쓰는 중", isOn: Binding(get: { model.state.settings.autoQuietFullscreen }, set: { v in model.update { $0.autoQuietFullscreen = v } }))
                Toggle("화면을 공유·기록하는 중", isOn: Binding(get: { model.state.settings.autoQuietSharing }, set: { v in model.update { $0.autoQuietSharing = v } }))
                Toggle("캘린더 일정 중", isOn: Binding(get: { model.state.settings.autoQuietCalendar }, set: { v in
                    guard v else { model.update { $0.autoQuietCalendar = false }; return }
                    Task {
                        // 켤 때만 캘린더 권한을 묻는다. 거절하면 꺼진 채로 둔다
                        let ok = FocusMonitor.hasCalendarAccess ? true : await FocusMonitor.shared.requestCalendar()
                        model.update { $0.autoQuietCalendar = ok }
                    }
                }))
                Text("이때 온 소식은 물방울 없이 '안 읽음'에 쌓이고, 알릴 만한 소식은 그 분야 묶음으로 모입니다. 화면 공유는 Zoom 공유·화면 기록·화면 공유 앱 연결을 알아봅니다. 일정은 지금 진행 중인지만 보고 내용은 저장하지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("번역") {
                Picker("번역 방식", selection: Binding(
                    get: { model.state.settings.translateEngine },
                    set: { v in model.update { $0.translateEngine = v } })) {
                    Text("자동").tag(Translator.Mode.auto)
                    Text("기기 내 번역만").tag(Translator.Mode.apple)
                    Text("Google 번역").tag(Translator.Mode.google)
                    Text("번역 안 함").tag(Translator.Mode.off)
                }
                Text(Self.translateNote(model.state.settings.translateEngine, appleReady: appleReady))
                    .font(.caption).foregroundStyle(.secondary)
                if !appleReady, model.state.settings.translateEngine == .auto || model.state.settings.translateEngine == .apple {
                    if #available(macOS 26.0, *) {
                        PrepareTranslationButton(preparing: $preparing) {
                            Task { appleReady = await Translator.appleReady() }
                        }
                    }
                    Text("영어→한국어 언어 자료를 받으면 기사가 이 Mac 안에서 번역됩니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("글꼴") {
                Toggle("Pretendard 글꼴 쓰기 (한글이 더 또렷함)", isOn: Binding(
                    get: { Typography.usePretendard },
                    set: { UserDefaults.standard.set($0, forKey: "usePretendard"); model.objectWillChange.send(); Appearance.shared.changed() }))
                Text("끄면 시스템 글꼴을 씁니다. 열려 있는 창에도 바로 적용됩니다.").font(.caption).foregroundStyle(.secondary)
            }
            Section("요약") {
                LabeledContent("3줄 요약") {
                    Text(Summarizer.available ? "켜짐 — 이 Mac 의 Apple Intelligence 로 만듦" : "Apple Intelligence 를 켜면 쓸 수 있음")
                        .foregroundStyle(.secondary)
                }
            }
            IntegrationsSettingsSection()
            Section("시작") {
                Toggle("로그인할 때 자동 실행", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
            }
        }
        .formStyle(.grouped)
    }

    private var sources: some View {
        Form {
            Section {
                HStack {
                    TextField("언론사·블로그 주소 또는 youtube.com/@채널 · r/이름 · github.com/소유자/저장소", text: $newURL)
                        .onSubmit(addChannel)
                    Button(adding ? "찾는 중…" : "구독", action: addChannel).disabled(adding || newURL.isEmpty)
                }
                if let e = addError { Text(e).font(.caption).foregroundStyle(.red) }
                Text("웹사이트·뉴스레터(Substack·Medium)·YouTube 채널·GitHub 릴리스·Reddit·arXiv·팟캐스트 주소를 넣으면 알맞은 피드를 찾아 구독합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("채널 추가") }
            OPMLSection()

            Section("구독 중인 채널 \(model.state.customSources.count)") {
                if model.state.customSources.isEmpty {
                    Text("아래 추천 채널을 골라 보세요.").foregroundStyle(.secondary)
                }
                ForEach(model.state.customSources) { s in sourceRow(s, removable: true) }
            }

            ForEach(["lab", "press", "kr"], id: \.self) { tier in
                Section("기본 출처 · \(Resources.tierLabel(tier))") {
                    ForEach(Resources.config.sources.filter { $0.tier == tier }) { s in sourceRow(s, removable: false) }
                }
            }

            ForEach(ChannelCatalog.groups, id: \.self) { g in
                Section("추천 · \(g)") {
                    ForEach(ChannelCatalog.all.filter { $0.group == g }) { s in catalogRow(s) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addChannel() {
        adding = true; addError = nil
        Task {
            addError = await model.addChannel(newURL)
            adding = false
            if addError == nil { newURL = "" }
        }
    }

    @ViewBuilder private func sourceRow(_ s: Source, removable: Bool) -> some View {
        HStack(spacing: Space.m) {
            Monogram(letter: String(s.name.replacingOccurrences(of: "The ", with: "").prefix(1)).uppercased(), color: Color(hex: s.color), size: 22)
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.s) {
                    Text(s.name)
                    if s.itemKind != .article { KindBadge(kind: s.itemKind) }
                    if s.aiOnly { Text("AI 글만").font(.caption).foregroundStyle(.secondary) }
                    if let err = model.state.errors[s.id] {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("확인 실패: \(err)")
                    }
                    if model.state.enabled[s.id] == true { SourceHealthBadge(source: s) }
                }
                if let h = s.home ?? (removable ? s.url : nil) {
                    Text(h).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            Toggle(isOn: Binding(get: { model.notifies(s.id) }, set: { model.setNotify(s.id, $0) })) {
                Image(systemName: model.notifies(s.id) ? "bell.fill" : "bell.slash")
            }
            .toggleStyle(.button).buttonStyle(.borderless)
            .help(model.notifies(s.id) ? "새 글 알림 켜짐 (끄면 매거진에만 실림)" : "알림 꺼짐 — 매거진에만 실림")
            .disabled(model.state.enabled[s.id] != true)
            Toggle("", isOn: Binding(get: { model.state.enabled[s.id] == true }, set: { model.setEnabled(s.id, $0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
            if removable {
                Button(role: .destructive) { model.removeCustomSource(s.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("구독 해지")
            }
        }
    }

    @ViewBuilder private func catalogRow(_ s: Source) -> some View {
        HStack(spacing: Space.m) {
            Monogram(letter: String(s.name.prefix(1)).uppercased(), color: Color(hex: s.color), size: 22)
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.s) {
                    Text(s.name)
                    if s.itemKind != .article { KindBadge(kind: s.itemKind) }
                }
                Text(s.notifyDefault == false ? "글이 많아 알림 없이 매거진에만 실림" : "새 글이 오면 알림")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isSubscribed(s) {
                Label("구독 중", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon).font(.caption)
            } else {
                Button(model.subscribing.contains(s.url) ? "확인 중…" : "구독") { Task { addError = await model.subscribe(s) } }
                    .controlSize(.small).disabled(model.subscribing.contains(s.url))
            }
        }
    }
}

extension SettingsView {
    // 번역 방식 아래 한 줄 안내: 지금 실제로 무엇으로 번역되는지
    static func translateNote(_ mode: Translator.Mode, appleReady: Bool) -> String {
        switch mode {
        case .auto: return appleReady ? "지금: 기기 내 번역(Apple) — 무료·비공개. 안 되면 Google 번역." : "지금: Google 번역(기사 글이 Google 로 갑니다). 언어 자료를 받으면 기기 내 번역."
        case .apple: return appleReady ? "이 Mac 안에서만 번역합니다. 안 되면 원문 그대로." : "언어 자료가 없어 지금은 번역하지 않습니다(원문 그대로)."
        case .google: return "늘 Google 번역 — 빠르지만 기사 글이 Google 로 갑니다."
        case .off: return "외국어 기사·제목을 원문 그대로 보여 줍니다."
        }
    }

    // 분야: 고른 분야마다 알림 모드·묶음 시각·하루 상한(docs/research/COMPETITIVE.md (다)-3)
    var sectionsTab: some View {
        Form {
            Section {
                HStack {
                    Text(model.chosenSections.isEmpty ? "아직 관심 분야를 고르지 않았습니다" :
                         "고른 분야 \(model.chosenSections.filter { $0 != Sections.top }.count)개")
                    Spacer()
                    Button("관심 분야 다시 고르기…") { OnboardingController.open() }
                }
                Text("즉시: 여러 곳이 함께 다룬 소식·공식 발표·꼭 알림 낱말·팔로우한 스토리만 바로 물방울로. 묶음: 정한 시각에 \"경제 7건\"처럼 한 방울. 매거진만: 알리지 않음.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Sections.all.filter { model.chosenSections.contains($0.id) }) { s in
                Section {
                    sectionRow(s)
                }
            }
            Section("알림 양") {
                Stepper("하루 전체 물방울 \(model.state.settings.totalDailyCap)번까지",
                        value: Binding(get: { model.state.settings.totalDailyCap }, set: { v in model.update { $0.totalDailyCap = v } }), in: 1...30)
                Stepper("국내 \(model.state.settings.krThreshold)곳 이상 보도면 중요",
                        value: Binding(get: { model.state.settings.krThreshold }, set: { v in model.update { $0.krThreshold = v } }), in: 1...10)
                Stepper("해외 \(model.state.settings.intlThreshold)곳 이상 보도면 중요",
                        value: Binding(get: { model.state.settings.intlThreshold }, set: { v in model.update { $0.intlThreshold = v } }), in: 1...10)
                Stepper("국내 \(model.state.settings.bigThreshold)곳 이상이면 상한을 넘어도 알림",
                        value: Binding(get: { model.state.settings.bigThreshold }, set: { v in model.update { $0.bigThreshold = v } }), in: 2...20)
                Text("상한을 넘은 소식은 고였다가 그 분야 묶음 시각에 한 방울로 나갑니다. 같은 이야기는 한 번만 알립니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.state.hiddenSources.isEmpty {
                Section("숨긴 출처") {
                    ForEach(model.state.hiddenSources, id: \.self) { id in
                        HStack {
                            Text(Sections.meta[id]?.name ?? model.allSources.first { $0.id == id }?.name ?? id)
                            Spacer()
                            Button("다시 보이기") { model.unhideSource(id) }.buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func sectionRow(_ s: NewsSection) -> some View {
        let p = model.policy(s.id)
        let count = model.sourceCount(s.id)
        HStack(spacing: Space.m) {
            Image(systemName: s.symbol).foregroundStyle(.white).font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26).background(s.tint.gradient, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(s.name).font(.headline)
                Text(s.isFlow ? "어느 분야든 크게 다룬 소식" : count.all > 0 ? "출처 \(count.on)/\(count.all)곳 켜짐" : "구독 탭에서 출처를 켜고 끕니다")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: Binding(get: { p.mode }, set: { v in model.setPolicy(s.id) { $0.mode = v } })) {
                ForEach(NotifyMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 200)
            .help(p.mode.help)
        }
        if p.mode != .magazine {
            HStack {
                Picker("묶음 시각", selection: Binding(get: { p.bundleHour }, set: { v in model.setPolicy(s.id) { $0.bundleHour = v } })) {
                    ForEach(6..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                }
                .help(p.mode == .instant ? "하루 상한을 넘어 고인 소식을 보내는 시각" : "모아 둔 소식을 한 방울로 보내는 시각")
                if p.mode == .instant {
                    Stepper("하루 \(p.dailyCap)번까지", value: Binding(get: { p.dailyCap }, set: { v in model.setPolicy(s.id) { $0.dailyCap = v } }), in: 1...10)
                }
            }
        }
    }

    var filters: some View {
        Form {
            Section("낱말로 거르기") {
                TextField("꼭 알림 (★ 중요 표시)", text: $mustText, prompt: Text("예: GPT-6, Claude, Gemini, 오픈소스"))
                    .onSubmit(saveKeywords)
                    .onChange(of: mustText) { scheduleSave() }
                TextField("알리지 않음", text: $muteText, prompt: Text("예: 주식, 채용, 이벤트"))
                    .onSubmit(saveKeywords)
                    .onChange(of: muteText) { scheduleSave() }
                    // 카드의 '이 낱말 알리지 않기' 등 바깥에서 낱말이 바뀌면 칸도 따라간다(예전엔 남은 옛 글자를 탭을 옮길 때 다시 저장해 되돌렸다 — E2E 22)
                    .onChange(of: model.state.settings.mustKeywords) { _, v in if Self.splitKeywords(mustText) != v { mustText = v.joined(separator: ", ") } }
                    .onChange(of: model.state.settings.muteKeywords) { _, v in if Self.splitKeywords(muteText) != v { muteText = v.joined(separator: ", ") } }
                TextField("지켜볼 낱말 (회사·인물·법안)", text: $watchText, prompt: Text("예: 삼성전자, 엔비디아, AI 기본법"))
                    .onSubmit(saveKeywords)
                    .onChange(of: watchText) { scheduleSave() }
                    .onChange(of: model.state.settings.watchKeywords) { _, v in if WatchWords.normalized(Self.splitKeywords(watchText)) != v { watchText = v.joined(separator: ", ") } }
                Text("지켜볼 낱말이 든 소식은 분야 설정과 상관없이 같은 이야기마다 한 번 알리고, 아침 브리핑 시각에 \"오늘 ○○ 소식 3건\"으로 모아 알립니다. 꼭 알림(★)과 겹치면 ★ 로 표시합니다.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("쉼표로 나눠 적으면 바로 저장·적용됩니다. 제목·요약에 그 낱말이 들어가면 걸립니다.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("저장", action: saveKeywords)
                }
            }
            Section("방해 금지 시간") {
                Toggle("이 시간에는 알리지 않기", isOn: Binding(get: { model.state.settings.quietEnabled }, set: { v in model.update { $0.quietEnabled = v } }))
                Picker("시작", selection: Binding(get: { model.state.settings.quietStart }, set: { v in model.update { $0.quietStart = v } })) {
                    ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                }
                .disabled(!model.state.settings.quietEnabled)
                Picker("끝", selection: Binding(get: { model.state.settings.quietEnd }, set: { v in model.update { $0.quietEnd = v } })) {
                    ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                }
                .disabled(!model.state.settings.quietEnabled)
                Text("이 시간에 온 소식은 알림 없이 '안 읽음'에 쌓입니다.").font(.caption).foregroundStyle(.secondary)
            }
            Section("아침 브리핑") {
                Toggle("매일 지난 하루 소식을 분야별로 정리해 알리기", isOn: Binding(get: { model.state.settings.digestEnabled }, set: { v in model.update { $0.digestEnabled = v } }))
                Picker("시각", selection: Binding(get: { model.state.settings.digestHour }, set: { v in model.update { $0.digestHour = v } })) {
                    ForEach(5..<13, id: \.self) { Text("오전 \($0)시").tag($0) }
                }
                .disabled(!model.state.settings.digestEnabled)
                Button("매거진 열기") { MagazineController.open() }
            }
            Section("단축키") {
                LabeledContent("가장 최근 안 읽은 소식 열기") { hotKeyLabel("⌥⌘N", HotKey.Key.n) }
                LabeledContent("매거진 열기") { hotKeyLabel("⌥⌘M", HotKey.Key.m) }
                ForEach(NavKey.help, id: \.0) { key, what in
                    LabeledContent(what) { Text(key).monospaced().foregroundStyle(.secondary) }
                }
            }
            Section("같은 소식 묶기") {
                Text("여러 곳이 같은 소식을 다루면 한 번만 알리고 \"외 N곳\"으로 표시합니다. 공식 발표를 먼저 고릅니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDisappear { saveKeywords() } // 탭을 옮기거나 창을 닫을 때도 저장
    }

    // 다른 앱이 먼저 쓰고 있어 등록하지 못한 전역 단축키는 그렇다고 알린다
    private func hotKeyLabel(_ text: String, _ key: HotKey.Key) -> some View {
        HStack(spacing: Space.s) {
            if HotKey.unavailable.contains(key.rawValue) {
                Label("다른 앱이 쓰는 중", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
            Text(text).monospaced().foregroundStyle(.secondary)
        }
    }

    // 입력이 멈추고 0.6초 뒤 저장(글자마다 저장·목록 다시 계산하지 않게)
    func scheduleSave() {
        KeywordSaveTimer.shared.schedule { saveKeywords() }
    }

    static func splitKeywords(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func saveKeywords() {
        let must = Self.splitKeywords(mustText), mute = Self.splitKeywords(muteText), watch = WatchWords.normalized(Self.splitKeywords(watchText))
        guard must != model.state.settings.mustKeywords || mute != model.state.settings.muteKeywords || watch != model.state.settings.watchKeywords else { return }
        model.update { $0.mustKeywords = must; $0.muteKeywords = mute; $0.watchKeywords = watch }
        model.reapplyKeywords() // 이미 받은 목록에도 바로 적용
    }
}

// 언어 자료 받기: 시스템이 내려받기 창을 띄운다
@available(macOS 26.0, *)
private struct PrepareTranslationButton: View {
    @Binding var preparing: Bool
    let done: () -> Void
    @State private var config: TranslationSession.Configuration?

    var body: some View {
        Button(preparing ? "받는 중…" : "기기 내 번역 자료 받기") {
            preparing = true
            config = TranslationSession.Configuration(source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "ko"))
        }
        .disabled(preparing)
        .translationTask(config) { session in
            try? await session.prepareTranslation()
            await MainActor.run {
                preparing = false
                done()
            }
        }
    }
}


@MainActor
final class KeywordSaveTimer {
    static let shared = KeywordSaveTimer()
    private var work: DispatchWorkItem?
    func schedule(_ f: @escaping @MainActor () -> Void) {
        work?.cancel()
        let w = DispatchWorkItem { MainActor.assumeIsolated { f() } }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }
}

// 설정 창 열기: 상단바 창·매거진 옆 목록·⌘,(매거진·읽기 창) 이 모두 이 길로. 앱 메뉴가 없는 상단바 앱이라 ⌘, 는 창마다 따로 단다.
// 연 창(매거진·읽기) 앞에 뜨고, 이미 열려 있으면 앞으로만 가져온다.
@MainActor
enum SettingsWindow {
    static func open(_ openSettings: OpenSettingsAction) {
        TestLog.write("[설정] 열기 요청")
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        DispatchQueue.main.async { find()?.makeKeyAndOrderFront(nil) } // 이미 떠 있던 설정 창이 다른 창 뒤에 있으면 앞으로
    }
    static func find() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" }
            ?? NSApp.windows.first { $0.toolbar?.items.contains { $0.label == "거르기" } == true }
    }
}
