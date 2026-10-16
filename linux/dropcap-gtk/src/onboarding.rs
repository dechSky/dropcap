// 첫 실행: 관심 분야 고르기(G-03, 맥 UI/SectionViews.swift 의 OnboardingView).
// 분야 카드(기호·색·이름·대표 출처 2~3곳), 주요 뉴스 스위치(기본 켬), '더 보기'(기후·환경).
// 고르면 그 분야 기본 출처만 켜지고 최근 3일 소식으로 매거진을 채운다(core.choose_sections). 설정 › 분야에서 다시 연다.
use crate::app::ui;
use crate::widgets::{icon, label};
use adw::prelude::*;
use dropcap_core::sections::{self, NewsSection};
use std::cell::RefCell;
use std::collections::HashSet;
use std::rc::Rc;

thread_local! {
    static WINDOW: RefCell<Option<gtk::Window>> = const { RefCell::new(None) };
}

fn css(w: &impl IsA<gtk::Widget>, rule: &str) {
    let prov = gtk::CssProvider::new();
    prov.load_from_string(rule);
    #[allow(deprecated)]
    w.as_ref().style_context().add_provider(&prov, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
}

fn rgb(hex: &str) -> (u8, u8, u8) {
    let (r, g, b) = dropcap_core::models::hex_rgb(hex);
    ((r * 255.0) as u8, (g * 255.0) as u8, (b * 255.0) as u8)
}

struct State {
    picked: HashSet<String>,
    show_more: bool,
}

pub fn open() {
    if let Some(w) = WINDOW.with(|w| w.borrow().clone()) {
        w.present();
        return;
    }
    let u = ui();
    let now = u.core.state().sections_chosen;
    let picked: HashSet<String> = now.clone().unwrap_or_else(|| vec![sections::TOP.into()]).into_iter().collect();
    let show_more = now.as_ref().map(|c| c.iter().any(|id| sections::by_id(id).map(|s| s.is_more()).unwrap_or(false))).unwrap_or(false);
    let st = Rc::new(RefCell::new(State { picked, show_more }));

    let window = gtk::Window::builder().title("관심 분야 고르기").default_width(680).default_height(680).resizable(false).build();
    crate::section_photos::load(); // 분야마다 오늘의 사진(처음 실행이면 피드를 바로 받아 옴)
    window.set_application(Some(&u.app));
    let root = gtk::Box::new(gtk::Orientation::Vertical, 0);

    // 머리: DROPCAP 로고 + 물음 + 설명
    let head = gtk::Box::new(gtk::Orientation::Vertical, 8);
    head.set_margin_start(30);
    head.set_margin_end(30);
    head.set_margin_top(26);
    head.set_margin_bottom(18);
    let logo = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    let d = label("D", 30.0, 900, &[]);
    d.set_wrap(false);
    css(&d, "label { font-family: serif; }");
    let rest = label("ROPCAP", 17.0, 800, &[]);
    rest.set_wrap(false);
    rest.set_valign(gtk::Align::End);
    rest.set_margin_bottom(4);
    css(&rest, "label { font-family: serif; letter-spacing: 2.4px; }");
    logo.append(&d);
    logo.append(&rest);
    head.append(&logo);
    head.append(&label("어떤 소식을 받아 볼까요?", 28.0, 700, &["dc-display"]));
    head.append(&label(
        "고른 분야의 언론사 피드가 켜지고, 매거진 지면도 그 분야로 엮입니다. 알림은 처음엔 고른 분야 중 두 개만 바로 오고, 나머지는 정한 시각에 한 방울로 모아 옵니다.",
        13.0,
        400,
        &["dc-secondary"],
    ));
    root.append(&head);

    let body = gtk::Box::new(gtk::Orientation::Vertical, 14);
    body.set_margin_start(30);
    body.set_margin_end(30);
    body.set_margin_bottom(16);
    let scroll = gtk::ScrolledWindow::builder().hscrollbar_policy(gtk::PolicyType::Never).vexpand(true).child(&body).build();
    root.append(&scroll);

    // 주요 뉴스 스위치
    if let Some(top) = sections::by_id(sections::TOP) {
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 10);
        let (r, g, b) = rgb(&top.color);
        css(&row, &format!("box {{ background: rgba({r},{g},{b},0.08); border-radius: 14px; padding: 14px; }}"));
        let ic = icon(top.icon(), 16);
        css(&ic, &format!("image {{ color: rgb({r},{g},{b}); }}"));
        row.append(&ic);
        let tv = gtk::Box::new(gtk::Orientation::Vertical, 2);
        tv.set_hexpand(true);
        tv.append(&label(&top.name, 14.0, 600, &[]));
        tv.append(&label("어느 분야든 여러 곳이 함께 크게 다룬 소식만 골라 알려 드려요", 12.0, 400, &["dc-secondary"]));
        row.append(&tv);
        let sw = gtk::Switch::builder().valign(gtk::Align::Center).active(st.borrow().picked.contains(sections::TOP)).build();
        {
            let st = st.clone();
            sw.connect_active_notify(move |s| {
                let mut st = st.borrow_mut();
                if s.is_active() {
                    st.picked.insert(sections::TOP.into());
                } else {
                    st.picked.remove(sections::TOP);
                }
            });
        }
        row.append(&sw);
        body.append(&row);
    }

    // 분야 카드 격자
    let grid = gtk::FlowBox::builder().selection_mode(gtk::SelectionMode::None).min_children_per_line(3).max_children_per_line(3).column_spacing(14).row_spacing(14).homogeneous(true).build();
    body.append(&grid);
    let more_btn = gtk::Button::builder().css_classes(["flat"]).halign(gtk::Align::Start).build();
    let mb = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    mb.append(&icon("pan-down-symbolic", 12));
    let ml = label("더 보기", 12.5, 600, &[]);
    ml.set_wrap(false);
    mb.append(&ml);
    more_btn.set_child(Some(&mb));
    body.append(&more_btn);

    // 바닥: 몇 개 골랐는지 + 시작하기/저장
    root.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
    let foot = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    foot.set_margin_start(30);
    foot.set_margin_end(30);
    foot.set_margin_top(14);
    foot.set_margin_bottom(14);
    let count_label = label("", 12.0, 400, &["dc-secondary"]);
    count_label.set_hexpand(true);
    foot.append(&count_label);
    let go = gtk::Button::builder().label(if now.is_none() { "시작하기" } else { "저장" }).css_classes(["suggested-action", "pill"]).build();
    foot.append(&go);
    root.append(&foot);

    let refresh: Rc<RefCell<Option<Box<dyn Fn()>>>> = Rc::new(RefCell::new(None));
    {
        let (st, grid, more_btn, count_label, go) = (st.clone(), grid.clone(), more_btn.clone(), count_label.clone(), go.clone());
        let refresh2 = refresh.clone();
        *refresh.borrow_mut() = Some(Box::new(move || {
            while let Some(c) = grid.first_child() {
                grid.remove(&c);
            }
            let s = st.borrow();
            for sec in sections::pickable().into_iter().filter(|x| !x.is_more() || s.show_more) {
                let on = s.picked.contains(&sec.id);
                let card = section_card(&sec, on);
                let st2 = st.clone();
                let r2 = refresh2.clone();
                let id = sec.id.clone();
                card.connect_clicked(move |_| {
                    {
                        let mut s = st2.borrow_mut();
                        if !s.picked.remove(&id) {
                            s.picked.insert(id.clone());
                        }
                    }
                    if let Some(f) = r2.borrow().as_ref() {
                        f();
                    }
                });
                grid.insert(&card, -1);
            }
            more_btn.set_visible(!s.show_more && sections::pickable().iter().any(|x| x.is_more()));
            let n = s.picked.iter().filter(|x| *x != sections::TOP).count();
            count_label.set_text(&if n == 0 { "분야를 하나 이상 골라 주세요".to_string() } else { format!("{n}개 분야 · 설정 › 분야에서 언제든 바꿀 수 있어요") });
            go.set_sensitive(n > 0);
        }));
    }
    let run = {
        let refresh = refresh.clone();
        move || {
            if let Some(f) = refresh.borrow().as_ref() {
                f();
            }
        }
    };
    run();
    {
        let st = st.clone();
        let run = run.clone();
        more_btn.connect_clicked(move |_| {
            st.borrow_mut().show_more = true;
            run();
        });
    }
    {
        let st = st.clone();
        let w = window.clone();
        go.connect_clicked(move |_| {
            let ids: Vec<String> = st.borrow().picked.iter().cloned().collect();
            ui().core.choose_sections(&ids);
            w.close();
        });
    }
    window.set_child(Some(&root));
    window.connect_close_request(|_| {
        WINDOW.with(|w| *w.borrow_mut() = None);
        gtk::glib::Propagation::Proceed
    });
    WINDOW.with(|w| *w.borrow_mut() = Some(window.clone()));
    crate::motion::present(&window);
    crate::shots::shot_later(&window, "onboarding", 3000);
    crate::shots::shot_later(&window, "onboarding-15s", 15000); // 분야 사진이 채워진 뒤
}

// 분야 유리 카드(나-3 · 맥 SectionGlassCard): 흐린 오늘의 사진 + 분야색 유리판 + 영문·한글 이름 + 대표 출처 2~3곳(처음 고르면 켜질 곳 먼저) + 고름 표시
fn section_card(sec: &NewsSection, on: bool) -> gtk::Button {
    let mut srcs = sections::sources_in(&sec.id, &sections::META);
    srcs.sort_by_key(|m| if m.default_on == Some(true) { 0 } else { 1 });
    let names: Vec<String> = srcs.iter().take(3).map(|m| m.name.clone().unwrap_or_else(|| m.id.clone())).collect();
    let sub = if names.is_empty() { (sec.id == sections::AI).then(|| "OpenAI · Anthropic · AI타임스".to_string()) } else { Some(names.join(" · ")) };
    let card = crate::section_photos::glass_card(sec, sub, 130, true, on);
    let btn = gtk::Button::builder().child(&card.area).build();
    css(&btn, "button { background: none; border: none; padding: 0; box-shadow: none; min-height: 130px; } button:hover { background: none; }");
    btn.update_property(&[gtk::accessible::Property::Label(&format!("{}{}", sec.name, if on { ", 고름" } else { "" }))]);
    btn
}
