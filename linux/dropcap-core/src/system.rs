// 운영체제와 맞닿는 작은 일: 하나만 실행(C-12), 로그인할 때 자동 실행(P-05 · XDG autostart).
use std::fs::File;
use std::path::{Path, PathBuf};

// 데이터 폴더의 dropcap.lock 을 잠근다. 이미 다른 실행이 잡고 있으면 None → 바로 종료.
// 잠금은 돌려받은 File 이 살아 있는 동안 유지된다(프로세스가 죽으면 운영체제가 풀어 준다).
pub fn single_instance(dir: &Path) -> Option<File> {
    use std::os::unix::io::AsRawFd;
    let f = File::options().create(true).truncate(false).write(true).open(dir.join("dropcap.lock")).ok()?;
    let r = unsafe { libc::flock(f.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if r == 0 {
        Some(f)
    } else {
        None
    }
}

pub fn autostart_dir() -> PathBuf {
    if let Ok(x) = std::env::var("XDG_CONFIG_HOME") {
        if !x.is_empty() && Path::new(&x).is_absolute() {
            return PathBuf::from(x).join("autostart");
        }
    }
    crate::store::home_dir().join(".config/autostart")
}

pub const AUTOSTART_FILE: &str = "io.github.dechsky.Dropcap.desktop";

// 실행 파일 경로: AppImage 로 돌면 $APPIMAGE(옮겨도 그 파일), 아니면 지금 실행 파일
pub fn exec_path() -> String {
    std::env::var("APPIMAGE").ok().filter(|s| !s.is_empty()).unwrap_or_else(|| {
        std::env::current_exe().map(|p| p.to_string_lossy().to_string()).unwrap_or_else(|_| "dropcap".into())
    })
}

pub fn autostart_entry(exec: &str) -> String {
    let quoted = if exec.contains(' ') { format!("\"{exec}\"") } else { exec.to_string() };
    format!(
        "[Desktop Entry]\nType=Application\nName=Dropcap\nComment=AI 소식 매거진·알림\nExec={quoted} --background\nIcon=io.github.dechsky.Dropcap\nTerminal=false\nX-GNOME-Autostart-enabled=true\nX-GNOME-Autostart-Delay=5\n"
    )
}

pub fn launch_at_login(dir: &Path) -> bool {
    dir.join(AUTOSTART_FILE).exists()
}

pub fn set_launch_at_login(dir: &Path, on: bool, exec: &str) -> std::io::Result<()> {
    let f = dir.join(AUTOSTART_FILE);
    if on {
        std::fs::create_dir_all(dir)?;
        crate::store::write_atomic(&f, autostart_entry(exec).as_bytes())
    } else if f.exists() {
        std::fs::remove_file(f)
    } else {
        Ok(())
    }
}
