// 소리 내어 읽기(R-09): speech-dispatcher 의 spd-say 로, 보이는 언어(번역이면 한국어, 원문이면 영어)의 목소리.
// 문단마다 하나씩 기다리며 읽고(-w), 멈추면 spd-say -C 로 이 앱이 보낸 말을 모두 취소한다. 창을 닫으면 멈춘다.
// speech 기능이 꺼졌거나 spd-say 가 없으면 단추를 숨긴다.
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;

pub struct Speaker {
    speaking: Arc<AtomicBool>,
    generation: Arc<AtomicU64>, // 멈춘 뒤 이전 읽기 줄이 계속되지 않게
}

pub fn available() -> bool {
    if !cfg!(feature = "speech") {
        return false;
    }
    std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).any(|d| d.join("spd-say").is_file()))
        .unwrap_or(false)
}

impl Speaker {
    pub fn new() -> Speaker {
        Speaker { speaking: Arc::new(AtomicBool::new(false)), generation: Arc::new(AtomicU64::new(0)) }
    }

    pub fn speaking(&self) -> bool {
        self.speaking.load(Ordering::SeqCst)
    }

    // done: 다 읽었거나 멈췄을 때(메인 루프에서 부름)
    pub fn toggle(&self, title: &str, paragraphs: &[String], korean: bool, done: impl Fn() + 'static) {
        if self.speaking() {
            self.stop();
            done();
            return;
        }
        let texts: Vec<String> = std::iter::once(title.to_string()).chain(paragraphs.iter().cloned()).filter(|t| !t.trim().is_empty()).collect();
        let lang = if korean { "ko" } else { "en" };
        let gen = self.generation.fetch_add(1, Ordering::SeqCst) + 1;
        let generation = self.generation.clone();
        let speaking = self.speaking.clone();
        speaking.store(true, Ordering::SeqCst);
        let (tx, rx) = async_channel::bounded::<()>(1);
        std::thread::spawn(move || {
            for t in texts {
                if generation.load(Ordering::SeqCst) != gen {
                    break;
                }
                let _ = std::process::Command::new("spd-say").args(["-w", "-l", lang, "-r", if korean { "5" } else { "0" }, "--"]).arg(&t).status();
            }
            if generation.load(Ordering::SeqCst) == gen {
                speaking.store(false, Ordering::SeqCst);
            }
            let _ = tx.send_blocking(());
        });
        gtk::glib::spawn_future_local(async move {
            let _ = rx.recv().await;
            done();
        });
    }

    pub fn stop(&self) {
        if !self.speaking() {
            return;
        }
        self.generation.fetch_add(1, Ordering::SeqCst);
        self.speaking.store(false, Ordering::SeqCst);
        let _ = std::process::Command::new("spd-say").arg("-C").status();
    }
}
