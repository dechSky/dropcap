import AppKit
import SwiftUI

// 분야 아이콘: 앱 정체성(물방울 · 드롭캡)을 담은 세 가지 시안. 고른 하나를 분야 고르기·칩·설정·매거진 머리에 같이 쓴다.
struct SectionIcon: View {
    enum Style: String, CaseIterable { case drop, dropSoft, dropLine, dropcap, lens }
    let section: NewsSection
    var style: Style = .drop
    var size: CGFloat = 44

    var body: some View {
        switch style {
        case .drop: dropBadge
        case .dropSoft: dropSoft
        case .dropLine: dropLine
        case .dropcap: dropCap
        case .lens: lens
        }
    }

    // 가: 물방울 배지 — 분야 색 물이 담긴 물방울, 위쪽 반사광, 기호는 물방울 몸통 가운데
    private var dropBadge: some View {
        let t = section.tint
        return ZStack {
            DropShape().fill(LinearGradient(colors: [t.mix(.white, 0.35), t, t.mix(.black, 0.28)], startPoint: .top, endPoint: .bottom))
            DropShape().stroke(.white.opacity(0.35), lineWidth: max(0.6, size * 0.02))
            Ellipse().fill(.white.opacity(0.55)).frame(width: size * 0.16, height: size * 0.24)
                .rotationEffect(.degrees(28)).blur(radius: size * 0.015)
                .offset(x: -size * 0.15, y: size * 0.02)
            Image(systemName: section.symbol).font(.system(size: size * 0.3, weight: .semibold))
                .foregroundStyle(.white).shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                .offset(y: size * 0.14)
        }
        .frame(width: size * 0.82, height: size)
        .shadow(color: t.opacity(0.35), radius: size * 0.08, y: size * 0.05)
    }

    // 가-2: 은은한 채움 — 옅은 분야색 물방울 + 분야색 기호(차분함)
    private var dropSoft: some View {
        let t = section.tint
        return ZStack {
            DropShape().fill(LinearGradient(colors: [t.opacity(0.14), t.opacity(0.26)], startPoint: .top, endPoint: .bottom))
            Ellipse().fill(.white.opacity(0.5)).frame(width: size * 0.12, height: size * 0.18)
                .rotationEffect(.degrees(28)).offset(x: -size * 0.15, y: size * 0.04)
            Image(systemName: section.symbol).font(.system(size: size * 0.3, weight: .semibold))
                .foregroundStyle(t).offset(y: size * 0.14)
        }
        .frame(width: size * 0.82, height: size)
    }

    // 가-3: 선 — 분야색 테두리 물방울 + 분야색 기호(가볍고 세련)
    private var dropLine: some View {
        let t = section.tint
        return ZStack {
            DropShape().fill(t.opacity(0.06))
            DropShape().stroke(t, lineWidth: max(1, size * 0.05))
            Image(systemName: section.symbol).font(.system(size: size * 0.28, weight: .semibold))
                .foregroundStyle(t).offset(y: size * 0.14)
        }
        .frame(width: size * 0.82, height: size)
        .padding(size * 0.025)
    }

    // 나: 드롭캡 — 분야 이름 첫 글자를 장식 첫 글자처럼 크게, 오른쪽 위에 물방울 점
    private var dropCap: some View {
        let t = section.tint
        return ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(LinearGradient(colors: [t.opacity(0.16), t.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(t.opacity(0.28), lineWidth: max(0.6, size * 0.02)))
            Text(Self.initial(section.name))
                .font(.custom("AppleMyungjo", size: size * (Self.initial(section.name).count > 1 ? 0.42 : 0.6)).weight(.heavy))
                .foregroundStyle(t)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(y: size * 0.03)
            DropShape().fill(t).frame(width: size * 0.16, height: size * 0.2).padding(size * 0.1)
        }
        .frame(width: size, height: size)
    }

    // 다: 물방울 렌즈 — 둥근 유리 물방울 속에 기호가 확대돼 비치고, 아래쪽엔 분야 색 물이 찰랑
    private var lens: some View {
        let t = section.tint
        return ZStack {
            Circle().fill(RadialGradient(colors: [.white.opacity(0.9), t.opacity(0.12)], center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.6))
            Wave(level: 0.38, amp: size * 0.025).fill(LinearGradient(colors: [t.opacity(0.75), t], startPoint: .top, endPoint: .bottom))
                .clipShape(Circle())
            Image(systemName: section.symbol).font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(t.mix(.black, 0.15))
                .scaleEffect(1.12)
            Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.9), t.opacity(0.45)], startPoint: .top, endPoint: .bottom), lineWidth: max(0.8, size * 0.035))
            Circle().trim(from: 0.58, to: 0.72).stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: size * 0.04, lineCap: .round))
                .padding(size * 0.12)
        }
        .frame(width: size, height: size)
        .shadow(color: t.opacity(0.3), radius: size * 0.08, y: size * 0.06)
    }

    static func initial(_ name: String) -> String {
        let latin = name.prefix(2).allSatisfy { $0.isASCII && $0.isLetter }
        return latin ? String(name.prefix(2)) : String(name.prefix(1))
    }
}

// 물방울 모양: 위가 뾰족하고 아래가 둥근 모양
struct DropShape: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height, rad = w / 2, cy = r.maxY - rad
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addCurve(to: CGPoint(x: r.maxX, y: cy), control1: CGPoint(x: r.midX + w * 0.12, y: r.minY + h * 0.22), control2: CGPoint(x: r.maxX, y: cy - rad * 0.75))
        p.addArc(center: CGPoint(x: r.midX, y: cy), radius: rad, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        p.addCurve(to: CGPoint(x: r.midX, y: r.minY), control1: CGPoint(x: r.minX, y: cy - rad * 0.75), control2: CGPoint(x: r.midX - w * 0.12, y: r.minY + h * 0.22))
        p.closeSubpath()
        return p
    }
}

// 아래쪽 물(위 가장자리가 물결)
struct Wave: Shape {
    var level: CGFloat   // 0~1, 아래에서부터 높이
    var amp: CGFloat
    func path(in r: CGRect) -> Path {
        var p = Path()
        let y0 = r.maxY - r.height * level
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: y0))
        var x = r.minX
        while x <= r.maxX { p.addLine(to: CGPoint(x: x, y: y0 + amp * sin((x - r.minX) / r.width * .pi * 3))); x += 2 }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

#if DEBUG // 시험 장치(M9)
// 시험용: 세 시안을 모든 분야로 그려 PNG 로(밝은·어두운 바탕)
enum SectionIconLab {
    @MainActor static func render(to dir: String) {
        for dark in [false, true] {
            let view = VStack(alignment: .leading, spacing: 26) {
                ForEach([SectionIcon.Style.drop, .dropSoft, .dropLine], id: \.self) { st in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(["drop": "가-1 · 채움", "dropSoft": "가-2 · 은은한 채움", "dropLine": "가-3 · 선", "dropcap": "나 · 드롭캡", "lens": "다 · 렌즈"][st.rawValue] ?? "")
                            .font(.app(15, .bold))
                        HStack(alignment: .bottom, spacing: 18) {
                            ForEach(Sections.all, id: \.id) { s in
                                VStack(spacing: 7) {
                                    SectionIcon(section: s, style: st, size: 48)
                                    Text(s.name).font(.app(11, .medium)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        HStack(spacing: 10) { // 작은 크기(칩) 미리보기
                            ForEach(Sections.all.prefix(6), id: \.id) { s in
                                HStack(spacing: 5) { SectionIcon(section: s, style: st, size: 18); Text(s.name).font(.app(12, .semibold)) }
                                    .padding(.horizontal, 9).padding(.vertical, 5)
                                    .background(.primary.opacity(0.07), in: Capsule())
                            }
                        }
                    }
                }
            }
            .padding(30)
            .background(dark ? Color(white: 0.12) : Color(white: 0.97))
            .environment(\.colorScheme, dark ? .dark : .light)
            let r = ImageRenderer(content: view); r.scale = 2
            if let cg = r.cgImage {
                try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "\(dir)/icons-\(dark ? "dark" : "light").png"))
            }
        }
        NSLog("[아이콘 시험] 끝")
    }
}
#endif
