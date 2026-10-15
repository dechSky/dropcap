// 회의·발표 중 자동 조용히(N-25 · D-8) — 맥 Core/FocusGuard.swift.
// 전체 화면 앱을 쓰는 중, 화면을 공유·기록하는 중이면 물방울 대신 고이게 한다(방해 금지와 같은 길).
// 리눅스:
//   ① 전체 화면: 화면 쪽(X11)이 '앞에 있는 다른 앱 창이 전체 화면 상태인가'를 알려 준다(set_fullscreen_probe).
//      Wayland 는 다른 앱 창의 상태를 알 공개 방법이 없어 감지하지 않는다.
//   ② 화면 공유·기록: 그때만 떠 있는 프로세스 이름(/proc/*/comm). 맥의 CptHost·screencaptureui 에 해당하는 리눅스 도구.
//   ③ 캘린더: 리눅스에는 데스크톱 공통 일정 저장소가 없어(Evolution Data Server 는 GNOME 전용) 쓰지 않는다.
//      설정 값(autoQuietCalendar)은 상태 파일 호환을 위해 읽고 쓰기만 한다.
use crate::store::Settings;
use once_cell::sync::Lazy;
use std::sync::Mutex;
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FocusReason {
    Fullscreen,
    Sharing,
    Calendar,
}

impl FocusReason {
    pub fn label(&self) -> &'static str {
        match self {
            FocusReason::Fullscreen => "전체 화면 사용 중",
            FocusReason::Sharing => "화면 공유·기록 중",
            FocusReason::Calendar => "캘린더 일정 중",
        }
    }
    pub fn from_raw(s: &str) -> Option<FocusReason> {
        match s {
            "fullscreen" => Some(FocusReason::Fullscreen),
            "sharing" => Some(FocusReason::Sharing),
            "calendar" => Some(FocusReason::Calendar),
            _ => None,
        }
    }
}

// 화면을 공유·기록하는 동안에만 떠 있는 프로세스(/proc/*/comm 은 15자까지라 잘린 이름으로)
// obs: OBS Studio · simplescreenrec: SimpleScreenRecorder · kazam·peek·kooha·vokoscreenNG: 화면 기록 앱 ·
// wf-recorder·wl-screenrec: Wayland 화면 기록 · gpu-screen-reco: GPU Screen Recorder.
// Zoom·Meet·Teams 의 화면 공유는 리눅스에서 따로 뜨는 프로세스가 없어(같은 프로세스 · 포털/PipeWire) 알 수 없다 → 전체 화면으로만 잡힌다.
pub const SHARING_PROCESSES: &[&str] =
    &["obs", "simplescreenrec", "kazam", "peek", "kooha", "vokoscreenNG", "wf-recorder", "wl-screenrec", "gpu-screen-reco"];

pub fn sharing(process_names: &[String]) -> bool {
    process_names.iter().any(|n| SHARING_PROCESSES.contains(&n.as_str()))
}

// 일정 중인가: 하루 종일 일정·'한가함'·거절한 일정은 빼고, 지금이 시작~끝 사이(맥과 같은 판정 — 리눅스는 일정을 읽지 않음)
#[derive(Debug, Clone, PartialEq)]
pub struct EventInfo {
    pub start: chrono::DateTime<chrono::Utc>,
    pub end: chrono::DateTime<chrono::Utc>,
    pub all_day: bool,
    pub free: bool,
    pub declined: bool,
}
pub fn in_event(events: &[EventInfo], now: chrono::DateTime<chrono::Utc>) -> bool {
    events.iter().any(|e| !e.all_day && !e.free && !e.declined && e.start <= now && now < e.end)
}

// 지금 떠 있는 프로세스 이름
pub fn live_process_names() -> Vec<String> {
    let Ok(rd) = std::fs::read_dir("/proc") else { return vec![] };
    let mut out = vec![];
    for e in rd.flatten() {
        let name = e.file_name();
        if !name.to_string_lossy().bytes().all(|b| b.is_ascii_digit()) {
            continue;
        }
        if let Ok(c) = std::fs::read_to_string(e.path().join("comm")) {
            out.push(c.trim().to_string());
        }
    }
    out
}

type Probe = Box<dyn Fn() -> bool + Send + Sync>;

// 앱 안에서 쓰는 쪽: 설정을 따라 지금 조용히 할 이유를 알려 준다(15초 동안 기억 — 확인·1분 타이머가 자주 묻지 않게)
pub struct FocusMonitor {
    cached: Mutex<Option<(Instant, Option<FocusReason>)>>,
    fullscreen: Mutex<Option<Probe>>,
    override_: Mutex<Option<Option<FocusReason>>>, // 시험용: 감지 결과를 정해 둔다
}

pub static MONITOR: Lazy<FocusMonitor> = Lazy::new(|| {
    let m = FocusMonitor { cached: Mutex::new(None), fullscreen: Mutex::new(None), override_: Mutex::new(None) };
    // 시험용: DROPCAP_TEST_FOCUS=fullscreen|sharing|calendar|none
    if let Some(v) = crate::test_hooks::var("DROPCAP_TEST_FOCUS") {
        *m.override_.lock().unwrap() = Some(FocusReason::from_raw(&v));
    }
    m
});

pub const CACHE_SECS: u64 = 15;

impl FocusMonitor {
    pub fn set_fullscreen_probe(&self, f: Probe) {
        *self.fullscreen.lock().unwrap() = Some(f);
        self.invalidate();
    }
    pub fn set_override(&self, r: Option<Option<FocusReason>>) {
        *self.override_.lock().unwrap() = r;
    }
    pub fn invalidate(&self) {
        *self.cached.lock().unwrap() = None;
    }

    pub fn reason(&self, s: &Settings) -> Option<FocusReason> {
        if let Some(o) = *self.override_.lock().unwrap() {
            return o;
        }
        if let Some((at, r)) = *self.cached.lock().unwrap() {
            if at.elapsed() < Duration::from_secs(CACHE_SECS) {
                return r;
            }
        }
        let r = self.detect(s);
        *self.cached.lock().unwrap() = Some((Instant::now(), r));
        r
    }

    fn detect(&self, s: &Settings) -> Option<FocusReason> {
        if s.auto_quiet_fullscreen {
            if let Some(p) = self.fullscreen.lock().unwrap().as_ref() {
                if p() {
                    return Some(FocusReason::Fullscreen);
                }
            }
        }
        if s.auto_quiet_sharing && sharing(&live_process_names()) {
            return Some(FocusReason::Sharing);
        }
        None
    }
}
