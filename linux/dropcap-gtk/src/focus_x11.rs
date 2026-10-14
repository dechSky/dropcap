// 회의·발표 중 자동 조용히(N-25)의 '전체 화면' 감지 — X11.
// 앞에 있는 창(_NET_ACTIVE_WINDOW)이 전체 화면 상태(_NET_WM_STATE_FULLSCREEN)이고 Dropcap 자신의 창이 아니면 참.
// 창 이름·내용은 읽지 않는다. Wayland 에서는 다른 앱 창의 상태를 알 공개 방법이 없어 넣지 않는다(화면 공유·기록 감지만).
#[cfg(feature = "x11")]
pub fn install() {
    if std::env::var_os("WAYLAND_DISPLAY").is_some() || std::env::var_os("DISPLAY").is_none() {
        return;
    }
    dropcap_core::focus_guard::MONITOR.set_fullscreen_probe(Box::new(|| front_is_fullscreen().unwrap_or(false)));
}

#[cfg(not(feature = "x11"))]
pub fn install() {}

#[cfg(feature = "x11")]
fn front_is_fullscreen() -> Result<bool, Box<dyn std::error::Error>> {
    use x11rb::connection::Connection;
    use x11rb::protocol::xproto::{AtomEnum, ConnectionExt};
    let (conn, screen) = x11rb::connect(None)?;
    let root = conn.setup().roots[screen].root;
    let atom = |n: &str| -> Result<u32, Box<dyn std::error::Error>> { Ok(conn.intern_atom(false, n.as_bytes())?.reply()?.atom) };
    let active = conn.get_property(false, root, atom("_NET_ACTIVE_WINDOW")?, AtomEnum::WINDOW, 0, 1)?.reply()?;
    let Some(win) = active.value32().and_then(|mut v| v.next()).filter(|w| *w != 0) else { return Ok(false) };
    let pid = conn.get_property(false, win, atom("_NET_WM_PID")?, AtomEnum::CARDINAL, 0, 1)?.reply()?.value32().and_then(|mut v| v.next());
    if pid == Some(std::process::id()) {
        return Ok(false); // Dropcap 자신(매거진 전체 화면)
    }
    let full = atom("_NET_WM_STATE_FULLSCREEN")?;
    let state = conn.get_property(false, win, atom("_NET_WM_STATE")?, AtomEnum::ATOM, 0, 64)?.reply()?;
    Ok(state.value32().map(|mut v| v.any(|a| a == full)).unwrap_or(false))
}
