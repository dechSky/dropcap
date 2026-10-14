// 시험용 그리기 결과 저장(DROPCAP_TEST_SHOT_DIR): 화면 캡처 권한 없이 위젯을 PNG 로 남긴다.
use gtk::prelude::*;
use gtk::{gdk, graphene};

pub fn save(widget: &impl IsA<gtk::Widget>, path: &std::path::Path) -> bool {
    let w = widget.as_ref();
    let (width, height) = (w.width(), w.height());
    if width <= 0 || height <= 0 {
        log::warn!("[찍기] 크기가 0: {}", path.display());
        return false;
    }
    let paintable = gtk::WidgetPaintable::new(Some(w));
    let snap = gtk::Snapshot::new();
    paintable.snapshot(&snap, width as f64, height as f64);
    let Some(node) = snap.to_node() else { return false };
    let Some(native) = w.native() else { return false };
    let Some(renderer) = native.renderer() else { return false };
    let tex: gdk::Texture = renderer.render_texture(&node, Some(&graphene::Rect::new(0.0, 0.0, width as f32, height as f32)));
    let ok = tex.save_to_png(path).is_ok();
    log::info!("[찍기] {} {}", path.display(), if ok { "저장" } else { "실패" });
    ok
}

pub fn shot_later(widget: &impl IsA<gtk::Widget>, name: &str, ms: u64) {
    let Some(dir) = crate::app::ui().env.shot_dir.clone() else { return };
    let w = widget.as_ref().clone();
    let name = name.to_string();
    gtk::glib::timeout_add_local_once(std::time::Duration::from_millis(ms), move || {
        let _ = std::fs::create_dir_all(&dir);
        save(&w, &dir.join(format!("{name}.png")));
    });
}
