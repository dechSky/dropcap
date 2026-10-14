// 트레이 아이콘(U-01): StatusNotifierItem(ksni). 신문 모양, 안 읽은 소식이 있으면 채워진 모양.
// 아이콘을 누르면 상단바 창을 열고 닫는다. 오른쪽 클릭 메뉴: 창 열기·매거진·지금 확인·설정·종료.
// 기능(tray)이 꺼진 빌드(맥 개발용)에서는 아무것도 하지 않는다 — 앱을 다시 실행하면 상단바 창이 열린다.

#[cfg(feature = "tray")]
mod imp {
    use crate::app::{resource, try_ui, ui};
    use crate::strings;
    use gtk::glib;
    use gtk::prelude::*;
    use ksni::blocking::TrayMethods;
    use std::cell::RefCell;

    enum Cmd {
        Toggle(i32, i32),
        Menu,
        Magazine,
        Settings,
        Check,
        Quit,
    }

    struct Tray {
        unread: bool,
        tx: async_channel::Sender<Cmd>,
        theme_path: String,
    }

    impl Tray {
        fn send(&self, c: Cmd) {
            let _ = self.tx.send_blocking(c);
        }
    }

    impl ksni::Tray for Tray {
        fn id(&self) -> String {
            crate::APP_ID.into()
        }
        fn title(&self) -> String {
            "Dropcap".into()
        }
        fn category(&self) -> ksni::Category {
            ksni::Category::ApplicationStatus
        }
        fn icon_theme_path(&self) -> String {
            self.theme_path.clone()
        }
        fn icon_name(&self) -> String {
            if self.unread {
                "dropcap-newspaper-filled-symbolic".into()
            } else {
                "dropcap-newspaper-symbolic".into()
            }
        }
        fn tool_tip(&self) -> ksni::ToolTip {
            ksni::ToolTip { title: "Dropcap".into(), description: strings::APP_COMMENT.into(), ..Default::default() }
        }
        fn activate(&mut self, x: i32, y: i32) {
            self.send(Cmd::Toggle(x, y));
        }
        fn menu(&self) -> Vec<ksni::MenuItem<Self>> {
            use ksni::menu::StandardItem;
            fn item(label: String, f: fn(&mut Tray)) -> ksni::MenuItem<Tray> {
                StandardItem { label, activate: Box::new(f), ..Default::default() }.into()
            }
            vec![
                item(format!("{} 열기", strings::NEWS), |t| t.send(Cmd::Menu)),
                item("매거진 열기".into(), |t| t.send(Cmd::Magazine)),
                item("지금 확인".into(), |t| t.send(Cmd::Check)),
                item("설정…".into(), |t| t.send(Cmd::Settings)),
                ksni::MenuItem::Separator,
                item("Dropcap 종료".into(), |t| t.send(Cmd::Quit)),
            ]
        }
    }

    thread_local! {
        static HANDLE: RefCell<Option<ksni::blocking::Handle<Tray>>> = const { RefCell::new(None) };
    }

    // 아이콘 파일이 있는 폴더(개발: resources/icons, 설치본: share/dropcap)
    fn theme_path() -> String {
        let p = resource("icons/dropcap-newspaper-symbolic.svg");
        let p = if p.exists() { p } else { resource("dropcap-newspaper-symbolic.svg") };
        p.parent().map(|d| d.to_string_lossy().to_string()).unwrap_or_default()
    }

    pub fn start() {
        let (tx, rx) = async_channel::unbounded::<Cmd>();
        let tray = Tray { unread: false, tx, theme_path: theme_path() };
        match tray.spawn() {
            Ok(h) => HANDLE.with(|c| *c.borrow_mut() = Some(h)),
            Err(e) => {
                // 트레이가 없는 데스크톱(GNOME 에 AppIndicator 확장이 없는 경우 등): 앱을 다시 실행하면 상단바 창이 열린다
                log::warn!("[트레이] 아이콘을 띄우지 못함: {e}");
                return;
            }
        }
        glib::spawn_future_local(async move {
            while let Ok(c) = rx.recv().await {
                if try_ui().is_none() {
                    continue;
                }
                match c {
                    Cmd::Toggle(x, y) => crate::menu::toggle_at(Some((x, y))),
                    Cmd::Menu => crate::menu::open(),
                    Cmd::Magazine => crate::magazine::open(),
                    Cmd::Settings => crate::settings::open(None),
                    Cmd::Check => ui().core.check_now(),
                    Cmd::Quit => ui().app.quit(),
                }
            }
        });
    }

    pub fn update(unread: i64) {
        HANDLE.with(|c| {
            if let Some(h) = c.borrow().as_ref() {
                let on = unread > 0;
                h.update(|t| t.unread = on);
            }
        });
    }

    pub fn active() -> bool {
        HANDLE.with(|c| c.borrow().is_some())
    }
}

#[cfg(feature = "tray")]
pub use imp::{active, start, update};

#[cfg(not(feature = "tray"))]
pub fn start() {}
#[cfg(not(feature = "tray"))]
pub fn update(_unread: i64) {}
// 트레이가 실제로 떠 있는가(없으면 상단바 창은 보통 창처럼 뜬다)
#[cfg(not(feature = "tray"))]
pub fn active() -> bool {
    false
}
