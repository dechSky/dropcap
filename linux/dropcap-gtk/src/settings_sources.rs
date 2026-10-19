// 설정 › 구독(P-06, K-02~K-04, 맥 SettingsView.sources): 채널 추가 · 출처 찾기(찾기 칸·보기·상태·요약·수) ·
// 내 채널 · 기본 출처(매체별/분야별/지역별 묶음, 묶음 켜기/끄기는 보이는 것에만) · 추천 채널(접힘) · OPML.
// 규칙은 dropcap_core::source_directory(시험: dropcap-core/tests/source_directory_tests.rs). 보이는 목록이 달라질 때만 줄을 다시 만든다.
use crate::app::{bg, ui};
use crate::settings::{caption, tag};
use crate::theme;
use crate::widgets::{chip, icon, label};
use adw::prelude::*;
use dropcap_core::app_model::UiEvent;
use dropcap_core::channels::{self, CATALOG};
use dropcap_core::models::{resources, ItemKind, Source};
use dropcap_core::paywall::PaywallKind;
use dropcap_core::sections;
use dropcap_core::source_directory::{self as sd, Layout, Status};
use gtk::glib;
use std::cell::{Cell, RefCell};
use std::collections::HashSet;
use std::rc::Rc;

// 보이는 목록의 꼴: 이것이 같으면 줄은 그대로 두고 값(스위치·켠 수)만 고친다
#[derive(PartialEq)]
struct Shape {
    layout: Layout,
    searching: bool,
    mine_shown: bool,
    no_custom: bool,
    mine: Vec<String>,
    groups: Vec<(String, Vec<String>)>,
    catalog: Vec<String>,
    open: Vec<String>, // 펼친 묶음(펼침·접힘도 줄을 다시 만든다)
}

struct View {
    query: RefCell<String>,
    status: Cell<Status>,
    layout: Cell<Layout>,
    expanded: RefCell<HashSet<String>>,            // 찾지 않을 때 펼친 묶음
    collapsed_searching: RefCell<HashSet<String>>, // 찾는 중에 사용자가 접은 묶음
    shape: RefCell<Option<Shape>>,
    summary: adw::ActionRow,
    count: gtk::Label,
    empty: gtk::Label,
    status_buttons: Vec<(Status, gtk::ToggleButton)>,
    mine_group: adw::PreferencesGroup,
    base_group: adw::PreferencesGroup,
    catalog_group: adw::PreferencesGroup,
    rows: RefCell<Vec<(adw::PreferencesGroup, gtk::Widget)>>,
    heads: RefCell<Vec<(String, gtk::Label, gtk::Button)>>, // 묶음 줄: 'N/M 켬'·모두 켜기/끄기
    updaters: RefCell<Vec<Box<dyn Fn()>>>,
    err: gtk::Label,
}

// 고르기 단추 한 벌(맥 segmented Picker): linked ToggleButton
fn segmented<T: Copy + PartialEq + 'static>(items: &[(T, &str)], current: T, on: impl Fn(T) + 'static) -> (gtk::Box, Vec<(T, gtk::ToggleButton)>) {
    let b = gtk::Box::builder().css_classes(["linked"]).valign(gtk::Align::Center).build();
    let on = Rc::new(on);
    let mut buttons: Vec<(T, gtk::ToggleButton)> = vec![];
    for (v, text) in items {
        let t = gtk::ToggleButton::builder().label(*text).active(*v == current).build();
        if let Some((_, first)) = buttons.first() {
            t.set_group(Some(first));
        }
        let (v, on) = (*v, on.clone());
        t.connect_toggled(move |t| {
            if t.is_active() {
                on(v)
            }
        });
        b.append(&t);
        buttons.push((v, t));
    }
    (b, buttons)
}

pub fn page() -> adw::PreferencesPage {
    let page = adw::PreferencesPage::builder().title("구독").icon_name("network-transmit-receive-symbolic").name("sources").build();

    // 1. 채널 추가(그대로)
    let g = adw::PreferencesGroup::builder().title("채널 추가").build();
    let entry = adw::EntryRow::builder().title("사이트·뉴스레터·YouTube·GitHub·Reddit 주소").build();
    let add = gtk::Button::builder().label("구독").valign(gtk::Align::Center).css_classes(["suggested-action"]).build();
    entry.add_suffix(&add);
    g.add(&entry);
    let err = label("", 12.0, 400, &["error"]);
    err.set_visible(false);
    err.set_margin_top(6);
    g.add(&err);
    g.add(&caption("웹사이트·뉴스레터(Substack·Medium)·YouTube(youtube.com/@채널)·GitHub 릴리스(github.com/소유자/저장소)·Reddit(r/이름)·arXiv·팟캐스트 주소를 넣으면 알맞은 피드를 찾아 구독합니다."));
    page.add(&g);
    let do_add = {
        let entry = entry.clone();
        let add = add.clone();
        let err = err.clone();
        Rc::new(move || {
            let text = entry.text().to_string();
            if text.trim().is_empty() {
                return;
            }
            add.set_sensitive(false);
            add.set_label("찾는 중…");
            err.set_visible(false);
            let core = ui().core.clone();
            let (entry, add, err) = (entry.clone(), add.clone(), err.clone());
            bg(core.add_channel(text, String::new()), move |r| {
                add.set_sensitive(true);
                add.set_label("구독");
                match r {
                    Some(e) => {
                        err.set_text(&e);
                        err.set_visible(true);
                    }
                    None => entry.set_text(""),
                }
            });
        })
    };
    {
        let f = do_add.clone();
        add.connect_clicked(move |_| f());
        let f = do_add.clone();
        entry.connect_entry_activated(move |_| f());
    }

    // 2. 출처 찾기: 찾기 칸 · 보기 · 상태 · 요약(누르면 '켠 것') · 걸린 수 · 결과 없음 안내
    let g = adw::PreferencesGroup::builder().title("출처 찾기").build();
    let find = adw::EntryRow::builder().title("출처 찾기 — 이름·주소·분야·국내/해외").build();
    find.add_prefix(&icon("system-search-symbolic", 16));
    let clear = gtk::Button::builder().icon_name("edit-clear-symbolic").css_classes(["flat"]).valign(gtk::Align::Center).tooltip_text("찾기 지우기").visible(false).build();
    find.add_suffix(&clear);
    g.add(&find);
    let layout_now = Layout::from_raw(&ui().prefs.borrow().source_layout);
    let view_slot: Rc<RefCell<Option<Rc<View>>>> = Rc::new(RefCell::new(None));
    let (layout_box, _) = {
        let slot = view_slot.clone();
        segmented(&Layout::ALL.map(|l| (l, l.label())), layout_now, move |l| {
            ui().update_prefs(|p| p.source_layout = l.raw().into());
            if let Some(v) = slot.borrow().clone() {
                v.layout.set(l);
                refresh(&v);
            }
        })
    };
    let r = adw::ActionRow::builder().title("보기").build();
    r.add_suffix(&layout_box);
    g.add(&r);
    let (status_box, status_buttons) = {
        let slot = view_slot.clone();
        segmented(&Status::ALL.map(|s| (s, s.label())), Status::All, move |s| {
            if let Some(v) = slot.borrow().clone() {
                v.status.set(s);
                refresh(&v);
            }
        })
    };
    let r = adw::ActionRow::builder().title("상태").build();
    r.add_suffix(&status_box);
    g.add(&r);
    let summary = adw::ActionRow::builder().activatable(true).use_markup(false).tooltip_text("켠 것만 보기 / 다시 누르면 전체").build();
    let count = tag("", 12.0, 400, &["dc-secondary", "numeric"]);
    summary.add_suffix(&count);
    g.add(&summary);
    let empty = caption("찾는 출처가 없습니다. 이름·주소를 다시 확인하거나 위 '채널 추가'에 주소를 넣어 보세요.");
    empty.set_visible(false);
    g.add(&empty);
    page.add(&g);

    // 3~5. 내 채널 · 기본 출처 · 추천 채널(줄은 refresh 가 채움)
    let mine_group = adw::PreferencesGroup::new();
    let base_group = adw::PreferencesGroup::builder().title("기본 출처").build();
    let catalog_group = adw::PreferencesGroup::new();
    page.add(&mine_group);
    page.add(&base_group);
    page.add(&catalog_group);
    // 6. OPML 가져오기·내보내기(맨 아래)
    page.add(&crate::settings_tools::opml_group());

    let v = Rc::new(View {
        query: RefCell::new(String::new()),
        status: Cell::new(Status::All),
        layout: Cell::new(layout_now),
        expanded: RefCell::new(HashSet::new()),
        collapsed_searching: RefCell::new(HashSet::new()),
        shape: RefCell::new(None),
        summary,
        count,
        empty,
        status_buttons,
        mine_group,
        base_group,
        catalog_group,
        rows: RefCell::new(vec![]),
        heads: RefCell::new(vec![]),
        updaters: RefCell::new(vec![]),
        err,
    });
    *view_slot.borrow_mut() = Some(v.clone());
    {
        let (v, clear) = (v.clone(), clear.clone());
        find.connect_changed(move |e| {
            let q = e.text().to_string();
            clear.set_visible(!q.is_empty());
            if sd::fold(&q).is_empty() {
                v.collapsed_searching.borrow_mut().clear(); // 찾기를 끝내면 다음 찾기는 다시 모두 펼침
            }
            *v.query.borrow_mut() = q;
            refresh(&v);
        });
    }
    {
        let find = find.clone();
        clear.connect_clicked(move |_| find.set_text(""));
    }
    {
        let v = v.clone();
        v.summary.clone().connect_activated(move |_| {
            // 켠 것 ↔ 전체
            let to = if v.status.get() == Status::On { Status::All } else { Status::On };
            if let Some((_, b)) = v.status_buttons.iter().find(|(s, _)| *s == to) {
                b.set_active(true); // toggled → status → refresh
            }
        });
    }
    refresh(&v);
    {
        let v = v.clone();
        ui().listen(move |e| {
            if matches!(e, UiEvent::State) {
                refresh(&v);
            }
        });
    }
    page
}

fn refresh(v: &Rc<View>) {
    let st = ui().core.state();
    let enabled = |id: &str| st.enabled.get(id) == Some(&true);
    let all = &resources::CONFIG.sources;
    let query = v.query.borrow().clone();
    let status = v.status.get();
    let layout = v.layout.get();
    let searching = !sd::fold(&query).is_empty();
    let shown = sd::filter(all, &query, status, enabled);
    let mine = sd::sorted(&sd::filter(&st.custom_sources, &query, status, enabled));
    let catalog: Vec<&Source> = CATALOG.iter().filter(|s| sd::matches(s, &query)).collect();
    let groups = sd::groups(all, &shown, layout, enabled);

    // 늘 고치는 값: 요약·수·안내·묶음 제목
    let everything: Vec<Source> = all.iter().chain(st.custom_sources.iter()).cloned().collect();
    v.summary.set_title(&sd::summary_text(&everything, enabled));
    v.count.set_text(&sd::count_text(shown.len() + mine.len(), all.len() + st.custom_sources.len()));
    v.empty.set_visible(shown.is_empty() && mine.is_empty() && catalog.is_empty());
    v.mine_group.set_title(&format!("내 채널 {}", st.custom_sources.len()));
    v.catalog_group.set_visible(!catalog.is_empty());

    let shape = Shape {
        layout,
        searching,
        mine_shown: !mine.is_empty() || (!searching && status == Status::All),
        no_custom: st.custom_sources.is_empty(),
        mine: mine.iter().map(|s| s.id.clone()).collect(),
        groups: groups.iter().map(|g| (g.id.clone(), g.sources.iter().map(|s| s.id.clone()).collect())).collect(),
        catalog: catalog.iter().map(|s| s.id.clone()).collect(),
        open: groups.iter().map(|g| g.id.clone()).chain(["catalog".to_string()]).filter(|id| is_open(v, id, searching)).collect(),
    };
    if v.shape.borrow().as_ref() != Some(&shape) {
        rebuild(v, &shape, &mine, &groups, &catalog);
        *v.shape.borrow_mut() = Some(shape);
    }
    for u in v.updaters.borrow().iter() {
        u();
    }
    for (id, count, btn) in v.heads.borrow().iter() {
        if let Some(g) = groups.iter().find(|g| &g.id == id) {
            count.set_text(&format!("{}/{} 켬", g.on, g.total));
            let all_on = g.sources.iter().all(|s| enabled(&s.id));
            btn.set_label(if all_on { "모두 끄기" } else { "모두 켜기" });
        }
    }
}

fn rebuild(v: &Rc<View>, shape: &Shape, mine: &[Source], groups: &[sd::Group], catalog: &[&Source]) {
    for (g, r) in v.rows.borrow_mut().drain(..) {
        g.remove(&r);
    }
    v.heads.borrow_mut().clear();
    v.updaters.borrow_mut().clear();
    let mut rows: Vec<(adw::PreferencesGroup, gtk::Widget)> = vec![];

    // 내 채널(직접 추가한 것, 찾기·거르개 적용, 해지 단추)
    v.mine_group.set_visible(shape.mine_shown);
    if shape.mine_shown && shape.no_custom {
        let r = adw::ActionRow::builder().title("아래 추천 채널을 골라 보세요.").css_classes(["dim-label"]).build();
        rows.push((v.mine_group.clone(), r.upcast()));
    }
    for s in mine {
        rows.push((v.mine_group.clone(), source_row(s, true, None, false, v).upcast()));
    }

    // 기본 출처: 고른 보기의 묶음. 묶음 줄과 하위 줄을 따로 만들어 모든 줄이 같은 열(col)을 쓴다
    v.base_group.set_visible(!groups.is_empty());
    let layout = shape.layout;
    for g in groups {
        if layout == Layout::Media && g.total == 1 {
            if let Some(s) = g.sources.first() {
                rows.push((v.base_group.clone(), source_row(s, false, None, false, v).upcast()));
            }
            continue;
        }
        let ids: Vec<String> = g.sources.iter().map(|s| s.id.clone()).collect();
        let btn = gtk::Button::builder().label("모두 켜기").css_classes(["flat"]).valign(gtk::Align::Center).build();
        btn.set_tooltip_text(Some(&if g.sources.len() < g.total { format!("보이는 {}곳에만", g.sources.len()) } else { format!("이 묶음 {}곳 모두", g.total) }));
        btn.connect_clicked(move |_| {
            let core = ui().core.clone();
            let st = core.state();
            let all_on = ids.iter().all(|id| st.enabled.get(id) == Some(&true));
            core.set_enabled_many(&ids, !all_on); // 거른 것에만, 저장·확인은 한 번
        });
        let (head, count) = head_row(v, &g.id, &g.title, &format!("{}/{} 켬", g.on, g.total), group_mark(g, layout), shape.searching, Some(btn.clone().upcast()));
        v.heads.borrow_mut().push((g.id.clone(), count, btn));
        rows.push((v.base_group.clone(), head.upcast()));
        if is_open(v, &g.id, shape.searching) {
            let media = (layout == Layout::Media).then_some(g.title.as_str());
            for s in &g.sources {
                rows.push((v.base_group.clone(), source_row(s, false, media, true, v).upcast()));
            }
        }
    }

    // 추천 채널: 맨 아래 접힌 묶음(찾기 적용, 걸리면 펼침)
    if !catalog.is_empty() {
        let mark = icon("starred-symbolic", 16);
        mark.add_css_class("dc-secondary");
        let (head, _) = head_row(v, "catalog", "추천 채널", &catalog.len().to_string(), mark.upcast(), shape.searching, None);
        rows.push((v.catalog_group.clone(), head.upcast()));
        if is_open(v, "catalog", shape.searching) {
            for group in channels::GROUPS {
                let list: Vec<&&Source> = catalog.iter().filter(|s| s.group.as_deref() == Some(group)).collect();
                if list.is_empty() {
                    continue;
                }
                let (h, line) = row_frame(&spacer(col::DISCLOSURE + col::INDENT));
                line.append(&tag(group, 12.0, 400, &["dc-secondary"]));
                rows.push((v.catalog_group.clone(), h.upcast()));
                for s in list {
                    rows.push((v.catalog_group.clone(), catalog_row(s, v).upcast()));
                }
            }
        }
    }

    for (g, r) in &rows {
        g.add(r);
    }
    *v.rows.borrow_mut() = rows;
}

// 줄 열(맥 DesignSystem.swift RowColumn · 윈도우 settings.css --col-* 와 같은 규칙):
// [펼침 자리] [아이콘] [이름(고정 폭, 말줄임)] [칩들] … [건수·모두 켜기·구독] [알림 종] [켜기 스위치].
// 하위 줄은 한 단계(아이콘 + 간격) 들이고 이름 열을 그만큼 줄여 칩 열은 그대로. GTK 스위치·평평한 단추가 맥보다 커서 종·스위치 열만 넓다.
mod col {
    pub const DISCLOSURE: i32 = 16;
    pub const ICON: i32 = 22;
    pub const GAP: i32 = 8;
    pub const INDENT: i32 = ICON + GAP;
    pub const NAME: i32 = 136;
    pub const BELL: i32 = 34;
    pub const TOGGLE: i32 = 48;
    pub const CONTROLS: i32 = BELL + GAP + TOGGLE;
}

// 찾는 중이면 걸린 묶음을 펼친다(찾는 중에 접은 것은 접힌 채로), 아니면 사용자가 펼친 것만
fn is_open(v: &View, id: &str, searching: bool) -> bool {
    if searching { !v.collapsed_searching.borrow().contains(id) } else { v.expanded.borrow().contains(id) }
}

// 줄 틀: 목록 한 칸 안에 열 상자 하나(제목 없이 앞 자리에). lead = 펼침 자리(하위 줄은 + 들임)
fn row_frame(lead: &impl IsA<gtk::Widget>) -> (adw::ActionRow, gtk::Box) {
    let line = gtk::Box::new(gtk::Orientation::Horizontal, col::GAP);
    line.set_hexpand(true);
    line.append(lead);
    let row = adw::ActionRow::new();
    row.add_prefix(&line);
    (row, line)
}

fn spacer(width: i32) -> gtk::Box {
    let b = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    b.set_size_request(width, -1);
    b
}

// 이름 열: 고정 폭, 길면 말줄임(전체 이름은 풍선 도움말)
fn name_label(text: &str, full: &str, width: i32, bold: bool) -> gtk::Label {
    let l = gtk::Label::new(Some(text));
    l.set_xalign(0.0);
    l.set_ellipsize(gtk::pango::EllipsizeMode::End);
    l.set_max_width_chars(1); // 자연 폭을 줄여 정한 폭(size_request)만 쓰게
    l.set_size_request(width, -1);
    l.set_tooltip_text(Some(full));
    if bold {
        l.add_css_class("heading");
    }
    l
}

// 오른쪽 열 상자: 정한 폭 안에서 오른쪽 끝에 붙인다(밖으로 늘어나지 않게 hexpand 를 끊는다)
fn end_slot(width: i32, child: &impl IsA<gtk::Widget>) -> gtk::Box {
    let b = spacer(width);
    b.set_hexpand(false);
    child.set_halign(gtk::Align::End);
    child.set_hexpand(true);
    b.append(child);
    b
}

// 묶음 줄: [펼침 화살표] [아이콘] [이름] [건수] … [모두 켜기(종+스위치 자리)]. 줄을 누르면(Enter 포함) 펼치고 접는다.
// 모두 켜기/끄기는 줄 안 따로 단추라 줄 누름이 묶음을 켜지 않는다
fn head_row(v: &Rc<View>, id: &str, title: &str, count: &str, mark: gtk::Widget, searching: bool, trailing: Option<gtk::Widget>) -> (adw::ActionRow, gtk::Label) {
    let open = is_open(v, id, searching);
    let arrow = icon(if open { "pan-down-symbolic" } else { "pan-end-symbolic" }, 16);
    arrow.add_css_class("dc-secondary");
    arrow.set_size_request(col::DISCLOSURE, -1);
    let (row, line) = row_frame(&arrow);
    row.set_activatable(true);
    row.upcast_ref::<gtk::Widget>().update_property(&[gtk::accessible::Property::Label(&format!("{title}, {count}"))]);
    row.upcast_ref::<gtk::Widget>().update_state(&[gtk::accessible::State::Expanded(Some(open))]);
    mark.set_size_request(col::ICON, col::ICON);
    mark.set_valign(gtk::Align::Center);
    line.append(&mark);
    line.append(&name_label(title, title, col::NAME, true));
    let n = tag(count, 12.0, 400, &["dc-secondary", "numeric"]);
    n.set_hexpand(true);
    line.append(&n);
    if let Some(t) = trailing {
        line.append(&end_slot(col::CONTROLS, &t));
    }
    let (v, id) = (v.clone(), id.to_string());
    row.connect_activated(move |_| {
        {
            let mut set = if searching { v.collapsed_searching.borrow_mut() } else { v.expanded.borrow_mut() };
            if !set.remove(&id) {
                set.insert(id.clone());
            }
        }
        let v = v.clone();
        glib::idle_add_local_once(move || refresh(&v)); // 누른 줄을 그 신호 안에서 지우지 않게 다음 차례에
    });
    (row, n)
}

// 묶음 줄 앞 표시: 매체 = 첫 글자 동그라미, 분야 = 분야 아이콘, 지역 = 집/지구
fn group_mark(g: &sd::Group, layout: Layout) -> gtk::Widget {
    match layout {
        Layout::Media => {
            let mut s = g.sources[0].clone();
            s.name = g.title.clone();
            source_monogram(&s).upcast()
        }
        Layout::Section => {
            let i = icon(sections::by_id(g.id.trim_start_matches("section:")).map(|s| s.icon()).unwrap_or("text-x-generic-symbolic"), 16);
            i.add_css_class("dc-secondary");
            i.upcast()
        }
        Layout::Region => {
            let i = icon(if g.id == "region:kr" { "go-home-symbolic" } else { "web-browser-symbolic" }, 16);
            i.add_css_class("dc-secondary");
            i.upcast()
        }
    }
}

fn source_monogram(src: &Source) -> gtk::DrawingArea {
    let mut it = dropcap_core::models::NewsItem::new("", "", "", &src.id, &src.name, &src.tier);
    it.source_name = src.name.clone();
    let d = gtk::DrawingArea::builder().content_width(22).content_height(22).valign(gtk::Align::Center).build();
    let color = src.color.clone();
    let letter = it.initial();
    d.set_draw_func(move |area, cr, w, h| {
        let r = (w.min(h) as f64) / 2.0;
        let (cr_, cg, cb) = dropcap_core::models::hex_rgb(&color);
        cr.arc(w as f64 / 2.0, h as f64 / 2.0, r, 0.0, std::f64::consts::TAU);
        cr.set_source_rgb(cr_, cg, cb);
        let _ = cr.fill();
        let layout = area.create_pango_layout(Some(&letter));
        layout.set_font_description(Some(&theme::font(r * 0.95, gtk::pango::Weight::Bold)));
        let (_, ext) = layout.pixel_extents();
        cr.set_source_rgb(1.0, 1.0, 1.0);
        cr.move_to(w as f64 / 2.0 - ext.width() as f64 / 2.0 - ext.x() as f64, h as f64 / 2.0 - ext.height() as f64 / 2.0 - ext.y() as f64);
        crate::widgets::pangocairo_show(cr, &layout);
    });
    d
}

fn kind_badge(k: ItemKind) -> gtk::Label {
    chip(k.label(), dropcap_core::category::kind_color(k, theme::is_dark()))
}

// 출처 줄: 이름(묶음 안에서는 짧은 이름) · 분야 칩 · 국내/해외 · 유료 자물쇠 · (종류) · 알림 종 · 켜기 스위치 · (해지) · 주소 · 오류 표시
// 열은 col(묶음 안 줄 child 는 한 단계 들임)
fn source_row(src: &Source, removable: bool, media: Option<&str>, child: bool, v: &Rc<View>) -> adw::ActionRow {
    let name = media.map(|m| sd::short_name(src, m)).unwrap_or_else(|| src.name.clone());
    let indent = if child { col::INDENT } else { 0 };
    let (row, line) = row_frame(&spacer(col::DISCLOSURE + indent));
    row.upcast_ref::<gtk::Widget>().update_property(&[gtk::accessible::Property::Label(&name)]);
    line.append(&source_monogram(src));
    let body = gtk::Box::new(gtk::Orientation::Vertical, 2);
    body.set_hexpand(true);
    body.set_valign(gtk::Align::Center);
    let top = gtk::Box::new(gtk::Orientation::Horizontal, col::GAP);
    body.append(&top);
    line.append(&body);
    top.append(&name_label(&name, &src.name, col::NAME - indent, false));
    if let Some(h) = src.home.clone().or_else(|| removable.then(|| src.url.clone())) {
        let sub = tag(&h, 12.0, 400, &["dc-secondary"]);
        sub.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
        body.append(&sub);
    }
    if let Some(sec) = sections::by_id(src.section_id()) {
        let c = chip(&sec.name, &sec.color);
        c.set_valign(gtk::Align::Center);
        top.append(&c);
    }
    top.append(&tag(sd::region_label(src), 11.5, 400, &["dc-secondary"]));
    if let Some(note) = sd::paywall_note(src) {
        let k = if src.paywall.as_deref() == Some("metered") { PaywallKind::Metered } else { PaywallKind::Hard };
        let lock = icon(k.icon(), 13);
        lock.add_css_class("dc-secondary");
        lock.set_valign(gtk::Align::Center);
        lock.set_tooltip_text(Some(note));
        lock.update_property(&[gtk::accessible::Property::Label(note)]);
        top.append(&lock);
    }
    if src.item_kind() != ItemKind::Article {
        let b = kind_badge(src.item_kind());
        b.set_valign(gtk::Align::Center);
        top.append(&b);
    }
    if src.ai_only {
        top.append(&tag("AI 글만", 11.5, 400, &["dc-secondary"]));
    }
    let warn = icon("dialog-warning-symbolic", 14);
    warn.add_css_class("warning");
    top.append(&warn);
    // 출처 건강: 조용함·멈춤·글 없음·오류(켜진 출처만)
    let health = crate::settings_tools::health_badge();
    top.append(&health);
    // 해지 단추는 종 앞에 — 종·스위치 열은 모든 줄에서 오른쪽 끝 같은 자리
    if removable {
        let del = gtk::Button::builder().icon_name("user-trash-symbolic").css_classes(["flat"]).valign(gtk::Align::Center).tooltip_text("구독 해지").build();
        let id = src.id.clone();
        del.connect_clicked(move |_| ui().core.remove_custom_source(&id));
        line.append(&del);
    }
    let bell = gtk::ToggleButton::builder().css_classes(["flat"]).valign(gtk::Align::Center).build();
    line.append(&end_slot(col::BELL, &bell));
    let sw = gtk::Switch::builder().valign(gtk::Align::Center).build();
    line.append(&end_slot(col::TOGGLE, &sw));
    let id = src.id.clone();
    let busy = Rc::new(Cell::new(false));
    let update = {
        let (warn, bell, sw, id, busy, health) = (warn.clone(), bell.clone(), sw.clone(), id.clone(), busy.clone(), health.clone());
        move || {
            busy.set(true);
            let core = ui().core.clone();
            let st = core.state();
            match st.errors.get(&id) {
                Some(e) => {
                    warn.set_visible(true);
                    warn.set_tooltip_text(Some(&format!("확인 실패: {e}")));
                }
                None => warn.set_visible(false),
            }
            let enabled = st.enabled.get(&id) == Some(&true);
            let n = core.notifies(&id);
            bell.set_active(n);
            bell.set_icon_name(if n { "preferences-system-notifications-symbolic" } else { "notifications-disabled-symbolic" });
            bell.set_tooltip_text(Some(if n { "새 글 알림 켜짐 (끄면 매거진에만 실림)" } else { "알림 꺼짐 — 매거진에만 실림" }));
            bell.set_sensitive(enabled);
            sw.set_active(enabled);
            crate::settings_tools::update_health(&health, &id, enabled);
            busy.set(false);
        }
    };
    update();
    {
        let (id, busy) = (id.clone(), busy.clone());
        bell.connect_toggled(move |b| {
            if !busy.get() {
                ui().core.set_notify(&id, b.is_active());
            }
        });
    }
    {
        let busy = busy.clone();
        sw.connect_active_notify(move |w| {
            if !busy.get() {
                ui().core.set_enabled(&id, w.is_active());
            }
        });
    }
    v.updaters.borrow_mut().push(Box::new(update));
    row
}

// 추천 채널: 구독 / 확인 중… / 구독 중
// '추천 채널' 묶음의 하위 줄 — 출처 줄과 같은 열, 구독 단추는 종+스위치 자리
fn catalog_row(src: &Source, v: &Rc<View>) -> adw::ActionRow {
    let (row, line) = row_frame(&spacer(col::DISCLOSURE + col::INDENT));
    row.upcast_ref::<gtk::Widget>().update_property(&[gtk::accessible::Property::Label(&src.name)]);
    line.append(&source_monogram(src));
    let body = gtk::Box::new(gtk::Orientation::Vertical, 2);
    body.set_hexpand(true);
    body.set_valign(gtk::Align::Center);
    let top = gtk::Box::new(gtk::Orientation::Horizontal, col::GAP);
    top.append(&name_label(&src.name, &src.name, col::NAME - col::INDENT, false));
    if src.item_kind() != ItemKind::Article {
        let b = kind_badge(src.item_kind());
        b.set_valign(gtk::Align::Center);
        top.append(&b);
    }
    body.append(&top);
    body.append(&tag(if src.notify_default == Some(false) { "글이 많아 알림 없이 매거진에만 실림" } else { "새 글이 오면 알림" }, 12.0, 400, &["dc-secondary"]));
    line.append(&body);
    let done = gtk::Box::new(gtk::Orientation::Horizontal, 4);
    let ok = icon("object-select-symbolic", 13);
    ok.add_css_class("success");
    done.append(&ok);
    let l = tag("구독 중", 12.0, 500, &["success"]);
    done.append(&l);
    done.set_valign(gtk::Align::Center);
    let btn = gtk::Button::builder().label("구독").valign(gtk::Align::Center).build();
    let right = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    right.append(&done);
    right.append(&btn);
    line.append(&end_slot(col::CONTROLS, &right));
    let src2 = src.clone();
    let update = {
        let (done, btn) = (done.clone(), btn.clone());
        move || {
            let core = ui().core.clone();
            let sub = core.is_subscribed(&src2);
            let busy = core.is_subscribing(&src2.url);
            done.set_visible(sub);
            btn.set_visible(!sub);
            btn.set_sensitive(!busy);
            btn.set_label(if busy { "확인 중…" } else { "구독" });
        }
    };
    update();
    {
        let src = src.clone();
        let err = v.err.clone();
        btn.connect_clicked(move |b| {
            b.set_sensitive(false);
            b.set_label("확인 중…");
            let err = err.clone();
            bg(ui().core.clone().subscribe(src.clone()), move |r| {
                if let Some(e) = r {
                    err.set_text(&e);
                    err.set_visible(true);
                }
            });
        });
    }
    v.updaters.borrow_mut().push(Box::new(update));
    row
}
