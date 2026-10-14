// 한 호의 지면(맥 MagazineView.IssueView · Masthead · CoverStory · SectionBlock · MagSort).
use crate::app::{bg, open_from_magazine, ui};
use crate::magazine::tint;
use crate::magazine_card::{has_photo, origin_of, scroll_focus, stagger, ChipBar, StoryCard};
use crate::widgets::{self, label, lines};
use crate::{motion, theme};
use dropcap_core::app_model::UiEvent;
use dropcap_core::category::NewsCategory;
use dropcap_core::magazine::{self, Issue, Resolved, Section};
use dropcap_core::models::NewsItem;
use adw::prelude::*;
use gtk::{cairo, gdk, glib};
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;

#[derive(Debug, Clone, PartialEq)]
pub enum IssueSource {
    Today,
    Week,
    Fixed(Issue),
}

// 기사 정렬 기준(M-10, prefs.mag_sort 기억)
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum MagSort {
    Recommended,
    Newest,
    Coverage,
    Source,
}

impl MagSort {
    pub const ALL: [MagSort; 4] = [MagSort::Recommended, MagSort::Newest, MagSort::Coverage, MagSort::Source];
    pub fn raw(self) -> &'static str {
        match self {
            MagSort::Recommended => "recommended",
            MagSort::Newest => "newest",
            MagSort::Coverage => "coverage",
            MagSort::Source => "source",
        }
    }
    pub fn label(self) -> &'static str {
        match self {
            MagSort::Recommended => "추천순",
            MagSort::Newest => "최신순",
            MagSort::Coverage => "많이 보도된 순",
            MagSort::Source => "출처별",
        }
    }
    pub fn from_raw(s: &str) -> MagSort {
        Self::ALL.into_iter().find(|m| m.raw() == s).unwrap_or(MagSort::Recommended)
    }
    // 추천순은 편집 순서(점수) 그대로. 많이 보도된 순은 스토리 크기(외 N곳보다 큰 쪽)
    pub fn apply(self, items: &[NewsItem], cov: &HashMap<String, i64>) -> Vec<NewsItem> {
        let mut v: Vec<(usize, NewsItem)> = items.iter().cloned().enumerate().collect();
        match self {
            MagSort::Recommended => {}
            MagSort::Newest => v.sort_by(|a, b| b.1.date_or_past().cmp(&a.1.date_or_past())),
            MagSort::Coverage => {
                let c = |i: &NewsItem| cov.get(&i.key()).cloned().unwrap_or(1).max(i.related_count() as i64 + 1);
                v.sort_by(|a, b| c(&b.1).cmp(&c(&a.1)).then(a.0.cmp(&b.0)));
            }
            MagSort::Source => v.sort_by(|a, b| a.1.source_name.cmp(&b.1.source_name).then(b.1.date_or_past().cmp(&a.1.date_or_past()))),
        }
        v.into_iter().map(|(_, i)| i).collect()
    }
}

// 화면 밖에서(tokio) 엮어 온 한 호
struct Built {
    r: Resolved,
    coverage: HashMap<String, i64>,
    cover_size: i64,
}

pub struct IssuePage {
    pub root: gtk::Overlay,
    pub scroll: gtk::ScrolledWindow,
    content: gtk::Box,
    banner: gtk::Button,
    source: IssueSource,
    focus: RefCell<Option<String>>,
    sub: RefCell<Option<NewsCategory>>,
    data: RefCell<Option<Rc<Built>>>,
    pending_new: Cell<bool>,
    building: Cell<bool>,
    first: Cell<bool>,
    on_story: Rc<dyn Fn(String)>,
    cards: Rc<RefCell<Vec<gtk::Widget>>>,
}

impl IssuePage {
    pub fn new(source: IssueSource, focus: Option<String>, on_story: Rc<dyn Fn(String)>) -> Rc<IssuePage> {
        let content = gtk::Box::new(gtk::Orientation::Vertical, 0);
        let scroll = gtk::ScrolledWindow::builder().hscrollbar_policy(gtk::PolicyType::Never).child(&content).vexpand(true).hexpand(true).build();
        let root = gtk::Overlay::new();
        root.set_child(Some(&scroll));
        // 보는 동안 새 소식이 오면 지면을 갈아엎지 않고 위에 띠만(M-11)
        let banner = gtk::Button::new();
        banner.add_css_class("flat");
        banner.add_css_class("dc-banner");
        let bb = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        bb.append(&widgets::icon("go-up-symbolic", 12));
        bb.append(&label("새 소식이 들어왔어요 · 새로 보기", 12.5, 600, &[]));
        banner.set_child(Some(&bb));
        banner.set_halign(gtk::Align::Center);
        banner.set_valign(gtk::Align::Start);
        banner.set_margin_top(14);
        banner.set_visible(false);
        root.add_overlay(&banner);
        let me = Rc::new(IssuePage {
            root,
            scroll: scroll.clone(),
            content,
            banner: banner.clone(),
            source,
            focus: RefCell::new(focus),
            sub: RefCell::new(None),
            data: RefCell::new(None),
            pending_new: Cell::new(false),
            building: Cell::new(false),
            first: Cell::new(true),
            on_story,
            cards: Rc::new(RefCell::new(vec![])),
        });
        {
            let weak = Rc::downgrade(&me);
            banner.connect_clicked(move |_| {
                if let Some(m) = weak.upgrade() {
                    m.pending_new.set(false);
                    m.banner.set_visible(false);
                    m.rebuild();
                    m.scroll.vadjustment().set_value(0.0);
                }
            });
        }
        scroll_focus(&scroll, me.cards.clone());
        me.rebuild();
        me
    }

    fn is_fixed(&self) -> bool {
        matches!(self.source, IssueSource::Fixed(_))
    }

    // 핵심 소식에 맞춰 다시 엮기(M-11)
    pub fn on_event(self: &Rc<Self>, e: &UiEvent) {
        match e {
            UiEvent::Magazine if !self.is_fixed() => {
                let empty = self.data.borrow().as_ref().map(|d| d.r.cover.is_none() || d.r.issue.count == 0).unwrap_or(true);
                if empty || ui().core.preparing.load(std::sync::atomic::Ordering::SeqCst) {
                    self.rebuild(); // 빈 지면·표지 없음·첫 호 엮는 중이면 알림 없이 바로 채운다
                } else {
                    self.pending_new.set(true);
                    self.banner.set_visible(true);
                    widgets::fade_in(&self.banner, 300);
                }
            }
            UiEvent::Images => {
                if !self.pending_new.get() {
                    self.rebuild(); // 사진만 새로 채워졌으면 조용히 반영
                }
            }
            UiEvent::Layout => self.rebuild(), // 출처 숨기기·분야 바꾸기는 바로
            UiEvent::Preparing(false) if !self.is_fixed() => self.rebuild(),
            _ => {}
        }
    }

    pub fn rebuild(self: &Rc<Self>) {
        if self.building.replace(true) {
            return;
        }
        let core = ui().core.clone();
        let source = self.source.clone();
        let weak = Rc::downgrade(self);
        bg(
            async move {
                let ed = core.editorial();
                let issue = match source {
                    IssueSource::Today => magazine::live_daily(&core.db, &ed),
                    IssueSource::Week => magazine::live_weekly(&core.db, &ed),
                    IssueSource::Fixed(i) => i,
                };
                let r = magazine::resolve(&core.db, &issue, &ed.hidden);
                let keys: Vec<String> = r.sections.iter().flat_map(|(_, items)| items.iter().map(|i| i.key())).collect();
                let coverage = core.db.coverage(&keys);
                let cover_size = r.cover.as_ref().and_then(|c| c.cluster.as_ref()).and_then(|c| core.db.cluster(c)).map(|c| c.size).unwrap_or(1);
                Built { r, coverage, cover_size }
            },
            move |b| {
                let Some(me) = weak.upgrade() else { return };
                me.building.set(false);
                *me.data.borrow_mut() = Some(Rc::new(b));
                me.render();
            },
        );
    }

    fn width(&self) -> i32 {
        let w = self.scroll.width();
        if w > 100 {
            w
        } else {
            900
        }
    }

    // 분야 칩으로 거른 지면
    fn shown(&self, d: &Built) -> Vec<(Section, Vec<NewsItem>)> {
        let Some(f) = self.focus.borrow().clone() else { return d.r.sections.clone() };
        let sub = *self.sub.borrow();
        d.r.sections
            .iter()
            .filter(|(s, _)| s.section.as_deref() == Some(f.as_str()))
            .filter_map(|(s, items)| {
                let items: Vec<NewsItem> = if f == dropcap_core::sections::AI && sub.is_some() { items.iter().filter(|i| Some(i.category()) == sub).cloned().collect() } else { items.clone() };
                (!items.is_empty()).then(|| (s.clone(), items))
            })
            .collect()
    }

    fn render(self: &Rc<Self>) {
        let Some(d) = self.data.borrow().clone() else { return };
        widgets::clear_box(&self.content);
        self.cards.borrow_mut().clear();
        let appeared = self.first.replace(false);
        let live = !self.is_fixed();
        // 머리(M-06)
        let head = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        head.set_margin_top(28);
        head.set_margin_bottom(22);
        head.set_margin_start(36);
        head.set_margin_end(36);
        head.append(&masthead(&d.r.issue, live, appeared));
        let sort = gtk::DropDown::from_strings(&MagSort::ALL.map(|m| m.label()));
        let current = MagSort::from_raw(&ui().prefs.borrow().mag_sort);
        sort.set_selected(MagSort::ALL.iter().position(|m| *m == current).unwrap_or(0) as u32);
        sort.set_valign(gtk::Align::End);
        sort.set_tooltip_text(Some("지면 안의 기사 순서"));
        {
            let weak = Rc::downgrade(self);
            sort.connect_selected_notify(move |dd| {
                let m = MagSort::ALL[(dd.selected() as usize).min(3)];
                ui().update_prefs(|p| p.mag_sort = m.raw().into());
                if let Some(me) = weak.upgrade() {
                    me.render();
                }
            });
        }
        head.append(&sort);
        self.content.append(&head);
        // 분야 칩 줄(G-09): 지면이 있는 분야(건수)
        let chips: Vec<String> = d.r.sections.iter().filter_map(|(s, _)| s.section.clone()).collect();
        if chips.len() > 1 || self.focus.borrow().is_some() {
            let mut counts: HashMap<String, usize> = HashMap::new();
            for (s, items) in &d.r.sections {
                if let Some(id) = &s.section {
                    *counts.entry(id.clone()).or_default() += items.len();
                }
            }
            let weak = Rc::downgrade(self);
            let bar = ChipBar::new(
                &chips,
                &counts,
                self.focus.borrow().clone(),
                *self.sub.borrow(),
                Rc::new(move |f, s| {
                    if let Some(me) = weak.upgrade() {
                        *me.focus.borrow_mut() = f;
                        *me.sub.borrow_mut() = s;
                        let me2 = me.clone();
                        glib::idle_add_local_once(move || me2.render());
                    }
                }),
            );
            bar.root.set_margin_start(36);
            bar.root.set_margin_end(36);
            bar.root.set_margin_bottom(18);
            self.content.append(&bar.root);
        }
        // 표지(M-07) — 분야만 보고 있으면 표지 없이 그 지면만
        if self.focus.borrow().is_none() {
            match &d.r.cover {
                Some(c) => {
                    let cover = cover_story(&c.item, c.cluster.clone(), d.cover_size, self.on_story.clone());
                    cover.set_margin_start(28);
                    cover.set_margin_end(28);
                    if appeared && motion::enabled() {
                        cover.set_opacity(0.0);
                        let c2 = cover.clone();
                        widgets::later(150, move || widgets::fade_in(&c2, 700));
                    }
                    self.content.append(&cover);
                }
                None => self.content.append(&empty_issue(live)),
            }
        }
        // 분야 지면(G-10)
        let sort = MagSort::from_raw(&ui().prefs.borrow().mag_sort);
        let width = self.width() - 56;
        for (sec, items) in self.shown(&d) {
            let items = sort.apply(&items, &d.coverage);
            let block = self.section_block(&sec, &items, &d.r, width);
            block.set_margin_top(38);
            self.content.append(&block);
        }
        // 저작권 안내(M-22)
        let foot = label("기사 저작권은 각 언론사·기업에 있습니다. 제목·요약·사진은 원문으로 이어 주기 위한 것입니다.", 11.0, 400, &["dc-tertiary"]);
        foot.set_margin_start(36);
        foot.set_margin_end(36);
        foot.set_margin_top(40);
        foot.set_margin_bottom(40);
        self.content.append(&foot);
    }

    fn section_block(self: &Rc<Self>, sec: &Section, items: &[NewsItem], r: &Resolved, width: i32) -> gtk::Box {
        let b = gtk::Box::new(gtk::Orientation::Vertical, 14);
        let head = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        head.set_margin_start(36);
        head.set_margin_end(36);
        let i = widgets::icon(sec.icon(), 18);
        tint(&i, &sec.color(theme::is_dark()));
        head.append(&i);
        head.append(&label(&sec.label(), 20.0, 700, &["dc-display"]));
        head.append(&label(&items.len().to_string(), 13.0, 600, &["dc-secondary"]));
        let line = gtk::Separator::new(gtk::Orientation::Horizontal);
        line.set_hexpand(true);
        line.set_valign(gtk::Align::Center);
        line.set_margin_start(6);
        head.append(&line);
        b.append(&head);
        let flow = gtk::FlowBox::new();
        flow.set_selection_mode(gtk::SelectionMode::None);
        flow.set_homogeneous(true);
        flow.set_column_spacing(18);
        flow.set_row_spacing(22);
        flow.set_margin_start(28);
        flow.set_margin_end(28);
        // 마지막 줄에 카드 한 장만 남지 않게 칸 수를 고른다(맥 BalancedGrid)
        let fit = ((width + 18) / (230 + 18)).max(1) as usize;
        let cols = balanced_columns(fit.min(4), items.len());
        flow.set_min_children_per_line(cols as u32);
        flow.set_max_children_per_line(cols as u32);
        for (n, it) in items.iter().enumerate() {
            let cluster = r.clusters.get(&it.key()).cloned();
            let story_items = cluster.as_ref().and_then(|c| r.regions.get(c)).cloned().unwrap_or_default();
            let card = StoryCard::build(it, n, cluster, &story_items, Some(self.on_story.clone()));
            self.cards.borrow_mut().push(card.clone());
            flow.insert(&card, -1);
        }
        b.append(&flow);
        b
    }
}

// 마지막 줄에 카드 한 장만 남지 않게(4장이면 2×2, 7장이면 4+3 …)
pub fn balanced_columns(fit: usize, count: usize) -> usize {
    let fit = fit.max(1);
    if count <= fit || count % fit != 1 {
        return fit.min(count.max(1));
    }
    if fit + 1 <= 4 && count % (fit + 1) != 1 && count >= fit + 1 {
        return fit + 1;
    }
    if fit > 2 && count % (fit - 1) != 1 {
        return fit - 1;
    }
    fit
}

// 머리: DROPCAP 로고(D 크게)·"매거진"·발행 중·호 제목·소식 수·분야 수, 줄이 그어지며 나타남(M-06)
fn masthead(issue: &Issue, live: bool, appeared: bool) -> gtk::Box {
    let v = gtk::Box::new(gtk::Orientation::Vertical, 6);
    v.set_hexpand(true);
    let top = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let logo = gtk::Label::new(None);
    logo.set_markup("<span font_family='serif' weight='heavy' size='22pt'>D</span><span font_family='serif' weight='heavy' size='13pt' letter_spacing='2200'>ROPCAP</span>");
    logo.set_valign(gtk::Align::Baseline);
    top.append(&logo);
    top.append(&label(crate::strings::MAGAZINE, 11.5, 500, &["dc-secondary"]));
    if live {
        let l = gtk::Label::new(Some("발행 중"));
        l.add_css_class("dc-live");
        l.set_valign(gtk::Align::Center);
        top.append(&l);
    }
    v.append(&top);
    let title = label(&issue.title(), 38.0, 700, &["dc-display"]);
    v.append(&title);
    v.append(&label(&format!("소식 {}건 · 분야 {}개", issue.count, issue.sections.len()), 13.0, 400, &["dc-secondary"]));
    // 줄이 그어지며 나타남
    let progress = Rc::new(Cell::new(if appeared && motion::enabled() { 0.0 } else { 1.0 }));
    let line = gtk::DrawingArea::builder().content_height(2).hexpand(true).build();
    line.set_margin_top(10);
    {
        let p = progress.clone();
        line.set_draw_func(move |area, cr, w, h| {
            let c = area.color();
            cr.set_source_rgba(c.red() as f64, c.green() as f64, c.blue() as f64, 0.85);
            cr.rectangle(0.0, 0.0, w as f64 * p.get(), h as f64);
            let _ = cr.fill();
        });
    }
    if progress.get() < 1.0 {
        let l2 = line.clone();
        let p = progress.clone();
        let target = adw::CallbackAnimationTarget::new(move |x| {
            p.set(x);
            l2.queue_draw();
        });
        let a = adw::TimedAnimation::new(&line, 0.0, 1.0, 900, target);
        a.set_easing(adw::Easing::EaseOutCubic);
        widgets::later(100, move || adw::prelude::AnimationExt::play(&a));
    }
    v.append(&line);
    for (i, w) in [top.upcast::<gtk::Widget>(), title.upcast()].into_iter().enumerate() {
        if appeared {
            stagger(&w, i);
        }
    }
    v
}

fn empty_issue(live: bool) -> gtk::Box {
    let v = gtk::Box::new(gtk::Orientation::Vertical, 8);
    v.set_margin_start(36);
    v.set_margin_top(60);
    v.set_margin_bottom(60);
    if ui().core.preparing.load(std::sync::atomic::Ordering::SeqCst) {
        let sp = gtk::Spinner::new();
        sp.start();
        sp.set_halign(gtk::Align::Start);
        v.append(&sp);
        v.append(&label("첫 호를 엮는 중…", 20.0, 600, &["dc-display"]));
        v.append(&label("구독한 출처에서 최근 사흘 소식을 모으고 번역하고 있어요. 잠시면 됩니다.", 13.0, 400, &["dc-secondary"]));
    } else {
        let i = widgets::icon("x-office-document-symbolic", 34);
        i.set_halign(gtk::Align::Start);
        i.add_css_class("dc-tertiary");
        v.append(&i);
        v.append(&label(if live { "아직 이번 호에 실을 소식이 없습니다" } else { "이 호에는 소식이 없습니다" }, 20.0, 600, &["dc-display"]));
        v.append(&label("새 소식이 들어오는 대로 지면이 채워집니다.", 13.0, 400, &["dc-secondary"]));
    }
    v
}

// 텍스처를 Cairo 그림으로(켄 번스로 직접 그리려고)
fn texture_surface(t: &gdk::Texture) -> Option<cairo::ImageSurface> {
    let (w, h) = (t.width(), t.height());
    let stride = cairo::Format::ARgb32.stride_for_width(w as u32).ok()?;
    let mut data = vec![0u8; (stride * h) as usize];
    t.download(&mut data, stride as usize);
    cairo::ImageSurface::create_for_data(data, cairo::Format::ARgb32, w, h, stride).ok()
}

// 표지(M-07): 큰 사진 + 켄 번스(22초 왕복) + 아래 그라데이션, 배지·분야·출처·시간, 큰 제목·원제목, '기사 읽기', '여러 시각 N곳'
fn cover_story(item: &NewsItem, cluster: Option<String>, size: i64, on_story: Rc<dyn Fn(String)>) -> gtk::Widget {
    let photo = has_photo(item);
    let ov = gtk::Overlay::new();
    ov.add_css_class("dc-cover");
    ov.set_overflow(gtk::Overflow::Hidden);
    if photo {
        let surf: Rc<RefCell<Option<cairo::ImageSurface>>> = Rc::new(RefCell::new(None));
        let t = Rc::new(Cell::new(0.0f64));
        let area = gtk::DrawingArea::builder().content_height(400).hexpand(true).build();
        {
            let surf = surf.clone();
            let t = t.clone();
            let accent = widgets::source_color(&item.source_id);
            area.set_draw_func(move |_, cr, w, h| {
                let (w, h) = (w as f64, h as f64);
                if let Some(s) = surf.borrow().as_ref() {
                    let (iw, ih) = (s.width() as f64, s.height() as f64);
                    let k = t.get();
                    let scale = (w / iw).max(h / ih) * (1.0 + 0.12 * k);
                    let dx = 8.0 + (-22.0 - 8.0) * k;
                    let dy = 4.0 + (-10.0 - 4.0) * k;
                    cr.save().ok();
                    cr.translate(w / 2.0 + dx, h / 2.0 + dy);
                    cr.scale(scale, scale);
                    let _ = cr.set_source_surface(s, -iw / 2.0, -ih / 2.0);
                    let _ = cr.paint();
                    cr.restore().ok();
                } else {
                    let (r, g, b) = dropcap_core::models::hex_rgb(&accent); // 사진을 받기 전에는 출처 색으로
                    cr.set_source_rgba(r, g, b, 0.2);
                    let _ = cr.paint();
                }
                // 아래 그라데이션
                let g = cairo::LinearGradient::new(0.0, 0.0, 0.0, h);
                g.add_color_stop_rgba(0.25, 0.0, 0.0, 0.0, 0.0);
                g.add_color_stop_rgba(1.0, 0.0, 0.0, 0.0, 0.82);
                let _ = cr.set_source(&g);
                let _ = cr.paint();
            });
        }
        if let Some(url) = item.image.clone() {
            let a2 = area.clone();
            let surf2 = surf.clone();
            widgets::load_texture(&url, move |tex| {
                if let Some(t) = tex {
                    *surf2.borrow_mut() = texture_surface(&t);
                    a2.queue_draw();
                }
            });
        }
        // 움직임 줄이기를 켠 사람에게는 끝없이 흐르는 켄 번스를 돌리지 않는다
        if motion::enabled() {
            let a3 = area.clone();
            let t2 = t.clone();
            let target = adw::CallbackAnimationTarget::new(move |x| {
                t2.set(x);
                a3.queue_draw();
            });
            let anim = adw::TimedAnimation::new(&area, 0.0, 1.0, 22_000, target);
            anim.set_repeat_count(0);
            anim.set_alternate(true);
            anim.set_easing(adw::Easing::EaseInOutSine);
            adw::prelude::AnimationExt::play(&anim);
        }
        ov.set_child(Some(&area));
    } else {
        let plain = gtk::Box::new(gtk::Orientation::Vertical, 0);
        plain.add_css_class("dc-cover-plain");
        ov.set_child(Some(&plain));
    }
    let ink = if photo { Some("white") } else { None };
    let col = gtk::Box::new(gtk::Orientation::Vertical, 10);
    col.set_valign(gtk::Align::End);
    col.set_halign(gtk::Align::Fill);
    col.set_margin_top(30);
    col.set_margin_bottom(30);
    col.set_margin_start(30);
    col.set_margin_end(30);
    let meta = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let badge = gtk::Label::new(Some("표지"));
    badge.add_css_class("dc-badge");
    if photo {
        badge.add_css_class("dc-badge-photo");
    }
    meta.append(&badge);
    let topic = gtk::Box::new(gtk::Orientation::Horizontal, 4);
    topic.append(&widgets::icon(item.topic_icon(), 12));
    topic.append(&label(&item.topic_label(), 12.0, 600, &[]));
    meta.append(&topic);
    meta.append(&label(&format!("{} · {}", item.source_name, widgets::time_text(item)), 12.0, 400, &[]));
    col.append(&meta);
    let title = label(item.display_title(), 34.0, 700, &["dc-display"]);
    lines(&title, 3);
    col.append(&title);
    if item.title_ko.is_some() && item.title_ko.as_deref() != Some(item.title.as_str()) {
        let o = label(&item.title, 13.0, 400, &[]);
        o.set_opacity(0.7);
        lines(&o, 1);
        col.append(&o);
    }
    let buttons = gtk::Box::new(gtk::Orientation::Horizontal, 10);
    buttons.set_margin_top(4);
    let read = gtk::Button::new();
    read.add_css_class("dc-pill");
    read.add_css_class("suggested-action");
    let rb = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    rb.append(&widgets::icon("accessories-text-editor-symbolic", 13));
    rb.append(&label("기사 읽기", 13.0, 600, &[]));
    read.set_child(Some(&rb));
    {
        let it = item.clone();
        let o = ov.clone();
        read.connect_clicked(move |_| open_from_magazine(&it, origin_of(&o)));
    }
    buttons.append(&read);
    if let Some(c) = cluster.filter(|_| size >= 2) {
        let b = gtk::Button::new();
        b.add_css_class("dc-pill");
        let bb = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        bb.append(&widgets::icon("view-dual-symbolic", 13));
        bb.append(&label(&format!("여러 시각 {size}곳"), 13.0, 600, &[]));
        b.set_child(Some(&bb));
        b.connect_clicked(move |_| on_story(c.clone()));
        buttons.append(&b);
    }
    col.append(&buttons);
    if let Some(c) = ink {
        for w in [meta.upcast_ref::<gtk::Widget>(), title.upcast_ref(), buttons.upcast_ref()] {
            tint(w, c);
        }
        let prov = gtk::CssProvider::new();
        prov.load_from_string("label { text-shadow: 0 2px 8px alpha(black, 0.3); }");
        #[allow(deprecated)]
        title.style_context().add_provider(&prov, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION);
    }
    ov.add_overlay(&col);
    ov.upcast()
}
