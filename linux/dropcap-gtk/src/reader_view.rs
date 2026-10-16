// 읽기 창 화면(맥 Reader/ReaderView.swift): 표지 사진·머리·3줄 요약·본문 블록·문단 스크랩·실패 화면·자리표시.
// 진행 상황은 핵심 ArticleService 가 tokio 스레드에서 알려 주고, 채널로 메인 루프에 넘겨 그린다.
use crate::app::{bg, copy_text, open_external, ui};
use crate::reader::Origin;
use crate::reader_find;
use crate::reader_image;
use crate::reader_speech::{self, Speaker};
use crate::widgets::{self, load_texture, monogram};
use crate::{motion, theme};
use adw::prelude::*;
use chrono::{Datelike, Local, Timelike};
use dropcap_core::app_model::UiEvent;
use dropcap_core::article::{self, body_cleanup, image_key, Block, BlockKind, PreparedArticle, Stage};
use dropcap_core::cover_pick;
use dropcap_core::models::{resources, NewsItem};
use dropcap_core::paywall::{self, PaywallKind};
use dropcap_core::translator::looks_foreign;
use gtk::{gdk, gio, glib, pango};
use std::cell::{Cell, RefCell};
use std::rc::{Rc, Weak};

pub const FONT_MIN: f64 = 13.0;
pub const FONT_MAX: f64 = 26.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Phase {
    Loading,
    Translating,
    Done,
    Failed,
}

#[derive(Debug, Clone)]
struct Model {
    phase: Phase,
    title: String,
    original_title: String,
    blocks: Vec<Block>,
    translated: bool,
    show_original: bool,
    summary: String,                 // 본문을 못 추렸을 때
    key_points: Option<Vec<String>>, // 3줄 요약
    summarizing: bool,
    engine: String,
    cover: Option<String>, // 표지 사진(피드 → 매거진 기록 → 기사 머리 대표 사진)
    paywalled: bool,                // 맛보기만 나옴(유료벽 뒤, G-14)
    partial: bool,                  // 본문 일부만 가져왔을 수 있음(READER-CUT.md A)
    paywall: Option<PaywallKind>,   // 출처가 유료로 알려졌거나 자주 막히는 곳
    alternatives: Vec<NewsItem>,    // 같은 스토리의 무료 보도(G-15)
    open_originals: std::collections::HashSet<usize>, // 원문을 펼친 문단(번역 보기에서 문단마다, 블록 번호)
}

impl Model {
    fn new(item: &NewsItem) -> Model {
        Model {
            phase: Phase::Loading,
            title: item.display_title().to_string(),
            original_title: item.title.clone(),
            blocks: vec![],
            translated: false,
            show_original: false,
            summary: String::new(),
            key_points: None,
            summarizing: false,
            engine: String::new(),
            cover: None,
            paywalled: false,
            partial: false,
            paywall: None,
            alternatives: vec![],
            open_originals: Default::default(),
        }
    }
}

// 스크랩할 수 있는 문단 줄
struct Row {
    content: gtk::Widget,
    button: gtk::Button,
    label: Option<gtk::Label>,
    text: String,
    original: Option<String>,
}

pub struct ReaderWindow {
    item: RefCell<NewsItem>,
    sequence: Vec<NewsItem>, // 이 기사를 연 목록(J/K 로 다음·이전, H-05)
    accent: RefCell<String>,
    win: adw::ApplicationWindow,
    toasts: adw::ToastOverlay,
    scroller: gtk::ScrolledWindow,
    column: gtk::Box,
    model: RefCell<Model>,
    rows: RefCell<Vec<Row>>,
    speaker: Speaker,
    observe: Cell<Option<u64>>,
    alive: Cell<bool>,
    // 도구 막대
    mode_box: gtk::Box,
    mode_original: gtk::ToggleButton,
    speak_btn: gtk::Button,
    save_btn: gtk::Button,
    reload_btn: gtk::Button,
    scrap_btn: adw::SplitButton,
    // 기사 안 찾기
    find_bar: gtk::SearchBar,
    find_entry: gtk::SearchEntry,
    find_count: gtk::Label,
    find_index: Cell<usize>,
    title_label: RefCell<Option<gtk::Label>>,
    base_attrs: RefCell<std::collections::HashMap<usize, pango::AttrList>>,
}

// "10월 13일 오후 3:05"
pub fn date_text(d: chrono::DateTime<chrono::Utc>) -> String {
    let l = d.with_timezone(&Local);
    let (pm, h) = l.hour12();
    format!("{}월 {}일 {} {}:{:02}", l.month(), l.day(), if pm { "오후" } else { "오전" }, h, l.minute())
}

// 글자 하나에 크기·굵기·줄 간격·기울임·고정폭
fn text(t: &str, size: f64, weight: u16, line: f64, italic: bool, mono: bool) -> gtk::Label {
    let l = gtk::Label::new(Some(t));
    l.set_xalign(0.0);
    l.set_wrap(true);
    l.set_wrap_mode(pango::WrapMode::WordChar);
    l.set_selectable(true);
    l.set_can_focus(false);
    let attrs = pango::AttrList::new();
    attrs.insert(pango::AttrSize::new_size_absolute((size * pango::SCALE as f64) as i32));
    attrs.insert(pango::AttrInt::new_weight(widgets::weight_of(weight)));
    if line > 0.0 {
        attrs.insert(pango::AttrFloat::new_line_height(line));
    }
    if italic {
        attrs.insert(pango::AttrInt::new_style(pango::Style::Italic));
    }
    if mono {
        attrs.insert(pango::AttrString::new_family("monospace"));
    }
    l.set_attributes(Some(&attrs));
    l
}

// 위젯 하나에만 거는 CSS
fn style(w: &impl IsA<gtk::Widget>, css: &str) {
    let p = gtk::CssProvider::new();
    p.load_from_string(&format!("* {{ {css} }}"));
    #[allow(deprecated)]
    w.as_ref().style_context().add_provider(&p, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION);
}

fn rgb(hex: &str) -> (u8, u8, u8) {
    let (r, g, b) = dropcap_core::models::hex_rgb(hex);
    ((r * 255.0) as u8, (g * 255.0) as u8, (b * 255.0) as u8)
}

fn icon_label_button(icon: &str, tip: &str) -> gtk::Button {
    let b = gtk::Button::from_icon_name(icon);
    b.set_tooltip_text(Some(tip));
    b.add_css_class("flat");
    b
}

impl ReaderWindow {
    pub fn new(item: NewsItem, others: usize, sequence: Vec<NewsItem>) -> Rc<ReaderWindow> {
        let app_ui = ui();
        let accent = widgets::source_color(&item.source_id);
        let win = adw::ApplicationWindow::builder()
            .application(&app_ui.app)
            .title(item.source_name.as_str())
            .default_width(760)
            .default_height(860)
            .width_request(460)
            .height_request(400)
            .build();
        // 여러 창은 비켜서(창 위치는 창 관리자가 정해 크기만 조금씩 달리 — R-14 ~)
        if others > 0 {
            win.set_default_size(760 - (others as i32 % 6) * 24, 860 - (others as i32 % 6) * 24);
        }
        let header = adw::HeaderBar::new();

        // 번역/원문
        let mode_box = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        mode_box.add_css_class("linked");
        let mode_translated = gtk::ToggleButton::with_label("번역");
        let mode_original = gtk::ToggleButton::with_label("원문");
        mode_original.set_group(Some(&mode_translated));
        mode_translated.set_active(true);
        mode_box.append(&mode_translated);
        mode_box.append(&mode_original);
        mode_box.set_tooltip_text(Some("번역과 원문 바꿔 보기"));
        mode_box.set_visible(false);
        header.pack_start(&mode_box);

        let size_box = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        size_box.add_css_class("linked");
        let smaller = icon_label_button("zoom-out-symbolic", "글자 작게 (Ctrl+-)");
        let larger = icon_label_button("zoom-in-symbolic", "글자 크게 (Ctrl+=)");
        smaller.remove_css_class("flat");
        larger.remove_css_class("flat");
        size_box.append(&smaller);
        size_box.append(&larger);
        size_box.set_tooltip_text(Some("글자 크기 (Ctrl+- / Ctrl+=)"));
        header.pack_start(&size_box);

        let share_btn = icon_label_button("send-to-symbolic", "링크 복사(공유)");
        let browser_btn = icon_label_button("web-browser-symbolic", "원문을 브라우저에서 열기");
        let save_btn = icon_label_button("bookmark-new-symbolic", "나중에 읽기로 저장");
        let scrap_btn = adw::SplitButton::builder().icon_name("edit-cut-symbolic").tooltip_text("기사 스크랩 (누르면 마지막 폴더에, 화살표로 폴더 고르기)").build();
        let speak_btn = icon_label_button("audio-speakers-symbolic", "소리 내어 읽기");
        speak_btn.set_visible(reader_speech::available());
        let reload_btn = icon_label_button("view-refresh-symbolic", "다시 받기 — 저장한 본문을 지우고 원문에서 다시 받기");
        header.pack_end(&share_btn);
        header.pack_end(&reload_btn);
        header.pack_end(&browser_btn);
        header.pack_end(&save_btn);
        header.pack_end(&scrap_btn);
        header.pack_end(&speak_btn);

        let column = gtk::Box::new(gtk::Orientation::Vertical, 0);
        column.set_margin_top(20);
        column.set_margin_bottom(80);
        column.set_margin_end(36);
        column.set_margin_start(0);
        let clamp = adw::Clamp::builder().maximum_size(660 + 38 + 36).tightening_threshold(500).child(&column).build();
        let scroller = gtk::ScrolledWindow::builder().hscrollbar_policy(gtk::PolicyType::Never).child(&clamp).vexpand(true).build();
        let toasts = adw::ToastOverlay::new();
        toasts.set_child(Some(&scroller));
        let tv = adw::ToolbarView::new();
        tv.add_top_bar(&header);
        // 찾기 막대(Ctrl+F): 입력 · n/m · 이전 · 다음
        let find_entry = gtk::SearchEntry::builder().placeholder_text("기사 안에서 찾기").width_chars(24).build();
        let find_count = gtk::Label::new(None);
        find_count.add_css_class("dc-secondary");
        find_count.set_width_chars(6);
        let find_prev = gtk::Button::builder().icon_name("go-up-symbolic").tooltip_text("이전 (Shift+Ctrl+G)").css_classes(["flat"]).build();
        let find_next = gtk::Button::builder().icon_name("go-down-symbolic").tooltip_text("다음 (Ctrl+G)").css_classes(["flat"]).build();
        let find_row = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        find_row.append(&find_entry);
        find_row.append(&find_count);
        find_row.append(&find_prev);
        find_row.append(&find_next);
        let find_bar = gtk::SearchBar::builder().child(&find_row).show_close_button(true).build();
        find_bar.connect_entry(&find_entry);
        tv.add_top_bar(&find_bar);
        tv.set_content(Some(&toasts));
        win.set_content(Some(&tv));
        // 바탕은 글 읽는 흰 바탕(맥 textBackgroundColor)
        style(&scroller, "background-color: @view_bg_color;");

        let me = Rc::new(ReaderWindow {
            accent: RefCell::new(accent),
            model: RefCell::new(Model::new(&item)),
            item: RefCell::new(item),
            sequence,
            win,
            toasts,
            scroller,
            column,
            rows: RefCell::new(vec![]),
            speaker: Speaker::new(),
            observe: Cell::new(None),
            alive: Cell::new(true),
            mode_box,
            mode_original,
            speak_btn,
            save_btn,
            reload_btn,
            scrap_btn,
            find_bar,
            find_entry,
            find_count,
            find_index: Cell::new(0),
            title_label: RefCell::new(None),
            base_attrs: RefCell::new(std::collections::HashMap::new()),
        });

        // 연결
        let w = Rc::downgrade(&me);
        me.mode_original.connect_toggled(move |b| {
            if let Some(me) = w.upgrade() {
                me.model.borrow_mut().show_original = b.is_active();
                me.speaker.stop();
                me.update_speak();
                me.render();
            }
        });
        let w = Rc::downgrade(&me);
        smaller.connect_clicked(move |_| {
            if let Some(me) = w.upgrade() {
                me.change_font(-1.0)
            }
        });
        let w = Rc::downgrade(&me);
        larger.connect_clicked(move |_| {
            if let Some(me) = w.upgrade() {
                me.change_font(1.0)
            }
        });
        let w = Rc::downgrade(&me);
        me.speak_btn.connect_clicked(move |_| {
            if let Some(me) = w.upgrade() {
                me.toggle_speak()
            }
        });
        let w = Rc::downgrade(&me);
        me.save_btn.connect_clicked(move |_| {
            if let Some(me) = w.upgrade() {
                ui().core.toggle_saved(&me.item());
                me.update_tools();
            }
        });
        let w = Rc::downgrade(&me);
        me.find_entry.connect_search_changed(move |_| {
            if let Some(me) = w.upgrade() {
                me.find_index.set(0);
                me.update_find(true);
            }
        });
        let w = Rc::downgrade(&me);
        me.find_entry.connect_activate(move |_| {
            if let Some(me) = w.upgrade() {
                me.find_step(true);
            }
        });
        let w = Rc::downgrade(&me);
        find_next.connect_clicked(move |_| {
            if let Some(me) = w.upgrade() {
                me.find_step(true);
            }
        });
        let w = Rc::downgrade(&me);
        find_prev.connect_clicked(move |_| {
            if let Some(me) = w.upgrade() {
                me.find_step(false);
            }
        });
        let w = Rc::downgrade(&me);
        me.find_bar.connect_search_mode_enabled_notify(move |b| {
            if let Some(me) = w.upgrade() {
                if !b.is_search_mode() {
                    me.find_entry.set_text("");
                }
                me.update_find(false);
            }
        });
        let w = Rc::downgrade(&me);
        me.reload_btn.connect_clicked(move |_| {
            if let Some(me) = w.upgrade() {
                me.reload();
            }
        });
        let w = Rc::downgrade(&me);
        browser_btn.connect_clicked(move |_| {
            if let Some(me) = w.upgrade() {
                open_external(&me.item().link);
            }
        });
        let w = Rc::downgrade(&me);
        share_btn.connect_clicked(move |_| {
            if let Some(me) = w.upgrade() {
                me.copy_link();
            }
        });
        // 주소가 이상하면 공유 단추를 숨김(맥 A-37)
        share_btn.set_visible(dropcap_core::url_safety::external_link(&me.item().link).is_some());
        let w = Rc::downgrade(&me);
        me.scrap_btn.connect_clicked(move |_| {
            if let Some(me) = w.upgrade() {
                me.scrap_article(None);
            }
        });
        me.install_actions();
        me.install_shortcuts();
        me.rebuild_scrap_menu();
        me.update_tools();

        // 다른 창(매거진 등)에서 저장·스크랩이 바뀌면 단추 모양을 맞춘다
        let w = Rc::downgrade(&me);
        app_ui.listen(move |e| {
            if let (UiEvent::State, Some(me)) = (e, w.upgrade()) {
                if me.alive.get() {
                    me.update_tools();
                }
            }
        });
        me.render();
        me
    }

    pub fn window(&self) -> &adw::ApplicationWindow {
        &self.win
    }

    fn item(&self) -> std::cell::Ref<'_, NewsItem> {
        self.item.borrow()
    }

    fn accent(&self) -> String {
        self.accent.borrow().clone()
    }

    // 같은 창에서 연 목록의 다음·이전 기사로(H-05 · 맥 ReaderController.step): 영상·팟캐스트는 건너뛰고, 끝이면 경고음
    pub fn step(self: &Rc<Self>, d: i64) {
        let list: Vec<&NewsItem> = self.sequence.iter().filter(|i| !i.item_kind().opens_externally()).collect();
        let key = self.item().key();
        let next = list
            .iter()
            .position(|i| i.key() == key)
            .map(|i| i as i64 + d)
            .filter(|j| *j >= 0 && (*j as usize) < list.len())
            .map(|j| list[j as usize].clone());
        let Some(next) = next else {
            self.win.error_bell();
            return;
        };
        ui().core.mark_opened(&next);
        // 지금 기사의 관찰·소리를 끊고 내용만 바꿔 끼운다
        self.speaker.stop();
        if let Some(id) = self.observe.take() {
            ui().core.articles.stop_observing(&self.item().link, id);
        }
        *self.accent.borrow_mut() = widgets::source_color(&next.source_id);
        *self.model.borrow_mut() = Model::new(&next);
        self.win.set_title(Some(&next.source_name));
        *self.item.borrow_mut() = next;
        self.mode_original.set_active(false);
        self.mode_box.set_visible(false);
        self.find_bar.set_search_mode(false);
        self.update_tools();
        self.update_speak();
        self.render();
        self.scroller.vadjustment().set_value(0.0);
        self.load();
    }

    // 누른 카드 자리에서 커져 나온다(R-14). GTK4 는 창 위치·크기를 앱이 움직일 수 없어
    // 0.38초 동안 창이 옅은 데서 또렷해지며 내용이 살짝 커지는 것으로 대신한다.
    pub fn present(&self, from: Option<Origin>) {
        let animate = from.map(|o| o.w > 10.0).unwrap_or(false) && motion::enabled();
        if !animate {
            self.win.present();
            return;
        }
        self.win.set_opacity(0.2);
        self.win.present();
        let target = adw::CallbackAnimationTarget::new({
            let win = self.win.clone();
            move |v| win.set_opacity(v)
        });
        let a = adw::TimedAnimation::new(&self.win, 0.2, 1.0, 380, target);
        a.set_easing(adw::Easing::EaseOutQuint);
        adw::prelude::AnimationExt::play(&a);
    }

    pub fn closed(&self) {
        self.alive.set(false);
        self.speaker.stop();
        if let Some(id) = self.observe.take() {
            ui().core.articles.stop_observing(&self.item().link, id);
        }
    }

    // MARK: 불러오기
    // 기사 주소 복사(Ctrl+Shift+C · 공유 단추)
    fn copy_link(&self) {
        if let Some(u) = dropcap_core::url_safety::external_link(&self.item().link) {
            copy_text(&u);
            self.flash("기사 주소를 복사했어요");
        }
    }

    // 상단바 목록의 기사 정보에는 대표 사진이 비어 있을 수 있다(매거진만 기사 머리에서 찾아 둠).
    // 그때 본문의 첫 그림(기자 프로필 등)을 표지로 쓰던 문제가 있어, 대표 사진을 먼저 찾는다(맥 ReaderModel.findCover).
    // 피드 사진이 작은 미리보기(가로 400px 미만)거나 받지 못하면 기사 머리 대표 사진(og:image)으로 바꾸고,
    // 대신할 것도 없으면 깨진 자리를 지운다(R-22 · cover_pick::choose)
    fn find_cover(self: &Rc<Self>) {
        let junk = |u: &str| image_key::is_junk(Some(u));
        let known = self.item().image.clone().filter(|i| !junk(i)).or_else(|| ui().core.db.image(&self.item().key()).filter(|i| !junk(i)));
        if let Some(k) = &known {
            self.model.borrow_mut().cover = Some(k.clone());
        }
        let key = self.item().key();
        let link = self.item().link.clone();
        let w = Rc::downgrade(self);
        let then = move |known: Option<String>, known_width: Option<u32>| {
            if !cover_pick::needs_og(known.as_deref(), known_width) {
                return;
            }
            let decide = move |og: Option<String>, og_width: Option<u32>| {
                let Some(me) = w.upgrade() else { return };
                if !me.alive.get() || me.item().key() != key {
                    return; // J/K 로 다른 기사로 바뀜
                }
                let choice = cover_pick::choose(known.as_deref(), known_width, og.as_deref(), og_width, |u| image_key::is_junk(Some(u)));
                let next = match choice {
                    cover_pick::CoverChoice::Keep => return,
                    cover_pick::CoverChoice::Use(u) => Some(u),
                    cover_pick::CoverChoice::Remove => None,
                };
                me.model.borrow_mut().cover = next;
                me.render();
            };
            if link.is_empty() {
                decide(None, None);
                return;
            }
            bg(async move { cover_pick::og_image_for(&link).await }, move |og| match og {
                Some(o) => {
                    let o2 = o.clone();
                    load_texture(&o, move |tex| decide(Some(o2), tex.map(|t| t.width().max(0) as u32)));
                }
                None => decide(None, None),
            });
        };
        match known {
            Some(k) => load_texture(&k.clone(), move |tex| then(Some(k), tex.map(|t| t.width().max(0) as u32))),
            None => then(None, None),
        }
    }

    pub fn load(self: &Rc<Self>) {
        self.find_cover();
        // 유료 표시·같은 스토리의 무료 보도(DB 를 읽으므로 뒤에서)
        {
            let core = ui().core.clone();
            let item = self.item().clone();
            let w = Rc::downgrade(self);
            bg(
                async move {
                    let filter = core.source_filter();
                    (core.paywall.source_kind(&item), core.paywall.alternatives(&item, &filter), item.key())
                },
                move |(kind, alts, key)| {
                    let Some(me) = w.upgrade() else { return };
                    if !me.alive.get() || me.item().key() != key {
                        return;
                    }
                    {
                        let mut m = me.model.borrow_mut();
                        m.paywall = kind;
                        m.alternatives = alts;
                    }
                    me.render();
                },
            );
        }
        let svc = ui().core.articles.clone();
        if let Some(c) = svc.cached(&self.item().link) {
            self.apply(&c);
            if !c.summarizing {
                return;
            }
        }
        let (tx, rx) = async_channel::unbounded::<PreparedArticle>();
        let id = svc.observe(
            &self.item().link,
            Box::new(move |a| {
                let _ = tx.send_blocking(a.clone());
            }),
        );
        self.observe.set(Some(id));
        let w = Rc::downgrade(self);
        let link = self.item().link.clone();
        glib::spawn_future_local(async move {
            while let Ok(a) = rx.recv().await {
                match w.upgrade() {
                    // J/K 로 다른 기사로 바뀌었으면 그만
                    Some(me) if me.alive.get() && me.item().link == link => me.apply(&a),
                    _ => break,
                }
            }
        });
        let item = self.item().clone();
        let link = item.link.clone();
        let w = Rc::downgrade(self);
        bg(async move { svc.prepare(item, true).await }, move |a| {
            if let Some(me) = w.upgrade() {
                if me.item().link != link {
                    return; // J/K 로 다른 기사로 바뀜
                }
                if me.alive.get() {
                    me.apply(&a);
                }
                if let Some(id) = me.observe.take() {
                    ui().core.articles.stop_observing(&me.item().link, id);
                }
            }
        });
    }

    // '다시 받기': 저장한 것을 지우고 처음부터(맛보기·일부만이 풀렸는지, 앱이 고쳐졌는지 — 맥 ReaderModel.reload)
    fn reload(self: &Rc<Self>) {
        if matches!(self.model.borrow().phase, Phase::Loading | Phase::Translating) {
            return;
        }
        if let Some(id) = self.observe.take() {
            ui().core.articles.stop_observing(&self.item().link, id);
        }
        ui().core.articles.forget_cached(&self.item().link);
        {
            let mut m = self.model.borrow_mut();
            m.phase = Phase::Loading;
            m.blocks.clear();
            m.open_originals.clear();
        }
        self.update_tools();
        self.render();
        self.load();
    }

    fn apply(self: &Rc<Self>, a: &PreparedArticle) {
        let changed = {
            let mut m = self.model.borrow_mut();
            let before = (m.phase, m.blocks.len(), m.translated, m.key_points.clone(), m.summarizing, m.title.clone(), m.paywalled, m.partial);
            // 예전에 저장한 기사에도 적용: 제목 끝의 사이트 이름은 출처가 이미 보이므로 뗀다
            m.title = strip_site_name(&a.title, &self.item().source_name, &self.item().title);
            m.original_title = strip_site_name(&a.original_title, &self.item().source_name, &self.item().title);
            m.translated = a.translated;
            m.engine = a.engine.clone();
            m.key_points = a.summary.clone();
            m.summarizing = a.summarizing;
            m.summary = a.fallback.clone();
            m.paywalled = a.paywalled == Some(true);
            m.partial = a.partial == Some(true);
            let blocks_changed = !a.blocks.is_empty() && a.blocks != m.blocks;
            if !a.blocks.is_empty() {
                m.blocks = a.blocks.clone();
            }
            m.phase = match a.stage {
                Stage::Extracting => Phase::Loading,
                Stage::Original | Stage::Translating => Phase::Translating,
                Stage::Done => Phase::Done,
                Stage::Failed => Phase::Failed,
            };
            blocks_changed || before != (m.phase, m.blocks.len(), m.translated, m.key_points.clone(), m.summarizing, m.title.clone(), m.paywalled, m.partial)
        };
        self.mode_box.set_visible(self.model.borrow().translated);
        self.update_tools();
        self.update_speak();
        if changed {
            self.render();
        }
    }

    // MARK: 그리기
    fn cover_url(&self) -> Option<String> {
        // 표지: 대표 사진(피드 → 매거진 기록 → 기사 머리), 없으면 본문의 첫 진짜 사진(잡그림 제외)
        let m = self.model.borrow();
        m.cover.clone().or_else(|| m.blocks.iter().find(|b| b.kind == BlockKind::Img && !image_key::is_junk(b.src.as_deref())).and_then(|b| b.src.clone()))
    }

    // 본문에서 빼는 블록: 기자 줄·짝 잃은 설명 문구, 표지와 같은 사진 처음 한 번과 그 설명, 잡그림(body_cleanup::hidden)
    fn hidden_blocks(&self, blocks: &[Block]) -> std::collections::HashSet<usize> {
        body_cleanup::hidden(blocks, self.cover_url().as_deref())
    }

    fn font_size(&self) -> f64 {
        ui().prefs.borrow().reader_font_size.clamp(FONT_MIN, FONT_MAX)
    }

    // MARK: 찾기
    // 지금 보이는 글 조각(제목 + 본문 줄) — 화면에 나오는 순서
    fn find_labels(&self) -> Vec<gtk::Label> {
        let mut v: Vec<gtk::Label> = self.title_label.borrow().iter().cloned().collect();
        v.extend(self.rows.borrow().iter().filter_map(|r| r.label.clone()));
        v
    }

    fn find_step(self: &Rc<Self>, forward: bool) {
        if !self.find_bar.is_search_mode() {
            self.find_bar.set_search_mode(true);
            self.find_entry.grab_focus();
            return;
        }
        let pieces: Vec<String> = self.find_labels().iter().map(|l| l.text().to_string()).collect();
        let n = reader_find::matches(&pieces, &self.find_entry.text()).len();
        self.find_index.set(reader_find::step(self.find_index.get(), n, forward));
        self.update_find(true);
    }

    // 일치한 곳을 칠하고(지금 고른 곳은 주황) 그 자리로 굴린다
    fn update_find(&self, scroll: bool) {
        let labels = self.find_labels();
        let query = if self.find_bar.is_search_mode() { self.find_entry.text().to_string() } else { String::new() };
        let pieces: Vec<String> = labels.iter().map(|l| l.text().to_string()).collect();
        let found = reader_find::matches(&pieces, &query);
        let idx = self.find_index.get().min(found.len().saturating_sub(1));
        self.find_count.set_text(&reader_find::count_text(&query, found.len(), idx));
        let current = found.get(idx).copied();
        let mut base = self.base_attrs.borrow_mut();
        for (p, l) in labels.iter().enumerate() {
            let key = l.as_ptr() as usize;
            let attrs = base.entry(key).or_insert_with(|| l.attributes().unwrap_or_default()).copy().unwrap_or_default();
            for (n, (a, b)) in reader_find::ranges(&pieces[p], &query).into_iter().enumerate() {
                let now = current == Some(reader_find::Match { piece: p, nth: n });
                let (r, g, bl) = if now { (0xFFFF, 0x9500, 0) } else { (0xFFFF, 0xE000, 0x4000) };
                let mut bg = pango::AttrColor::new_background(r, g, bl);
                bg.set_start_index(a as u32);
                bg.set_end_index(b as u32);
                attrs.insert(bg);
                if now {
                    let mut fg = pango::AttrColor::new_foreground(0, 0, 0);
                    fg.set_start_index(a as u32);
                    fg.set_end_index(b as u32);
                    attrs.insert(fg);
                }
            }
            l.set_attributes(Some(&attrs));
        }
        drop(base);
        if let (true, Some(m)) = (scroll, current) {
            if let Some(l) = labels.get(m.piece) {
                if let Some(pt) = l.compute_point(&self.column, &gtk::graphene::Point::new(0.0, 0.0)) {
                    let adj = self.scroller.vadjustment();
                    adj.set_value((pt.y() as f64 - adj.page_size() / 2.0).max(0.0));
                }
            }
        }
    }

    fn render(self: &Rc<Self>) {
        // 다시 그려도 읽던 자리를 지킨다
        let adj = self.scroller.vadjustment();
        let pos = adj.value();
        widgets::clear_box(&self.column);
        self.rows.borrow_mut().clear();
        self.base_attrs.borrow_mut().clear();
        *self.title_label.borrow_mut() = None;
        if let Some(u) = self.cover_url() {
            self.column.append(&self.cover(&u));
        }
        self.column.append(&self.header());
        let (phase, paywalled, partial) = {
            let m = self.model.borrow();
            (m.phase, m.paywalled, m.partial)
        };
        // 맛보기면 본문 바로 위에, 무료 보도가 없어도 늘(무료 보도 상자와 따로 — READER-CUT.md C②)
        if paywalled && matches!(phase, Phase::Translating | Phase::Done) {
            let b = self.teaser_banner();
            b.set_margin_top(18);
            self.column.append(&b);
        }
        if let Some(b) = self.free_box() {
            b.set_margin_top(18);
            self.column.append(&b);
        }
        let phase = self.model.borrow().phase;
        match phase {
            Phase::Loading => {
                // 본문을 받는 동안에도 빈 화면 대신 피드가 준 요약을 먼저 보여 준다
                if let Some(lede) = feed_summary(&self.item()) {
                    let l = text(&lede, 16.0, 400, 1.45, false, false);
                    l.add_css_class("dc-secondary");
                    l.set_margin_top(24);
                    l.set_margin_start(38);
                    self.column.append(&l);
                }
                let s = skeleton("기사를 불러오는 중");
                s.set_margin_top(28);
                s.set_margin_start(38);
                self.column.append(&s);
            }
            Phase::Translating | Phase::Done => {
                if let Some(k) = self.key_points_box() {
                    k.set_margin_top(22);
                    self.column.append(&k);
                }
                if phase == Phase::Translating {
                    let b = gtk::Box::new(gtk::Orientation::Horizontal, 6);
                    b.append(&widgets::icon("preferences-desktop-locale-symbolic", 14));
                    b.append(&text("한국어로 바꾸는 중 — 위에서부터 차례로 바뀝니다", 12.0, 400, 0.0, false, false));
                    b.add_css_class("dc-secondary");
                    b.set_margin_top(18);
                    b.set_margin_start(38);
                    pulse(&b);
                    self.column.append(&b);
                }
                let body = self.article_body();
                body.set_margin_top(24);
                self.column.append(&body);
                widgets::fade_in(&body, 300);
                if paywalled || partial {
                    let n = self.cut_end_note(paywalled);
                    n.set_margin_top(6);
                    self.column.append(&n);
                }
            }
            Phase::Failed => {
                let f = self.failed();
                f.set_margin_top(24);
                self.column.append(&f);
            }
        }
        self.refresh_scrap_marks();
        // 시험용(DROPCAP_TEST_FIND=낱말): 찾기 막대를 연 채로(맥과 같은 변수)
        if let Some(q) = dropcap_core::test_hooks::var("DROPCAP_TEST_FIND") {
            if !q.is_empty() && !self.find_bar.is_search_mode() {
                self.find_bar.set_search_mode(true);
                self.find_entry.set_text(&q);
            }
        }
        if self.find_bar.is_search_mode() {
            self.update_find(false); // 다시 그린 글에도 칠한 곳을 그대로
        }
        glib::idle_add_local_once(move || adj.set_value(pos));
    }

    fn cover(&self, url: &str) -> gtk::Widget {
        let frame = gtk::Overlay::new();
        frame.set_margin_start(38);
        frame.set_margin_bottom(22);
        frame.set_overflow(gtk::Overflow::Hidden);
        frame.set_height_request(340);
        style(&frame, "border-radius: 16px;");
        let bgd = gtk::DrawingArea::builder().hexpand(true).height_request(340).build();
        let accent = self.accent();
        let cat = self.item().category().color(theme::is_dark()).to_string();
        bgd.set_draw_func(move |_, cr, w, h| {
            let g = gtk::cairo::LinearGradient::new(0.0, 0.0, w as f64, h as f64);
            let (ar, ag, ab) = dropcap_core::models::hex_rgb(&accent);
            let (cr_, cg, cb) = dropcap_core::models::hex_rgb(&cat);
            g.add_color_stop_rgba(0.0, ar, ag, ab, 0.35);
            g.add_color_stop_rgba(1.0, cr_, cg, cb, 0.2);
            let _ = cr.set_source(&g);
            let _ = cr.paint();
        });
        frame.set_child(Some(&bgd));
        let spin = gtk::Spinner::new();
        spin.set_halign(gtk::Align::Center);
        spin.set_valign(gtk::Align::Center);
        spin.start();
        frame.add_overlay(&spin);
        let pic = gtk::Picture::new();
        pic.set_content_fit(gtk::ContentFit::Cover);
        pic.set_can_shrink(true);
        pic.set_opacity(0.0);
        frame.add_overlay(&pic);
        let f2 = frame.clone();
        let u2 = url.to_string();
        load_texture(url, move |tex| match tex {
            Some(t) => {
                spin.set_visible(false);
                pic.set_paintable(Some(&t));
                widgets::fade_in(&pic, 350);
                reader_image::attach_tools(&f2, &t, &u2, ""); // 표지에도 사진 도구(맥 CoverImage.imageActions)
            }
            None => f2.set_visible(false), // 표지 사진을 못 받으면 자리째 숨김
        });
        frame.upcast()
    }

    fn header(&self) -> gtk::Widget {
        let m = self.model.borrow();
        let v = gtk::Box::new(gtk::Orientation::Vertical, 10);
        v.set_margin_start(38);
        let top = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        top.append(&monogram(&self.item(), 22));
        top.append(&text(&self.item().source_name, 13.0, 600, 0.0, false, false));
        let tier = widgets::chip(&resources::tier_label(&self.item().tier), &self.accent());
        style(&tier, "border-radius: 5px; font-size: 11px;");
        top.append(&tier);
        if let Some(d) = self.item().date {
            let l = text(&date_text(d), 12.0, 400, 0.0, false, false);
            l.add_css_class("dc-secondary");
            top.append(&l);
        }
        if let Some(mins) = self.reading_minutes(&m) {
            let b = gtk::Box::new(gtk::Orientation::Horizontal, 4);
            b.append(&widgets::icon("alarm-symbolic", 12));
            b.append(&text(&format!("약 {mins}분"), 12.0, 400, 0.0, false, false));
            b.add_css_class("dc-secondary");
            b.set_tooltip_text(Some("읽는 시간(한국어 분당 약 500자 기준)"));
            top.append(&b);
        }
        v.append(&top);
        let title = text(if m.show_original { &m.original_title } else { &m.title }, 30.0, 700, 1.1, false, false);
        style(&title, "letter-spacing: -0.4px;");
        *self.title_label.borrow_mut() = Some(title.clone());
        v.append(&title);
        if !m.show_original && m.original_title != m.title {
            let o = text(&m.original_title, 14.0, 400, 0.0, false, false);
            o.add_css_class("dc-secondary");
            v.append(&o);
        }
        // 바이라인: 본문에서 뺀 기자 줄(제목 아래)
        if let Some(by) = body_cleanup::analyze(&m.blocks).1 {
            let b = text(&by, 12.5, 500, 0.0, false, false);
            b.add_css_class("dc-secondary");
            v.append(&b);
        }
        // 쓰인 번역 방식(T-07)
        if m.translated && !m.engine.is_empty() {
            let b = gtk::Box::new(gtk::Orientation::Horizontal, 4);
            b.append(&widgets::icon("preferences-desktop-locale-symbolic", 11));
            b.append(&text(&m.engine, 11.0, 400, 0.0, false, false));
            b.add_css_class("dc-tertiary");
            v.append(&b);
        }
        v.upcast()
    }

    fn visible_texts(m: &Model) -> Vec<String> {
        m.blocks.iter().filter_map(|b| if m.show_original { b.original.clone().or(b.text.clone()) } else { b.text.clone() }).collect()
    }

    fn reading_minutes(&self, m: &Model) -> Option<i64> {
        let t = Self::visible_texts(m);
        (!t.is_empty()).then(|| article::reading_minutes(&t))
    }

    // 3줄 요약(Ollama 가 있을 때만, T-06)
    fn key_points_box(&self) -> Option<gtk::Widget> {
        let m = self.model.borrow();
        if m.key_points.is_none() && !m.summarizing {
            return None;
        }
        let fs = self.font_size();
        let (r, g, b) = rgb(&self.accent());
        let v = gtk::Box::new(gtk::Orientation::Vertical, 9);
        v.set_margin_start(38);
        style(
            &v,
            &format!("padding: 16px; border-radius: 14px; background-color: rgba({r},{g},{b},0.07); border: 0.5px solid rgba({r},{g},{b},0.15);"),
        );
        let head = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        let star = widgets::icon("starred-symbolic", 12);
        style(&star, &format!("color: rgb({r},{g},{b});"));
        head.append(&star);
        let hl = text("3줄 요약", 12.0, 600, 0.0, false, false);
        style(&hl, &format!("color: rgb({r},{g},{b});"));
        head.append(&hl);
        v.append(&head);
        match &m.key_points {
            Some(pts) => {
                for p in pts {
                    let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
                    let dot = text("•", fs - 1.0, 400, 0.0, false, false);
                    dot.set_valign(gtk::Align::Start);
                    style(&dot, &format!("color: rgb({r},{g},{b});"));
                    row.append(&dot);
                    let l = text(p, fs - 1.0, 400, 1.3, false, false);
                    l.set_hexpand(true);
                    row.append(&l);
                    v.append(&row);
                }
            }
            None => {
                let l = text("요약하는 중…", 13.0, 400, 0.0, false, false);
                l.add_css_class("dc-secondary");
                pulse(&l);
                v.append(&l);
            }
        }
        Some(v.upcast())
    }

    fn article_body(self: &Rc<Self>) -> gtk::Box {
        let body = gtk::Box::new(gtk::Orientation::Vertical, 0);
        let (blocks, show_original) = {
            let m = self.model.borrow();
            (m.blocks.clone(), m.show_original)
        };
        let hidden = self.hidden_blocks(&blocks);
        let open = self.model.borrow().open_originals.clone();
        for (i, b) in blocks.iter().enumerate() {
            if hidden.contains(&i) {
                continue;
            }
            let t = if show_original { b.original.clone().or(b.text.clone()) } else { b.text.clone() }.unwrap_or_default();
            let prev_li = i > 0 && blocks[i - 1].kind == BlockKind::Li;
            let (content, label) = self.block_view(b, &t, prev_li);
            let enabled = matches!(b.kind, BlockKind::P | BlockKind::Li | BlockKind::Quote | BlockKind::H) && !t.is_empty();
            let original = if show_original { None } else { b.original.clone() };
            // 문단별 원문 펼치기(번역 보기에서 번역된 문단만 — 맥 f5c8d57)
            let can_open = !show_original && b.original.is_some() && b.kind != BlockKind::Img;
            let toggle = can_open.then_some((i, open.contains(&i)));
            body.append(&self.scrap_row(content, label, t, original, enabled, toggle));
            if let (true, Some(o)) = (can_open && open.contains(&i), b.original.as_deref()) {
                body.append(&self.original_under(o));
            }
        }
        body
    }

    // 펼친 문단의 원문: 번역문 바로 아래에 작게, 왼쪽에 기사 빛깔 줄
    fn original_under(&self, o: &str) -> gtk::Widget {
        let fs = self.font_size();
        let l = text(o, fs - 2.0, 400, 1.35, false, false);
        l.add_css_class("dc-secondary");
        l.set_hexpand(true);
        let (r, g, b) = rgb(&self.accent());
        let wrap = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        style(&wrap, &format!("border-left: 2px solid rgba({r},{g},{b},0.4); padding-left: 12px;"));
        wrap.append(&l);
        wrap.set_margin_start(38);
        wrap.set_margin_top(-(fs as i32 - 4).max(0));
        wrap.set_margin_bottom(fs as i32);
        wrap.upcast()
    }

    fn toggle_original(self: &Rc<Self>, i: usize) {
        {
            let mut m = self.model.borrow_mut();
            if !m.open_originals.remove(&i) {
                m.open_originals.insert(i);
            }
        }
        self.render();
    }

    // 맛보기(유료벽 앞부분)만 받은 기사 — 본문 바로 위 띠(맥 TeaserBanner 문구 그대로)
    fn teaser_banner(&self) -> gtk::Widget {
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        row.set_margin_start(38);
        row.add_css_class("dc-teaser");
        let lock = widgets::icon("changes-prevent-symbolic", 14);
        style(&lock, "color: #e67e00;");
        row.append(&lock);
        let v = gtk::Box::new(gtk::Orientation::Vertical, 3);
        v.set_hexpand(true);
        let t = text(paywall::TEASER_TITLE, 13.5, 600, 0.0, false, false);
        t.set_selectable(false);
        v.append(&t);
        let d = text(paywall::TEASER_DETAIL, 12.5, 400, 0.0, false, false);
        d.set_selectable(false);
        d.add_css_class("dc-secondary");
        v.append(&d);
        row.append(&v);
        let open = gtk::Button::with_label(paywall::OPEN_ORIGINAL);
        open.set_valign(gtk::Align::Center);
        let link = self.item().link.clone();
        open.connect_clicked(move |_| {
            open_external(&link);
        });
        row.append(&open);
        style(&row, "padding: 11px 14px; border-radius: 12px; background-color: rgba(255,149,0,0.09); border: 1px solid rgba(255,149,0,0.28);");
        row.upcast()
    }

    // 본문 끝 한 줄: 맛보기가 끝난 자리, 또는 일부만 가져왔을 수 있음(맥 CutEndNote 문구 그대로)
    fn cut_end_note(self: &Rc<Self>, teaser: bool) -> gtk::Widget {
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        row.set_margin_start(38);
        let lead = text(if teaser { paywall::TEASER_END } else { paywall::PARTIAL_END }, 12.5, 400, 0.0, false, false);
        lead.set_selectable(false);
        lead.add_css_class("dc-secondary");
        row.append(&lead);
        let dot = || {
            let d = text("·", 12.5, 400, 0.0, false, false);
            d.set_selectable(false);
            d.add_css_class("dc-secondary");
            d
        };
        let link_btn = |label: &str| {
            let b = gtk::Button::with_label(label);
            b.add_css_class("flat");
            b.add_css_class("dc-link");
            style(&b, "padding: 0 2px; min-height: 0; font-size: 12.5px; color: @accent_color;");
            b
        };
        row.append(&dot());
        let open = link_btn(if teaser { paywall::TEASER_CONTINUE } else { paywall::OPEN_ORIGINAL });
        let link = self.item().link.clone();
        open.connect_clicked(move |_| {
            open_external(&link);
        });
        row.append(&open);
        row.append(&dot());
        let again = link_btn(paywall::RELOAD);
        let w = Rc::downgrade(self);
        again.connect_clicked(move |_| {
            if let Some(me) = w.upgrade() {
                me.reload();
            }
        });
        row.append(&again);
        row.upcast()
    }

    fn block_view(&self, b: &Block, t: &str, prev_li: bool) -> (gtk::Widget, Option<gtk::Label>) {
        let fs = self.font_size();
        let (r, g, bl) = rgb(&self.accent());
        match b.kind {
            BlockKind::H => {
                let l = text(t, fs + 4.0, 700, 0.0, false, false);
                style(&l, "letter-spacing: -0.2px;");
                l.set_margin_top(26);
                l.set_margin_bottom(8);
                (l.clone().upcast(), Some(l))
            }
            BlockKind::P => {
                let l = text(t, fs, 400, 1.47, false, false);
                l.set_margin_bottom(fs as i32 + 1);
                (l.clone().upcast(), Some(l))
            }
            BlockKind::Li => {
                let row = gtk::Box::new(gtk::Orientation::Horizontal, 10);
                let dot = gtk::DrawingArea::builder().content_width(5).content_height(5).valign(gtk::Align::Start).build();
                dot.set_margin_top((fs * 0.62) as i32);
                let accent = self.accent();
                dot.set_draw_func(move |_, cr, w, h| {
                    let (rr, gg, bb) = dropcap_core::models::hex_rgb(&accent);
                    cr.set_source_rgba(rr, gg, bb, 0.8);
                    cr.arc(w as f64 / 2.0, h as f64 / 2.0, w.min(h) as f64 / 2.0, 0.0, std::f64::consts::TAU);
                    let _ = cr.fill();
                });
                row.append(&dot);
                let l = text(t, fs, 400, 1.41, false, false);
                l.set_hexpand(true);
                row.append(&l);
                row.set_margin_top(if prev_li { 0 } else { 2 });
                row.set_margin_bottom(8);
                row.set_margin_start(4);
                (row.upcast(), Some(l))
            }
            BlockKind::Quote => {
                let l = text(t, fs, 400, 1.41, true, false);
                l.add_css_class("dc-secondary");
                let wrap = gtk::Box::new(gtk::Orientation::Horizontal, 0);
                style(&wrap, &format!("border-left: 3px solid rgba({r},{g},{bl},0.6); padding-left: 16px;"));
                wrap.append(&l);
                l.set_hexpand(true);
                wrap.set_margin_top(6);
                wrap.set_margin_bottom(20);
                (wrap.upcast(), Some(l))
            }
            BlockKind::Pre => {
                let l = text(t, 13.0, 400, 0.0, false, true);
                l.set_wrap(false);
                style(&l, "padding: 14px;");
                let sw = gtk::ScrolledWindow::builder().vscrollbar_policy(gtk::PolicyType::Never).child(&l).propagate_natural_height(true).build();
                style(&sw, "border-radius: 10px; background-color: alpha(@window_fg_color, 0.06);");
                sw.set_margin_bottom(18);
                (sw.upcast(), None)
            }
            BlockKind::Img => (reader_image::article_image(b.src.as_deref().unwrap_or("")), None),
            BlockKind::Cap => {
                let l = text(t, 13.0, 400, 0.0, false, false);
                l.add_css_class("dc-secondary");
                l.set_margin_bottom(18);
                (l.clone().upcast(), Some(l))
            }
        }
    }

    fn failed(&self) -> gtk::Widget {
        let m = self.model.borrow();
        let v = gtk::Box::new(gtk::Orientation::Vertical, 14);
        v.set_margin_start(38);
        let lede = if m.summary.is_empty() { feed_summary(&self.item()) } else { Some(m.summary.clone()) };
        if let Some(t) = lede {
            v.append(&text(&t, 17.0, 400, 1.5, false, false));
        }
        let blocked = article::is_blocked_host(&self.item().link);
        let note = text(
            if blocked {
                "이 사이트는 앱에서 본문을 가져가지 못하게 막아 두었습니다. 위는 피드가 준 요약입니다."
            } else {
                "이 기사는 본문을 추리지 못했습니다(유료 기사·차단 등). 위는 피드가 준 요약입니다."
            },
            13.0,
            400,
            0.0,
            false,
            false,
        );
        note.add_css_class("dc-secondary");
        v.append(&note);
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let o = gtk::Button::with_label("원문 열기");
        o.add_css_class("suggested-action");
        o.add_css_class("pill");
        let link = self.item().link.clone();
        o.connect_clicked(move |_| {
            open_external(&link);
        });
        row.append(&o);
        // 번역된 웹페이지는 외국어 기사일 때만
        if looks_foreign(&m.original_title) {
            if let Some(u) = article::translate_goog(&self.item().link) {
                let b = gtk::Button::with_label("번역된 웹페이지로 보기");
                b.add_css_class("pill");
                b.connect_clicked(move |_| {
                    open_external(&u);
                });
                row.append(&b);
            }
        }
        v.append(&row);
        v.upcast()
    }

    // 막힌 기사면 같은 스토리의 열리는 보도를 먼저 권한다(G-15 · 맥 FreeAlternativesBox). 원문 링크는 그대로 남는다
    fn free_box(&self) -> Option<gtk::Widget> {
        let m = self.model.borrow();
        let reason = paywall::free_reason(!m.alternatives.is_empty(), m.phase == Phase::Failed, m.paywalled, m.paywall)?;
        let v = gtk::Box::new(gtk::Orientation::Vertical, 10);
        v.set_margin_start(38);
        v.add_css_class("dc-free-box");
        let head = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        head.append(&widgets::icon("changes-prevent-symbolic", 11));
        head.append(&text(reason, 12.5, 600, 0.0, false, false));
        head.add_css_class("dc-secondary");
        v.append(&head);
        let names: Vec<&str> = m.alternatives.iter().map(|a| a.source_name.as_str()).collect();
        v.append(&text(&format!("같은 소식을 무료로 읽기: {}", names.join("·")), 13.5, 600, 0.0, false, false));
        let list = gtk::Box::new(gtk::Orientation::Vertical, 6);
        for alt in &m.alternatives {
            let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
            let src = text(&alt.source_name, 12.0, 700, 0.0, false, false);
            src.set_selectable(false);
            src.set_wrap(false);
            let (r, g, b) = rgb(&widgets::source_color(&alt.source_id));
            style(&src, &format!("color: rgb({r},{g},{b});"));
            row.append(&src);
            let t = text(alt.display_title(), 13.0, 400, 0.0, false, false);
            t.set_selectable(false);
            t.set_wrap(false);
            t.set_ellipsize(pango::EllipsizeMode::End);
            t.set_hexpand(true);
            row.append(&t);
            let arrow = widgets::icon("go-next-symbolic", 10);
            arrow.add_css_class("dc-tertiary");
            row.append(&arrow);
            let btn = gtk::Button::builder().child(&row).css_classes(["flat"]).build();
            let a = alt.clone();
            btn.connect_clicked(move |_| crate::app::open_from_magazine(&a, None));
            list.append(&btn);
        }
        v.append(&list);
        let orig = gtk::LinkButton::with_label(&self.item().link, "원문 그대로 열기");
        orig.set_halign(gtk::Align::Start);
        let link = self.item().link.clone();
        orig.connect_activate_link(move |_| {
            open_external(&link);
            glib::Propagation::Stop
        });
        v.append(&orig);
        Some(v.upcast())
    }

    // toggle: 번역된 문단이면 (블록 번호, 원문 펼쳐짐) — 왼쪽 여백에 '원문' 단추·오른쪽 클릭 메뉴
    fn scrap_row(
        self: &Rc<Self>,
        content: gtk::Widget,
        label: Option<gtk::Label>,
        t: String,
        original: Option<String>,
        enabled: bool,
        toggle: Option<(usize, bool)>,
    ) -> gtk::Widget {
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        let gutter = gtk::Box::new(gtk::Orientation::Vertical, 0);
        gutter.set_size_request(38, -1);
        let button = gtk::Button::from_icon_name("edit-cut-symbolic");
        button.add_css_class("circular");
        button.add_css_class("flat");
        button.set_valign(gtk::Align::Start);
        button.set_halign(gtk::Align::Start);
        button.set_size_request(26, 26);
        button.set_opacity(0.0);
        button.set_sensitive(enabled);
        gutter.append(&button);
        // 문단별 원문 펼치기 단추(번역 문단에 마우스를 올리면, 펼친 동안은 늘)
        let orig_btn = toggle.map(|(i, open)| {
            let b = gtk::Button::with_label("원문");
            b.add_css_class("flat");
            b.add_css_class("pill");
            style(&b, "font-size: 9.5px; font-weight: 600; padding: 0 4px; min-height: 20px; min-width: 26px;");
            b.set_halign(gtk::Align::Start);
            b.set_margin_top(2);
            b.set_tooltip_text(Some(if open { "이 문단 원문 접기" } else { "이 문단 원문 펼치기" }));
            b.set_opacity(if open { 1.0 } else { 0.0 });
            if open {
                b.add_css_class("accent");
            }
            let w = Rc::downgrade(self);
            b.connect_clicked(move |_| {
                if let Some(me) = w.upgrade() {
                    me.toggle_original(i);
                }
            });
            gutter.append(&b);
            (b, open)
        });
        row.append(&gutter);
        content.set_hexpand(true);
        row.append(&content);
        if !enabled {
            return row.upcast();
        }
        // 마우스를 올린 문단을 옅게 칠해 무엇이 스크랩될지 보이게
        let hover = gtk::EventControllerMotion::new();
        let (b1, c1) = (button.clone(), content.clone());
        let o1 = orig_btn.clone();
        hover.connect_enter(move |_, _, _| {
            b1.set_opacity(1.0);
            if let Some((o, _)) = &o1 {
                o.set_opacity(1.0);
            }
            c1.add_css_class("dc-reader-hover");
        });
        // 살짝 벗어났다 돌아와도 단추가 깜빡이지 않게 잠깐(0.25초) 기다렸다 숨김
        let token = Rc::new(Cell::new(0u64));
        let t1 = token.clone();
        hover.connect_motion(move |_, _, _| t1.set(t1.get() + 1));
        let (b2, c2, t2) = (button.clone(), content.clone(), token.clone());
        let o2 = orig_btn.clone();
        hover.connect_leave(move |_| {
            if b2.first_child().is_some() && b2.has_css_class("dc-open") {
                return;
            }
            t2.set(t2.get() + 1);
            let my = t2.get();
            let (b3, c3, t3, o3) = (b2.clone(), c2.clone(), t2.clone(), o2.clone());
            glib::timeout_add_local_once(std::time::Duration::from_millis(250), move || {
                if t3.get() != my || b3.has_css_class("dc-open") {
                    return;
                }
                b3.set_opacity(0.0);
                if let Some((o, false)) = &o3 {
                    o.set_opacity(0.0);
                }
                c3.remove_css_class("dc-reader-hover");
            });
        });
        row.add_controller(hover);
        style(&content, "transition: background-color 150ms;");

        let idx = self.rows.borrow().len();
        self.rows.borrow_mut().push(Row { content: content.clone(), button: button.clone(), label, text: t.clone(), original: original.clone() });

        let w = Rc::downgrade(self);
        button.connect_clicked(move |btn| {
            if let Some(me) = w.upgrade() {
                me.scrap_paragraph(idx, None);
                me.show_scrap_popover(btn, idx);
            }
        });
        // 오른쪽 클릭: 지우기·다른 폴더에·복사
        let click = gtk::GestureClick::new();
        click.set_button(3);
        let w = Rc::downgrade(self);
        let r2 = row.clone();
        click.connect_pressed(move |g, _, x, y| {
            if let Some(me) = w.upgrade() {
                me.paragraph_menu(&r2, idx, x, y, toggle);
                g.set_state(gtk::EventSequenceState::Claimed);
            }
        });
        row.add_controller(click);
        row.upcast()
    }

    fn scrap_of(&self, idx: usize) -> Option<dropcap_core::scrapbook::Scrap> {
        let rows = self.rows.borrow();
        let r = rows.get(idx)?;
        let key = self.item().key();
        ui().scrapbook.borrow().scraps.iter().find(|s| s.item.key() == key && s.quote.as_deref() == Some(r.text.as_str())).cloned()
    }

    fn scrap_paragraph(&self, idx: usize, collection: Option<&str>) {
        let (t, o) = {
            let rows = self.rows.borrow();
            let Some(r) = rows.get(idx) else { return };
            (r.text.clone(), r.original.clone())
        };
        let ui = ui();
        if collection.is_none() && self.scrap_of(idx).is_some() {
            return;
        }
        {
            let mut book = ui.scrapbook.borrow_mut();
            ui.core.scrap(&mut book, &self.item(), Some(t), o, collection);
        }
        self.refresh_scrap_marks();
        self.update_tools();
    }

    // 스크랩한 뒤: 담긴 폴더, 폴더 바꾸기, 메모, 되돌리기
    fn show_scrap_popover(self: &Rc<Self>, anchor: &gtk::Button, idx: usize) {
        let Some(s) = self.scrap_of(idx) else { return };
        let pop = gtk::Popover::new();
        pop.set_parent(anchor);
        pop.set_position(gtk::PositionType::Left);
        anchor.add_css_class("dc-open");
        let v = gtk::Box::new(gtk::Orientation::Vertical, 10);
        v.set_margin_top(14);
        v.set_margin_bottom(14);
        v.set_margin_start(14);
        v.set_margin_end(14);
        v.set_size_request(280, -1);
        let done_row = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        done_row.append(&widgets::icon("object-select-symbolic", 14));
        let msg = text(&format!("‘{}’에 스크랩했어요", s.collection), 13.0, 600, 0.0, false, false);
        done_row.append(&msg);
        done_row.add_css_class("success");
        v.append(&done_row);
        let cols: Vec<String> = ui().scrapbook.borrow().collections.clone();
        let list = gtk::StringList::new(&cols.iter().map(|s| s.as_str()).collect::<Vec<_>>());
        let dd = gtk::DropDown::new(Some(list), None::<gtk::Expression>);
        dd.set_selected(cols.iter().position(|c| *c == s.collection).unwrap_or(0) as u32);
        let frow = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        frow.append(&text("폴더", 13.0, 400, 0.0, false, false));
        dd.set_hexpand(true);
        frow.append(&dd);
        v.append(&frow);
        let memo = gtk::Entry::builder().placeholder_text("메모 (선택)").text(s.memo.as_str()).build();
        v.append(&memo);
        let actions = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let undo = gtk::Button::with_label("되돌리기");
        undo.add_css_class("destructive-action");
        let spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        spacer.set_hexpand(true);
        let ok = gtk::Button::with_label("완료");
        ok.add_css_class("suggested-action");
        actions.append(&undo);
        actions.append(&spacer);
        actions.append(&ok);
        v.append(&actions);
        pop.set_child(Some(&v));
        pop.set_default_widget(Some(&ok));
        memo.set_activates_default(true);

        let id = s.id.clone();
        let w = Rc::downgrade(self);
        let msg2 = msg.clone();
        dd.connect_selected_notify(move |d| {
            let Some(me) = w.upgrade() else { return };
            let ui = ui();
            let col = cols.get(d.selected() as usize).cloned();
            let mut book = ui.scrapbook.borrow_mut();
            if let (Some(c), Some(mut sc)) = (col, book.scraps.iter().find(|x| x.id == id).cloned()) {
                sc.collection = c.clone();
                book.update(&sc);
                msg2.set_text(&format!("‘{c}’에 스크랩했어요"));
            }
            drop(book);
            me.refresh_scrap_marks();
        });
        let save_memo = {
            let id = s.id.clone();
            let memo = memo.clone();
            move || {
                let ui = ui();
                let mut book = ui.scrapbook.borrow_mut();
                if let Some(mut sc) = book.scraps.iter().find(|x| x.id == id).cloned() {
                    let m = memo.text().to_string();
                    if sc.memo != m {
                        sc.memo = m;
                        book.update(&sc);
                    }
                }
            }
        };
        let p1 = pop.clone();
        let sm = save_memo.clone();
        ok.connect_clicked(move |_| {
            sm();
            p1.popdown();
        });
        let p2 = pop.clone();
        let w = Rc::downgrade(self);
        let id = s.id.clone();
        undo.connect_clicked(move |_| {
            ui().scrapbook.borrow_mut().remove(&id);
            p2.popdown();
            if let Some(me) = w.upgrade() {
                me.refresh_scrap_marks();
                me.update_tools();
            }
        });
        let a2 = anchor.clone();
        pop.connect_closed(move |p| {
            save_memo();
            a2.remove_css_class("dc-open");
            let p = p.clone();
            glib::idle_add_local_once(move || p.unparent());
        });
        pop.popup();
    }

    fn paragraph_menu(self: &Rc<Self>, row: &gtk::Box, idx: usize, x: f64, y: f64, toggle: Option<(usize, bool)>) {
        let group = gio::SimpleActionGroup::new();
        let menu = gio::Menu::new();
        let scrapped = self.scrap_of(idx).is_some();
        let w = Rc::downgrade(self);
        if scrapped {
            let a = gio::SimpleAction::new("unscrap", None);
            a.connect_activate(move |_, _| {
                if let Some(me) = w.upgrade() {
                    if let Some(s) = me.scrap_of(idx) {
                        ui().scrapbook.borrow_mut().remove(&s.id);
                    }
                    me.refresh_scrap_marks();
                    me.update_tools();
                }
            });
            group.add_action(&a);
            menu.append(Some("스크랩 지우기"), Some("para.unscrap"));
        } else {
            let a = gio::SimpleAction::new("scrap", None);
            a.connect_activate(move |_, _| {
                if let Some(me) = w.upgrade() {
                    me.scrap_paragraph(idx, None);
                }
            });
            group.add_action(&a);
            menu.append(Some("이 문단 스크랩"), Some("para.scrap"));
        }
        let to = gio::SimpleAction::new("scrap-to", Some(glib::VariantTy::STRING));
        let w = Rc::downgrade(self);
        to.connect_activate(move |_, p| {
            if let (Some(me), Some(c)) = (w.upgrade(), p.and_then(|v| v.get::<String>())) {
                me.scrap_paragraph(idx, Some(&c));
            }
        });
        group.add_action(&to);
        let sub = gio::Menu::new();
        for c in ui().scrapbook.borrow().collections.iter() {
            let it = gio::MenuItem::new(Some(c), None);
            it.set_action_and_target_value(Some("para.scrap-to"), Some(&c.to_variant()));
            sub.append_item(&it);
        }
        menu.append_submenu(Some("다른 폴더에 스크랩"), &sub);
        if let Some((i, open)) = toggle {
            let a = gio::SimpleAction::new("original", None);
            let w = Rc::downgrade(self);
            a.connect_activate(move |_, _| {
                if let Some(me) = w.upgrade() {
                    me.toggle_original(i);
                }
            });
            group.add_action(&a);
            menu.append(Some(if open { "이 문단 원문 접기" } else { "이 문단 원문 펼치기" }), Some("para.original"));
        }
        let copy = gio::SimpleAction::new("copy", None);
        let t = self.rows.borrow().get(idx).map(|r| r.text.clone()).unwrap_or_default();
        copy.connect_activate(move |_, _| copy_text(&t));
        group.add_action(&copy);
        let sec = gio::Menu::new();
        sec.append(Some("이 문단 복사"), Some("para.copy"));
        menu.append_section(None, &sec);
        row.insert_action_group("para", Some(&group));
        let pop = gtk::PopoverMenu::from_model(Some(&menu));
        pop.set_parent(row);
        pop.set_has_arrow(false);
        pop.set_pointing_to(Some(&gdk::Rectangle::new(x as i32, y as i32, 1, 1)));
        pop.connect_closed(|p| {
            let p = p.clone();
            glib::idle_add_local_once(move || p.unparent());
        });
        pop.popup();
    }

    fn refresh_scrap_marks(&self) {
        let ui = ui();
        let book = ui.scrapbook.borrow();
        let key = self.item().key();
        for r in self.rows.borrow().iter() {
            let on = book.scraps.iter().any(|s| s.item.key() == key && s.quote.as_deref() == Some(r.text.as_str()));
            if on {
                r.content.add_css_class("dc-scrapped");
                r.button.set_icon_name("edit-cut-symbolic");
                r.button.add_css_class("warning");
                r.button.set_tooltip_text(Some("스크랩한 문단 — 눌러서 폴더·메모 바꾸기"));
            } else {
                r.content.remove_css_class("dc-scrapped");
                r.button.remove_css_class("warning");
                r.button.set_tooltip_text(Some("이 문단 스크랩"));
            }
        }
    }

    // MARK: 기사 스크랩(누르면 마지막 폴더, 펼치면 폴더 고르기·새 폴더)
    fn scrap_article(&self, collection: Option<&str>) {
        let ui = ui();
        {
            let mut book = ui.scrapbook.borrow_mut();
            ui.core.scrap(&mut book, &self.item(), None, None, collection);
        }
        let c = collection.map(|s| s.to_string()).unwrap_or_else(|| ui.scrapbook.borrow().last_collection());
        self.flash(&format!("‘{c}’에 스크랩했어요"));
        self.update_tools();
        self.rebuild_scrap_menu();
    }

    fn rebuild_scrap_menu(&self) {
        let menu = gio::Menu::new();
        let cols = gio::Menu::new();
        for c in ui().scrapbook.borrow().collections.iter() {
            let it = gio::MenuItem::new(Some(c), None);
            it.set_action_and_target_value(Some("reader.scrap-to"), Some(&c.to_variant()));
            cols.append_item(&it);
        }
        menu.append_section(None, &cols);
        let more = gio::Menu::new();
        more.append(Some("선택한 부분 스크랩 (Ctrl+Shift+S)"), Some("reader.scrap-selection"));
        more.append(Some("새 폴더에 스크랩…"), Some("reader.scrap-new"));
        menu.append_section(None, &more);
        self.scrap_btn.set_menu_model(Some(&menu));
    }

    fn install_actions(self: &Rc<Self>) {
        let group = gio::SimpleActionGroup::new();
        let to = gio::SimpleAction::new("scrap-to", Some(glib::VariantTy::STRING));
        let w = Rc::downgrade(self);
        to.connect_activate(move |_, p| {
            if let (Some(me), Some(c)) = (w.upgrade(), p.and_then(|v| v.get::<String>())) {
                me.scrap_article(Some(&c));
            }
        });
        group.add_action(&to);
        let sel = gio::SimpleAction::new("scrap-selection", None);
        let w = Rc::downgrade(self);
        sel.connect_activate(move |_, _| {
            if let Some(me) = w.upgrade() {
                me.scrap_selection();
            }
        });
        group.add_action(&sel);
        let new = gio::SimpleAction::new("scrap-new", None);
        let w = Rc::downgrade(self);
        new.connect_activate(move |_, _| {
            if let Some(me) = w.upgrade() {
                me.ask_new_folder();
            }
        });
        group.add_action(&new);
        self.win.insert_action_group("reader", Some(&group));
    }

    fn install_shortcuts(self: &Rc<Self>) {
        let sc = gtk::ShortcutController::new();
        sc.set_scope(gtk::ShortcutScope::Managed);
        let add = |trigger: &str, f: Box<dyn Fn(&Rc<ReaderWindow>)>| {
            let w = Rc::downgrade(self);
            let action = gtk::CallbackAction::new(move |_, _| {
                if let Some(me) = w.upgrade() {
                    f(&me);
                }
                glib::Propagation::Stop
            });
            if let Some(t) = gtk::ShortcutTrigger::parse_string(trigger) {
                sc.add_shortcut(gtk::Shortcut::new(Some(t), Some(action)));
            }
        };
        add("<Control>minus", Box::new(|me| me.change_font(-1.0)));
        add("<Control>equal", Box::new(|me| me.change_font(1.0)));
        add("<Control>plus", Box::new(|me| me.change_font(1.0)));
        add("<Control>KP_Subtract", Box::new(|me| me.change_font(-1.0)));
        add("<Control>KP_Add", Box::new(|me| me.change_font(1.0)));
        add("<Control><Shift>s", Box::new(|me| me.scrap_selection()));
        add("<Control><Shift>c", Box::new(|me| me.copy_link()));
        add("<Control>f", Box::new(|me| {
            me.find_bar.set_search_mode(true);
            me.find_entry.grab_focus();
        }));
        add("<Control>g", Box::new(|me| me.find_step(true)));
        add("<Control><Shift>g", Box::new(|me| me.find_step(false)));
        add("<Control>w", Box::new(|me| me.win.close()));
        self.win.add_controller(sc);
        // 같은 목록의 다음·이전 기사(J/K), Esc 로 닫기 — 찾기 칸이 열려 있으면 쓰지 않음(H-05)
        let keys = gtk::EventControllerKey::new();
        let w = Rc::downgrade(self);
        keys.connect_key_pressed(move |_, key, _, state| {
            let Some(me) = w.upgrade() else { return glib::Propagation::Proceed };
            if me.find_bar.is_search_mode() || state.intersects(gdk::ModifierType::CONTROL_MASK | gdk::ModifierType::ALT_MASK | gdk::ModifierType::SUPER_MASK) {
                return glib::Propagation::Proceed;
            }
            match key {
                gdk::Key::j | gdk::Key::J => me.step(1),
                gdk::Key::k | gdk::Key::K => me.step(-1),
                gdk::Key::Escape => me.win.close(),
                _ => return glib::Propagation::Proceed,
            }
            glib::Propagation::Stop
        });
        self.win.add_controller(keys);
    }

    fn ask_new_folder(self: &Rc<Self>) {
        let d = adw::AlertDialog::new(Some("새 스크랩 폴더"), None);
        let e = gtk::Entry::builder().placeholder_text("폴더 이름").activates_default(true).build();
        d.set_extra_child(Some(&e));
        d.add_response("cancel", "취소");
        d.add_response("ok", "스크랩");
        d.set_response_appearance("ok", adw::ResponseAppearance::Suggested);
        d.set_default_response(Some("ok"));
        d.set_close_response("cancel");
        let w = Rc::downgrade(self);
        d.connect_response(None, move |_, r| {
            if r != "ok" {
                return;
            }
            let Some(me) = w.upgrade() else { return };
            let n = e.text().trim().to_string();
            if n.is_empty() {
                return;
            }
            ui().scrapbook.borrow_mut().create_collection(&n);
            me.scrap_article(Some(&n));
        });
        d.present(Some(&self.win));
    }

    // 끌어서 고른 글만 스크랩: 고른 글이 들어 있는 문단의 원문도 함께(번역문을 골랐을 때)
    fn scrap_selection(&self) {
        let picked = self.rows.borrow().iter().find_map(|r| {
            let l = r.label.as_ref()?;
            let (a, b) = l.selection_bounds()?;
            let (a, b) = (a.min(b) as usize, a.max(b) as usize);
            let s: String = l.text().chars().skip(a).take(b - a).collect();
            let s = s.trim().to_string();
            (!s.is_empty()).then(|| (s, r.original.clone()))
        });
        let Some((t, original)) = picked else {
            self.flash("먼저 스크랩할 글을 끌어서 고르세요");
            return;
        };
        let ui = ui();
        {
            let mut book = ui.scrapbook.borrow_mut();
            ui.core.scrap(&mut book, &self.item(), Some(t), original, None);
        }
        let c = ui.scrapbook.borrow().last_collection();
        self.flash(&format!("고른 부분을 ‘{c}’에 스크랩했어요"));
        self.update_tools();
    }

    // MARK: 도구
    fn change_font(self: &Rc<Self>, d: f64) {
        let cur = self.font_size();
        let next = (cur + d).clamp(FONT_MIN, FONT_MAX);
        if next == cur {
            return;
        }
        ui().update_prefs(|p| p.reader_font_size = next);
        self.render();
    }

    fn update_tools(&self) {
        let ui = ui();
        let saved = ui.core.is_saved(&self.item());
        self.save_btn.set_icon_name(if saved { "user-bookmarks-symbolic" } else { "bookmark-new-symbolic" });
        self.save_btn.set_tooltip_text(Some(if saved { "저장 취소" } else { "나중에 읽기로 저장" }));
        // 다시 받기는 받거나 번역하는 동안엔 막음
        self.reload_btn.set_sensitive(!matches!(self.model.borrow().phase, Phase::Loading | Phase::Translating));
        let scrapped = ui.scrapbook.borrow().is_scrapped(&self.item(), None);
        if scrapped {
            self.scrap_btn.add_css_class("accent");
        } else {
            self.scrap_btn.remove_css_class("accent");
        }
    }

    fn update_speak(&self) {
        let phase = self.model.borrow().phase;
        self.speak_btn.set_sensitive(!matches!(phase, Phase::Loading | Phase::Failed));
        let on = self.speaker.speaking();
        self.speak_btn.set_icon_name(if on { "media-playback-stop-symbolic" } else { "audio-speakers-symbolic" });
        self.speak_btn.set_tooltip_text(Some(if on { "읽기 멈춤" } else { "소리 내어 읽기" }));
    }

    fn toggle_speak(self: &Rc<Self>) {
        let (title, paras, korean) = {
            let m = self.model.borrow();
            let korean = if m.translated { !m.show_original } else { !looks_foreign(&m.title) };
            let paras: Vec<String> = m
                .blocks
                .iter()
                .filter(|b| b.kind != BlockKind::Pre && b.kind != BlockKind::Img)
                .filter_map(|b| if m.show_original { b.original.clone().or(b.text.clone()) } else { b.text.clone() })
                .collect();
            (if m.show_original { m.original_title.clone() } else { m.title.clone() }, paras, korean)
        };
        let w: Weak<ReaderWindow> = Rc::downgrade(self);
        self.speaker.toggle(&title, &paras, korean, move || {
            if let Some(me) = w.upgrade() {
                me.update_speak();
            }
        });
        self.update_speak();
    }

    fn flash(&self, msg: &str) {
        let t = adw::Toast::new(msg);
        t.set_timeout(2);
        self.toasts.add_toast(t);
    }
}

// 불러오는 동안 글 모양 자리표시 + 은은하게 흐르는 빛(R-13). 움직임 줄이기면 멈춘 채로.
fn skeleton(label: &str) -> gtk::Widget {
    let v = gtk::Box::new(gtk::Orientation::Vertical, 0);
    let head = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    head.append(&widgets::icon("content-loading-symbolic", 12));
    head.append(&text(label, 12.0, 400, 0.0, false, false));
    head.add_css_class("dc-secondary");
    head.set_margin_bottom(20);
    pulse(&head);
    v.append(&head);
    let area = gtk::DrawingArea::builder().hexpand(true).content_height(3 * (4 * 22 + 14)).build();
    let phase = Rc::new(Cell::new(-1.0f64));
    let ph = phase.clone();
    area.set_draw_func(move |a, cr, w, _h| {
        let fg = a.color();
        let p = ph.get();
        let w = w as f64;
        let mut y = 0.0;
        for para in 0..3 {
            for line in 0..4 {
                let lw = if line == 3 { (260.0 + para as f64 * 60.0).min(w) } else { w };
                // 흐르는 빛: 0.55 ~ 1 ~ 0.55 의 띠가 왼쪽에서 오른쪽으로
                let g = gtk::cairo::LinearGradient::new(w * p, 0.0, w * (p + 2.0), 0.0);
                for (o, a) in [(0.0, 0.55), (0.5, 1.0), (1.0, 0.55)] {
                    g.add_color_stop_rgba(o, fg.red() as f64, fg.green() as f64, fg.blue() as f64, 0.09 * a);
                }
                let _ = cr.set_source(&g);
                rounded(cr, 0.0, y, lw, 13.0, 4.0);
                let _ = cr.fill();
                y += 22.0;
            }
            y += 14.0;
        }
    });
    if motion::enabled() {
        let start = Rc::new(Cell::new(None::<i64>));
        area.add_tick_callback(move |a, clock| {
            let t = clock.frame_time();
            let s = start.get().unwrap_or_else(|| {
                start.set(Some(t));
                t
            });
            let k = ((t - s) as f64 / 1_400_000.0).fract(); // 1.4초 한 바퀴
            phase.set(-1.0 + k);
            a.queue_draw();
            glib::ControlFlow::Continue
        });
    }
    v.append(&area);
    v.upcast()
}

fn rounded(cr: &gtk::cairo::Context, x: f64, y: f64, w: f64, h: f64, r: f64) {
    use std::f64::consts::{FRAC_PI_2, PI};
    cr.new_sub_path();
    cr.arc(x + w - r, y + r, r, -FRAC_PI_2, 0.0);
    cr.arc(x + w - r, y + h - r, r, 0.0, FRAC_PI_2);
    cr.arc(x + r, y + h - r, r, FRAC_PI_2, PI);
    cr.arc(x + r, y + r, r, PI, 3.0 * FRAC_PI_2);
    cr.close_path();
}

// 은은히 깜빡임(진행 중 표시). 움직임 줄이기면 그대로.
fn pulse(w: &impl IsA<gtk::Widget>) {
    if !motion::enabled() {
        return;
    }
    let w = w.as_ref().clone();
    let target = adw::CallbackAnimationTarget::new({
        let w = w.clone();
        move |v| w.set_opacity(v)
    });
    let a = adw::TimedAnimation::new(&w, 1.0, 0.45, 900, target);
    a.set_repeat_count(0);
    a.set_alternate(true);
    a.set_easing(adw::Easing::EaseInOutSine);
    adw::prelude::AnimationExt::play(&a);
}

// 읽기 창만 쓰는 모양(한 번만 건다)
pub fn ensure_css() {
    thread_local! { static DONE: Cell<bool> = const { Cell::new(false) }; }
    if DONE.with(|d| d.replace(true)) {
        return;
    }
    let Some(display) = gdk::Display::default() else { return };
    let p = gtk::CssProvider::new();
    p.load_from_string(".dc-reader-hover { background-color: alpha(@accent_bg_color, 0.06); border-radius: 6px; }");
    gtk::style_context_add_provider_for_display(&display, &p, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION);
}

// 시험용 찍기(DROPCAP_TEST_SHOT_DIR)
pub fn shot_reader(win: &adw::ApplicationWindow, name: &str) {
    if let Some(dir) = ui().env.shot_dir.clone() {
        let _ = std::fs::create_dir_all(&dir);
        crate::shots::save(win, &dir.join(format!("{name}.png")));
    }
}

// 웹 문서 제목 끝의 사이트 이름(" - AI타임스", " | The Verge")은 출처가 이미 위에 보이므로 뗀다(맥 ArticleService.stripSiteName)
pub fn strip_site_name(title: &str, source: &str, feed_title: &str) -> String {
    let norm = |s: &str| s.to_lowercase().chars().filter(|c| c.is_alphanumeric()).collect::<String>();
    for sep in [" - ", " | ", " – ", " — ", " :: ", " · "] {
        let Some(i) = title.rfind(sep) else { continue };
        let head = title[..i].trim();
        let tail = title[i + sep.len()..].trim();
        if head.is_empty() {
            continue;
        }
        let (ns, nt) = (norm(source), norm(tail));
        if nt == ns || norm(head) == norm(feed_title) || (!ns.is_empty() && nt.contains(&ns)) {
            return head.to_string();
        }
    }
    title.to_string()
}

#[cfg(test)]
mod tests {
    use super::strip_site_name;
    #[test]
    fn strips_site_name() {
        assert_eq!(strip_site_name("오픈AI, 새 모델 공개 - AI타임스", "AI타임스", "x"), "오픈AI, 새 모델 공개");
        assert_eq!(strip_site_name("Meta ships Wonder | The Verge", "The Verge", "x"), "Meta ships Wonder");
        assert_eq!(strip_site_name("Feed title · Something", "S", "Feed title"), "Feed title");
        assert_eq!(strip_site_name("A - B story", "Nope", "x"), "A - B story");
    }
}

// 피드 요약(HTML 꼬리표·여분 공백 제거, 제목과 같거나 너무 짧으면 없음 — 맥 ReaderView.feedSummary)
pub fn feed_summary(it: &NewsItem) -> Option<String> {
    let mut plain = String::with_capacity(it.summary.len());
    let mut in_tag = false;
    for c in it.summary.chars() {
        match c {
            '<' => in_tag = true,
            '>' if in_tag => {
                in_tag = false;
                plain.push(' ');
            }
            _ if !in_tag => plain.push(c),
            _ => {}
        }
    }
    let t = plain.split_whitespace().collect::<Vec<_>>().join(" ");
    let head: String = t.chars().take(25).collect();
    (t.chars().count() > 30 && !it.title.starts_with(&head)).then_some(t)
}
