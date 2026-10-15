// 설정 창(P-01~P-07·G-13, 맥 UI/SettingsView.swift): 일반 · 분야 · 구독 · 거르기.
use crate::app::{bg, ui};
use crate::strings;
use crate::theme;
use crate::widgets::{chip, icon, label};
use adw::prelude::*;
use dropcap_core::app_model::{UiEvent, INTERVALS};
use dropcap_core::channels::{self, CATALOG};
use dropcap_core::models::{resources, ItemKind, Source};
use dropcap_core::store::{Position, Style};
use gtk::glib;
use std::cell::RefCell;
use std::rc::Rc;

thread_local! {
    static WINDOW: RefCell<Option<adw::PreferencesWindow>> = const { RefCell::new(None) };
}

// tab: "general" | "sections" | "sources" | "filters" | "scrapbook"
pub fn open(tab: Option<&str>) {
    let w = WINDOW.with(|c| c.borrow().clone()).unwrap_or_else(build);
    if let Some(t) = tab {
        w.set_visible_page_name(t);
    }
    w.present();
    // 시험용(DROPCAP_TEST_SHOT_DIR): 세 쪽을 차례로 찍는다
    if ui().env.shot_dir.is_some() {
        crate::shots::shot_later(&w, "settings-general", 3000);
        for (i, page) in ["sections", "sources", "filters"].into_iter().enumerate() {
            let w2 = w.clone();
            crate::widgets::later(3500 + i as u64 * 2500, move || w2.set_visible_page_name(page));
            crate::shots::shot_later(&w, &format!("settings-{page}"), 5000 + i as u64 * 2500);
        }
    }
}

// 줄 끝에 붙는 짧은 글자(줄바꿈 없이)
fn tag(text: &str, size: f64, weight: u16, classes: &[&str]) -> gtk::Label {
    let l = label(text, size, weight, classes);
    l.set_wrap(false);
    l.set_valign(gtk::Align::Center);
    l
}

fn build() -> adw::PreferencesWindow {
    let u = ui();
    let w = adw::PreferencesWindow::builder()
        .title("Dropcap 설정")
        .default_width(600)
        .default_height(640)
        .search_enabled(false)
        .hide_on_close(true)
        .build();
    w.set_application(Some(&u.app));
    w.add(&general());
    w.add(&crate::settings_sections::page());
    w.add(&sources());
    w.add(&filters());
    w.add(&crate::scrapbook_settings::page()); // 스크랩북(I-05·I-06)
    WINDOW.with(|c| *c.borrow_mut() = Some(w.clone()));
    w
}

fn caption(text: &str) -> gtk::Label {
    let l = label(text, 12.0, 400, &["dc-secondary"]);
    l.set_margin_top(6);
    l
}

fn combo(title: &str, items: &[String], selected: usize, on: impl Fn(usize) + 'static) -> adw::ComboRow {
    let model = gtk::StringList::new(&items.iter().map(|s| s.as_str()).collect::<Vec<_>>());
    let row = adw::ComboRow::builder().title(title).model(&model).selected(selected as u32).build();
    row.connect_selected_notify(move |r| on(r.selected() as usize));
    row
}

fn switch(title: &str, on: bool, f: impl Fn(bool) + 'static) -> adw::SwitchRow {
    let r = adw::SwitchRow::builder().title(title).active(on).build();
    r.connect_active_notify(move |r| f(r.is_active()));
    r
}

// MARK: 일반(P-01~P-05)
fn general() -> adw::PreferencesPage {
    let u = ui();
    let st = u.core.settings();
    let page = adw::PreferencesPage::builder().title("일반").icon_name("emblem-system-symbolic").name("general").build();

    let g = adw::PreferencesGroup::builder().title("알림").build();
    let style = combo(
        "알림 모양",
        &["물방울 (앱이 직접 그림)".into(), "시스템 알림".into()],
        if st.style == Style::System { 1 } else { 0 },
        |i| ui().core.update(|s| s.style = if i == 1 { Style::System } else { Style::Drop }),
    );
    if crate::hotkeys::is_wayland_session() && desktop_is("GNOME") {
        style.set_subtitle("GNOME Wayland 에서는 앱이 화면 위에 창을 띄울 수 없어 시스템 알림으로 자동 전환됩니다.");
    } else if !crate::sysnotify::available() {
        style.set_subtitle("시스템 알림을 쓸 수 없는 환경이면 물방울로 알립니다.");
    }
    g.add(&style);
    g.add(&combo(
        "알림 위치",
        &["위쪽 가운데".into(), "오른쪽 위".into()],
        if st.position == Position::Right { 1 } else { 0 },
        |i| ui().core.update(|s| s.position = if i == 1 { Position::Right } else { Position::Center }),
    ));
    g.add(&switch("알림 소리", st.sound, |v| ui().core.update(|s| s.sound = v)));
    let labels: Vec<String> = INTERVALS.iter().map(|m| format!("{m}분")).collect();
    let sel = INTERVALS.iter().position(|m| *m == st.interval_minutes).unwrap_or(1);
    g.add(&combo("확인 간격", &labels, sel, |i| ui().core.update(|s| s.interval_minutes = INTERVALS[i])));
    let preview = adw::ActionRow::builder().title("알림 미리 보기").activatable(true).build();
    let pb = gtk::Button::builder().label("미리 보기").valign(gtk::Align::Center).build();
    pb.connect_clicked(|_| ui().core.preview());
    preview.add_suffix(&pb);
    preview.set_activatable_widget(Some(&pb));
    g.add(&preview);
    page.add(&g);

    // 회의·발표 중에는 조용히(N-25)
    let g = adw::PreferencesGroup::builder().title("회의·발표 중에는 조용히").build();
    g.add(&switch("전체 화면 앱을 쓰는 중", st.auto_quiet_fullscreen, |v| ui().core.update(|s| s.auto_quiet_fullscreen = v)));
    g.add(&switch("화면을 공유·기록하는 중", st.auto_quiet_sharing, |v| ui().core.update(|s| s.auto_quiet_sharing = v)));
    let cal = adw::SwitchRow::builder()
        .title("캘린더 일정 중")
        .subtitle("리눅스에는 데스크톱 공통 일정 저장소가 없어 쓸 수 없습니다")
        .active(false)
        .sensitive(false)
        .build();
    g.add(&cal);
    let full_note = if crate::hotkeys::is_wayland_session() {
        "Wayland 에서는 다른 앱의 전체 화면을 알 수 없어 화면 공유·기록만 알아봅니다."
    } else {
        "전체 화면은 앞에 있는 다른 앱 창이 전체 화면일 때입니다."
    };
    g.add(&caption(&format!(
        "이때 온 소식은 물방울 없이 '안 읽음'에 쌓이고, 알릴 만한 소식은 그 분야 묶음으로 모입니다. 화면 공유·기록은 OBS·SimpleScreenRecorder·Kooha 같은 기록 앱이 떠 있는지로 알아봅니다(Zoom·Meet 의 화면 공유는 알 수 없음). {full_note}"
    )));
    page.add(&g);

    // 번역(P-02): 리눅스에는 무료 기기 내 번역이 없다(T-05 ⊘)
    let g = adw::PreferencesGroup::builder().title("번역").build();
    let r = adw::ActionRow::builder().title("번역 방식").build();
    r.add_suffix(&tag("Google 번역", 13.0, 400, &["dc-secondary"]));
    g.add(&r);
    g.add(&caption("리눅스에는 무료 기기 내 번역이 없어 Google 번역 공개 엔드포인트를 씁니다. 기사 문장이 Google 로 전송되며, 공식 API 가 아니라 언제든 막힐 수 있습니다."));
    page.add(&g);

    // 글꼴(P-03)
    let g = adw::PreferencesGroup::builder().title("글꼴").build();
    g.add(&switch("Pretendard 글꼴 쓰기 (한글이 더 또렷함)", u.prefs.borrow().use_pretendard, |v| {
        ui().update_prefs(|p| p.use_pretendard = v);
        theme::refresh_all();
    }));
    g.add(&caption("끄면 시스템 글꼴을 씁니다. 열려 있는 창에도 바로 적용됩니다."));
    page.add(&g);

    // 요약(P-04): Ollama 가 있는지 확인은 뒤에서
    let g = adw::PreferencesGroup::builder().title("요약").build();
    let r = adw::ActionRow::builder().title("3줄 요약").subtitle("확인하는 중…").subtitle_lines(3).build();
    g.add(&r);
    {
        let r = r.clone();
        bg(dropcap_core::summarizer::model(), move |m| r.set_subtitle(&dropcap_core::summarizer::status_text(&m)));
    }
    page.add(&g);

    // 내 기록 내보내기·가져오기(P-08)
    page.add(&crate::backup_ui::group());

    // 시작(P-05)
    let g = adw::PreferencesGroup::builder().title("시작").build();
    let dir = dropcap_core::system::autostart_dir();
    let on = dropcap_core::system::launch_at_login(&dir);
    let row = adw::SwitchRow::builder().title("로그인할 때 자동 실행").active(on).build();
    row.connect_active_notify(|r| {
        let v = r.is_active();
        let dir = dropcap_core::system::autostart_dir();
        match dropcap_core::system::set_launch_at_login(&dir, v, &dropcap_core::system::exec_path()) {
            Ok(()) => ui().update_prefs(|p| p.launch_at_login = v),
            Err(e) => {
                log::warn!("로그인 항목 설정 실패: {e}");
                r.set_active(!v);
            }
        }
    });
    g.add(&row);
    page.add(&g);

    page.add(&crate::scrapbook_settings::integrations_group()); // 데스크톱 검색 · 명령줄(I-02·I-03)

    // 트레이 안내(GNOME)
    if desktop_is("GNOME") {
        let g = adw::PreferencesGroup::builder().title("트레이 아이콘").build();
        g.add(&caption("GNOME 에서는 AppIndicator 확장(gnome-shell-extension-appindicator)이 있어야 윗막대에 아이콘이 보입니다. 아이콘이 없으면 Dropcap 을 다시 실행하면 상단바 창이 열립니다."));
        page.add(&g);
    }
    page
}

fn desktop_is(name: &str) -> bool {
    std::env::var("XDG_CURRENT_DESKTOP").map(|d| d.split(':').any(|p| p.eq_ignore_ascii_case(name))).unwrap_or(false)
}

// MARK: 구독(P-06, K-02~K-04)
struct Sources {
    custom_group: adw::PreferencesGroup,
    custom_rows: RefCell<Vec<gtk::Widget>>,
    custom_ids: RefCell<Vec<String>>,
    updaters: RefCell<Vec<Box<dyn Fn()>>>,
}

fn sources() -> adw::PreferencesPage {
    let page = adw::PreferencesPage::builder().title("구독").icon_name("network-transmit-receive-symbolic").name("sources").build();

    // 채널 추가
    let g = adw::PreferencesGroup::builder().title("채널 추가").build();
    let entry = adw::EntryRow::builder().title("언론사·블로그 주소 또는 youtube.com/@채널 · r/이름 · github.com/소유자/저장소").build();
    let add = gtk::Button::builder().label("구독").valign(gtk::Align::Center).css_classes(["suggested-action"]).build();
    entry.add_suffix(&add);
    g.add(&entry);
    let err = label("", 12.0, 400, &["error"]);
    err.set_visible(false);
    err.set_margin_top(6);
    g.add(&err);
    g.add(&caption("웹사이트·뉴스레터(Substack·Medium)·YouTube 채널·GitHub 릴리스·Reddit·arXiv·팟캐스트 주소를 넣으면 알맞은 피드를 찾아 구독합니다."));
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

    // OPML 가져오기·내보내기
    page.add(&crate::settings_tools::opml_group());

    // 구독 중인 채널
    let custom_group = adw::PreferencesGroup::new();
    page.add(&custom_group);
    let s = Rc::new(Sources { custom_group, custom_rows: RefCell::new(vec![]), custom_ids: RefCell::new(vec![]), updaters: RefCell::new(vec![]) });

    // 기본 출처(등급별)
    for tier in ["lab", "press", "kr"] {
        let g = adw::PreferencesGroup::builder().title(format!("기본 출처 · {}", resources::tier_label(tier))).build();
        for src in resources::CONFIG.sources.iter().filter(|x| x.tier == tier) {
            g.add(&source_row(src, false, &s));
        }
        page.add(&g);
    }

    // 추천 채널(묶음별)
    for group in channels::GROUPS {
        let g = adw::PreferencesGroup::builder().title(format!("추천 · {group}")).build();
        for src in CATALOG.iter().filter(|x| x.group.as_deref() == Some(group)) {
            g.add(&catalog_row(src, &s, &err));
        }
        page.add(&g);
    }

    rebuild_custom(&s);
    {
        let s = s.clone();
        ui().listen(move |e| {
            if matches!(e, UiEvent::State) {
                rebuild_custom(&s);
                for u in s.updaters.borrow().iter() {
                    u();
                }
            }
        });
    }
    page
}

fn rebuild_custom(s: &Rc<Sources>) {
    let st = ui().core.state();
    let ids: Vec<String> = st.custom_sources.iter().map(|x| x.id.clone()).collect();
    s.custom_group.set_title(&format!("구독 중인 채널 {}", st.custom_sources.len()));
    if *s.custom_ids.borrow() == ids && !s.custom_rows.borrow().is_empty() {
        return;
    }
    for r in s.custom_rows.borrow_mut().drain(..) {
        s.custom_group.remove(&r);
    }
    *s.custom_ids.borrow_mut() = ids;
    let mut rows = vec![];
    if st.custom_sources.is_empty() {
        let r = adw::ActionRow::builder().title("아래 추천 채널을 골라 보세요.").css_classes(["dim-label"]).build();
        rows.push(r.upcast::<gtk::Widget>());
    } else {
        for src in &st.custom_sources {
            rows.push(source_row(src, true, s).upcast::<gtk::Widget>());
        }
    }
    for r in &rows {
        s.custom_group.add(r);
    }
    *s.custom_rows.borrow_mut() = rows;
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

// 구독 중인 채널·기본 출처: 알림 종 · 켜기 스위치 · (지우기) · 주소 · 오류 표시
fn source_row(src: &Source, removable: bool, s: &Rc<Sources>) -> adw::ActionRow {
    let row = adw::ActionRow::builder().title(glib::markup_escape_text(&src.name).as_str()).build();
    row.add_prefix(&source_monogram(src));
    if let Some(h) = src.home.clone().or_else(|| removable.then(|| src.url.clone())) {
        row.set_subtitle(&glib::markup_escape_text(&h));
        row.set_subtitle_lines(1);
    }
    if src.item_kind() != ItemKind::Article {
        let b = kind_badge(src.item_kind());
        b.set_valign(gtk::Align::Center);
        row.add_suffix(&b);
    }
    if src.ai_only {
        row.add_suffix(&tag("AI 글만", 11.5, 400, &["dc-secondary"]));
    }
    let warn = icon("dialog-warning-symbolic", 14);
    warn.add_css_class("warning");
    row.add_suffix(&warn);
    // 출처 건강: 조용함·멈춤·글 없음·오류(켜진 출처만)
    let health = crate::settings_tools::health_badge();
    row.add_suffix(&health);
    let bell = gtk::ToggleButton::builder().css_classes(["flat"]).valign(gtk::Align::Center).build();
    row.add_suffix(&bell);
    let sw = gtk::Switch::builder().valign(gtk::Align::Center).build();
    row.add_suffix(&sw);
    if removable {
        let del = gtk::Button::builder().icon_name("user-trash-symbolic").css_classes(["flat"]).valign(gtk::Align::Center).tooltip_text("구독 해지").build();
        let id = src.id.clone();
        del.connect_clicked(move |_| ui().core.remove_custom_source(&id));
        row.add_suffix(&del);
    }
    let id = src.id.clone();
    let busy = Rc::new(std::cell::Cell::new(false));
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
    s.updaters.borrow_mut().push(Box::new(update));
    row
}

// 추천 채널: 구독 / 확인 중… / 구독 중
fn catalog_row(src: &Source, s: &Rc<Sources>, err: &gtk::Label) -> adw::ActionRow {
    let row = adw::ActionRow::builder()
        .title(glib::markup_escape_text(&src.name).as_str())
        .subtitle(if src.notify_default == Some(false) { "글이 많아 알림 없이 매거진에만 실림" } else { "새 글이 오면 알림" })
        .build();
    row.add_prefix(&source_monogram(src));
    if src.item_kind() != ItemKind::Article {
        let b = kind_badge(src.item_kind());
        b.set_valign(gtk::Align::Center);
        row.add_suffix(&b);
    }
    let done = gtk::Box::new(gtk::Orientation::Horizontal, 4);
    let ok = icon("object-select-symbolic", 13);
    ok.add_css_class("success");
    done.append(&ok);
    let l = tag("구독 중", 12.0, 500, &["success"]);
    done.append(&l);
    done.set_valign(gtk::Align::Center);
    row.add_suffix(&done);
    let btn = gtk::Button::builder().label("구독").valign(gtk::Align::Center).build();
    row.add_suffix(&btn);
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
        let err = err.clone();
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
    s.updaters.borrow_mut().push(Box::new(update));
    row
}

// MARK: 거르기(P-07)
fn filters() -> adw::PreferencesPage {
    let u = ui();
    let st = u.core.settings();
    let page = adw::PreferencesPage::builder().title("거르기").icon_name(crate::menu::filter_icon()).name("filters").build();

    // 낱말로 거르기(C-14)
    let g = adw::PreferencesGroup::builder().title("낱말로 거르기").build();
    let must = adw::EntryRow::builder().title("꼭 알림 (★ 중요 표시) — 예: GPT-6, Claude, Gemini, 오픈소스").text(st.must_keywords.join(", ")).build();
    let mute = adw::EntryRow::builder().title("알리지 않음 — 예: 주식, 채용, 이벤트").text(st.mute_keywords.join(", ")).build();
    let watch = adw::EntryRow::builder().title("지켜볼 낱말 (회사·인물·법안) — 예: 삼성전자, 엔비디아, AI 기본법").text(st.watch_keywords.join(", ")).build();
    g.add(&must);
    g.add(&mute);
    g.add(&watch);
    g.add(&caption("지켜볼 낱말이 든 소식은 분야 설정과 상관없이 같은 이야기마다 한 번 알리고, 아침 브리핑 시각에 \"오늘 ○○ 소식 3건\"으로 모아 알립니다. 꼭 알림(★)과 겹치면 ★ 로 표시합니다."));
    let save_row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    save_row.set_margin_top(6);
    let c = caption("쉼표로 나눠 적으면 바로 저장·적용됩니다. 제목·요약에 그 낱말이 들어가면 걸립니다.");
    c.set_hexpand(true);
    save_row.append(&c);
    let save = gtk::Button::builder().label("저장").valign(gtk::Align::Center).build();
    save_row.append(&save);
    g.add(&save_row);
    let do_save = {
        let (must, mute, watch) = (must.clone(), mute.clone(), watch.clone());
        Rc::new(move || {
            let split = |s: &str| -> Vec<String> { s.split([',', '\n']).map(|x| x.trim().to_string()).filter(|x| !x.is_empty()).collect() };
            let (a, b) = (split(&must.text()), split(&mute.text()));
            let w = dropcap_core::watch_words::normalized(&split(&watch.text()));
            let core = ui().core.clone();
            let now = core.settings();
            if a == now.must_keywords && b == now.mute_keywords && w == now.watch_keywords {
                return;
            }
            core.update(|s| {
                s.must_keywords = a;
                s.mute_keywords = b;
                s.watch_keywords = w;
            });
            core.reapply_keywords(); // 이미 받은 목록에도 바로 적용
        })
    };
    // 입력이 멈추고 0.6초 뒤 저장(글자마다 저장·목록 다시 계산하지 않게)
    let timer: Rc<std::cell::Cell<Option<glib::SourceId>>> = Rc::new(std::cell::Cell::new(None));
    for e in [&must, &mute, &watch] {
        let f = do_save.clone();
        e.connect_entry_activated(move |_| f());
        let (f, t) = (do_save.clone(), timer.clone());
        e.connect_changed(move |_| {
            if let Some(id) = t.take() {
                id.remove();
            }
            let (f, t2) = (f.clone(), t.clone());
            t.set(Some(glib::timeout_add_local_once(std::time::Duration::from_millis(600), move || {
                t2.set(None);
                f();
            })));
        });
    }
    // 탭을 옮기거나 창을 닫을 때도 저장
    {
        let f = do_save.clone();
        page.connect_unmap(move |_| f());
    }
    {
        let f = do_save.clone();
        save.connect_clicked(move |_| f());
    }
    page.add(&g);

    // 방해 금지 시간(C-19)
    let g = adw::PreferencesGroup::builder().title("방해 금지 시간").build();
    let hours: Vec<String> = (0..24).map(|h| format!("{h:02}:00")).collect();
    let start = combo("시작", &hours, st.quiet_start.clamp(0, 23) as usize, |i| ui().core.update(|s| s.quiet_start = i as i64));
    let end = combo("끝", &hours, st.quiet_end.clamp(0, 23) as usize, |i| ui().core.update(|s| s.quiet_end = i as i64));
    start.set_sensitive(st.quiet_enabled);
    end.set_sensitive(st.quiet_enabled);
    let toggle = {
        let (start, end) = (start.clone(), end.clone());
        switch("이 시간에는 알리지 않기", st.quiet_enabled, move |v| {
            ui().core.update(|s| s.quiet_enabled = v);
            start.set_sensitive(v);
            end.set_sensitive(v);
        })
    };
    g.add(&toggle);
    g.add(&start);
    g.add(&end);
    g.add(&caption("이 시간에 온 소식은 알림 없이 '안 읽음'에 쌓입니다."));
    page.add(&g);

    // 아침 브리핑(C-21): 오전 5~12시
    let g = adw::PreferencesGroup::builder().title("아침 브리핑").build();
    let dh: Vec<String> = (5..13).map(|h| format!("오전 {h}시")).collect();
    let hour = combo("시각", &dh, (st.digest_hour.clamp(5, 12) - 5) as usize, |i| ui().core.update(|s| s.digest_hour = i as i64 + 5));
    hour.set_sensitive(st.digest_enabled);
    let dt = {
        let hour = hour.clone();
        switch("매일 지난 하루 소식을 분야별로 정리해 알리기", st.digest_enabled, move |v| {
            ui().core.update(|s| s.digest_enabled = v);
            hour.set_sensitive(v);
        })
    };
    g.add(&dt);
    g.add(&hour);
    let mr = adw::ActionRow::builder().title(format!("{} 보기", strings::MAGAZINE)).build();
    let mb = gtk::Button::builder().label("매거진 열기").valign(gtk::Align::Center).build();
    mb.connect_clicked(|_| crate::magazine::open());
    mr.add_suffix(&mb);
    g.add(&mr);
    page.add(&g);

    // 단축키(H-01·H-02)
    let g = adw::PreferencesGroup::builder().title("단축키").build();
    for (t, k) in [("가장 최근 안 읽은 소식 열기".to_string(), "Ctrl+Alt+N"), (format!("{} 열기", strings::MAGAZINE), "Ctrl+Alt+M")] {
        let r = adw::ActionRow::builder().title(t).build();
        r.add_suffix(&tag(k, 12.5, 400, &["dc-secondary", "monospace"]));
        g.add(&r);
    }
    if let Some(n) = crate::hotkeys::note() {
        g.add(&caption(n));
    }
    // 목록·매거진·읽기 창 안의 키(H-03~H-05)
    for (k, t) in crate::keynav::HELP {
        let r = adw::ActionRow::builder().title(*t).build();
        r.add_suffix(&tag(k, 12.5, 400, &["dc-secondary", "monospace"]));
        g.add(&r);
    }
    page.add(&g);

    // 같은 소식 묶기
    let g = adw::PreferencesGroup::builder().title("같은 소식 묶기").build();
    g.add(&caption("여러 곳이 같은 소식을 다루면 한 번만 알리고 \"외 N곳\"으로 표시합니다. 공식 발표를 먼저 고릅니다."));
    page.add(&g);
    page
}

