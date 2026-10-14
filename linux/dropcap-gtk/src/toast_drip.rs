// 천장에 물이 맺혀 → 부풀고 → 목이 늘어나다 → 톡 끊어져 떨어지는 모습(맥 Toast/DripView.swift 의 canvasBody 방식, N-01·N-02·N-21).
// 덩어리 몇 개를 흐리게 그린 뒤 경계만 또렷하게 잘라내면(알파 문턱값) 가까운 덩어리가 액체처럼 이어져,
// 목이 생기고 끊어지는 모양이 저절로 나온다. 같은 모양이면 다시 계산하지 않고 기억해 둔 그림을 쓴다.
use gtk::cairo;

pub const WIDTH: f64 = 120.0;
pub const SWELL: f64 = 0.45; // 맺혀서 부푸는 시간
pub const SAG: f64 = 0.22; // 무게로 처지며 목이 늘어나는 시간
pub const DETACH: f64 = SWELL + SAG;
pub const GRAVITY: f64 = 2600.0; // pt/s²
pub const DROP_RADIUS: f64 = 15.0;
pub const DETACH_Y: f64 = 9.0 + DROP_RADIUS + 13.0;
const BLUR: f64 = 4.5;

pub fn fall_time(y0: f64, y1: f64) -> f64 {
    (2.0 * (y1 - y0).max(0.0) / GRAVITY).sqrt()
}

pub fn landing_time(land_y: f64) -> f64 {
    DETACH + fall_time(DETACH_Y, land_y)
}

#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct S {
    pub film: f64,
    pub bead_r: f64,
    pub neck: f64,
    pub drop_r: f64,
    pub drop_y: f64,
    pub stretch: f64,
    pub sat_r: f64,
    pub sat_y: f64,
}

pub fn state(t: f64, land_y: f64) -> S {
    let mut s = S { stretch: 1.0, ..Default::default() };
    let r = DROP_RADIUS;
    let ease = |x: f64| 1.0 - (1.0 - x.clamp(0.0, 1.0)).powi(3);
    let smooth = |a: f64, b: f64, x: f64| {
        let u = ((x - a) / (b - a)).clamp(0.0, 1.0);
        u * u * (3.0 - 2.0 * u)
    };
    if t < DETACH {
        // 맺힘 → 부풂
        let g = ease(t / SWELL);
        s.film = (t / 0.18).min(1.0);
        s.bead_r = 4.0 + 6.0 * g;
        s.drop_r = 3.0 + (r - 3.0) * g;
        // 숨 쉬듯 살짝 떨림
        s.drop_r += (t * 26.0).sin() * 0.6 * (1.0 - smooth(0.0, SWELL, t)) * g;
        // 처짐: 아래로 늘어나며 목이 생기고 가늘어진다
        let sag = smooth(SWELL * 0.7, DETACH, t);
        s.drop_y = 9.0 + s.drop_r * 0.85 + 13.0 * sag;
        s.neck = (3.6 - 2.4 * sag) * g;
        s.stretch = 1.0 + 0.08 * sag;
    } else {
        // 떨어짐: 점점 빨라지고, 속도만큼 길어진다
        let dt = t - DETACH;
        let v = GRAVITY * dt;
        s.drop_r = r;
        s.drop_y = DETACH_Y + 0.5 * GRAVITY * dt * dt;
        s.stretch = 1.0 + (v / 1500.0).min(0.32);
        if s.drop_y >= land_y {
            s.drop_r = 0.0; // 닿는 순간부터는 카드의 물이 이어받는다
        }
        // 천장에 남은 물: 위로 튕겼다가 출렁이며 사라짐
        let k = dt;
        s.film = (1.0 - k / 0.5).max(0.0);
        s.bead_r = ((7.0 + 3.0 * (-k * 7.0).exp() * (k * 34.0).cos()) * (1.0 - k / 0.55)).max(0.0);
        // 작은 물방울: 끊어진 목에서 생겨 뒤따라 떨어지다 사라짐
        if k < 0.22 {
            s.sat_r = 4.6 * (1.0 - k / 0.22);
            s.sat_y = 20.0 + 0.5 * GRAVITY * 0.55 * k * k;
        }
    }
    s
}

// 같은 모양인지 비교하는 열쇠(0.25 화소 단위)
pub fn key(s: &S, land_y: f64, color: (f64, f64, f64)) -> [i64; 12] {
    let q = |v: f64| (v * 4.0).round() as i64;
    [q(s.film), q(s.bead_r), q(s.neck), q(s.drop_r), q(s.drop_y), q(s.stretch * 10.0), q(s.sat_r), q(s.sat_y), q(land_y), q(color.0 * 64.0), q(color.1 * 64.0), q(color.2 * 64.0)]
}

pub fn visible(s: &S) -> bool {
    s.film > 0.0 || s.bead_r > 0.5 || s.drop_r > 0.5 || s.sat_r > 0.5
}

// 흐림 + 문턱값으로 그린 액체 한 장(WIDTH × 높이, 화면 배율 scale 만큼 촘촘히)
pub fn render(s: &S, land_y: f64, color: (f64, f64, f64), scale: f64) -> Option<cairo::ImageSurface> {
    let w = (WIDTH * scale).ceil() as i32;
    let h = ((land_y + DROP_RADIUS * 2.0) * scale).ceil() as i32;
    if w <= 0 || h <= 0 {
        return None;
    }
    // 1) 덩어리를 A8 에 또렷하게
    let mut mask = cairo::ImageSurface::create(cairo::Format::A8, w, h).ok()?;
    {
        let cr = cairo::Context::new(&mask).ok()?;
        cr.scale(scale, scale);
        cr.set_source_rgba(0.0, 0.0, 0.0, 1.0);
        let cx = WIDTH / 2.0;
        let ellipse = |cr: &cairo::Context, x: f64, y: f64, ew: f64, eh: f64| {
            if ew <= 0.0 || eh <= 0.0 {
                return;
            }
            cr.save().ok();
            cr.translate(x + ew / 2.0, y + eh / 2.0);
            cr.scale(ew / 2.0, eh / 2.0);
            cr.arc(0.0, 0.0, 1.0, 0.0, std::f64::consts::TAU);
            cr.restore().ok();
            let _ = cr.fill();
        };
        // 천장에 젖은 얇은 막
        if s.film > 0.0 {
            ellipse(&cr, cx - 22.0 * s.film, -7.0, 44.0 * s.film, 12.0);
        }
        // 천장에 붙은 물
        if s.bead_r > 0.5 {
            ellipse(&cr, cx - s.bead_r * 1.15, -s.bead_r * 0.35, s.bead_r * 2.3, s.bead_r * 1.6);
        }
        // 목: 두 덩어리 사이를 잇는 가는 기둥
        if s.neck > 0.3 {
            let top = s.bead_r * 0.8;
            let bottom = s.drop_y - s.drop_r * 0.6;
            if bottom > top {
                rounded(&cr, cx - s.neck, top, s.neck * 2.0, bottom - top, s.neck);
                let _ = cr.fill();
            }
        }
        // 물방울: 떨어지는 속도만큼 세로로 길어진다
        if s.drop_r > 0.5 {
            let ew = s.drop_r * 2.0 / s.stretch.sqrt();
            let eh = s.drop_r * 2.0 * s.stretch;
            ellipse(&cr, cx - ew / 2.0, s.drop_y - eh / 2.0, ew, eh);
        }
        // 끊어질 때 생기는 작은 물방울
        if s.sat_r > 0.5 {
            ellipse(&cr, cx - s.sat_r, s.sat_y - s.sat_r, s.sat_r * 2.0, s.sat_r * 2.0);
        }
    }
    mask.flush();
    let stride = mask.stride() as usize;
    let (wu, hu) = (w as usize, h as usize);
    let mut a: Vec<f32> = {
        let data = mask.data().ok()?;
        let mut v = vec![0f32; wu * hu];
        for y in 0..hu {
            for x in 0..wu {
                v[y * wu + x] = data[y * stride + x] as f32 / 255.0;
            }
        }
        v
    };
    // 2) 흐림(상자 흐림 세 번 ≈ 가우스)
    let rad = ((BLUR * scale) / 1.6).round().max(1.0) as usize;
    for _ in 0..3 {
        box_blur(&mut a, wu, hu, rad);
    }
    // 3) 문턱값: 0.5 근처만 부드럽게(가장자리 계단 없이)
    let mut out = cairo::ImageSurface::create(cairo::Format::ARgb32, w, h).ok()?;
    {
        let ostride = out.stride() as usize;
        let mut d = out.data().ok()?;
        let (r, g, b) = color;
        let aa = 0.06f32;
        for y in 0..hu {
            for x in 0..wu {
                let v = a[y * wu + x];
                let al = ((v - (0.5 - aa)) / (2.0 * aa)).clamp(0.0, 1.0);
                if al <= 0.0 {
                    continue;
                }
                let o = y * ostride + x * 4;
                // ARGB32 premultiplied, little endian: B G R A
                d[o] = (b as f32 * al * 255.0) as u8;
                d[o + 1] = (g as f32 * al * 255.0) as u8;
                d[o + 2] = (r as f32 * al * 255.0) as u8;
                d[o + 3] = (al * 255.0) as u8;
            }
        }
    }
    out.mark_dirty();
    out.set_device_scale(scale, scale);
    Some(out)
}

fn box_blur(a: &mut [f32], w: usize, h: usize, r: usize) {
    let mut tmp = vec![0f32; a.len()];
    let n = (2 * r + 1) as f32;
    for y in 0..h {
        let row = &a[y * w..(y + 1) * w];
        let mut sum = 0.0;
        for i in 0..=r.min(w - 1) {
            sum += row[i];
        }
        for x in 0..w {
            tmp[y * w + x] = sum / n;
            if x + r + 1 < w {
                sum += row[x + r + 1];
            }
            if x >= r {
                sum -= row[x - r];
            }
        }
    }
    for x in 0..w {
        let mut sum = 0.0;
        for i in 0..=r.min(h - 1) {
            sum += tmp[i * w + x];
        }
        for y in 0..h {
            a[y * w + x] = sum / n;
            if y + r + 1 < h {
                sum += tmp[(y + r + 1) * w + x];
            }
            if y >= r {
                sum -= tmp[(y - r) * w + x];
            }
        }
    }
}

// 반사광 두 점(액체 위에 덧그림)
pub fn highlights(cr: &cairo::Context, s: &S) {
    if s.drop_r <= 6.0 {
        return;
    }
    let cx = WIDTH / 2.0;
    let r = s.drop_r;
    let hx = cx - r * 0.38 / s.stretch.sqrt();
    let hy = s.drop_y - r * 0.35 * s.stretch;
    cr.save().ok();
    cr.translate(hx, hy);
    cr.scale(2.6, 3.4);
    cr.arc(0.0, 0.0, 1.0, 0.0, std::f64::consts::TAU);
    cr.restore().ok();
    cr.set_source_rgba(1.0, 1.0, 1.0, 0.75);
    let _ = cr.fill();
    cr.arc(cx + r * 0.3, s.drop_y + r * 0.35 * s.stretch, 1.2, 0.0, std::f64::consts::TAU);
    cr.set_source_rgba(1.0, 1.0, 1.0, 0.35);
    let _ = cr.fill();
}

pub fn rounded(cr: &cairo::Context, x: f64, y: f64, w: f64, h: f64, r: f64) {
    let r = r.min(w / 2.0).min(h / 2.0).max(0.0);
    use std::f64::consts::{FRAC_PI_2, PI};
    cr.new_sub_path();
    cr.arc(x + w - r, y + r, r, -FRAC_PI_2, 0.0);
    cr.arc(x + w - r, y + h - r, r, 0.0, FRAC_PI_2);
    cr.arc(x + r, y + h - r, r, FRAC_PI_2, PI);
    cr.arc(x + r, y + r, r, PI, 3.0 * FRAC_PI_2);
    cr.close_path();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timeline_matches_mac() {
        assert!((DETACH - 0.67).abs() < 1e-9);
        let land = 46.0 + 80.0 - 9.0;
        // 떨어지는 동안 점점 빨라지고 닿으면 사라진다
        let a = state(DETACH + 0.05, land);
        let b = state(DETACH + 0.1, land);
        assert!(b.drop_y > a.drop_y && b.stretch >= a.stretch);
        assert_eq!(state(landing_time(land) + 0.01, land).drop_r, 0.0);
        // 맺히는 동안은 천장에 붙어 있음
        let s = state(0.2, land);
        assert!(s.film > 0.0 && s.bead_r > 4.0 && s.neck > 0.0);
    }

    #[test]
    fn metaball_connects_neck() {
        let land = 117.0;
        let s = state(DETACH - 0.02, land);
        let img = render(&s, land, (0.2, 0.5, 1.0), 1.0).unwrap();
        let stride = img.stride() as usize;
        let mut img = img;
        let d = img.data().unwrap();
        // 가운데 세로줄이 천장부터 물방울까지 이어져 있다(목)
        let x = (WIDTH / 2.0) as usize;
        let filled = (2..(s.drop_y as usize)).filter(|&y| d[y * stride + x * 4 + 3] > 128).count();
        assert!(filled as f64 > s.drop_y * 0.8, "{filled} / {}", s.drop_y);
    }
}
