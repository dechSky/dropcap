// 보관함(지난 기사) 지면 — 맥 UI/ArchiveView.swift 와 같은 단추·문구·수치.
// 일·주·월·연 단추와 ◀ ▶ 로 기간을 고르고, 그 기간의 기사를 최신순으로 본다(분야·출처 거르기, 100건씩 더 보기).
// 월·연은 날짜별 건수 막대를 먼저 보이고(막대를 누르면 그날로), 그날 지난 호가 있으면 맨 위에 '이 날의 호 보기'.
use crate::app::{bg, open_external, ui};
use crate::magazine::tint;
use crate::magazine_card::origin_of;
use crate::widgets::{self, label, lines};
use chrono::{DateTime, Local, Utc};
use dropcap_core::archive::{self, ArchivedItem, Page, Period};
use dropcap_core::magazine::Issue;
use dropcap_core::sections;
use adw::prelude::*;
use gtk::{gio, glib};
use std::cell::{Cell, RefCell};
use std::rc::Rc;

pub const PAGE_SIZE: usize = 100;

pub struct ArchivePage {
    period: Cell<Period>,
    anchor: Cell<DateTime<Utc>>,
    section: RefCell<Option<String>>,
    source: RefCell<Option<String>>,
    limit: Cell<usize>,
    earliest: Cell<Option<DateTime<Utc>>>,
    page: RefCell<Option<Page>>,
    serial: Cell<u64>,
    syncing: Cell<bool>, // 거르기 메뉴를 다시 채우는 동안 고름 알림을 무시
    title: gtk::Label,
    count: gtk::Label,
    periods: Vec<(Period, gtk::ToggleButton)>,
    prev: gtk::Button,
    next: gtk::Button,
    today: gtk::Button,
    section_menu: gtk::DropDown,
    section_keys: RefCell<Vec<Option<String>>>,
    source_menu: gtk::DropDown,
    source_keys: RefCell<Vec<Option<String>>>,
    body: gtk::Box,
    on_issue: Rc<dyn Fn(Issue)>,
}

pub fn page(on_issue: Rc<dyn Fn(Issue)>) -> (gtk::Widget, gtk::ScrolledWindow, Rc<ArchivePage>) {
    let v = gtk::Box::new(gtk::Orientation::Vertical, 16);
    v.set_margin_start(32);
    v.set_margin_end(32);
    v.set_margin_bottom(40);
    let scroll = gtk::ScrolledWindow::builder().hscrollbar_policy(gtk::PolicyType::Never).child(&v).vexpand(true).hexpand(true).build();

    // 머리: 보관함 · 기간 이름 · 건수
    let head = gtk::Box::new(gtk::Orientation::Vertical, 4);
    head.set_margin_top(28);
    head.append(&label("보관함", 11.0, 700, &["dc-secondary"]));
    let title = label("", 34.0, 700, &["dc-display"]);
    head.append(&title);
    let count = label(" ", 13.0, 400, &["dc-secondary"]);
    head.append(&count);
    v.append(&head);

    // 단추 줄: 일·주·월·연 | ◀ ▶ 오늘 | 분야·출처 거르기
    let controls = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    let seg = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    seg.add_css_class("linked");
    seg.set_homogeneous(true);
    seg.set_size_request(200, -1);
    let mut periods = vec![];
    let mut first: Option<gtk::ToggleButton> = None;
    for p in Period::ALL {
        let b = gtk::ToggleButton::with_label(p.label());
        if let Some(f) = &first {
            b.set_group(Some(f));
        } else {
            first = Some(b.clone());
        }
        seg.append(&b);
        periods.push((p, b));
    }
    controls.append(&seg);
    let nav = gtk::Box::new(gtk::Orientation::Horizontal, 4);
    let prev = gtk::Button::from_icon_name("go-previous-symbolic");
    prev.set_tooltip_text(Some("이전 기간"));
    prev.update_property(&[gtk::accessible::Property::Label("이전 기간")]);
    let next = gtk::Button::from_icon_name("go-next-symbolic");
    next.set_tooltip_text(Some("다음 기간"));
    next.update_property(&[gtk::accessible::Property::Label("다음 기간")]);
    let today = gtk::Button::with_label("오늘");
    nav.append(&prev);
    nav.append(&next);
    nav.append(&today);
    controls.append(&nav);
    let spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    spacer.set_hexpand(true);
    controls.append(&spacer);
    let section_menu = gtk::DropDown::from_strings(&["모든 분야"]);
    section_menu.set_tooltip_text(Some("분야로 거르기"));
    let source_menu = gtk::DropDown::from_strings(&["모든 출처"]);
    source_menu.set_tooltip_text(Some("출처로 거르기"));
    controls.append(&section_menu);
    controls.append(&source_menu);
    v.append(&controls);

    let body = gtk::Box::new(gtk::Orientation::Vertical, 16);
    v.append(&body);

    let period = Period::from_raw(&ui().prefs.borrow().archive_period);
    let me = Rc::new(ArchivePage {
        period: Cell::new(period),
        anchor: Cell::new(Utc::now()),
        section: RefCell::new(None),
        source: RefCell::new(None),
        limit: Cell::new(PAGE_SIZE),
        earliest: Cell::new(None),
        page: RefCell::new(None),
        serial: Cell::new(0),
        syncing: Cell::new(false),
        title,
        count,
        periods,
        prev,
        next,
        today,
        section_menu,
        section_keys: RefCell::new(vec![None]),
        source_menu,
        source_keys: RefCell::new(vec![None]),
        body,
        on_issue,
    });
    me.wire();
    me.sync_periods();
    me.reload();
    {
        // ◀ 의 끝(기록이 있는 가장 이른 때)
        let weak = Rc::downgrade(&me);
        let reader = ui().core.archive_reader.clone();
        bg(async move { reader.earliest_record() }, move |e| {
            if let Some(me) = weak.upgrade() {
                me.earliest.set(e);
                me.update_nav();
            }
        });
    }
    (scroll.clone().upcast(), scroll, me)
}

impl ArchivePage {
    fn wire(self: &Rc<Self>) {
        for (p, b) in &self.periods {
            let (p, weak) = (*p, Rc::downgrade(self));
            b.connect_toggled(move |b| {
                let Some(me) = weak.upgrade() else { return };
                if b.is_active() && !me.syncing.get() && me.period.get() != p {
                    me.set_period(p);
                }
            });
        }
        let weak = Rc::downgrade(self);
        self.prev.connect_clicked(move |_| {
            if let Some(me) = weak.upgrade() {
                me.move_by(-1);
            }
        });
        let weak = Rc::downgrade(self);
        self.next.connect_clicked(move |_| {
            if let Some(me) = weak.upgrade() {
                me.move_by(1);
            }
        });
        let weak = Rc::downgrade(self);
        self.today.connect_clicked(move |_| {
            if let Some(me) = weak.upgrade() {
                me.anchor.set(Utc::now());
                me.limit.set(PAGE_SIZE);
                me.reload();
            }
        });
        let weak = Rc::downgrade(self);
        self.section_menu.connect_selected_notify(move |dd| {
            let Some(me) = weak.upgrade() else { return };
            if me.syncing.get() {
                return;
            }
            let k = me.section_keys.borrow().get(dd.selected() as usize).cloned().flatten();
            *me.section.borrow_mut() = k;
            me.limit.set(PAGE_SIZE);
            me.reload();
        });
        let weak = Rc::downgrade(self);
        self.source_menu.connect_selected_notify(move |dd| {
            let Some(me) = weak.upgrade() else { return };
            if me.syncing.get() {
                return;
            }
            let k = me.source_keys.borrow().get(dd.selected() as usize).cloned().flatten();
            *me.source.borrow_mut() = k;
            me.limit.set(PAGE_SIZE);
            me.reload();
        });
    }

    fn range(&self) -> (DateTime<Utc>, DateTime<Utc>) {
        archive::range(self.period.get(), self.anchor.get())
    }

    fn set_period(self: &Rc<Self>, p: Period) {
        self.period.set(p);
        self.limit.set(PAGE_SIZE);
        ui().update_prefs(|x| x.archive_period = p.raw().into());
        self.sync_periods();
        self.reload();
    }

    fn sync_periods(&self) {
        let was = self.syncing.replace(true);
        for (p, b) in &self.periods {
            b.set_active(*p == self.period.get());
        }
        self.syncing.set(was);
    }

    fn move_by(self: &Rc<Self>, n: i64) {
        self.anchor.set(archive::shift(self.period.get(), self.anchor.get(), n));
        self.limit.set(PAGE_SIZE);
        self.reload();
    }

    fn update_nav(&self) {
        let (from, to) = self.range();
        let now = Utc::now();
        self.next.set_sensitive(to <= now);
        self.prev.set_sensitive(self.earliest.get().map(|e| from > e).unwrap_or(false));
        self.today.set_sensitive(archive::range(self.period.get(), now).0 != from);
        self.title.set_text(&archive::title(self.period.get(), self.anchor.get()));
    }

    // 매거진에 새 기사가 들어오면 지금 기간을 다시 읽는다(고른 기간·거르기·더 보기는 그대로).
    // 새로 받는 기사는 길어야 2주 안이므로 그보다 이른 기간은 그대로 둔다(읽던 자리가 흔들리지 않게)
    pub fn refresh(self: &Rc<Self>) {
        if self.range().1 > Utc::now() - chrono::Duration::days(14) {
            self.reload();
        }
    }

    // 지금 기간을 뒤에서 읽고(DB) 다 되면 그린다. 그새 기간을 바꿨으면 버림
    fn reload(self: &Rc<Self>) {
        self.update_nav();
        let n = self.serial.get() + 1;
        self.serial.set(n);
        if self.page.borrow().is_none() {
            widgets::clear_box(&self.body);
            let sp = gtk::Spinner::new();
            sp.start();
            sp.set_halign(gtk::Align::Start);
            sp.set_margin_top(24);
            self.body.append(&sp);
        }
        let (from, to) = self.range();
        let (section, source, limit) = (self.section.borrow().clone(), self.source.borrow().clone(), self.limit.get());
        let reader = ui().core.archive_reader.clone();
        let vis = ui().core.archive_visibility();
        let weak = Rc::downgrade(self);
        bg(async move { reader.period(from, to, section.as_deref(), source.as_deref(), limit, &vis) }, move |p| {
            let Some(me) = weak.upgrade() else { return };
            if me.serial.get() != n {
                return;
            }
            *me.page.borrow_mut() = Some(p);
            me.render();
        });
    }

    fn render(self: &Rc<Self>) {
        let Some(page) = self.page.borrow().clone() else { return };
        self.update_nav();
        self.count.set_text(&if page.more { format!("기사 {}건 · 최신순 {}건 보는 중", page.total, page.items.len()) } else { format!("기사 {}건", page.total) });
        self.fill_menus(&page);
        widgets::clear_box(&self.body);
        let period = self.period.get();
        let (from, to) = self.range();
        // 고른 날의 지난 호(일 보기에서만)
        if period == Period::Day {
            let id = format!("daily-{}", dropcap_core::magazine::day_id(from));
            if let Some(issue) = ui().core.archive().into_iter().find(|i| i.id == id) {
                let b = gtk::Button::new();
                b.add_css_class("flat");
                b.add_css_class("dc-soft");
                let h = gtk::Box::new(gtk::Orientation::Horizontal, 8);
                h.set_margin_top(10);
                h.set_margin_bottom(10);
                h.set_margin_start(8);
                h.append(&widgets::icon("x-office-document-symbolic", 16));
                h.append(&label(&format!("이 날의 호 보기 — {}", issue.title()), 14.0, 600, &["accent"]));
                b.set_child(Some(&h));
                let on = self.on_issue.clone();
                b.connect_clicked(move |_| on(issue.clone()));
                self.body.append(&b);
            }
        }
        if period.shows_bars() && page.total > 0 {
            let weak = Rc::downgrade(self);
            self.body.append(&day_bars(archive::days(from, to), &page, period == Period::Year, move |d| {
                if let Some(me) = weak.upgrade() {
                    me.anchor.set(d);
                    me.set_period(Period::Day);
                }
            }));
        }
        if page.items.is_empty() {
            let filtered = self.section.borrow().is_some() || self.source.borrow().is_some();
            let l = label(if filtered { "거른 조건에 맞는 기사가 없습니다." } else { "이 기간에는 모인 기사가 없습니다." }, 13.0, 400, &["dc-secondary"]);
            l.set_margin_top(24);
            self.body.append(&l);
            return;
        }
        let list = gtk::Box::new(gtk::Orientation::Vertical, 0);
        for (i, it) in page.items.iter().enumerate() {
            if i > 0 {
                let s = gtk::Separator::new(gtk::Orientation::Horizontal);
                s.set_opacity(0.5);
                list.append(&s);
            }
            list.append(&archive_row(it, period != Period::Day));
        }
        self.body.append(&list);
        if page.more {
            let more = gtk::Button::with_label(&format!("{PAGE_SIZE}건 더 보기"));
            more.add_css_class("flat");
            more.set_halign(gtk::Align::Start);
            let weak = Rc::downgrade(self);
            more.connect_clicked(move |b| {
                if let Some(me) = weak.upgrade() {
                    b.set_sensitive(false);
                    me.limit.set(me.limit.get() + PAGE_SIZE);
                    me.reload();
                }
            });
            self.body.append(&more);
        }
    }

    // 거르기 메뉴: 전체 + 건수 많은 순(분야는 같은 건수면 분야 순서). 고른 것이 이 기간에 없어도 메뉴에 남긴다
    fn fill_menus(&self, page: &Page) {
        let was = self.syncing.replace(true);
        let fill = |dd: &gtk::DropDown, keys: &RefCell<Vec<Option<String>>>, all: &str, counts: &std::collections::HashMap<String, i64>, current: Option<String>, name: &dyn Fn(&str) -> String, order: &dyn Fn(&str) -> usize| {
            let mut v: Vec<(&String, &i64)> = counts.iter().collect();
            v.sort_by(|a, b| b.1.cmp(a.1).then_with(|| order(a.0).cmp(&order(b.0))).then_with(|| a.0.cmp(b.0)));
            let mut k: Vec<Option<String>> = vec![None];
            let mut labels = vec![all.to_string()];
            for (key, n) in v {
                k.push(Some(key.clone()));
                labels.push(format!("{}  {n}", name(key)));
            }
            if let Some(c) = &current {
                if !k.iter().any(|x| x.as_deref() == Some(c.as_str())) {
                    k.push(Some(c.clone()));
                    labels.push(format!("{}  0", name(c)));
                }
            }
            let sel = k.iter().position(|x| *x == current).unwrap_or(0);
            dd.set_model(Some(&gtk::StringList::new(&labels.iter().map(|s| s.as_str()).collect::<Vec<_>>())));
            dd.set_selected(sel as u32);
            *keys.borrow_mut() = k;
        };
        fill(&self.section_menu, &self.section_keys, "모든 분야", &page.sections, self.section.borrow().clone(), &|s| sections::name(s), &|s| sections::order(s));
        fill(&self.source_menu, &self.source_keys, "모든 출처", &page.sources, self.source.borrow().clone(), &|s| s.to_string(), &|_| 0);
        self.syncing.set(was);
    }
}

// 날짜별 건수 막대(월·연). 막대를 누르면 그날 보기로
fn day_bars(days: Vec<DateTime<Utc>>, page: &Page, compact: bool, pick: impl Fn(DateTime<Utc>) + 'static) -> gtk::Box {
    const H: f64 = 72.0;
    let counts: Vec<i64> = days.iter().map(|d| page.day_counts.get(&archive::day_key(*d)).copied().unwrap_or(0)).collect();
    let peak = counts.iter().copied().max().unwrap_or(1).max(1);
    let wrap = gtk::Box::new(gtk::Orientation::Vertical, 4);
    wrap.add_css_class("dc-soft");
    let area = gtk::DrawingArea::new();
    area.set_content_height(H as i32);
    area.set_hexpand(true);
    area.set_margin_top(12);
    area.set_margin_start(12);
    area.set_margin_end(12);
    let n = days.len().max(1);
    {
        let counts = counts.clone();
        area.set_draw_func(move |a, cr, w, h| {
            let dark = crate::theme::is_dark();
            let fg = a.color();
            let gap = if compact { 1.0 } else { 2.0 };
            let slot = w as f64 / n as f64;
            let bw = (slot - gap).max(1.0);
            for (i, c) in counts.iter().enumerate() {
                let x = i as f64 * slot;
                let bh = if *c == 0 { 2.0 } else { (H * *c as f64 / peak as f64).max(3.0) };
                if *c == 0 {
                    cr.set_source_rgba(fg.red() as f64, fg.green() as f64, fg.blue() as f64, 0.15);
                } else if dark {
                    cr.set_source_rgba(0.04, 0.52, 1.0, 0.75); // 강조색(#0A84FF)
                } else {
                    cr.set_source_rgba(0.0, 0.48, 1.0, 0.75); // 강조색(#007AFF)
                }
                let r: f64 = if compact { 1.0 } else { 2.0 };
                rounded(cr, x, h as f64 - bh, bw, bh, r.min(bw / 2.0));
                let _ = cr.fill();
            }
        });
    }
    // 마우스를 올리면 그날·건수, 누르면 그날로(0건인 날은 누르지 않음)
    let at = move |a: &gtk::DrawingArea, x: f64| -> usize { ((x / (a.width().max(1) as f64 / n as f64)) as usize).min(n - 1) };
    area.set_has_tooltip(true);
    {
        let (days, counts) = (days.clone(), counts.clone());
        area.connect_query_tooltip(move |a, x, _, _, tip| {
            let i = at(a, x as f64);
            tip.set_text(Some(&format!("{} · {}건", archive::title(Period::Day, days[i]), counts[i])));
            true
        });
    }
    {
        let click = gtk::GestureClick::new();
        let (days, counts, a2) = (days.clone(), counts.clone(), area.clone());
        click.connect_released(move |_, _, x, _| {
            let i = at(&a2, x);
            if counts[i] > 0 {
                pick(days[i]);
            }
        });
        area.add_controller(click);
    }
    area.set_cursor_from_name(Some("pointer"));
    wrap.append(&area);
    let foot = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    foot.set_margin_start(12);
    foot.set_margin_end(12);
    foot.set_margin_bottom(10);
    let dot = |d: Option<&DateTime<Utc>>| d.map(|d| archive::day_key(*d).replace('-', ". ")).unwrap_or_default();
    let first = label(&dot(days.first()), 11.0, 400, &["dc-tertiary"]);
    let mid = label(&format!("하루 많게는 {peak}건"), 11.0, 400, &["dc-tertiary"]);
    mid.set_hexpand(true);
    mid.set_xalign(0.5);
    let last = label(&dot(days.last()), 11.0, 400, &["dc-tertiary"]);
    foot.append(&first);
    foot.append(&mid);
    foot.append(&last);
    wrap.append(&foot);
    wrap
}

fn rounded(cr: &gtk::cairo::Context, x: f64, y: f64, w: f64, h: f64, r: f64) {
    use std::f64::consts::PI;
    let r = r.min(h / 2.0);
    cr.new_sub_path();
    cr.arc(x + w - r, y + r, r, -PI / 2.0, 0.0);
    cr.arc(x + w - r, y + h - r, r, 0.0, PI / 2.0);
    cr.arc(x + r, y + h - r, r, PI / 2.0, PI);
    cr.arc(x + r, y + r, r, PI, 1.5 * PI);
    cr.close_path();
}

// 보관 기사 한 줄: 때 · 분야 · 제목 · 출처. 누르면 읽기 창(본문은 링크에서 다시 받음), 오른쪽 클릭은 브라우저에서 열기
pub fn archive_row(item: &ArchivedItem, show_day: bool) -> gtk::Widget {
    let l = item.date.with_timezone(&Local);
    let when = if show_day { l.format("%-m/%-d %H:%M").to_string() } else { l.format("%H:%M").to_string() };
    let h = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    let t = label(&when, 11.5, 400, &["dc-tertiary", "numeric"]);
    t.set_wrap(false);
    t.set_width_chars(if show_day { 11 } else { 5 });
    t.set_valign(gtk::Align::Start);
    h.append(&t);
    let dot = gtk::Label::new(Some("●"));
    dot.set_valign(gtk::Align::Start);
    dot.set_tooltip_text(Some(&sections::name(&item.section)));
    let color = sections::by_id(&item.section).map(|s| s.color.clone()).unwrap_or_else(|| "#8E8E93".into());
    tint(&dot, &color);
    let attrs = gtk::pango::AttrList::new();
    attrs.insert(gtk::pango::AttrSize::new_size_absolute(8 * gtk::pango::SCALE));
    dot.set_attributes(Some(&attrs));
    h.append(&dot);
    let title = label(item.display_title(), 13.5, 400, &[]);
    lines(&title, 2);
    title.set_hexpand(true);
    if item.title_ko.is_some() {
        title.set_tooltip_text(Some(&item.title));
    }
    h.append(&title);
    let src = label(&item.source, 11.5, 400, &["dc-secondary"]);
    src.set_wrap(false);
    src.set_ellipsize(gtk::pango::EllipsizeMode::End);
    src.set_max_width_chars(18);
    src.set_valign(gtk::Align::Start);
    h.append(&src);
    let b = gtk::Button::builder().child(&h).css_classes(["flat", "dc-row"]).build();
    {
        let it = item.news_item();
        b.connect_clicked(move |b| crate::reader::open_in(&it, origin_of(b), vec![]));
    }
    // 오른쪽 클릭: 브라우저에서 열기(카드 메뉴와 같은 방식 — 닫히면 떼어 냄)
    let rc = gtk::GestureClick::builder().button(3).build();
    {
        let link = item.link.clone();
        rc.connect_pressed(move |g, _, x, y| {
            g.set_state(gtk::EventSequenceState::Claimed);
            let Some(target) = g.widget() else { return };
            let group = gio::SimpleActionGroup::new();
            let a = gio::SimpleAction::new("browser", None);
            let l = link.clone();
            a.connect_activate(move |_, _| {
                open_external(&l);
            });
            group.add_action(&a);
            target.insert_action_group("archive", Some(&group));
            let menu = gio::Menu::new();
            menu.append(Some("브라우저에서 열기"), Some("archive.browser"));
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
    }
    b.add_controller(rc);
    b.upcast()
}
