// 분야 칩 줄(G-09, 맥 UI/SectionViews.swift 의 SectionChipBar): '전체' + 고른 분야.
// AI 를 고르면 그 아래에 AI 안의 하위 칩(모델·연구·정책·투자·보안)이 한 줄 더 나온다.
use crate::widgets::{icon, label};
use dropcap_core::category::NewsCategory;
use dropcap_core::sections;
use gtk::prelude::*;
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

#[derive(Clone, Default, PartialEq)]
pub struct Pick {
    pub section: Option<String>,
    pub sub: Option<NewsCategory>,
}

pub struct ChipBar {
    pub root: gtk::Box,
    main: gtk::Box,
    sub_row: gtk::Revealer,
    sub_box: gtk::Box,
    pick: Rc<RefCell<Pick>>,
    on_change: Rc<RefCell<Option<Box<dyn Fn(&Pick)>>>>,
    small: bool,
}

// 칩 하나: 고르면 분야 색으로 채우고 글자는 흰색, 아니면 옅은 분야 색 바탕에 분야 색 글자
pub fn chip(text: &str, icon_name: &str, color_hex: &str, on: bool, count: Option<usize>, small: bool) -> gtk::Button {
    let b = gtk::Box::new(gtk::Orientation::Horizontal, 4);
    b.append(&icon(icon_name, if small { 10 } else { 11 }));
    let l = label(text, if small { 11.0 } else { 11.5 }, if on { 600 } else { 500 }, &[]);
    l.set_wrap(false);
    b.append(&l);
    if let Some(n) = count.filter(|n| *n > 0) {
        let c = label(&n.to_string(), 10.5, 600, &[]);
        c.set_wrap(false);
        c.set_opacity(0.7);
        b.append(&c);
    }
    let btn = gtk::Button::builder().child(&b).build();
    let (r, g, bl) = dropcap_core::models::hex_rgb(color_hex);
    let (r, g, bl) = ((r * 255.0) as u8, (g * 255.0) as u8, (bl * 255.0) as u8);
    let pad = if small { "3px 7px" } else { "4px 9px" };
    let css = if on {
        format!("button {{ border-radius: 99px; padding: {pad}; min-height: 0; color: white; background: rgb({r},{g},{bl}); box-shadow: none; border: none; }}")
    } else {
        format!(
            "button {{ border-radius: 99px; padding: {pad}; min-height: 0; color: rgb({r},{g},{bl}); background: rgba({r},{g},{bl},0.11); box-shadow: none; border: none; }} button:hover {{ background: rgba({r},{g},{bl},0.18); }}"
        )
    };
    let prov = gtk::CssProvider::new();
    prov.load_from_string(&css);
    #[allow(deprecated)]
    btn.style_context().add_provider(&prov, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
    btn
}

fn accent() -> &'static str {
    "#3584E4"
}

impl ChipBar {
    pub fn new(small: bool) -> Rc<ChipBar> {
        let root = gtk::Box::new(gtk::Orientation::Vertical, 6);
        let main = gtk::Box::new(gtk::Orientation::Horizontal, 5);
        let scroll = gtk::ScrolledWindow::builder().vscrollbar_policy(gtk::PolicyType::Never).hscrollbar_policy(gtk::PolicyType::External).child(&main).build();
        scroll.set_propagate_natural_height(true);
        root.append(&scroll);
        let sub_box = gtk::Box::new(gtk::Orientation::Horizontal, 4);
        let sub_scroll = gtk::ScrolledWindow::builder().vscrollbar_policy(gtk::PolicyType::Never).hscrollbar_policy(gtk::PolicyType::External).child(&sub_box).build();
        sub_scroll.set_propagate_natural_height(true);
        let sub_row = gtk::Revealer::builder().transition_type(gtk::RevealerTransitionType::SlideDown).transition_duration(180).child(&sub_scroll).build();
        root.append(&sub_row);
        Rc::new(ChipBar { root, main, sub_row, sub_box, pick: Rc::new(RefCell::new(Pick::default())), on_change: Rc::new(RefCell::new(None)), small })
    }

    pub fn connect_changed(&self, f: impl Fn(&Pick) + 'static) {
        *self.on_change.borrow_mut() = Some(Box::new(f));
    }

    pub fn pick(&self) -> Pick {
        self.pick.borrow().clone()
    }

    // 고른 분야 목록(sections)과 칩마다 건수(counts)로 다시 그린다
    pub fn rebuild(self: &Rc<Self>, sections_ids: &[String], counts: &HashMap<String, usize>) {
        crate::widgets::clear_box(&self.main);
        let p = self.pick();
        // 고른 분야가 바뀌어 지금 칩이 없어졌으면 '전체'로
        if p.section.as_ref().map(|s| !sections_ids.contains(s)).unwrap_or(false) {
            *self.pick.borrow_mut() = Pick::default();
        }
        let p = self.pick();
        let all = chip("전체", "view-grid-symbolic", accent(), p.section.is_none(), None, self.small);
        {
            let me = self.clone();
            all.connect_clicked(move |_| me.set(Pick::default()));
        }
        self.main.append(&all);
        for id in sections_ids {
            let Some(s) = sections::by_id(id) else { continue };
            let on = p.section.as_deref() == Some(id.as_str());
            let b = chip(&s.name, s.icon(), &s.color, on, counts.get(id).cloned(), self.small);
            let me = self.clone();
            let id2 = id.clone();
            b.connect_clicked(move |_| {
                let cur = me.pick();
                let next = if cur.section.as_deref() == Some(id2.as_str()) { Pick::default() } else { Pick { section: Some(id2.clone()), sub: None } };
                me.set(next);
            });
            self.main.append(&b);
        }
        self.rebuild_sub();
    }

    fn rebuild_sub(self: &Rc<Self>) {
        crate::widgets::clear_box(&self.sub_box);
        let p = self.pick();
        let show = p.section.as_deref() == Some(sections::AI);
        if show {
            for c in NewsCategory::all().into_iter().filter(|c| !c.is_other()) {
                let b = chip(c.label(), c.icon(), c.color(crate::theme::is_dark()), p.sub == Some(c), None, true);
                let me = self.clone();
                b.connect_clicked(move |_| {
                    let mut cur = me.pick();
                    cur.sub = if cur.sub == Some(c) { None } else { Some(c) };
                    me.set(cur);
                });
                self.sub_box.append(&b);
            }
        }
        self.sub_row.set_reveal_child(show);
    }

    // 고른 칩을 바꾸고 알린다(칩 모양은 부르는 쪽이 rebuild 로 다시 그림)
    fn set(self: &Rc<Self>, p: Pick) {
        *self.pick.borrow_mut() = p.clone();
        if let Some(f) = self.on_change.borrow().as_ref() {
            f(&p);
        }
    }
}
