// 여러 창이 함께 쓰는 작은 부품: 출처 글자 원형, 안전한 사진 칸, 칩, 글자.
use crate::app::{bg, ui};
use crate::theme;
use dropcap_core::byte_cache::{self, ByteLru};
use dropcap_core::category::NewsCategory;
use dropcap_core::models::{relative_time, NewsItem};
use gtk::prelude::*;
use gtk::{gdk, glib, pango};
use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;

pub fn source_color(source_id: &str) -> String {
    ui().core.source(source_id).map(|s| s.color).unwrap_or_else(|| "#3B82F6".into())
}

// 출처 글자 원형(모노그램)
pub fn monogram(item: &NewsItem, size: i32) -> gtk::DrawingArea {
    let color = source_color(&item.source_id);
    let letter = item.initial();
    let d = gtk::DrawingArea::builder().content_width(size).content_height(size).valign(gtk::Align::Center).build();
    d.set_draw_func(move |area, cr, w, h| {
        let r = (w.min(h) as f64) / 2.0;
        let (cr_, cg, cb) = dropcap_core::models::hex_rgb(&color);
        cr.arc(w as f64 / 2.0, h as f64 / 2.0, r, 0.0, std::f64::consts::TAU);
        cr.set_source_rgb(cr_, cg, cb);
        let _ = cr.fill();
        let layout = area.create_pango_layout(Some(&letter));
        layout.set_font_description(Some(&theme::font(r * 0.95, pango::Weight::Bold)));
        let (_, ext) = layout.pixel_extents();
        cr.set_source_rgb(1.0, 1.0, 1.0);
        cr.move_to(w as f64 / 2.0 - ext.width() as f64 / 2.0 - ext.x() as f64, h as f64 / 2.0 - ext.height() as f64 / 2.0 - ext.y() as f64);
        pangocairo_show(cr, &layout);
    });
    d
}

pub fn pangocairo_show(cr: &gtk::cairo::Context, layout: &pango::Layout) {
    pangocairo::functions::show_layout(cr, layout);
}

pub fn label(text: &str, size: f64, weight: u16, classes: &[&str]) -> gtk::Label {
    let l = gtk::Label::new(Some(text));
    l.set_xalign(0.0);
    l.set_wrap(true);
    l.set_wrap_mode(pango::WrapMode::WordChar);
    let attrs = pango::AttrList::new();
    attrs.insert(pango::AttrSize::new_size_absolute((size * pango::SCALE as f64) as i32));
    attrs.insert(pango::AttrInt::new_weight(weight_of(weight)));
    l.set_attributes(Some(&attrs));
    for c in classes {
        l.add_css_class(c);
    }
    l
}

pub fn weight_of(w: u16) -> pango::Weight {
    match w {
        0..=349 => pango::Weight::Light,
        350..=449 => pango::Weight::Normal,
        450..=549 => pango::Weight::Medium,
        550..=649 => pango::Weight::Semibold,
        650..=749 => pango::Weight::Bold,
        750..=849 => pango::Weight::Ultrabold,
        _ => pango::Weight::Heavy,
    }
}

// 줄 수 제한(맥 lineLimit)
pub fn lines(l: &gtk::Label, n: i32) -> &gtk::Label {
    l.set_lines(n);
    l.set_ellipsize(pango::EllipsizeMode::End);
    l
}

pub fn chip(text: &str, color_hex: &str) -> gtk::Label {
    let l = gtk::Label::new(Some(text));
    l.add_css_class("dc-chip");
    let prov = gtk::CssProvider::new();
    let (r, g, b) = dropcap_core::models::hex_rgb(color_hex);
    let (r, g, b) = ((r * 255.0) as u8, (g * 255.0) as u8, (b * 255.0) as u8);
    prov.load_from_string(&format!("label {{ color: rgb({r},{g},{b}); background-color: rgba({r},{g},{b},0.14); }}"));
    #[allow(deprecated)]
    l.style_context().add_provider(&prov, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION);
    l
}

#[allow(dead_code)] // 매거진 화면(새 FEATURES 까지 보류)에서 씀
pub fn category_chip(cat: NewsCategory) -> gtk::Label {
    chip(cat.label(), cat.color(theme::is_dark()))
}

pub fn time_text(item: &NewsItem) -> String {
    relative_time(item.date, chrono::Utc::now())
}

pub fn icon(name: &str, size: i32) -> gtk::Image {
    let i = gtk::Image::from_icon_name(name);
    i.set_pixel_size(size);
    i
}

// MARK: 사진(S-07): 안전 로더로만. 메모리에는 풀린 크기 64MB 까지(최근 사용 순 — 맥 ImageMemoryCache).
// 예전엔 장 수(160장)로만 묶어 1400px RGBA 텍스처만으로 1GB 가까이 될 수 있었다.
thread_local! {
    static TEXTURES: RefCell<ByteLru<gdk::Texture>> = RefCell::new(ByteLru::new(byte_cache::TEXTURE_LIMIT));
}

pub fn cached_texture(url: &str) -> Option<gdk::Texture> {
    TEXTURES.with(|t| t.borrow_mut().get(url))
}

fn remember_texture(url: &str, tex: &gdk::Texture) {
    let cost = byte_cache::rgba_bytes(tex.width(), tex.height());
    TEXTURES.with(|t| t.borrow_mut().insert(url, tex.clone(), cost));
}

// 사진 하나를 안전 로더로 받아 텍스처로(메인 루프에서 cb)
pub fn load_texture(url: &str, cb: impl FnOnce(Option<gdk::Texture>) + 'static) {
    if let Some(t) = cached_texture(url) {
        cb(Some(t));
        return;
    }
    let u = url.to_string();
    bg(async move { dropcap_core::images::shared().image(&u).await }, {
        let url = url.to_string();
        move |p: Option<PathBuf>| {
            let tex = p.and_then(|p| gdk::Texture::from_filename(&p).ok());
            if let Some(t) = &tex {
                remember_texture(&url, t);
            }
            cb(tex);
        }
    });
}

// 사진 칸: 불러오는 동안·사진이 없을 때는 분야 색의 은은한 그라데이션과 기호(맥 RemoteImage).
// 주소가 바뀌면 이전 사진을 비우고 다시(M-21).
#[derive(Clone)]
#[allow(dead_code)] // 매거진 화면(새 FEATURES 까지 보류)에서 씀
pub struct RemoteImage {
    pub root: gtk::Overlay,
    picture: gtk::Picture,
    current: Rc<RefCell<Option<String>>>,
}

#[allow(dead_code)] // 매거진 화면(새 FEATURES 까지 보류)에서 씀
impl RemoteImage {
    pub fn new(url: Option<&str>, category: NewsCategory, accent_hex: &str, w: i32, h: i32) -> RemoteImage {
        let bg_area = gtk::DrawingArea::builder().content_width(w).content_height(h).hexpand(true).vexpand(true).build();
        let accent = accent_hex.to_string();
        let cat_hex = category.color(theme::is_dark()).to_string();
        bg_area.set_draw_func(move |_, cr, w, h| {
            let g = gtk::cairo::LinearGradient::new(0.0, 0.0, w as f64, h as f64);
            let (ar, ag, ab) = dropcap_core::models::hex_rgb(&accent);
            let (cr_, cg, cb) = dropcap_core::models::hex_rgb(&cat_hex);
            g.add_color_stop_rgba(0.0, ar, ag, ab, 0.35);
            g.add_color_stop_rgba(0.5, cr_, cg, cb, 0.25);
            g.add_color_stop_rgba(1.0, ar, ag, ab, 0.12);
            let _ = cr.set_source(&g);
            let _ = cr.paint();
        });
        let root = gtk::Overlay::new();
        root.set_child(Some(&bg_area));
        root.set_overflow(gtk::Overflow::Hidden);
        let sym = icon(category.icon(), (h / 4).clamp(14, 40));
        sym.set_opacity(0.55);
        sym.set_halign(gtk::Align::Center);
        sym.set_valign(gtk::Align::Center);
        root.add_overlay(&sym);
        let picture = gtk::Picture::new();
        picture.set_content_fit(gtk::ContentFit::Cover);
        picture.set_can_shrink(true);
        picture.set_opacity(0.0);
        root.add_overlay(&picture);
        let me = RemoteImage { root, picture, current: Rc::new(RefCell::new(None)) };
        me.set_url(url);
        me
    }

    pub fn set_url(&self, url: Option<&str>) {
        *self.current.borrow_mut() = url.map(|s| s.to_string());
        self.picture.set_paintable(None::<&gdk::Paintable>);
        self.picture.set_opacity(0.0);
        let Some(url) = url else { return };
        let pic = self.picture.clone();
        let cur = self.current.clone();
        let want = url.to_string();
        load_texture(url, move |tex| {
            if cur.borrow().as_deref() != Some(want.as_str()) {
                return; // 그새 다른 기사로 바뀜
            }
            if let Some(t) = tex {
                pic.set_paintable(Some(&t));
                fade_in(&pic, crate::motion::SLOW);
            }
        });
    }

    pub fn picture(&self) -> &gtk::Picture {
        &self.picture
    }
}

// 0.5초 동안 서서히(움직임 줄이기면 바로)
pub fn fade_in(w: &impl IsA<gtk::Widget>, ms: u32) {
    let w = w.clone().upcast::<gtk::Widget>();
    if !crate::motion::enabled() {
        w.set_opacity(1.0);
        return;
    }
    let target = adw::CallbackAnimationTarget::new({
        let w = w.clone();
        move |v| w.set_opacity(v)
    });
    let a = adw::TimedAnimation::new(&w, 0.0, 1.0, ms, target);
    a.set_easing(crate::motion::ENTER);
    adw::prelude::AnimationExt::play(&a);
}

pub fn clear_box(b: &gtk::Box) {
    while let Some(c) = b.first_child() {
        b.remove(&c);
    }
}

pub fn later(ms: u64, f: impl FnOnce() + 'static) {
    glib::timeout_add_local_once(std::time::Duration::from_millis(ms), f);
}

// 목록 줄·매거진 카드·스토리에 붙는 작은 자물쇠(G-14): hard·배움 = 잠긴 자물쇠, metered = 열린 자물쇠, 마우스를 올리면 이유.
// 맛보기로 판정된 기사(미리 받기 포함)는 잠긴 자물쇠 + '앞부분만'(주황)으로 따로(맥 PaywallMark)
pub fn paywall_mark(item: &NewsItem) -> Option<gtk::Widget> {
    let k = crate::app::ui().core.paywall.kind(item)?;
    let i = icon(k.icon(), 9);
    i.set_valign(gtk::Align::Center);
    let Some(t) = k.short_text() else {
        i.add_css_class("dc-secondary");
        i.set_tooltip_text(Some(&k.tooltip()));
        i.update_property(&[gtk::accessible::Property::Label(k.label())]);
        return Some(i.upcast());
    };
    let b = gtk::Box::new(gtk::Orientation::Horizontal, 2);
    b.set_valign(gtk::Align::Center);
    b.append(&i);
    let l = label(t, 9.5, 600, &[]);
    l.set_wrap(false);
    b.append(&l);
    crate::magazine::tint(&b, "#FF9500");
    crate::magazine::tint(&i, "#FF9500");
    crate::magazine::tint(&l, "#FF9500");
    b.set_tooltip_text(Some(&k.tooltip()));
    b.update_property(&[gtk::accessible::Property::Label(k.label())]);
    Some(b.upcast())
}
