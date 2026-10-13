import SwiftUI

// 카드 안에 물이 찰랑찰랑 차오르는 모습.
// 떨어진 물방울이 바닥에 튀고 → 물높이가 아래에서 위로 차오르며 물결이 좌우로 출렁이고 → 가득 차면 잔잔해진다.
// 가득 찬 뒤에는 옅은 물이 남아, 남은 시간만큼 천천히 빠진다(시간 표시 대신).
struct WaterFill: View {
    let start: Date          // 물방울이 바닥에 닿은 때
    let color: Color
    let level: Double        // 가득 찬 뒤의 물높이(남은 시간, 0~1)
    var calm = false         // 잔잔해진 뒤에는 초당 12번만 다시 그림(전기·CPU 절약)

    static let fillTime = 0.75

    var body: some View {
        TimelineView(.animation(minimumInterval: calm ? 1.0 / 12 : nil)) { tl in
            let e = tl.date.timeIntervalSince(start)
            Canvas { ctx, size in
                draw(&ctx, size, e)
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize, _ e: Double) {
        let w = size.width, h = size.height
        let F = Self.fillTime
        let filling = e < F
        let fill = 1 - pow(1 - min(max(e / F, 0), 1), 3) // 처음엔 빠르게, 끝에서 천천히
        let lvl = CGFloat(filling ? fill : min(fill, level))

        // 물결: 차오르는 동안 크게 출렁이다 잔잔해지고, 평소엔 아주 작게 일렁인다
        let amp = CGFloat(4.5 * exp(-2.2 * e) + 0.9)
        let tilt = CGFloat(0.05 * sin(e * 7.5) * exp(-1.6 * e)) // 좌우로 기우뚱
        // 글자가 물과 함께 떠오르므로 물빛은 옅게 시작하고, 다 차면 더 맑게
        let alpha = 0.4 - 0.27 * smooth((e - F * 0.6) / 0.45)

        func wave(phase: Double, length: CGFloat, ampScale: CGFloat) -> Path {
            var p = Path()
            let base = h * (1 - lvl)
            p.move(to: CGPoint(x: 0, y: h))
            var x: CGFloat = 0
            while x <= w + 4 {
                let y = base + amp * ampScale * CGFloat(sin(Double(x / length) * 2 * .pi + phase)) + tilt * (x - w / 2)
                p.addLine(to: CGPoint(x: x, y: y))
                x += 4
            }
            p.addLine(to: CGPoint(x: w, y: h))
            p.closeSubpath()
            return p
        }

        // 뒷물결(옅게, 엇박자) + 앞물결
        let back = wave(phase: e * 2.4 + 1.7, length: w * 0.62, ampScale: 0.8)
        ctx.fill(back, with: .color(color.opacity(alpha * 0.5)))
        let front = wave(phase: e * 3.2, length: w * 0.48, ampScale: 1)
        ctx.fill(front, with: .linearGradient(
            Gradient(colors: [color.mix(.white, 0.35).opacity(alpha), color.opacity(alpha * 1.1)]),
            startPoint: CGPoint(x: 0, y: h * (1 - lvl)), endPoint: CGPoint(x: 0, y: h)))

        // 물 표면의 반짝이는 선
        if lvl > 0.02 && lvl < 0.995 {
            var surface = Path()
            var x: CGFloat = 0
            let base = h * (1 - lvl)
            while x <= w + 4 {
                let y = base + amp * CGFloat(sin(Double(x / (w * 0.48)) * 2 * .pi + e * 3.2)) + tilt * (x - w / 2)
                if x == 0 { surface.move(to: CGPoint(x: x, y: y)) } else { surface.addLine(to: CGPoint(x: x, y: y)) }
                x += 4
            }
            ctx.stroke(surface, with: .color(.white.opacity(0.55 * alpha / 0.5)), lineWidth: 1)
        }

        // 바닥에 닿을 때 튀어 오르는 작은 물방울
        if e < 0.42 {
            let g = 900.0
            for (vx, vy, r) in [(-70.0, 210.0, 2.2), (55.0, 240.0, 1.8), (10.0, 270.0, 1.5), (-25.0, 180.0, 1.4)] {
                let x = w / 2 + CGFloat(vx * e)
                let y = h - CGFloat(vy * e - 0.5 * g * e * e) - 2
                guard y < h else { continue }
                let a = 0.75 * (1 - e / 0.42)
                ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(color.mix(.white, 0.3).opacity(a)))
            }
        }

        // 물속에서 올라오는 작은 거품
        if e > 0.12 && e < 1.6 {
            let bubbles: [(x: CGFloat, delay: Double, r: CGFloat, speed: CGFloat)] = [
                (0.18, 0.12, 1.6, 70), (0.33, 0.30, 2.4, 60), (0.52, 0.18, 1.3, 85), (0.68, 0.40, 2.0, 65), (0.84, 0.25, 1.5, 75),
            ]
            let top = h * (1 - lvl)
            for b in bubbles where e > b.delay {
                let k = e - b.delay
                let y = h - 4 - b.speed * CGFloat(k)
                guard y > top + 3 else { continue }
                let x = b.x * w + CGFloat(sin(k * 9 + Double(b.x) * 10)) * 2
                let a = 0.6 * (1 - smooth((e - 1.1) / 0.5))
                ctx.stroke(Path(ellipseIn: CGRect(x: x - b.r, y: y - b.r, width: b.r * 2, height: b.r * 2)), with: .color(.white.opacity(a)), lineWidth: 0.8)
            }
        }
    }

    private func smooth(_ x: Double) -> Double {
        let u = min(max(x, 0), 1)
        return u * u * (3 - 2 * u)
    }
}
