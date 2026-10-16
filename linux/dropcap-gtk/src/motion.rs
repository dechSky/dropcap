// 움직임 줄이기(N-17·N-24): GTK 설정 gtk-enable-animations 가 꺼져 있으면 움직임 없이.
// DROPCAP_REDUCE_MOTION=1 로 시험할 수 있다.

pub fn enabled() -> bool {
    if std::env::var("DROPCAP_REDUCE_MOTION").as_deref() == Ok("1") {
        return false;
    }
    gtk::Settings::default().map(|s| s.is_gtk_enable_animations()).unwrap_or(true)
}

// 디자인 시스템 움직임 토큰(docs/DESIGN.md · 맥 UI/DesignSystem.swift Motion 과 같은 값, 밀리초)
pub const QUICK: u32 = 150; // 올림·누름·나감
pub const STANDARD: u32 = 250; // 나타남·내용 바뀜·창 열기
pub const SLOW: u32 = 400; // 사진 뜸·큰 것
pub const SETTLE: u32 = 500; // 지면 넘김·카드 깔림(맥 settle 스프링이 자리 잡는 시간)
pub const STAGGER: u64 = 40; // 차례로 깔림 한 칸
pub const STAGGER_MAX: u64 = 300;

// 곡선: 들어옴(감속 — 맥 0.2,0.9,0.25,1 에 가장 가까운 것) · 나감(가속) · 자리 안 바뀜
pub const ENTER: adw::Easing = adw::Easing::EaseOutQuint;
pub const EXIT: adw::Easing = adw::Easing::EaseInCubic;
pub const CHANGE: adw::Easing = adw::Easing::EaseInOutCubic;

pub fn stagger(order: usize) -> u64 {
    (order as u64 * STAGGER).min(STAGGER_MAX)
}

// 창 열기: 모든 앱 창(읽기·매거진·분야 고르기·설정·사진)이 같은 방식으로 나타난다(STANDARD, ENTER).
// GTK4 는 최상위 창의 크기를 움직일 수 없어 맥의 '살짝 커짐'(0.96 → 1) 없이 투명도만 0 → 1.
// 이미 열린 창을 앞으로 부를 땐 움직이지 않는다(그냥 present). 움직임 줄이기면 바로 보인다.
pub fn present(win: &impl gtk::prelude::IsA<gtk::Window>) {
    use gtk::prelude::*;
    let win = win.as_ref().clone();
    if !enabled() {
        win.present();
        return;
    }
    win.set_opacity(0.0);
    win.present();
    let target = adw::CallbackAnimationTarget::new({
        let w = win.clone();
        move |v| w.set_opacity(v)
    });
    let a = adw::TimedAnimation::new(&win, 0.0, 1.0, STANDARD, target);
    a.set_easing(ENTER);
    adw::prelude::AnimationExt::play(&a);
}
