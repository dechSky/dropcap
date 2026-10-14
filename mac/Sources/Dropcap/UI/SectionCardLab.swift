import AppKit
import SwiftUI

// 시험용: 분야 고르기 카드를 세 방식으로 — 분야마다 오늘 들어온 진짜 기사 사진을 얼굴로 쓴다.
// 가) 사진 타일(Pinterest·Netflix) 나) 색면 + 기울인 사진(Spotify 장르 카드) 다) 타이포그래피(잡지 섹션 머리)
enum SectionCardLab {
    // 분야마다 가장 최근의 사진 있는 기사
    @MainActor static func photos() async -> [String: (NewsItem, NSImage)] {
        var out: [String: (NewsItem, NSImage)] = [:]
        let items = Database.shared.items(from: Date().addingTimeInterval(-3 * 86400), limit: 3000).map(\.item)
        for s in Sections.all {
            guard let got = await SectionPhoto.pick(items.filter { $0.inSection(s.id) }) else { continue }
            out[s.id] = (got.item, got.image)
        }
        return out
    }

    @MainActor static func render(to dir: String) async {
        let ph = await photos()
        NSLog("[카드 시험] 사진 있는 분야 %d/%d", ph.count, Sections.all.count)
        let secs = Sections.all.filter { !$0.isFlow }
        let only = ProcessInfo.processInfo.environment["DROPCAP_TEST_CARDLAB_STYLES"].map { Set($0.split(separator: ",").map(String.init)) }
        for (name, style) in [("photo", 0), ("color", 1), ("type", 2), ("glow", 3), ("mesh", 4), ("glass", 5)] where only?.contains(name) ?? true {
            let view = VStack(alignment: .leading, spacing: 16) {
                Text(["가 · 사진 타일", "나 · 색면 + 기울인 사진", "다 · 타이포그래피", "나-1 · 빛 번짐", "나-2 · 메시 그라데이션", "나-3 · 유리"][style]).font(.app(16, .bold))
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(196), spacing: 14), count: 4), spacing: 14) {
                    ForEach(Array(secs.enumerated()), id: \.element.id) { i, s in
                        card(s, ph[s.id], style: style, selected: [1, 4, 6].contains(i))
                    }
                }
            }
            .padding(28).frame(width: 28 * 2 + 196 * 4 + 14 * 3)
            .background(Color(white: 0.11)).environment(\.colorScheme, .dark)
            let r = ImageRenderer(content: view); r.scale = 2
            if let cg = r.cgImage { try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/cards-\(name).png")) }
        }
        NSLog("[카드 시험] 끝")
    }

    @ViewBuilder static func card(_ s: NewsSection, _ p: (NewsItem, NSImage)?, style: Int, selected: Bool) -> some View {
        let t = s.tint
        switch style {
        case 0: // 사진 타일: 사진 전체 + 아래 어둡게 + 이름, 고르면 분야색 테두리와 체크
            ZStack(alignment: .bottomLeading) {
                if let p { Image(nsImage: p.1).resizable().aspectRatio(contentMode: .fill) } else { t.opacity(0.4) }
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name).font(.app(17, .heavy))
                    if let p { Text(p.0.displayTitle).font(.app(10.5)).lineLimit(1).opacity(0.75) }
                }
                .foregroundStyle(.white).padding(12)
            }
            .frame(width: 196, height: 130).clipped()
            .overlay(alignment: .topTrailing) { check(selected, t).padding(9) }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(selected ? t : .clear, lineWidth: 3))
        case 1: // 색면 + 기울인 사진(오른쪽 아래)
            ZStack(alignment: .topLeading) {
                t.mix(.black, 0.12)
                if let p {
                    Image(nsImage: p.1).resizable().aspectRatio(contentMode: .fill).frame(width: 92, height: 92)
                        .clipShape(RoundedRectangle(cornerRadius: 6)).shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                        .rotationEffect(.degrees(24)).offset(x: 122, y: 52)
                }
                Text(s.name).font(.app(19, .heavy)).foregroundStyle(.white).padding(13)
            }
            .frame(width: 196, height: 130).clipped()
            .overlay(alignment: .bottomLeading) { check(selected, .white).padding(10) }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(selected ? 1 : 0.88)
        case 3: // 나-1 빛 번짐: 대각선 그라데이션 + 모서리 빛 + 윗면 광택 + 흰 테두리 사진
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [shift(t, hue: -0.03, bri: 0.12), t, shift(t, hue: 0.05, bri: -0.28)], startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [.white.opacity(0.35), .clear], center: UnitPoint(x: 0.12, y: 0.05), startRadius: 0, endRadius: 120)
                RadialGradient(colors: [shift(t, hue: 0.08, bri: 0.2).opacity(0.7), .clear], center: UnitPoint(x: 0.95, y: 1.0), startRadius: 0, endRadius: 110)
                LinearGradient(colors: [.white.opacity(0.18), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.35))
                if let p { tilted(p.1, frame: true).offset(x: 118, y: 46) }
                Text(s.name).font(.app(19, .heavy)).foregroundStyle(.white).shadow(color: .black.opacity(0.18), radius: 3, y: 1).padding(13)
            }
            .frame(width: 196, height: 130).clipped()
            .overlay(alignment: .bottomLeading) { check(selected, .white).padding(10) }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(selected ? 0.9 : 0.18), lineWidth: selected ? 2.5 : 1))
            .shadow(color: t.opacity(selected ? 0.55 : 0.25), radius: selected ? 14 : 8, y: 5)
        case 4: // 나-2 메시 그라데이션: 이웃 색이 섞인 물감 + 입자 + 큰 영문 워터마크
            ZStack(alignment: .topLeading) {
                t
                Canvas { ctx, size in
                    ctx.addFilter(.blur(radius: 26))
                    let blobs: [(CGPoint, CGFloat, Color)] = [
                        (CGPoint(x: size.width * 0.1, y: size.height * 0.1), 90, shift(t, hue: -0.06, bri: 0.15)),
                        (CGPoint(x: size.width * 0.9, y: size.height * 0.2), 80, shift(t, hue: 0.07, sat: -0.1, bri: 0.05)),
                        (CGPoint(x: size.width * 0.75, y: size.height * 0.95), 95, shift(t, hue: 0.12, bri: -0.25)),
                        (CGPoint(x: size.width * 0.15, y: size.height * 0.95), 70, shift(t, hue: -0.1, bri: -0.1))]
                    for (c, r, col) in blobs { ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(col)) }
                }
                Canvas { ctx, size in // 고운 입자
                    var g = SystemRandomNumberGenerator()
                    for _ in 0..<900 { let x = CGFloat.random(in: 0...size.width, using: &g), y = CGFloat.random(in: 0...size.height, using: &g)
                        ctx.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)), with: .color(.white.opacity(Double.random(in: 0.04...0.14, using: &g)))) }
                }
                Text(english(s.id)).font(.system(size: 44, weight: .black, design: .rounded)).foregroundStyle(.white.opacity(0.1))
                    .fixedSize().rotationEffect(.degrees(-8)).offset(x: -6, y: 70)
                if let p { tilted(p.1, frame: false).offset(x: 122, y: 50) }
                Text(s.name).font(.app(19, .heavy)).foregroundStyle(.white).padding(13)
            }
            .frame(width: 196, height: 130).clipped()
            .overlay(alignment: .bottomLeading) { check(selected, .white).padding(10) }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(selected ? 0.9 : 0.12), lineWidth: selected ? 2.5 : 1))
        case 5: // 나-3 유리: 흐린 사진 바탕 + 분야색 유리판
            ZStack(alignment: .topLeading) {
                if let p { Image(nsImage: p.1).resizable().aspectRatio(contentMode: .fill).frame(width: 196, height: 130).blur(radius: 10).saturation(1.2) } else { t }
                LinearGradient(colors: [t.opacity(0.85), shift(t, hue: 0.05, bri: -0.2).opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.1))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
                    .padding(8)
                if let p { tilted(p.1, frame: true).offset(x: 118, y: 46) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(english(s.id)).font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.4).opacity(0.8)
                    Text(s.name).font(.app(19, .heavy))
                }
                .foregroundStyle(.white).padding(16)
            }
            .frame(width: 196, height: 130).clipped()
            .overlay(alignment: .bottomLeading) { check(selected, .white).padding(14) }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: t.opacity(0.35), radius: 8, y: 4)
        default: // 타이포그래피: 영문 섹션명(고정폭 대문자) + 한글 큰 이름 + 오늘의 머리기사 한 줄 + 분야색 줄
            VStack(alignment: .leading, spacing: 6) {
                Text(english(s.id)).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.6).foregroundStyle(t)
                Text(s.name).font(.custom("AppleMyungjo", size: 26).weight(.heavy)).foregroundStyle(.primary)
                Rectangle().fill(t).frame(width: 28, height: 2.5)
                Text(p?.0.displayTitle ?? " ").font(.app(11)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(14).frame(width: 196, height: 130, alignment: .topLeading)
            .background(selected ? t.opacity(0.14) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? t.opacity(0.8) : .primary.opacity(0.08), lineWidth: selected ? 1.5 : 1))
            .overlay(alignment: .topTrailing) { check(selected, t).padding(10) }
        }
    }

    static func tilted(_ img: NSImage, frame: Bool) -> some View {
        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).allowsHitTesting(false).frame(width: 90, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: frame ? 4 : 7))
            .padding(frame ? 4 : 0).background(frame ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
            .rotationEffect(.degrees(20))
    }

    // 분야 색을 색상·채도·밝기로 조금 옮긴 색(그라데이션용)
    static func shift(_ c: Color, hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0) -> Color {
        let n = NSColor(c).usingColorSpace(.deviceRGB) ?? .gray
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        n.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: Double((h + hue + 1).truncatingRemainder(dividingBy: 1)), saturation: Double(min(1, max(0, s + sat))), brightness: Double(min(1, max(0, b + bri))))
    }

    static func check(_ on: Bool, _ c: Color) -> some View {
        Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.system(size: 18, weight: .semibold))
            .foregroundStyle(on ? c : .white.opacity(0.7)).shadow(color: .black.opacity(0.3), radius: 2)
    }

    static func english(_ id: String) -> String {
        ["politics": "POLITICS", "economy": "ECONOMY", "society": "SOCIETY", "world": "WORLD", "tech": "TECH", "ai": "AI",
         "science": "SCIENCE", "life": "LIFE · HEALTH", "culture": "CULTURE", "sports": "SPORTS", "climate": "CLIMATE"][id] ?? id.uppercased()
    }
}
