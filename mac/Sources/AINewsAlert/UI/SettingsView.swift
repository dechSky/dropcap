import SwiftUI
import Translation

struct SettingsView: View {
    @ObservedObject var model = AppModel.shared
    @State private var appleReady = false
    @State private var preparing = false
    @State private var newName = ""
    @State private var newURL = ""
    @State private var adding = false
    @State private var addError: String?
    @State private var mustText = ""
    @State private var muteText = ""

    var body: some View {
        TabView {
            general.tabItem { Label("일반", systemImage: "gearshape") }
            sources.tabItem { Label("출처", systemImage: "newspaper") }
            filters.tabItem { Label("거르기", systemImage: "line.3.horizontal.decrease.circle") }
        }
        .frame(width: 480, height: 560)
        .task {
            appleReady = await Translator.appleReady()
            mustText = model.state.settings.mustKeywords.joined(separator: ", ")
            muteText = model.state.settings.muteKeywords.joined(separator: ", ")
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
            Section("번역") {
                LabeledContent("번역 방식") {
                    Text(appleReady ? "기기 내 번역(Apple) — 무료·비공개" : "Google 번역")
                        .foregroundStyle(.secondary)
                }
                if !appleReady {
                    if #available(macOS 26.0, *) {
                        PrepareTranslationButton(preparing: $preparing) {
                            Task { appleReady = await Translator.appleReady() }
                        }
                    }
                    Text("영어→한국어 언어 자료를 받으면 기사가 이 Mac 안에서 번역됩니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("요약") {
                LabeledContent("3줄 요약") {
                    Text(Summarizer.available ? "켜짐 — 이 Mac 의 Apple Intelligence 로 만듦" : "Apple Intelligence 를 켜면 쓸 수 있음")
                        .foregroundStyle(.secondary)
                }
            }
            Section("시작") {
                Toggle("로그인할 때 자동 실행", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
            }
        }
        .formStyle(.grouped)
    }

    private var sources: some View {
        Form {
            Section("직접 추가한 출처") {
                ForEach(model.state.customSources) { s in
                    HStack {
                        Toggle(isOn: Binding(get: { model.state.enabled[s.id] == true }, set: { model.setEnabled(s.id, $0) })) {
                            HStack(spacing: 9) {
                                Monogram(letter: String(s.name.prefix(1)).uppercased(), color: Color(hex: s.color), size: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(s.name)
                                    Text(s.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                            }
                        }
                        Button(role: .destructive) { model.removeCustomSource(s.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("이 출처 지우기")
                    }
                }
                TextField("이름 (예: Mistral 블로그)", text: $newName)
                HStack {
                    TextField("RSS 주소 https://…", text: $newURL)
                    Button(adding ? "확인 중…" : "추가") {
                        adding = true; addError = nil
                        Task {
                            addError = await model.addCustomSource(name: newName, url: newURL)
                            adding = false
                            if addError == nil { newName = ""; newURL = "" }
                        }
                    }
                    .disabled(adding || newURL.isEmpty)
                }
                if let e = addError { Text(e).font(.caption).foregroundStyle(.red) }
                Text("주소를 실제로 읽어 보고 글이 있을 때만 추가합니다. 처음엔 기존 글은 알리지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(["lab", "press", "kr"], id: \.self) { tier in
                Section(Resources.tierLabel(tier)) {
                    ForEach(Resources.config.sources.filter { $0.tier == tier }) { s in
                        Toggle(isOn: Binding(get: { model.state.enabled[s.id] == true }, set: { model.setEnabled(s.id, $0) })) {
                            HStack(spacing: 9) {
                                Monogram(letter: String(s.name.replacingOccurrences(of: "The ", with: "").prefix(1)), color: Color(hex: s.color), size: 20)
                                Text(s.name)
                                if s.aiOnly { Text("AI 글만").font(.caption).foregroundStyle(.secondary) }
                                if let err = model.state.errors[s.id] {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("확인 실패: \(err)")
                                }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

extension SettingsView {
    var filters: some View {
        Form {
            Section("낱말로 거르기") {
                TextField("꼭 알림 (★ 중요 표시)", text: $mustText, prompt: Text("예: GPT-6, Claude, Gemini, 오픈소스"))
                    .onSubmit(saveKeywords)
                TextField("알리지 않음", text: $muteText, prompt: Text("예: 주식, 채용, 이벤트"))
                    .onSubmit(saveKeywords)
                HStack {
                    Text("쉼표로 나눠 적고 Return. 제목·요약에 그 낱말이 들어가면 적용됩니다.").font(.caption).foregroundStyle(.secondary)
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
                LabeledContent("가장 최근 안 읽은 소식 열기") { Text("⌥⌘N").monospaced().foregroundStyle(.secondary) }
                LabeledContent("AI 매거진 열기") { Text("⌥⌘M").monospaced().foregroundStyle(.secondary) }
            }
            Section("같은 소식 묶기") {
                Text("여러 곳이 같은 소식을 다루면 한 번만 알리고 \"외 N곳\"으로 표시합니다. 공식 발표를 먼저 고릅니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    func saveKeywords() {
        let split = { (s: String) in s.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        model.update { $0.mustKeywords = split(mustText); $0.muteKeywords = split(muteText) }
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
