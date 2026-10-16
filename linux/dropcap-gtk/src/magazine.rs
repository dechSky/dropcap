// 매거진 창(M-01~M-22·G-09·G-10·G-12)·스크랩북·스토리 — 맥 UI/MagazineView.swift 와 같은 지면·문구·수치.
// 창: 옆 목록(이번 호·분야·모아 보기·지난 호) + 지면(책장 넘기듯 바뀜). 지면 그리기는 magazine_issue·magazine_card·magazine_pages.
use crate::app::ui;
use crate::magazine_issue::{IssuePage, IssueSource};
use crate::magazine_pages;
use crate::{motion, shots, widgets};
use dropcap_core::app_model::UiEvent;
use dropcap_core::magazine::Issue;
use dropcap_core::sections;
use adw::prelude::*;
use gtk::{gdk, glib};
use std::cell::{Cell, RefCell};
use std::rc::Rc;

#[derive(Debug, Clone, PartialEq)]
pub enum Page {
    Today,
    Week,
    Section(String), // 오늘 호의 한 분야
    Issue(Issue),
    Stories,
    Story(String),
    Saved,
    Search,
    Scrapbook,
}

impl Page {
    // 넘기는 방향을 정하는 순서(맥 MagazineView.order)
    fn order(&self, archive: &[Issue]) -> i64 {
        match self {
            Page::Today => 0,
            Page::Section(_) | Page::Week => 1,
            Page::Stories => 2,
            Page::Story(_) => 3,
            Page::Saved => 4,
            Page::Scrapbook => 5,
            Page::Search => 7,
            Page::Issue(i) => 100 + archive.iter().position(|a| a == i).unwrap_or(0) as i64,
        }
    }
}

pub struct Magazine {
    pub window: adw::ApplicationWindow,
    stack: gtk::Stack,
    sidebar: gtk::ListBox,
    page: RefCell<Page>,
    rows: RefCell<Vec<(gtk::ListBoxRow, Page)>>,
    current_issue: RefCell<Option<Rc<IssuePage>>>,
    current_scroll: RefCell<Option<gtk::ScrolledWindow>>,
    serial: Cell<u64>,
    syncing: Cell<bool>,
}

thread_local! {
    static MAG: RefCell<Option<Rc<Magazine>>> = const { RefCell::new(None) };
    static LISTENING: Cell<bool> = const { Cell::new(false) };
}

fn current() -> Option<Rc<Magazine>> {
    MAG.with(|m| m.borrow().clone())
}

pub fn open() {
    if let Some(m) = current() {
        m.window.present();
        return;
    }
    let first = initial_page();
    let m = build(first);
    crate::motion::present(&m.window);
    if let Some(dir) = ui().env.shot_dir.clone() {
        if ui().env.test_magazine {
            test_shots(&m, dir);
        }
    }
}

// 시험용: 지금 지면에 키를 누른 것처럼 · 지면 넘기기(DROPCAP_TEST_KEYNAV)
pub fn test_key(k: Option<crate::keynav::NavKey>, flip: i64) {
    let Some(m) = current() else { return };
    if flip != 0 {
        m.flip(flip);
    }
    let ip = m.current_issue.borrow().clone();
    if let (Some(k), Some(ip)) = (k, ip) {
        ip.key_nav(k);
    }
}

// 매거진 검색 지면을 그 낱말로(지켜볼 낱말 정리 물방울·알림을 눌렀을 때, N-27)
pub fn search_for(word: &str) {
    magazine_pages::PENDING_QUERY.with(|p| *p.borrow_mut() = Some(word.to_string()));
    open();
    if let Some(m) = current() {
        m.show(Page::Search, 1); // 이미 검색 지면이어도 그 낱말로 다시
    }
}

pub fn window() -> Option<adw::ApplicationWindow> {
    current().map(|m| m.window.clone())
}

// 그 분야 지면을 열기(묶음 알림을 눌렀을 때 · 옆 목록 '분야')
pub fn open_section(section: &str) {
    open();
    if let Some(m) = current() {
        m.go(Page::Section(section.to_string()));
    }
}

fn initial_page() -> Page {
    let env = &ui().env;
    match env.test_mag_page.as_deref() {
        Some("scrapbook") => Page::Scrapbook,
        Some("stories") => Page::Stories,
        Some("saved") => Page::Saved,
        Some("search") => Page::Search,
        Some("week") => Page::Week,
        Some(p) if p.starts_with("section:") => Page::Section(p["section:".len()..].to_string()),
        Some(p) if p.starts_with("story:") => Page::Story(p["story:".len()..].to_string()),
        _ => Page::Today,
    }
}

fn build(first: Page) -> Rc<Magazine> {
    ensure_css();
    let window = adw::ApplicationWindow::builder()
        .application(&ui().app)
        .title("Dropcap")
        .default_width(1180)
        .default_height(820)
        .width_request(860)
        .height_request(620)
        .build();
    let sidebar = gtk::ListBox::new();
    sidebar.set_selection_mode(gtk::SelectionMode::Single);
    sidebar.add_css_class("navigation-sidebar");
    let side_scroll = gtk::ScrolledWindow::builder().hscrollbar_policy(gtk::PolicyType::Never).child(&sidebar).width_request(210).build();
    let stack = gtk::Stack::new();
    stack.set_hexpand(true);
    stack.set_vexpand(true);
    stack.set_transition_duration(crate::motion::SETTLE);
    stack.add_css_class("dc-mag-bg");
    let body = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    body.append(&side_scroll);
    body.append(&gtk::Separator::new(gtk::Orientation::Vertical));
    body.append(&stack);
    let tv = adw::ToolbarView::new();
    let hb = adw::HeaderBar::new();
    hb.set_title_widget(Some(&gtk::Label::new(None)));
    tv.add_top_bar(&hb);
    tv.set_content(Some(&body));
    window.set_content(Some(&tv));

    let m = Rc::new(Magazine {
        window,
        stack,
        sidebar,
        page: RefCell::new(Page::Today),
        rows: RefCell::new(vec![]),
        current_issue: RefCell::new(None),
        current_scroll: RefCell::new(None),
        serial: Cell::new(0),
        syncing: Cell::new(false),
    });
    MAG.with(|x| *x.borrow_mut() = Some(m.clone()));
    m.fill_sidebar();
    {
        let weak = Rc::downgrade(&m);
        m.sidebar.connect_row_selected(move |_, row| {
            let (Some(m), Some(row)) = (weak.upgrade(), row) else { return };
            if m.syncing.get() {
                return;
            }
            let p = m.rows.borrow().iter().find(|(r, _)| r == row).map(|(_, p)| p.clone());
            // 이미 그 칸에 해당하는 지면이면(스토리 상세 → 옆 목록은 '스토리') 다시 열지 않는다
            // (창이 초점을 얻을 때 목록이 고른 줄을 다시 알리는 경우)
            if let Some(p) = p.filter(|p| *p != sidebar_key(&m.page.borrow())) {
                m.go(p);
            }
        });
    }
    m.sidebar.connect_row_activated(|_, row| {
        if row.widget_name() == SETTINGS_ROW {
            crate::settings::open(None);
        }
    });
    m.install_shortcuts();
    m.window.connect_close_request(|_| {
        MAG.with(|x| *x.borrow_mut() = None);
        glib::Propagation::Proceed
    });
    // 핵심 소식: 옆 목록 수(저장·스크랩북·지난 호)와 보고 있는 지면에 알린다(창이 닫혀 있으면 무시)
    if !LISTENING.with(|l| l.replace(true)) {
        ui().listen(|e| {
            let Some(m) = current() else { return };
            if matches!(e, UiEvent::State | UiEvent::Layout | UiEvent::Magazine | UiEvent::Preparing(_)) {
                m.fill_sidebar();
            }
            let ip = m.current_issue.borrow().clone();
            if let Some(ip) = ip {
                ip.on_event(e);
            }
        });
    }
    m.show(first, 0);
    m
}

impl Magazine {
    fn fill_sidebar(self: &Rc<Self>) {
        self.syncing.set(true);
        while let Some(c) = self.sidebar.first_child() {
            self.sidebar.remove(&c);
        }
        self.rows.borrow_mut().clear();
        let ui = ui();
        let st = ui.core.state();
        let header = |t: &str| {
            let l = gtk::Label::new(Some(t));
            l.set_xalign(0.0);
            l.add_css_class("dc-side-head");
            gtk::ListBoxRow::builder().child(&l).selectable(false).activatable(false).build()
        };
        let add = |me: &Rc<Self>, icon: &str, text: &str, color: Option<&str>, page: Page| {
            let b = gtk::Box::new(gtk::Orientation::Horizontal, 9);
            let i = widgets::icon(icon, 16);
            if let Some(c) = color {
                tint(&i, c);
            }
            b.append(&i);
            let l = gtk::Label::new(Some(text));
            l.set_xalign(0.0);
            l.set_ellipsize(gtk::pango::EllipsizeMode::End);
            b.append(&l);
            b.set_margin_top(3);
            b.set_margin_bottom(3);
            let r = gtk::ListBoxRow::builder().child(&b).build();
            me.sidebar.append(&r);
            me.rows.borrow_mut().push((r, page));
        };
        self.sidebar.append(&header("이번 호"));
        add(self, "x-office-document-symbolic", "오늘", None, Page::Today);
        add(self, "x-office-calendar-symbolic", "이번 주", None, Page::Week);
        let chosen = ui.core.chosen_sections();
        if !chosen.is_empty() {
            self.sidebar.append(&header("분야"));
            for id in chosen {
                let s = sections::by_id(&id);
                add(self, s.map(|s| s.icon()).unwrap_or("view-app-grid-symbolic"), &sections::name(&id), s.map(|s| s.color.as_str()), Page::Section(id));
            }
        }
        self.sidebar.append(&header("모아 보기"));
        add(self, "network-workgroup-symbolic", "스토리", None, Page::Stories);
        add(self, "user-bookmarks-symbolic", &format!("저장 {}", st.saved.len()), None, Page::Saved);
        let scraps = ui.scrapbook.borrow().scraps.len();
        add(self, "edit-cut-symbolic", &format!("스크랩북 {scraps}"), None, Page::Scrapbook);
        add(self, "system-search-symbolic", "검색", None, Page::Search);
        let archive = ui.core.archive();
        if !archive.is_empty() {
            self.sidebar.append(&header("지난 호"));
            for i in archive {
                let icon = if i.kind == dropcap_core::magazine::IssueKind::Weekly { "accessories-dictionary-symbolic" } else { "text-x-generic-symbolic" };
                // 이름은 오른쪽 머리와 같은 title(), 기사가 너무 적은 호는 흐리게 + 도움말 '기록 적음'(머리에는 글로)
                let (thin, tip) = (i.is_thin(), if i.is_thin() { format!("기록 적음 — 소식 {}건", i.count) } else { i.title() });
                add(self, icon, &i.title(), None, Page::Issue(i));
                if let Some((r, _)) = self.rows.borrow().last() {
                    r.set_tooltip_text(Some(&tip));
                    if thin {
                        r.set_opacity(0.55);
                    }
                }
            }
        }
        // 맨 아래 '설정' 줄: 지면이 아니라 설정 창을 연다(고를 수 없는 줄 — 고른 지면은 그대로, row-activated 에서 받음)
        self.sidebar.append(&header(""));
        add(self, "emblem-system-symbolic", "설정", None, Page::Today);
        if let Some((r, _)) = self.rows.borrow_mut().pop() {
            r.set_selectable(false);
            r.set_widget_name(SETTINGS_ROW);
            r.set_tooltip_text(Some("설정 열기 (Ctrl+,)"));
        }
        let p = self.page.borrow().clone();
        self.select_row_for(&p);
        self.syncing.set(false);
    }

    fn select_row_for(&self, p: &Page) {
        let key = sidebar_key(p);
        let row = self.rows.borrow().iter().find(|(_, pg)| *pg == key).map(|(r, _)| r.clone());
        let was = self.syncing.replace(true);
        match row {
            Some(r) => self.sidebar.select_row(Some(&r)),
            None => self.sidebar.unselect_all(),
        }
        self.syncing.set(was);
    }

    pub fn go(self: &Rc<Self>, p: Page) {
        if *self.page.borrow() == p {
            return;
        }
        let archive = ui().core.archive();
        let dir = if p.order(&archive) >= self.page.borrow().order(&archive) { 1 } else { -1 };
        self.show(p, dir);
    }

    // 지면을 만들어 넣는다. 책장 넘기듯(앞으로 가면 왼쪽으로 돌아 넘어가고, 뒤로 가면 반대로)(M-19)
    fn show(self: &Rc<Self>, p: Page, dir: i32) {
        log::debug!("[매거진] 지면 {p:?}");
        *self.page.borrow_mut() = p.clone();
        self.select_row_for(&p);
        let weak = Rc::downgrade(self);
        let on_story: Rc<dyn Fn(String)> = Rc::new(move |id: String| {
            if let Some(m) = weak.upgrade() {
                m.go(Page::Story(id));
            }
        });
        *self.current_issue.borrow_mut() = None;
        let (widget, scroll): (gtk::Widget, gtk::ScrolledWindow) = match &p {
            Page::Today | Page::Week | Page::Section(_) | Page::Issue(_) => {
                let (src, focus) = match &p {
                    Page::Week => (IssueSource::Week, None),
                    Page::Section(s) => (IssueSource::Section(s.clone()), None), // 분야 지면(M-25): 그 분야 기사만으로 엮은 지면
                    Page::Issue(i) => (IssueSource::Fixed(i.clone()), None),
                    _ => (IssueSource::Today, None),
                };
                let ip = IssuePage::new(src, focus, on_story.clone());
                let w = ip.root.clone().upcast::<gtk::Widget>();
                let s = ip.scroll.clone();
                *self.current_issue.borrow_mut() = Some(ip);
                (w, s)
            }
            Page::Stories => magazine_pages::stories(on_story.clone()),
            Page::Story(id) => {
                let weak = Rc::downgrade(self);
                magazine_pages::story(
                    id,
                    Rc::new(move || {
                        if let Some(m) = weak.upgrade() {
                            m.go(Page::Stories);
                        }
                    }),
                )
            }
            Page::Saved => magazine_pages::saved(),
            Page::Search => magazine_pages::search(),
            Page::Scrapbook => magazine_pages::scrapbook(&self.window),
        };
        *self.current_scroll.borrow_mut() = Some(scroll);
        let n = self.serial.get() + 1;
        self.serial.set(n);
        let name = format!("p{n}");
        self.stack.add_named(&widget, Some(&name));
        self.stack.set_transition_type(if !motion::enabled() || dir == 0 {
            gtk::StackTransitionType::None
        } else {
            gtk::StackTransitionType::Crossfade // 지면 넘김: 회전 없이(docs/DESIGN.md — 맥은 떠오름+흐려짐)
        });
        let old = self.stack.visible_child();
        self.stack.set_visible_child_name(&name);
        // 넘김이 끝나면 앞 지면을 치운다
        if let Some(old) = old {
            let stack = self.stack.clone();
            widgets::later(700, move || {
                if stack.visible_child().as_ref() != Some(&old) {
                    stack.remove(&old);
                }
            });
        }
    }

    // 단축키(M-20): Ctrl+1 오늘·Ctrl+2 이번 주·Ctrl+3 스토리·Ctrl+4 스크랩북·Ctrl+F 검색·Ctrl+R 지금 확인·Ctrl+, 설정
    fn install_shortcuts(self: &Rc<Self>) {
        let sc = gtk::ShortcutController::new();
        sc.set_scope(gtk::ShortcutScope::Managed);
        let add = |trigger: &str, f: Rc<dyn Fn()>| {
            let action = gtk::CallbackAction::new(move |_, _| {
                f();
                glib::Propagation::Stop
            });
            sc.add_shortcut(gtk::Shortcut::new(gtk::ShortcutTrigger::parse_string(trigger), Some(action)));
        };
        for (t, p) in [("<Control>1", Page::Today), ("<Control>2", Page::Week), ("<Control>3", Page::Stories), ("<Control>4", Page::Scrapbook), ("<Control>f", Page::Search)] {
            let weak = Rc::downgrade(self);
            add(
                t,
                Rc::new(move || {
                    if let Some(m) = weak.upgrade() {
                        m.go(p.clone());
                    }
                }),
            );
        }
        add("<Control>r", Rc::new(|| ui().core.check_now()));
        add("<Control>comma", Rc::new(|| crate::settings::open(None)));
        // 지면 넘기기(H-04): 옆 목록 순서대로, 끝이면 경고음
        for (t, d) in [("<Control>bracketleft", -1), ("<Control>bracketright", 1)] {
            let weak = Rc::downgrade(self);
            add(
                t,
                Rc::new(move || {
                    if let Some(m) = weak.upgrade() {
                        m.flip(d);
                    }
                }),
            );
        }
        self.window.add_controller(sc);
        // 지면 카드 키보드 탐색(H-03): 글자를 치는 칸에 커서가 있으면 쓰지 않음
        let weak = Rc::downgrade(self);
        crate::keynav::attach(&self.window, move |key, state| {
            let Some(m) = weak.upgrade() else { return false };
            let Some(k) = crate::keynav::NavKey::from(key, state) else { return false };
            if crate::keynav::typing(&m.window) {
                return false;
            }
            let Some(ip) = m.current_issue.borrow().clone() else { return false };
            ip.key_nav(k);
            true
        });
    }

    // 옆 목록 순서: 오늘·이번 주·분야들·스토리·저장·스크랩북·검색·지난 호
    fn page_order(&self) -> Vec<Page> {
        let mut v = vec![Page::Today, Page::Week];
        v.extend(ui().core.chosen_sections().into_iter().map(Page::Section));
        v.extend([Page::Stories, Page::Saved, Page::Scrapbook, Page::Search]);
        v.extend(ui().core.archive().into_iter().map(Page::Issue));
        v
    }

    fn flip(self: &Rc<Self>, d: i64) {
        let list = self.page_order();
        let here = sidebar_key(&self.page.borrow());
        let next = list.iter().position(|p| *p == here).map(|i| i as i64 + d).filter(|j| *j >= 0 && (*j as usize) < list.len());
        match next {
            Some(j) => self.go(list[j as usize].clone()),
            None => self.window.error_bell(),
        }
    }

    pub fn scroll_to(&self, y: f64) {
        if let Some(s) = self.current_scroll.borrow().as_ref() {
            s.vadjustment().set_value(y);
        }
    }
}

const SETTINGS_ROW: &str = "dc-settings-row"; // 옆 목록 맨 아래 '설정' 줄

// 옆 목록에서 이 지면에 해당하는 칸(스토리 상세는 '스토리')
fn sidebar_key(p: &Page) -> Page {
    match p {
        Page::Story(_) => Page::Stories,
        other => other.clone(),
    }
}

pub fn tint(w: &impl IsA<gtk::Widget>, hex: &str) {
    // 색 값은 출처(가져온 기록·상태 파일)에서 올 수 있으므로 #16진수·글자 이름만 CSS 에 넣는다(L6)
    let safe = (hex.starts_with('#') && (4..=9).contains(&hex.len()) && hex[1..].chars().all(|c| c.is_ascii_hexdigit()))
        || (!hex.is_empty() && hex.len() <= 20 && hex.chars().all(|c| c.is_ascii_alphabetic()));
    if !safe {
        return;
    }
    let prov = gtk::CssProvider::new();
    prov.load_from_string(&format!("* {{ color: {hex}; }}"));
    #[allow(deprecated)]
    w.as_ref().style_context().add_provider(&prov, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION);
}

// 맥 App.swift 와 같은 시험 찍기: 4·12·40초, 그다음 지면을 아래로 내려 가며
fn test_shots(m: &Rc<Magazine>, dir: std::path::PathBuf) {
    let _ = std::fs::create_dir_all(&dir);
    for sec in [4u64, 12, 40] {
        let w = m.window.clone();
        let d = dir.clone();
        widgets::later(sec * 1000, move || {
            shots::save(&w, &d.join(format!("mag-{sec}.png")));
        });
    }
    for (i, y) in [700.0, 1400.0, 2100.0, 2800.0, 3500.0, 4200.0].into_iter().enumerate() {
        let d = dir.clone();
        widgets::later(42_000 + i as u64 * 2000, move || {
            if let Some(m) = current() {
                m.scroll_to(y);
            }
        });
        widgets::later(43_000 + i as u64 * 2000, move || {
            if let Some(m) = current() {
                shots::save(&m.window, &d.join(format!("scroll-{}.png", y as i64)));
            }
        });
    }
}

// 시험용(DROPCAP_TEST_SCRAP): 오늘 호에서 3건을 "GPT 조사" 폴더에 문단+기사 스크랩(맥 App.swift 와 같음)
pub fn seed_test_scraps() {
    let core = ui().core.clone();
    crate::app::bg(
        async move {
            let ed = core.editorial();
            let issue = dropcap_core::magazine::live_daily(&core.db, &ed);
            let r = dropcap_core::magazine::resolve(&core.db, &issue, &ed.filter);
            r.sections.into_iter().flat_map(|(_, items)| items).take(3).collect::<Vec<_>>()
        },
        |items| {
            let ui = ui();
            {
                let mut book = ui.scrapbook.borrow_mut();
                for it in items {
                    book.add(&it, Some(format!("{} — 핵심 문단 예시입니다.", it.display_title())), Some(it.title.clone()), "보고서에 인용", Some("GPT 조사"));
                    book.add(&it, None, None, "", Some("GPT 조사"));
                }
            }
            ui.dispatch(&UiEvent::State);
        },
    );
}

thread_local! {
    static CSS_DONE: Cell<bool> = const { Cell::new(false) };
}

fn ensure_css() {
    if CSS_DONE.with(|c| c.replace(true)) {
        return;
    }
    let Some(display) = gdk::Display::default() else { return };
    let prov = gtk::CssProvider::new();
    prov.load_from_string(
        r#"
.dc-mag-bg { background-color: @view_bg_color; }
.dc-side-head { font-size: 11px; font-weight: 700; opacity: 0.55; margin: 12px 8px 2px 8px; }
.dc-magcard { border-radius: 14px; background-color: @view_bg_color; border: 1px solid alpha(@window_fg_color, 0.08);
  box-shadow: 0 4px 10px alpha(black, 0.12); transition: box-shadow 300ms cubic-bezier(0.2, 0.9, 0.25, 1), transform 300ms cubic-bezier(0.2, 0.9, 0.25, 1); padding: 0; }
.dc-magcard:hover { box-shadow: 0 10px 18px alpha(black, 0.20); transform: scale(1.025); }
.dc-magcard .dc-magphoto { transition: transform 300ms cubic-bezier(0.2, 0.9, 0.25, 1); }
.dc-magcard:hover .dc-magphoto { transform: scale(1.08); }
.dc-cover { border-radius: 20px; box-shadow: 0 10px 18px alpha(black, 0.20); transition: box-shadow 300ms cubic-bezier(0.2, 0.9, 0.25, 1); }
.dc-cover:hover { box-shadow: 0 14px 26px alpha(black, 0.28); }
.dc-cover-plain { background-color: alpha(@window_fg_color, 0.045); }
.dc-pill { border-radius: 99px; padding: 7px 14px; font-weight: 600; }
.dc-live { background-color: #ff3b30; color: white; border-radius: 99px; padding: 1px 7px; font-size: 10.5px; font-weight: 700; }
.dc-badge { background-color: alpha(@window_fg_color, 0.9); color: @view_bg_color; border-radius: 4px; padding: 2px 7px; font-weight: 800; font-size: 11px; letter-spacing: 1.5px; }
.dc-badge-photo { background-color: white; color: black; }
.dc-banner { border-radius: 99px; padding: 8px 14px; background-color: alpha(@window_bg_color, 0.95); border: 1px solid alpha(@window_fg_color, 0.1); box-shadow: 0 4px 10px alpha(black, 0.15); font-weight: 600; }
.dc-soft { background-color: alpha(@window_fg_color, 0.04); border-radius: 14px; }
.dc-soft:hover { background-color: alpha(@window_fg_color, 0.07); }
.dc-quote { border-left: 3px solid alpha(#F5C518, 0.7); padding-left: 12px; }
.dc-weekly { background-color: alpha(#F5C518, 0.07); border: 1px solid alpha(#F5C518, 0.25); border-radius: 16px; padding: 18px; }
.dc-folder { border-radius: 99px; padding: 5px 11px; background-color: alpha(@window_fg_color, 0.05); }
.dc-folder-on { background-color: alpha(@accent_bg_color, 0.16); color: @accent_color; font-weight: 600; }
.dc-secchip { border-radius: 99px; padding: 4px 9px; font-weight: 500; }
.dc-fresh { background-color: #ff3b30; color: white; border-radius: 99px; padding: 1px 6px; font-size: 10.5px; font-weight: 700; }
.dc-kind { background-color: alpha(@window_bg_color, 0.85); border-radius: 5px; padding: 2px 6px; font-size: 10.5px; font-weight: 600; }
.dc-play { background-color: alpha(black, 0.45); color: white; border-radius: 99px; border: 1px solid alpha(white, 0.6); min-width: 46px; min-height: 46px; }
"#,
    );
    gtk::style_context_add_provider_for_display(&display, &prov, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION);
}
