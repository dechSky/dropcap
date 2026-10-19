// 알림 창의 자리·성질(N-11·N-14·N-20·N-22·N-23).
// - X11(x11 기능): 커서가 있는 모니터의 작업 영역 위쪽(GNOME 윗막대·KDE 패널 아래). 항상 위·작업 표시줄에 안 보임·
//   입력 초점을 받지 않는 알림 창 종류로 표시하고, 직접 그 자리로 옮긴다.
// - Wayland: layer-shell 이 되면(KDE·Sway 등) 위쪽 가운데 layer(초점 화면, 커서 따라가기 없음).
//   안 되면(GNOME) 물방울 대신 시스템 알림.
// - 그 밖(맥 개발 빌드 등): 일반 투명 창.
use gtk::gdk;
use gtk::prelude::*;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Backend {
    X11,
    Wayland,
    Other,
}

pub fn backend() -> Backend {
    let Some(d) = gdk::Display::default() else { return Backend::Other };
    let name = d.type_().name();
    if name.contains("X11") {
        Backend::X11
    } else if name.contains("Wayland") {
        Backend::Wayland
    } else {
        Backend::Other
    }
}

pub fn layer_shell_supported() -> bool {
    #[cfg(feature = "layer-shell")]
    {
        backend() == Backend::Wayland && gtk4_layer_shell::is_supported()
    }
    #[cfg(not(feature = "layer-shell"))]
    {
        false
    }
}

// 물방울 창을 띄울 수 있는가. 아니면 시스템 알림으로 자동 전환(N-18·N-22).
pub fn can_drip() -> bool {
    match backend() {
        Backend::Wayland => layer_shell_supported(),
        // 컴포지터가 없으면 투명 창이 검은 사각형이 된다
        Backend::X11 => gdk::Display::default().map(|d| d.is_composited() && d.is_rgba()).unwrap_or(false),
        Backend::Other => true,
    }
}

// 방해하지 않기(N-23): GNOME 이 배너를 끄라고 했거나(show-banners=false) KDE 방해 금지(Inhibited)면 띄우지 않는다
pub fn banners_allowed() -> bool {
    gnome_banners() && !notifications_inhibited()
}

fn gnome_banners() -> bool {
    let id = "org.gnome.desktop.notifications";
    let Some(src) = gtk::gio::SettingsSchemaSource::default() else { return true };
    let Some(schema) = src.lookup(id, true) else { return true };
    if !schema.has_key("show-banners") {
        return true;
    }
    gtk::gio::Settings::new(id).boolean("show-banners")
}

thread_local! {
    static INHIBIT: std::cell::RefCell<Option<(bool, std::time::Instant)>> = const { std::cell::RefCell::new(None) };
}

// org.freedesktop.Notifications 의 Inhibited 속성(KDE Plasma). 30초 기억, 0.2초 안에 답이 없으면 막지 않음.
fn notifications_inhibited() -> bool {
    if backend() == Backend::Other {
        return false;
    }
    if let Some((v, at)) = INHIBIT.with(|i| *i.borrow()) {
        if at.elapsed().as_secs() < 30 {
            return v;
        }
    }
    use gtk::gio;
    use gtk::glib;
    let v = gio::bus_get_sync(gio::BusType::Session, gio::Cancellable::NONE)
        .ok()
        .and_then(|bus| {
            bus.call_sync(
                Some("org.freedesktop.Notifications"),
                "/org/freedesktop/Notifications",
                "org.freedesktop.DBus.Properties",
                "Get",
                Some(&("org.freedesktop.Notifications", "Inhibited").to_variant()),
                Some(glib::VariantTy::new("(v)").unwrap()),
                gio::DBusCallFlags::NONE,
                200,
                gio::Cancellable::NONE,
            )
            .ok()
        })
        .and_then(|r| r.child_value(0).as_variant())
        .and_then(|v| v.get::<bool>())
        .unwrap_or(false);
    INHIBIT.with(|i| *i.borrow_mut() = Some((v, std::time::Instant::now())));
    v
}

// 창을 다시 놓을지(맥 ToastCenter.needsPlace): 숨어 있었거나 위치 설정이 놓을 때와 달라졌으면.
// 예전엔 숨었을 때만 놓아 알림이 떠 있는 동안 '오른쪽 위'로 바꾸면 다음 알림도 가운데에 떨어졌다.
pub fn needs_place(visible: bool, placed_right: Option<bool>, right: bool) -> bool {
    !visible || placed_right != Some(right)
}

// realize 전에 한 번: layer-shell 이면 layer 로 바꾼다
pub fn prepare(win: &gtk::Window, right: bool) {
    #[cfg(feature = "layer-shell")]
    if layer_shell_supported() {
        use gtk4_layer_shell::{Edge, KeyboardMode, Layer, LayerShell};
        win.init_layer_shell();
        win.set_layer(Layer::Overlay);
        win.set_namespace(Some("dropcap"));
        win.set_keyboard_mode(KeyboardMode::None); // 입력 초점을 빼앗지 않음
        win.set_exclusive_zone(-1);
        win.set_anchor(Edge::Top, true);
        win.set_anchor(Edge::Right, right);
        win.set_margin(Edge::Right, if right { 2 } else { 0 });
        return;
    }
    let _ = (win, right);
}

pub fn set_right(win: &gtk::Window, right: bool) {
    #[cfg(feature = "layer-shell")]
    if layer_shell_supported() {
        use gtk4_layer_shell::{Edge, LayerShell};
        win.set_anchor(Edge::Right, right);
        win.set_margin(Edge::Right, if right { 2 } else { 0 });
    }
    let _ = (win, right);
}

// 카드 둘레만 입력을 받는다(카드 밖 클릭은 뒤 창으로, N-13)
pub fn set_input_rects(win: &gtk::Window, rects: &[(f64, f64, f64, f64)]) {
    let Some(surface) = win.surface() else { return };
    let region = gtk::cairo::Region::create();
    for (x, y, w, h) in rects {
        let r = gtk::cairo::RectangleInt::new(x.floor() as i32, y.floor() as i32, w.ceil() as i32, h.ceil() as i32);
        let _ = region.union_rectangle(&r);
    }
    surface.set_input_region(Some(&region));
}

// MARK: X11
#[cfg(feature = "x11")]
pub mod x11 {
    use super::*;
    use x11rb::connection::Connection;
    use x11rb::protocol::xproto::{AtomEnum, ConfigureWindowAux, ConnectionExt, PropMode};
    use x11rb::wrapper::ConnectionExt as _;

    pub struct X {
        conn: x11rb::rust_connection::RustConnection,
        root: u32,
    }

    #[derive(Debug, Clone, Copy, PartialEq)]
    pub struct Rect {
        pub x: i32,
        pub y: i32,
        pub w: i32,
        pub h: i32,
    }

    impl Rect {
        fn contains(&self, px: i32, py: i32) -> bool {
            px >= self.x && px < self.x + self.w && py >= self.y && py < self.y + self.h
        }
        fn intersect(&self, o: &Rect) -> Option<Rect> {
            let x0 = self.x.max(o.x);
            let y0 = self.y.max(o.y);
            let x1 = (self.x + self.w).min(o.x + o.w);
            let y1 = (self.y + self.h).min(o.y + o.h);
            (x1 > x0 && y1 > y0).then_some(Rect { x: x0, y: y0, w: x1 - x0, h: y1 - y0 })
        }
    }

    impl X {
        pub fn connect() -> Option<X> {
            let (conn, screen) = x11rb::connect(None).ok()?;
            let root = conn.setup().roots[screen].root;
            Some(X { conn, root })
        }

        fn atom(&self, name: &str) -> Option<u32> {
            Some(self.conn.intern_atom(false, name.as_bytes()).ok()?.reply().ok()?.atom)
        }

        pub fn pointer(&self) -> Option<(i32, i32)> {
            let r = self.conn.query_pointer(self.root).ok()?.reply().ok()?;
            Some((r.root_x as i32, r.root_y as i32))
        }

        fn cardinals(&self, name: &str) -> Vec<i32> {
            let Some(a) = self.atom(name) else { return vec![] };
            let Ok(c) = self.conn.get_property(false, self.root, a, AtomEnum::CARDINAL, 0, 4096) else { return vec![] };
            let Ok(r) = c.reply() else { return vec![] };
            r.value32().map(|v| v.map(|x| x as i32).collect()).unwrap_or_default()
        }

        // 작업 영역들: Mutter 의 모니터별 값(_GTK_WORKAREAS_Dn)이 있으면 그것, 없으면 _NET_WORKAREA
        pub fn workareas(&self) -> Vec<Rect> {
            let desk = self.cardinals("_NET_CURRENT_DESKTOP").first().cloned().unwrap_or(0);
            let per = self.cardinals(&format!("_GTK_WORKAREAS_D{desk}"));
            let list = if !per.is_empty() { per } else { self.cardinals("_NET_WORKAREA").into_iter().skip(desk as usize * 4).take(4).collect() };
            list.chunks(4).filter(|c| c.len() == 4).map(|c| Rect { x: c[0], y: c[1], w: c[2], h: c[3] }).collect()
        }

        // 알림 창으로 표시: 항상 위, 작업 표시줄·창 전환에 안 보임, 입력 초점 받지 않음
        pub fn mark_notification(&self, xid: u32) {
            let atom = |n: &str| self.atom(n).unwrap_or(0);
            let _ = self.conn.change_property32(PropMode::REPLACE, xid, atom("_NET_WM_WINDOW_TYPE"), AtomEnum::ATOM, &[atom("_NET_WM_WINDOW_TYPE_NOTIFICATION")]);
            let _ = self.conn.change_property32(
                PropMode::REPLACE,
                xid,
                atom("_NET_WM_STATE"),
                AtomEnum::ATOM,
                &[atom("_NET_WM_STATE_ABOVE"), atom("_NET_WM_STATE_SKIP_TASKBAR"), atom("_NET_WM_STATE_SKIP_PAGER"), atom("_NET_WM_STATE_STICKY")],
            );
            // WM_HINTS: flags=InputHint(1), input=False
            let _ = self.conn.change_property32(PropMode::REPLACE, xid, AtomEnum::WM_HINTS, AtomEnum::WM_HINTS, &[1, 0, 0, 0, 0, 0, 0, 0, 0]);
            let _ = self.conn.flush();
        }

        pub fn move_to(&self, xid: u32, x: i32, y: i32) {
            // WM_NORMAL_HINTS 에 사용자 위치(USPosition|PPosition)를 적어 창 관리자가 자리를 바꾸지 않게
            let hints = [1u32 | 4, x as u32, y as u32, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
            let _ = self.conn.change_property32(PropMode::REPLACE, xid, AtomEnum::WM_NORMAL_HINTS, AtomEnum::WM_SIZE_HINTS, &hints);
            let _ = self.conn.configure_window(xid, &ConfigureWindowAux::new().x(x).y(y));
            let _ = self.conn.flush();
        }
    }

    // 모니터들(장치 화소). GDK 는 논리 좌표를 주므로 배율을 곱한다.
    pub fn monitors() -> Vec<Rect> {
        let Some(d) = gdk::Display::default() else { return vec![] };
        let list = d.monitors();
        (0..list.n_items())
            .filter_map(|i| list.item(i).and_then(|o| o.downcast::<gdk::Monitor>().ok()))
            .map(|m| {
                let g = m.geometry();
                let s = m.scale_factor();
                Rect { x: g.x() * s, y: g.y() * s, w: g.width() * s, h: g.height() * s }
            })
            .collect()
    }

    // 커서가 있는 모니터와 그 작업 영역에서 창 왼쪽 위 자리(장치 화소)
    pub fn place(x: &X, panel_w: i32, right: bool) -> Option<((i32, i32), Rect)> {
        let (px, py) = x.pointer().unwrap_or((0, 0));
        let mons = monitors();
        let mon = mons.iter().find(|m| m.contains(px, py)).or(mons.first()).cloned()?;
        let area = x.workareas().iter().filter_map(|w| w.intersect(&mon)).max_by_key(|r| r.w * r.h).unwrap_or(mon);
        let scale = {
            let d = gdk::Display::default()?;
            let list = d.monitors();
            list.item(0).and_then(|o| o.downcast::<gdk::Monitor>().ok()).map(|m| m.scale_factor()).unwrap_or(1)
        };
        let w = panel_w * scale;
        let left = if right { area.x + area.w - w - 2 * scale } else { mon.x + mon.w / 2 - w / 2 };
        Some(((left, area.y), mon))
    }

    pub fn monitor_of(px: i32, py: i32) -> Option<Rect> {
        monitors().into_iter().find(|m| m.contains(px, py))
    }

    // GTK 창의 X 창 번호(리눅스 X11 판의 libgtk-4 에 있는 함수)
    #[cfg(target_os = "linux")]
    pub fn xid(win: &gtk::Window) -> Option<u32> {
        use gtk::glib::translate::ToGlibPtr;
        extern "C" {
            fn gdk_x11_surface_get_xid(surface: *mut gdk::ffi::GdkSurface) -> std::os::raw::c_ulong;
        }
        let s = win.surface()?;
        if !s.type_().name().contains("X11") {
            return None;
        }
        let id = unsafe { gdk_x11_surface_get_xid(s.to_glib_none().0) };
        (id != 0).then_some(id as u32)
    }

    #[cfg(not(target_os = "linux"))]
    pub fn xid(_win: &gtk::Window) -> Option<u32> {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::needs_place;

    // 알림 위치를 바꾸면 떠 있는 창도 다음 알림에서 다시 놓는다(맥 SettingsQATests 와 같은 표)
    #[test]
    fn position_change_replaces_shown_window() {
        assert!(needs_place(true, Some(false), true));
        assert!(needs_place(true, Some(true), false));
        assert!(!needs_place(true, Some(true), true));
        assert!(needs_place(false, Some(true), true));
        assert!(needs_place(true, None, false));
    }
}
