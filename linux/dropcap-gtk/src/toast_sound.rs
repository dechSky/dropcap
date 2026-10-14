// "똑" 하는 물방울 소리를 파일 없이 즉석에서 만든다(맥 Toast/DropSound.swift 와 같은 합성):
// 높은음에서 빠르게 떨어지는 짧은 사인파 두 개. 재생은 GTK 미디어(GStreamer)로, 안 되면 paplay·pw-play·aplay.
use gtk::prelude::*;
use gtk::{gio, glib};
use once_cell::sync::Lazy;
use std::cell::RefCell;

const RATE: f64 = 44100.0;
const VOLUME: f64 = 0.6; // 맥 NSSound.volume

pub fn samples() -> Vec<i16> {
    let length = (RATE * 0.2) as usize;
    let mut s = vec![0f64; length];
    let mut tone = |f0: f64, f1: f64, start: f64, dur: f64, vol: f64| {
        let mut phase = 0.0;
        let s0 = (start * RATE) as usize;
        let n = (dur * RATE) as usize;
        for i in 0..n {
            if s0 + i >= length {
                break;
            }
            let t = i as f64 / n as f64;
            let f = f0 * (f1 / f0).powf(t); // 지수로 내려가는 음높이
            phase += 2.0 * std::f64::consts::PI * f / RATE;
            let attack = (i as f64 / (0.006 * RATE)).min(1.0);
            let env = attack * (1.0 - t).powf(2.2); // 빠르게 사라짐
            s[s0 + i] = (s[s0 + i] + phase.sin() * env * vol * 32767.0).clamp(-32767.0, 32767.0);
        }
    };
    tone(1500.0, 620.0, 0.0, 0.11, 0.32);
    tone(2100.0, 1300.0, 0.07, 0.08, 0.10);
    s.into_iter().map(|v| (v * VOLUME) as i16).collect()
}

pub fn wav(samples: &[i16]) -> Vec<u8> {
    let mut d = Vec::with_capacity(44 + samples.len() * 2);
    let bytes = (samples.len() * 2) as u32;
    let rate = RATE as u32;
    d.extend_from_slice(b"RIFF");
    d.extend_from_slice(&(36 + bytes).to_le_bytes());
    d.extend_from_slice(b"WAVEfmt ");
    d.extend_from_slice(&16u32.to_le_bytes());
    d.extend_from_slice(&1u16.to_le_bytes());
    d.extend_from_slice(&1u16.to_le_bytes());
    d.extend_from_slice(&rate.to_le_bytes());
    d.extend_from_slice(&(rate * 2).to_le_bytes());
    d.extend_from_slice(&2u16.to_le_bytes());
    d.extend_from_slice(&16u16.to_le_bytes());
    d.extend_from_slice(b"data");
    d.extend_from_slice(&bytes.to_le_bytes());
    for v in samples {
        d.extend_from_slice(&v.to_le_bytes());
    }
    d
}

static WAV: Lazy<Vec<u8>> = Lazy::new(|| wav(&samples()));

thread_local! {
    static MEDIA: RefCell<Option<gtk::MediaFile>> = const { RefCell::new(None) };
}

// 미디어 백엔드가 있으면 그걸로(지연이 가장 짧음)
fn play_media() -> bool {
    MEDIA.with(|m| {
        let mut m = m.borrow_mut();
        if m.is_none() {
            let stream = gio::MemoryInputStream::from_bytes(&glib::Bytes::from(&WAV[..]));
            let f = gtk::MediaFile::for_input_stream(&stream);
            *m = Some(f);
        }
        let f = m.as_ref().unwrap();
        if f.error().is_some() {
            return false;
        }
        f.set_volume(1.0);
        if f.is_prepared() {
            f.seek(0);
        }
        f.play();
        // 준비가 안 되는 환경(미디어 백엔드 없음)은 오류가 바로 생긴다
        f.error().is_none()
    })
}

fn play_command() {
    // 공용 임시 폴더의 정해진 이름은 다른 사용자가 미리 만들어 둘 수 있으므로 쓰지 않는다:
    // 이 사용자만 쓰는 앱 데이터 폴더에, 이미 있는 파일을 믿지 않고 매번 원자적으로 새로 쓴다.
    let path = dropcap_core::store::DIR.join("drop-sound.wav");
    if dropcap_core::store::write_atomic(&path, &WAV[..]).is_err() {
        return;
    }
    std::thread::spawn(move || {
        for cmd in ["pw-play", "paplay", "aplay", "afplay"] {
            let ok = std::process::Command::new(cmd)
                .arg(&path)
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status()
                .map(|s| s.success())
                .unwrap_or(false);
            if ok {
                return;
            }
        }
    });
}

thread_local! {
    static MEDIA_OK: RefCell<Option<bool>> = const { RefCell::new(None) };
}

pub fn play() {
    // 미디어 백엔드가 한 번 실패하면 그다음부터는 바로 명령으로
    let known = MEDIA_OK.with(|k| *k.borrow());
    if known != Some(false) && play_media() {
        MEDIA_OK.with(|k| *k.borrow_mut() = Some(true));
        return;
    }
    MEDIA_OK.with(|k| *k.borrow_mut() = Some(false));
    play_command();
}
