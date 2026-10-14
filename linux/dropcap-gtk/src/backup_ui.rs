// 내 기록 내보내기·가져오기(P-08 · 맥 BackupManager): 파일 고르기 · 가져오기 전 자동 백업 · 되돌리기.
// 파일 형식은 핵심 backup.rs(맥·윈도우와 같은 JSON). 스크랩 폴더 목록은 화면의 prefs 사본으로 읽고 쓴다(덮어쓰기 방지).
use crate::app::ui;
use adw::prelude::*;
use chrono::Utc;
use dropcap_core::backup;
use gtk::gio;
use std::path::{Path, PathBuf};

fn dir() -> PathBuf {
    backup::backups_dir(&ui().core.store.dir)
}

fn current() -> backup::BackupFile {
    let folders = ui().scrapbook.borrow().collections.clone();
    ui().core.backup(&folders)
}

// 마지막 가져오기 전에 남긴 파일(되돌리기)
pub fn undo_file() -> Option<PathBuf> {
    backup::latest_before_import(&dir())
}

pub fn export(path: &Path) -> String {
    match dropcap_core::store::write_atomic(path, &backup::encode(&current())) {
        Ok(()) => format!("내보냈습니다: {}", path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default()),
        Err(e) => format!("내보내지 못했습니다: {e}"),
    }
}

// 가져오기 전 지금 기록을 backups/ 에 남기고(최근 5개만), 합친다
pub fn import(path: &Path) -> String {
    let data = match std::fs::read(path) {
        Ok(d) => d,
        Err(e) => return format!("가져오지 못했습니다: {e}"),
    };
    let b = match backup::decode(&data) {
        Ok(b) => b,
        Err(e) => return format!("가져오지 못했습니다: {e}"),
    };
    if let Err(e) = backup::write_before_import(&dir(), &current(), Utc::now()) {
        return format!("가져오지 못했습니다(지금 기록을 남기지 못함): {e}");
    }
    let u = ui();
    let (scraps, folders) = {
        let book = u.scrapbook.borrow();
        (book.scraps.clone(), book.collections.clone())
    };
    let m = backup::merge(&b, &u.core.state(), &scraps, &folders);
    for s in &m.new_scraps {
        u.core.db.save_scrap(s);
    }
    let all = u.core.db.scraps(None);
    u.update_prefs(|p| p.scrap_collections = backup::extra_folders(&m.folders, &all));
    let state = m.state.clone();
    u.core.replace_state(move |_| state);
    u.scrapbook.borrow_mut().reload();
    format!("가져왔습니다 — {}", m.summary.text())
}

pub fn undo() -> String {
    let Some(f) = undo_file() else { return "되돌릴 가져오기가 없습니다".into() };
    let b = match std::fs::read(&f).map_err(|e| e.to_string()).and_then(|d| backup::decode(&d).map_err(|e| e.to_string())) {
        Ok(b) => b,
        Err(e) => return format!("되돌리지 못했습니다: {e}"),
    };
    let u = ui();
    for s in u.core.db.scraps(None) {
        if !b.scraps.iter().any(|x| x.id == s.id) {
            u.core.db.delete_scrap(&s.id);
        }
    }
    let have: Vec<String> = u.core.db.scraps(None).into_iter().map(|s| s.id).collect();
    for s in b.scraps.iter().filter(|s| !have.contains(&s.id)) {
        u.core.db.save_scrap(s);
    }
    u.update_prefs(|p| p.scrap_collections = b.scrap_folders.iter().filter(|f| f.as_str() != dropcap_core::scrapbook::DEFAULT_COLLECTION).cloned().collect());
    let b2 = b.clone();
    u.core.replace_state(move |s| backup::restore(&b2, s));
    u.scrapbook.borrow_mut().reload();
    let _ = std::fs::remove_file(&f);
    "가져오기 전으로 되돌렸습니다".into()
}

// 설정 '일반 › 내 기록'
pub fn group() -> adw::PreferencesGroup {
    let g = adw::PreferencesGroup::builder().title("내 기록").build();
    let intro = gtk::Label::new(Some("계정도 서버도 없습니다. 모든 기록은 이 컴퓨터 안에만 있습니다."));
    intro.set_xalign(0.0);
    intro.set_wrap(true);
    intro.set_margin_bottom(8);
    g.add(&intro);
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let exp = gtk::Button::with_label("내 기록 내보내기…");
    let imp = gtk::Button::with_label("가져오기…");
    let und = gtk::Button::with_label("마지막 가져오기 되돌리기");
    und.set_tooltip_text(Some("가져오기 전에 자동으로 남긴 기록으로 되돌립니다"));
    und.set_visible(undo_file().is_some());
    row.append(&exp);
    row.append(&imp);
    row.append(&und);
    g.add(&row);
    let note = gtk::Label::new(Some(
        "다른 컴퓨터(맥·윈도우·리눅스)로 옮길 때: 저장·스크랩과 폴더·구독·분야·알림 설정·낱말·숨긴 출처를 JSON 파일 하나로 내보내고, 다른 컴퓨터에서 가져오면 없는 것만 더합니다(같은 것은 건너뜀). 기사 캐시·사진은 담지 않습니다. 가져오기 전 기록은 자동으로 남겨 되돌릴 수 있습니다.",
    ));
    note.set_xalign(0.0);
    note.set_wrap(true);
    note.add_css_class("dim-label");
    note.add_css_class("caption");
    note.set_margin_top(8);
    g.add(&note);
    let msg = gtk::Label::new(None);
    msg.set_xalign(0.0);
    msg.set_wrap(true);
    msg.add_css_class("caption");
    msg.set_visible(false);
    g.add(&msg);
    let show = {
        let (msg, und) = (msg.clone(), und.clone());
        move |t: String| {
            msg.set_text(&t);
            msg.set_visible(true);
            und.set_visible(undo_file().is_some());
        }
    };
    {
        let show = show.clone();
        exp.connect_clicked(move |b| {
            let name = format!("Dropcap-기록-{}.json", &backup::stamp(Utc::now())[..8]);
            let dlg = gtk::FileDialog::builder().title("내 기록 내보내기").initial_name(name.as_str()).modal(true).build();
            let parent = b.root().and_downcast::<gtk::Window>();
            let show = show.clone();
            dlg.save(parent.as_ref(), None::<&gio::Cancellable>, move |r| {
                let Ok(file) = r else { return };
                let Some(path) = file.path() else { return };
                show(export(&path));
            });
        });
    }
    {
        let show = show.clone();
        imp.connect_clicked(move |b| {
            let filter = gtk::FileFilter::new();
            filter.set_name(Some("JSON"));
            filter.add_pattern("*.json");
            let filters = gio::ListStore::new::<gtk::FileFilter>();
            filters.append(&filter);
            let dlg = gtk::FileDialog::builder().title("다른 컴퓨터에서 내보낸 Dropcap 기록 가져오기").filters(&filters).modal(true).build();
            let parent = b.root().and_downcast::<gtk::Window>();
            let show = show.clone();
            dlg.open(parent.as_ref(), None::<&gio::Cancellable>, move |r| {
                let Ok(file) = r else { return };
                let Some(path) = file.path() else { return };
                show(import(&path));
            });
        });
    }
    und.connect_clicked(move |_| show(undo()));
    g
}
