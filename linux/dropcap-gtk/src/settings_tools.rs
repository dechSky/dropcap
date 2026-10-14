// 설정 '구독' 탭에 끼워 넣는 조각(맥 UI/SourceTools.swift): 출처 건강 표시, OPML 가져오기·내보내기.
use crate::app::{bg, ui};
use crate::widgets::label;
use adw::prelude::*;
use chrono::Utc;
use dropcap_core::channels::opml;
use dropcap_core::sections;
use dropcap_core::source_health::{Status, BOOK};
use gtk::{gio, glib};
use std::cell::RefCell;
use std::rc::Rc;

fn css(w: &impl IsA<gtk::Widget>, rule: &str) {
    let prov = gtk::CssProvider::new();
    prov.load_from_string(rule);
    #[allow(deprecated)]
    w.as_ref().style_context().add_provider(&prov, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
}

// 출처 줄 옆의 작은 표시: 조용함(n일째 새 글 없음) · 멈춤 · 글 없음 · 오류. 문제 없으면 숨김.
pub fn health_badge() -> gtk::Label {
    let l = label("", 10.5, 600, &[]);
    l.set_wrap(false);
    l.set_valign(gtk::Align::Center);
    l.set_visible(false);
    l
}

pub fn update_health(badge: &gtk::Label, source_id: &str, enabled: bool) {
    let (text, help, color) = match BOOK.status(source_id, Utc::now()) {
        _ if !enabled => (None, String::new(), ""),
        Status::Unknown | Status::Ok => (None, String::new(), ""),
        Status::Quiet(d) => (Some("조용함"), format!("{d}일째 새 글 없음"), "alpha(@window_fg_color, 0.6)"),
        Status::Stalled(d) => (Some("멈춤"), format!("{d}일째 새 글이 없습니다. 주소가 바뀌었거나 피드를 닫았을 수 있습니다."), "#E66100"),
        Status::Empty => (Some("글 없음"), "피드를 받았지만 글이 하나도 없습니다.".into(), "#E66100"),
        Status::Failing(n, m) => (Some("오류"), format!("{n}번 연속 확인 실패{}", if m.is_empty() { String::new() } else { format!(": {m}") }), "#E01B24"),
    };
    match text {
        Some(t) => {
            badge.set_text(t);
            badge.set_tooltip_text(Some(&help));
            css(badge, &format!("label {{ color: {color}; border: 0.5px solid {color}; border-radius: 99px; padding: 0 5px; }}"));
            badge.set_visible(true);
        }
        None => badge.set_visible(false),
    }
}

struct Import {
    running: bool,
    total: usize,
    done: usize,
    added: usize,
    skipped: usize,
    failed: Vec<(String, String, String)>, // 제목·주소·이유
}

// OPML 묶음: 가져오기(다른 RSS 앱에서 내보낸 파일의 피드를 하나씩 확인해 구독) · 내보내기(켜 둔 출처 전부를 분야별로)
pub fn opml_group() -> adw::PreferencesGroup {
    let g = adw::PreferencesGroup::builder().title("OPML").build();
    let row = adw::ActionRow::new();
    let imp = gtk::Button::builder().label("OPML 가져오기…").valign(gtk::Align::Center).build();
    let exp = gtk::Button::builder().label("OPML 내보내기…").valign(gtk::Align::Center).build();
    let bar = gtk::ProgressBar::builder().valign(gtk::Align::Center).width_request(120).visible(false).build();
    let count = label("", 11.5, 400, &["dc-secondary", "numeric"]);
    count.set_wrap(false);
    count.set_visible(false);
    let b = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    b.append(&imp);
    b.append(&exp);
    row.add_prefix(&b);
    row.add_suffix(&count);
    row.add_suffix(&bar);
    g.add(&row);
    let summary = label("", 12.0, 400, &["dc-secondary"]);
    summary.set_margin_top(6);
    summary.set_visible(false);
    g.add(&summary);
    let failed = gtk::Expander::builder().visible(false).build();
    let failed_box = gtk::Box::new(gtk::Orientation::Vertical, 4);
    failed.set_child(Some(&failed_box));
    g.add(&failed);
    let note = label("다른 RSS 앱에서 내보낸 OPML 파일의 피드를 하나씩 확인해 구독합니다. 내보내기는 켜 둔 출처 전부를 분야별로 담습니다.", 12.0, 400, &["dc-secondary"]);
    note.set_margin_top(6);
    g.add(&note);

    let st = Rc::new(RefCell::new(Import { running: false, total: 0, done: 0, added: 0, skipped: 0, failed: vec![] }));
    let show = {
        let (st, imp, exp, bar, count, summary, failed, failed_box) =
            (st.clone(), imp.clone(), exp.clone(), bar.clone(), count.clone(), summary.clone(), failed.clone(), failed_box.clone());
        Rc::new(move || {
            let s = st.borrow();
            imp.set_sensitive(!s.running);
            exp.set_sensitive(!s.running);
            bar.set_visible(s.running);
            count.set_visible(s.running);
            if s.running {
                bar.set_fraction(s.done as f64 / s.total.max(1) as f64);
                count.set_text(&format!("{}/{}", s.done, s.total));
            } else if s.total > 0 {
                summary.set_text(&format!(
                    "{}곳 중 {}곳 추가 · {}곳은 이미 있음{}",
                    s.total,
                    s.added,
                    s.skipped,
                    if s.failed.is_empty() { String::new() } else { format!(" · {}곳 실패", s.failed.len()) }
                ));
                summary.set_visible(true);
            }
            crate::widgets::clear_box(&failed_box);
            for (t, u, r) in &s.failed {
                let v = gtk::Box::new(gtk::Orientation::Vertical, 1);
                v.append(&label(if t.is_empty() { u } else { t }, 11.5, 400, &[]));
                v.append(&label(r, 10.5, 400, &["dc-secondary"]));
                failed_box.append(&v);
            }
            failed.set_label(Some(&format!("추가하지 못한 피드 {}곳", s.failed.len())));
            failed.set_visible(!s.running && !s.failed.is_empty());
        })
    };

    {
        let (st, show, summary) = (st.clone(), show.clone(), summary.clone());
        imp.connect_clicked(move |b| {
            let filter = gtk::FileFilter::new();
            filter.set_name(Some("OPML"));
            filter.add_pattern("*.opml");
            filter.add_pattern("*.xml");
            let filters = gio::ListStore::new::<gtk::FileFilter>();
            filters.append(&filter);
            let dlg = gtk::FileDialog::builder().title("OPML 가져오기").filters(&filters).modal(true).build();
            let parent = b.root().and_downcast::<gtk::Window>();
            let (st, show, summary) = (st.clone(), show.clone(), summary.clone());
            dlg.open(parent.as_ref(), None::<&gio::Cancellable>, move |r| {
                let Ok(file) = r else { return };
                let Some(path) = file.path() else { return };
                let entries = match std::fs::read(&path).map_err(|e| e.to_string()).and_then(|d| opml::parse(&d).map_err(|e| e.to_string())) {
                    Ok(e) => e,
                    Err(e) => {
                        summary.set_text(&format!("OPML 파일을 읽지 못했습니다: {e}"));
                        summary.set_visible(true);
                        return;
                    }
                };
                run_import(entries, st, show);
            });
        });
    }
    {
        let summary = summary.clone();
        exp.connect_clicked(move |b| {
            let dlg = gtk::FileDialog::builder().title("OPML 내보내기").initial_name("Dropcap.opml").modal(true).build();
            let parent = b.root().and_downcast::<gtk::Window>();
            let summary = summary.clone();
            dlg.save(parent.as_ref(), None::<&gio::Cancellable>, move |r| {
                let Ok(file) = r else { return };
                let Some(path) = file.path() else { return };
                let core = ui().core.clone();
                let st = core.state();
                let on: Vec<_> = core.all_sources().into_iter().filter(|s| st.enabled.get(&s.id) == Some(&true)).collect();
                let xml = opml::export(&on, sections::name, Utc::now());
                let msg = match std::fs::write(&path, xml) {
                    Ok(()) => format!("출처 {}곳을 내보냈습니다.", on.len()),
                    Err(e) => format!("저장하지 못했습니다: {e}"),
                };
                summary.set_text(&msg);
                summary.set_visible(true);
            });
        });
    }
    g
}

// 주소 해석기로 실제 피드인지 확인한 뒤 사용자 출처로 추가한다(4곳씩 함께)
fn run_import(entries: Vec<opml::Entry>, st: Rc<RefCell<Import>>, show: Rc<dyn Fn()>) {
    {
        let mut s = st.borrow_mut();
        *s = Import { running: true, total: entries.len(), done: 0, added: 0, skipped: 0, failed: vec![] };
    }
    show();
    let core = ui().core.clone();
    let (tx, rx) = async_channel::unbounded::<(opml::Entry, Option<Option<String>>)>();
    bg(
        async move {
            for chunk in entries.chunks(4) {
                let mut jobs = vec![];
                for e in chunk {
                    if core.all_sources().iter().any(|s| s.url == e.url) {
                        let _ = tx.send((e.clone(), None)).await;
                        continue;
                    }
                    let (c, e2, tx2) = (core.clone(), e.clone(), tx.clone());
                    jobs.push(tokio::spawn(async move {
                        let r = c.add_channel(e2.url.clone(), e2.title.clone()).await;
                        let _ = tx2.send((e2, Some(r))).await;
                    }));
                }
                for j in jobs {
                    let _ = j.await;
                }
            }
        },
        |_| {},
    );
    glib::spawn_future_local(async move {
        while let Ok((e, r)) = rx.recv().await {
            {
                let mut s = st.borrow_mut();
                s.done += 1;
                match r {
                    None => s.skipped += 1,
                    Some(None) => s.added += 1,
                    Some(Some(reason)) if reason == "이미 구독 중인 채널입니다" => s.skipped += 1,
                    Some(Some(reason)) => s.failed.push((e.title.clone(), e.url.clone(), reason)),
                }
                if s.done >= s.total {
                    s.running = false;
                }
            }
            show();
            if !st.borrow().running {
                break;
            }
        }
    });
}
