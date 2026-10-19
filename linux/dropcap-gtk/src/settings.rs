// 설정 창(P-01~P-07·G-13, 맥 UI/SettingsView.swift): 일반 · 분야 · 구독 · 거르기.
use crate::app::{bg, ui};
use crate::strings;
use crate::theme;
use crate::widgets::label;
use adw::prelude::*;
use dropcap_core::app_model::INTERVALS;
use dropcap_core::store::{Position, Style};
use dropcap_core::translator;
use gtk::glib;
use std::cell::RefCell;
use std::rc::Rc;

thread_local! {
    static WINDOW: RefCell<Option<adw::PreferencesWindow>> = const { RefCell::new(None) };
}

// tab: "general" | "sections" | "sources" | "filters" | "scrapbook"
pub fn open(tab: Option<&str>) {
    let existing = WINDOW.with(|c| c.borrow().clone());
    let w = existing.clone().unwrap_or_else(build);
    if let Some(t) = tab {
        w.set_visible_page_name(t);
    }
    if existing.is_some() { w.present() } else { crate::motion::present(&w) } // 새 창만 열기 움직임
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
pub(crate) fn tag(text: &str, size: f64, weight: u16, classes: &[&str]) -> gtk::Label {
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
    w.add(&crate::settings_sources::page()); // 구독(찾기·묶음, settings_sources.rs)
    w.add(&filters());
    w.add(&crate::scrapbook_settings::page()); // 스크랩북(I-05·I-06)
    WINDOW.with(|c| *c.borrow_mut() = Some(w.clone()));
    w
}

pub(crate) fn caption(text: &str) -> gtk::Label {
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

    // 번역(P-02 · L4): 번역 방식 고르기(translateEngine — 맥·윈도우와 같은 키·값). 리눅스에는 무료 기기 내 번역이 없다(T-05 ⊘)
    let g = adw::PreferencesGroup::builder().title("번역").build();
    let opts = translator::engine_options(&st.translate_engine);
    let labels: Vec<String> = opts.iter().map(|(_, l)| l.to_string()).collect();
    let sel = opts.iter().position(|(m, _)| *m == translator::normalize_mode(&st.translate_engine)).unwrap_or(0);
    let note = caption(translator::engine_note(&st.translate_engine));
    {
        let note = note.clone();
        g.add(&combo("번역 방식", &labels, sel, move |i| {
            let m = opts[i].0;
            note.set_text(translator::engine_note(m));
            ui().core.update(|s| s.translate_engine = m.into());
        }));
    }
    g.add(&note);
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
    // 사용자가 고쳤을 때만 저장한다: 창은 닫아도 숨기만 하므로, 기록 가져오기·되돌리기 뒤 남은 옛 글자를
    // 탭을 옮기거나 닫을 때(unmap) 다시 저장하면 가져온 낱말을 덮어썼다
    let dirty = Rc::new(std::cell::Cell::new(false));
    let syncing = Rc::new(std::cell::Cell::new(false));
    let do_save = {
        let (must, mute, watch) = (must.clone(), mute.clone(), watch.clone());
        let dirty = dirty.clone();
        Rc::new(move || {
            if !dirty.replace(false) {
                return;
            }
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
        let (f, t, d, sy) = (do_save.clone(), timer.clone(), dirty.clone(), syncing.clone());
        e.connect_changed(move |_| {
            if sy.get() {
                return;
            }
            d.set(true);
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
    // 다시 보일 때 고치던 것이 없으면 지금 값으로(가져오기·되돌리기·다른 창에서 바뀐 낱말)
    {
        let (must, mute, watch) = (must.clone(), mute.clone(), watch.clone());
        let (d, sy) = (dirty.clone(), syncing.clone());
        page.connect_map(move |_| {
            if d.get() {
                return;
            }
            let st = ui().core.settings();
            sy.set(true);
            must.set_text(&st.must_keywords.join(", "));
            mute.set_text(&st.mute_keywords.join(", "));
            watch.set_text(&st.watch_keywords.join(", "));
            sy.set(false);
        });
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

