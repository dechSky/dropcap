// 읽기 창(R-01~R-18): 창 열기·여러 창 관리·본문 추리기 엔진 설치.
// 화면 그리기는 reader_view, 소리 내어 읽기는 reader_speech, WebKitGTK 추출은 reader_webkit(webkit 기능).
use crate::reader_view::ReaderWindow;
use dropcap_core::models::NewsItem;
use gtk::prelude::*;
use std::cell::RefCell;
use std::rc::Rc;

// 누른 자리(화면 좌표 또는 창 기준 사각형): 창이 그 자리에서 커져 나온다(R-14)
#[derive(Debug, Clone, Copy)]
#[allow(dead_code)] // x·y·h 는 창 자리를 정할 수 있는 환경(X11)에서 쓸 자리
pub struct Origin {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

thread_local! {
    static WINDOWS: RefCell<Vec<Rc<ReaderWindow>>> = const { RefCell::new(Vec::new()) };
}

// 시험용: 가장 나중에 연 읽기 창에서 J/K(DROPCAP_TEST_KEYNAV)
pub fn test_step(d: i64) {
    if let Some(w) = WINDOWS.with(|w| w.borrow().last().cloned()) {
        w.step(d);
    }
}

// 가장 나중에 연 읽기 창(시험 찍기)
pub fn last_window() -> Option<adw::ApplicationWindow> {
    WINDOWS.with(|w| w.borrow().last().map(|x| x.window().clone()))
}

// 웹 엔진(WebKitGTK)이 있으면 빠른 길·느린 길을 맡긴다. 없으면 핵심의 Rust 판 빠른 길만.
pub fn install_extractor() {
    #[cfg(feature = "webkit")]
    crate::reader_webkit::install();
}

// 영상·팟캐스트는 읽기 창 대신 원래 앱·브라우저로(R-17)
pub fn open(item: &NewsItem, from: Option<Origin>) {
    open_in(item, from, vec![]);
}

// sequence: 이 기사를 연 목록(상단바 목록·매거진 지면 순서) — 읽기 창에서 J/K 로 다음·이전(H-05)
pub fn open_in(item: &NewsItem, from: Option<Origin>, sequence: Vec<NewsItem>) {
    if item.item_kind().opens_externally() {
        crate::app::open_external(&item.link);
        return;
    }
    let others = WINDOWS.with(|w| w.borrow().len());
    let win = ReaderWindow::new(item.clone(), others, sequence);
    WINDOWS.with(|w| w.borrow_mut().push(win.clone()));
    // 창을 닫으면 목록에서 빼고 관찰·소리를 끊는다
    let weak = Rc::downgrade(&win);
    win.window().connect_close_request(move |_| {
        if let Some(w) = weak.upgrade() {
            w.closed();
            WINDOWS.with(|list| list.borrow_mut().retain(|x| !Rc::ptr_eq(x, &w)));
        }
        gtk::glib::Propagation::Proceed
    });
    crate::reader_view::ensure_css();
    win.present(from);
    win.load();
    // 시험용: DROPCAP_TEST_URL 로 연 창을 3·8·20초에 PNG 로
    let ui = crate::app::ui();
    if ui.env.shot_dir.is_some() && ui.env.test_url.as_deref() == Some(item.link.as_str()) {
        for sec in [3u64, 8, 20] {
            let w = win.window().clone();
            crate::widgets::later(sec * 1000, move || crate::reader_view::shot_reader(&w, &format!("reader-{sec}")));
        }
    }
}
