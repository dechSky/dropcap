// 카드 안에 물이 찰랑찰랑 차오르는 모습(맥 Toast/WaterFill.swift, N-03).
// 떨어진 물방울이 바닥에 튀고 → 물높이가 아래에서 위로 차오르며 물결이 좌우로 출렁이고 → 가득 차면 잔잔해진다.
// 가득 찬 뒤에는 옅은 물이 남아, 남은 시간만큼 천천히 빠진다(N-07).
use gtk::cairo;

pub const FILL_TIME: f64 = 0.75;

fn smooth(x: f64) -> f64 {
    let u = x.clamp(0.0, 1.0);
    u * u * (3.0 - 2.0 * u)
}

pub fn mix(a: (f64, f64, f64), b: (f64, f64, f64), t: f64) -> (f64, f64, f64) {
    (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
}

const WHITE: (f64, f64, f64) = (1.0, 1.0, 1.0);

// e = 물방울이 바닥에 닿은 뒤 지난 초, level = 가득 찬 뒤의 물높이(남은 시간 0~1)
pub fn draw(cr: &cairo::Context, w: f64, h: f64, e: f64, color: (f64, f64, f64), level: f64) {
    let f = FILL_TIME;
    let filling = e < f;
    let fill = 1.0 - (1.0 - (e / f).clamp(0.0, 1.0)).powi(3); // 처음엔 빠르게, 끝에서 천천히
    let lvl = if filling { fill } else { fill.min(level) };

    // 물결: 차오르는 동안 크게 출렁이다 잔잔해지고, 평소엔 아주 작게 일렁인다
    let amp = 4.5 * (-2.2 * e).exp() + 0.9;
    let tilt = 0.05 * (e * 7.5).sin() * (-1.6 * e).exp(); // 좌우로 기우뚱
    // 글자가 물과 함께 떠오르므로 물빛은 옅게 시작하고, 다 차면 더 맑게
    let alpha = 0.4 - 0.27 * smooth((e - f * 0.6) / 0.45);
    let base = h * (1.0 - lvl);

    let wave = |phase: f64, length: f64, amp_scale: f64| {
        cr.new_path();
        cr.move_to(0.0, h);
        let mut x = 0.0;
        while x <= w + 4.0 {
            let y = base + amp * amp_scale * ((x / length) * std::f64::consts::TAU + phase).sin() + tilt * (x - w / 2.0);
            cr.line_to(x, y);
            x += 4.0;
        }
        cr.line_to(w, h);
        cr.close_path();
    };

    // 뒷물결(옅게, 엇박자) + 앞물결
    wave(e * 2.4 + 1.7, w * 0.62, 0.8);
    cr.set_source_rgba(color.0, color.1, color.2, alpha * 0.5);
    let _ = cr.fill();
    wave(e * 3.2, w * 0.48, 1.0);
    let light = mix(color, WHITE, 0.35);
    let g = cairo::LinearGradient::new(0.0, base, 0.0, h);
    g.add_color_stop_rgba(0.0, light.0, light.1, light.2, alpha);
    g.add_color_stop_rgba(1.0, color.0, color.1, color.2, (alpha * 1.1).min(1.0));
    let _ = cr.set_source(&g);
    let _ = cr.fill();

    // 물 표면의 반짝이는 선
    if lvl > 0.02 && lvl < 0.995 {
        cr.new_path();
        let mut x = 0.0;
        while x <= w + 4.0 {
            let y = base + amp * ((x / (w * 0.48)) * std::f64::consts::TAU + e * 3.2).sin() + tilt * (x - w / 2.0);
            if x == 0.0 {
                cr.move_to(x, y);
            } else {
                cr.line_to(x, y);
            }
            x += 4.0;
        }
        cr.set_source_rgba(1.0, 1.0, 1.0, (0.55 * alpha / 0.5).min(1.0));
        cr.set_line_width(1.0);
        let _ = cr.stroke();
    }

    // 바닥에 닿을 때 튀어 오르는 작은 물방울 4개
    if e < 0.42 {
        let gr = 900.0;
        let spl = mix(color, WHITE, 0.3);
        for (vx, vy, r) in [(-70.0, 210.0, 2.2), (55.0, 240.0, 1.8), (10.0, 270.0, 1.5), (-25.0, 180.0, 1.4)] {
            let x = w / 2.0 + vx * e;
            let y = h - (vy * e - 0.5 * gr * e * e) - 2.0;
            if y >= h {
                continue;
            }
            let a = 0.75 * (1.0 - e / 0.42);
            cr.arc(x, y, r, 0.0, std::f64::consts::TAU);
            cr.set_source_rgba(spl.0, spl.1, spl.2, a);
            let _ = cr.fill();
        }
    }

    // 물속에서 올라오는 작은 거품 5개
    if e > 0.12 && e < 1.6 {
        let bubbles = [(0.18, 0.12, 1.6, 70.0), (0.33, 0.30, 2.4, 60.0), (0.52, 0.18, 1.3, 85.0), (0.68, 0.40, 2.0, 65.0), (0.84, 0.25, 1.5, 75.0)];
        for (bx, delay, r, speed) in bubbles {
            if e <= delay {
                continue;
            }
            let k = e - delay;
            let y = h - 4.0 - speed * k;
            if y <= base + 3.0 {
                continue;
            }
            let x = bx * w + (k * 9.0 + bx * 10.0).sin() * 2.0;
            let a = 0.6 * (1.0 - smooth((e - 1.1) / 0.5));
            cr.new_path();
            cr.arc(x, y, r, 0.0, std::f64::consts::TAU);
            cr.set_source_rgba(1.0, 1.0, 1.0, a);
            cr.set_line_width(0.8);
            let _ = cr.stroke();
        }
    }
}
