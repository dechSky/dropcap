// Dropcap 리눅스 판(GTK4 · libadwaita). 맥 앱(mac/Sources/Dropcap)과 같은 기능·문구·수치.
mod add_url_bar;
mod app;
mod backup_ui;
mod focus_x11;
mod hotkeys;
mod integrations;
mod keynav;
mod magazine;
mod magazine_archive;
mod magazine_card;
mod magazine_issue;
mod magazine_pages;
mod menu;
mod menu_chips;
mod motion;
mod onboarding;
mod reader;
mod reader_find;
mod reader_image;
mod reader_speech;
mod reader_view;
#[cfg(feature = "webkit")]
mod reader_webkit;
mod section_photos;
mod scrapbook_settings;
mod settings;
mod settings_sections;
mod settings_sources;
mod settings_tools;
mod shots;
mod strings;
mod sysnotify;
mod theme;
mod toast;
mod toast_drip;
mod toast_place;
mod toast_sound;
mod toast_water;
mod test_extras;
mod tray;
mod widgets;

use adw::prelude::*;
use app::{Env, Ui};
use dropcap_core::app_model::{AppModel, UiEvent};
use dropcap_core::store::{Store, DIR};
use gtk::glib;
use std::rc::Rc;

pub const APP_ID: &str = "io.github.dechsky.Dropcap";

// 핵심의 소식을 알맞은 창으로
pub fn route(ui: &Rc<Ui>, e: &UiEvent) {
    match e {
        UiEvent::Toast { items, sound } => toast::show(items.clone(), *sound),
        UiEvent::System { items, sound } => sysnotify::post(items.clone(), *sound),
        UiEvent::Info { title, sub } => toast::show_info(title, sub),
        UiEvent::Digest { count } => toast::show_digest(*count),
        UiEvent::Welcome => toast::show_welcome(),
        UiEvent::State => tray::update(ui.core.state().unread),
        UiEvent::Bundle { section, items, sound } => toast::show_bundle(section, items.clone(), *sound),
        UiEvent::SystemBundle { section, items, sound } => sysnotify::post_bundle(section, items.clone(), *sound),
        UiEvent::Watch { word, items, sound } => toast::show_watch(word, items.clone(), *sound),
        UiEvent::SystemWatch { word, items, sound } => sysnotify::post_watch(word, items.clone(), *sound),
        _ => {}
    }
}

fn main() -> glib::ExitCode {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();
    let args: Vec<String> = std::env::args().collect();
    let env = Env::read(&args);
    // 명령줄(I-02): --latest 는 창 없이 출력만, --save·--magazine·dropcap:// 는 주소로 바꿔 앱(이미 떠 있으면 그쪽)에 넘긴다
    let uris = match dropcap_core::url_router::cli(&args) {
        dropcap_core::url_router::Cli::Run { uris } => uris,
        other => return glib::ExitCode::from(print_cli(other)),
    };

    // 하나만 실행(C-12): 잠금을 못 잡으면 바로 끝낸다(D-Bus 가 있으면 GApplication 이 먼저 기존 실행을 깨운다)
    let rt = tokio::runtime::Builder::new_multi_thread().worker_threads(4).enable_all().thread_name("dropcap-bg").build().expect("tokio");

    let app = adw::Application::builder().application_id(APP_ID).flags(gtk::gio::ApplicationFlags::HANDLES_OPEN).build();
    let lock = std::cell::RefCell::new(None);
    let env2 = env.clone();
    let handle = rt.handle().clone();
    app.connect_startup(move |app| {
        let Some(l) = dropcap_core::system::single_instance(&DIR) else {
            log::info!("Dropcap 이 이미 실행 중이라 종료합니다");
            app.quit();
            return;
        };
        *lock.borrow_mut() = Some(l);
        theme::register_font();
        let core = AppModel::new(Store::new(DIR.clone()), handle.clone());
        let ui = app::install(Ui::new(core, handle.clone(), app.clone(), env2.clone()));
        theme::apply();
        adw::StyleManager::default().connect_dark_notify(|_| theme::apply());
        app::connect_events(&ui);
        integrations::install_search(app); // GNOME 검색·KRunner(I-03)
        scrapbook_settings::start(); // 스크랩 노트 폴더 자동 저장(I-06)
        reader::install_extractor();
        focus_x11::install(); // 회의·발표 중 조용히: 전체 화면 감지(X11)
        tray::start();
        hotkeys::start();
        // 창이 없어도 꺼지지 않게(트레이 앱)
        std::mem::forget(app.hold());
        ui.core.start();
        // 처음 실행(관심 분야를 아직 고르지 않음): 분야 고르기 창(G-03)
        if ui.core.needs_onboarding() {
            widgets::later(600, onboarding::open);
        }
        tray::update(ui.core.state().unread);
        test_hooks(&ui);
    });
    app.connect_activate(move |_| {
        // 다시 실행하거나(이미 떠 있을 때) 처음 켤 때: 트레이가 안 보이는 환경을 위해 상단바 창을 띄운다
        if let Some(ui) = app::try_ui() {
            if !ui.env.background {
                menu::open();
            }
        }
    });
    // dropcap:// 주소(I-04): 처음 켤 때도, 이미 떠 있는 앱에 넘어온 것도 여기로
    app.connect_open(|_, files, _| {
        if app::try_ui().is_none() {
            return; // 이미 실행 중이라 끝나는 쪽
        }
        let list: Vec<String> = files.iter().map(|f| f.uri().to_string()).collect();
        integrations::handle_uris(&list);
    });
    // GApplication 에는 넘길 주소만(--background 같은 우리 선택은 GApplication 이 모르는 선택이라 넘기지 않음)
    let gargs: Vec<String> = args.iter().take(1).cloned().chain(uris).collect();
    let code = app.run_with_args(&gargs);
    drop(rt);
    code
}

// --latest · --help · 잘못된 선택: 창 없이 출력하고 끝(종료 값)
fn print_cli(c: dropcap_core::url_router::Cli) -> u8 {
    use dropcap_core::url_router::{self as ur, Cli, SectionChoice};
    match c {
        Cli::Help => {
            print!("{}", ur::HELP);
            0
        }
        Cli::Error(e) => {
            eprintln!("{e}");
            2
        }
        Cli::Latest { section, count, json } => {
            let sec = match ur::section(section.as_deref()) {
                SectionChoice::All => None,
                SectionChoice::Only(c) => Some(c),
                SectionChoice::Unknown => {
                    eprintln!("'{}' 분야를 찾지 못했습니다. {} 중에서 고르세요.", section.unwrap_or_default(), ur::section_names().join(", "));
                    return 2;
                }
            };
            // 읽기만: 상태 파일을 고치지 않는다(앱이 떠 있어도 안전)
            let (state, _) = dropcap_core::store::read_state(&Store::new(DIR.clone()).file(), &Store::new(DIR.clone()).backup_file());
            let items = ur::latest(&ur::visible_recent(&state), sec, count);
            print!("{}", ur::format_latest(&items, json, chrono::Utc::now()));
            0
        }
        Cli::Run { .. } => 0,
    }
}

// 시험용 환경 변수(Q-03)
fn test_hooks(ui: &Rc<Ui>) {
    let env = ui.env.clone();
    if let Some(u) = env.test_url.clone() {
        let mut it = dropcap_core::models::NewsItem::new(&u, &u, &u, "openai", "시험", "lab");
        it.date = Some(chrono::Utc::now());
        widgets::later(500, move || reader::open(&it, None));
    }
    if let Some(subs) = env.test_subscribe.clone() {
        let core = ui.core.clone();
        ui.rt.spawn(async move {
            for id in subs.split(',') {
                if let Some(s) = dropcap_core::channels::CATALOG.iter().find(|s| s.id == id).cloned() {
                    let _ = core.clone().subscribe(s).await;
                }
            }
        });
    }
    if env.test_toast {
        let core = ui.core.clone();
        widgets::later(1000, move || core.preview());
    }
    if env.test_burst {
        widgets::later(1500, || toast::show_burst_samples());
    }
    if env.test_magazine {
        widgets::later(1000, magazine::open);
    }
    if env.test_menu {
        widgets::later(800, menu::open);
    }
    if env.test_settings {
        widgets::later(800, || settings::open(None));
    }
    if env.test_scrap {
        widgets::later(25_000, magazine::seed_test_scraps);
    }
    test_extras::run();
    if let Some(s) = env.test_quit_after {
        widgets::later(s * 1000, || app::ui().app.quit());
    }
}
