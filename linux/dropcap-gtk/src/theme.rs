// 디자인 바탕(D-01·D-02·P-03): Pretendard 를 이 앱 안에서만 등록하고, 앱 전체 CSS(라이트·다크)를 건다.
use crate::app::{resource, ui};
use gtk::prelude::*;
use gtk::{gdk, pango};
use std::cell::RefCell;

pub const FAMILY: &str = "Pretendard Variable";

thread_local! {
    static PROVIDER: RefCell<Option<gtk::CssProvider>> = const { RefCell::new(None) };
}

// 앱을 켤 때 한 번: 글꼴 파일을 이 프로세스의 글꼴 지도에만 넣는다(시스템에 설치하지 않음)
pub fn register_font() -> bool {
    let path = resource("fonts/PretendardVariable.ttf");
    if !path.exists() {
        log::warn!("[글꼴] Pretendard 파일이 없음: {}", path.display());
        return false;
    }
    let map = pangocairo_fontmap();
    match map {
        Some(m) => match m.add_font_file(&path) {
            Ok(()) => true,
            Err(e) => {
                log::warn!("[글꼴] 등록 실패: {e}");
                false
            }
        },
        None => false,
    }
}

fn pangocairo_fontmap() -> Option<pango::FontMap> {
    // GTK 가 쓰는 기본 글꼴 지도(위젯의 pango 문맥에서 얻는다)
    let l = gtk::Label::new(None);
    l.pango_context().font_map()
}

pub fn use_pretendard() -> bool {
    ui().prefs.borrow().use_pretendard
}

pub fn family() -> String {
    if use_pretendard() {
        format!("\"{FAMILY}\", sans-serif")
    } else {
        "sans-serif".into()
    }
}

pub fn is_dark() -> bool {
    adw::StyleManager::default().is_dark()
}

// 맥 SwiftUI 기본 색에 맞춘 이름 있는 색(라이트, 다크)
pub fn css() -> String {
    let f = family();
    format!(
        r#"
* {{ font-family: {f}; }}
.dc-title {{ font-weight: 700; letter-spacing: -0.2px; }}
.dc-display {{ font-weight: 800; letter-spacing: -0.6px; }}
.dc-secondary {{ opacity: 0.62; }}
.dc-tertiary {{ opacity: 0.45; }}
.dc-read {{ opacity: 0.55; }}
.dc-chip {{ border-radius: 99px; padding: 1px 7px; font-size: 10.5px; font-weight: 600; }}
.dc-card {{ border-radius: 14px; background-color: alpha(@window_fg_color, 0.04); }}
.dc-card:hover {{ background-color: alpha(@window_fg_color, 0.07); }}
.dc-row {{ border-radius: 10px; padding: 7px 9px; }}
.dc-row:hover {{ background-color: alpha(@window_fg_color, 0.06); }}
.dc-unread-dot {{ min-width: 7px; min-height: 7px; border-radius: 99px; background-color: @accent_bg_color; }}
.dc-accent-button {{ background-color: @accent_bg_color; color: @accent_fg_color; border-radius: 9px; font-weight: 600; }}
.dc-scrapped {{ border-left: 3px solid #F5C518; padding-left: 9px; background-color: alpha(#F5C518, 0.10); }}
.dc-reader-body {{ line-height: 1.6; }}
.dc-skeleton {{ border-radius: 6px; background-color: alpha(@window_fg_color, 0.08); }}
.dc-toast {{ border-radius: 20px; }}
.dc-masthead-logo {{ font-weight: 900; letter-spacing: -1px; }}
.dc-glass {{ background-color: alpha(@window_bg_color, 0.78); border-radius: 18px; border: 1px solid alpha(@window_fg_color, 0.10); }}
"#
    )
}

pub fn apply() {
    let Some(display) = gdk::Display::default() else { return };
    PROVIDER.with(|p| {
        let mut p = p.borrow_mut();
        if let Some(old) = p.take() {
            gtk::style_context_remove_provider_for_display(&display, &old);
        }
        let prov = gtk::CssProvider::new();
        prov.load_from_string(&css());
        gtk::style_context_add_provider_for_display(&display, &prov, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION);
        *p = Some(prov);
    });
}

// 맥 RemoteImage 와 같은 바탕: 분야 색의 은은한 그라데이션
#[allow(dead_code)] // 매거진 화면(새 FEATURES 까지 보류)에서 씀
pub fn rgba(hex: &str, a: f64) -> gdk::RGBA {
    let (r, g, b) = dropcap_core::models::hex_rgb(hex);
    gdk::RGBA::new(r as f32, g as f32, b as f32, a as f32)
}

// pango 글꼴 설명(그리기 영역에서 직접 글자를 그릴 때)
pub fn font(size: f64, weight: pango::Weight) -> pango::FontDescription {
    let mut d = pango::FontDescription::new();
    d.set_family(if use_pretendard() { FAMILY } else { "sans-serif" });
    d.set_absolute_size(size * pango::SCALE as f64);
    d.set_weight(weight);
    d
}
