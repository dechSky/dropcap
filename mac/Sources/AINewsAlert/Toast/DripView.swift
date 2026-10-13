import SwiftUI

// 천장(상단바 아래 가장자리)에 물이 맺혀 → 부풀고 → 목이 늘어나다 → 톡 끊어져 떨어지는 모습.
// 덩어리 몇 개를 흐리게 그린 뒤 경계만 또렷하게 잘라내면(알파 문턱값) 서로 가까운 덩어리가 액체처럼 이어져,
// 목이 생기고 끊어지는 모양이 저절로 나온다.
struct DripView: View {
    let start: Date
    let color: Color
    let landY: CGFloat        // 떨어진 물방울 중심이 닿을 높이(이 보기 위쪽 기준)
    var dark = false          // 노치에서 떨어질 때는 검은 물
    static let width: CGFloat = 120

    // 시간표(초)
    static let swell = 0.62     // 맺혀서 부푸는 시간
    static let sag = 0.30       // 무게로 처지며 목이 늘어나는 시간
    static var detach: Double { swell + sag }
    static let gravity: CGFloat = 2600 // 화면에서 보기 좋게 빠르게 한 중력(pt/s²)
    static let dropRadius: CGFloat = 15

    // 떨어지기 시작해서 닿을 때까지 걸리는 시간
    static func fallTime(from y0: CGFloat, to y1: CGFloat) -> Double { Double(sqrt(2 * max(0, y1 - y0) / gravity)) }
    static var detachY: CGFloat { 9 + dropRadius + 13 }
    static func landingTime(_ landY: CGFloat) -> Double { detach + fallTime(from: detachY, to: landY) }

    var body: some View {
        Group {
            if #available(macOS 26.0, *) { glassBody } else { canvasBody }
        }
        .frame(width: Self.width, height: landY + Self.dropRadius * 2, alignment: .top)
        .allowsHitTesting(false)
    }

    // macOS 26: 진짜 유리(Liquid Glass) 물방울. 뒤의 화면이 렌즈처럼 굴절돼 비치고,
    // 같은 그릇(GlassEffectContainer) 안의 유리끼리는 가까우면 붙고 멀어지면 목이 늘어나다 끊어진다.
    @available(macOS 26.0, *)
    private var glassBody: some View {
        TimelineView(.animation) { tl in
            let s = state(at: tl.date.timeIntervalSince(start))
            let glass = Glass.clear.tint(dark ? Color.black.opacity(0.85) : color.opacity(0.22))
            let cx = Self.width / 2
            // 유리는 '그려지는 자리'가 아니라 '배치된 자리'를 기준으로 렌더링된다.
            // 그래서 offset 대신 position(배치)으로 놓아야 물방울·반사광·카드 착지점이 같은 좌표를 쓴다.
            GlassEffectContainer(spacing: 18) {
                ZStack(alignment: .topLeading) {
                    Color.clear
                    if s.film > 0 { blob(44 * s.film, 12, center: CGPoint(x: cx, y: -1), glass) }
                    if s.beadR > 0.5 { blob(s.beadR * 2.3, s.beadR * 1.6, center: CGPoint(x: cx, y: s.beadR * 0.45), glass) }
                    if s.dropR > 0.5 {
                        let w = s.dropR * 2 / sqrt(s.stretch), h = s.dropR * 2 * s.stretch
                        blob(w, h, center: CGPoint(x: cx, y: s.dropY), glass)
                    }
                    if s.satR > 0.5 { blob(s.satR * 2, s.satR * 2, center: CGPoint(x: cx, y: s.satY), glass) }
                }
                .frame(width: Self.width, height: landY + Self.dropRadius * 2)
            }
            .overlay(alignment: .top) { highlight(s) }
        }
    }

    @available(macOS 26.0, *)
    private func blob(_ w: CGFloat, _ h: CGFloat, center: CGPoint, _ glass: Glass) -> some View {
        Group {
            // 시험용: AINEWS_DEBUG_DRIP=1 이면 유리 대신 보이는 색으로(캡처로 자리 확인)
            if Self.debugFill {
                Ellipse().fill(Color.red.opacity(0.8)).frame(width: max(w, 1), height: max(h, 1))
            } else {
                Color.clear.frame(width: max(w, 1), height: max(h, 1)).glassEffect(glass, in: Ellipse())
            }
        }
        .position(center)
    }
    private static let debugFill = ProcessInfo.processInfo.environment["AINEWS_DEBUG_DRIP"] == "1"

    // 물방울 위쪽의 반짝이는 반사광과 아래쪽의 맺힌 빛
    private func highlight(_ s: S) -> some View {
        ZStack(alignment: .top) {
            if s.dropR > 6 {
                let r = s.dropR
                Ellipse().fill(.white.opacity(0.8)).frame(width: 5.2, height: 6.8)
                    .offset(x: -r * 0.38 / sqrt(s.stretch), y: s.dropY - r * 0.35 * s.stretch - 3.4)
                Circle().fill(.white.opacity(0.4)).frame(width: 2.6, height: 2.6)
                    .offset(x: r * 0.3, y: s.dropY + r * 0.38 * s.stretch - 1.3)
            }
        }
        .frame(width: Self.width, alignment: .top)
    }

    // macOS 26 미만: 흐림 + 문턱값으로 그린 액체
    private var canvasBody: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSince(start)
            Canvas { ctx, size in
                let cx = size.width / 2
                let s = state(at: t)

                // 액체 덩어리들: 흐리게 → 문턱값으로 또렷하게
                ctx.drawLayer { g in
                    g.addFilter(.alphaThreshold(min: 0.5, color: color))
                    g.addFilter(.blur(radius: 4.5))
                    g.drawLayer { l in
                        // 천장에 젖은 얇은 막
                        if s.film > 0 {
                            l.fill(Path(ellipseIn: CGRect(x: cx - 22 * s.film, y: -7, width: 44 * s.film, height: 12)), with: .color(.black))
                        }
                        // 천장에 붙은 물 (떨어지고 나면 출렁이며 다시 빨려 올라감)
                        if s.beadR > 0.5 {
                            l.fill(Path(ellipseIn: CGRect(x: cx - s.beadR * 1.15, y: -s.beadR * 0.35, width: s.beadR * 2.3, height: s.beadR * 1.6)), with: .color(.black))
                        }
                        // 목: 두 덩어리 사이를 잇는 가는 기둥
                        if s.neck > 0.3 {
                            let top = s.beadR * 0.8, bottom = s.dropY - s.dropR * 0.6
                            if bottom > top {
                                l.fill(Path(roundedRect: CGRect(x: cx - s.neck, y: top, width: s.neck * 2, height: bottom - top), cornerRadius: s.neck), with: .color(.black))
                            }
                        }
                        // 물방울: 떨어지는 속도만큼 세로로 길어진다
                        if s.dropR > 0.5 {
                            let w = s.dropR * 2 / sqrt(s.stretch), h = s.dropR * 2 * s.stretch
                            l.fill(Path(ellipseIn: CGRect(x: cx - w / 2, y: s.dropY - h / 2, width: w, height: h)), with: .color(.black))
                        }
                        // 끊어질 때 생기는 작은 물방울
                        if s.satR > 0.5 {
                            l.fill(Path(ellipseIn: CGRect(x: cx - s.satR, y: s.satY - s.satR, width: s.satR * 2, height: s.satR * 2)), with: .color(.black))
                        }
                    }
                }
                // 반사광(액체 위에 덧그림)
                if s.dropR > 6 {
                    let r = s.dropR
                    let hx = cx - r * 0.38 / sqrt(s.stretch), hy = s.dropY - r * 0.35 * s.stretch
                    ctx.fill(Path(ellipseIn: CGRect(x: hx - 2.6, y: hy - 3.4, width: 5.2, height: 6.8)), with: .color(.white.opacity(0.75)))
                    ctx.fill(Path(ellipseIn: CGRect(x: cx + r * 0.3 - 1.2, y: s.dropY + r * 0.35 * s.stretch - 1.2, width: 2.4, height: 2.4)), with: .color(.white.opacity(0.35)))
                }
            }
        }
    }

    private struct S {
        var film: CGFloat = 0, beadR: CGFloat = 0, neck: CGFloat = 0
        var dropR: CGFloat = 0, dropY: CGFloat = 0, stretch: CGFloat = 1
        var satR: CGFloat = 0, satY: CGFloat = 0
    }

    private func state(at t: Double) -> S {
        var s = S()
        let R = Self.dropRadius
        let ease = { (x: Double) -> CGFloat in CGFloat(1 - pow(1 - min(max(x, 0), 1), 3)) }
        let smooth = { (a: Double, b: Double, x: Double) -> CGFloat in
            let u = min(max((x - a) / (b - a), 0), 1); return CGFloat(u * u * (3 - 2 * u))
        }

        if t < Self.detach {
            // 맺힘 → 부풂
            let g = ease(t / Self.swell)
            s.film = min(1, CGFloat(t / 0.18))
            s.beadR = 4 + 6 * g
            s.dropR = 3 + (R - 3) * g
            // 숨 쉬듯 살짝 떨림
            let wobble = CGFloat(sin(t * 26) * 0.6) * (1 - smooth(0, Self.swell, t)) * g
            s.dropR += wobble
            // 처짐: 아래로 늘어나며 목이 생기고 가늘어진다
            let sag = smooth(Self.swell * 0.7, Self.detach, t)
            s.dropY = 9 + s.dropR * 0.85 + 13 * sag
            s.neck = (3.6 - 2.4 * sag) * g
            s.stretch = 1 + 0.08 * sag
        } else {
            // 떨어짐: 점점 빨라지고, 속도만큼 길어진다
            let dt = t - Self.detach
            let v = Self.gravity * CGFloat(dt)
            s.dropR = R
            s.dropY = Self.detachY + 0.5 * Self.gravity * CGFloat(dt * dt)
            s.stretch = 1 + min(0.32, v / 1500)
            if s.dropY >= landY { s.dropR = 0 } // 닿는 순간부터는 카드의 물방울이 이어받는다
            // 천장에 남은 물: 위로 튕겼다가 출렁이며 사라짐
            let k = dt
            s.film = max(0, 1 - CGFloat(k / 0.5))
            s.beadR = max(0, (7 + 3 * CGFloat(exp(-k * 7) * cos(k * 34))) * (1 - CGFloat(k / 0.55)))
            // 작은 물방울: 끊어진 목에서 생겨 뒤따라 떨어지다 사라짐
            if k < 0.22 {
                s.satR = 4.6 * (1 - CGFloat(k / 0.22))
                s.satY = 20 + 0.5 * Self.gravity * 0.55 * CGFloat(k * k)
            }
        }
        return s
    }
}
