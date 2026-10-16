// 키보드 탐색(H-03~H-05 · 맥 UI/KeyNav.swift): 상단바 목록·매거진 카드·읽기 창이 같은 키를 쓴다.
//   ↑↓ 또는 K·J  선택 이동 · ⏎ 열기 · S 나중에 읽기 · O 브라우저 · M 읽음/안 읽음
//   매거진: Ctrl+[ · Ctrl+] 지면 넘기기 · 읽기 창: J·K 다음·이전 기사(연 목록의 순서), Esc 닫기
use crate::app::{open_external, open_from_magazine_in, open_item_in, ui};
use dropcap_core::models::NewsItem;
use gtk::prelude::*;
use gtk::{gdk, glib};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NavKey {
    Next,
    Prev,
    Open,
    Save,
    Browser,
    ToggleRead,
}

impl NavKey {
    // 컨트롤·알트·슈퍼 키가 함께 눌렸으면 탐색 키가 아니다(Ctrl+S 같은 다른 단축키와 겹치지 않게)
    pub fn from(key: gdk::Key, state: gdk::ModifierType) -> Option<NavKey> {
        if state.intersects(gdk::ModifierType::CONTROL_MASK | gdk::ModifierType::ALT_MASK | gdk::ModifierType::SUPER_MASK | gdk::ModifierType::META_MASK) {
            return None;
        }
        Some(match key {
            gdk::Key::Down | gdk::Key::KP_Down | gdk::Key::j | gdk::Key::J => NavKey::Next,
            gdk::Key::Up | gdk::Key::KP_Up | gdk::Key::k | gdk::Key::K => NavKey::Prev,
            gdk::Key::Return | gdk::Key::KP_Enter => NavKey::Open,
            gdk::Key::s | gdk::Key::S => NavKey::Save,
            gdk::Key::o | gdk::Key::O => NavKey::Browser,
            gdk::Key::m | gdk::Key::M => NavKey::ToggleRead,
            _ => return None,
        })
    }
}

// 목록 안에서 선택을 옮긴다(끝에서는 멈춤). 선택이 없으면 처음(또는 끝)부터
pub fn step(selected: Option<&str>, keys: &[String], d: i64) -> Option<String> {
    if keys.is_empty() {
        return None;
    }
    let Some(i) = selected.and_then(|s| keys.iter().position(|k| k == s)) else {
        return Some(if d > 0 { keys[0].clone() } else { keys[keys.len() - 1].clone() });
    };
    let j = (i as i64 + d).clamp(0, keys.len() as i64 - 1) as usize;
    Some(keys[j].clone())
}

// 단축키 안내(설정 '단축키' 절)
pub const HELP: &[(&str, &str)] = &[
    ("↓ / J · ↑ / K", "다음·이전 소식 고르기 (상단바 목록·매거진 카드)"),
    ("Enter", "고른 소식 열기"),
    ("S", "나중에 읽기 / 저장 취소"),
    ("O", "브라우저에서 열기"),
    ("M", "읽음 / 안 읽음"),
    ("Ctrl+[ · Ctrl+]", "매거진 이전·다음 지면"),
    ("J · K (읽기 창)", "같은 목록의 다음·이전 기사"),
    ("Esc (읽기 창)", "창 닫기"),
    ("Ctrl+,", "설정 열기 (매거진·읽기 창)"),
];

// 고른 소식에 키 동작을 한다
pub fn perform(k: NavKey, item: &NewsItem, sequence: &[NewsItem], from_magazine: bool) {
    let core = ui().core.clone();
    match k {
        NavKey::Open => {
            if from_magazine {
                open_from_magazine_in(item, None, sequence.to_vec());
            } else {
                open_item_in(item, None, sequence.to_vec());
            }
        }
        NavKey::Save => core.toggle_saved(item),
        NavKey::Browser => {
            open_external(&item.link);
            core.set_read(item, true);
        }
        NavKey::ToggleRead => {
            let r = core.is_read(item);
            core.set_read(item, !r);
        }
        NavKey::Next | NavKey::Prev => {}
    }
}

// 고른 카드·줄 표시(강조색 2.5pt 테두리 + 옅은 빛)
pub fn mark(w: &gtk::Widget, on: bool) {
    if on {
        w.add_css_class("dc-selected");
    } else {
        w.remove_css_class("dc-selected");
    }
}

// 고른 것을 화면 가운데로(움직임 줄이기면 애니메이션 없이)
pub fn center(scroll: &gtk::ScrolledWindow, w: &gtk::Widget) {
    let Some(mut child) = scroll.child() else { return };
    // 스크롤 창이 감싼 Viewport 가 아니라 그 안의 내용 기준 자리(Viewport 기준이면 보이는 칸 안의 자리라 어긋남)
    if let Some(v) = child.downcast_ref::<gtk::Viewport>().and_then(|v| v.child()) {
        child = v;
    }
    let Some(b) = w.compute_bounds(&child) else { return };
    let adj = scroll.vadjustment();
    let target = (b.y() as f64 + b.height() as f64 / 2.0 - adj.page_size() / 2.0).clamp(adj.lower(), (adj.upper() - adj.page_size()).max(adj.lower()));
    if !crate::motion::enabled() {
        adj.set_value(target);
        return;
    }
    let from = adj.value();
    let a = adw::TimedAnimation::new(scroll, from, target, crate::motion::STANDARD, adw::CallbackAnimationTarget::new(move |v| adj.set_value(v)));
    a.set_easing(crate::motion::CHANGE);
    adw::prelude::AnimationExt::play(&a);
}

// 창에 키 처리기를 붙인다: f 가 true 를 돌려주면 그 키는 여기서 끝
pub fn attach(w: &impl IsA<gtk::Widget>, f: impl Fn(gdk::Key, gdk::ModifierType) -> bool + 'static) {
    let keys = gtk::EventControllerKey::new();
    keys.connect_key_pressed(move |_, key, _, state| if f(key, state) { glib::Propagation::Stop } else { glib::Propagation::Proceed });
    w.add_controller(keys);
}

// 지금 글자를 치는 칸에 입력 커서가 있는가(그때는 J/K/S/O/M 을 탐색 키로 쓰지 않는다)
pub fn typing(root: &impl IsA<gtk::Root>) -> bool {
    gtk::prelude::RootExt::focus(root.as_ref())
        .map(|f| f.is::<gtk::Text>() || f.is::<gtk::Entry>() || f.is::<gtk::SearchEntry>() || f.ancestor(gtk::SearchEntry::static_type()).is_some() || f.is::<gtk::TextView>())
        .unwrap_or(false)
}
