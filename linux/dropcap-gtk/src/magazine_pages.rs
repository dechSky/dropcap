// 모아 보기 지면(맥 MagazineView 의 StoriesView·StoryView·SavedView·SearchView·ScrapbookView·WeeklyQuotes).
use crate::app::{bg, copy_text, ui};
use crate::magazine::tint;
use crate::magazine_card::{has_photo, open_card, region_columns, stagger, StoryCard, CARD_MIN_WIDTH};
use crate::magazine_issue::balanced_columns;
use crate::widgets::{self, label, lines, RemoteImage};
use dropcap_core::app_model::UiEvent;
use dropcap_core::category::NewsCategory;
use dropcap_core::database::Cluster;
use dropcap_core::models::{relative_time, resources, NewsItem};
use dropcap_core::scrapbook::{Scrap, DEFAULT_COLLECTION};
use chrono::{Datelike, Local, Utc};
use adw::prelude::*;
use gtk::{gio, glib};
use std::cell::{Cell, RefCell};
use std::rc::Rc;

fn page_box() -> (gtk::Box, gtk::ScrolledWindow) {
    let v = gtk::Box::new(gtk::Orientation::Vertical, 14);
    v.set_margin_start(36);
    v.set_margin_end(36);
    v.set_margin_bottom(40);
    let clamp = adw::Clamp::builder().maximum_size(820).tightening_threshold(820).child(&v).build();
    clamp.set_halign(gtk::Align::Start);
    let scroll = gtk::ScrolledWindow::builder().hscrollbar_policy(gtk::PolicyType::Never).child(&clamp).vexpand(true).hexpand(true).build();
    (v, scroll)
}

fn wide_box() -> (gtk::Box, gtk::ScrolledWindow) {
    let v = gtk::Box::new(gtk::Orientation::Vertical, 14);
    v.set_margin_start(32);
    v.set_margin_end(32);
    v.set_margin_bottom(40);
    let scroll = gtk::ScrolledWindow::builder().hscrollbar_policy(gtk::PolicyType::Never).child(&v).vexpand(true).hexpand(true).build();
    (v, scroll)
}

fn big_title(t: &str) -> gtk::Label {
    let l = label(t, 34.0, 700, &["dc-display"]);
    l.set_margin_top(28);
    l
}

// 큰 제목 옆에 작은 수(저장 N건 · 스크랩북 모두 N개 — 옆 목록 수와 같게)
fn title_with_count(t: &str, count: &str) -> gtk::Box {
    let h = gtk::Box::new(gtk::Orientation::Horizontal, 10);
    h.set_margin_top(28);
    h.append(&label(t, 34.0, 700, &["dc-display"]));
    let c = label(count, 15.0, 600, &["dc-secondary"]);
    c.set_valign(gtk::Align::End);
    c.set_margin_bottom(7);
    h.append(&c);
    h
}

// 카드 격자(최소 230, 최대 360 폭) — 마지막 줄 한 장 남지 않게
fn card_grid(items: &[NewsItem], width_hint: i32, decorate: impl Fn(&NewsItem, gtk::Widget) -> gtk::Widget) -> gtk::FlowBox {
    let flow = gtk::FlowBox::new();
    flow.set_selection_mode(gtk::SelectionMode::None);
    flow.set_homogeneous(true);
    flow.set_column_spacing(18);
    flow.set_row_spacing(22);
    let fit = ((width_hint + 18) / (CARD_MIN_WIDTH + 18)).clamp(1, 4) as usize;
    let cols = balanced_columns(fit, items.len());
    flow.set_min_children_per_line(cols as u32);
    flow.set_max_children_per_line(cols as u32);
    for (i, it) in items.iter().enumerate() {
        let c = StoryCard::build(it, i, None, &[], None, items);
        flow.insert(&decorate(it, c), -1);
    }
    flow
}

// MARK: 스토리 목록(M-14): 지금 커지는 스토리(24시간) · 지난 스토리(2주)
pub fn stories(on_story: Rc<dyn Fn(String)>) -> (gtk::Widget, gtk::ScrolledWindow) {
    let (v, scroll) = page_box();
    v.append(&big_title("스토리"));
    v.append(&label("여러 곳이 함께 다룬 소식을 한 줄기로 묶었습니다. 팔로우하면 새 보도가 붙을 때 알려 드립니다.", 13.0, 400, &["dc-secondary"]));
    let list = gtk::Box::new(gtk::Orientation::Vertical, 14);
    v.append(&list);
    let core = ui().core.clone();
    bg(
        async move {
            let filter = core.source_filter(); // 지금 보이는 출처로만(S-13)
            // 스토리 목록 전체를 문장 두 번으로, 카드에는 이때 읽은 보도를 넘긴다(스토리마다 DB 를 다시 묻지 않게)
            let (live, past) = dropcap_core::magazine::story_cards(&core.db, Utc::now(), &filter);
            (live, past)
        },
        move |(live, past)| {
            if live.is_empty() && past.is_empty() {
                let l = label("아직 여러 곳이 함께 다룬 소식이 없습니다. 출처를 더 구독하면 스토리가 늘어납니다.", 13.0, 400, &["dc-secondary"]);
                l.set_margin_top(40);
                l.set_margin_bottom(40);
                list.append(&l);
            }
            let mut n = 0;
            for (title, sub, group) in [("지금 커지는 스토리", "최근 24시간", &live), ("지난 스토리", "최근 2주", &past)] {
                if group.is_empty() {
                    continue;
                }
                let h = gtk::Box::new(gtk::Orientation::Horizontal, 8);
                h.set_margin_top(14);
                h.append(&label(title, 15.0, 700, &[]));
                h.append(&label(sub, 12.0, 400, &["dc-tertiary"]));
                list.append(&h);
                for (i, sc) in group.iter().enumerate() {
                    let card = story_list_card(&sc.cluster, &sc.items, sc.topic.as_ref(), group.as_ptr() == live.as_ptr() && i == 0, on_story.clone());
                    stagger(&card, n);
                    n += 1;
                    list.append(&card);
                }
            }
        },
    );
    (scroll.clone().upcast(), scroll)
}

fn unique_sources(items: &[NewsItem]) -> Vec<NewsItem> {
    let mut out: Vec<NewsItem> = vec![];
    for it in items {
        if !out.iter().any(|o| o.source_name == it.source_name) {
            out.push(it.clone());
        }
    }
    out
}

// 스토리 카드: 대표 사진 · 분야 · 다룬 출처들 · 시작/최근 · 새 보도 · 팔로우 표시
fn story_list_card(c: &Cluster, items: &[NewsItem], topic: Option<&(String, Option<NewsCategory>)>, big: bool, on_story: Rc<dyn Fn(String)>) -> gtk::Widget {
    let core = ui().core.clone();
    let b = gtk::Button::new();
    b.add_css_class("flat");
    b.add_css_class("dc-soft");
    b.set_vexpand(false);
    let h = gtk::Box::new(gtk::Orientation::Horizontal, 16);
    h.set_margin_top(14);
    h.set_margin_bottom(14);
    h.set_margin_start(14);
    h.set_margin_end(14);
    if let Some(photo) = items.iter().find(|i| has_photo(i)) {
        let (w, hh) = if big { (210, 140) } else { (120, 80) };
        let img = RemoteImage::new(photo.image.as_deref(), photo.category(), &widgets::source_color(&photo.source_id), w, hh);
        img.root.set_size_request(w, hh);
        img.root.set_valign(gtk::Align::Start);
        round(&img.root, 12);
        h.append(&img.root);
    }
    let v = gtk::Box::new(gtk::Orientation::Vertical, 8);
    v.set_hexpand(true);
    let meta = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    // 분야는 묶인 보도들의 다수결(대표 기사 하나의 AI 하위 분류를 그대로 쓰면 IT 소식이 'AI·모델·제품'이 됐다, M-26) — 목록을 만들 때 화면 줄기 밖에서
    if let Some(topic) = topic {
        let (name, icon, color) = dropcap_core::magazine::story_topic_label(topic, crate::theme::is_dark());
        let t = gtk::Box::new(gtk::Orientation::Horizontal, 4);
        t.append(&widgets::icon(icon, 11));
        t.append(&label(&name, 11.5, 600, &[]));
        tint(&t, &color);
        meta.append(&t);
    }
    meta.append(&label(&format!("{}곳 보도", c.size), 11.5, 600, &["dc-secondary"]));
    let fresh = core.unseen_reports(c);
    if fresh > 0 {
        let f = gtk::Label::new(Some(&format!("새 보도 {fresh}")));
        f.add_css_class("dc-fresh");
        meta.append(&f);
    }
    if core.is_following(&c.id) {
        let bell = widgets::icon("preferences-system-notifications-symbolic", 11);
        tint(&bell, "#FF9500");
        bell.set_tooltip_text(Some("팔로우 중"));
        meta.append(&bell);
    }
    v.append(&meta);
    v.append(&label(&c.title, if big { 21.0 } else { 16.0 }, 600, &["dc-display"]));
    let srcs = unique_sources(items);
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 4);
    for it in srcs.iter().take(6) {
        let m = widgets::monogram(it, 20);
        m.set_tooltip_text(Some(&it.source_name));
        row.append(&m);
    }
    let names = label(&format!("  {}", srcs.iter().take(6).map(|i| i.source_name.clone()).collect::<Vec<_>>().join(" · ")), 11.5, 400, &["dc-secondary"]);
    names.set_wrap(false);
    names.set_ellipsize(gtk::pango::EllipsizeMode::End);
    row.append(&names);
    v.append(&row);
    let now = Utc::now();
    v.append(&label(&format!("첫 보도 {} · 최근 {}", relative_time(Some(c.first), now), relative_time(Some(c.last), now)), 11.5, 400, &["dc-tertiary"]));
    h.append(&v);
    b.set_child(Some(&h));
    let id = c.id.clone();
    b.connect_clicked(move |_| on_story(id.clone()));
    b.upcast()
}

fn round(w: &impl IsA<gtk::Widget>, r: i32) {
    let w = w.as_ref();
    w.set_overflow(gtk::Overflow::Hidden);
    w.set_vexpand(false); // 사진 칸이 둘레 카드를 세로로 늘리지 않게
    let prov = gtk::CssProvider::new();
    prov.load_from_string(&format!("* {{ border-radius: {r}px; }}"));
    #[allow(deprecated)]
    w.style_context().add_provider(&prov, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION);
}

// 보도 기간(맥 StoryView.span)
pub fn span(items: &[NewsItem]) -> String {
    let ds: Vec<_> = items.iter().filter_map(|i| i.date).collect();
    let (Some(a), Some(b)) = (ds.iter().min(), ds.iter().max()) else { return String::new() };
    let h = (*b - *a).num_seconds() as f64 / 3600.0;
    if h < 1.0 {
        "한 시간 안에 이어진 보도".into()
    } else if h < 48.0 {
        format!("{}시간에 걸친 보도", h.round() as i64)
    } else {
        format!("{}일에 걸친 보도", (h / 24.0).round() as i64)
    }
}

fn weekday_short(w: chrono::Weekday) -> &'static str {
    use chrono::Weekday::*;
    match w {
        Mon => "월",
        Tue => "화",
        Wed => "수",
        Thu => "목",
        Fri => "금",
        Sat => "토",
        Sun => "일",
    }
}

// 앞 보도와의 간격: 날이 바뀌면 날짜, 아니면 'N시간 뒤'(30분 안이면 표시 안 함)
pub fn gap(items: &[NewsItem], i: usize) -> Option<String> {
    if i == 0 {
        return None;
    }
    let (a, b) = (items[i - 1].date?, items[i].date?);
    let (la, lb) = (a.with_timezone(&Local), b.with_timezone(&Local));
    if la.date_naive() != lb.date_naive() {
        return Some(format!("{}월 {}일 ({})", lb.month(), lb.day(), weekday_short(lb.weekday())));
    }
    let m = (b - a).num_seconds() as f64 / 60.0;
    if m < 30.0 {
        None
    } else if m < 90.0 {
        Some(format!("{}분 뒤", m.round() as i64))
    } else {
        Some(format!("{}시간 뒤", (m / 60.0).round() as i64))
    }
}

// 요약의 첫 문장(HTML 꼬리표 제거, 제목과 같으면 생략)
pub fn lede(it: &NewsItem) -> Option<String> {
    let t = dropcap_core::feed_parser::plain::clean(&it.summary);
    let head: String = it.title.chars().take(20).collect();
    if t.chars().count() <= 20 || t.starts_with(&head) {
        return None;
    }
    Some(t.chars().take(220).collect())
}

// MARK: 한 스토리(M-14): 한눈에 요약 → 해외·국내 나란히 → 보도 줄기(선이 그려지며 차례로, 간격·첫 보도) · 팔로우
pub fn story(id: &str, back: Rc<dyn Fn()>) -> (gtk::Widget, gtk::ScrolledWindow) {
    let (v, scroll) = page_box();
    let bk = gtk::Button::new();
    bk.add_css_class("flat");
    bk.set_halign(gtk::Align::Start);
    bk.set_margin_top(24);
    let bb = gtk::Box::new(gtk::Orientation::Horizontal, 4);
    bb.append(&widgets::icon("go-previous-symbolic", 14));
    bb.append(&gtk::Label::new(Some("스토리")));
    bk.set_child(Some(&bb));
    bk.connect_clicked(move |_| back());
    v.append(&bk);
    let body = gtk::Box::new(gtk::Orientation::Vertical, 0);
    v.append(&body);
    let core = ui().core.clone();
    let cid = id.to_string();
    bg(
        async move {
            let items: Vec<NewsItem> = core.story_items(&cid);
            (core.db.cluster(&cid), items)
        },
        {
            let id = id.to_string();
            move |(cluster, items)| fill_story(&body, &id, cluster, items)
        },
    );
    (scroll.clone().upcast(), scroll)
}

fn fill_story(body: &gtk::Box, id: &str, cluster: Option<Cluster>, items: Vec<NewsItem>) {
    let core = ui().core.clone();
    let title = label(cluster.as_ref().map(|c| c.title.as_str()).unwrap_or("스토리"), 30.0, 700, &["dc-display"]);
    title.set_margin_top(10);
    body.append(&title);
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 10);
    row.set_margin_top(6);
    row.set_margin_bottom(22);
    let info = label(&format!("{}곳 보도 · {}", items.len(), span(&items)), 13.0, 400, &["dc-secondary"]);
    info.set_hexpand(true);
    row.append(&info);
    let follow = gtk::Button::new();
    let set_follow_label = {
        let follow = follow.clone();
        move |on: bool| {
            let bx = gtk::Box::new(gtk::Orientation::Horizontal, 6);
            bx.append(&widgets::icon(if on { "preferences-system-notifications-symbolic" } else { "alarm-symbolic" }, 13));
            bx.append(&label(if on { "팔로우 중" } else { "이 스토리 팔로우" }, 12.5, 600, &[]));
            follow.set_child(Some(&bx));
            if on {
                tint(&follow, "#FF9500");
            }
        }
    };
    set_follow_label(core.is_following(id));
    follow.set_tooltip_text(Some("새 보도가 이 스토리에 붙으면 알림"));
    {
        let id = id.to_string();
        let n = items.len() as i64;
        let c = core.clone();
        let set = set_follow_label.clone();
        follow.connect_clicked(move |_| {
            let on = !c.is_following(&id);
            c.set_following(&id, on, n);
            set(on);
        });
    }
    row.append(&follow);
    body.append(&row);
    core.mark_story_seen(id, items.len() as i64);
    // 한눈에(여러 보도를 합친 요약 — Ollama 가 있을 때만)
    if let Some(c) = cluster.clone() {
        let digest_box = gtk::Box::new(gtk::Orientation::Vertical, 8);
        digest_box.add_css_class("dc-soft");
        digest_box.set_margin_bottom(26);
        digest_box.set_visible(false);
        let inner = gtk::Box::new(gtk::Orientation::Vertical, 8);
        inner.set_margin_top(16);
        inner.set_margin_bottom(16);
        inner.set_margin_start(16);
        inner.set_margin_end(16);
        let h = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        h.append(&widgets::icon("format-justify-left-symbolic", 13));
        h.append(&label("한눈에", 12.5, 700, &["dc-secondary"]));
        inner.append(&h);
        let wait = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let sp = gtk::Spinner::new();
        sp.start();
        wait.append(&sp);
        wait.append(&label("여러 보도를 합쳐 요약하는 중…", 13.0, 400, &["dc-secondary"]));
        inner.append(&wait);
        digest_box.append(&inner);
        body.append(&digest_box);
        let core2 = core.clone();
        bg(
            async move {
                if !dropcap_core::summarizer::available().await {
                    return (false, None);
                }
                (true, core2.story_digest(&c).await)
            },
            move |(avail, d)| {
                if !avail {
                    return;
                }
                digest_box.set_visible(true);
                inner.remove(&wait);
                match d {
                    Some(lines_) => {
                        for l in lines_ {
                            let r = gtk::Box::new(gtk::Orientation::Horizontal, 8);
                            r.append(&label("•", 15.0, 400, &["dc-secondary"]));
                            r.append(&label(&l, 15.0, 400, &[]));
                            inner.append(&r);
                        }
                        inner.append(&label("여러 보도를 이 컴퓨터의 Ollama 로 합쳐 요약했습니다.", 11.0, 400, &["dc-tertiary"]));
                        widgets::fade_in(&digest_box, crate::motion::STANDARD);
                    }
                    None => digest_box.set_visible(false),
                }
            },
        );
        // 디지스트를 띄우는 동안 첫 표시(요약 중)
        let _ = Cell::new(0);
    }
    // 해외·국내 나란히(G-12)
    if let Some(r) = region_columns(&items) {
        body.append(&r);
    }
    // 보도 줄기
    let ov = gtk::Overlay::new();
    let progress = Rc::new(Cell::new(if crate::motion::enabled() { 0.0 } else { 1.0 }));
    let line = gtk::DrawingArea::builder().width_request(20).vexpand(true).build();
    line.set_halign(gtk::Align::Start);
    line.set_margin_start(0);
    {
        let p = progress.clone();
        line.set_draw_func(move |area, cr, _w, h| {
            let c = area.color();
            cr.set_source_rgba(c.red() as f64, c.green() as f64, c.blue() as f64, 0.15);
            cr.rectangle(9.0, 0.0, 2.0, h as f64 * p.get());
            let _ = cr.fill();
        });
    }
    let rows = gtk::Box::new(gtk::Orientation::Vertical, 18);
    ov.set_child(Some(&rows));
    ov.add_overlay(&line);
    ov.set_clip_overlay(&line, true);
    line.set_can_target(false);
    let mut row_widgets: Vec<gtk::Widget> = vec![];
    for (i, it) in items.iter().enumerate() {
        if let Some(g) = gap(&items, i) {
            let l = label(&g, 11.0, 600, &["dc-tertiary"]);
            l.set_margin_start(36);
            l.set_margin_top(-6);
            rows.append(&l);
        }
        let r = timeline_row(it, i == 0);
        rows.append(&r);
        row_widgets.push(r.upcast());
    }
    body.append(&ov);
    if crate::motion::enabled() {
        for r in &row_widgets {
            r.set_opacity(0.0);
        }
        let total = (400.0 + 180.0 * items.len() as f64) as u32;
        let p = progress.clone();
        let l2 = line.clone();
        let rw = row_widgets.clone();
        let n = items.len().max(1) as f64;
        let target = adw::CallbackAnimationTarget::new(move |x| {
            p.set(x);
            l2.queue_draw();
            for (i, r) in rw.iter().enumerate() {
                if x >= (i as f64 + 1.0) / n * 0.9 && r.opacity() == 0.0 {
                    widgets::fade_in(r, crate::motion::SETTLE);
                }
            }
        });
        let anim = adw::TimedAnimation::new(&line, 0.0, 1.0, total, target);
        anim.set_easing(adw::Easing::EaseInOutCubic);
        let rw2 = row_widgets.clone();
        anim.connect_done(move |_| {
            for r in &rw2 {
                r.set_opacity(1.0);
            }
        });
        adw::prelude::AnimationExt::play(&anim);
    }
}

fn timeline_row(it: &NewsItem, first: bool) -> gtk::Box {
    let accent = widgets::source_color(&it.source_id);
    let h = gtk::Box::new(gtk::Orientation::Horizontal, 16);
    let dot = gtk::DrawingArea::builder().content_width(20).content_height(20).valign(gtk::Align::Start).build();
    {
        let a = accent.clone();
        dot.set_draw_func(move |area, cr, w, hh| {
            let (r, g, b) = dropcap_core::models::hex_rgb(&a);
            let c = area.color();
            let _ = c;
            cr.arc(w as f64 / 2.0, hh as f64 / 2.0, 9.0, 0.0, std::f64::consts::TAU);
            if first {
                cr.set_source_rgb(r, g, b);
                let _ = cr.fill_preserve();
            }
            cr.set_source_rgb(r, g, b);
            cr.set_line_width(2.0);
            let _ = cr.stroke();
        });
    }
    h.append(&dot);
    let v = gtk::Box::new(gtk::Orientation::Vertical, 6);
    v.set_hexpand(true);
    let meta = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    meta.append(&widgets::monogram(it, 18));
    meta.append(&label(&it.source_name, 12.5, 600, &[]));
    meta.append(&label(&resources::tier_label(&it.tier), 11.0, 400, &["dc-secondary"]));
    if let Some(p) = widgets::paywall_mark(it) {
        meta.append(&p);
    }
    meta.append(&label(&format!("· {}", dropcap_core::app_model::clock(it.date)), 11.5, 400, &["dc-secondary"]));
    if first {
        let f = label("첫 보도", 10.5, 700, &[]);
        tint(&f, &accent);
        meta.append(&f);
    }
    v.append(&meta);
    let b = gtk::Button::new();
    b.add_css_class("flat");
    b.add_css_class("dc-soft");
    let inner = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    inner.set_margin_top(14);
    inner.set_margin_bottom(14);
    inner.set_margin_start(14);
    inner.set_margin_end(14);
    let tv = gtk::Box::new(gtk::Orientation::Vertical, 6);
    tv.set_hexpand(true);
    tv.append(&label(it.display_title(), 16.0, 600, &["dc-display"]));
    if let Some(l) = lede(it) {
        let ll = label(&l, 13.0, 400, &["dc-secondary"]);
        lines(&ll, 2);
        tv.append(&ll);
    }
    inner.append(&tv);
    if has_photo(it) {
        let img = RemoteImage::new(it.image.as_deref(), it.category(), &accent, 92, 62);
        img.root.set_size_request(92, 62);
        img.root.set_valign(gtk::Align::Start);
        round(&img.root, 9);
        inner.append(&img.root);
    }
    b.set_child(Some(&inner));
    let item = it.clone();
    b.connect_clicked(move |b| open_card(&item, b));
    v.append(&b);
    h.append(&v);
    h
}

// MARK: 저장(M-15): 카드 격자 + "보관됨"
pub fn saved() -> (gtk::Widget, gtk::ScrolledWindow) {
    let (v, scroll) = wide_box();
    let core = ui().core.clone();
    let list = core.state().saved;
    // 옆 목록 '저장 N' 과 같은 수
    v.append(&title_with_count("저장", &format!("{}건", list.len())));
    v.append(&label("저장한 기사는 번역까지 이 컴퓨터에 보관돼 인터넷 없이도 읽을 수 있습니다.", 13.0, 400, &["dc-secondary"]));
    // 피드에 없는 기사도 주소로 저장(I-05, 맥 AddURLBar(compact: false))
    let bar = crate::add_url_bar::build(false);
    bar.set_halign(gtk::Align::Start);
    bar.set_size_request(560, -1);
    v.append(&bar);
    if list.is_empty() {
        let l = label("아직 저장한 기사가 없습니다. 카드를 오른쪽 클릭해 '나중에 읽기'로 저장하세요.", 13.0, 400, &["dc-secondary"]);
        l.set_margin_top(40);
        v.append(&l);
    }
    let width = 900;
    let grid = card_grid(&list, width, |it, card| {
        if core.articles.cached(&it.link).is_none() {
            return card;
        }
        let ov = gtk::Overlay::new();
        ov.set_child(Some(&card));
        let b = gtk::Box::new(gtk::Orientation::Horizontal, 4);
        b.add_css_class("dc-kind");
        b.append(&widgets::icon("folder-download-symbolic", 11));
        b.append(&label("보관됨", 10.5, 600, &[]));
        b.set_halign(gtk::Align::End);
        b.set_valign(gtk::Align::Start);
        b.set_margin_top(10);
        b.set_margin_end(10);
        b.set_can_target(false);
        ov.add_overlay(&b);
        ov.upcast()
    });
    v.append(&grid);
    (scroll.clone().upcast(), scroll)
}

// MARK: 검색(M-16): 전체 기록에서 제목·출처·요약(2글자부터, 입력이 멈추면 0.25초 뒤)
thread_local! {
    // 다음에 여는 검색 지면에 미리 넣을 낱말(지켜볼 낱말 정리 물방울을 눌렀을 때)
    pub static PENDING_QUERY: std::cell::RefCell<Option<String>> = const { std::cell::RefCell::new(None) };
}

pub const OLDER_PAGE: i64 = 200; // 보관 표에서 한 번에 꺼내는 오래된 기사 수

pub fn search() -> (gtk::Widget, gtk::ScrolledWindow) {
    let (v, scroll) = wide_box();
    v.append(&big_title("검색"));
    let bar = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    let entry = gtk::SearchEntry::new();
    entry.set_placeholder_text(Some("모든 기록에서 제목·출처·요약 검색"));
    entry.set_search_delay(250);
    entry.set_hexpand(true);
    bar.append(&entry);
    // 오래된 기사 포함: 보관함에 옮겨 둔 지난 기사(제목·출처)에서도 찾는다(맥 magSearchArchive — 기본 켬)
    let include = gtk::CheckButton::with_label("오래된 기사 포함");
    include.set_active(ui().prefs.borrow().mag_search_archive);
    include.set_tooltip_text(Some("보관함에 옮겨 둔 지난 기사(제목·출처)에서도 찾습니다"));
    bar.append(&include);
    v.append(&bar);
    let count = label("", 13.0, 400, &["dc-secondary"]);
    v.append(&count);
    // 빈 검색 화면: 지켜볼 낱말·최근 검색어를 눌러 바로 찾기, 무엇을 찾는지 안내(맥 SearchView.emptyState)
    let empty = gtk::Box::new(gtk::Orientation::Vertical, 16);
    empty.set_margin_top(6);
    v.append(&empty);
    let results = gtk::Box::new(gtk::Orientation::Vertical, 0);
    v.append(&results);
    // 보관 표에서 찾은 오래된 기사(최신순 200건씩): 머리 · 줄 목록 · 더 보기
    let older_box = gtk::Box::new(gtk::Orientation::Vertical, 8);
    older_box.set_margin_top(16);
    v.append(&older_box);
    let serial = Rc::new(Cell::new(0u64));
    let last_hit: Rc<RefCell<String>> = Rc::new(RefCell::new(String::new())); // 결과가 있었던 마지막 낱말(떠날 때 최근 검색에)
    let current_older: Rc<RefCell<Option<Rc<OlderList>>>> = Rc::new(RefCell::new(None)); // 지금 낱말의 오래된 기사 목록
    let run: Rc<dyn Fn(String)> = {
        let results = results.clone();
        let count = count.clone();
        let empty = empty.clone();
        let older_box = older_box.clone();
        let last_hit = last_hit.clone();
        let current_older = current_older.clone();
        let entry = entry.clone();
        Rc::new(move |q: String| {
            let n = serial.get() + 1;
            serial.set(n);
            empty.set_visible(q.is_empty());
            if q.chars().count() < 2 {
                widgets::clear_box(&results);
                widgets::clear_box(&older_box);
                *current_older.borrow_mut() = None;
                count.set_text("");
                return;
            }
            let core = ui().core.clone();
            let with_older = ui().prefs.borrow().mag_search_archive;
            let results = results.clone();
            let count = count.clone();
            let older_box = older_box.clone();
            let serial = serial.clone();
            let last_hit = last_hit.clone();
            let current_older = current_older.clone();
            let entry = entry.clone();
            let q2 = q.clone();
            bg(
                async move {
                    let r = core.search(&q2, 200);
                    let o = if with_older { core.archive_reader.search(&q2, OLDER_PAGE, 0, &core.archive_visibility()) } else { vec![] };
                    (r, o)
                },
                move |(found, older)| {
                    if serial.get() != n || entry.text() != q.as_str() {
                        return; // 그새 다른 글자를 입력함(찾기 시작한 뒤 낱말이 바뀜)
                    }
                    if !found.is_empty() || !older.is_empty() {
                        *last_hit.borrow_mut() = q.clone();
                    }
                    widgets::clear_box(&results);
                    results.append(&card_grid(&found, 900, |_, c| c));
                    let fetched = older.len() as i64;
                    // 최근 결과에 이미 있는 링크는 빼고
                    let links: std::collections::HashSet<&str> = found.iter().map(|i| i.link.as_str()).collect();
                    let older: Vec<_> = older.into_iter().filter(|a| !links.contains(a.link.as_str())).collect();
                    *current_older.borrow_mut() = Some(OlderList::fill(&older_box, &count, &entry, &q, found.len(), older, fetched, n, &serial));
                },
            );
        })
    };
    fill_search_empty(&empty, &entry);
    {
        let (r, e) = (run.clone(), entry.clone());
        include.connect_toggled(move |c| {
            let on = c.is_active();
            ui().update_prefs(|p| p.mag_search_archive = on);
            r(e.text().to_string());
        });
    }
    let r1 = run.clone();
    entry.connect_search_changed(move |e| r1(e.text().to_string()));
    entry.connect_activate(move |e| {
        remember_search(&e.text());
        run(e.text().to_string())
    });
    scroll.connect_unmap(move |_| {
        let q = last_hit.borrow().clone();
        if !q.is_empty() {
            remember_search(&q);
        }
    });
    if let Some(q) = PENDING_QUERY.with(|p| p.borrow_mut().take()) {
        entry.set_text(&q);
    }
    let e2 = entry.clone();
    widgets::later(300, move || {
        e2.grab_focus();
    });
    (scroll.clone().upcast(), scroll)
}

// 검색 지면의 '오래된 기사' 목록: 보관 표에서 최신순 200건씩, '200건 더 보기'로 이어서
struct OlderList {
    q: String,
    recent: usize,
    items: RefCell<Vec<dropcap_core::archive::ArchivedItem>>,
    offset: Cell<i64>, // 보관 표에서 지금까지 꺼낸 수(거르기 전 — 다음 쪽의 시작)
    more: Cell<bool>,
    list: gtk::Box,
    more_button: gtk::Button,
    count: gtk::Label,
    entry: gtk::SearchEntry,
    serial: Rc<Cell<u64>>,
    n: u64,
}

impl OlderList {
    #[allow(clippy::too_many_arguments)]
    fn fill(
        holder: &gtk::Box,
        count: &gtk::Label,
        entry: &gtk::SearchEntry,
        q: &str,
        recent: usize,
        older: Vec<dropcap_core::archive::ArchivedItem>,
        fetched: i64,
        n: u64,
        serial: &Rc<Cell<u64>>,
    ) -> Rc<OlderList> {
        widgets::clear_box(holder);
        let list = gtk::Box::new(gtk::Orientation::Vertical, 0);
        let more_button = gtk::Button::with_label(&format!("{OLDER_PAGE}건 더 보기"));
        more_button.add_css_class("flat");
        more_button.set_halign(gtk::Align::Start);
        let me = Rc::new(OlderList {
            q: q.to_string(),
            recent,
            items: RefCell::new(vec![]),
            offset: Cell::new(0),
            more: Cell::new(false),
            list: list.clone(),
            more_button: more_button.clone(),
            count: count.clone(),
            entry: entry.clone(),
            serial: serial.clone(),
            n,
        });
        holder.append(&label("오래된 기사", 20.0, 700, &["dc-title"]));
        holder.append(&list);
        holder.append(&more_button);
        me.add(older, fetched);
        holder.set_visible(!me.items.borrow().is_empty());
        let weak = Rc::downgrade(&me);
        more_button.connect_clicked(move |b| {
            let Some(me) = weak.upgrade() else { return };
            b.set_sensitive(false);
            let core = ui().core.clone();
            let (q, off) = (me.q.clone(), me.offset.get());
            let me2 = me.clone();
            bg(async move { core.archive_reader.search(&q, OLDER_PAGE, off, &core.archive_visibility()) }, move |o| {
                if me2.serial.get() != me2.n || me2.entry.text() != me2.q.as_str() {
                    return; // 그새 다른 낱말로 찾음 — 이어 붙이지 않는다
                }
                let fetched = o.len() as i64;
                me2.add(o, fetched);
                me2.more_button.set_sensitive(true);
            });
        });
        me
    }

    fn add(&self, o: Vec<dropcap_core::archive::ArchivedItem>, fetched: i64) {
        self.offset.set(self.offset.get() + fetched);
        self.more.set(fetched >= OLDER_PAGE);
        let have: std::collections::HashSet<String> = self.items.borrow().iter().map(|a| a.id()).collect();
        for a in o.into_iter().filter(|a| !have.contains(&a.id())) {
            if !self.items.borrow().is_empty() {
                let s = gtk::Separator::new(gtk::Orientation::Horizontal);
                s.set_opacity(0.5);
                self.list.append(&s);
            }
            self.list.append(&crate::magazine_archive::archive_row(&a, true));
            self.items.borrow_mut().push(a);
        }
        self.more_button.set_visible(self.more.get());
        let n = self.items.borrow().len();
        self.count.set_text(&if n == 0 {
            format!("{}건", self.recent)
        } else {
            format!("최근 {}건 · 오래된 기사 {n}{}", self.recent, if self.more.get() { "건 넘음" } else { "건" })
        });
    }
}

fn remember_search(q: &str) {
    let now = ui().prefs.borrow().mag_recent_searches.clone();
    let next = dropcap_core::magazine::remember_search(q, &now);
    if next != now {
        ui().update_prefs(|p| p.mag_recent_searches = next);
    }
}

fn fill_search_empty(empty: &gtk::Box, entry: &gtk::SearchEntry) {
    widgets::clear_box(empty);
    let watch = ui().core.state().settings.watch_keywords;
    let recent = ui().prefs.borrow().mag_recent_searches.clone();
    let row = |title: &str, words: &[String], icon_name: &str| -> gtk::Box {
        let col = gtk::Box::new(gtk::Orientation::Vertical, 8);
        let h = gtk::Box::new(gtk::Orientation::Horizontal, 5);
        h.append(&widgets::icon(icon_name, 12));
        h.append(&label(title, 12.5, 600, &["dc-secondary"]));
        col.append(&h);
        let chips = gtk::FlowBox::new();
        chips.set_selection_mode(gtk::SelectionMode::None);
        chips.set_column_spacing(6);
        chips.set_row_spacing(6);
        for w in words {
            let b = crate::menu_chips::chip(w, icon_name, "#3584E4", false, None, false);
            let (e, w) = (entry.clone(), w.clone());
            b.connect_clicked(move |_| e.set_text(&w));
            chips.insert(&b, -1);
        }
        col.append(&chips);
        col
    };
    if !watch.is_empty() {
        empty.append(&row("지켜볼 낱말", &watch, "view-reveal-symbolic"));
    }
    if !recent.is_empty() {
        empty.append(&row("최근 검색", &recent, "document-open-recent-symbolic"));
        let clear = gtk::Button::with_label("최근 검색 지우기");
        clear.add_css_class("flat");
        clear.set_halign(gtk::Align::Start);
        let (em, en) = (empty.clone(), entry.clone());
        clear.connect_clicked(move |_| {
            ui().update_prefs(|p| p.mag_recent_searches.clear());
            fill_search_empty(&em, &en);
        });
        empty.append(&clear);
    }
    let help = gtk::Box::new(gtk::Orientation::Vertical, 4);
    help.append(&label("이 컴퓨터에 모인 최근 기사(지난 호 포함)의 제목·출처·요약에서 찾고, '오래된 기사 포함'을 켜 두면 보관함의 지난 기사 제목·출처에서도 찾습니다.", 13.0, 400, &["dc-secondary"]));
    help.append(&label("회사·인물 이름이나 출처 이름(예: 연합뉴스)으로도 찾을 수 있습니다. Ctrl+F 로 언제든 이 화면을 엽니다.", 13.0, 400, &["dc-secondary"]));
    if watch.is_empty() {
        help.append(&label("설정 › 거르기의 '지켜볼 낱말'을 넣으면 여기서 바로 누를 수 있습니다.", 13.0, 400, &["dc-secondary"]));
    }
    empty.append(&help);
}

// MARK: 스크랩북(M-17·M-18)
struct ScrapPage {
    window: adw::ApplicationWindow,
    body: gtk::Box,
    folder: RefCell<String>,
}

// 마지막으로 스크랩한 폴더, 없으면 내용이 있는 첫 폴더
fn initial_folder() -> String {
    let ui = ui();
    let book = ui.scrapbook.borrow();
    if let Some(last) = ui.prefs.borrow().last_scrap_collection.clone() {
        if book.collections.contains(&last) {
            return last;
        }
    }
    let last = book.last_collection();
    if book.collections.contains(&last) && book.scraps.iter().any(|s| s.collection == last) {
        return last;
    }
    book.collections.iter().find(|c| book.scraps.iter().any(|s| &s.collection == *c)).cloned().unwrap_or_else(|| DEFAULT_COLLECTION.into())
}

pub fn scrapbook(window: &adw::ApplicationWindow) -> (gtk::Widget, gtk::ScrolledWindow) {
    let body = gtk::Box::new(gtk::Orientation::Vertical, 18);
    body.set_margin_start(36);
    body.set_margin_end(36);
    body.set_margin_bottom(40);
    let clamp = adw::Clamp::builder().maximum_size(860).tightening_threshold(860).child(&body).build();
    clamp.set_halign(gtk::Align::Start);
    let scroll = gtk::ScrolledWindow::builder().hscrollbar_policy(gtk::PolicyType::Never).child(&clamp).vexpand(true).hexpand(true).build();
    let me = Rc::new(ScrapPage { window: window.clone(), body, folder: RefCell::new(initial_folder()) });
    me.render();
    // 스크랩이 바뀌면(읽기 창에서 더함 등) 다시 그린다
    {
        let weak = Rc::downgrade(&me);
        ui().listen(move |e| {
            if let (Some(m), UiEvent::State) = (weak.upgrade(), e) {
                ui().scrapbook.borrow_mut().reload();
                if !ui().scrapbook.borrow().scraps.iter().any(|s| s.collection == *m.folder.borrow()) {
                    *m.folder.borrow_mut() = initial_folder();
                }
                m.render();
            }
        });
    }
    // 화면에 붙어 있는 동안 살려 둔다
    unsafe {
        scroll.set_data("dc-scrap-page", me);
    }
    (scroll.clone().upcast(), scroll)
}

impl ScrapPage {
    fn render(self: &Rc<Self>) {
        let u = ui();
        widgets::clear_box(&self.body);
        let folder = self.folder.borrow().clone();
        let (list, collections, all): (Vec<Scrap>, Vec<String>, Vec<Scrap>) = {
            let book = u.scrapbook.borrow();
            (book.scraps.iter().filter(|s| s.collection == folder).cloned().collect(), book.collections.clone(), book.scraps.clone())
        };
        let head = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        head.set_margin_top(28);
        let t = label("스크랩북", 34.0, 700, &["dc-display"]);
        head.append(&t);
        // 옆 목록 '스크랩북 N' 과 같은 수(폴더별은 아래 칩)
        let n = label(&format!("모두 {}개", all.len()), 15.0, 600, &["dc-secondary"]);
        n.set_valign(gtk::Align::End);
        n.set_margin_bottom(7);
        n.set_hexpand(true);
        n.set_xalign(0.0);
        head.append(&n);
        let copy = gtk::Button::with_label("Markdown 복사");
        copy.set_sensitive(!list.is_empty());
        {
            let f = folder.clone();
            copy.connect_clicked(move |b| {
                copy_text(&ui().scrapbook.borrow().markdown(&f));
                b.set_label("복사됨");
                let b2 = b.clone();
                widgets::later(1500, move || b2.set_label("Markdown 복사"));
            });
        }
        head.append(&copy);
        let save = gtk::Button::with_label("파일로 저장");
        save.set_sensitive(!list.is_empty());
        {
            let f = folder.clone();
            let win = self.window.clone();
            save.connect_clicked(move |_| save_markdown(&win, &f));
        }
        head.append(&save);
        self.body.append(&head);
        self.body.append(&label("읽기 창에서 문단에 마우스를 올려 ✂︎ 를 누르거나, 도구막대의 스크랩으로 기사를 모아 두세요. 폴더째 Markdown 으로 내보낼 수 있습니다.", 13.0, 400, &["dc-secondary"]));
        if let Some(w) = weekly_quotes(&all) {
            self.body.append(&w);
        }
        // 폴더 칩(개수)
        let chips = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        for c in &collections {
            let n = all.iter().filter(|s| &s.collection == c).count();
            let on = *c == folder;
            let b = gtk::Button::new();
            b.add_css_class("flat");
            b.add_css_class("dc-folder");
            if on {
                b.add_css_class("dc-folder-on");
            }
            let bx = gtk::Box::new(gtk::Orientation::Horizontal, 5);
            bx.append(&widgets::icon(if on { "folder-open-symbolic" } else { "folder-symbolic" }, 13));
            bx.append(&label(&format!("{c} {n}"), 12.5, if on { 600 } else { 400 }, &[]));
            b.set_child(Some(&bx));
            {
                let weak = Rc::downgrade(self);
                let c2 = c.clone();
                b.connect_clicked(move |_| {
                    if let Some(m) = weak.upgrade() {
                        *m.folder.borrow_mut() = c2.clone();
                        let m2 = m.clone();
                        glib::idle_add_local_once(move || m2.render());
                    }
                });
            }
            // 오른쪽 클릭: 이름 바꾸기
            let click = gtk::GestureClick::new();
            click.set_button(3);
            {
                let weak = Rc::downgrade(self);
                let c2 = c.clone();
                click.connect_pressed(move |_, _, _, _| {
                    if let Some(m) = weak.upgrade() {
                        m.ask_name("폴더 이름 바꾸기", "바꾸기", &c2, {
                            let from = c2.clone();
                            let weak = Rc::downgrade(&m);
                            move |name| {
                                let ok = ui().scrapbook.borrow_mut().rename(&from, &name);
                                if let (true, Some(m)) = (ok, weak.upgrade()) {
                                    *m.folder.borrow_mut() = name.trim().to_string();
                                    m.render();
                                }
                            }
                        });
                    }
                });
            }
            b.add_controller(click);
            chips.append(&b);
        }
        let add = gtk::Button::new();
        add.add_css_class("flat");
        let ab = gtk::Box::new(gtk::Orientation::Horizontal, 4);
        ab.append(&widgets::icon("list-add-symbolic", 12));
        ab.append(&label("새 폴더", 12.5, 400, &[]));
        add.set_child(Some(&ab));
        {
            let weak = Rc::downgrade(self);
            add.connect_clicked(move |_| {
                if let Some(m) = weak.upgrade() {
                    let weak2 = Rc::downgrade(&m);
                    m.ask_name("새 스크랩 폴더", "만들기", "", move |name| {
                        let ok = ui().scrapbook.borrow_mut().create_collection(&name);
                        if let (true, Some(m)) = (ok, weak2.upgrade()) {
                            *m.folder.borrow_mut() = name.trim().to_string();
                            m.render();
                        }
                    });
                }
            });
        }
        chips.append(&add);
        let cs = gtk::ScrolledWindow::builder().vscrollbar_policy(gtk::PolicyType::Never).child(&chips).build();
        self.body.append(&cs);
        // 기사별로 묶기(최근 스크랩 순)
        let mut order: Vec<String> = vec![];
        let mut groups: std::collections::HashMap<String, Vec<Scrap>> = Default::default();
        for s in &list {
            let k = s.item.key();
            if !groups.contains_key(&k) {
                order.push(k.clone());
            }
            groups.entry(k).or_default().push(s.clone());
        }
        if order.is_empty() {
            let e = gtk::Box::new(gtk::Orientation::Vertical, 8);
            e.set_margin_top(40);
            e.set_margin_bottom(40);
            let i = widgets::icon("edit-cut-symbolic", 30);
            i.set_halign(gtk::Align::Start);
            i.add_css_class("dc-tertiary");
            e.append(&i);
            e.append(&label("이 폴더는 비어 있습니다", 18.0, 600, &["dc-display"]));
            self.body.append(&e);
        }
        for (i, k) in order.iter().enumerate() {
            let mut g = groups.remove(k).unwrap_or_default();
            g.sort_by_key(|s| s.created);
            let card = self.group_card(&g, &collections);
            stagger(&card, i);
            self.body.append(&card);
        }
    }

    fn group_card(self: &Rc<Self>, scraps: &[Scrap], collections: &[String]) -> gtk::Box {
        let item = scraps[0].item.clone();
        let v = gtk::Box::new(gtk::Orientation::Vertical, 12);
        v.add_css_class("dc-soft");
        let inner = gtk::Box::new(gtk::Orientation::Vertical, 12);
        inner.set_margin_top(18);
        inner.set_margin_bottom(18);
        inner.set_margin_start(18);
        inner.set_margin_end(18);
        let b = gtk::Button::new();
        b.add_css_class("flat");
        let h = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        if has_photo(&item) {
            let img = RemoteImage::new(item.image.as_deref(), item.category(), &widgets::source_color(&item.source_id), 84, 56);
            img.root.set_size_request(84, 56);
            img.root.set_valign(gtk::Align::Start);
            round(&img.root, 9);
            h.append(&img.root);
        }
        let tv = gtk::Box::new(gtk::Orientation::Vertical, 4);
        tv.set_hexpand(true);
        tv.append(&label(item.display_title(), 16.0, 600, &["dc-display"]));
        tv.append(&label(&format!("{} · {}", item.source_name, widgets::time_text(&item)), 12.0, 400, &["dc-secondary"]));
        h.append(&tv);
        b.set_child(Some(&h));
        {
            let it = item.clone();
            b.connect_clicked(move |b| open_card(&it, b));
        }
        inner.append(&b);
        for s in scraps {
            inner.append(&self.scrap_row(s, collections));
        }
        v.append(&inner);
        v
    }

    fn scrap_row(self: &Rc<Self>, s: &Scrap, collections: &[String]) -> gtk::Box {
        let v = gtk::Box::new(gtk::Orientation::Vertical, 8);
        v.set_margin_top(4);
        v.set_margin_bottom(4);
        match &s.quote {
            Some(q) => {
                let qb = gtk::Box::new(gtk::Orientation::Vertical, 6);
                qb.add_css_class("dc-quote");
                let ql = label(q, 14.5, 400, &[]);
                ql.set_selectable(true);
                qb.append(&ql);
                if let Some(o) = s.quote_original.as_ref().filter(|o| *o != q) {
                    let ol = label(o, 12.5, 400, &["dc-secondary"]);
                    ol.set_selectable(true);
                    qb.append(&ol);
                }
                v.append(&qb);
            }
            None => {
                let h = gtk::Box::new(gtk::Orientation::Horizontal, 6);
                h.append(&widgets::icon("text-x-generic-symbolic", 12));
                h.append(&label("기사 전체를 스크랩", 12.0, 400, &[]));
                h.add_css_class("dc-secondary");
                v.append(&h);
            }
        }
        // 메모(바로 저장: Enter·초점을 잃을 때)
        let h = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        h.append(&widgets::icon("document-edit-symbolic", 11));
        let memo = gtk::Entry::new();
        memo.set_has_frame(false);
        memo.set_placeholder_text(Some("메모 남기기"));
        memo.set_text(&s.memo);
        memo.set_hexpand(true);
        let save_memo = {
            let id = s.id.clone();
            move |text: String| {
                let ui = ui();
                let mut book = ui.scrapbook.borrow_mut();
                if let Some(mut sc) = book.scraps.iter().find(|x| x.id == id).cloned() {
                    if sc.memo != text {
                        sc.memo = text;
                        book.update(&sc);
                    }
                }
            }
        };
        {
            let f = save_memo.clone();
            memo.connect_activate(move |e| f(e.text().to_string()));
        }
        let focus = gtk::EventControllerFocus::new();
        {
            let m = memo.clone();
            focus.connect_leave(move |_| save_memo(m.text().to_string()));
        }
        memo.add_controller(focus);
        h.append(&memo);
        // … 메뉴: 다른 폴더로 옮기기 · 지우기
        let menu = gio::Menu::new();
        let group = gio::SimpleActionGroup::new();
        let mv = gio::SimpleAction::new("move", Some(glib::VariantTy::STRING));
        {
            let id = s.id.clone();
            let m2 = memo.clone();
            let weak = Rc::downgrade(self);
            mv.connect_activate(move |_, v| {
                let Some(to) = v.and_then(|v| v.str().map(|x| x.to_string())) else { return };
                {
                    let ui = ui();
                    let mut book = ui.scrapbook.borrow_mut();
                    if let Some(mut sc) = book.scraps.iter().find(|x| x.id == id).cloned() {
                        sc.collection = to;
                        sc.memo = m2.text().to_string();
                        book.update(&sc);
                    }
                }
                if let Some(m) = weak.upgrade() {
                    let m2 = m.clone();
                    glib::idle_add_local_once(move || m2.render());
                }
            });
        }
        group.add_action(&mv);
        let moves = gio::Menu::new();
        for c in collections.iter().filter(|c| **c != s.collection) {
            let mi = gio::MenuItem::new(Some(&format!("‘{c}’로 옮기기")), None);
            mi.set_action_and_target_value(Some("scrap.move"), Some(&c.to_variant()));
            moves.append_item(&mi);
        }
        menu.append_section(None, &moves);
        let del = gio::SimpleAction::new("delete", None);
        {
            let id = s.id.clone();
            let weak = Rc::downgrade(self);
            del.connect_activate(move |_, _| {
                ui().scrapbook.borrow_mut().remove(&id);
                if let Some(m) = weak.upgrade() {
                    let m2 = m.clone();
                    glib::idle_add_local_once(move || m2.render());
                }
            });
        }
        group.add_action(&del);
        let dm = gio::Menu::new();
        dm.append(Some("스크랩 지우기"), Some("scrap.delete"));
        menu.append_section(None, &dm);
        let mb = gtk::MenuButton::new();
        mb.set_icon_name("view-more-symbolic");
        mb.add_css_class("flat");
        mb.set_menu_model(Some(&menu));
        mb.set_opacity(0.4);
        mb.insert_action_group("scrap", Some(&group));
        let hover = gtk::EventControllerMotion::new();
        {
            let m = mb.clone();
            hover.connect_enter(move |_, _, _| m.set_opacity(1.0));
        }
        {
            let m = mb.clone();
            hover.connect_leave(move |_| m.set_opacity(0.4));
        }
        v.add_controller(hover);
        h.append(&mb);
        v.append(&h);
        v
    }

    // 폴더 이름 묻기(새 폴더·이름 바꾸기)
    fn ask_name(self: &Rc<Self>, title: &str, ok: &str, initial: &str, done: impl Fn(String) + 'static) {
        let d = adw::AlertDialog::new(Some(title), None);
        let entry = gtk::Entry::new();
        entry.set_placeholder_text(Some("폴더 이름"));
        entry.set_text(initial);
        entry.set_activates_default(true);
        d.set_extra_child(Some(&entry));
        d.add_responses(&[("cancel", "취소"), ("ok", ok)]);
        d.set_default_response(Some("ok"));
        d.set_close_response("cancel");
        d.set_response_appearance("ok", adw::ResponseAppearance::Suggested);
        let e = entry.clone();
        d.connect_response(Some("ok"), move |_, _| done(e.text().to_string()));
        d.present(Some(&self.window));
    }
}

// 파일로 저장(M-18): 형식은 핵심 Scrapbook.render 그대로
fn save_markdown(win: &adw::ApplicationWindow, folder: &str) {
    let dialog = gtk::FileDialog::new();
    dialog.set_initial_name(Some(&format!("{folder}.md")));
    let f = folder.to_string();
    dialog.save(Some(win), None::<&gio::Cancellable>, move |r| {
        let Ok(file) = r else { return };
        let Some(path) = file.path() else { return };
        let md = ui().scrapbook.borrow().markdown(&f);
        if let Err(e) = std::fs::write(&path, md) {
            log::warn!("[스크랩북] 저장 실패: {e}");
        }
    });
}

// 일요일 저녁(17시부터) 스크랩북 첫머리에 '이번 주 모은 문장'(맥 WeeklyQuotes, M-27) — 지난 7일 동안 문단으로 스크랩한 글.
// 고르는 규칙은 core(magazine::pick_weekly_quotes · is_sunday_evening, 시험 magazine_catchup_tests)
fn weekly_quotes(all: &[Scrap]) -> Option<gtk::Box> {
    let list = dropcap_core::magazine::pick_weekly_quotes(all, Utc::now(), 6);
    if !dropcap_core::magazine::is_sunday_evening(&Local::now()) || list.is_empty() {
        return None;
    }
    let v = gtk::Box::new(gtk::Orientation::Vertical, 14);
    v.add_css_class("dc-weekly");
    let h = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let t = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    t.append(&widgets::icon("format-text-italic-symbolic", 16));
    t.append(&label("이번 주 모은 문장", 20.0, 700, &["dc-display"]));
    t.set_hexpand(true);
    h.append(&t);
    h.append(&label(&format!("{}개 · 지난 7일", list.len()), 12.0, 400, &["dc-secondary"]));
    v.append(&h);
    for s in list {
        let q = gtk::Box::new(gtk::Orientation::Vertical, 5);
        q.add_css_class("dc-quote");
        let ql = label(&format!("“{}”", s.quote.clone().unwrap_or_default()), 14.5, 400, &[]);
        lines(&ql, 5);
        ql.set_selectable(true);
        q.append(&ql);
        let m = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        let src = label(&s.item.source_name, 11.5, 600, &[]);
        tint(&src, &widgets::source_color(&s.item.source_id));
        m.append(&src);
        let tl = label(s.item.display_title(), 11.5, 400, &["dc-secondary"]);
        lines(&tl, 1);
        m.append(&tl);
        q.append(&m);
        // 두 번 누르면 그 기사
        let click = gtk::GestureClick::new();
        let it = s.item.clone();
        click.connect_pressed(move |g, n, _, _| {
            if n == 2 {
                if let Some(w) = g.widget() {
                    open_card(&it, &w);
                }
            }
        });
        q.add_controller(click);
        v.append(&q);
    }
    Some(v)
}
