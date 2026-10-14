// 전역 단축키(H-01·H-02): X11 에서만 Ctrl+Alt+N(가장 최근 안 읽은 소식)·Ctrl+Alt+M(매거진).
// Wayland 는 앱이 전역 단축키를 잡을 수 없어 ⊘(설정 › 거르기 › 단축키에 안내).

#[cfg_attr(not(feature = "x11"), allow(dead_code))]
// 지금 세션이 X11 인가(XWayland 의 DISPLAY 만 있는 Wayland 세션은 아님)
pub fn is_x11_session() -> bool {
    let has_display = std::env::var("DISPLAY").map(|s| !s.is_empty()).unwrap_or(false);
    let wayland = std::env::var("WAYLAND_DISPLAY").map(|s| !s.is_empty()).unwrap_or(false)
        || std::env::var("XDG_SESSION_TYPE").map(|s| s == "wayland").unwrap_or(false);
    has_display && !wayland
}

pub fn is_wayland_session() -> bool {
    std::env::var("WAYLAND_DISPLAY").map(|s| !s.is_empty()).unwrap_or(false)
        || std::env::var("XDG_SESSION_TYPE").map(|s| s == "wayland").unwrap_or(false)
}

#[cfg(feature = "x11")]
mod imp {
    use gtk::glib;
    use std::sync::atomic::{AtomicBool, Ordering};
    use x11rb::connection::Connection;
    use x11rb::protocol::xproto::{ConnectionExt, GrabMode, ModMask};
    use x11rb::protocol::Event;

    static RUNNING: AtomicBool = AtomicBool::new(false);

    const XK_N: u32 = 0x006e;
    const XK_M: u32 = 0x006d;

    #[derive(Clone, Copy)]
    enum Key {
        Latest,
        Magazine,
    }

    pub fn start() {
        if !super::is_x11_session() {
            return;
        }
        let (tx, rx) = async_channel::unbounded::<Key>();
        let spawned = std::thread::Builder::new().name("dropcap-hotkeys".into()).spawn(move || {
            if let Err(e) = run(tx) {
                log::warn!("[단축키] 잡지 못함: {e}");
            }
        });
        if spawned.is_err() {
            return;
        }
        glib::spawn_future_local(async move {
            while let Ok(k) = rx.recv().await {
                let ui = crate::app::ui();
                match k {
                    Key::Latest => {
                        if let Some(it) = ui.core.latest_unread() {
                            crate::app::open_item(&it, None);
                        }
                    }
                    Key::Magazine => crate::magazine::open(),
                }
            }
        });
    }

    fn run(tx: async_channel::Sender<Key>) -> Result<(), Box<dyn std::error::Error>> {
        let (conn, screen) = x11rb::connect(None)?;
        let root = conn.setup().roots[screen].root;
        let min = conn.setup().min_keycode;
        let max = conn.setup().max_keycode;
        let map = conn.get_keyboard_mapping(min, max - min + 1)?.reply()?;
        let per = map.keysyms_per_keycode as usize;
        let code_of = |sym: u32| -> Option<u8> {
            map.keysyms.chunks(per.max(1)).position(|c| c.contains(&sym)).map(|i| min + i as u8)
        };
        let n = code_of(XK_N).ok_or("N 키를 찾지 못함")?;
        let m = code_of(XK_M).ok_or("M 키를 찾지 못함")?;
        let base = ModMask::CONTROL | ModMask::M1;
        // NumLock(M2)·CapsLock(LOCK)이 켜져 있어도 걸리게 조합을 모두 잡는다
        let extras = [ModMask::from(0u16), ModMask::LOCK, ModMask::M2, ModMask::LOCK | ModMask::M2];
        for code in [n, m] {
            for e in extras {
                conn.grab_key(true, root, base | e, code, GrabMode::ASYNC, GrabMode::ASYNC)?.check()?;
            }
        }
        conn.flush()?;
        RUNNING.store(true, Ordering::SeqCst);
        log::info!("[단축키] Ctrl+Alt+N · Ctrl+Alt+M");
        loop {
            if let Event::KeyPress(k) = conn.wait_for_event()? {
                let key = if k.detail == n { Key::Latest } else if k.detail == m { Key::Magazine } else { continue };
                if tx.send_blocking(key).is_err() {
                    return Ok(());
                }
            }
        }
    }

    pub fn supported() -> bool {
        super::is_x11_session()
    }

    #[allow(dead_code)]
    pub fn running() -> bool {
        RUNNING.load(Ordering::SeqCst)
    }
}

#[cfg(feature = "x11")]
pub use imp::{start, supported};

#[cfg(not(feature = "x11"))]
pub fn start() {}
#[cfg(not(feature = "x11"))]
pub fn supported() -> bool {
    false
}

// 설정 화면의 안내 문구
pub fn note() -> Option<&'static str> {
    if supported() {
        None
    } else if is_wayland_session() {
        Some("Wayland 에서는 전역 단축키를 쓸 수 없습니다. X11 세션에서만 동작합니다.")
    } else {
        Some("이 빌드에서는 전역 단축키를 쓸 수 없습니다(X11 기능이 꺼져 있음).")
    }
}
