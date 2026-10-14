// 분야의 '오늘 얼굴' 사진과 분야 유리 카드(맥 UI/SectionPhotos.swift · SectionGlassCard).
// 사진: 매거진 기록에서 그 분야의 최근 사진 기사 중 사진 점수(M-24)를 넘는 첫 사진, 없으면(처음 실행) 그 분야 기본 출처 피드를 바로 받아 고른다.
// 분야 고르기 카드·매거진 분야 머리가 같이 쓴다. 한 번 고른 사진은 실행 동안 기억.
// 카드: 흐린 사진 바탕 + 분야색 유리판 + 영문 섹션명·한글 이름 + 흰 테두리를 두른 기울인 사진(나-3).
use crate::app::{bg, ui};
use crate::theme;
use dropcap_core::models::NewsItem;
use dropcap_core::sections::{self, NewsSection};
use gtk::prelude::*;
use gtk::{cairo, gdk, pango};
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::path::PathBuf;
use std::rc::Rc;

thread_local! {
    static PHOTOS: RefCell<HashMap<String, PathBuf>> = RefCell::new(HashMap::new());
    static SURFACES: RefCell<HashMap<String, Rc<(cairo::ImageSurface, cairo::ImageSurface)>>> = RefCell::new(HashMap::new());
    static LOADING: Cell<bool> = const { Cell::new(false) };
    static LISTENERS: RefCell<Vec<Box<dyn Fn() -> bool>>> = const { RefCell::new(Vec::new()) };
}

// 사진이 새로 채워지면 부른다. f 가 false 를 돌려주면(창이 닫힘) 빠진다
pub fn listen(f: impl Fn() -> bool + 'static) {
    LISTENERS.with(|l| l.borrow_mut().push(Box::new(f)));
}

fn notify() {
    let list: Vec<Box<dyn Fn() -> bool>> = LISTENERS.with(|l| std::mem::take(&mut *l.borrow_mut()));
    let keep: Vec<Box<dyn Fn() -> bool>> = list.into_iter().filter(|f| f()).collect();
    LISTENERS.with(|l| {
        let mut l = l.borrow_mut();
        let added = std::mem::take(&mut *l);
        *l = keep;
        l.extend(added);
    });
}

pub fn photo(section: &str) -> Option<PathBuf> {
    PHOTOS.with(|p| p.borrow().get(section).cloned())
}

pub fn load() {
    if LOADING.with(|l| l.replace(true)) {
        return;
    }
    for s in sections::ALL.iter().filter(|s| photo(&s.id).is_none()) {
        let core = ui().core.clone();
        let id = s.id.clone();
        bg(
            async move {
                let db = core.db.clone();
                let since = chrono::Utc::now() - chrono::Duration::days(3);
                let recent: Vec<NewsItem> = db.items(since, None, 3000).into_iter().map(|s| s.item).filter(|i| i.in_section(&id)).collect();
                let mut got = dropcap_core::photo_quality::pick(&db, &recent, 6).await;
                if got.is_none() {
                    got = dropcap_core::photo_quality::pick(&db, &feed_items(&core, &id).await, 6).await;
                }
                (id, got.map(|g| g.1))
            },
            |(id, file)| {
                let Some(f) = file else { return };
                PHOTOS.with(|p| p.borrow_mut().insert(id, f));
                notify();
            },
        );
    }
}

// 그 분야 기본(켤) 출처부터 차례로 받은 글들(사진 있는 글이 4개 나올 때까지 최대 세 곳)
async fn feed_items(core: &std::sync::Arc<dropcap_core::app_model::AppModel>, section: &str) -> Vec<NewsItem> {
    let mut metas = sections::sources_in(section, &sections::META);
    metas.sort_by_key(|m| if m.default_on == Some(true) { 0 } else { 1 });
    let mut out: Vec<NewsItem> = vec![];
    for m in metas.iter().take(3) {
        let Some(src) = core.source(&m.id) else { continue };
        if let Ok(Some(items)) = dropcap_core::feed_service::SHARED.items(&src, false).await {
            out.extend(items);
        }
        if out.iter().filter(|i| i.image.is_some() && !dropcap_core::article::image_key::is_junk(i.image.as_deref())).count() >= 4 {
            break;
        }
    }
    out
}

// 영문 섹션명(고정폭 대문자)
pub fn english(id: &str) -> String {
    match id {
        "politics" => "POLITICS",
        "economy" => "ECONOMY",
        "society" => "SOCIETY",
        "world" => "WORLD",
        "tech" => "TECH",
        "ai" => "AI",
        "science" => "SCIENCE",
        "life" => "LIFE · HEALTH",
        "culture" => "CULTURE",
        "sports" => "SPORTS",
        "climate" => "CLIMATE",
        _ => return id.to_uppercase(),
    }
    .to_string()
}

// 분야 색을 색상·밝기로 조금 옮긴 색(그라데이션용)
pub fn shift(hex: &str, hue: f64, bri: f64) -> (f64, f64, f64) {
    let (r, g, b) = dropcap_core::models::hex_rgb(hex);
    let max = r.max(g).max(b);
    let min = r.min(g).min(b);
    let d = max - min;
    let mut h = if d == 0.0 {
        0.0
    } else if max == r {
        ((g - b) / d).rem_euclid(6.0) / 6.0
    } else if max == g {
        ((b - r) / d + 2.0) / 6.0
    } else {
        ((r - g) / d + 4.0) / 6.0
    };
    let s = if max == 0.0 { 0.0 } else { d / max };
    let v = (max + bri).clamp(0.0, 1.0);
    h = (h + hue + 1.0).rem_euclid(1.0);
    let i = (h * 6.0).floor();
    let f = h * 6.0 - i;
    let (p, q, t) = (v * (1.0 - s), v * (1.0 - f * s), v * (1.0 - (1.0 - f) * s));
    match i as i32 % 6 {
        0 => (v, t, p),
        1 => (q, v, p),
        2 => (p, v, t),
        3 => (p, q, v),
        4 => (t, p, v),
        _ => (v, p, q),
    }
}

// 사진 파일 → (흐린 바탕용 작은 그림, 원래 그림). 한 번 만든 것은 다시 쓴다
fn surfaces(file: &PathBuf) -> Option<Rc<(cairo::ImageSurface, cairo::ImageSurface)>> {
    let key = file.to_string_lossy().to_string();
    if let Some(s) = SURFACES.with(|m| m.borrow().get(&key).cloned()) {
        return Some(s);
    }
    let tex = gdk::Texture::from_filename(file).ok()?;
    let (w, h) = (tex.width(), tex.height());
    let stride = cairo::Format::ARgb32.stride_for_width(w as u32).ok()?;
    let mut data = vec![0u8; (stride * h) as usize];
    tex.download(&mut data, stride as usize);
    let full = cairo::ImageSurface::create_for_data(data, cairo::Format::ARgb32, w, h, stride).ok()?;
    // 흐리게: 아주 작게 줄였다가 부드럽게 키운다(맥 blur 10 에 가깝게)
    let (sw, sh) = (((w as f64) / 24.0).ceil().max(2.0) as i32, ((h as f64) / 24.0).ceil().max(2.0) as i32);
    let small = cairo::ImageSurface::create(cairo::Format::ARgb32, sw, sh).ok()?;
    {
        let cr = cairo::Context::new(&small).ok()?;
        cr.scale(sw as f64 / w as f64, sh as f64 / h as f64);
        cr.set_source_surface(&full, 0.0, 0.0).ok()?;
        cr.source().set_filter(cairo::Filter::Good);
        cr.paint().ok()?;
    }
    let s = Rc::new((small, full));
    SURFACES.with(|m| m.borrow_mut().insert(key, s.clone()));
    Some(s)
}

fn rounded(cr: &cairo::Context, x: f64, y: f64, w: f64, h: f64, r: f64) {
    let r = r.min(w / 2.0).min(h / 2.0);
    cr.new_sub_path();
    cr.arc(x + w - r, y + r, r, -std::f64::consts::FRAC_PI_2, 0.0);
    cr.arc(x + w - r, y + h - r, r, 0.0, std::f64::consts::FRAC_PI_2);
    cr.arc(x + r, y + h - r, r, std::f64::consts::FRAC_PI_2, std::f64::consts::PI);
    cr.arc(x + r, y + r, r, std::f64::consts::PI, 1.5 * std::f64::consts::PI);
    cr.close_path();
}

// 그림을 사각형에 꽉 차게(넘치는 곳은 잘림)
fn paint_cover(cr: &cairo::Context, s: &cairo::ImageSurface, x: f64, y: f64, w: f64, h: f64) {
    let (iw, ih) = (s.width() as f64, s.height() as f64);
    let k = (w / iw).max(h / ih);
    cr.save().ok();
    rounded(cr, x, y, w, h, 0.0);
    cr.clip();
    cr.translate(x + (w - iw * k) / 2.0, y + (h - ih * k) / 2.0);
    cr.scale(k, k);
    let _ = cr.set_source_surface(s, 0.0, 0.0);
    cr.source().set_filter(cairo::Filter::Good);
    let _ = cr.paint();
    cr.restore().ok();
}

fn text_layout(cr: &cairo::Context, t: &str, size: f64, weight: pango::Weight, mono: bool, spacing: i32, width: Option<f64>) -> pango::Layout {
    let l = pangocairo::functions::create_layout(cr);
    let mut d = theme::font(size, weight);
    if mono {
        d.set_family("monospace");
    }
    l.set_font_description(Some(&d));
    if spacing != 0 {
        let a = pango::AttrList::new();
        a.insert(pango::AttrInt::new_letter_spacing(spacing));
        l.set_attributes(Some(&a));
    }
    if let Some(w) = width {
        l.set_width((w * pango::SCALE as f64) as i32);
        l.set_wrap(pango::WrapMode::WordChar);
        l.set_ellipsize(pango::EllipsizeMode::End);
        l.set_height(-2); // 두 줄까지
    }
    l.set_text(t);
    l
}

// 분야 유리 카드 하나(그리기만). selected·hover 는 바깥에서 다시 그리며 바꾼다
pub struct GlassCard {
    pub area: gtk::DrawingArea,
}

pub fn glass_card(section: &NewsSection, subtitle: Option<String>, height: i32, shows_check: bool, selected: bool) -> GlassCard {
    let area = gtk::DrawingArea::builder().content_height(height).hexpand(true).build();
    let sel = Rc::new(Cell::new(selected));
    let hover = Rc::new(Cell::new(false));
    let (id, name, tint) = (section.id.clone(), section.name.clone(), section.color.clone());
    {
        let (sel, hover) = (sel.clone(), hover.clone());
        area.set_draw_func(move |_, cr, w, h| {
            let (w, h) = (w as f64, h as f64);
            let s = h / 130.0;
            let (tr, tg, tb) = dropcap_core::models::hex_rgb(&tint);
            cr.save().ok();
            rounded(cr, 0.0, 0.0, w, h, 14.0);
            cr.clip();
            let surf = photo(&id).and_then(|f| surfaces(&f));
            // 흐린 사진 바탕(없으면 분야색)
            match &surf {
                Some(p) => paint_cover(cr, &p.0, 0.0, 0.0, w, h),
                None => {
                    cr.set_source_rgb(tr, tg, tb);
                    let _ = cr.paint();
                }
            }
            // 분야색 유리
            let g = cairo::LinearGradient::new(0.0, 0.0, w, h);
            let (sr, sg, sb) = shift(&tint, 0.05, -0.2);
            g.add_color_stop_rgba(0.0, tr, tg, tb, 0.88);
            g.add_color_stop_rgba(1.0, sr, sg, sb, 0.6);
            let _ = cr.set_source(&g);
            let _ = cr.paint();
            // 안쪽 유리판: 흰 10% + 빛나는 테두리
            rounded(cr, 8.0, 8.0, w - 16.0, h - 16.0, 10.0);
            cr.set_source_rgba(1.0, 1.0, 1.0, 0.1);
            let _ = cr.fill_preserve();
            let edge = cairo::LinearGradient::new(8.0, 8.0, w - 8.0, h - 8.0);
            edge.add_color_stop_rgba(0.0, 1.0, 1.0, 1.0, 0.6);
            edge.add_color_stop_rgba(1.0, 1.0, 1.0, 1.0, 0.08);
            let _ = cr.set_source(&edge);
            cr.set_line_width(1.0);
            let _ = cr.stroke();
            // 흰 테두리를 두른 기울인 사진(오른쪽 아래로 걸침)
            if let Some(p) = &surf {
                let side = 98.0 * s;
                let (x, y) = (w - 78.0 * s, h * 0.36);
                cr.save().ok();
                cr.translate(x + side / 2.0, y + side / 2.0);
                cr.rotate((20.0f64 + if hover.get() { 2.0 } else { 0.0 }).to_radians());
                rounded(cr, -side / 2.0 + 2.0, -side / 2.0 + 5.0, side, side, 6.0 * s);
                cr.set_source_rgba(0.0, 0.0, 0.0, 0.25);
                let _ = cr.fill();
                rounded(cr, -side / 2.0, -side / 2.0, side, side, 6.0 * s);
                cr.set_source_rgb(1.0, 1.0, 1.0);
                let _ = cr.fill();
                let inner = side - 8.0 * s;
                cr.save().ok();
                rounded(cr, -inner / 2.0, -inner / 2.0, inner, inner, 4.0 * s);
                cr.clip();
                paint_cover(cr, &p.1, -inner / 2.0, -inner / 2.0, inner, inner);
                cr.restore().ok();
                cr.restore().ok();
            }
            // 글자: 영문 섹션명 · 한글 이름 · 부제
            let pad = 16.0;
            let mut y = pad;
            let show = |cr: &cairo::Context, l: &pango::Layout, x: f64, y: f64, alpha: f64| {
                cr.move_to(x, y + 1.0);
                cr.set_source_rgba(0.0, 0.0, 0.0, 0.2);
                pangocairo::functions::show_layout(cr, l);
                cr.move_to(x, y);
                cr.set_source_rgba(1.0, 1.0, 1.0, alpha);
                pangocairo::functions::show_layout(cr, l);
            };
            let en = text_layout(cr, &english(&id), 9.0, pango::Weight::Semibold, true, (1.4 * pango::SCALE as f64) as i32, None);
            show(cr, &en, pad, y, 0.85);
            y += en.pixel_size().1 as f64 + 2.0;
            let nm = text_layout(cr, &name, 19.0, pango::Weight::Heavy, false, 0, None);
            show(cr, &nm, pad, y, 1.0);
            y += nm.pixel_size().1 as f64 + 4.0;
            if let Some(sub) = &subtitle {
                let maxw = w * if w > 400.0 { 0.7 } else { 0.55 };
                let sl = text_layout(cr, sub, 11.0, pango::Weight::Normal, false, 0, Some(maxw));
                show(cr, &sl, pad, y, 0.85);
            }
            cr.restore().ok();
            // 고름 표시(왼쪽 아래)
            if shows_check {
                let (cx, cy, r) = (14.0 + 9.0, h - 14.0 - 9.0, 9.0);
                cr.new_path(); // 글자를 쓴 자리에서 선이 이어지지 않게
                if sel.get() {
                    cr.arc(cx, cy, r, 0.0, std::f64::consts::TAU);
                    cr.set_source_rgb(1.0, 1.0, 1.0);
                    let _ = cr.fill();
                    cr.set_source_rgb(tr, tg, tb);
                    cr.set_line_width(2.0);
                    cr.move_to(cx - 4.0, cy);
                    cr.line_to(cx - 1.0, cy + 3.0);
                    cr.line_to(cx + 4.5, cy - 3.5);
                    let _ = cr.stroke();
                } else {
                    cr.arc(cx, cy, r - 1.0, 0.0, std::f64::consts::TAU);
                    cr.set_source_rgba(1.0, 1.0, 1.0, 0.75);
                    cr.set_line_width(2.0);
                    let _ = cr.stroke();
                }
            }
            // 고른 카드: 흰 테두리
            if sel.get() && shows_check {
                cr.new_path();
                rounded(cr, 1.25, 1.25, w - 2.5, h - 2.5, 13.0);
                cr.set_source_rgba(1.0, 1.0, 1.0, 0.95);
                cr.set_line_width(2.5);
                let _ = cr.stroke();
            }
        });
    }
    let motion = gtk::EventControllerMotion::new();
    {
        let (a, h2) = (area.clone(), hover.clone());
        motion.connect_enter(move |_, _, _| {
            h2.set(true);
            a.queue_draw();
        });
    }
    {
        let (a, h2) = (area.clone(), hover.clone());
        motion.connect_leave(move |_| {
            h2.set(false);
            a.queue_draw();
        });
    }
    area.add_controller(motion);
    // 그림자: 분야색(고르면 진하게)
    let prov = gtk::CssProvider::new();
    let (r, g, b) = dropcap_core::models::hex_rgb(&section.color);
    let (r, g, b) = ((r * 255.0) as u8, (g * 255.0) as u8, (b * 255.0) as u8);
    prov.load_from_string(&format!(
        "drawingarea {{ border-radius: 14px; box-shadow: 0 4px {}px rgba({r},{g},{b},{}); }}",
        if selected { 12 } else { 7 },
        if selected { 0.5 } else { 0.28 }
    ));
    #[allow(deprecated)]
    area.style_context().add_provider(&prov, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION);
    area.set_tooltip_text(Some(&format!("{}{}", section.name, if selected && shows_check { ", 고름" } else { "" })));
    // 사진이 채워지면 다시 그림
    let weak = area.downgrade();
    listen(move || match weak.upgrade() {
        Some(a) => {
            a.queue_draw();
            true
        }
        None => false,
    });
    GlassCard { area }
}
