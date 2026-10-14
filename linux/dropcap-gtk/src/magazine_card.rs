// 매거진 카드와 작은 부품(맥 MagazineView.StoryCard · SectionViews 의 SectionChipBar·ReduceMenu·RegionSplit).
use crate::app::{open_external, open_from_magazine, ui};
use crate::magazine::tint;
use crate::reader::Origin;
use crate::widgets::{self, label, lines, RemoteImage};
use dropcap_core::article::image_key;
use dropcap_core::category::NewsCategory;
use dropcap_core::models::{ItemKind, NewsItem};
use dropcap_core::notify_policy::NotifyMode;
use dropcap_core::sections;
use adw::prelude::*;
use gtk::{gio, glib};
use std::cell::{Cell, RefCell};
use std::rc::Rc;

// 사진이 있고 잡그림이 아니면(없으면 사진 자리를 만들지 않음 — 지어낸 그림은 쓰지 않음)
pub fn has_photo(it: &NewsItem) -> bool {
    it.image.is_some() && !image_key::is_junk(it.image.as_deref())
}

pub fn origin_of(w: &impl IsA<gtk::Widget>) -> Option<Origin> {
    let w = w.as_ref();
    let root = w.root()?;
    let b = w.compute_bounds(&root)?;
    Some(Origin { x: b.x() as f64, y: b.y() as f64, w: b.width() as f64, h: b.height() as f64 })
}

// 카드에서 연 기사(읽음·관심사 기록 → 읽기 창이 그 자리에서)
pub fn open_card(item: &NewsItem, w: &impl IsA<gtk::Widget>) {
    open_from_magazine(item, origin_of(w));
}

// MARK: 바로 줄이기(G-11) — 카드·목록 줄의 오른쪽 클릭 메뉴 뒤쪽
pub fn reduce_menu(item: &NewsItem, group: &gio::SimpleActionGroup) -> gio::Menu {
    let core = ui().core.clone();
    let menu = gio::Menu::new();
    let sec = core.notify_section(item);
    let mode = core.policy(&sec).mode;
    {
        let id = item.source_id.clone();
        let c = core.clone();
        let a = gio::SimpleAction::new("hide", None);
        a.connect_activate(move |_, _| c.hide_source(&id));
        group.add_action(&a);
        menu.append(Some(&format!("이 출처 숨기기 — {}", item.source_name)), Some("card.hide"));
    }
    if core.chosen_sections().contains(&sec) && mode != NotifyMode::Magazine {
        let c = core.clone();
        let s = sec.clone();
        let a = gio::SimpleAction::new("less", None);
        a.connect_activate(move |_, _| c.less_of(&s));
        group.add_action(&a);
        let to = if mode == NotifyMode::Instant { "묶음으로" } else { "매거진에만" };
        menu.append(Some(&format!("{} 덜 받기 — {to}", sections::name(&sec))), Some("card.less"));
    }
    let words = dropcap_core::app_model::title_words(item);
    if !words.is_empty() {
        let sub = gio::Menu::new();
        let a = gio::SimpleAction::new("mute", Some(glib::VariantTy::STRING));
        let c = core.clone();
        a.connect_activate(move |_, v| {
            if let Some(w) = v.and_then(|v| v.str().map(|s| s.to_string())) {
                c.mute_word(&w);
            }
        });
        group.add_action(&a);
        for w in words {
            let mi = gio::MenuItem::new(Some(&w), None);
            mi.set_action_and_target_value(Some("card.mute"), Some(&w.to_variant()));
            sub.append_item(&mi);
        }
        menu.append_submenu(Some("이 낱말 알리지 않기"), &sub);
    }
    menu
}

// 카드 오른쪽 클릭: 나중에 읽기 · 여러 시각 보기 · 브라우저 · 바로 줄이기
pub fn attach_context(w: &impl IsA<gtk::Widget>, item: &NewsItem, cluster: Option<String>, on_story: Option<Rc<dyn Fn(String)>>) {
    let w = w.as_ref().clone();
    let item = item.clone();
    let click = gtk::GestureClick::new();
    click.set_button(3);
    click.connect_pressed(move |g, _, x, y| {
        let core = ui().core.clone();
        let group = gio::SimpleActionGroup::new();
        let menu = gio::Menu::new();
        let top = gio::Menu::new();
        {
            let it = item.clone();
            let c = core.clone();
            let a = gio::SimpleAction::new("save", None);
            a.connect_activate(move |_, _| c.toggle_saved(&it));
            group.add_action(&a);
            top.append(Some(if core.is_saved(&item) { "저장 취소" } else { "나중에 읽기" }), Some("card.save"));
        }
        if let (Some(c), Some(f)) = (cluster.clone(), on_story.clone()) {
            let a = gio::SimpleAction::new("story", None);
            a.connect_activate(move |_, _| f(c.clone()));
            group.add_action(&a);
            top.append(Some("여러 시각 보기"), Some("card.story"));
        }
        {
            let link = item.link.clone();
            let a = gio::SimpleAction::new("browser", None);
            a.connect_activate(move |_, _| {
                open_external(&link);
            });
            group.add_action(&a);
            top.append(Some("브라우저에서 열기"), Some("card.browser"));
        }
        menu.append_section(None, &top);
        menu.append_section(None, &reduce_menu(&item, &group));
        let target = g.widget().unwrap();
        target.insert_action_group("card", Some(&group));
        let pop = gtk::PopoverMenu::from_model(Some(&menu));
        pop.set_parent(&target);
        pop.set_has_arrow(false);
        pop.set_pointing_to(Some(&gtk::gdk::Rectangle::new(x as i32, y as i32, 1, 1)));
        pop.connect_closed(|p| {
            let p = p.clone();
            glib::idle_add_local_once(move || p.unparent());
        });
        pop.popup();
    });
    w.add_controller(click);
}

// MARK: 해외·국내 나란히(G-12)
fn unique_names(list: &[NewsItem], n: usize) -> Vec<String> {
    let mut out: Vec<String> = vec![];
    for it in list {
        if !out.contains(&it.source_name) {
            out.push(it.source_name.clone());
        }
    }
    out.truncate(n);
    out
}

// 카드 안의 두 줄(출처 이름 3곳까지). 해외·국내가 섞였을 때만
pub fn region_lines(items: &[NewsItem]) -> Option<gtk::Box> {
    let (intl, kr) = dropcap_core::magazine::split_by_region(items, &sections::META);
    if intl.is_empty() || kr.is_empty() {
        return None;
    }
    let b = gtk::Box::new(gtk::Orientation::Vertical, 3);
    for (t, list) in [("해외에서는", &intl), ("국내에서는", &kr)] {
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 5);
        row.append(&label(t, 10.5, 700, &["dc-secondary"]));
        let names = label(&unique_names(list, 3).join(" · "), 10.5, 400, &["dc-tertiary"]);
        names.set_wrap(false);
        names.set_ellipsize(gtk::pango::EllipsizeMode::End);
        row.append(&names);
        b.append(&row);
    }
    Some(b)
}

// 스토리 상세의 두 칸('해외에서는 N곳 / 국내에서는 N곳')
pub fn region_columns(items: &[NewsItem]) -> Option<gtk::Box> {
    let (intl, kr) = dropcap_core::magazine::split_by_region(items, &sections::META);
    if intl.is_empty() || kr.is_empty() {
        return None;
    }
    let b = gtk::Box::new(gtk::Orientation::Horizontal, 14);
    b.set_homogeneous(true);
    b.set_margin_bottom(26);
    for (t, icon, list) in [("해외에서는", "web-browser-symbolic", &intl), ("국내에서는", "go-home-symbolic", &kr)] {
        let col = gtk::Box::new(gtk::Orientation::Vertical, 8);
        col.add_css_class("dc-soft");
        let inner = gtk::Box::new(gtk::Orientation::Vertical, 8);
        inner.set_margin_top(14);
        inner.set_margin_bottom(14);
        inner.set_margin_start(14);
        inner.set_margin_end(14);
        let head = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        head.append(&widgets::icon(icon, 14));
        head.append(&label(&format!("{t} {}곳", list.len()), 12.5, 700, &["dc-secondary"]));
        inner.append(&head);
        for it in list.iter() {
            let bt = gtk::Button::new();
            bt.add_css_class("flat");
            let v = gtk::Box::new(gtk::Orientation::Vertical, 2);
            let s = label(&it.source_name, 11.0, 600, &[]);
            tint(&s, &widgets::source_color(&it.source_id));
            v.append(&s);
            v.append(lines(&label(it.display_title(), 13.0, 400, &[]), 3));
            if it.title_ko.is_some() && it.title_ko.as_deref() != Some(it.title.as_str()) {
                v.append(lines(&label(&it.title, 11.0, 400, &["dc-tertiary"]), 1));
            }
            bt.set_child(Some(&v));
            let item = it.clone();
            bt.connect_clicked(move |b| open_card(&item, b));
            inner.append(&bt);
        }
        col.append(&inner);
        b.append(&col);
    }
    Some(b)
}

// MARK: 분야 칩 줄(G-09) — '전체' + 지면이 있는 분야(건수). AI 를 고르면 하위 칩 한 줄 더
pub struct ChipBar {
    pub root: gtk::Box,
}

pub fn chip_button(text: &str, icon: &str, color: &str, on: bool, count: Option<usize>, small: bool) -> gtk::Button {
    let b = gtk::Button::new();
    b.add_css_class("flat");
    b.add_css_class("dc-secchip");
    let h = gtk::Box::new(gtk::Orientation::Horizontal, 4);
    h.append(&widgets::icon(icon, if small { 10 } else { 12 }));
    let t = label(text, if small { 11.0 } else { 12.5 }, if on { 600 } else { 500 }, &[]);
    t.set_wrap(false);
    h.append(&t);
    if let Some(n) = count.filter(|n| *n > 0) {
        let c = label(&n.to_string(), 10.5, 600, &["dc-secondary"]);
        c.set_wrap(false);
        h.append(&c);
    }
    b.set_child(Some(&h));
    let (r, g, bl) = dropcap_core::models::hex_rgb(color);
    let (r, g, bl) = ((r * 255.0) as u8, (g * 255.0) as u8, (bl * 255.0) as u8);
    let css = if on {
        format!("button {{ background-color: rgb({r},{g},{bl}); color: white; }}")
    } else {
        format!("button {{ background-color: rgba({r},{g},{bl},0.11); color: rgb({r},{g},{bl}); }} button:hover {{ background-color: rgba({r},{g},{bl},0.18); }}")
    };
    let prov = gtk::CssProvider::new();
    prov.load_from_string(&css);
    #[allow(deprecated)]
    b.style_context().add_provider(&prov, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION);
    b
}

impl ChipBar {
    // focus: 고른 분야, sub: AI 하위 분류. on_change(분야, 하위) 로 알린다.
    pub fn new(
        sections_: &[String],
        counts: &std::collections::HashMap<String, usize>,
        focus: Option<String>,
        sub: Option<NewsCategory>,
        on_change: Rc<dyn Fn(Option<String>, Option<NewsCategory>)>,
    ) -> ChipBar {
        let root = gtk::Box::new(gtk::Orientation::Vertical, 6);
        let scroll = gtk::ScrolledWindow::builder().vscrollbar_policy(gtk::PolicyType::Never).hscrollbar_policy(gtk::PolicyType::Automatic).build();
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 5);
        let accent = if crate::theme::is_dark() { "#0A84FF" } else { "#007AFF" };
        let all = chip_button("전체", "view-grid-symbolic", accent, focus.is_none(), None, false);
        {
            let f = on_change.clone();
            all.connect_clicked(move |_| f(None, None));
        }
        row.append(&all);
        for id in sections_ {
            let s = sections::by_id(id);
            let on = focus.as_deref() == Some(id.as_str());
            let b = chip_button(&sections::name(id), s.map(|s| s.icon()).unwrap_or("view-app-grid-symbolic"), s.map(|s| s.color.as_str()).unwrap_or("#8E8E93"), on, counts.get(id).cloned(), false);
            let f = on_change.clone();
            let id2 = id.clone();
            b.connect_clicked(move |_| f(if on { None } else { Some(id2.clone()) }, None));
            row.append(&b);
        }
        scroll.set_child(Some(&row));
        root.append(&scroll);
        if focus.as_deref() == Some(sections::AI) {
            let subrow = gtk::Box::new(gtk::Orientation::Horizontal, 4);
            for c in NewsCategory::all().into_iter().filter(|c| !c.is_other()) {
                let on = sub == Some(c);
                let b = chip_button(c.label(), c.icon(), c.color(crate::theme::is_dark()), on, None, true);
                let f = on_change.clone();
                b.connect_clicked(move |_| f(Some(sections::AI.into()), if on { None } else { Some(c) }));
                subrow.append(&b);
            }
            root.append(&subrow);
            widgets::fade_in(&subrow, 180);
        }
        ChipBar { root }
    }
}

// MARK: 기사 카드(M-08)
pub struct StoryCard;

impl StoryCard {
    // order: 지면 안 순서(차례로 깔리는 지연), story_items: 해외·국내가 섞인 스토리 보도
    // seq: 이 카드가 놓인 지면의 기사 순서(읽기 창 J/K 로 다음·이전, H-05)
    pub fn build(item: &NewsItem, order: usize, cluster: Option<String>, story_items: &[NewsItem], on_story: Option<Rc<dyn Fn(String)>>, seq: &[NewsItem]) -> gtk::Widget {
        let core = ui().core.clone();
        let button = gtk::Button::new();
        button.add_css_class("flat");
        button.add_css_class("dc-magcard");
        button.set_overflow(gtk::Overflow::Hidden);
        let v = gtk::Box::new(gtk::Orientation::Vertical, 0);
        if has_photo(item) {
            let ov = gtk::Overlay::new();
            ov.set_overflow(gtk::Overflow::Hidden);
            ov.set_vexpand(false); // 사진 칸은 150 으로 고정(같은 줄의 카드 높이에 따라 늘지 않게)
            ov.set_valign(gtk::Align::Start);
            let img = RemoteImage::new(item.image.as_deref(), item.category(), &widgets::source_color(&item.source_id), 300, 150);
            img.root.set_size_request(-1, 150);
            img.root.set_vexpand(false);
            img.root.add_css_class("dc-magphoto");
            ov.set_child(Some(&img.root));
            if matches!(item.item_kind(), ItemKind::Video | ItemKind::Podcast) {
                let p = widgets::icon(if item.item_kind() == ItemKind::Video { "media-playback-start-symbolic" } else { "audio-x-generic-symbolic" }, 18);
                p.add_css_class("dc-play");
                p.set_halign(gtk::Align::Center);
                p.set_valign(gtk::Align::Center);
                ov.add_overlay(&p);
            }
            if item.item_kind() != ItemKind::Article {
                let k = label(item.item_kind().label(), 10.5, 600, &["dc-kind"]);
                k.set_halign(gtk::Align::Start);
                k.set_valign(gtk::Align::Start);
                k.set_margin_top(8);
                k.set_margin_start(8);
                ov.add_overlay(&k);
            }
            // 마우스를 따라 사진이 살짝 움직이는 시차 효과
            let prov = gtk::CssProvider::new();
            #[allow(deprecated)]
            img.root.style_context().add_provider(&prov, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
            let motion = gtk::EventControllerMotion::new();
            let p2 = prov.clone();
            let w = button.clone();
            motion.connect_motion(move |_, x, y| {
                if !crate::motion::enabled() {
                    return;
                }
                let tx = (x / (w.width().max(1) as f64) - 0.5) * 8.0;
                let ty = (y / 220.0 - 0.5) * 6.0;
                p2.load_from_string(&format!(".dc-magphoto {{ transform: translate({tx:.1}px, {ty:.1}px) scale(1.08); }}"));
            });
            let p3 = prov.clone();
            motion.connect_leave(move |_| p3.load_from_string(""));
            button.add_controller(motion);
            v.append(&ov);
        }
        let body = gtk::Box::new(gtk::Orientation::Vertical, 7);
        body.set_margin_top(14);
        body.set_margin_bottom(14);
        body.set_margin_start(14);
        body.set_margin_end(14);
        let meta = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        if item.is_important() {
            let s = widgets::icon("starred-symbolic", 10);
            tint(&s, "#FF9500");
            meta.append(&s);
        }
        meta.append(&label(&item.source_name, 11.5, 600, &[]));
        if let Some(p) = widgets::paywall_mark(item) {
            meta.append(&p);
        }
        if item.related_count() > 0 {
            meta.append(&label(&format!("외 {}곳", item.related_count()), 11.0, 400, &["dc-secondary"]));
        }
        if !has_photo(item) && item.item_kind() != ItemKind::Article {
            meta.append(&label(item.item_kind().label(), 10.5, 600, &["dc-kind"]));
        }
        let sp = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        sp.set_hexpand(true);
        meta.append(&sp);
        meta.append(&label(&widgets::time_text(item), 11.0, 400, &["dc-tertiary"]));
        body.append(&meta);
        let title = label(item.display_title(), 15.0, 600, &["dc-title"]);
        lines(&title, 3);
        body.append(&title);
        if !story_items.is_empty() {
            if let Some(r) = region_lines(story_items) {
                body.append(&r);
            }
        }
        if core.is_read(item) {
            let r = gtk::Box::new(gtk::Orientation::Horizontal, 4);
            r.append(&widgets::icon("object-select-symbolic", 10));
            r.append(&label("읽음", 10.5, 400, &[]));
            r.add_css_class("dc-tertiary");
            body.append(&r);
        }
        v.append(&body);
        button.set_child(Some(&v));
        {
            let it = item.clone();
            let seq = seq.to_vec();
            button.connect_clicked(move |b| crate::app::open_from_magazine_in(&it, origin_of(b), seq.clone()));
        }
        attach_context(&button, item, cluster, on_story);
        // 지면이 차례로 깔림: 카드마다 0.05초, 최대 0.4초(M-09)
        stagger(&button, order);
        button.upcast()
    }
}

thread_local! {
    static STAGGER_GEN: Cell<u64> = const { Cell::new(0) };
}

// 차례로 깔림: 처음엔 투명했다가 순서대로 떠오름(움직임 줄이기면 바로)
pub fn stagger(w: &impl IsA<gtk::Widget>, order: usize) {
    let w = w.as_ref().clone();
    if !crate::motion::enabled() {
        return;
    }
    w.set_opacity(0.0);
    let delay = (order as u64 * 50).min(400);
    widgets::later(delay, move || widgets::fade_in(&w, 450));
}

// 스크롤할 때 들어오며 또렷해짐(M-09): 보이는 칸 밖의 카드는 옅게, 들어오면 또렷하게
pub fn scroll_focus(scroll: &gtk::ScrolledWindow, cards: Rc<RefCell<Vec<gtk::Widget>>>) {
    let adj = scroll.vadjustment();
    let s = scroll.clone();
    let busy = Rc::new(Cell::new(false));
    adj.connect_value_changed(move |_| {
        if busy.replace(true) || !crate::motion::enabled() {
            busy.set(false);
            return;
        }
        let height = s.height() as f32;
        for c in cards.borrow().iter() {
            let Some(b) = c.compute_bounds(&s) else { continue };
            let visible = b.y() + b.height() > -20.0 && b.y() < height + 20.0;
            let inside = b.y() >= -10.0 && b.y() + b.height() <= height + 10.0;
            if visible && c.opacity() > 0.0 {
                c.set_opacity(if inside { 1.0 } else { 0.55 });
            }
        }
        busy.set(false);
    });
}
