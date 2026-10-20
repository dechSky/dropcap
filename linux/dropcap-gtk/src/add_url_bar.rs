// 저장 목록 위의 '주소로 추가…' 칸(맥 UI/AddURLBar.swift): 피드에 없는 기사 주소를 붙여 넣어 나중에 읽기로 저장
use crate::ds::{font, space};
use crate::widgets::label;
use gtk::prelude::*;
use std::cell::Cell;
use std::rc::Rc;

// compact: 상단바 창(작게) · 매거진(넓게)
pub fn build(compact: bool) -> gtk::Box {
    let root = gtk::Box::new(gtk::Orientation::Vertical, space::XS);
    let row = gtk::Box::new(gtk::Orientation::Horizontal, space::S);
    let entry = gtk::Entry::builder()
        .placeholder_text("주소로 추가… (기사 주소를 붙여 넣고 Enter)")
        .primary_icon_name("insert-link-symbolic")
        .hexpand(true)
        .build();
    let save = gtk::Button::builder().label("저장").css_classes(["flat"]).visible(false).build();
    let spinner = gtk::Spinner::builder().visible(false).build();
    row.append(&entry);
    row.append(&spinner);
    row.append(&save);
    root.append(&row);
    let msg = label("", if compact { font::CAPTION } else { font::CALLOUT }, &[]);
    msg.set_wrap(false);
    msg.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
    msg.set_visible(false);
    root.append(&msg);

    let busy = Rc::new(Cell::new(false));
    let shown = Rc::new(Cell::new(0u64)); // 알림 글 차례(늦게 끝난 지우기가 새 글을 지우지 않게)
    {
        let save = save.clone();
        entry.connect_changed(move |e| save.set_visible(!e.text().is_empty()));
    }
    let add = {
        let (entry, save, spinner, msg, busy, shown) = (entry.clone(), save.clone(), spinner.clone(), msg.clone(), busy.clone(), shown.clone());
        Rc::new(move || {
            let raw = entry.text().to_string();
            if raw.trim().is_empty() || busy.get() {
                return;
            }
            busy.set(true);
            entry.set_sensitive(false);
            save.set_visible(false);
            spinner.set_visible(true);
            spinner.start();
            let (entry, save, spinner, msg, busy, shown) = (entry.clone(), save.clone(), spinner.clone(), msg.clone(), busy.clone(), shown.clone());
            crate::integrations::save(&raw, None, false, move |r| {
                busy.set(false);
                entry.set_sensitive(true);
                spinner.stop();
                spinner.set_visible(false);
                msg.remove_css_class("success");
                msg.remove_css_class("warning");
                match r {
                    Ok(it) => {
                        msg.set_text(&format!("✓ 저장함 · {}", it.display_title()));
                        msg.add_css_class("success");
                        entry.set_text("");
                    }
                    Err(f) => {
                        msg.set_text(&format!("⚠ {}", f.message()));
                        msg.add_css_class("warning");
                        save.set_visible(!entry.text().is_empty());
                    }
                }
                msg.set_visible(true);
                let n = shown.get() + 1;
                shown.set(n);
                crate::widgets::later(4000, move || {
                    if shown.get() == n {
                        msg.set_visible(false);
                    }
                });
            });
        })
    };
    {
        let add = add.clone();
        entry.connect_activate(move |_| add());
    }
    save.connect_clicked(move |_| add());
    root
}
