// 상단바(트레이) 창(U-02~U-08, 맥 UI/MenuView.swift·MenuStyles.swift): 최근 소식(전체·안 읽음·저장) + 몇 가지 동작.
// 트레이가 떠 있으면 아이콘 근처에 테두리 없이 뜨고 다른 곳을 누르면 닫힌다. 트레이가 없으면 보통 창으로 뜬다.
// 목록은 맥 기본 모양 '첫 소식 크게'(첫 기사 큰 사진 카드 + 나머지 사진 카드). 사진이 없으면 사진 자리를 만들지 않는다.
use crate::app::{bg, copy_text, open_external, ui};
use crate::menu_chips::{ChipBar, Pick};
use crate::widgets::{self, clear_box, icon, label, lines};
use adw::prelude::*;
use chrono::{Duration, Local, Utc};
use dropcap_core::app_model::{by_importance, clock, title_words, tomorrow_morning, UiEvent};
use dropcap_core::article::image_key;
use dropcap_core::models::NewsItem;
use dropcap_core::notify_policy::NotifyMode;
use dropcap_core::sections;
use gtk::{gdk, gio, glib};
use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

pub const WIDTH: i32 = 370;
pub const LIST_HEIGHT: i32 = 400;
const HERO_W: i32 = 346;
const HERO_H: i32 = 168;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Tab {
    All,
    Unread,
    Saved,
}

struct Menu {
    window: gtk::Window,
    tab: Tab,
    query: String,
    pick: Pick,
    coverage: HashMap<String, i64>, // 중요순 점수에 쓰는 기사별 보도 수(뒤에서 받아 둠)
    // 머리
    quiet: gtk::Image,
    hush: gtk::Image, // 회의·발표 중 자동 조용히(N-25) 이유
    status: gtk::Label,
    snooze_icon: gtk::Image,
    snooze_button: gtk::MenuButton,
    refresh: gtk::Button,
    spinner: gtk::Spinner,
    // 탭
    tabs: Vec<(Tab, gtk::ToggleButton)>,
    sort_button: gtk::MenuButton,
    chips: Rc<ChipBar>,
    // 목록
    list: gtk::Box,
    scroll: gtk::ScrolledWindow,
    shown: Vec<(NewsItem, gtk::Widget)>, // 지금 보이는 순서(키보드 탐색·읽기 창 J/K)
    selected: Option<String>,            // 키보드로 고른 소식(H-03)
    stack: gtk::Stack,
    empty_icon: gtk::Image,
    empty_title: gtk::Label,
    empty_sub: gtk::Label,
}

thread_local! {
    static MENU: RefCell<Option<Rc<RefCell<Menu>>>> = const { RefCell::new(None) };
}

fn current() -> Option<Rc<RefCell<Menu>>> {
    MENU.with(|m| m.borrow().clone())
}

pub fn open() {
    open_at(None);
}

// 트레이 아이콘을 누르면: 떠 있으면 닫고, 아니면 연다(at = 아이콘을 누른 화면 좌표)
#[cfg_attr(not(feature = "tray"), allow(dead_code))]
pub fn toggle_at(at: Option<(i32, i32)>) {
    if let Some(m) = current() {
        let w = m.borrow().window.clone();
        if w.is_visible() {
            w.set_visible(false);
            return;
        }
    }
    open_at(at);
}

fn open_at(at: Option<(i32, i32)>) {
    let m = current().unwrap_or_else(build);
    let w = m.borrow().window.clone();
    refresh(&m);
    w.present();
    // 창을 열면 안 읽음 수 초기화(U-08)
    ui().core.mark_read();
    // 열자마자 검색칸에 입력 커서가 들어가지 않게
    gtk::prelude::GtkWindowExt::set_focus(&w, None::<&gtk::Widget>);
    place(&w, at);
    crate::shots::shot_later(&w, "menu", 4000);
}

fn css(w: &impl IsA<gtk::Widget>, rule: &str) {
    let prov = gtk::CssProvider::new();
    prov.load_from_string(rule);
    #[allow(deprecated)]
    w.as_ref().style_context().add_provider(&prov, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
}

// MARK: 만들기
fn build() -> Rc<RefCell<Menu>> {
    let u = ui();
    let popup = crate::tray::active() && u.env.shot_dir.is_none();
    let window = gtk::Window::builder().title("Dropcap").resizable(false).decorated(!popup).default_width(WIDTH).build();
    window.set_application(Some(&u.app));
    window.set_hide_on_close(true);
    if popup {
        window.add_css_class("dc-glass");
    }

    let root = gtk::Box::new(gtk::Orientation::Vertical, 0);
    root.set_size_request(WIDTH, -1);

    // 머리(U-02): 'Dropcap' 제목 + 확인 시각(+방해 금지 표시·잠시 끄기·지금 확인)
    let header = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    header.set_margin_start(16);
    header.set_margin_end(12);
    header.set_margin_top(14);
    header.set_margin_bottom(10);
    let titles = gtk::Box::new(gtk::Orientation::Vertical, 2);
    titles.set_valign(gtk::Align::Center);
    let title_row = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    let t = label("Dropcap", 16.0, 800, &[]);
    t.set_wrap(false);
    title_row.append(&t);
    let quiet = icon("weather-clear-night-symbolic", 12);
    quiet.set_tooltip_text(Some("방해 금지 시간이라 알림을 띄우지 않습니다"));
    css(&quiet, "image { color: #5856D6; }");
    title_row.append(&quiet);
    let hush = icon("system-users-symbolic", 12);
    css(&hush, "image { color: #5856D6; }");
    title_row.append(&hush);
    titles.append(&title_row);
    let status = label("", 11.0, 400, &["dc-secondary", "numeric"]);
    status.set_wrap(false);
    titles.append(&status);
    header.append(&titles);
    let spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    spacer.set_hexpand(true);
    header.append(&spacer);

    let snooze_icon = icon("preferences-system-notifications-symbolic", 14);
    let snooze_button = gtk::MenuButton::builder().child(&snooze_icon).css_classes(["flat"]).valign(gtk::Align::Center).build();
    header.append(&snooze_button);

    let refresh_box = gtk::Stack::new();
    let refresh_btn = gtk::Button::builder().icon_name("view-refresh-symbolic").css_classes(["flat"]).tooltip_text("지금 확인").build();
    let spinner = gtk::Spinner::new();
    refresh_box.add_named(&refresh_btn, Some("button"));
    refresh_box.add_named(&spinner, Some("spin"));
    refresh_box.set_valign(gtk::Align::Center);
    refresh_btn.connect_clicked(|_| ui().core.check_now());
    header.append(&refresh_box);
    root.append(&header);

    // 탭(U-03)
    let tab_box = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    tab_box.add_css_class("linked");
    tab_box.set_homogeneous(true);
    tab_box.set_margin_start(14);
    tab_box.set_margin_end(14);
    tab_box.set_margin_bottom(8);
    let mut tabs = vec![];
    let mut first: Option<gtk::ToggleButton> = None;
    for (t, name) in [(Tab::All, "전체"), (Tab::Unread, "안 읽음"), (Tab::Saved, "저장")] {
        let b = gtk::ToggleButton::with_label(name);
        if let Some(f) = &first {
            b.set_group(Some(f));
        } else {
            first = Some(b.clone());
        }
        tab_box.append(&b);
        tabs.push((t, b));
    }
    tabs[0].1.set_active(true);
    root.append(&tab_box);

    // 검색칸 + 정렬 메뉴 한 줄(U-04), 그 아래 분야 칩 줄(G-09)
    let search_row = gtk::Box::new(gtk::Orientation::Horizontal, 4);
    search_row.set_margin_start(14);
    search_row.set_margin_end(14);
    search_row.set_margin_bottom(8);
    let search = gtk::SearchEntry::builder().placeholder_text("제목·출처 검색").hexpand(true).build();
    search_row.append(&search);
    let sort_button = gtk::MenuButton::builder().css_classes(["flat"]).tooltip_text("정렬").build();
    search_row.append(&sort_button);
    root.append(&search_row);
    let chips = ChipBar::new(true);
    chips.root.set_margin_start(14);
    chips.root.set_margin_end(14);
    chips.root.set_margin_bottom(8);
    root.append(&chips.root);
    root.append(&gtk::Separator::new(gtk::Orientation::Horizontal));

    // 목록(높이 고정: 내용이 줄어도 창 크기를 줄이지 않는다)
    let list = gtk::Box::new(gtk::Orientation::Vertical, 2);
    list.set_margin_start(6);
    list.set_margin_end(6);
    list.set_margin_top(6);
    list.set_margin_bottom(6);
    let scroll = gtk::ScrolledWindow::builder().hscrollbar_policy(gtk::PolicyType::Never).child(&list).build();
    let empty = gtk::Box::new(gtk::Orientation::Vertical, 8);
    empty.set_valign(gtk::Align::Center);
    empty.set_margin_start(24);
    empty.set_margin_end(24);
    let empty_icon = icon("x-office-document-symbolic", 30);
    empty_icon.add_css_class("dc-tertiary");
    let empty_title = label("", 13.0, 500, &[]);
    empty_title.set_xalign(0.5);
    empty_title.set_justify(gtk::Justification::Center);
    let empty_sub = label("", 11.5, 400, &["dc-secondary"]);
    empty_sub.set_xalign(0.5);
    empty_sub.set_justify(gtk::Justification::Center);
    empty.append(&empty_icon);
    empty.append(&empty_title);
    empty.append(&empty_sub);
    let stack = gtk::Stack::new();
    stack.add_named(&scroll, Some("list"));
    stack.add_named(&empty, Some("empty"));
    stack.set_size_request(WIDTH, LIST_HEIGHT);
    // '저장' 탭에서만: 목록 위 '주소로 추가…' 칸(I-05)
    let add_bar = crate::add_url_bar::build(true);
    add_bar.set_margin_start(10);
    add_bar.set_margin_end(10);
    add_bar.set_margin_top(6);
    add_bar.set_visible(false);
    // 칸이 보여도 창 높이는 그대로(목록 자리를 나눠 씀)
    let body = gtk::Box::new(gtk::Orientation::Vertical, 0);
    body.set_size_request(WIDTH, LIST_HEIGHT);
    stack.set_size_request(WIDTH, -1);
    stack.set_vexpand(true);
    body.append(&add_bar);
    body.append(&stack);
    root.append(&body);
    root.append(&gtk::Separator::new(gtk::Orientation::Horizontal));

    // 바닥(U-07)
    let footer = gtk::Box::new(gtk::Orientation::Horizontal, 4);
    footer.set_margin_start(10);
    footer.set_margin_end(10);
    footer.set_margin_top(8);
    footer.set_margin_bottom(8);
    let mag = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    mag.append(&icon("accessories-dictionary-symbolic", 14));
    let ml = label("매거진 열기", 12.5, 600, &[]);
    ml.set_wrap(false);
    mag.append(&ml);
    let sc = label("Ctrl+Alt+M", 11.0, 400, &[]);
    sc.set_wrap(false);
    sc.set_opacity(0.7);
    mag.append(&sc);
    let mag_btn = gtk::Button::builder().child(&mag).css_classes(["dc-accent-button"]).build();
    mag_btn.connect_clicked(|_| crate::magazine::open());
    footer.append(&mag_btn);
    let fs = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    fs.set_hexpand(true);
    footer.append(&fs);
    let settings_btn = gtk::Button::builder().icon_name("emblem-system-symbolic").css_classes(["flat"]).tooltip_text("설정").build();
    settings_btn.connect_clicked(|_| crate::settings::open(None));
    footer.append(&settings_btn);
    let more = gio::Menu::new();
    more.append(Some("모두 읽음으로 표시"), Some("menu.all-read"));
    more.append(Some("알림 미리 보기"), Some("menu.preview"));
    let quit = gio::Menu::new();
    quit.append(Some("Dropcap 종료"), Some("menu.quit"));
    more.append_section(None, &quit);
    let more_btn = gtk::MenuButton::builder().icon_name("view-more-symbolic").css_classes(["flat"]).tooltip_text("더 보기").menu_model(&more).build();
    footer.append(&more_btn);
    root.append(&footer);

    window.set_child(Some(&root));

    let m = Rc::new(RefCell::new(Menu {
        window: window.clone(),
        tab: Tab::All,
        query: String::new(),
        pick: Pick::default(),
        coverage: HashMap::new(),
        quiet,
        hush,
        status,
        snooze_icon,
        snooze_button: snooze_button.clone(),
        refresh: refresh_btn,
        spinner,
        tabs,
        sort_button: sort_button.clone(),
        chips: chips.clone(),
        list,
        scroll: scroll.clone(),
        shown: vec![],
        selected: None,
        stack,
        empty_icon,
        empty_title,
        empty_sub,
    }));
    MENU.with(|c| *c.borrow_mut() = Some(m.clone()));

    // 동작
    let actions = gio::SimpleActionGroup::new();
    let add = |name: &str, f: fn()| {
        let a = gio::SimpleAction::new(name, None);
        a.connect_activate(move |_, _| f());
        actions.add_action(&a);
    };
    add("all-read", || ui().core.mark_all_read());
    add("preview", || ui().core.preview());
    add("quit", || ui().app.quit());
    add("snooze-1h", || ui().core.snooze(Some(Utc::now() + Duration::hours(1))));
    add("snooze-3h", || ui().core.snooze(Some(Utc::now() + Duration::hours(3))));
    add("snooze-morning", || ui().core.snooze(Some(tomorrow_morning(Local::now(), 8))));
    add("snooze-off", || ui().core.snooze(None));
    let sort = gio::SimpleAction::new_stateful("sort", Some(glib::VariantTy::STRING), &u.prefs.borrow().list_sort.to_variant());
    {
        let m = m.clone();
        sort.connect_activate(move |a, v| {
            if let Some(s) = v.and_then(|v| v.str().map(|s| s.to_string())) {
                a.set_state(&s.to_variant());
                ui().update_prefs(|p| p.list_sort = s);
                refresh(&m);
            }
        });
    }
    actions.add_action(&sort);
    window.insert_action_group("menu", Some(&actions));

    let sort_menu = gio::Menu::new();
    sort_menu.append(Some("최신순"), Some("menu.sort::newest"));
    sort_menu.append(Some("중요·많이 보도된 순"), Some("menu.sort::important"));
    sort_menu.append(Some("출처별"), Some("menu.sort::source"));
    sort_button.set_menu_model(Some(&sort_menu));

    {
        let m2 = m.clone();
        chips.connect_changed(move |p| {
            m2.borrow_mut().pick = p.clone();
            refresh(&m2);
        });
    }
    for (t, b) in m.borrow().tabs.iter() {
        let m2 = m.clone();
        let t = *t;
        let add_bar = add_bar.clone();
        b.connect_toggled(move |b| {
            if b.is_active() {
                add_bar.set_visible(t == Tab::Saved);
                m2.borrow_mut().tab = t;
                refresh(&m2);
            }
        });
    }
    {
        let m = m.clone();
        search.connect_search_changed(move |e| {
            m.borrow_mut().query = e.text().to_string();
            refresh(&m);
        });
    }

    // 키보드 탐색(H-03): 열면 목록이 키를 받고, 검색칸에서 ↓ 로 목록으로
    {
        let m = m.clone();
        let win = window.clone();
        crate::keynav::attach(&window, move |key, state| {
            let Some(k) = crate::keynav::NavKey::from(key, state) else { return false };
            if crate::keynav::typing(&win) {
                if k != crate::keynav::NavKey::Next || !matches!(key, gdk::Key::Down | gdk::Key::KP_Down) {
                    return false;
                }
                gtk::prelude::GtkWindowExt::set_focus(&win, None::<&gtk::Widget>);
            }
            key_nav(&m, k);
            true
        });
    }

    // 다른 곳을 누르면 닫힘(트레이에서 내려온 창일 때)
    if popup {
        window.connect_is_active_notify(|w| {
            if !w.is_active() && w.is_visible() {
                let w = w.clone();
                widgets::later(120, move || {
                    if !w.is_active() {
                        w.set_visible(false);
                    }
                });
            }
        });
    }

    // 핵심 소식이 오면 갱신(숨긴 출처·고른 분야가 바뀌어도)
    {
        let m = m.clone();
        u.listen(move |e| {
            if matches!(e, UiEvent::State | UiEvent::Checking(_) | UiEvent::Layout | UiEvent::Paywall) && m.borrow().window.is_visible() {
                refresh(&m);
            }
        });
    }
    m
}

// 주요 뉴스 칩: 여러 곳이 함께 다룬 소식·공식 발표·꼭 알림 낱말
fn in_pick(it: &NewsItem, p: &Pick) -> bool {
    if let Some(s) = &p.section {
        let ok = if s == sections::TOP { it.related_count() >= 1 || it.tier == "lab" || it.is_important() } else { it.in_section(s) };
        if !ok {
            return false;
        }
    }
    p.sub.map(|c| it.category() == c).unwrap_or(true)
}

fn items(m: &Menu, recent: &[NewsItem], saved: &[NewsItem], read: &HashSet<String>) -> Vec<NewsItem> {
    let mut list: Vec<NewsItem> = match m.tab {
        Tab::All => recent.to_vec(),
        Tab::Unread => recent.iter().filter(|i| !read.contains(&i.key())).cloned().collect(),
        Tab::Saved => saved.to_vec(),
    };
    list.retain(|i| in_pick(i, &m.pick));
    let q = m.query.trim().to_lowercase();
    if !q.is_empty() {
        list.retain(|i| format!("{} {} {} {}", i.title, i.title_ko.as_deref().unwrap_or(""), i.source_name, i.summary).to_lowercase().contains(&q));
    }
    match ui().prefs.borrow().list_sort.as_str() {
        "important" => by_importance(list, &m.coverage, Utc::now()),
        "source" => {
            list.sort_by(|a, b| a.source_name.cmp(&b.source_name).then(b.date_or_past().cmp(&a.date_or_past())));
            list
        }
        _ => {
            list.sort_by(|a, b| b.date_or_past().cmp(&a.date_or_past()));
            list
        }
    }
}

fn refresh(m: &Rc<RefCell<Menu>>) {
    // 중요순은 기사별 보도 수(DB)가 필요하다 — 화면을 멈추지 않게 뒤에서 받아 온 뒤 그린다
    if ui().prefs.borrow().list_sort == "important" {
        let core = ui().core.clone();
        let m2 = m.clone();
        bg(
            async move {
                let st = core.state();
                let all: Vec<NewsItem> = st.recent.into_iter().chain(st.saved).collect();
                core.coverage(&all)
            },
            move |cov| {
                m2.borrow_mut().coverage = cov;
                render(&m2);
            },
        );
    }
    render(m);
}

fn render(m: &Rc<RefCell<Menu>>) {
    let u = ui();
    let core = &u.core;
    let st = core.state();
    let checking = core.is_checking();
    let chosen = core.chosen_sections();
    // 분야 칩(고른 분야). 칩을 누르면 refresh 가 다시 불린다
    let chips = m.borrow().chips.clone();
    chips.rebuild(&chosen, &HashMap::new());
    let mm = m.borrow();

    // 머리: 회의·발표 중이면 그 이유, 아니면 방해 금지 달
    let hush = core.auto_quiet_reason();
    mm.hush.set_visible(hush.is_some());
    if let Some(r) = hush {
        mm.hush.set_tooltip_text(Some(&format!("{}이라 알림을 띄우지 않고 모아 둡니다", r.label())));
    }
    mm.quiet.set_visible(hush.is_none() && core.is_quiet_time());
    mm.status.set_text(&if checking { "확인하는 중…".to_string() } else { format!("마지막 확인 {}", clock(st.last_check)) });
    let snoozed = core.is_snoozed();
    mm.snooze_icon.set_icon_name(Some(if snoozed { "notifications-disabled-symbolic" } else { "preferences-system-notifications-symbolic" }));
    if snoozed {
        mm.snooze_icon.add_css_class("warning");
    } else {
        mm.snooze_icon.remove_css_class("warning");
    }
    mm.snooze_button.set_tooltip_text(Some(&if snoozed { format!("알림 꺼짐 — {}까지", clock(st.snooze_until)) } else { "알림 잠시 끄기".into() }));
    let sm = gio::Menu::new();
    if snoozed {
        sm.append(Some("다시 알림 켜기"), Some("menu.snooze-off"));
    } else {
        sm.append(Some("1시간 동안"), Some("menu.snooze-1h"));
        sm.append(Some("3시간 동안"), Some("menu.snooze-3h"));
        sm.append(Some("내일 아침 8시까지"), Some("menu.snooze-morning"));
    }
    mm.snooze_button.set_menu_model(Some(&sm));
    mm.refresh.set_visible(!checking);
    mm.spinner.set_visible(checking);
    mm.spinner.set_spinning(checking);
    if let Some(p) = mm.refresh.parent().and_then(|p| p.downcast::<gtk::Stack>().ok()) {
        p.set_visible_child_name(if checking { "spin" } else { "button" });
    }

    // 정렬 단추: 지금 정렬이 무엇인지(최신순이 아닐 때는 이름까지)
    let sort = u.prefs.borrow().list_sort.clone();
    let sb = gtk::Box::new(gtk::Orientation::Horizontal, 3);
    let (ic, name) = match sort.as_str() {
        "important" => ("starred-symbolic", Some("중요순")),
        "source" => ("system-users-symbolic", Some("출처별")),
        _ => ("view-sort-descending-symbolic", None),
    };
    sb.append(&icon(ic, 13));
    if let Some(n) = name {
        let l = label(n, 11.0, 600, &["accent"]);
        l.set_wrap(false);
        sb.append(&l);
    }
    mm.sort_button.set_child(Some(&sb));

    // 탭: 안 읽음 N
    let read: HashSet<String> = st.read.keys().cloned().collect();
    // 꺼진·지운·숨긴 출처 글과 '알리지 않음' 낱말 글은 빼고(지우지 않고 거르기만, S-13)
    let visible = core.visible_recent();
    let unread = visible.iter().filter(|i| !read.contains(&i.key())).count();
    for (t, b) in &mm.tabs {
        if *t == Tab::Unread {
            b.set_label(&format!("안 읽음 {unread}"));
        }
    }

    // 목록
    let list = items(&mm, &visible, &st.saved, &read);
    clear_box(&mm.list);
    drop(mm);
    m.borrow_mut().shown.clear();
    let mm = m.borrow();
    if list.is_empty() {
        let filtered = !mm.query.trim().is_empty() || mm.pick.section.is_some() || mm.pick.sub.is_some();
        mm.empty_icon.set_icon_name(Some(if mm.tab == Tab::Saved { "user-bookmarks-symbolic" } else { "x-office-document-symbolic" }));
        mm.empty_title.set_text(if filtered {
            "맞는 소식이 없습니다"
        } else {
            match mm.tab {
                Tab::Saved => "저장한 소식이 없습니다",
                Tab::Unread => "모두 읽었습니다",
                Tab::All => "아직 새 소식이 없습니다",
            }
        });
        mm.empty_sub.set_text(if mm.tab == Tab::Saved {
            "소식을 오른쪽 클릭해 '나중에 읽기'로 저장할 수 있어요"
        } else {
            "새 글이 올라오면 물방울이 떨어지듯 알려 드려요"
        });
        mm.stack.set_visible_child_name("empty");
        return;
    }
    let saved_keys: HashSet<String> = st.saved.iter().map(|s| s.key()).collect();
    let by_source = sort == "source";
    let mut shown: Vec<(NewsItem, gtk::Widget)> = vec![];
    for (i, it) in list.iter().enumerate() {
        let prev = if i > 0 { Some(&list[i - 1]) } else { None };
        // 출처별일 때는 출처가 바뀌는 곳에 이름표
        if by_source && prev.map(|p| p.source_name != it.source_name).unwrap_or(true) {
            let n = list.iter().filter(|x| x.source_name == it.source_name).count();
            mm.list.append(&source_label(&it.source_name, n, i == 0));
        }
        // 시간 묶음 이름표(방금·오늘·어제·이전) — 첫 큰 카드 위에는 두지 않고, 그 바로 뒤에는 늘 붙인다
        if !by_source && i > 0 {
            if let Some(t) = time_section(it, if i == 1 { None } else { prev }) {
                mm.list.append(&section_label(&t, i == 1));
            }
        }
        let r = read.contains(&it.key());
        let w = if i == 0 && !by_source { hero_card(it, r, &list) } else { card_row(it, r, saved_keys.contains(&it.key()), &list) };
        mm.list.append(&w);
        shown.push((it.clone(), w));
    }
    mm.stack.set_visible_child_name("list");
    let sel = mm.selected.clone();
    drop(mm);
    let mut mb = m.borrow_mut();
    mb.shown = shown;
    // 다시 그려도 고른 것은 그대로(목록에서 빠졌으면 고르지 않음)
    if mb.selected.is_some() && !mb.shown.iter().any(|(it, _)| Some(it.key()) == sel) {
        mb.selected = None;
    }
    for (it, w) in &mb.shown {
        crate::keynav::mark(w, Some(it.key()) == mb.selected);
    }
}

// 시험용: 키를 누른 것처럼(DROPCAP_TEST_KEYNAV)
pub fn test_key(k: crate::keynav::NavKey) -> Option<gtk::Window> {
    let m = current()?;
    key_nav(&m, k);
    let w = m.borrow().window.clone();
    Some(w)
}

// 고른 소식 옮기기·열기·저장·브라우저·읽음(H-03)
fn key_nav(m: &Rc<RefCell<Menu>>, k: crate::keynav::NavKey) {
    use crate::keynav::NavKey;
    let (keys, sel) = {
        let mb = m.borrow();
        (mb.shown.iter().map(|(it, _)| it.key()).collect::<Vec<_>>(), mb.selected.clone())
    };
    match k {
        NavKey::Next | NavKey::Prev => {
            let next = crate::keynav::step(sel.as_deref(), &keys, if k == NavKey::Next { 1 } else { -1 });
            let mut mb = m.borrow_mut();
            mb.selected = next.clone();
            for (it, w) in &mb.shown {
                crate::keynav::mark(w, Some(it.key()) == next);
            }
            if let Some((_, w)) = mb.shown.iter().find(|(it, _)| Some(it.key()) == next) {
                crate::keynav::center(&mb.scroll, w);
            }
        }
        _ => {
            let (item, seq) = {
                let mb = m.borrow();
                let Some(item) = mb.shown.iter().find(|(it, _)| Some(it.key()) == sel).map(|(it, _)| it.clone()) else { return };
                (item, mb.shown.iter().map(|(it, _)| it.clone()).collect::<Vec<_>>())
            };
            crate::keynav::perform(k, &item, &seq, false);
        }
    }
}

// 시간 묶음: 방금(1시간 안) · 오늘 · 어제 · 이전 — 앞 기사와 묶음이 바뀔 때만(첫 카드 바로 뒤는 늘 붙임)
fn bucket(it: &NewsItem) -> &'static str {
    let Some(d) = it.date else { return "이전" };
    let now = Utc::now();
    if (now - d).num_seconds() < 3600 {
        return "방금";
    }
    let day = d.with_timezone(&Local).date_naive();
    let today = now.with_timezone(&Local).date_naive();
    if day == today {
        "오늘"
    } else if day == today - Duration::days(1) {
        "어제"
    } else {
        "이전"
    }
}

fn time_section(it: &NewsItem, prev: Option<&NewsItem>) -> Option<String> {
    let b = bucket(it);
    match prev {
        Some(p) if bucket(p) == b => None,
        _ => Some(b.to_string()),
    }
}

fn section_label(text: &str, first: bool) -> gtk::Widget {
    let h = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    h.set_margin_start(8);
    h.set_margin_end(8);
    h.set_margin_top(if first { 4 } else { 12 });
    h.set_margin_bottom(4);
    let l = label(text, 11.0, 700, &["dc-secondary"]);
    l.set_wrap(false);
    h.append(&l);
    let line = gtk::Separator::new(gtk::Orientation::Horizontal);
    line.set_hexpand(true);
    line.set_valign(gtk::Align::Center);
    line.set_opacity(0.5);
    h.append(&line);
    h.upcast()
}

fn source_label(name: &str, n: usize, first: bool) -> gtk::Widget {
    let h = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    h.add_css_class("dc-secondary");
    h.set_margin_start(8);
    h.set_margin_top(if first { 2 } else { 10 });
    h.set_margin_bottom(2);
    let l = label(name, 11.0, 700, &[]);
    l.set_wrap(false);
    h.append(&l);
    let c = label(&n.to_string(), 10.5, 400, &["dc-tertiary"]);
    c.set_wrap(false);
    h.append(&c);
    h.upcast()
}

// 사진 주소: 피드 사진, 없으면 매거진이 기사 머리에서 찾아 둔 대표 사진. 잡그림(로고·아바타 등)은 쓰지 않는다
fn photo_url(it: &NewsItem, cb: impl FnOnce(Option<String>) + 'static) {
    if let Some(u) = it.image.clone().filter(|u| !image_key::is_junk(Some(u))) {
        cb(Some(u));
        return;
    }
    let core = ui().core.clone();
    let key = it.key();
    bg(async move { core.db.image(&key) }, move |u: Option<String>| cb(u.filter(|u| !image_key::is_junk(Some(u)))));
}

// 텍스처를 cairo 그림으로(한 번만 바꿔 두고 다시 그릴 때 쓴다)
fn surface_of(tex: &gdk::Texture) -> Option<gtk::cairo::ImageSurface> {
    let (w, h) = (tex.width(), tex.height());
    let stride = gtk::cairo::Format::ARgb32.stride_for_width(w as u32).ok()?;
    let mut data = vec![0u8; (stride * h) as usize];
    // gdk 기본 내려받기 형식은 미리 곱한 BGRA(리틀 엔디언) = cairo ARGB32 와 같다
    tex.download(&mut data, stride as usize);
    gtk::cairo::ImageSurface::create_for_data(data, gtk::cairo::Format::ARgb32, w, h, stride).ok()
}

// 사진 칸: 정한 크기에 꽉 차게 잘라 둥근 모서리로. 사진을 받으면 나타나고, 없으면 자리를 차지하지 않는다(대체 그림 없음)
fn thumb(it: &NewsItem, w: i32, h: i32, radius: i32) -> gtk::DrawingArea {
    let area = gtk::DrawingArea::builder().content_width(w).content_height(h).visible(false).build();
    let surf: Rc<RefCell<Option<gtk::cairo::ImageSurface>>> = Rc::new(RefCell::new(None));
    {
        let surf = surf.clone();
        area.set_draw_func(move |_, cr, aw, ah| {
            let Some(s) = surf.borrow().clone() else { return };
            let (aw, ah) = (aw as f64, ah as f64);
            let r = radius as f64;
            // 둥근 사각형으로 자르기
            cr.new_sub_path();
            cr.arc(aw - r, r, r, -std::f64::consts::FRAC_PI_2, 0.0);
            cr.arc(aw - r, ah - r, r, 0.0, std::f64::consts::FRAC_PI_2);
            cr.arc(r, ah - r, r, std::f64::consts::FRAC_PI_2, std::f64::consts::PI);
            cr.arc(r, r, r, std::f64::consts::PI, 1.5 * std::f64::consts::PI);
            cr.close_path();
            cr.clip();
            let (sw, sh) = (s.width() as f64, s.height() as f64);
            let k = (aw / sw).max(ah / sh); // 꽉 차게(cover)
            cr.translate((aw - sw * k) / 2.0, (ah - sh * k) / 2.0);
            cr.scale(k, k);
            let _ = cr.set_source_surface(&s, 0.0, 0.0);
            cr.source().set_filter(gtk::cairo::Filter::Good);
            let _ = cr.paint();
        });
    }
    let a2 = area.clone();
    photo_url(it, move |u| {
        let Some(u) = u else { return };
        widgets::load_texture(&u, move |tex| {
            let Some(t) = tex else { return };
            *surf.borrow_mut() = surface_of(&t);
            if surf.borrow().is_some() {
                a2.set_visible(true);
                a2.queue_draw();
                widgets::fade_in(&a2, crate::motion::SLOW);
            }
        });
    });
    area
}

// 분야 칩 글자(AI 분야는 'AI·모델' 처럼 하위 분류까지)
fn topic(it: &NewsItem) -> gtk::Label {
    let l = label(&it.topic_label(), 10.5, 600, &[]);
    l.set_wrap(false);
    let (r, g, b) = dropcap_core::models::hex_rgb(&it.topic_color(crate::theme::is_dark()));
    css(&l, &format!("label {{ color: rgb({},{},{}); }}", (r * 255.0) as u8, (g * 255.0) as u8, (b * 255.0) as u8));
    l
}

// 출처 분야와 다른데 낱말이 강하게 걸린 분야 칩 하나 더(예: 정치 출처의 기준금리 기사 → 정치 · 경제)
fn extra_topic(it: &NewsItem) -> Option<gtk::Label> {
    let x = it.extra_topic()?;
    let l = label(&sections::name(&x), 10.5, 600, &[]);
    l.set_wrap(false);
    let hex = sections::by_id(&x).map(|s| s.color.clone()).unwrap_or_else(|| "#8E8E93".into());
    let (r, g, b) = dropcap_core::models::hex_rgb(&hex);
    css(&l, &format!("label {{ color: rgb({},{},{}); }}", (r * 255.0) as u8, (g * 255.0) as u8, (b * 255.0) as u8));
    Some(l)
}

fn unread_dot(it: &NewsItem, size: i32) -> gtk::DrawingArea {
    let dot = gtk::DrawingArea::builder().content_width(size).content_height(size).valign(gtk::Align::Center).build();
    let color = widgets::source_color(&it.source_id);
    dot.set_draw_func(move |_, cr, w, hh| {
        let (r, g, b) = dropcap_core::models::hex_rgb(&color);
        cr.set_source_rgb(r, g, b);
        cr.arc(w as f64 / 2.0, hh as f64 / 2.0, (w.min(hh) as f64) / 2.0, 0.0, std::f64::consts::TAU);
        let _ = cr.fill();
    });
    dot
}

// 첫 소식 크게: 사진 위에 제목(아래 어둡게). 사진이 없으면 사진 없이 글자 카드로
fn hero_card(it: &NewsItem, read: bool, seq: &[NewsItem]) -> gtk::Widget {
    let overlay = gtk::Overlay::new();
    overlay.set_overflow(gtk::Overflow::Hidden);
    overlay.set_margin_top(4);
    overlay.set_margin_bottom(4);
    overlay.set_margin_start(6);
    overlay.set_margin_end(6);
    css(&overlay, "overlay { border-radius: 14px; }");
    // 사진 없을 때의 바탕: 옅은 카드
    let base = gtk::Box::new(gtk::Orientation::Vertical, 0);
    base.add_css_class("dc-card");
    overlay.set_child(Some(&base));
    let pic = gtk::Picture::new();
    pic.set_content_fit(gtk::ContentFit::Cover);
    pic.set_can_shrink(true);
    pic.set_size_request(HERO_W, HERO_H);
    pic.set_visible(false);
    overlay.add_overlay(&pic);
    let shade = gtk::DrawingArea::new();
    shade.set_draw_func(|_, cr, _w, h| {
        let g = gtk::cairo::LinearGradient::new(0.0, h as f64 * 0.5, 0.0, h as f64);
        g.add_color_stop_rgba(0.0, 0.0, 0.0, 0.0, 0.0);
        g.add_color_stop_rgba(1.0, 0.0, 0.0, 0.0, 0.72);
        let _ = cr.set_source(&g);
        let _ = cr.paint();
    });
    shade.set_visible(false);
    overlay.add_overlay(&shade);
    let text = gtk::Box::new(gtk::Orientation::Vertical, 5);
    text.set_valign(gtk::Align::End);
    text.set_margin_start(13);
    text.set_margin_end(13);
    text.set_margin_bottom(13);
    text.set_margin_top(13);
    let meta = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    let chip = label(&it.topic_label(), 10.5, 700, &[]);
    chip.set_wrap(false);
    let (r, g, b) = dropcap_core::models::hex_rgb(&it.topic_color(crate::theme::is_dark()));
    css(&chip, &format!("label {{ color: white; background: rgba({},{},{},0.85); border-radius: 99px; padding: 2px 7px; }}", (r * 255.0) as u8, (g * 255.0) as u8, (b * 255.0) as u8));
    meta.append(&chip);
    if let Some(x) = it.extra_topic() {
        let c2 = label(&sections::name(&x), 10.5, 700, &[]);
        c2.set_wrap(false);
        let hex = sections::by_id(&x).map(|s| s.color.clone()).unwrap_or_else(|| "#8E8E93".into());
        let (r, g, b) = dropcap_core::models::hex_rgb(&hex);
        css(&c2, &format!("label {{ color: white; background: rgba({},{},{},0.85); border-radius: 99px; padding: 2px 7px; }}", (r * 255.0) as u8, (g * 255.0) as u8, (b * 255.0) as u8));
        meta.append(&c2);
    }
    let src = label(&format!("{} · {}", it.source_name, widgets::time_text(it)), 11.0, 500, &[]);
    src.set_wrap(false);
    src.set_opacity(0.85);
    meta.append(&src);
    if let Some(p) = widgets::paywall_mark(it) {
        meta.append(&p);
    }
    text.append(&meta);
    let title = label(it.display_title(), 15.5, 700, &[]);
    lines(&title, 2);
    text.append(&title);
    overlay.add_overlay(&text);
    if read {
        text.set_opacity(0.75);
    }
    // 사진을 받으면 사진 카드로(글자는 흰색), 못 받으면 사진 없는 글자 카드 그대로
    {
        let (o, p, s, t) = (overlay.clone(), pic.clone(), shade.clone(), text.clone());
        photo_url(it, move |u| {
            let Some(u) = u else { return };
            widgets::load_texture(&u, move |tex| {
                let Some(tex) = tex else { return };
                p.set_paintable(Some(&tex));
                p.set_visible(true);
                s.set_visible(true);
                css(&t, "box { color: white; }");
                o.set_size_request(HERO_W, HERO_H);
                widgets::fade_in(&p, crate::motion::SLOW);
            });
        });
    }
    clickable(&overlay, it, seq);
    overlay.upcast()
}

// 사진 카드: 왼쪽 사진(없으면 자리 없음), 오른쪽 제목 두 줄 + 출처·분야·시각
fn card_row(it: &NewsItem, read: bool, saved: bool, seq: &[NewsItem]) -> gtk::Widget {
    let h = gtk::Box::new(gtk::Orientation::Horizontal, 11);
    h.add_css_class("dc-card");
    h.set_margin_top(2);
    h.set_margin_bottom(2);
    css(&h, "box { padding: 8px; border-radius: 12px; }");
    let th = thumb(it, 54, 54, 10);
    th.set_valign(gtk::Align::Center);
    if read {
        th.set_opacity(0.65);
    }
    h.append(&th);
    let v = gtk::Box::new(gtk::Orientation::Vertical, 4);
    v.set_hexpand(true);
    v.set_valign(gtk::Align::Center);
    let t = label(it.display_title(), 13.0, if read { 400 } else { 600 }, if read { &["dc-secondary"] } else { &[] });
    lines(&t, 2);
    v.append(&t);
    let meta = gtk::Box::new(gtk::Orientation::Horizontal, 5);
    meta.add_css_class("dc-secondary");
    if it.is_important() {
        let s = icon("starred-symbolic", 11);
        s.add_css_class("warning");
        meta.append(&s);
    } else if let Some(w) = &it.watch {
        // 지켜볼 낱말에 걸린 소식(★ 와 겹치면 ★ 만)
        let e = icon("view-reveal-symbolic", 11);
        css(&e, "image { color: #30B0C7; }");
        e.set_tooltip_text(Some(&format!("지켜볼 낱말: {w}")));
        meta.append(&e);
    }
    let mut srcname = it.source_name.clone();
    if it.related_count() > 0 {
        srcname += &format!(" 외 {}곳", it.related_count());
    }
    let sl = label(&srcname, 10.5, 600, &[]);
    lines(&sl, 1);
    meta.append(&sl);
    if let Some(p) = widgets::paywall_mark(it) {
        meta.append(&p);
    }
    meta.append(&topic(it));
    if let Some(x) = extra_topic(it) {
        meta.append(&x);
    }
    let tl = label(&widgets::time_text(it), 10.5, 400, &["dc-tertiary"]);
    tl.set_wrap(false);
    meta.append(&tl);
    if saved {
        let b = icon("user-bookmarks-symbolic", 11);
        tint(&b, &widgets::source_color(&it.source_id));
        meta.append(&b);
    }
    v.append(&meta);
    h.append(&v);
    if !read {
        h.append(&unread_dot(it, 6));
    }
    clickable(&h, it, seq);
    h.upcast()
}

// 누르면 읽기 창, 오른쪽 클릭이면 메뉴
fn clickable(w: &impl IsA<gtk::Widget>, it: &NewsItem, seq: &[NewsItem]) {
    let w = w.as_ref().clone();
    let click = gtk::GestureClick::new();
    click.set_button(0);
    let it = it.clone();
    let seq = seq.to_vec();
    let w2 = w.clone();
    click.connect_released(move |g, _, x, y| {
        if g.current_button() == 3 {
            context_menu(&w2, &it, x, y);
        } else if g.current_button() == 1 {
            crate::app::open_item_in(&it, origin_of(&w2), seq.clone());
        }
    });
    w.add_controller(click);
    w.set_cursor_from_name(Some("pointer"));
}

// 누른 줄의 자리(창 기준) — 읽기 창이 그 자리에서 커져 나오게(R-14)
fn origin_of(w: &gtk::Widget) -> Option<crate::reader::Origin> {
    let root = w.root()?;
    let b = w.compute_bounds(&root)?;
    Some(crate::reader::Origin { x: b.x() as f64, y: b.y() as f64, w: b.width() as f64, h: b.height() as f64 })
}

// 오른쪽 클릭(U-05): 나중에 읽기 · 읽음/안 읽음 · 브라우저 · 링크 복사 + 바로 줄이기(G-11)
fn context_menu(parent: &gtk::Widget, it: &NewsItem, x: f64, y: f64) {
    let core = ui().core.clone();
    let model = gio::Menu::new();
    model.append(Some(if core.is_saved(it) { "저장 취소" } else { "나중에 읽기" }), Some("row.save"));
    model.append(Some(if core.is_read(it) { "안 읽음으로 표시" } else { "읽음으로 표시" }), Some("row.read"));
    let sec = gio::Menu::new();
    sec.append(Some("브라우저에서 열기"), Some("row.browser"));
    sec.append(Some("링크 복사"), Some("row.copy"));
    model.append_section(None, &sec);
    let group = gio::SimpleActionGroup::new();
    reduce_menu(&model, &group, it);
    let add = |name: &str, f: Box<dyn Fn()>| {
        let a = gio::SimpleAction::new(name, None);
        a.connect_activate(move |_, _| f());
        group.add_action(&a);
    };
    let i1 = it.clone();
    add("save", Box::new(move || ui().core.toggle_saved(&i1)));
    let i2 = it.clone();
    add("read", Box::new(move || {
        let c = ui().core.clone();
        let r = c.is_read(&i2);
        c.set_read(&i2, !r);
    }));
    let i3 = it.clone();
    add("browser", Box::new(move || {
        open_external(&i3.link);
    }));
    let i4 = it.clone();
    add("copy", Box::new(move || copy_text(&i4.link)));
    parent.insert_action_group("row", Some(&group));
    let pop = gtk::PopoverMenu::from_model(Some(&model));
    pop.set_parent(parent);
    pop.set_has_arrow(false);
    pop.set_pointing_to(Some(&gdk::Rectangle::new(x as i32, y as i32, 1, 1)));
    pop.connect_closed(|p| {
        let p = p.clone();
        glib::idle_add_local_once(move || p.unparent());
    });
    pop.popup();
}

// 바로 줄이기(G-11, 맥 ReduceMenu): 이 출처 숨기기 / 이 분야 덜 받기 / 이 낱말 알리지 않기.
// 다른 창(물방울 등)도 쓸 수 있게 공개한다: 이름은 "row.*" 동작으로 group 에 붙는다.
pub fn reduce_menu(model: &gio::Menu, group: &gio::SimpleActionGroup, it: &NewsItem) {
    let core = ui().core.clone();
    let sec = core.notify_section(it);
    let mode = core.policy(&sec).mode;
    let reduce = gio::Menu::new();
    reduce.append(Some(&format!("이 출처 숨기기 — {}", it.source_name)), Some("row.hide-source"));
    if core.chosen_sections().contains(&sec) && mode != NotifyMode::Magazine {
        let to = if mode == NotifyMode::Instant { "묶음으로" } else { "매거진에만" };
        reduce.append(Some(&format!("{} 덜 받기 — {to}", sections::name(&sec))), Some("row.less"));
    }
    let words = gio::Menu::new();
    for w in title_words(it) {
        words.append(Some(&w), Some(&format!("row.mute::{w}")));
    }
    reduce.append_submenu(Some("이 낱말 알리지 않기"), &words);
    model.append_section(None, &reduce);
    let src = it.source_id.clone();
    let a = gio::SimpleAction::new("hide-source", None);
    a.connect_activate(move |_, _| ui().core.hide_source(&src));
    group.add_action(&a);
    let a = gio::SimpleAction::new("less", None);
    a.connect_activate(move |_, _| ui().core.less_of(&sec));
    group.add_action(&a);
    let a = gio::SimpleAction::new("mute", Some(glib::VariantTy::STRING));
    a.connect_activate(move |_, v| {
        if let Some(w) = v.and_then(|v| v.str().map(|s| s.to_string())) {
            ui().core.mute_word(&w);
        }
    });
    group.add_action(&a);
}

// 기호 아이콘에 색(분야 색 등)
fn tint(w: &impl IsA<gtk::Widget>, hex: &str) {
    let (r, g, b) = dropcap_core::models::hex_rgb(hex);
    css(w, &format!("image {{ color: rgb({},{},{}); }}", (r * 255.0) as u8, (g * 255.0) as u8, (b * 255.0) as u8));
}

// MARK: 자리 잡기: X11 이면 트레이 아이콘 근처(없으면 화면 오른쪽 위). Wayland 는 앱이 정할 수 없음.
#[cfg(feature = "x11")]
fn place(w: &gtk::Window, at: Option<(i32, i32)>) {
    if !crate::hotkeys::is_x11_session() || w.is_decorated() {
        return;
    }
    let title = w.title().map(|t| t.to_string()).unwrap_or_default();
    // 창이 실제로 그려진 뒤에 옮긴다
    widgets::later(60, move || {
        if let Err(e) = x11_move(&title, at) {
            log::debug!("[상단바 창] 자리 잡기 실패: {e}");
        }
    });
}

#[cfg(feature = "x11")]
fn x11_move(title: &str, at: Option<(i32, i32)>) -> Result<(), Box<dyn std::error::Error>> {
    use x11rb::connection::Connection;
    use x11rb::protocol::xproto::{AtomEnum, ConfigureWindowAux, ConnectionExt};
    let (conn, screen) = x11rb::connect(None)?;
    let s = &conn.setup().roots[screen];
    let root = s.root;
    let (sw, sh) = (s.width_in_pixels as i32, s.height_in_pixels as i32);
    let atom = |n: &str| -> Result<u32, Box<dyn std::error::Error>> { Ok(conn.intern_atom(false, n.as_bytes())?.reply()?.atom) };
    let list = atom("_NET_CLIENT_LIST")?;
    let pid_a = atom("_NET_WM_PID")?;
    let name_a = atom("_NET_WM_NAME")?;
    let utf8 = atom("UTF8_STRING")?;
    let clients = conn.get_property(false, root, list, AtomEnum::WINDOW, 0, 4096)?.reply()?;
    let me = std::process::id();
    for win in clients.value32().into_iter().flatten() {
        let pid = conn.get_property(false, win, pid_a, AtomEnum::CARDINAL, 0, 1)?.reply()?.value32().and_then(|mut v| v.next());
        if pid != Some(me) {
            continue;
        }
        let name = conn.get_property(false, win, name_a, utf8, 0, 1024)?.reply()?;
        if String::from_utf8_lossy(&name.value) != title {
            continue;
        }
        let g = conn.get_geometry(win)?.reply()?;
        let (w, h) = (g.width as i32, g.height as i32);
        let (x, y) = match at {
            Some((x, y)) if x > 0 || y > 0 => {
                let nx = (x - w / 2).clamp(8, (sw - w - 8).max(8));
                // 아이콘이 화면 아래쪽(아래 패널)이면 위로 펼친다
                let ny = if y > sh / 2 { (y - h - 12).max(8) } else { y + 12 };
                (nx, ny)
            }
            _ => (sw - w - 12, 36),
        };
        conn.configure_window(win, &ConfigureWindowAux::new().x(x).y(y))?;
        conn.flush()?;
        break;
    }
    Ok(())
}

#[cfg(not(feature = "x11"))]
fn place(_w: &gtk::Window, _at: Option<(i32, i32)>) {}

// 아이콘 테마마다 이름이 달라 있는 것을 고른다(거르기: KDE view-filter, GNOME 에는 없음)
pub fn pick_icon(cands: &[&'static str]) -> &'static str {
    let Some(d) = gtk::gdk::Display::default() else { return cands[0] };
    let theme = gtk::IconTheme::for_display(&d);
    cands.iter().find(|n| theme.has_icon(n)).copied().unwrap_or(cands[cands.len() - 1])
}

pub fn filter_icon() -> &'static str {
    pick_icon(&["view-filter-symbolic", "funnel-symbolic", "view-list-symbolic"])
}
