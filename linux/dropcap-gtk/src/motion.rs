// 움직임 줄이기(N-17·N-24): GTK 설정 gtk-enable-animations 가 꺼져 있으면 움직임 없이.
// DROPCAP_REDUCE_MOTION=1 로 시험할 수 있다.

pub fn enabled() -> bool {
    if std::env::var("DROPCAP_REDUCE_MOTION").as_deref() == Ok("1") {
        return false;
    }
    gtk::Settings::default().map(|s| s.is_gtk_enable_animations()).unwrap_or(true)
}
