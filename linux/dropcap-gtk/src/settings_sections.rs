// 설정 '분야' 탭(G-13, 맥 SettingsView.sectionsTab): 고른 분야마다 알림 모드·묶음 시각·하루 상한·켜진 출처 수,
// 전체 상한·문턱, 숨긴 출처 되돌리기, 관심 분야 다시 고르기.
use crate::ds::{font, space};
use crate::app::ui;
use crate::widgets::{icon, label};
use adw::prelude::*;
use dropcap_core::app_model::UiEvent;
use dropcap_core::notify_policy::NotifyMode;
use dropcap_core::sections::{self, NewsSection};
use std::cell::RefCell;
use std::rc::Rc;

fn css(w: &impl IsA<gtk::Widget>, rule: &str) {
    let prov = gtk::CssProvider::new();
    prov.load_from_string(rule);
    #[allow(deprecated)]
    w.as_ref().style_context().add_provider(&prov, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
}

fn caption(text: &str) -> gtk::Label {
    let l = label(text, font::CALLOUT, &["dc-secondary"]);
    l.set_margin_top(space::S);
    l
}

struct Page {
    page: adw::PreferencesPage,
    groups: RefCell<Vec<adw::PreferencesGroup>>,
    signature: RefCell<String>, // 고른 분야·숨긴 출처가 바뀔 때만 다시 그린다(값을 고치는 중에 칸이 사라지지 않게)
}

pub fn page() -> adw::PreferencesPage {
    let page = adw::PreferencesPage::builder().title("분야").icon_name("view-grid-symbolic").name("sections").build();
    let p = Rc::new(Page { page: page.clone(), groups: RefCell::new(vec![]), signature: RefCell::new(String::new()) });
    rebuild(&p);
    {
        let p = p.clone();
        ui().listen(move |e| {
            if matches!(e, UiEvent::State | UiEvent::Layout) {
                rebuild(&p);
            }
        });
    }
    page
}

fn signature() -> String {
    let st = ui().core.state();
    format!("{:?}|{:?}", st.sections_chosen, st.hidden_sources)
}

fn rebuild(p: &Rc<Page>) {
    let sig = signature();
    if *p.signature.borrow() == sig && !p.groups.borrow().is_empty() {
        return;
    }
    *p.signature.borrow_mut() = sig;
    for g in p.groups.borrow_mut().drain(..) {
        p.page.remove(&g);
    }
    let core = ui().core.clone();
    let chosen = core.chosen_sections();
    let mut groups = vec![];

    // 머리: 고른 분야 수 + 다시 고르기
    let g = adw::PreferencesGroup::new();
    let n = chosen.iter().filter(|s| *s != sections::TOP).count();
    let head = adw::ActionRow::builder().title(if chosen.is_empty() { "아직 관심 분야를 고르지 않았습니다".to_string() } else { format!("고른 분야 {n}개") }).build();
    let again = gtk::Button::builder().label("관심 분야 다시 고르기…").valign(gtk::Align::Center).build();
    again.connect_clicked(|_| crate::onboarding::open());
    head.add_suffix(&again);
    g.add(&head);
    g.add(&caption("즉시: 여러 곳이 함께 다룬 소식·공식 발표·꼭 알림 낱말·팔로우한 스토리만 바로 물방울로. 묶음: 정한 시각에 \"경제 7건\"처럼 한 방울. 매거진만: 알리지 않음."));
    groups.push(g);

    // 고른 분야마다
    for s in sections::ALL.iter().filter(|s| chosen.contains(&s.id)) {
        groups.push(section_group(s));
    }

    // 알림 양(전체 상한·문턱)
    let st = core.settings();
    let g = adw::PreferencesGroup::builder().title("알림 양").build();
    g.add(&spin("하루 전체 물방울 (번까지)", st.total_daily_cap, 1, 30, |v| ui().core.update(|s| s.total_daily_cap = v)));
    g.add(&spin("국내 n곳 이상 보도면 중요", st.kr_threshold, 1, 10, |v| ui().core.update(|s| s.kr_threshold = v)));
    g.add(&spin("해외 n곳 이상 보도면 중요", st.intl_threshold, 1, 10, |v| ui().core.update(|s| s.intl_threshold = v)));
    g.add(&spin("국내 n곳 이상이면 상한을 넘어도 알림", st.big_threshold, 2, 20, |v| ui().core.update(|s| s.big_threshold = v)));
    g.add(&caption("상한을 넘은 소식은 고였다가 그 분야 묶음 시각에 한 방울로 나갑니다. 같은 이야기는 한 번만 알립니다."));
    groups.push(g);

    // 숨긴 출처
    let hidden = core.state().hidden_sources;
    if !hidden.is_empty() {
        let g = adw::PreferencesGroup::builder().title("숨긴 출처").build();
        let all = core.all_sources();
        for id in hidden {
            let name = sections::META.get(&id).and_then(|m| m.name.clone()).or_else(|| all.iter().find(|s| s.id == id).map(|s| s.name.clone())).unwrap_or_else(|| id.clone());
            let r = adw::ActionRow::builder().title(gtk::glib::markup_escape_text(&name).as_str()).build();
            let b = gtk::Button::builder().label("다시 보이기").css_classes(["flat"]).valign(gtk::Align::Center).build();
            b.connect_clicked(move |_| ui().core.unhide_source(&id));
            r.add_suffix(&b);
            g.add(&r);
        }
        groups.push(g);
    }
    for g in &groups {
        p.page.add(g);
    }
    *p.groups.borrow_mut() = groups;
}

fn spin(title: &str, value: i64, min: i64, max: i64, on: impl Fn(i64) + 'static) -> adw::SpinRow {
    let r = adw::SpinRow::with_range(min as f64, max as f64, 1.0);
    r.set_title(title);
    r.set_value(value as f64);
    r.connect_value_notify(move |r| on(r.value() as i64));
    r
}

// 분야 하나: 기호·이름·켜진 출처 수 + 모드(즉시·묶음·매거진만) + 묶음 시각 + 하루 상한(즉시일 때)
fn section_group(s: &NewsSection) -> adw::PreferencesGroup {
    let core = ui().core.clone();
    let p = core.policy(&s.id);
    let (on, all) = core.source_count(&s.id);
    let g = adw::PreferencesGroup::new();
    let sub = if s.is_flow() {
        "어느 분야든 크게 다룬 소식".to_string()
    } else if all > 0 {
        format!("출처 {on}/{all}곳 켜짐")
    } else {
        "구독 탭에서 출처를 켜고 끕니다".to_string()
    };
    let row = adw::ActionRow::builder().title(gtk::glib::markup_escape_text(&s.name).as_str()).subtitle(sub).build();
    let tile = gtk::Box::new(gtk::Orientation::Vertical, 0);
    tile.set_size_request(26, 26);
    tile.set_valign(gtk::Align::Center);
    let ic = icon(s.icon(), 13);
    ic.set_vexpand(true);
    css(&ic, "image { color: white; }");
    tile.append(&ic);
    let (r, gg, b) = dropcap_core::models::hex_rgb(&s.color);
    css(&tile, &format!("box {{ background: rgb({},{},{}); border-radius: 7px; }}", (r * 255.0) as u8, (gg * 255.0) as u8, (b * 255.0) as u8));
    row.add_prefix(&tile);
    let modes = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    modes.add_css_class("linked");
    modes.set_valign(gtk::Align::Center);
    let mut first: Option<gtk::ToggleButton> = None;
    let mut buttons = vec![];
    for m in NotifyMode::ALL {
        let bt = gtk::ToggleButton::with_label(m.label());
        bt.set_tooltip_text(Some(m.help()));
        if let Some(f) = &first {
            bt.set_group(Some(f));
        } else {
            first = Some(bt.clone());
        }
        bt.set_active(p.mode == m);
        modes.append(&bt);
        buttons.push((m, bt));
    }
    row.add_suffix(&modes);
    g.add(&row);

    let hours: Vec<String> = (6..24).map(|h| format!("{h:02}:00")).collect();
    let hour = adw::ComboRow::builder()
        .title("묶음 시각")
        .model(&gtk::StringList::new(&hours.iter().map(|s| s.as_str()).collect::<Vec<_>>()))
        .selected((p.bundle_hour.clamp(6, 23) - 6) as u32)
        .build();
    let id = s.id.clone();
    hour.connect_selected_notify(move |r| {
        let h = r.selected() as i64 + 6;
        ui().core.set_policy(&id, |p| p.bundle_hour = h);
    });
    let cap = adw::SpinRow::with_range(1.0, 10.0, 1.0);
    cap.set_title("하루 몇 번까지");
    cap.set_value(p.daily_cap as f64);
    let id = s.id.clone();
    cap.connect_value_notify(move |r| {
        let v = r.value() as i64;
        ui().core.set_policy(&id, |p| p.daily_cap = v);
    });
    g.add(&hour);
    g.add(&cap);
    let show = {
        let (hour, cap) = (hour.clone(), cap.clone());
        move |m: NotifyMode| {
            hour.set_visible(m != NotifyMode::Magazine);
            hour.set_subtitle(if m == NotifyMode::Instant { "하루 상한을 넘어 고인 소식을 보내는 시각" } else { "모아 둔 소식을 한 방울로 보내는 시각" });
            cap.set_visible(m == NotifyMode::Instant);
        }
    };
    show(p.mode);
    for (m, bt) in buttons {
        let id = s.id.clone();
        let show = show.clone();
        bt.connect_toggled(move |b| {
            if b.is_active() {
                ui().core.set_policy(&id, |p| p.mode = m);
                show(m);
            }
        });
    }
    g
}
