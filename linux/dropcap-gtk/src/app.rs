// 화면 쪽의 공통 바탕: 핵심(AppModel)과 GTK 메인 루프를 잇는다.
// - 핵심은 tokio 작업에서 돌고, UiEvent 는 async_channel 로 메인 루프에 넘어와 여기서 각 창에 나눠 준다.
// - 화면에서 오래 걸리는 일은 bg() 로 tokio 에 맡기고 결과만 메인 루프에서 받는다(Q-07).
use dropcap_core::app_model::{AppModel, UiEvent};
use dropcap_core::models::NewsItem;
use dropcap_core::scrapbook::Scrapbook;
use dropcap_core::store::Prefs;
use gtk::glib;
use gtk::prelude::*;
use once_cell::unsync::OnceCell;
use std::cell::RefCell;
use std::future::Future;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;

pub struct Ui {
    pub core: Arc<AppModel>,
    pub rt: tokio::runtime::Handle,
    pub app: adw::Application,
    pub scrapbook: RefCell<Scrapbook>,
    pub prefs: RefCell<Prefs>,
    pub env: Env,
    listeners: RefCell<Vec<Box<dyn Fn(&UiEvent)>>>,
}

// 시험용 환경 변수(Q-03)
#[derive(Debug, Clone, Default)]
pub struct Env {
    pub background: bool,           // --background: 로그인 때 자동 실행(창 없이)
    pub shot_dir: Option<PathBuf>,  // DROPCAP_TEST_SHOT_DIR: 화면을 PNG 로 남길 폴더
    pub test_toast: bool,           // DROPCAP_TEST_TOAST: 알림 미리 보기
    pub test_burst: bool,           // DROPCAP_TEST_BURST: 견본 3건
    pub test_url: Option<String>,   // DROPCAP_TEST_URL: 읽기 창 바로
    pub test_magazine: bool,        // DROPCAP_TEST_MAGAZINE
    pub test_mag_page: Option<String>, // DROPCAP_TEST_MAG_PAGE=scrapbook 등
    pub test_menu: bool,            // DROPCAP_TEST_MENU: 트레이 창을 바로
    pub test_settings: bool,        // DROPCAP_TEST_SETTINGS
    pub test_subscribe: Option<String>, // DROPCAP_TEST_SUBSCRIBE=cat-a,cat-b
    pub test_scrap: bool,           // DROPCAP_TEST_SCRAP
    pub test_quit_after: Option<u64>, // DROPCAP_TEST_QUIT_AFTER=초: 시험 실행을 스스로 끝냄
}

impl Env {
    pub fn read(args: &[String]) -> Env {
        let v = |k: &str| dropcap_core::test_hooks::var(k).filter(|s| !s.is_empty()); // 시험 훅은 개발 빌드에서만
        Env {
            background: args.iter().any(|a| a == "--background"),
            shot_dir: v("DROPCAP_TEST_SHOT_DIR").map(PathBuf::from),
            test_toast: v("DROPCAP_TEST_TOAST").is_some(),
            test_burst: v("DROPCAP_TEST_BURST").is_some(),
            test_url: v("DROPCAP_TEST_URL"),
            test_magazine: v("DROPCAP_TEST_MAGAZINE").is_some(),
            test_mag_page: v("DROPCAP_TEST_MAG_PAGE"),
            test_menu: v("DROPCAP_TEST_MENU").is_some(),
            test_settings: v("DROPCAP_TEST_SETTINGS").is_some(),
            test_subscribe: v("DROPCAP_TEST_SUBSCRIBE"),
            test_scrap: v("DROPCAP_TEST_SCRAP").is_some(),
            test_quit_after: v("DROPCAP_TEST_QUIT_AFTER").and_then(|s| s.parse().ok()),
        }
    }
}

thread_local! {
    static UI: OnceCell<Rc<Ui>> = const { OnceCell::new() };
}

pub fn ui() -> Rc<Ui> {
    UI.with(|u| u.get().expect("Ui 가 아직 없음").clone())
}

pub fn try_ui() -> Option<Rc<Ui>> {
    UI.with(|u| u.get().cloned())
}

pub fn install(ui: Ui) -> Rc<Ui> {
    let rc = Rc::new(ui);
    UI.with(|u| {
        let _ = u.set(rc.clone());
    });
    rc
}

impl Ui {
    pub fn new(core: Arc<AppModel>, rt: tokio::runtime::Handle, app: adw::Application, env: Env) -> Ui {
        let dir = core.store.dir.clone();
        let scrapbook = Scrapbook::new(core.db.clone(), dir.clone());
        Ui {
            core,
            rt,
            app,
            scrapbook: RefCell::new(scrapbook),
            prefs: RefCell::new(Prefs::load(&dir)),
            env,
            listeners: RefCell::new(vec![]),
        }
    }

    // 창들이 핵심의 소식(상태 바뀜·새 기사 등)을 받아 본다
    pub fn listen(&self, f: impl Fn(&UiEvent) + 'static) {
        self.listeners.borrow_mut().push(Box::new(f));
    }

    pub fn dispatch(&self, e: &UiEvent) {
        for l in self.listeners.borrow().iter() {
            l(e);
        }
    }

    pub fn save_prefs(&self) {
        // 핵심이 직접 쓰는 값(같은 소식 판정 기준 버전)은 디스크 쪽이 더 새로우면 살린다(화면 사본이 덮어쓰지 않게)
        let disk = Prefs::load(&self.core.store.dir);
        let mut p = self.prefs.borrow_mut();
        p.story_rule_version = p.story_rule_version.max(disk.story_rule_version);
        p.save(&self.core.store.dir);
    }

    pub fn update_prefs(&self, f: impl FnOnce(&mut Prefs)) {
        f(&mut self.prefs.borrow_mut());
        self.save_prefs();
    }
}

// 핵심의 UiEvent 를 메인 루프로
pub fn connect_events(ui: &Rc<Ui>) {
    let (tx, rx) = async_channel::unbounded::<UiEvent>();
    ui.core.set_sink(Arc::new(move |e| {
        let _ = tx.send_blocking(e);
    }));
    glib::spawn_future_local(async move {
        while let Ok(e) = rx.recv().await {
            if let Some(ui) = try_ui() {
                crate::route(&ui, &e);
                ui.dispatch(&e);
            }
        }
    });
}

// 오래 걸리는 일을 tokio 에서 돌리고, 끝나면 결과를 메인 루프의 cb 로
pub fn bg<T: Send + 'static>(fut: impl Future<Output = T> + Send + 'static, cb: impl FnOnce(T) + 'static) {
    let rt = ui().rt.clone();
    let h = rt.spawn(fut);
    glib::spawn_future_local(async move {
        if let Ok(v) = h.await {
            cb(v);
        }
    });
}

// 기다리기만(결과 없이)
#[allow(dead_code)] // 매거진 화면에서 씀(지금은 쓰지 않는 것도 남겨 둠)
pub fn bg_run(fut: impl Future<Output = ()> + Send + 'static) {
    ui().rt.spawn(fut);
}

// 기사 열기: 영상·팟캐스트는 원래 앱·브라우저로, 나머지는 읽기 창(R-17). from = 누른 자리(화면 좌표, R-14)
pub fn open_item(item: &NewsItem, from: Option<crate::reader::Origin>) {
    open_item_in(item, from, vec![]);
}

// sequence: 연 목록(읽기 창 J/K 로 다음·이전, H-05)
pub fn open_item_in(item: &NewsItem, from: Option<crate::reader::Origin>, sequence: Vec<NewsItem>) {
    let ui = ui();
    if !ui.core.open(item) {
        return; // 미리 보기 견본은 아무것도 열지 않음(N-15)
    }
    if item.item_kind().opens_externally() {
        open_external(&item.link);
    } else {
        crate::reader::open_in(item, from, sequence);
    }
}

// 매거진에서 연 기사(읽음·관심사만 기록하고 읽기 창은 같은 방식으로)
pub fn open_from_magazine(item: &NewsItem, from: Option<crate::reader::Origin>) {
    open_from_magazine_in(item, from, vec![]);
}

pub fn open_from_magazine_in(item: &NewsItem, from: Option<crate::reader::Origin>, sequence: Vec<NewsItem>) {
    let ui = ui();
    ui.core.mark_opened(item);
    if item.item_kind().opens_externally() {
        open_external(&item.link);
    } else {
        crate::reader::open_in(item, from, sequence);
    }
}

// 바깥(브라우저·앱)으로 여는 모든 곳은 이것만: 공개 http(s) 검사 하나로(S-08)
pub fn open_external(link: &str) -> bool {
    let Some(u) = dropcap_core::url_safety::external_link(link) else { return false };
    let launcher = gtk::UriLauncher::new(&u);
    launcher.launch(None::<&gtk::Window>, None::<&gtk::gio::Cancellable>, |r| {
        if let Err(e) = r {
            log::warn!("[바깥 열기] 실패: {e}");
        }
    });
    true
}

pub fn copy_text(s: &str) {
    if let Some(d) = gtk::gdk::Display::default() {
        d.clipboard().set_text(s);
    }
}

// 자원 폴더: AppImage/설치본은 <exe>/../share/dropcap, 개발 중에는 저장소의 linux/resources
pub fn resource(name: &str) -> PathBuf {
    let mut cands = vec![];
    if let Ok(dir) = std::env::var("DROPCAP_RESOURCES") {
        cands.push(PathBuf::from(dir).join(name));
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(bin) = exe.parent() {
            cands.push(bin.join("../share/dropcap").join(name));
        }
    }
    // 개발 중에만 저장소의 linux/resources(배포판에 빌드한 컴퓨터의 경로가 남지 않게)
    #[cfg(debug_assertions)]
    cands.push(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../resources").join(name));
    cands.iter().find(|p| p.exists()).cloned().unwrap_or_else(|| cands.last().cloned().unwrap_or_else(|| PathBuf::from(name)))
}
