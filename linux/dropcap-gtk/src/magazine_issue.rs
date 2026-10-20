// 한 호의 지면(맥 MagazineView.IssueView · Masthead · CoverStory · SectionBlock · MagSort).
use crate::ds::{font, space};
use crate::app::{bg, ui};
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
    Section(String), // 옆 목록의 분야: 오늘 호 기간의 그 분야 기사만(M-25)
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
    entries: RefCell<Vec<(NewsItem, gtk::Widget)>>, // 지면의 카드 순서(키보드 탐색, H-03)
    selected: RefCell<Option<String>>,
    today_done: Cell<bool>, // 오늘 호를 다 읽음(M-23) — 그날은 새 소식 띠를 띄우지 않는다
    progress: RefCell<Option<(gtk::Box, Vec<String>)>>, // 오늘 호 진행 막대와 대표 기사
    seq: RefCell<Vec<NewsItem>>, // 지면 기사 순서(읽기 창 J/K)
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
        let bb = gtk::Box::new(gtk::Orientation::Horizontal, space::S);
        bb.append(&widgets::icon("go-up-symbolic", 12));
        bb.append(&label("새 소식이 들어왔어요 · 새로 보기", font::BODY_STRONG, &[]));
        banner.set_child(Some(&bb));
        banner.set_halign(gtk::Align::Center);
        banner.set_valign(gtk::Align::Start);
        banner.set_margin_top(space::L);
        banner.set_visible(false);
        root.add_overlay(&banner);
        let me = Rc::new(IssuePage {
            root,
            scroll: scroll.clone(),
            content,
            banner: banner.clone(),
            focus: RefCell::new(focus),
            sub: RefCell::new(None),
            data: RefCell::new(None),
            pending_new: Cell::new(false),
            building: Cell::new(false),
            first: Cell::new(true),
            today_done: Cell::new(source == IssueSource::Today && dropcap_core::today_issue::is_marked_done(&ui().prefs.borrow(), chrono::Utc::now())),
            source,
            on_story,
            cards: Rc::new(RefCell::new(vec![])),
            entries: RefCell::new(vec![]),
            selected: RefCell::new(None),
            progress: RefCell::new(None),
            seq: RefCell::new(vec![]),
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
            // 오늘 호를 다 읽었으면 새 소식을 더 밀어 넣지 않는다(M-23)
            UiEvent::Magazine if self.source == IssueSource::Today && self.today_done.get() => {}
            UiEvent::State => self.update_progress(),
            UiEvent::Magazine if !self.is_fixed() => {
                let empty = self.data.borrow().as_ref().map(|d| d.r.cover.is_none() || d.r.issue.count == 0).unwrap_or(true);
                if empty || ui().core.preparing.load(std::sync::atomic::Ordering::SeqCst) {
                    self.rebuild(); // 빈 지면·표지 없음·첫 호 엮는 중이면 알림 없이 바로 채운다
                } else {
                    self.pending_new.set(true);
                    self.banner.set_visible(true);
                    widgets::fade_in(&self.banner, crate::motion::STANDARD);
                }
            }
            UiEvent::Images | UiEvent::Paywall => {
                if !self.pending_new.get() {
                    self.rebuild(); // 사진·자물쇠만 바뀌었으면 조용히 반영
                }
            }
            UiEvent::Layout => self.rebuild(), // 출처 숨기기·분야 바꾸기·저녁 정리는 바로
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
                    IssueSource::Section(id) => magazine::live_section(&core.db, &ed, &id),
                    IssueSource::Fixed(i) => i,
                };
                let r = magazine::resolve(&core.db, &issue, &ed.filter);
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

    fn section_id(&self) -> Option<&str> {
        match &self.source {
            IssueSource::Section(id) => Some(id.as_str()),
            _ => None,
        }
    }

    // 분야 칩으로 거른 지면(분야 지면에서는 AI 하위 칩만)
    fn shown(&self, d: &Built) -> Vec<(Section, Vec<NewsItem>)> {
        let sub = *self.sub.borrow();
        if self.section_id().is_some() {
            let Some(c) = sub else { return d.r.sections.clone() };
            return d
                .r
                .sections
                .iter()
                .filter_map(|(s, items)| {
                    let items: Vec<NewsItem> = items.iter().filter(|i| i.category() == c).cloned().collect();
                    (!items.is_empty()).then(|| (s.clone(), items))
                })
                .collect();
        }
        let Some(f) = self.focus.borrow().clone() else { return d.r.sections.clone() };
        d.r.sections
            .iter()
            .filter(|(s, _)| s.section.as_deref() == Some(f.as_str()))
            .filter_map(|(s, items)| {
                let items: Vec<NewsItem> = if f == dropcap_core::sections::AI && sub.is_some() { items.iter().filter(|i| Some(i.category()) == sub).cloned().collect() } else { items.clone() };
                (!items.is_empty()).then(|| (s.clone(), items))
            })
            .collect()
    }

    // 표지는 칩으로 거르지 않았을 때만(AI 하위 칩을 고르면 그 분류 기사만)
    fn shown_cover(&self, d: &Built) -> Option<dropcap_core::database::StoredItem> {
        if self.focus.borrow().is_some() {
            return None;
        }
        let c = d.r.cover.clone()?;
        match *self.sub.borrow() {
            Some(sub) if c.item.category() != sub => None,
            _ => Some(c),
        }
    }

    // 머리: 옆 목록에서 고른 것과 같은 이름, 숫자는 지면에 실린 것 기준(M-25)
    fn head_title(&self, d: &Built) -> String {
        match &self.source {
            IssueSource::Section(id) => dropcap_core::sections::name(id),
            IssueSource::Week => d.r.issue.title().replace("주간 · ", "이번 주 · "),
            _ => d.r.issue.title(),
        }
    }
    fn kicker(&self, d: &Built) -> String {
        match &self.source {
            IssueSource::Today => "오늘".into(),
            IssueSource::Week => "이번 주".into(),
            IssueSource::Section(_) => format!("오늘 호의 분야 지면 · {}", d.r.issue.title().replace(" 호", "")),
            IssueSource::Fixed(i) if i.is_thin() => "지난 호 · 기록 적음".into(),
            IssueSource::Fixed(_) => "지난 호".into(),
        }
    }
    fn subtitle(&self, d: &Built, pages: &[(Section, Vec<NewsItem>)]) -> String {
        let cover = self.shown_cover(d);
        if let Some(id) = self.section_id() {
            let shown: Vec<NewsItem> = cover.map(|c| c.item).into_iter().chain(pages.iter().flat_map(|(_, i)| i.clone())).collect();
            return magazine::section_subtitle(id, d.r.issue.count, &shown);
        }
        let n = cover.is_some() as i64 + pages.iter().map(|(_, i)| i.len() as i64).sum::<i64>();
        let head = magazine::subtitle(d.r.issue.count, n, pages.iter().filter(|(s, _)| s.kind.is_none()).count(), "소식");
        match &self.source {
            IssueSource::Fixed(i) => magazine::thin_reason(i).map(|why| format!("{head} · {why}")).unwrap_or(head),
            _ => head,
        }
    }

    fn render(self: &Rc<Self>) {
        let Some(d) = self.data.borrow().clone() else { return };
        widgets::clear_box(&self.content);
        self.cards.borrow_mut().clear();
        self.entries.borrow_mut().clear();
        *self.progress.borrow_mut() = None;
        let appeared = self.first.replace(false);
        let live = !self.is_fixed();
        let sort = MagSort::from_raw(&ui().prefs.borrow().mag_sort);
        let width = self.width() - 56;
        let pages: Vec<(Section, Vec<NewsItem>)> = self.shown(&d).into_iter().map(|(sec, items)| { let it = sort.apply(&items, &d.coverage); (sec, it) }).collect();
        let shown_cover = self.shown_cover(&d);
        let seq: Vec<NewsItem> = shown_cover.iter().map(|c| c.item.clone()).chain(pages.iter().flat_map(|(_, i)| i.clone())).collect();
        *self.seq.borrow_mut() = seq.clone();

        // 머리(M-06)
        let head = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        head.set_margin_top(space::XXL);
        head.set_margin_bottom(space::XL);
        head.set_margin_start(space::PAGE);
        head.set_margin_end(space::PAGE);
        head.append(&masthead(&self.head_title(&d), &self.kicker(&d), &self.subtitle(&d, &pages), live, appeared));
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
        // 오늘 호 대표 기사 진행(M-23): 머리 아래 작게, 다 읽으면 마무리 띠
        if self.source == IssueSource::Today && self.focus.borrow().is_none() {
            let keys = dropcap_core::today_issue::keys(d.r.cover.as_ref().map(|c| c.item.key()).as_deref(), &d.r.sections, &ui().core.chosen_sections());
            let holder = gtk::Box::new(gtk::Orientation::Vertical, 0);
            holder.set_margin_start(space::PAGE);
            holder.set_margin_end(space::PAGE);
            holder.set_margin_top(-8);
            holder.set_margin_bottom(space::L);
            self.content.append(&holder);
            *self.progress.borrow_mut() = Some((holder, keys));
            self.update_progress();
        }
        // 분야 칩 줄(G-09): 지면이 있는 분야(건수)
        let chips: Vec<String> = d.r.sections.iter().filter_map(|(s, _)| s.section.clone()).collect();
        if let Some(id) = self.section_id() {
            // 분야 지면: '전체'·다른 분야 칩 없이, AI 면 그 안의 하위 칩만(기타까지 — 칩 숫자의 합 = 실린 수)
            if id == dropcap_core::sections::AI {
                let all: Vec<NewsItem> = d.r.cover.iter().map(|c| c.item.clone()).chain(d.r.sections.iter().flat_map(|(_, i)| i.clone())).collect();
                let row = self.ai_sub_chips(&magazine::sub_chip_counts(&all));
                row.set_margin_start(space::PAGE);
                row.set_margin_end(space::PAGE);
                row.set_margin_bottom(space::L);
                self.content.append(&row);
            }
            if let Some(b) = ui().core.brief(id) {
                let bx = evening_brief_box(&b);
                bx.set_margin_start(space::PAGE);
                bx.set_margin_end(space::PAGE);
                bx.set_margin_bottom(space::L);
                self.content.append(&bx);
            }
        } else if self.source == IssueSource::Today && chips.len() > 1 {
            // 오늘 호의 분야 칩은 옆 목록의 분야 지면으로 간다(칩과 목록 선택이 늘 같게). 건수는 가는 곳과 달라 달지 않는다
            let bar = ChipBar::new(
                &chips,
                &HashMap::new(),
                None,
                None,
                Rc::new(move |f, _| {
                    if let Some(id) = f {
                        glib::idle_add_local_once(move || crate::magazine::open_section(&id));
                    }
                }),
            );
            bar.root.set_margin_start(space::PAGE);
            bar.root.set_margin_end(space::PAGE);
            bar.root.set_margin_bottom(space::L);
            self.content.append(&bar.root);
        } else if chips.len() > 1 || self.focus.borrow().is_some() {
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
            bar.root.set_margin_start(space::PAGE);
            bar.root.set_margin_end(space::PAGE);
            bar.root.set_margin_bottom(space::L);
            self.content.append(&bar.root);
        }
        // 표지(M-07) — 칩으로 분야만 보고 있으면 표지 없이 그 지면만
        let has_cover = shown_cover.is_some();
        {
            match &shown_cover {
                Some(c) => {
                    let cover = cover_story(&c.item, c.cluster.clone(), d.cover_size, self.on_story.clone(), seq.clone());
                    cover.set_margin_start(space::XXL);
                    cover.set_margin_end(space::XXL);
                    if appeared && motion::enabled() {
                        cover.set_opacity(0.0);
                        let c2 = cover.clone();
                        widgets::later(crate::motion::stagger(4), move || widgets::fade_in(&c2, crate::motion::SETTLE));
                    }
                    self.content.append(&cover);
                }
                None if pages.is_empty() => self.content.append(&empty_issue(live)),
                None => {}
            }
        }
        // 분야 지면(G-10). 읽기 창 J/K 순서 = 표지 + 지면 순서. 분야 지면은 머리가 이미 분야 이름이므로 유리 띠를 다시 달지 않는다
        let header = self.section_id().is_none();
        for (si, (sec, items)) in pages.into_iter().enumerate() {
            let block = self.section_block(&sec, &items, &d.r, width, &seq, header);
            block.set_margin_top(if si == 0 && !has_cover { space::S } else { space::XXXL });
            self.content.append(&block);
        }
        // 다시 그려도 고른 카드는 그대로
        let sel = self.selected.borrow().clone();
        if !self.entries.borrow().iter().any(|(it, _)| Some(it.key()) == sel) {
            *self.selected.borrow_mut() = None;
        }
        for (it, w) in self.entries.borrow().iter() {
            crate::keynav::mark(w, Some(it.key()) == *self.selected.borrow());
        }
        // 저작권 안내(M-22)
        let foot = label("기사 저작권은 각 언론사·기업에 있습니다. 제목·요약·사진은 원문으로 이어 주기 위한 것입니다.", font::CAPTION, &["dc-tertiary"]);
        foot.set_margin_start(space::PAGE);
        foot.set_margin_end(space::PAGE);
        foot.set_margin_top(space::XXXL);
        foot.set_margin_bottom(space::XXXL);
        self.content.append(&foot);
    }

    // AI 분야 지면의 하위 칩(맥 AISubChips): 실린 기사에 있는 분류만, 건수와 함께. 누르면 그 분류만, 다시 누르면 전부
    fn ai_sub_chips(self: &Rc<Self>, counts: &[(NewsCategory, usize)]) -> gtk::ScrolledWindow {
        let scroll = gtk::ScrolledWindow::builder().vscrollbar_policy(gtk::PolicyType::Never).hscrollbar_policy(gtk::PolicyType::Automatic).build();
        scroll.set_propagate_natural_height(true);
        let row = gtk::Box::new(gtk::Orientation::Horizontal, space::XS);
        let sub = *self.sub.borrow();
        for (c, n) in counts.iter().cloned() {
            let on = sub == Some(c);
            let b = crate::magazine_card::chip_button(c.label(), c.icon(), c.color(theme::is_dark()), on, Some(n), false);
            let weak = Rc::downgrade(self);
            b.connect_clicked(move |_| {
                if let Some(me) = weak.upgrade() {
                    *me.sub.borrow_mut() = if on { None } else { Some(c) };
                    let me2 = me.clone();
                    glib::idle_add_local_once(move || me2.render());
                }
            });
            row.append(&b);
        }
        scroll.set_child(Some(&row));
        scroll
    }

    fn section_block(self: &Rc<Self>, sec: &Section, items: &[NewsItem], r: &Resolved, width: i32, seq: &[NewsItem], header: bool) -> gtk::Box {
        let b = gtk::Box::new(gtk::Orientation::Vertical, space::L);
        if !header {
            self.append_cards(&b, items, r, width, seq);
            return b;
        }
        // 분야 지면: 분야 고르기와 같은 유리 띠(오늘의 사진 · 기사 수 · 첫 기사 제목)
        if let (Some(ns), None) = (sec.section.as_deref().and_then(dropcap_core::sections::by_id), &sec.kind) {
            let sub = format!("{}건 · {}", items.len(), items.first().map(|i| i.display_title()).unwrap_or(""));
            let card = crate::section_photos::glass_card(&ns, Some(sub), 92, false, false);
            card.area.set_margin_start(space::XXL);
            card.area.set_margin_end(space::XXL);
            b.append(&card.area);
            crate::section_photos::load();
            self.append_cards(&b, items, r, width, seq);
            return b;
        }
        let head = gtk::Box::new(gtk::Orientation::Horizontal, space::S);
        head.set_margin_start(space::PAGE);
        head.set_margin_end(space::PAGE);
        let i = widgets::icon(sec.icon(), 18);
        tint(&i, &sec.color(theme::is_dark()));
        head.append(&i);
        head.append(&label(&sec.label(), font::HEADING, &["dc-display"]));
        head.append(&label(&items.len().to_string(), font::BODY_STRONG, &["dc-secondary"]));
        let line = gtk::Separator::new(gtk::Orientation::Horizontal);
        line.set_hexpand(true);
        line.set_valign(gtk::Align::Center);
        line.set_margin_start(space::S);
        head.append(&line);
        b.append(&head);
        self.append_cards(&b, items, r, width, seq);
        b
    }

    fn append_cards(self: &Rc<Self>, b: &gtk::Box, items: &[NewsItem], r: &Resolved, width: i32, seq: &[NewsItem]) {
        let flow = gtk::FlowBox::new();
        flow.set_selection_mode(gtk::SelectionMode::None);
        flow.set_homogeneous(true);
        flow.set_column_spacing(space::L as u32);
        flow.set_row_spacing(space::XL as u32);
        flow.set_margin_start(space::XXL);
        flow.set_margin_end(space::XXL);
        // 마지막 줄에 카드 한 장만 남지 않게 칸 수를 고른다(맥 BalancedGrid)
        let fit = ((width + 18) / (230 + 18)).max(1) as usize;
        let cols = balanced_columns(fit.min(4), items.len());
        flow.set_min_children_per_line(cols as u32);
        flow.set_max_children_per_line(cols as u32);
        for (n, it) in items.iter().enumerate() {
            let cluster = r.clusters.get(&it.key()).cloned();
            let story_items = cluster.as_ref().and_then(|c| r.regions.get(c)).cloned().unwrap_or_default();
            let card = StoryCard::build(it, n, cluster, &story_items, Some(self.on_story.clone()), seq);
            self.cards.borrow_mut().push(card.clone());
            self.entries.borrow_mut().push((it.clone(), card.clone()));
            flow.insert(&card, -1);
        }
        b.append(&flow);
    }

    // 오늘 호 진행 막대·마무리 띠 다시 그리기(읽음이 바뀔 때마다)
    fn update_progress(&self) {
        let Some((holder, keys)) = self.progress.borrow().clone() else { return };
        widgets::clear_box(&holder);
        let core = ui().core.clone();
        let st = core.state();
        let read = keys.iter().filter(|k| st.read.contains_key(*k)).count();
        let now = chrono::Utc::now();
        if !keys.is_empty() && read >= keys.len() && !self.today_done.get() {
            ui().update_prefs(|p| dropcap_core::today_issue::mark_done(p, now));
            self.today_done.set(true);
            self.pending_new.set(false);
            self.banner.set_visible(false);
        }
        if self.today_done.get() {
            let band = gtk::Box::new(gtk::Orientation::Horizontal, space::M);
            band.add_css_class("dc-done-band");
            let i = widgets::icon("object-select-symbolic", 22);
            tint(&i, "#34C759");
            band.append(&i);
            let v = gtk::Box::new(gtk::Orientation::Vertical, space::XS);
            v.append(&label("오늘 호를 다 읽었어요", font::SUBHEADING, &["dc-display"]));
            v.append(&label(&dropcap_core::today_issue::next_issue_text(st.settings.digest_enabled, st.settings.digest_hour), font::CALLOUT, &["dc-secondary"]));
            band.append(&v);
            holder.append(&band);
            widgets::fade_in(&band, crate::motion::STANDARD);
        } else if !keys.is_empty() {
            let row = gtk::Box::new(gtk::Orientation::Horizontal, space::M);
            let t = label(&format!("오늘 호 대표 기사 {read}/{}", keys.len()), font::CAPTION, &["dc-secondary", "numeric"]);
            t.set_wrap(false);
            row.append(&t);
            let bar = gtk::ProgressBar::new();
            bar.add_css_class("dc-progress");
            bar.set_fraction(read as f64 / keys.len().max(1) as f64);
            bar.set_size_request(120, -1);
            bar.set_valign(gtk::Align::Center);
            row.append(&bar);
            row.set_tooltip_text(Some("표지와 주요 뉴스·고른 분야의 첫 줄을 다 읽으면 오늘 호가 끝납니다"));
            holder.append(&row);
        }
    }

    // 지면 카드 키보드 탐색(H-03): ↓/J·↑/K 고르기, ⏎ 열기, S·O·M
    pub fn key_nav(&self, k: crate::keynav::NavKey) {
        use crate::keynav::NavKey;
        let keys: Vec<String> = self.entries.borrow().iter().map(|(it, _)| it.key()).collect();
        let sel = self.selected.borrow().clone();
        match k {
            NavKey::Next | NavKey::Prev => {
                let next = crate::keynav::step(sel.as_deref(), &keys, if k == NavKey::Next { 1 } else { -1 });
                *self.selected.borrow_mut() = next.clone();
                for (it, w) in self.entries.borrow().iter() {
                    crate::keynav::mark(w, Some(it.key()) == next);
                }
                if let Some((_, w)) = self.entries.borrow().iter().find(|(it, _)| Some(it.key()) == next) {
                    crate::keynav::center(&self.scroll, w);
                }
            }
            _ => {
                let Some(item) = self.entries.borrow().iter().find(|(it, _)| Some(it.key()) == sel).map(|(it, _)| it.clone()) else { return };
                crate::keynav::perform(k, &item, &self.seq.borrow(), true);
            }
        }
    }
}

// 분야 지면 위: 저녁 정리(N-26). 기기 안 요약임을 밝히고, 줄마다 근거 기사 번호, 아래에 근거 기사 원제목·링크
fn evening_brief_box(b: &dropcap_core::brief::SectionBrief) -> gtk::Box {
    let v = gtk::Box::new(gtk::Orientation::Vertical, space::M);
    v.add_css_class("dc-brief-box");
    let head = gtk::Box::new(gtk::Orientation::Horizontal, space::S);
    let moon = widgets::icon("weather-clear-night-symbolic", 16);
    tint(&moon, &dropcap_core::sections::by_id(&b.section).map(|s| s.color.clone()).unwrap_or_else(|| "#5856D6".into()));
    head.append(&moon);
    let t = label(&format!("저녁 정리 · {}", dropcap_core::sections::name(&b.section)), font::SUBHEADING, &["dc-display"]);
    t.set_wrap(false);
    head.append(&t);
    let at = b.at.with_timezone(&chrono::Local);
    let (pm, h) = chrono::Timelike::hour12(&at);
    let tl = label(&format!("{} {}:{:02}", if pm { "오후" } else { "오전" }, h, chrono::Timelike::minute(&at)), font::CAPTION, &["dc-tertiary"]);
    tl.set_wrap(false);
    head.append(&tl);
    let sp = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    sp.set_hexpand(true);
    head.append(&sp);
    let note = label("기기 안 요약 · 원문을 확인하세요", font::CAPTION, &["dc-secondary"]);
    note.set_wrap(false);
    note.set_tooltip_text(Some("이 컴퓨터의 Ollama 가 아래 기사들의 제목·요약만 보고 만든 정리입니다. 틀릴 수 있어 근거 기사를 함께 둡니다."));
    head.append(&note);
    v.append(&head);
    for line in b.lines.clone().unwrap_or_default() {
        let row = gtk::Box::new(gtk::Orientation::Horizontal, space::S);
        let dot = label("•", (14.0, 400), &["dc-secondary"]);
        dot.set_valign(gtk::Align::Start);
        row.append(&dot);
        // 문장 바로 뒤에 근거 번호(맥과 같이)
        let refs: String = line.refs.iter().map(|r| format!("[{}]", r + 1)).collect();
        let l = gtk::Label::new(None);
        l.set_markup(&format!("<span font='14px'>{}</span>  <span font='11px' weight='600' alpha='60%'>{}</span>", gtk::glib::markup_escape_text(&line.text), refs));
        l.set_xalign(0.0);
        l.set_wrap(true);
        l.set_hexpand(true);
        row.append(&l);
        v.append(&row);
    }
    v.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
    let list = gtk::Box::new(gtk::Orientation::Vertical, space::XS);
    for (i, it) in b.items.iter().enumerate() {
        let row = gtk::Box::new(gtk::Orientation::Horizontal, space::S);
        let n = label(&format!("[{}]", i + 1), font::CHIP, &["dc-secondary", "numeric"]);
        n.set_wrap(false);
        row.append(&n);
        let t = label(&it.title, font::CALLOUT, &[]); // 원제목 그대로
        t.set_wrap(false);
        t.set_ellipsize(gtk::pango::EllipsizeMode::End);
        row.append(&t);
        let s = label(&format!("— {}", it.source_name), font::CAPTION, &["dc-secondary"]);
        s.set_wrap(false);
        row.append(&s);
        let btn = gtk::Button::builder().child(&row).css_classes(["flat"]).tooltip_text(it.link.as_str()).build();
        let (item, seq) = (it.clone(), b.items.clone());
        btn.connect_clicked(move |w| crate::app::open_from_magazine_in(&item, origin_of(w), seq.clone()));
        list.append(&btn);
    }
    v.append(&list);
    v
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
fn masthead(title_text: &str, kicker: &str, subtitle: &str, live: bool, appeared: bool) -> gtk::Box {
    let v = gtk::Box::new(gtk::Orientation::Vertical, space::S);
    v.set_hexpand(true);
    let top = gtk::Box::new(gtk::Orientation::Horizontal, space::S);
    let logo = gtk::Label::new(None);
    logo.set_markup("<span font_family='serif' weight='heavy' size='22pt'>D</span><span font_family='serif' weight='heavy' size='13pt' letter_spacing='2200'>ROPCAP</span>");
    logo.set_valign(gtk::Align::Baseline);
    top.append(&logo);
    top.append(&label(crate::strings::MAGAZINE, font::CAPTION, &["dc-secondary"]));
    if !kicker.is_empty() {
        top.append(&label(&format!("· {kicker}"), font::CAPTION, &["dc-secondary"]));
    }
    if live {
        let l = gtk::Label::new(Some("발행 중"));
        l.add_css_class("dc-live");
        l.set_valign(gtk::Align::Center);
        top.append(&l);
    }
    v.append(&top);
    let title = label(title_text, font::HERO, &["dc-display"]);
    v.append(&title);
    v.append(&label(subtitle, font::BODY, &["dc-secondary"]));
    // 줄이 그어지며 나타남
    let progress = Rc::new(Cell::new(if appeared && motion::enabled() { 0.0 } else { 1.0 }));
    let line = gtk::DrawingArea::builder().content_height(2).hexpand(true).build();
    line.set_margin_top(space::M);
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
        let a = adw::TimedAnimation::new(&line, 0.0, 1.0, crate::motion::SETTLE, target);
        a.set_easing(crate::motion::ENTER);
        widgets::later(crate::motion::stagger(3), move || adw::prelude::AnimationExt::play(&a));
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
    let v = gtk::Box::new(gtk::Orientation::Vertical, space::S);
    v.set_margin_start(space::PAGE);
    v.set_margin_top(60);
    v.set_margin_bottom(60);
    if ui().core.preparing.load(std::sync::atomic::Ordering::SeqCst) {
        let sp = gtk::Spinner::new();
        sp.start();
        sp.set_halign(gtk::Align::Start);
        v.append(&sp);
        v.append(&label("첫 호를 엮는 중…", font::HEADING, &["dc-display"]));
        v.append(&label("구독한 출처에서 최근 일주일 소식을 모으고 번역하고 있어요. 잠시면 됩니다.", font::BODY, &["dc-secondary"]));
    } else {
        let i = widgets::icon("x-office-document-symbolic", 34);
        i.set_halign(gtk::Align::Start);
        i.add_css_class("dc-tertiary");
        v.append(&i);
        v.append(&label(if live { "아직 이번 호에 실을 소식이 없습니다" } else { "이 호에는 소식이 없습니다" }, font::HEADING, &["dc-display"]));
        v.append(&label("새 소식이 들어오는 대로 지면이 채워집니다.", font::BODY, &["dc-secondary"]));
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
fn cover_story(item: &NewsItem, cluster: Option<String>, size: i64, on_story: Rc<dyn Fn(String)>, seq: Vec<NewsItem>) -> gtk::Widget {
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
    let col = gtk::Box::new(gtk::Orientation::Vertical, space::M);
    col.set_valign(gtk::Align::End);
    col.set_halign(gtk::Align::Fill);
    col.set_margin_top(space::XXL);
    col.set_margin_bottom(space::XXL);
    col.set_margin_start(space::XXL);
    col.set_margin_end(space::XXL);
    let meta = gtk::Box::new(gtk::Orientation::Horizontal, space::S);
    let badge = gtk::Label::new(Some("표지"));
    badge.add_css_class("dc-badge");
    if photo {
        badge.add_css_class("dc-badge-photo");
    }
    meta.append(&badge);
    let topic = gtk::Box::new(gtk::Orientation::Horizontal, space::XS);
    topic.append(&widgets::icon(item.topic_icon(), 12));
    topic.append(&label(&item.topic_label(), font::CHIP, &[]));
    meta.append(&topic);
    meta.append(&label(&format!("{} · {}", item.source_name, widgets::time_text(item)), font::CALLOUT, &[]));
    if let Some(p) = widgets::paywall_mark(item) {
        meta.append(&p);
    }
    col.append(&meta);
    let title = label(item.display_title(), font::TITLE, &["dc-display"]);
    lines(&title, 3);
    col.append(&title);
    if item.title_ko.is_some() && item.title_ko.as_deref() != Some(item.title.as_str()) {
        let o = label(&item.title, font::BODY, &[]);
        o.set_opacity(0.7);
        lines(&o, 1);
        col.append(&o);
    }
    let buttons = gtk::Box::new(gtk::Orientation::Horizontal, space::M);
    buttons.set_margin_top(space::XS);
    let read = gtk::Button::new();
    read.add_css_class("dc-pill");
    read.add_css_class("suggested-action");
    let rb = gtk::Box::new(gtk::Orientation::Horizontal, space::S);
    rb.append(&widgets::icon("accessories-text-editor-symbolic", 13));
    rb.append(&label("기사 읽기", font::BODY_STRONG, &[]));
    read.set_child(Some(&rb));
    {
        let it = item.clone();
        let o = ov.clone();
        read.connect_clicked(move |_| crate::app::open_from_magazine_in(&it, origin_of(&o), seq.clone()));
    }
    buttons.append(&read);
    if let Some(c) = cluster.filter(|_| size >= 2) {
        let b = gtk::Button::new();
        b.add_css_class("dc-pill");
        let bb = gtk::Box::new(gtk::Orientation::Horizontal, space::S);
        bb.append(&widgets::icon("view-dual-symbolic", 13));
        bb.append(&label(&format!("여러 시각 {size}곳"), font::BODY_STRONG, &[]));
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
