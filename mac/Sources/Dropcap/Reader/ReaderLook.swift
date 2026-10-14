import AppKit
import SwiftUI

// 읽기 창 모양: 글자 크기 · 줄 간격 · 본문 폭 · 바탕 · 글꼴. 값은 @AppStorage 로 기억한다(모든 읽기 창 공통).
enum ReaderLook {
    static let fontSizeKey = "readerFontSize"
    static let spacingKey = "readerLineSpacing"
    static let widthKey = "readerWidth"
    static let themeKey = "readerTheme"
    static let fontKey = "readerFont"
    static let sizeRange: ClosedRange<Double> = 13...26

    enum Spacing: String, CaseIterable, Identifiable {
        case tight, normal, loose
        var id: String { rawValue }
        var label: String { switch self { case .tight: "좁게"; case .normal: "보통"; case .loose: "넓게" } }
        var factor: CGFloat { switch self { case .tight: 0.68; case .normal: 1; case .loose: 1.4 } }
    }

    enum Width: String, CaseIterable, Identifiable {
        case narrow, normal, wide
        var id: String { rawValue }
        var label: String { switch self { case .narrow: "좁게"; case .normal: "보통"; case .wide: "넓게" } }
        var points: CGFloat { switch self { case .narrow: 540; case .normal: 660; case .wide: 820 } }
    }

    enum Theme: String, CaseIterable, Identifiable {
        case auto, sepia, dark
        var id: String { rawValue }
        var label: String { switch self { case .auto: "자동"; case .sepia: "종이"; case .dark: "어둡게" } }
        // 자동은 시스템(밝은/어두운 화면)을 따른다
        var scheme: ColorScheme? { switch self { case .auto: nil; case .sepia: .light; case .dark: .dark } }
        var background: Color {
            switch self {
            case .auto: Color(nsColor: .textBackgroundColor)
            case .sepia: Color(red: 0.969, green: 0.937, blue: 0.867)   // #F7EFDD
            case .dark: Color(red: 0.11, green: 0.11, blue: 0.118)      // #1C1C1E
            }
        }
        var text: Color? {
            switch self {
            case .auto: nil
            case .sepia: Color(red: 0.29, green: 0.22, blue: 0.16)       // 짙은 갈색
            case .dark: Color(red: 0.88, green: 0.88, blue: 0.9)
            }
        }
        var swatch: Color { self == .auto ? Color(nsColor: .textBackgroundColor) : background }
    }

    enum Face: String, CaseIterable, Identifiable {
        case pretendard, serif, system
        var id: String { rawValue }
        var label: String { switch self { case .pretendard: "Pretendard"; case .serif: "명조"; case .system: "시스템" } }
        // 빈 값: 앱 설정(Pretendard 쓰기)을 따른다
        static func resolve(_ raw: String) -> Face { Face(rawValue: raw) ?? (Typography.usePretendard ? .pretendard : .system) }
    }

    static func clampSize(_ v: Double) -> Double { min(sizeRange.upperBound, max(sizeRange.lowerBound, v)) }

    // 본문 글꼴. 명조: 영문은 New York(시스템 명조), 한글은 AppleMyungjo 로 잇는다.
    @MainActor static func font(_ face: Face, _ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        switch face {
        case .pretendard: return .custom(Typography.family, size: size).weight(weight)
        case .system: return .system(size: size, weight: weight)
        case .serif: return Font(serifFont(size, bold: weight == .bold || weight == .semibold || weight == .heavy))
        }
    }

    @MainActor private static var serifCache: [String: NSFont] = [:]
    @MainActor static func serifFont(_ size: CGFloat, bold: Bool) -> NSFont {
        let k = "\(size)-\(bold)"
        if let f = serifCache[k] { return f }
        let base = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        var desc = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        let kor = NSFontDescriptor(fontAttributes: [.name: "AppleMyungjo"])
        desc = desc.addingAttributes([.cascadeList: [kor]])
        let f = NSFont(descriptor: desc, size: size) ?? base
        serifCache[k] = f
        return f
    }
}

// 도구 막대의 '모양'(Aa) 단추와 팝오버
struct ReaderLookButton: View {
    @State private var open = false
    var body: some View {
        Button { open.toggle() } label: { Label("모양", systemImage: "textformat.size") }
            .help("읽기 모양 — 글자 크기·줄 간격·폭·바탕·글꼴")
            .popover(isPresented: $open, arrowEdge: .bottom) { ReaderLookPanel() }
    }
}

struct ReaderLookPanel: View {
    @AppStorage(ReaderLook.fontSizeKey) private var fs: Double = 17
    @AppStorage(ReaderLook.spacingKey) private var spacing = ReaderLook.Spacing.normal.rawValue
    @AppStorage(ReaderLook.widthKey) private var width = ReaderLook.Width.normal.rawValue
    @AppStorage(ReaderLook.themeKey) private var theme = ReaderLook.Theme.auto.rawValue
    @AppStorage(ReaderLook.fontKey) private var face = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            row("글자 크기") {
                HStack(spacing: 10) {
                    Button { fs = ReaderLook.clampSize(fs - 1) } label: { Image(systemName: "textformat.size.smaller") }
                        .disabled(fs <= ReaderLook.sizeRange.lowerBound).help("작게 (⌘-)")
                    Text("\(Int(fs))").font(.app(13, .semibold)).monospacedDigit().frame(minWidth: 24)
                    Button { fs = ReaderLook.clampSize(fs + 1) } label: { Image(systemName: "textformat.size.larger") }
                        .disabled(fs >= ReaderLook.sizeRange.upperBound).help("크게 (⌘=)")
                    Spacer()
                    Text("⌘- / ⌘=").font(.app(11)).foregroundStyle(.tertiary)
                }
            }
            row("줄 간격") {
                Picker("", selection: $spacing) { ForEach(ReaderLook.Spacing.allCases) { Text($0.label).tag($0.rawValue) } }
                    .pickerStyle(.segmented).labelsHidden()
            }
            row("본문 폭") {
                Picker("", selection: $width) { ForEach(ReaderLook.Width.allCases) { Text($0.label).tag($0.rawValue) } }
                    .pickerStyle(.segmented).labelsHidden()
            }
            row("바탕") {
                HStack(spacing: 8) {
                    ForEach(ReaderLook.Theme.allCases) { t in
                        let on = (ReaderLook.Theme(rawValue: theme) ?? .auto) == t
                        Button { theme = t.rawValue } label: {
                            VStack(spacing: 4) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(t.swatch)
                                    if t == .auto { // 자동: 반은 밝게 반은 어둡게
                                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ReaderLook.Theme.dark.background)
                                            .mask(alignment: .trailing) { Rectangle().frame(width: 30) }
                                    }
                                    Text("가").font(.app(13, .semibold)).foregroundStyle(t.text ?? .primary)
                                }
                                .frame(width: 60, height: 34)
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(on ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: on ? 2 : 0.5))
                                Text(t.label).font(.app(11, on ? .semibold : .regular)).foregroundStyle(on ? Color.accentColor : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("바탕 \(t.label)")
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            row("글꼴") {
                Picker("", selection: Binding(get: { ReaderLook.Face.resolve(face).rawValue }, set: { face = $0 })) {
                    ForEach(ReaderLook.Face.allCases) { f in Text(f.label).tag(f.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            Divider()
            HStack {
                Text("모든 읽기 창에 같이 적용됩니다").font(.app(11)).foregroundStyle(.secondary)
                Spacer()
                Button("기본값") {
                    fs = 17; spacing = ReaderLook.Spacing.normal.rawValue; width = ReaderLook.Width.normal.rawValue
                    theme = ReaderLook.Theme.auto.rawValue; face = ""
                }
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.app(11.5, .semibold)).foregroundStyle(.secondary)
            c()
        }
    }
}

// 바탕을 '어둡게'·'종이'로 고르면 창 전체(제목줄·도구 막대 포함)를 그 모양으로
struct WindowAppearance: NSViewRepresentable {
    let scheme: ColorScheme?
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async {
            v.window?.appearance = scheme.map { NSAppearance(named: $0 == .dark ? .darkAqua : .aqua) } ?? nil
        }
    }
}
