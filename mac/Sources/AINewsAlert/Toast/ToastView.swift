import SwiftUI

// 물방울 → 카드로 변하는 모양. t = 0 이면 위쪽 가운데의 작은 원, 1 이면 카드 전체.
struct DropletShape: Shape {
    var t: CGFloat
    static let drop: CGFloat = DripView.dropRadius * 2
    static let radius: CGFloat = 20

    var animatableData: CGFloat {
        get { t }
        set { t = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let p = min(max(t, 0), 1)
        // 가로가 먼저 퍼지고 세로가 뒤따라 늘어난다(물이 번지는 느낌)
        let px = 1 - pow(1 - p, 2.2)
        let py = pow(p, 1.25)
        let w = Self.drop + (rect.width - Self.drop) * px
        let h = Self.drop + (rect.height - Self.drop) * py
        let r = min(Self.drop / 2 + (Self.radius - Self.drop / 2) * p, h / 2, w / 2)
        let frame = CGRect(x: rect.midX - w / 2, y: rect.minY, width: w, height: h)
        return Path(roundedRect: frame, cornerRadius: r, style: .continuous)
    }
}

struct ToastStack: View {
    @EnvironmentObject var center: ToastCenter
    static let top: CGFloat = 46 // 천장(상단바)에서 카드까지: 물방울이 맺히고 떨어질 자리

    var body: some View {
        VStack(spacing: 10) {
            ForEach(center.toasts) { t in
                ToastView(toast: t)
                    .transition(.identity) // 들어오고 나가는 움직임은 카드가 직접 한다
            }
            Spacer(minLength: 0)
        }
        .padding(.top, ToastStack.top)
        .padding(.horizontal, 20)
        .frame(width: ToastCenter.panelWidth, height: ToastCenter.panelHeight, alignment: .top)
        .coordinateSpace(name: "panel")
    }
}

struct ToastView: View {
    let toast: Toast
    @EnvironmentObject var center: ToastCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    // 움직임 상태
    @State private var t: CGFloat = 1          // 카드(1) → 물방울(0): 사라질 때 오므라든다
    @State private var dropY: CGFloat = 0       // 사라질 때 천장으로 빨려 올라가는 높이
    @State private var sx: CGFloat = 1
    @State private var sy: CGFloat = 1
    @State private var dripStart: Date?         // 천장에 맺혀 떨어지는 물방울
    @State private var alpha: Double = 0
    @State private var tint: Double = 0         // 사라질 때의 물빛
    @State private var fillStart: Date?         // 물이 차오르기 시작한 때
    @State private var cardH: CGFloat = 80
    @State private var shadow: Double = 0
    @State private var reveal = false           // 글자 떠오름

    // 사라짐 시계
    @State private var hovering = false
    @State private var remaining: Double = 1
    @State private var calm = false
    @State private var thumb: String?            // 카드의 사진(피드에 없으면 기사 머리에서 찾아 옴)
    @State private var developed: Double = 0     // 사진 인화 정도 0~1            // 물이 다 차고 잔잔해짐: 다시 그리는 횟수를 줄인다
    @State private var leaving = false
    private let lifetime: Double = 9

    private var dripColor: Color { center.notchMode ? .black : toast.accent.mix(.white, 0.18) }
    private var waterColor: Color { center.notchMode ? Color(white: 0.25) : toast.accent }
    // 물방울이 카드 바닥까지 떨어진다
    private var landY: CGFloat { ToastStack.top + cardH - DripView.dropRadius * 0.6 }

    // 유리 물방울(macOS 26)일 때는 물빛을 옅게 해서 맑은 물처럼, 노치에서는 검게
    private var waterTint: Double {
        if center.notchMode { return 1 }
        if #available(macOS 26.0, *) { return 0.28 }
        return 1
    }

    private var isNews: Bool { if case .news = toast.kind { return true }; return false }
    private var isClickable: Bool {
        switch toast.kind { case .news, .digest: return true; default: return false }
    }

    var body: some View {
        ZStack(alignment: .top) {
            card
                .scaleEffect(x: sx * (hovering ? 1.012 : 1), y: sy * (hovering ? 1.012 : 1), anchor: .top)
                .offset(y: dropY)
                .opacity(alpha)
            closeButton
            quickActions
        }
        .frame(width: 360)
        .overlay(alignment: .top) {
            if let d = dripStart {
                DripView(start: d, color: dripColor, landY: landY, dark: center.notchMode)
                    .offset(y: -ToastStack.top)
            }
        }
        .background(GeometryReader { g in
            Color.clear.preference(key: CardFrameKey.self, value: [toast.id: g.frame(in: .named("panel"))])
        })
        .onPreferenceChange(CardFrameKey.self) { frames in
            for (k, v) in frames { center.cardFrames[k] = v }
            if let f = frames[toast.id], f.height > 20 { cardH = f.height }
        }
        .onChange(of: center.hoveredID) { _, id in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { hovering = id == toast.id && !leaving }
        }
        .task { await run() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: 카드
    private var card: some View {
        content
            .frame(width: 360, alignment: .leading)
            .background {
                ZStack {
                    glass
                    if let f = fillStart { WaterFill(start: f, color: waterColor, level: remaining, calm: calm) }
                }
            }
            .overlay { tintLayer }
            .clipShape(DropletShape(t: t))
            .contentShape(DropletShape(t: t))
            .background {
                DropletShape(t: t)
                    .fill(Color.black.opacity(0.001))
                    .shadow(color: .black.opacity((scheme == .dark ? 0.5 : 0.2) * shadow * (hovering ? 1.35 : 1)), radius: hovering ? 22 : 16, y: hovering ? 12 : 8)
                    .shadow(color: .black.opacity(0.08 * shadow), radius: 2, y: 1)
            }
            .onTapGesture { tap() }
    }

    @ViewBuilder private var glass: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular.tint(toast.accent.opacity(0.06)), in: DropletShape(t: t))
        } else {
            DropletShape(t: t).fill(.regularMaterial)
        }
    }

    // 떨어지는 동안의 물방울 빛깔: 출처 색 + 위쪽의 작은 반사광
    private var tintLayer: some View {
        ZStack(alignment: .top) {
            RadialGradient(colors: center.notchMode
                               ? [Color(white: 0.16), .black, toast.accent.mix(.black, 0.6)]
                               : [toast.accent.mix(.white, 0.35), toast.accent, toast.accent.mix(.black, 0.25)],
                           center: UnitPoint(x: 0.5, y: 0), startRadius: 0, endRadius: 60)
            Circle().fill(.white.opacity(0.75)).frame(width: 8, height: 8).blur(radius: 1).offset(x: -4, y: 6)
        }
        .opacity(tint)
        .allowsHitTesting(false)
    }

    // 열지 않고 바로: 나중에 읽기 · 브라우저로
    @ViewBuilder private var quickActions: some View {
        if case .news(let item) = toast.kind {
            HStack(spacing: 4) {
                QuickButton(symbol: AppModel.shared.isSaved(item) ? "bookmark.fill" : "bookmark", help: "나중에 읽기") {
                    AppModel.shared.toggleSaved(item)
                }
                QuickButton(symbol: "safari", help: "브라우저에서 열기") {
                    if let u = URL(string: item.link) { NSWorkspace.shared.open(u) }
                    AppModel.shared.setRead(item, true)
                    Task { await leave(quick: true) }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .opacity(hovering ? 1 : 0)
            .offset(y: hovering ? 0 : 4)
        }
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .offset(x: -7, y: -7)
        .opacity(hovering ? 1 : 0)
        .scaleEffect(hovering ? 1 : 0.6, anchor: .topLeading)
        .accessibilityLabel("닫기")
    }

    // MARK: 내용
    @ViewBuilder private var content: some View {
        switch toast.kind {
        case .news(let item):
            HStack(alignment: .top, spacing: 12) {
                Monogram(letter: item.initial, color: item.accent)
                    .rise(reveal, 0)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if item.important == true {
                            Image(systemName: "star.fill").font(.system(size: 9.5, weight: .bold)).foregroundStyle(.orange)
                                .help("꼭 알림 낱말이 들어간 소식")
                        }
                        Text(item.sourceName).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                        CategoryChip(category: item.category)
                        if let r = item.related, !r.isEmpty {
                            Text("외 \(r.count)곳").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                                .help("같은 소식: \(r.joined(separator: ", "))")
                        }
                        Spacer(minLength: 4)
                        Text(RelativeTime.string(item.date)).font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
                    }
                    .rise(reveal, 1)
                    Text(item.displayTitle)
                        .font(.system(size: 14.5, weight: .semibold))
                        .tracking(-0.15)
                        .lineSpacing(1.5)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .rise(reveal, 2)
                    if let ko = item.titleKo, ko != item.title {
                        Text(item.title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                            .rise(reveal, 3)
                    }
                }
                if let thumb {
                    // 인화: 물에 잠긴 사진이 회색·흐림에서 점점 또렷한 색으로 떠오른다
                    RemoteImage(url: thumb, category: item.category, accent: item.accent)
                        .frame(width: 58, height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                        .saturation(developed)
                        .blur(radius: (1 - developed) * 5)
                        .brightness((1 - developed) * 0.22)
                        .opacity(0.25 + 0.75 * developed)
                        .scaleEffect(0.94 + 0.06 * developed)
                }
            }
            .padding(EdgeInsets(top: 14, leading: 14, bottom: 15, trailing: 16))
        case .info(let title, let sub):
            HStack(spacing: 11) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: [.cyan, .blue], startPoint: .top, endPoint: .bottom))
                    .frame(width: 30, height: 30)
                    .background(.blue.opacity(0.12), in: Circle())
                    .rise(reveal, 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13.5, weight: .semibold)).rise(reveal, 1)
                    Text(sub).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).rise(reveal, 2)
                }
            }
            .padding(EdgeInsets(top: 12, leading: 13, bottom: 12, trailing: 16))
        case .digest(let n):
            HStack(spacing: 11) {
                Image(systemName: "sun.horizon.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: [.orange, .pink], startPoint: .top, endPoint: .bottom))
                    .frame(width: 30, height: 30)
                    .background(.orange.opacity(0.13), in: Circle())
                    .rise(reveal, 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text("오늘의 AI 브리핑").font(.system(size: 13.5, weight: .semibold)).rise(reveal, 1)
                    Text("지난 하루 소식 \(n)건 — 매거진에서 보기").font(.system(size: 12)).foregroundStyle(.secondary).rise(reveal, 2)
                }
            }
            .padding(EdgeInsets(top: 12, leading: 13, bottom: 12, trailing: 16))
        case .more(let n):
            HStack(spacing: 4) {
                Text("AI 소식")
                Text("\(n)건").foregroundStyle(Color.accentColor)
                Text("더 · 상단바 아이콘에서 확인")
            }
            .font(.system(size: 12.5, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .rise(reveal, 0)
        }
    }

    // MARK: 움직임
    private func run() async {
        if case .news(let item) = toast.kind, item.id != AppModel.previewID {
            thumb = item.image
            if thumb == nil, !item.link.isEmpty {
                Task { if let u = await FeedService.shared.ogImage(item.link) { withAnimation(.easeOut(duration: 0.3)) { thumb = u } } }
            }
        }
        if reduceMotion {
            developed = 1
            t = 1; dropY = 0; sx = 1; sy = 1; tint = 0
            withAnimation(.easeOut(duration: 0.2)) { alpha = 1; shadow = 1; reveal = true }
            if toast.playSound { DropSound.play() }
        } else {
            // 1) 빈 유리잔(카드)이 살며시 나타나고, 천장에 물이 맺혀 → 처지다 → 톡 떨어진다
            guard await pause(30) else { return } // 카드 높이를 잰 뒤
            dripStart = Date()
            withAnimation(.easeOut(duration: 0.5)) { alpha = 1; shadow = 0.6 }
            let land = DripView.landingTime(landY)
            guard await pause(Int(land * 1000) - 25) else { return } // 닿는 순간 바로 물이 차기 시작하게

            // 2) 바닥에 "퐁" 하고 닿으면 물이 찰랑찰랑 차오른다
            if toast.playSound { DropSound.play() }
            fillStart = Date()
            withAnimation(.easeInOut(duration: 2.0)) { developed = 1 }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.45)) { sy = 0.985 } // 닿는 순간 잔이 살짝 눌렸다가
            Task {
                try? await Task.sleep(for: .milliseconds(90))
                withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) { sy = 1 }
                try? await Task.sleep(for: .milliseconds(700)) // 천장에 남은 물이 다 빨려 들어간 뒤 치움
                dripStart = nil
            }

            // 3) 거의 다 차면 글자가 떠오르고 그림자가 짙어진다
            guard await pause(Int(WaterFill.fillTime * 0.85 * 1000)) else { return }
            withAnimation(.easeOut(duration: 0.4)) { shadow = 1 }
            reveal = true
            guard await pause(Int(WaterFill.fillTime * 0.15 * 1000)) else { return }
            Task { try? await Task.sleep(for: .milliseconds(900)); calm = true }
        }

        // 4) 머무름: 마감 시각 기준으로 남은 양을 계산(초당 10번). 마우스를 올린 동안은 마감을 미룬다.
        var deadline = Date().addingTimeInterval(lifetime)
        var last = Date()
        while !leaving {
            guard await pause(100) else { return } // 카드가 밀려나 취소되면 바로 끝
            let now = Date()
            if hovering { deadline += now.timeIntervalSince(last) }
            last = now
            remaining = max(0, deadline.timeIntervalSince(now) / lifetime)
            if remaining <= 0 { break }
        }
        if !leaving { await leave(quick: false) }
    }

    // 취소되면 false
    private func pause(_ ms: Int) async -> Bool {
        do { try await Task.sleep(for: .milliseconds(max(ms, 0))); return true } catch { return false }
    }

    private func tap() {
        guard !leaving else { return }
        if isClickable { center.open(toast) }
        Task { await leave(quick: true) }
    }

    private func dismiss() {
        Task { await leave(quick: false) }
    }

    // 물방울로 오므라들어 위로 빨려 올라간다
    private func leave(quick: Bool) async {
        guard !leaving else { return }
        leaving = true
        hovering = false
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.15)) { alpha = 0 }
            try? await Task.sleep(for: .milliseconds(150))
            center.remove(toast.id)
            return
        }
        // 카드만 조용히 사라진다: 살짝 작아지며 흐려지고 투명해짐
        let k = quick ? 0.6 : 1.0
        withAnimation(.easeOut(duration: 0.12 * k)) { reveal = false }
        withAnimation(.easeIn(duration: 0.28 * k)) { alpha = 0; shadow = 0; sx = 0.96; sy = 0.96 }
        try? await Task.sleep(for: .milliseconds(Int(280 * k)))
        center.remove(toast.id)
    }
}

struct Monogram: View {
    let letter: String
    let color: Color
    var size: CGFloat = 38

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
            .fill(LinearGradient(colors: [color.mix(.white, 0.18), color, color.mix(.black, 0.15)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(RoundedRectangle(cornerRadius: size * 0.29, style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
            .overlay(Text(letter).font(.system(size: size * 0.45, weight: .bold, design: .rounded)).foregroundStyle(.white))
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.35), radius: 3, y: 2)
    }
}

private struct CardFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct Rise: ViewModifier {
    let on: Bool
    let index: Int
    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0)
            .offset(y: on ? 0 : 5)
            .blur(radius: on ? 0 : 3)
            .animation(on ? .spring(response: 0.4, dampingFraction: 0.85).delay(0.14 + Double(index) * 0.045) : .easeOut(duration: 0.1), value: on)
    }
}

extension View {
    func rise(_ on: Bool, _ index: Int) -> some View { modifier(Rise(on: on, index: index)) }
}

extension Color {
    func mix(_ other: Color, _ amount: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .gray
        let f = CGFloat(amount)
        return Color(.sRGB, red: Double(a.redComponent + (b.redComponent - a.redComponent) * f),
                     green: Double(a.greenComponent + (b.greenComponent - a.greenComponent) * f),
                     blue: Double(a.blueComponent + (b.blueComponent - a.blueComponent) * f))
    }
}


struct CategoryChip: View {
    let category: NewsCategory
    var body: some View {
        Label(category.label, systemImage: category.symbol)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(category.color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(category.color.opacity(0.13), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .lineLimit(1)
    }
}

private struct QuickButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 22)
                .background(.primary.opacity(hover ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
    }
}
