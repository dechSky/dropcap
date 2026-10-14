// 시스템 알림(N-18): org.freedesktop.Notifications(notify-rust).
// 최대 3건 + 넘치면 "AI 소식 N건 더". 누르면 읽기 창(맥 SystemNotifier 와 같은 문구).
use crate::strings;
use dropcap_core::models::{resources, NewsItem};

// 알림 본문은 서버에 따라 마크업(<a>·<img>·<b>)으로 해석되므로, 피드에서 온 글자는 모두 글자 그대로 보이게 바꾼다
// (링크·사진을 몰래 넣어 바깥 주소를 열거나 불러오게 하는 것을 막음)
pub fn escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;").replace('\'', "&#39;")
}

// 알림 제목·본문(맥 SystemNotifier.post 와 같음). 제목(summary)은 표준상 마크업이 아니지만 같은 처리를 한다.
pub fn content(it: &NewsItem) -> (String, String) {
    let title = format!("{} · {}", it.source_name, resources::tier_label(&it.tier));
    let body = match &it.title_ko {
        Some(ko) => format!("{}\n{}", escape(ko), escape(&it.title)),
        None => escape(&it.title),
    };
    (escape(&title), body)
}

// 묶음 알림(G-07, 맥 SystemNotifier.postBundle): "<분야> N건" + 제목 3줄
pub fn bundle_content(section: &str, items: &[NewsItem]) -> (String, String) {
    let title = format!("{} {}건", dropcap_core::sections::name(section), items.len());
    let body = items.iter().take(3).map(|i| escape(i.display_title())).collect::<Vec<_>>().join("\n");
    (escape(&title), body)
}

// 지켜볼 낱말 하루 정리(N-27, 맥 SystemNotifier.postWatch): "오늘 ○○ 소식 N건" + 제목 2줄
pub fn watch_content(word: &str, items: &[NewsItem]) -> (String, String) {
    let title = format!("오늘 {word} 소식 {}건", items.len());
    let body = items.iter().take(2).map(|i| escape(i.display_title())).collect::<Vec<_>>().join("\n");
    (escape(&title), body)
}

pub fn more_content(n: usize) -> (String, String) {
    (strings::more(n), "트레이 아이콘에서 볼 수 있습니다.".into())
}

#[cfg(all(feature = "notify", target_os = "linux"))]
mod imp {
    use super::{bundle_content, content, more_content, watch_content};
    use dropcap_core::models::NewsItem;
    use gtk::glib;
    use notify_rust::{Hint, Notification};
    use std::cell::RefCell;

    thread_local! {
        static TX: RefCell<Option<async_channel::Sender<String>>> = const { RefCell::new(None) };
    }

    // 알림을 누르면 key 가 메인 루프로 와서 읽기 창이 열린다
    fn sender() -> async_channel::Sender<String> {
        TX.with(|c| {
            if let Some(t) = c.borrow().as_ref() {
                return t.clone();
            }
            let (tx, rx) = async_channel::unbounded::<String>();
            glib::spawn_future_local(async move {
                while let Ok(key) = rx.recv().await {
                    // 묶음 알림은 그 분야 지면을 연다
                    if let Some(sec) = key.strip_prefix("section:") {
                        crate::magazine::open_section(sec);
                        continue;
                    }
                    // 지켜볼 낱말 정리는 그 낱말 검색 결과
                    if let Some(w) = key.strip_prefix("search:") {
                        crate::magazine::search_for(w);
                        continue;
                    }
                    let ui = crate::app::ui();
                    let st = ui.core.state();
                    if let Some(it) = st.recent.iter().chain(st.saved.iter()).find(|i| i.key() == key).cloned() {
                        crate::app::open_item(&it, None);
                    }
                }
            });
            *c.borrow_mut() = Some(tx.clone());
            tx
        })
    }

    fn base(summary: &str, body: &str, sound: bool) -> Notification {
        let mut n = Notification::new();
        n.appname("Dropcap").summary(summary).body(body).icon(crate::APP_ID).hint(Hint::DesktopEntry(crate::APP_ID.into()));
        if sound {
            n.hint(Hint::SoundName("message-new-instant".into()));
        } else {
            n.hint(Hint::SuppressSound(true));
        }
        n
    }

    pub fn post(items: Vec<NewsItem>, sound: bool) {
        let tx = sender();
        for it in items.iter().take(3) {
            let (t, b) = content(it);
            let mut n = base(&t, &b, sound);
            n.action("default", "열기");
            let key = it.key();
            let tx = tx.clone();
            // 누르기를 기다리는 일은 알림마다 따로(메인 루프를 막지 않게)
            std::thread::spawn(move || match n.show() {
                Ok(h) => h.wait_for_action(|a| {
                    if a == "default" {
                        let _ = tx.send_blocking(key);
                    }
                }),
                Err(e) => log::warn!("[시스템 알림] 보내지 못함: {e}"),
            });
        }
        if items.len() > 3 {
            let (t, b) = more_content(items.len() - 3);
            let n = base(&t, &b, false);
            std::thread::spawn(move || {
                let _ = n.show();
            });
        }
    }

    pub fn post_bundle(section: &str, items: Vec<NewsItem>, sound: bool) {
        if items.is_empty() {
            return;
        }
        let (t, b) = bundle_content(section, &items);
        let mut n = base(&t, &b, sound);
        n.action("default", "매거진에서 보기");
        let key = format!("section:{section}");
        let tx = sender();
        std::thread::spawn(move || match n.show() {
            Ok(h) => h.wait_for_action(|a| {
                if a == "default" {
                    let _ = tx.send_blocking(key);
                }
            }),
            Err(e) => log::warn!("[시스템 알림] 보내지 못함: {e}"),
        });
    }

    pub fn post_watch(word: &str, items: Vec<NewsItem>, sound: bool) {
        if items.is_empty() {
            return;
        }
        let (t, b) = watch_content(word, &items);
        let mut n = base(&t, &b, sound);
        n.action("default", "검색 결과 보기");
        let key = format!("search:{word}");
        let tx = sender();
        std::thread::spawn(move || match n.show() {
            Ok(h) => h.wait_for_action(|a| {
                if a == "default" {
                    let _ = tx.send_blocking(key);
                }
            }),
            Err(e) => log::warn!("[시스템 알림] 보내지 못함: {e}"),
        });
    }

    // 세션 버스가 있어야 알림 서버에 닿는다
    pub fn available() -> bool {
        if std::env::var("DBUS_SESSION_BUS_ADDRESS").map(|s| !s.is_empty()).unwrap_or(false) {
            return true;
        }
        let uid = unsafe { libc_getuid() };
        std::path::Path::new(&format!("/run/user/{uid}/bus")).exists()
    }

    extern "C" {
        #[link_name = "getuid"]
        fn libc_getuid() -> u32;
    }
}

#[cfg(all(feature = "notify", target_os = "linux"))]
pub use imp::{available, post, post_bundle, post_watch};

#[cfg(not(all(feature = "notify", target_os = "linux")))]
pub fn post(items: Vec<NewsItem>, _sound: bool) {
    // 시스템 알림을 쓸 수 없는 빌드: 물방울로 대신(알림이 사라지지 않게)
    let _ = (content, more_content);
    crate::toast::show(items, false);
}
// 시스템 알림을 쓸 수 없는 빌드: 묶음도 물방울로
#[cfg(not(all(feature = "notify", target_os = "linux")))]
pub fn post_bundle(section: &str, items: Vec<NewsItem>, sound: bool) {
    let _ = bundle_content;
    crate::toast::show_bundle(section, items, sound);
}
#[cfg(not(all(feature = "notify", target_os = "linux")))]
pub fn post_watch(word: &str, items: Vec<NewsItem>, sound: bool) {
    let _ = watch_content;
    crate::toast::show_watch(word, items, sound);
}
#[cfg(not(all(feature = "notify", target_os = "linux")))]
pub fn available() -> bool {
    false
}

#[cfg(test)]
mod tests {
    #[test]
    fn feed_text_is_not_markup() {
        let mut it = dropcap_core::models::NewsItem::new("1", "<a href=\"http://10.0.0.1/\">x</a><img src=x>", "https://e.com", "s", "S & Co", "press");
        it.title_ko = Some("<b>굵게</b>".into());
        let (t, b) = super::content(&it);
        assert!(!b.contains('<') && !b.contains('>') && !t.contains('<'));
        assert!(b.contains("&lt;b&gt;굵게"));
        assert!(t.starts_with("S &amp; Co"));
    }

    #[test]
    fn bundle_text() {
        let items: Vec<_> = (0..5)
            .map(|i| {
                let mut it = dropcap_core::models::NewsItem::new(&i.to_string(), &format!("t{i}"), "https://e.com", "s", "S", "kr");
                it.title_ko = Some(format!("제목 {i} <b>"));
                it
            })
            .collect();
        let (t, b) = super::bundle_content("economy", &items);
        assert_eq!(t, "경제 5건");
        assert_eq!(b.lines().count(), 3);
        assert!(b.starts_with("제목 0 &lt;b&gt;"));
    }
}
