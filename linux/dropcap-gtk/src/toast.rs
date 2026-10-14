// 물방울 알림(N-01~N-24): 맥 Toast/ToastCenter.swift · ToastView.swift 와 같은 순서·수치.
// 투명한 창 하나(400×600)에 카드를 쌓고, 카드·물방울·물은 모두 Cairo 로 직접 그린다(프레임 시계).
// 카드가 없는 곳은 클릭이 뒤 창으로 그대로 지나간다(입력 영역 = 카드 둘레).
use crate::app::{self, bg, ui};
use crate::strings;
use crate::theme;
use crate::toast_drip as drip;
use crate::toast_place as place;
use crate::toast_water as water;
use dropcap_core::models::NewsItem;
use gtk::prelude::*;
use gtk::{cairo, gdk, glib, pango};
use std::cell::RefCell;
use std::time::Instant;

pub const PANEL_W: f64 = 400.0;
pub const PANEL_H: f64 = 600.0;
pub const TOP: f64 = 46.0; // 천장에서 카드까지: 물방울이 맺히고 떨어질 자리
pub const CARD_W: f64 = 360.0;
const SIDE: f64 = 20.0;
const GAP: f64 = 10.0;
const RADIUS: f64 = 20.0;
const LIFETIME: f64 = 9.0; // 머무름
const MAX_VISIBLE: usize = 4;
const BURST_GAP_MS: u64 = 320;
const MONO: f64 = 38.0;
const THUMB: f64 = 58.0;

#[derive(Clone)]
pub enum Kind {
    News(NewsItem),
    Info(String, String),
    More(usize),
    Digest(usize),
    Bundle(String, Vec<NewsItem>), // 묶음 카드: 분야 id · 고였던 소식
    Watch(String, Vec<NewsItem>),  // 지켜볼 낱말 하루 정리: 낱말 · 걸린 소식(N-27)
}

// 묶음·지켜볼 낱말 카드의 머리: (이름, 건수, 오른쪽 안내, 색, 아이콘, 소식)
fn group_head(kind: &Kind) -> Option<(String, String, &'static str, (f64, f64, f64), &'static str, &Vec<NewsItem>)> {
    match kind {
        Kind::Bundle(sec, items) => Some((
            dropcap_core::sections::name(sec),
            format!("{}건", items.len()),
            "모아 보기",
            bundle_color(sec),
            dropcap_core::sections::by_id(sec).map(|s| s.icon()).unwrap_or("mail-unread-symbolic"),
            items,
        )),
        Kind::Watch(word, items) => Some((format!("오늘 {word} 소식"), format!("{}건", items.len()), "검색 결과", accent_color(), "view-reveal-symbolic", items)),
        _ => None,
    }
}

// 시간에 따라 바뀌는 값 하나(시작·끝·길이·쉬움 곡선)
#[derive(Clone, Copy)]
struct Anim {
    from: f64,
    to: f64,
    start: f64,
    dur: f64,
    ease: fn(f64) -> f64,
}

fn ease_out(x: f64) -> f64 {
    1.0 - (1.0 - x).powi(3)
}
fn ease_in(x: f64) -> f64 {
    x * x * x
}
fn ease_in_out(x: f64) -> f64 {
    if x < 0.5 {
        4.0 * x * x * x
    } else {
        1.0 - (-2.0 * x + 2.0).powi(3) / 2.0
    }
}
// 살짝 넘쳤다 돌아오는 용수철 느낌(0→1)
fn spring(x: f64) -> f64 {
    if x >= 1.0 {
        return 1.0;
    }
    1.0 - (-6.0 * x).exp() * (6.0 * x * 1.6).cos() * (1.0 - x)
}

impl Anim {
    fn fixed(v: f64) -> Anim {
        Anim { from: v, to: v, start: 0.0, dur: 0.0, ease: ease_out }
    }
    fn value(&self, t: f64) -> f64 {
        if self.dur <= 0.0 || t >= self.start + self.dur {
            return self.to;
        }
        if t <= self.start {
            return self.from;
        }
        let k = (self.ease)((t - self.start) / self.dur);
        self.from + (self.to - self.from) * k
    }
    fn go(&mut self, t: f64, to: f64, dur: f64, ease: fn(f64) -> f64) {
        *self = Anim { from: self.value(t), to, start: t, dur, ease };
    }
    fn moving(&self, t: f64) -> bool {
        t < self.start + self.dur
    }
}

struct Card {
    id: u64,
    kind: Kind,
    play_sound: bool,
    quick: bool, // 여러 건일 때 두 번째부터: 맺히는 단계를 건너뛰고 바로 떨어짐
    // 시간표(epoch 기준 초)
    drip_start: Option<f64>,
    land_at: f64,
    fill_start: Option<f64>,
    reveal_at: Option<f64>,
    unreveal_at: Option<f64>,
    calm_at: f64,
    drip_end: f64,
    deadline: f64,
    landed: bool,
    // 움직임
    alpha: Anim,
    shadow: Anim,
    scale: Anim,
    developed: Anim,
    hover: Anim,
    land_bump: Option<f64>,
    remaining: f64,
    leaving: bool,
    remove_at: Option<f64>,
    // 자리
    y: f64,
    vy: f64,
    height: f64,
    placed: bool,
    // 사진
    thumb: Option<String>,
    photo: Option<Photo>,
    // 그림 기억(같은 물방울 모양이면 다시 계산하지 않음)
    drip_cache: Option<([i64; 12], cairo::ImageSurface)>,
    measured: bool,
    texts: Vec<pango::Layout>,
}

struct Photo {
    color: cairo::ImageSurface,
    gray: cairo::ImageSurface, // 회색·흐림·밝게(인화 전)
}

impl Card {
    fn new(id: u64, kind: Kind) -> Card {
        Card {
            id,
            kind,
            play_sound: false,
            quick: false,
            drip_start: None,
            land_at: f64::MAX,
            fill_start: None,
            reveal_at: None,
            unreveal_at: None,
            calm_at: f64::MAX,
            drip_end: f64::MAX,
            deadline: f64::MAX,
            landed: false,
            alpha: Anim::fixed(0.0),
            shadow: Anim::fixed(0.0),
            scale: Anim::fixed(1.0),
            developed: Anim::fixed(0.0),
            hover: Anim::fixed(0.0),
            land_bump: None,
            remaining: 1.0,
            leaving: false,
            remove_at: None,
            y: TOP,
            vy: 0.0,
            height: 80.0,
            placed: false,
            thumb: None,
            photo: None,
            drip_cache: None,
            measured: false,
            texts: vec![],
        }
    }

    fn accent(&self) -> (f64, f64, f64) {
        match &self.kind {
            Kind::News(it) => dropcap_core::models::hex_rgb(&crate::widgets::source_color(&it.source_id)),
            Kind::Bundle(sec, _) => bundle_color(sec),
            _ => accent_color(),
        }
    }

    fn is_news(&self) -> bool {
        matches!(self.kind, Kind::News(_))
    }

    // 물방울이 카드 바닥까지 떨어진다
    fn land_y(&self) -> f64 {
        TOP + self.height - drip::DROP_RADIUS * 0.6
    }
}

// 강조색(안내·"N건 더" 카드): Adwaita 기본 파랑
fn accent_color() -> (f64, f64, f64) {
    dropcap_core::models::hex_rgb(if theme::is_dark() { "#78AEED" } else { "#3584E4" })
}

struct Center {
    win: Option<gtk::Window>,
    area: Option<gtk::DrawingArea>,
    cards: Vec<Card>,
    pointer: Option<(f64, f64)>,
    next_id: u64,
    epoch: Instant,
    last_tick: f64,
    last_draw: f64,
    input_rects: Vec<(f64, f64, f64, f64)>,
    hide_at: Option<f64>,
    win_alpha: Anim,
    shots_planned: bool,
    #[cfg(feature = "x11")]
    x: Option<place::x11::X>,
    #[cfg(feature = "x11")]
    screen: Option<place::x11::Rect>,
    #[cfg(feature = "x11")]
    other_since: Option<f64>,
    #[cfg(feature = "x11")]
    moving_until: f64,
    win_pos: Option<(f64, f64)>, // 창의 화면 자리(논리 좌표) — 읽기 창이 누른 카드 자리에서 커져 나오게
    menu_card: Option<u64>,      // 오른쪽 클릭 메뉴가 열린 카드(열려 있는 동안 마우스를 올린 것처럼 멈춤)
    test_checked: bool,          // 시험용 환경 변수(DROPCAP_TEST_BUNDLE)를 한 번 봤는지
}

thread_local! {
    static CENTER: RefCell<Center> = RefCell::new(Center {
        win: None,
        area: None,
        cards: vec![],
        pointer: None,
        next_id: 1,
        epoch: Instant::now(),
        last_tick: 0.0,
        last_draw: 0.0,
        input_rects: vec![],
        hide_at: None,
        win_alpha: Anim::fixed(1.0),
        shots_planned: false,
        #[cfg(feature = "x11")]
        x: None,
        #[cfg(feature = "x11")]
        screen: None,
        #[cfg(feature = "x11")]
        other_since: None,
        #[cfg(feature = "x11")]
        moving_until: 0.0,
        win_pos: None,
        menu_card: None,
        test_checked: false,
    });
}

fn now() -> f64 {
    CENTER.with(|c| c.borrow().epoch.elapsed().as_secs_f64())
}

fn reduce_motion() -> bool {
    !crate::motion::enabled()
}

fn right() -> bool {
    ui().core.settings().position == dropcap_core::store::Position::Right
}

// MARK: 공개 API
pub fn show(items: Vec<NewsItem>, sound: bool) {
    if items.is_empty() {
        return;
    }
    // 방해하지 않기(N-23): 배너를 끈 동안은 띄우지 않는다(핵심이 이미 안 읽음에 쌓아 둠)
    if !place::banners_allowed() {
        log::info!("[알림] 방해 금지 중 — 조용히 쌓음");
        return;
    }
    // 물방울을 띄울 수 없는 환경(GNOME Wayland·컴포지터 없음)은 시스템 알림으로(N-18)
    if !place::can_drip() {
        crate::sysnotify::post(items, sound);
        return;
    }
    let mut queue: Vec<(Kind, bool, bool)> = items.iter().take(3).map(|i| (Kind::News(i.clone()), false, false)).collect();
    if items.len() > 3 {
        queue.push((Kind::More(items.len() - 3), false, false));
    }
    if sound {
        queue[0].1 = true;
    }
    for q in queue.iter_mut().skip(1) {
        q.2 = true;
    }
    // 여러 건이면 0.32초 간격으로 하나씩 떨어뜨린다
    for (i, (kind, s, quick)) in queue.into_iter().enumerate() {
        if i == 0 {
            push(kind, s, quick);
        } else {
            crate::widgets::later(i as u64 * BURST_GAP_MS, move || push(kind, s, quick));
        }
    }
}

pub fn show_info(title: &str, sub: &str) {
    if !place::can_drip() {
        system_fallback(title, sub);
        return;
    }
    push(Kind::Info(title.into(), sub.into()), false, false);
}

pub fn show_digest(count: usize) {
    if !place::banners_allowed() {
        return;
    }
    if !place::can_drip() {
        system_fallback(&digest_title(), &digest_sub(count));
        return;
    }
    push(Kind::Digest(count), ui().core.settings().sound, false);
}

pub fn show_welcome() {
    show_info("Dropcap 실행 중", &format!("{}이 오면 이렇게 상단바에서 떨어집니다", strings::NEWS));
}

// 시험용(DROPCAP_TEST_BURST): 견본 3건(두 번째부터 바로 떨어짐)
pub fn show_burst_samples() {
    let samples = [
        ("openai", "OpenAI", strings::PREVIEW_TITLE_KO, dropcap_core::texts::PREVIEW_TITLE_EN),
        ("verge", "The Verge", "두 번째 소식부터는 맺히지 않고 바로 떨어집니다", "From the second item it drops straight in"),
        ("aitimes", "AI타임스", "세 번째 소식도 이어서 내려앉습니다", "The third one lands right after"),
    ];
    let items: Vec<NewsItem> = samples
        .iter()
        .map(|s| {
            let mut it = NewsItem::new(dropcap_core::app_model::PREVIEW_ID, s.3, "", s.0, &format!("{} · 미리 보기", s.1), "lab");
            it.title_ko = Some(s.2.into());
            it.date = Some(chrono::Utc::now());
            it
        })
        .collect();
    let sound = ui().core.settings().sound;
    show(items, sound);
}

// 맥 최신 문구("오늘의 브리핑")
fn digest_title() -> String {
    "오늘의 브리핑".into()
}

// 묶음 카드: 분야 색(맥 Sections.byID)
fn bundle_color(sec: &str) -> (f64, f64, f64) {
    dropcap_core::sections::by_id(sec).map(|s| dropcap_core::models::hex_rgb(&s.color)).unwrap_or_else(accent_color)
}

fn bundle_lines(items: &[NewsItem]) -> Vec<String> {
    items.iter().take(2).map(|i| format!("· {}", i.display_title())).collect()
}

fn digest_sub(n: usize) -> String {
    format!("지난 하루 소식 {n}건 — 매거진에서 보기")
}

// 물방울을 못 띄우는 곳의 안내·브리핑 카드: 데스크톱 알림으로
fn system_fallback(title: &str, sub: &str) {
    let n = gtk::gio::Notification::new(title);
    n.set_body(Some(sub));
    ui().app.send_notification(None, &n);
}

// MARK: 쌓기
fn push(kind: Kind, sound: bool, quick: bool) {
    ensure_window();
    check_test_env();
    let id = CENTER.with(|c| {
        let mut c = c.borrow_mut();
        let id = c.next_id;
        c.next_id += 1;
        let mut card = Card::new(id, kind);
        card.play_sound = sound;
        card.quick = quick;
        if let Kind::News(it) = &card.kind {
            card.thumb = it.image.clone();
        }
        c.cards.insert(0, card);
        c.hide_at = None;
        // 최대 4장
        while c.cards.len() > MAX_VISIBLE {
            c.cards.pop();
        }
        id
    });
    start(id);
    plan_shots();
    queue_draw();
}

// 시험용(DROPCAP_TEST_BUNDLE=분야 id): 처음 알림이 뜰 때 견본 묶음 카드 하나를 더 띄운다(main.rs 를 건드리지 않고 이 모듈 안에서)
fn check_test_env() {
    let first = CENTER.with(|c| !std::mem::replace(&mut c.borrow_mut().test_checked, true));
    if !first {
        return;
    }
    let Ok(sec) = std::env::var("DROPCAP_TEST_BUNDLE") else { return };
    let sec = if sec.is_empty() || sec == "1" { "economy".to_string() } else { sec };
    crate::widgets::later(2500, move || show_bundle(&sec, bundle_samples(), false));
}

fn bundle_samples() -> Vec<NewsItem> {
    [("yna-market", "연합 마켓+", "코스피, 외국인 순매수에 2,900 회복"), ("hk-finance", "한국경제", "기준금리 동결…연내 인하 가능성은 열어 둬"), ("cnbc", "CNBC", "달러 약세에 원·달러 환율 1,350원대")]
        .iter()
        .map(|(src, name, t)| {
            let mut it = NewsItem::new(dropcap_core::app_model::PREVIEW_ID, t, "", src, &format!("{name} · 미리 보기"), "kr");
            it.date = Some(chrono::Utc::now());
            it
        })
        .collect()
}

// 시험용(DROPCAP_TEST_SHOT_DIR + TOAST/BURST): 맥 App.swift 처럼 여러 시점의 알림 창을 PNG 로
fn plan_shots() {
    let env = ui().env.clone();
    if env.shot_dir.is_none() || !(env.test_toast || env.test_burst || std::env::var("DROPCAP_TEST_BUNDLE").is_ok() || std::env::var("DROPCAP_TEST_EXTRAS2").is_ok()) {
        return;
    }
    let first = CENTER.with(|c| !std::mem::replace(&mut c.borrow_mut().shots_planned, true));
    if !first {
        return;
    }
    for ms in [150u64, 300, 450, 600, 750, 900, 1050, 1300, 1700, 2300, 3400, 6000] {
        crate::widgets::later(ms, move || snapshot(&format!("toast-{ms}")));
    }
}

// 카드 하나의 움직임 시작(맥 ToastView.run)
fn start(id: u64) {
    let Some(area) = CENTER.with(|c| c.borrow().area.clone()) else { return };
    with_card(id, |card| measure(card, &area)); // 카드 높이를 먼저 잰다
    let t = now();
    let reduce = reduce_motion();
    let mut want_og: Option<String> = None;
    with_card(id, |card| {
        if let Kind::News(it) = &card.kind {
            if it.id != dropcap_core::app_model::PREVIEW_ID && card.thumb.is_none() && !it.link.is_empty() {
                want_og = Some(it.link.clone());
            }
        }
        if reduce {
            // 움직임 줄이기(N-17·N-24): 물방울 없이 카드만 나타남
            card.developed = Anim::fixed(1.0);
            card.alpha.go(t, 1.0, 0.2, ease_out);
            card.shadow.go(t, 1.0, 0.2, ease_out);
            card.reveal_at = Some(t);
            card.landed = true;
            card.deadline = t + LIFETIME;
            if card.play_sound {
                crate::toast_sound::play();
            }
        } else {
            // 1) 빈 유리잔(카드)이 살며시 나타나고, 천장에 물이 맺혀 → 처지다 → 톡 떨어진다
            let t0 = t + 0.03;
            let skip = if card.quick { drip::DETACH - 0.12 } else { 0.0 };
            let ds = t0 - skip;
            card.drip_start = Some(ds);
            card.alpha = Anim { from: 0.0, to: 1.0, start: t0, dur: 0.5, ease: ease_out };
            card.shadow = Anim { from: 0.0, to: 0.6, start: t0, dur: 0.5, ease: ease_out };
            // 닿는 순간 바로 물이 차기 시작하게
            card.land_at = ds + drip::landing_time(card.land_y()) - 0.025;
        }
    });
    // 사진이 피드에 없으면 떨어지는 동안 기사 머리에서 찾아 온다(N-06)
    if let Some(link) = want_og {
        bg(async move { dropcap_core::feed_service::SHARED.og_image(&link).await }, move |u| {
            if let Some(u) = u {
                with_card(id, |c| {
                    c.thumb = Some(u.clone());
                    c.measured = false; // 글자 폭이 바뀜 → 다시 잼
                });
                load_photo(id, u);
            }
        });
    }
    if let Some(u) = with_card(id, |c| c.thumb.clone()).flatten() {
        load_photo(id, u);
    }
}

fn load_photo(id: u64, url: String) {
    crate::widgets::load_texture(&url, move |tex| {
        let Some(tex) = tex else { return };
        if let Some(p) = make_photo(&tex) {
            with_card(id, |c| c.photo = Some(p));
            queue_draw();
        }
    });
}

// 58×58 로 가운데를 잘라 담고, 인화 전 모습(회색·흐림·밝게)을 한 번만 미리 만들어 둔다
fn make_photo(tex: &gdk::Texture) -> Option<Photo> {
    let px = (THUMB * 2.0) as i32; // 고해상도 화면 대비 2배
    let (tw, th) = (tex.width(), tex.height());
    if tw <= 0 || th <= 0 {
        return None;
    }
    let stride = tw as usize * 4;
    let mut buf = vec![0u8; stride * th as usize];
    tex.download(&mut buf, stride); // B8G8R8A8 미리 곱함 = cairo ARGB32
    let src = cairo::ImageSurface::create_for_data(buf, cairo::Format::ARgb32, tw, th, stride as i32).ok()?;
    let color = cairo::ImageSurface::create(cairo::Format::ARgb32, px, px).ok()?;
    {
        let cr = cairo::Context::new(&color).ok()?;
        let s = (px as f64 / tw as f64).max(px as f64 / th as f64);
        cr.translate((px as f64 - tw as f64 * s) / 2.0, (px as f64 - th as f64 * s) / 2.0);
        cr.scale(s, s);
        cr.set_source_surface(&src, 0.0, 0.0).ok()?;
        cr.source().set_filter(cairo::Filter::Good);
        cr.paint().ok()?;
    }
    // 흐림: 작게 줄였다가 다시 키움(흐림 5pt 정도)
    let n = 12;
    let small = cairo::ImageSurface::create(cairo::Format::ARgb32, n, n).ok()?;
    {
        let cr = cairo::Context::new(&small).ok()?;
        cr.scale(n as f64 / px as f64, n as f64 / px as f64);
        cr.set_source_surface(&color, 0.0, 0.0).ok()?;
        cr.source().set_filter(cairo::Filter::Good);
        cr.paint().ok()?;
    }
    let mut gray = cairo::ImageSurface::create(cairo::Format::ARgb32, px, px).ok()?;
    {
        let cr = cairo::Context::new(&gray).ok()?;
        cr.scale(px as f64 / n as f64, px as f64 / n as f64);
        cr.set_source_surface(&small, 0.0, 0.0).ok()?;
        cr.source().set_filter(cairo::Filter::Bilinear);
        cr.paint().ok()?;
    }
    gray.flush();
    {
        // 회색 + 밝게(맥 saturation 0 · brightness +0.22)
        let gs = gray.stride() as usize;
        let mut d = gray.data().ok()?;
        for y in 0..px as usize {
            for x in 0..px as usize {
                let o = y * gs + x * 4;
                let (b, g, r, a) = (d[o] as f64, d[o + 1] as f64, d[o + 2] as f64, d[o + 3] as f64);
                let l = (0.299 * r + 0.587 * g + 0.114 * b + 0.22 * a).min(a);
                d[o] = l as u8;
                d[o + 1] = l as u8;
                d[o + 2] = l as u8;
            }
        }
    }
    gray.mark_dirty();
    Some(Photo { color, gray })
}

fn with_card<R>(id: u64, f: impl FnOnce(&mut Card) -> R) -> Option<R> {
    CENTER.with(|c| c.borrow_mut().cards.iter_mut().find(|k| k.id == id).map(f))
}

fn queue_draw() {
    if let Some(a) = CENTER.with(|c| c.borrow().area.clone()) {
        a.queue_draw();
    }
}

// MARK: 창
fn ensure_window() {
    if CENTER.with(|c| c.borrow().win.is_none()) {
        build_window();
    }
    let Some(win) = CENTER.with(|c| c.borrow().win.clone()) else { return };
    if !win.is_visible() {
        place_window(&win);
        win.set_opacity(1.0);
        CENTER.with(|c| c.borrow_mut().win_alpha = Anim::fixed(1.0));
        // present() 는 입력 초점을 가져가려 하므로 보이게만 한다(N-14)
        win.set_visible(true);
        #[cfg(feature = "x11")]
        {
            // 창 관리자가 처음 자리를 정한 뒤 한 번 더 옮긴다
            let w = win.clone();
            crate::widgets::later(30, move || place_window(&w));
        }
    }
}

fn build_window() {
    let win = gtk::Window::builder()
        .decorated(false)
        .resizable(false)
        .default_width(PANEL_W as i32)
        .default_height(PANEL_H as i32)
        .focusable(false)
        .can_focus(false)
        .focus_on_click(false)
        .title("Dropcap 알림")
        .build();
    win.add_css_class("dropcap-toast");
    let prov = gtk::CssProvider::new();
    prov.load_from_string("window.dropcap-toast, window.dropcap-toast > * { background: transparent; box-shadow: none; border: none; }");
    if let Some(d) = gdk::Display::default() {
        gtk::style_context_add_provider_for_display(&d, &prov, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
    }
    place::prepare(&win, right());
    let area = gtk::DrawingArea::builder().content_width(PANEL_W as i32).content_height(PANEL_H as i32).build();
    area.set_draw_func(|_, cr, _, _| draw_all(cr));
    // 마우스 올림·누름은 카드 사각형으로 판단한다
    let motion = gtk::EventControllerMotion::new();
    motion.connect_motion(|_, x, y| set_pointer(Some((x, y))));
    motion.connect_leave(|_| set_pointer(None));
    area.add_controller(motion);
    let click = gtk::GestureClick::new();
    click.connect_released(|g, _, x, y| {
        g.set_state(gtk::EventSequenceState::Claimed);
        click_at(x, y);
    });
    area.add_controller(click);
    // 오른쪽 클릭: 바로 줄이기(G-11 · 맥 ReduceMenu)
    let menu_click = gtk::GestureClick::new();
    menu_click.set_button(gdk::BUTTON_SECONDARY);
    menu_click.connect_pressed(|g, _, x, y| {
        g.set_state(gtk::EventSequenceState::Claimed);
        open_reduce_menu(x, y);
    });
    area.add_controller(menu_click);
    install_reduce_actions(&area);
    area.add_tick_callback(|_, _| {
        tick();
        glib::ControlFlow::Continue
    });
    win.set_child(Some(&area));
    WidgetExt::realize(&win);
    #[cfg(feature = "x11")]
    {
        let xc = CENTER.with(|c| c.borrow_mut().x.take()).or_else(place::x11::X::connect);
        if let (Some(x), Some(xid)) = (&xc, place::x11::xid(&win)) {
            x.mark_notification(xid); // 항상 위·작업 표시줄에 안 보임·초점 안 받음
        }
        CENTER.with(|c| c.borrow_mut().x = xc);
    }
    // 모니터를 꽂거나 빼면 자리를 다시 잡는다
    if let Some(d) = gdk::Display::default() {
        let w = win.clone();
        d.monitors().connect_items_changed(move |_, _, _, _| {
            if w.is_visible() {
                place_window(&w);
            }
        });
    }
    CENTER.with(|c| {
        let mut c = c.borrow_mut();
        c.win = Some(win);
        c.area = Some(area);
    });
}

// MARK: 바로 줄이기(G-11)
thread_local! {
    static MENU_ITEM: RefCell<Option<NewsItem>> = const { RefCell::new(None) };
}

fn install_reduce_actions(area: &gtk::DrawingArea) {
    let group = gtk::gio::SimpleActionGroup::new();
    let item = || MENU_ITEM.with(|m| m.borrow().clone());
    let hide = gtk::gio::SimpleAction::new("hide", None);
    hide.connect_activate(move |_, _| {
        if let Some(it) = item() {
            ui().core.hide_source(&it.source_id);
        }
    });
    group.add_action(&hide);
    let less = gtk::gio::SimpleAction::new("less", None);
    less.connect_activate(move |_, _| {
        if let Some(it) = item() {
            let core = ui().core.clone();
            core.less_of(&core.notify_section(&it));
        }
    });
    group.add_action(&less);
    let mute = gtk::gio::SimpleAction::new("mute", Some(glib::VariantTy::STRING));
    mute.connect_activate(|_, v| {
        if let Some(w) = v.and_then(|v| v.get::<String>()) {
            ui().core.mute_word(&w);
        }
    });
    group.add_action(&mute);
    area.insert_action_group("toast", Some(&group));
}

// 메뉴 항목(맥과 같은 문구): 이 출처 숨기기 — 출처 / (고른 분야이고 매거진만이 아니면) 분야 덜 받기 — 묶음으로·매거진에만 / 이 낱말 알리지 않기 ▸
pub fn reduce_menu_model(it: &NewsItem) -> gtk::gio::Menu {
    let core = ui().core.clone();
    let menu = gtk::gio::Menu::new();
    menu.append(Some(&format!("이 출처 숨기기 — {}", it.source_name)), Some("toast.hide"));
    let sec = core.notify_section(it);
    let mode = core.policy(&sec).mode;
    if core.chosen_sections().contains(&sec) && mode != dropcap_core::notify_policy::NotifyMode::Magazine {
        let how = if mode == dropcap_core::notify_policy::NotifyMode::Instant { "묶음으로" } else { "매거진에만" };
        menu.append(Some(&format!("{} 덜 받기 — {how}", dropcap_core::sections::name(&sec))), Some("toast.less"));
    }
    let words = gtk::gio::Menu::new();
    for w in dropcap_core::app_model::title_words(it) {
        let mi = gtk::gio::MenuItem::new(Some(&w), None);
        mi.set_action_and_target_value(Some("toast.mute"), Some(&w.to_variant()));
        words.append_item(&mi);
    }
    menu.append_submenu(Some("이 낱말 알리지 않기"), &words);
    menu
}

fn open_reduce_menu(x: f64, y: f64) {
    let found = CENTER.with(|c| {
        let c = c.borrow();
        c.cards.iter().filter(|k| !k.leaving).find(|k| card_rect(k, 0.0).contains((x, y))).and_then(|k| match &k.kind {
            Kind::News(it) if it.id != dropcap_core::app_model::PREVIEW_ID => Some((k.id, it.clone())),
            _ => None,
        })
    });
    let Some((id, it)) = found else { return };
    let Some(area) = CENTER.with(|c| c.borrow().area.clone()) else { return };
    let model = reduce_menu_model(&it);
    MENU_ITEM.with(|m| *m.borrow_mut() = Some(it));
    CENTER.with(|c| c.borrow_mut().menu_card = Some(id)); // 메뉴가 열린 동안 카드가 사라지지 않게(마우스를 올린 것처럼)
    let pop = gtk::PopoverMenu::from_model(Some(&model));
    pop.set_parent(&area);
    pop.set_has_arrow(false);
    pop.set_pointing_to(Some(&gdk::Rectangle::new(x as i32, y as i32, 1, 1)));
    pop.connect_closed(|p| {
        CENTER.with(|c| c.borrow_mut().menu_card = None);
        let p = p.clone();
        glib::idle_add_local_once(move || p.unparent());
    });
    pop.popup();
}

fn place_window(win: &gtk::Window) {
    place::set_right(win, right());
    #[cfg(feature = "x11")]
    {
        let xc = CENTER.with(|c| c.borrow_mut().x.take()).or_else(place::x11::X::connect);
        if let (Some(x), Some(xid)) = (&xc, place::x11::xid(win)) {
            if let Some(((px, py), mon)) = place::x11::place(x, PANEL_W as i32, right()) {
                x.move_to(xid, px, py);
                let scale = win.scale_factor().max(1) as f64;
                CENTER.with(|c| {
                    let mut c = c.borrow_mut();
                    c.screen = Some(mon);
                    c.win_pos = Some((px as f64 / scale, py as f64 / scale));
                });
            }
        }
        CENTER.with(|c| c.borrow_mut().x = xc);
    }
}

fn set_pointer(p: Option<(f64, f64)>) {
    CENTER.with(|c| c.borrow_mut().pointer = p);
    queue_draw();
}

// MARK: 매 프레임
fn tick() {
    let t = now();
    let dt = CENTER.with(|c| {
        let mut c = c.borrow_mut();
        let dt = (t - c.last_tick).clamp(0.0, 0.1);
        c.last_tick = t;
        dt
    });
    let mut sound = false;
    let mut busy = false;
    let reduce = reduce_motion();
    // 커서 아래 카드(카드 자체 크기 + 10pt)
    let hovered = CENTER.with(|c| {
        let c = c.borrow();
        if let Some(m) = c.menu_card {
            return Some(m);
        }
        let p = c.pointer?;
        c.cards.iter().filter(|k| !k.leaving).find(|k| card_rect(k, 10.0).contains(p)).map(|k| k.id)
    });
    let emptied = CENTER.with(|c| {
        let mut c = c.borrow_mut();
        // 쌓인 자리: 용수철(반응 0.5초, 감쇠 0.82)
        let mut y = TOP;
        for card in c.cards.iter_mut() {
            let target = y;
            if !card.placed || reduce {
                card.y = target;
                card.placed = true;
            } else {
                let w0 = 2.0 * std::f64::consts::PI / 0.5;
                let acc = -w0 * w0 * (card.y - target) - 2.0 * 0.82 * w0 * card.vy;
                card.vy += acc * dt;
                card.y += card.vy * dt;
                if (card.y - target).abs() < 0.05 && card.vy.abs() < 0.5 {
                    card.y = target;
                    card.vy = 0.0;
                }
            }
            if (card.y - target).abs() > 0.05 {
                busy = true;
            }
            y += card.height + GAP;
        }
        for card in c.cards.iter_mut() {
            let hov = hovered == Some(card.id) && !card.leaving;
            if (card.hover.to > 0.5) != hov {
                card.hover.go(t, if hov { 1.0 } else { 0.0 }, 0.3, if hov { spring } else { ease_out });
            }
            // 2) 바닥에 닿으면 "똑" 하고 물이 차오른다
            if !card.landed && t >= card.land_at {
                card.landed = true;
                sound |= card.play_sound;
                card.fill_start = Some(t);
                card.developed.go(t, 1.0, 2.0, ease_in_out);
                card.land_bump = Some(t); // 잔이 살짝 눌렸다가 돌아옴
                card.drip_end = t + 0.09 + 0.7; // 천장에 남은 물이 다 빨려 들어간 뒤 치움
                // 3) 물이 30% 찼을 때부터 글자가 물과 함께 떠오르고 그림자가 짙어진다
                let rv = t + water::FILL_TIME * 0.3;
                card.reveal_at = Some(rv);
                card.shadow = Anim { from: card.shadow.value(t), to: 1.0, start: rv, dur: 0.4, ease: ease_out };
                card.calm_at = rv + water::FILL_TIME * 0.7 + 0.9;
                card.deadline = rv + water::FILL_TIME * 0.7 + LIFETIME;
            }
            if t >= card.drip_end {
                card.drip_start = None;
                card.drip_cache = None;
            }
            // 4) 머무름 9초: 마우스를 올린 동안은 마감을 미룬다
            if card.deadline < f64::MAX && !card.leaving {
                if hov {
                    card.deadline += dt;
                }
                card.remaining = ((card.deadline - t) / LIFETIME).clamp(0.0, 1.0);
                if t >= card.deadline {
                    begin_leave(card, t, false, reduce);
                }
            }
            busy |= card.drip_start.is_some()
                || card.hover.moving(t)
                || card.alpha.moving(t)
                || card.scale.moving(t)
                || card.developed.moving(t)
                || card.leaving
                || (card.fill_start.is_some() && t < card.calm_at)
                || card.reveal_at.map(|r| t < r + 0.7).unwrap_or(false);
        }
        let before = c.cards.len();
        c.cards.retain(|k| k.remove_at.map(|r| t < r).unwrap_or(true));
        if c.cards.len() != before && c.cards.is_empty() && c.hide_at.is_none() {
            c.hide_at = Some(t + 0.4);
        }
        busy |= c.win_alpha.moving(t);
        c.hide_at.map(|h| t >= h && c.cards.is_empty()).unwrap_or(false)
    });
    if sound {
        crate::toast_sound::play();
    }
    // 다 비면 0.4초 뒤 창을 숨긴다
    if emptied {
        if let Some(w) = CENTER.with(|c| {
            let mut c = c.borrow_mut();
            c.hide_at = None;
            c.win.clone()
        }) {
            w.set_visible(false);
        }
        return;
    }
    #[cfg(feature = "x11")]
    follow_cursor(t);
    update_input_region();
    // 잔잔해진 뒤에는 초당 12번만 다시 그림(N-03)
    let due = CENTER.with(|c| {
        let mut c = c.borrow_mut();
        let due = busy || t - c.last_draw >= 1.0 / 12.0;
        if due {
            c.last_draw = t;
        }
        let a = c.win_alpha.value(t);
        if let Some(w) = &c.win {
            if (w.opacity() - a).abs() > 0.001 {
                w.set_opacity(a);
            }
        }
        due
    });
    if due {
        queue_draw();
    }
}

// 떠 있는 동안 커서가 다른 화면에 0.25초 머물면 살짝 사라졌다가 그 화면에 다시 나타난다(N-11, X11)
#[cfg(feature = "x11")]
fn follow_cursor(t: f64) {
    let go = CENTER.with(|c| {
        let mut c = c.borrow_mut();
        if c.cards.is_empty() || t < c.moving_until {
            return false;
        }
        let Some(x) = &c.x else { return false };
        let Some((px, py)) = x.pointer() else { return false };
        let target = place::x11::monitor_of(px, py);
        if target.is_none() || target == c.screen {
            c.other_since = None;
            return false;
        }
        match c.other_since {
            None => {
                c.other_since = Some(t);
                false
            }
            Some(s) if t - s > 0.25 => {
                c.other_since = None;
                c.moving_until = t + 0.34;
                c.win_alpha.go(t, 0.0, 0.14, ease_out);
                true
            }
            _ => false,
        }
    });
    if go {
        crate::widgets::later(140, || {
            if let Some(w) = CENTER.with(|c| c.borrow().win.clone()) {
                place_window(&w);
            }
            let t = now();
            CENTER.with(|c| c.borrow_mut().win_alpha.go(t, 1.0, 0.2, ease_out));
        });
    }
}

// 카드 둘레만 입력을 받는다(N-13): 카드가 바뀔 때만 다시 정함
fn update_input_region() {
    let (win, rects, changed) = CENTER.with(|c| {
        let c = c.borrow();
        let rects: Vec<(f64, f64, f64, f64)> = c
            .cards
            .iter()
            .filter(|k| !k.leaving && k.alpha.to > 0.0)
            .map(|k| card_rect(k, 10.0))
            .map(|r| ((r.x).round(), (r.y).round(), r.w.round(), r.h.round()))
            .collect();
        let changed = c.input_rects != rects;
        (c.win.clone(), rects, changed)
    });
    if changed {
        if let Some(w) = win {
            place::set_input_rects(&w, &rects);
        }
        CENTER.with(|c| c.borrow_mut().input_rects = rects);
    }
}

#[derive(Clone, Copy)]
struct R {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
}

impl R {
    fn contains(&self, p: (f64, f64)) -> bool {
        p.0 >= self.x && p.0 < self.x + self.w && p.1 >= self.y && p.1 < self.y + self.h
    }
}

fn card_rect(k: &Card, inset: f64) -> R {
    R { x: SIDE - inset, y: k.y - inset, w: CARD_W + inset * 2.0, h: k.height + inset * 2.0 }
}

fn begin_leave(card: &mut Card, t: f64, quick: bool, reduce: bool) {
    if card.leaving {
        return;
    }
    card.leaving = true;
    card.hover.go(t, 0.0, 0.15, ease_out);
    if reduce {
        card.alpha.go(t, 0.0, 0.15, ease_out);
        card.remove_at = Some(t + 0.15);
        return;
    }
    // 카드만 조용히 사라진다: 살짝 작아지며 흐려지고 투명해짐(N-09)
    let k = if quick { 0.6 } else { 1.0 };
    card.unreveal_at = Some(t);
    card.alpha.go(t, 0.0, 0.28 * k, ease_in);
    card.shadow.go(t, 0.0, 0.28 * k, ease_in);
    card.scale.go(t, 0.96, 0.28 * k, ease_in);
    card.remove_at = Some(t + 0.28 * k);
}

fn leave(id: u64, quick: bool) {
    let t = now();
    let reduce = reduce_motion();
    with_card(id, |c| begin_leave(c, t, quick, reduce));
    queue_draw();
}

// MARK: 누름
enum Hit {
    Close,
    Save,
    Browser,
    Card,
}

fn quick_buttons(r: &R) -> (f64, f64, f64) {
    let by = r.y + r.h - 8.0 - 22.0;
    let bx = r.x + r.w - 8.0 - 24.0;
    (bx - 4.0 - 24.0, bx, by)
}

fn hit_test(k: &Card, p: (f64, f64), hov: f64) -> Option<Hit> {
    let r = card_rect(k, 0.0);
    if hov > 0.5 {
        // 닫기 단추: 카드 왼쪽 위 모서리에 걸친 20pt 원
        if (p.0 - (r.x + 3.0)).hypot(p.1 - (r.y + 3.0)) <= 12.0 {
            return Some(Hit::Close);
        }
        if k.is_news() {
            let (sx, bx, by) = quick_buttons(&r);
            if (R { x: sx, y: by, w: 24.0, h: 22.0 }).contains(p) {
                return Some(Hit::Save);
            }
            if (R { x: bx, y: by, w: 24.0, h: 22.0 }).contains(p) {
                return Some(Hit::Browser);
            }
        }
    }
    card_rect(k, 10.0).contains(p).then_some(Hit::Card)
}

fn click_at(x: f64, y: f64) {
    let t = now();
    let found = CENTER.with(|c| {
        let c = c.borrow();
        c.cards
            .iter()
            .filter(|k| !k.leaving)
            .find_map(|k| hit_test(k, (x, y), k.hover.value(t)).map(|h| (k.id, h, k.kind.clone(), card_rect(k, 0.0))))
    });
    let Some((id, hit, kind, r)) = found else { return };
    match hit {
        Hit::Close => leave(id, false),
        Hit::Save => {
            if let Kind::News(it) = &kind {
                ui().core.toggle_saved(it);
                queue_draw();
            }
        }
        Hit::Browser => {
            if let Kind::News(it) = &kind {
                app::open_external(&it.link);
                ui().core.set_read(it, true);
            }
            leave(id, true);
        }
        Hit::Card => {
            match &kind {
                // 누르면 읽기 창(영상·팟캐스트는 원래 앱). 미리 보기 견본은 아무것도 열지 않음(N-14·N-15)
                Kind::News(it) => {
                    let from = CENTER.with(|c| c.borrow().win_pos).map(|(wx, wy)| crate::reader::Origin { x: wx + r.x, y: wy + r.y, w: r.w, h: r.h });
                    app::open_item(it, from);
                }
                Kind::Digest(_) => crate::magazine::open(),
                Kind::Bundle(sec, _) => crate::magazine::open_section(sec), // 매거진의 그 분야 지면
                Kind::Watch(word, _) => crate::magazine::search_for(word), // 그 낱말 검색 결과
                _ => {}
            }
            leave(id, true);
        }
    }
}

// MARK: 그리기
fn dark() -> bool {
    theme::is_dark()
}

fn ink(alpha: f64) -> (f64, f64, f64, f64) {
    if dark() {
        (1.0, 1.0, 1.0, alpha * 0.92)
    } else {
        (0.0, 0.0, 0.0, alpha * 0.86)
    }
}

const PRIMARY: f64 = 1.0;
const SECONDARY: f64 = 0.62;
const TERTIARY: f64 = 0.45;

fn layout(area: &gtk::DrawingArea, text: &str, size: f64, weight: pango::Weight, width: Option<f64>, lines: i32) -> pango::Layout {
    let l = area.create_pango_layout(Some(text));
    l.set_font_description(Some(&theme::font(size, weight)));
    if let Some(w) = width {
        l.set_width((w * pango::SCALE as f64) as i32);
        l.set_wrap(pango::WrapMode::WordChar);
        l.set_ellipsize(pango::EllipsizeMode::End);
        l.set_height(-lines);
    }
    l
}

fn lh(l: &pango::Layout) -> f64 {
    l.pixel_size().1 as f64
}

fn lw(l: &pango::Layout) -> f64 {
    l.pixel_size().0 as f64
}

fn text_width(has_thumb: bool) -> f64 {
    CARD_W - 14.0 - 16.0 - MONO - 12.0 - if has_thumb { THUMB + 12.0 } else { 0.0 }
}

// 글자 배치를 한 번 만들고 카드 높이를 잰다(사진이 오면 한 번 더)
fn measure(card: &mut Card, area: &gtk::DrawingArea) {
    card.texts.clear();
    match &card.kind {
        Kind::News(it) => {
            let tw = text_width(card.thumb.is_some());
            let title = layout(area, it.display_title(), 14.5, pango::Weight::Semibold, Some(tw), 2);
            title.set_spacing((1.5 * pango::SCALE as f64) as i32);
            let attrs = pango::AttrList::new();
            attrs.insert(pango::AttrInt::new_letter_spacing((-0.15 * pango::SCALE as f64) as i32));
            title.set_attributes(Some(&attrs));
            let mut text_h = 15.0 + 3.0 + lh(&title);
            card.texts.push(title);
            if let Some(ko) = &it.title_ko {
                if ko != &it.title {
                    let orig = layout(area, &it.title, 12.0, pango::Weight::Normal, Some(tw), 1);
                    text_h += 3.0 + lh(&orig);
                    card.texts.push(orig);
                }
            }
            let inner = text_h.max(MONO).max(if card.thumb.is_some() { THUMB } else { 0.0 });
            card.height = (14.0 + inner + 15.0).round();
        }
        Kind::Info(..) | Kind::Digest(_) => {
            let (title, sub) = match &card.kind {
                Kind::Info(a, b) => (a.clone(), b.clone()),
                Kind::Digest(n) => (digest_title(), digest_sub(*n)),
                _ => unreachable!(),
            };
            let tw = CARD_W - 13.0 - 16.0 - 30.0 - 11.0;
            let a = layout(area, &title, 13.5, pango::Weight::Semibold, Some(tw), 1);
            let b = layout(area, &sub, 12.0, pango::Weight::Normal, Some(tw), 2);
            let inner = (lh(&a) + 2.0 + lh(&b)).max(30.0);
            card.texts.push(a);
            card.texts.push(b);
            card.height = (12.0 + inner + 12.0).round();
        }
        Kind::Bundle(..) | Kind::Watch(..) => {
            // "경제 7건 … 모아 보기" · "오늘 엔비디아 소식 3건 … 검색 결과" + 제목 2줄
            let (name_s, count_s, hint_s, _, _, items) = group_head(&card.kind).unwrap();
            let tw = CARD_W - 13.0 - 16.0 - 30.0 - 11.0;
            let name = layout(area, &name_s, 13.5, pango::Weight::Semibold, None, 1);
            let count = layout(area, &count_s, 13.5, pango::Weight::Semibold, None, 1);
            let hint = layout(area, hint_s, 11.0, pango::Weight::Normal, None, 1);
            let mut inner = lh(&name);
            card.texts.push(name);
            card.texts.push(count);
            card.texts.push(hint);
            for line in bundle_lines(items) {
                let l = layout(area, &line, 12.0, pango::Weight::Normal, Some(tw), 1);
                inner += 3.0 + lh(&l);
                card.texts.push(l);
            }
            card.height = (12.0 + inner.max(30.0) + 12.0).round();
        }
        Kind::More(n) => {
            // "새 소식 N건 더 · 트레이 아이콘에서 확인" — N건만 강조색
            let l = area.create_pango_layout(None);
            l.set_font_description(Some(&theme::font(12.5, pango::Weight::Semibold)));
            let head = format!("{} ", strings::NEWS);
            let num = format!("{n}건");
            l.set_text(&format!("{head}{num} 더 · 트레이 아이콘에서 확인"));
            let (r, g, b) = accent_color();
            let attrs = pango::AttrList::new();
            let mut a = pango::AttrColor::new_foreground((r * 65535.0) as u16, (g * 65535.0) as u16, (b * 65535.0) as u16);
            a.set_start_index(head.len() as u32);
            a.set_end_index((head.len() + num.len()) as u32);
            attrs.insert(a);
            l.set_attributes(Some(&attrs));
            card.height = (10.0 + lh(&l) + 10.0).round();
            card.texts.push(l);
        }
    }
    card.measured = true;
}

fn draw_all(cr: &cairo::Context) {
    let Some(area) = CENTER.with(|c| c.borrow().area.clone()) else { return };
    let t = now();
    let scale = area.scale_factor() as f64;
    CENTER.with(|c| {
        let mut c = c.borrow_mut();
        for k in c.cards.iter_mut().filter(|k| !k.measured) {
            measure(k, &area);
        }
        // 아래 카드부터 그려 위 카드가 위에 오게
        for k in c.cards.iter_mut().rev() {
            draw_card(cr, &area, k, t, scale);
        }
    });
}

fn draw_card(cr: &cairo::Context, area: &gtk::DrawingArea, k: &mut Card, t: f64, scale: f64) {
    let alpha = k.alpha.value(t);
    let hov = k.hover.value(t);
    let r = card_rect(k, 0.0);
    let s = k.scale.value(t);
    let mut sy = s;
    if let Some(b) = k.land_bump {
        // 닿는 순간 잔이 살짝 눌렸다가 돌아옴(N-04)
        let e = t - b;
        if e < 1.2 {
            sy -= 0.015 * (std::f64::consts::PI * e / 0.18).sin() * (-5.0 * e).exp();
        }
    }
    let grow = 1.0 + 0.012 * hov; // 마우스를 올리면 살짝 커짐(N-08)
    if alpha > 0.002 {
        cr.save().ok();
        // 위쪽 가운데를 기준으로 키우고 줄임
        cr.translate(r.x + r.w / 2.0, r.y);
        cr.scale(s * grow, sy * grow);
        cr.translate(-(r.x + r.w / 2.0), -r.y);
        cr.push_group();
        draw_shadow(cr, &r, k.shadow.value(t), hov);
        cr.save().ok();
        drip::rounded(cr, r.x, r.y, r.w, r.h, RADIUS);
        cr.clip();
        draw_glass(cr, &r);
        if let Some(f) = k.fill_start {
            cr.save().ok();
            cr.translate(r.x, r.y);
            water::draw(cr, r.w, r.h, t - f, k.accent(), k.remaining);
            cr.restore().ok();
        }
        draw_content(cr, area, k, &r, t);
        draw_quick(cr, k, &r, hov);
        cr.restore().ok();
        // 유리 테두리
        drip::rounded(cr, r.x + 0.5, r.y + 0.5, r.w - 1.0, r.h - 1.0, RADIUS);
        let (ir, ig, ib, _) = ink(1.0);
        cr.set_source_rgba(ir, ig, ib, if dark() { 0.12 } else { 0.08 });
        cr.set_line_width(1.0);
        let _ = cr.stroke();
        if hov > 0.01 {
            draw_close(cr, &r, hov);
        }
        let _ = cr.pop_group_to_source();
        let _ = cr.paint_with_alpha(alpha);
        cr.restore().ok();
    }
    // 천장에 맺혀 떨어지는 물방울(카드 가운데로 떨어져 카드 바닥에 닿음, N-01·N-02)
    if let Some(ds) = k.drip_start {
        let land = k.land_y();
        let st = drip::state(t - ds, land);
        if drip::visible(&st) {
            let color = water::mix(k.accent(), (1.0, 1.0, 1.0), 0.18);
            let key = drip::key(&st, land, color);
            if k.drip_cache.as_ref().map(|(kk, _)| *kk != key).unwrap_or(true) {
                k.drip_cache = drip::render(&st, land, color, scale).map(|img| (key, img));
            }
            let ox = r.x + r.w / 2.0 - drip::WIDTH / 2.0;
            let oy = k.y - TOP;
            if let Some((_, img)) = &k.drip_cache {
                cr.save().ok();
                cr.translate(ox, oy);
                let _ = cr.set_source_surface(img, 0.0, 0.0);
                let _ = cr.paint();
                drip::highlights(cr, &st);
                cr.restore().ok();
            }
        }
    }
}

fn draw_shadow(cr: &cairo::Context, r: &R, shadow: f64, hov: f64) {
    if shadow <= 0.01 {
        return;
    }
    let base = (if dark() { 0.5 } else { 0.2 }) * shadow * (1.0 + 0.35 * hov);
    let radius = 16.0 + 6.0 * hov;
    let dy = 8.0 + 4.0 * hov;
    // 흐린 그림자를 겹친 둥근 사각형으로
    let steps = 10;
    for i in (0..steps).rev() {
        let k = i as f64 / steps as f64;
        let grow = radius * k;
        let a = base * (1.0 - k).powi(2) / steps as f64 * 2.2;
        drip::rounded(cr, r.x - grow * 0.5, r.y + dy - grow * 0.3, r.w + grow, r.h + grow * 0.6, RADIUS + grow * 0.5);
        cr.set_source_rgba(0.0, 0.0, 0.0, a);
        let _ = cr.fill();
    }
    drip::rounded(cr, r.x, r.y + 1.0, r.w, r.h, RADIUS);
    cr.set_source_rgba(0.0, 0.0, 0.0, 0.08 * shadow);
    let _ = cr.fill();
}

// 유리 재질(N-19): 반투명 카드(컴포지터가 흐림을 주면 뒤가 비침)
fn draw_glass(cr: &cairo::Context, r: &R) {
    if dark() {
        cr.set_source_rgba(0.17, 0.17, 0.19, 0.84);
    } else {
        cr.set_source_rgba(0.98, 0.98, 0.99, 0.86);
    }
    cr.rectangle(r.x, r.y, r.w, r.h);
    let _ = cr.fill();
    let g = cairo::LinearGradient::new(0.0, r.y, 0.0, r.y + r.h * 0.6);
    g.add_color_stop_rgba(0.0, 1.0, 1.0, 1.0, if dark() { 0.06 } else { 0.35 });
    g.add_color_stop_rgba(1.0, 1.0, 1.0, 1.0, 0.0);
    let _ = cr.set_source(&g);
    cr.rectangle(r.x, r.y, r.w, r.h);
    let _ = cr.fill();
}

// 글자 떠오름: 차례로(0.14초 + 0.045초씩) 투명→또렷, 5pt 아래에서 제자리로. 사라질 때는 0.12초에 흐려짐
fn rise(k: &Card, idx: usize, t: f64) -> (f64, f64) {
    if let Some(u) = k.unreveal_at {
        let p = ((t - u) / 0.12).clamp(0.0, 1.0);
        let (a, d) = rise_on(k, idx, u);
        return (a * (1.0 - p), d);
    }
    rise_on(k, idx, t)
}

fn rise_on(k: &Card, idx: usize, t: f64) -> (f64, f64) {
    let Some(rv) = k.reveal_at else { return (0.0, 5.0) };
    let start = rv + if reduce_motion() { 0.0 } else { 0.14 + idx as f64 * 0.045 };
    let p = ((t - start) / 0.4).clamp(0.0, 1.0);
    (ease_out(p), 5.0 * (1.0 - spring(p)))
}

fn show_layout(cr: &cairo::Context, l: &pango::Layout, x: f64, y: f64, color: (f64, f64, f64, f64), a: f64) {
    if a <= 0.0 {
        return;
    }
    cr.move_to(x, y);
    cr.set_source_rgba(color.0, color.1, color.2, color.3 * a);
    pangocairo::functions::update_layout(cr, l);
    pangocairo::functions::show_layout(cr, l);
}

fn draw_content(cr: &cairo::Context, area: &gtk::DrawingArea, k: &Card, r: &R, t: f64) {
    match &k.kind {
        Kind::News(it) => {
            let (a0, d0) = rise(k, 0, t);
            draw_monogram(cr, area, it, r.x + 14.0, r.y + 14.0 + d0, a0);
            let tx = r.x + 14.0 + MONO + 12.0;
            let tw = text_width(k.thumb.is_some());
            let mut y = r.y + 14.0;
            // 머리 줄: ★·출처·분야·외 N곳 … 몇 분 전
            let (a1, d1) = rise(k, 1, t);
            draw_header(cr, area, it, tx, y + d1, tw, a1);
            y += 15.0 + 3.0;
            if let Some(title) = k.texts.first() {
                let (a2, d2) = rise(k, 2, t);
                show_layout(cr, title, tx, y + d2, ink(PRIMARY), a2);
                y += lh(title) + 3.0;
            }
            if let Some(orig) = k.texts.get(1) {
                let (a3, d3) = rise(k, 3, t);
                show_layout(cr, orig, tx, y + d3, ink(SECONDARY), a3);
            }
            if k.thumb.is_some() {
                draw_photo(cr, k, r.x + CARD_W - 16.0 - THUMB, r.y + 14.0, t, it);
            }
        }
        Kind::Info(..) | Kind::Digest(_) => {
            let inner = r.h - 24.0;
            let (a0, d0) = rise(k, 0, t);
            let icon_y = r.y + 12.0 + (inner - 30.0) / 2.0;
            if matches!(k.kind, Kind::Info(..)) {
                draw_sparkle(cr, r.x + 13.0, icon_y + d0, a0);
            } else {
                draw_sun(cr, r.x + 13.0, icon_y + d0, a0);
            }
            let tx = r.x + 13.0 + 30.0 + 11.0;
            let th = k.texts.iter().map(lh).sum::<f64>() + 2.0;
            let mut y = r.y + 12.0 + (inner - th) / 2.0;
            for (i, l) in k.texts.iter().enumerate() {
                let (a, d) = rise(k, i + 1, t);
                show_layout(cr, l, tx, y + d, ink(if i == 0 { PRIMARY } else { SECONDARY }), a);
                y += lh(l) + 2.0;
            }
        }
        Kind::Bundle(..) | Kind::Watch(..) => {
            let (a0, d0) = rise(k, 0, t);
            let (_, _, _, col, icon, _) = group_head(&k.kind).unwrap();
            draw_badge(cr, r.x + 13.0, r.y + 12.0 + d0, col, icon, a0);
            let tx = r.x + 13.0 + 30.0 + 11.0;
            let right_edge = r.x + r.w - 16.0;
            let (a1, d1) = rise(k, 1, t);
            let mut y = r.y + 12.0;
            if let (Some(name), Some(count), Some(hint)) = (k.texts.first(), k.texts.get(1), k.texts.get(2)) {
                show_layout(cr, name, tx, y + d1, ink(PRIMARY), a1);
                show_layout(cr, count, tx + lw(name) + 5.0, y + d1, (col.0, col.1, col.2, 1.0), a1);
                show_layout(cr, hint, right_edge - lw(hint), y + 2.0 + d1, ink(TERTIARY), a1);
                y += lh(name);
            }
            let (a2, d2) = rise(k, 2, t);
            for l in k.texts.iter().skip(3) {
                y += 3.0;
                show_layout(cr, l, tx, y + d2, ink(SECONDARY), a2);
                y += lh(l);
            }
        }
        Kind::More(_) => {
            if let Some(l) = k.texts.first() {
                let (a, d) = rise(k, 0, t);
                show_layout(cr, l, r.x + (r.w - lw(l)) / 2.0, r.y + 10.0 + d, ink(PRIMARY), a);
            }
        }
    }
}

fn draw_header(cr: &cairo::Context, area: &gtk::DrawingArea, it: &NewsItem, x: f64, y: f64, w: f64, a: f64) {
    let time = layout(area, &crate::widgets::time_text(it), 11.0, pango::Weight::Normal, None, 1);
    let tw = lw(&time);
    show_layout(cr, &time, x + w - tw, y + 0.5, ink(TERTIARY), a);
    let mut cx = x;
    let limit = x + w - tw - 4.0;
    if it.is_important() {
        let star = layout(area, "★", 9.5, pango::Weight::Bold, None, 1);
        show_layout(cr, &star, cx, y + 2.0, (1.0, 0.58, 0.0, 1.0), a);
        cx += lw(&star) + 6.0;
    }
    // 분야 칩(N-05): AI 분야는 'AI·모델·제품'처럼 하위 분류까지, 나머지는 분야 이름(맥 TopicChip)
    let chip = layout(area, &it.topic_label(), 10.5, pango::Weight::Semibold, None, 1);
    let more = it.related.as_ref().filter(|r| !r.is_empty()).map(|r| layout(area, &format!("외 {}곳", r.len()), 10.5, pango::Weight::Medium, None, 1));
    let tail = lw(&chip) + 12.0 + 6.0 + more.as_ref().map(|m| lw(m) + 6.0).unwrap_or(0.0);
    let name = layout(area, &it.source_name, 11.5, pango::Weight::Semibold, Some((limit - cx - tail).max(30.0)), 1);
    show_layout(cr, &name, cx, y, ink(PRIMARY), a);
    cx += lw(&name) + 6.0;
    // 분야 칩(분야 색 13%)
    let (r, g, b) = dropcap_core::models::hex_rgb(&it.topic_color(dark()));
    let cw = lw(&chip) + 12.0;
    drip::rounded(cr, cx, y + 0.5, cw, lh(&chip) + 2.0, 5.0);
    cr.set_source_rgba(r, g, b, 0.13 * a);
    let _ = cr.fill();
    show_layout(cr, &chip, cx + 6.0, y + 1.5, (r, g, b, 1.0), a);
    cx += cw + 6.0;
    if let Some(m) = more {
        show_layout(cr, &m, cx, y + 1.0, ink(SECONDARY), a);
    }
}

fn draw_monogram(cr: &cairo::Context, area: &gtk::DrawingArea, it: &NewsItem, x: f64, y: f64, a: f64) {
    if a <= 0.0 {
        return;
    }
    let c = dropcap_core::models::hex_rgb(&crate::widgets::source_color(&it.source_id));
    let rad = MONO * 0.29;
    cr.save().ok();
    cr.push_group();
    drip::rounded(cr, x, y + 2.0, MONO, MONO, rad);
    cr.set_source_rgba(c.0, c.1, c.2, 0.25);
    let _ = cr.fill();
    drip::rounded(cr, x, y, MONO, MONO, rad);
    let g = cairo::LinearGradient::new(x, y, x + MONO, y + MONO);
    let l = water::mix(c, (1.0, 1.0, 1.0), 0.18);
    let d = water::mix(c, (0.0, 0.0, 0.0), 0.15);
    g.add_color_stop_rgb(0.0, l.0, l.1, l.2);
    g.add_color_stop_rgb(0.5, c.0, c.1, c.2);
    g.add_color_stop_rgb(1.0, d.0, d.1, d.2);
    let _ = cr.set_source(&g);
    let _ = cr.fill_preserve();
    cr.set_source_rgba(1.0, 1.0, 1.0, 0.22);
    cr.set_line_width(0.5);
    let _ = cr.stroke();
    let lt = layout(area, &it.initial(), MONO * 0.45, pango::Weight::Bold, None, 1);
    show_layout(cr, &lt, x + (MONO - lw(&lt)) / 2.0, y + (MONO - lh(&lt)) / 2.0, (1.0, 1.0, 1.0, 1.0), 1.0);
    let _ = cr.pop_group_to_source();
    let _ = cr.paint_with_alpha(a);
    cr.restore().ok();
}

// 사진 인화(N-06): 물에 잠긴 사진이 회색·흐림에서 점점 또렷한 색으로(2초)
fn draw_photo(cr: &cairo::Context, k: &Card, x: f64, y: f64, t: f64, it: &NewsItem) {
    let d = k.developed.value(t);
    let s = 0.94 + 0.06 * d;
    cr.save().ok();
    cr.translate(x + THUMB / 2.0, y + THUMB / 2.0);
    cr.scale(s, s);
    cr.translate(-THUMB / 2.0, -THUMB / 2.0);
    cr.push_group();
    cr.save().ok();
    drip::rounded(cr, 0.0, 0.0, THUMB, THUMB, 12.0);
    cr.clip();
    match &k.photo {
        Some(p) => {
            let k2 = THUMB / p.color.width() as f64;
            cr.scale(k2, k2);
            let _ = cr.set_source_surface(&p.gray, 0.0, 0.0);
            let _ = cr.paint_with_alpha(1.0 - d);
            let _ = cr.set_source_surface(&p.color, 0.0, 0.0);
            let _ = cr.paint_with_alpha(d);
        }
        None => {
            // 불러오는 동안: 분야 색의 은은한 그라데이션
            let a = dropcap_core::models::hex_rgb(&crate::widgets::source_color(&it.source_id));
            let c = dropcap_core::models::hex_rgb(&it.topic_color(dark()));
            let g = cairo::LinearGradient::new(0.0, 0.0, THUMB, THUMB);
            g.add_color_stop_rgba(0.0, a.0, a.1, a.2, 0.35);
            g.add_color_stop_rgba(0.5, c.0, c.1, c.2, 0.25);
            g.add_color_stop_rgba(1.0, a.0, a.1, a.2, 0.12);
            let _ = cr.set_source(&g);
            let _ = cr.paint();
        }
    }
    cr.restore().ok();
    drip::rounded(cr, 0.25, 0.25, THUMB - 0.5, THUMB - 0.5, 12.0);
    cr.set_source_rgba(1.0, 1.0, 1.0, 0.25);
    cr.set_line_width(0.5);
    let _ = cr.stroke();
    let _ = cr.pop_group_to_source();
    let _ = cr.paint_with_alpha(0.25 + 0.75 * d);
    cr.restore().ok();
}

// 열지 않고 바로: 나중에 읽기 · 브라우저로(마우스를 올리면 나타남, N-08)
fn draw_quick(cr: &cairo::Context, k: &Card, r: &R, hov: f64) {
    if hov <= 0.01 {
        return;
    }
    let Kind::News(it) = &k.kind else { return };
    let (sx, bx, by) = quick_buttons(r);
    let by = by + 4.0 * (1.0 - hov);
    let saved = ui().core.is_saved(it);
    let (ir, ig, ib, ia) = ink(1.0);
    for (i, x) in [sx, bx].into_iter().enumerate() {
        drip::rounded(cr, x, by, 24.0, 22.0, 7.0);
        cr.set_source_rgba(ir, ig, ib, 0.08 * hov);
        let _ = cr.fill();
        cr.set_source_rgba(ir, ig, ib, ia * hov);
        cr.set_line_width(1.3);
        let (cx, cy) = (x + 12.0, by + 11.0);
        if i == 0 {
            // 책갈피(저장했으면 채움)
            cr.move_to(cx - 4.0, cy - 6.0);
            cr.line_to(cx + 4.0, cy - 6.0);
            cr.line_to(cx + 4.0, cy + 6.0);
            cr.line_to(cx, cy + 3.0);
            cr.line_to(cx - 4.0, cy + 6.0);
            cr.close_path();
            if saved {
                let _ = cr.fill();
            } else {
                let _ = cr.stroke();
            }
        } else {
            // 나침반(브라우저)
            cr.new_sub_path();
            cr.arc(cx, cy, 6.5, 0.0, std::f64::consts::TAU);
            let _ = cr.stroke();
            cr.move_to(cx + 3.0, cy - 3.0);
            cr.line_to(cx - 1.2, cy - 1.2);
            cr.line_to(cx - 3.0, cy + 3.0);
            cr.line_to(cx + 1.2, cy + 1.2);
            cr.close_path();
            let _ = cr.fill();
        }
    }
}

fn draw_close(cr: &cairo::Context, r: &R, hov: f64) {
    let s = 0.6 + 0.4 * hov;
    cr.save().ok();
    cr.translate(r.x - 7.0, r.y - 7.0);
    cr.scale(s, s);
    cr.push_group();
    cr.arc(10.0, 11.0, 10.0, 0.0, std::f64::consts::TAU);
    cr.set_source_rgba(0.0, 0.0, 0.0, 0.15);
    let _ = cr.fill();
    cr.arc(10.0, 10.0, 10.0, 0.0, std::f64::consts::TAU);
    if dark() {
        cr.set_source_rgba(0.24, 0.24, 0.26, 0.95);
    } else {
        cr.set_source_rgba(0.97, 0.97, 0.98, 0.95);
    }
    let _ = cr.fill_preserve();
    let (ir, ig, ib, _) = ink(1.0);
    cr.set_source_rgba(ir, ig, ib, 0.1);
    cr.set_line_width(0.5);
    let _ = cr.stroke();
    cr.set_source_rgba(ir, ig, ib, 0.6);
    cr.set_line_width(1.4);
    cr.move_to(7.0, 7.0);
    cr.line_to(13.0, 13.0);
    cr.move_to(13.0, 7.0);
    cr.line_to(7.0, 13.0);
    let _ = cr.stroke();
    let _ = cr.pop_group_to_source();
    let _ = cr.paint_with_alpha(hov);
    cr.restore().ok();
}

// 묶음 카드의 분야 원(분야 색 14% 바탕 + 분야 기호)
fn draw_badge(cr: &cairo::Context, x: f64, y: f64, col: (f64, f64, f64), icon: &str, a: f64) {
    cr.save().ok();
    cr.arc(x + 15.0, y + 15.0, 15.0, 0.0, std::f64::consts::TAU);
    cr.set_source_rgba(col.0, col.1, col.2, 0.14 * a);
    let _ = cr.fill();
    cr.set_source_rgba(col.0, col.1, col.2, a);
    if let Some(surf) = icon_surface(icon, 16) {
        let _ = cr.mask_surface(&surf, x + 7.0, y + 7.0);
    } else {
        // 아이콘 테마에 없으면 쟁반 모양(줄 세 개)
        cr.set_line_width(1.8);
        for i in 0..3 {
            let yy = y + 10.5 + i as f64 * 4.5;
            cr.move_to(x + 9.0, yy);
            cr.line_to(x + 21.0, yy);
        }
        let _ = cr.stroke();
    }
    cr.restore().ok();
}

thread_local! {
    static ICONS: RefCell<std::collections::HashMap<String, Option<cairo::ImageSurface>>> = RefCell::new(Default::default());
}

// 아이콘 테마의 기호 아이콘을 Cairo 마스크로(색은 그릴 때 입힘). 한 번 만들면 기억.
fn icon_surface(name: &str, size: i32) -> Option<cairo::ImageSurface> {
    if let Some(s) = ICONS.with(|m| m.borrow().get(name).cloned()) {
        return s;
    }
    let made = (|| {
        let display = gdk::Display::default()?;
        let theme = gtk::IconTheme::for_display(&display);
        if !theme.has_icon(name) {
            return None;
        }
        let paintable = theme.lookup_icon(name, &[], size, 1, gtk::TextDirection::Ltr, gtk::IconLookupFlags::FORCE_SYMBOLIC);
        let file = paintable.file()?;
        let tex = gdk::Texture::from_file(&file).ok()?;
        let (w, h) = (tex.width() as usize, tex.height() as usize);
        let mut buf = vec![0u8; w * h * 4];
        tex.download(&mut buf, w * 4);
        let mut src = cairo::ImageSurface::create(cairo::Format::ARgb32, w as i32, h as i32).ok()?;
        let stride = src.stride() as usize;
        {
            let mut data = src.data().ok()?;
            for yy in 0..h {
                data[yy * stride..yy * stride + w * 4].copy_from_slice(&buf[yy * w * 4..(yy + 1) * w * 4]);
            }
        }
        let out = cairo::ImageSurface::create(cairo::Format::ARgb32, size, size).ok()?;
        {
            let cr = cairo::Context::new(&out).ok()?;
            cr.scale(size as f64 / w as f64, size as f64 / h as f64);
            cr.set_source_surface(&src, 0.0, 0.0).ok()?;
            cr.paint().ok()?;
        }
        Some(out)
    })();
    ICONS.with(|m| m.borrow_mut().insert(name.to_string(), made.clone()));
    made
}

// 안내 카드의 반짝이(하늘색→파랑)
fn draw_sparkle(cr: &cairo::Context, x: f64, y: f64, a: f64) {
    cr.save().ok();
    cr.push_group();
    cr.arc(x + 15.0, y + 15.0, 15.0, 0.0, std::f64::consts::TAU);
    cr.set_source_rgba(0.0, 0.48, 1.0, 0.12);
    let _ = cr.fill();
    let star = |cx: f64, cy: f64, r: f64| {
        cr.move_to(cx, cy - r);
        cr.curve_to(cx + r * 0.15, cy - r * 0.15, cx + r * 0.15, cy - r * 0.15, cx + r, cy);
        cr.curve_to(cx + r * 0.15, cy + r * 0.15, cx + r * 0.15, cy + r * 0.15, cx, cy + r);
        cr.curve_to(cx - r * 0.15, cy + r * 0.15, cx - r * 0.15, cy + r * 0.15, cx - r, cy);
        cr.curve_to(cx - r * 0.15, cy - r * 0.15, cx - r * 0.15, cy - r * 0.15, cx, cy - r);
        cr.close_path();
    };
    star(x + 14.0, y + 16.0, 7.5);
    star(x + 20.5, y + 9.0, 3.4);
    let g = cairo::LinearGradient::new(0.0, y + 6.0, 0.0, y + 24.0);
    g.add_color_stop_rgb(0.0, 0.2, 0.78, 0.9);
    g.add_color_stop_rgb(1.0, 0.0, 0.48, 1.0);
    let _ = cr.set_source(&g);
    let _ = cr.fill();
    let _ = cr.pop_group_to_source();
    let _ = cr.paint_with_alpha(a);
    cr.restore().ok();
}

// 아침 브리핑의 해(주황→분홍)
fn draw_sun(cr: &cairo::Context, x: f64, y: f64, a: f64) {
    cr.save().ok();
    cr.push_group();
    cr.arc(x + 15.0, y + 15.0, 15.0, 0.0, std::f64::consts::TAU);
    cr.set_source_rgba(1.0, 0.58, 0.0, 0.13);
    let _ = cr.fill();
    let g = cairo::LinearGradient::new(0.0, y + 7.0, 0.0, y + 22.0);
    g.add_color_stop_rgb(0.0, 1.0, 0.58, 0.0);
    g.add_color_stop_rgb(1.0, 1.0, 0.18, 0.33);
    let _ = cr.set_source(&g);
    let (cx, cy) = (x + 15.0, y + 18.5);
    cr.arc(cx, cy, 5.5, std::f64::consts::PI, 0.0);
    cr.close_path();
    let _ = cr.fill();
    cr.set_line_width(1.6);
    cr.set_line_cap(cairo::LineCap::Round);
    for i in 0..5 {
        let ang = std::f64::consts::PI + std::f64::consts::PI * (i as f64 + 0.5) / 5.0;
        cr.move_to(cx + ang.cos() * 7.5, cy + ang.sin() * 7.5);
        cr.line_to(cx + ang.cos() * 10.0, cy + ang.sin() * 10.0);
    }
    cr.move_to(cx - 10.0, cy + 1.5);
    cr.line_to(cx + 10.0, cy + 1.5);
    let _ = cr.stroke();
    let _ = cr.pop_group_to_source();
    let _ = cr.paint_with_alpha(a);
    cr.restore().ok();
}

// 시험용: 지금 알림 창을 PNG 로(회색 바탕에 2배로 직접 그려 화면 캡처 권한 없이)
pub fn snapshot(name: &str) {
    let Some(dir) = ui().env.shot_dir.clone() else { return };
    let _ = std::fs::create_dir_all(&dir);
    let Ok(img) = cairo::ImageSurface::create(cairo::Format::ARgb32, (PANEL_W * 2.0) as i32, (PANEL_H * 2.0) as i32) else { return };
    if let Ok(cr) = cairo::Context::new(&img) {
        cr.scale(2.0, 2.0);
        if dark() {
            cr.set_source_rgb(0.22, 0.24, 0.30);
        } else {
            cr.set_source_rgb(0.78, 0.82, 0.88);
        }
        let _ = cr.paint();
        draw_all(&cr);
    }
    let mut img = img;
    img.flush();
    let (w, h, stride) = (img.width(), img.height(), img.stride() as usize);
    let Ok(data) = img.data().map(|d| d.to_vec()) else { return };
    let tex = gdk::MemoryTexture::new(w, h, gdk::MemoryFormat::B8g8r8a8Premultiplied, &glib::Bytes::from_owned(data), stride);
    let _ = tex.save_to_png(dir.join(format!("{name}.png")));
}

// 묶음 한 방울(G-07): "경제 7건" + 제목 2줄, 누르면 매거진의 그 분야 지면(맥 ToastCenter.showBundle)
// 지켜볼 낱말 하루 정리 물방울(N-27): "오늘 ○○ 소식 3건" + 제목 2줄 → 누르면 매거진 검색 결과
pub fn show_watch(word: &str, items: Vec<NewsItem>, sound: bool) {
    if items.is_empty() || !place::banners_allowed() {
        return;
    }
    if !place::can_drip() {
        let title = format!("오늘 {word} 소식 {}건", items.len());
        system_fallback(&title, &items.iter().take(2).map(|i| i.display_title().to_string()).collect::<Vec<_>>().join("\n"));
        return;
    }
    push(Kind::Watch(word.to_string(), items), sound, false);
}

pub fn show_bundle(section: &str, items: Vec<NewsItem>, sound: bool) {
    if items.is_empty() || !place::banners_allowed() {
        return;
    }
    if !place::can_drip() {
        let title = format!("{} {}건", dropcap_core::sections::name(section), items.len());
        system_fallback(&title, &items.iter().take(3).map(|i| i.display_title().to_string()).collect::<Vec<_>>().join("\n"));
        return;
    }
    push(Kind::Bundle(section.to_string(), items), sound, false);
}
