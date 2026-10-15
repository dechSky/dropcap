// 설정 › 스크랩북(맥 UI/ScrapbookSettingsView.swift): 노트 폴더 자동 저장 · 아무 주소나 나중에 읽기로 보내는 방법(북마클릿·명령줄·주소)
// + 스크랩 노트 폴더 자동 저장 돌리기(맥 Core/ScrapExport.swift 의 화면 쪽).
// 스크랩은 여러 화면(읽기 창·매거진)에서 바뀌므로 2초마다 스크랩 지문을 보고 바뀌었을 때만 쓴다(쓰기 전에 내용 비교도 한 번 더).
use crate::app::ui;
use crate::widgets::label;
use adw::prelude::*;
use dropcap_core::save_link::BOOKMARKLET;
use dropcap_core::scrap_export::{self as se, Config};
use gtk::{gio, glib};
use std::cell::RefCell;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};

#[derive(Default)]
struct Export {
    cfg: Config,
    loaded: bool,
    fingerprint: u64,
    last_error: Option<String>,
    listeners: Vec<Box<dyn Fn()>>,
}

thread_local! {
    static EXPORT: RefCell<Export> = RefCell::new(Export::default());
}

fn dir() -> PathBuf {
    ui().core.store.dir.clone()
}

fn cfg() -> Config {
    EXPORT.with(|e| {
        let mut e = e.borrow_mut();
        if !e.loaded {
            e.cfg = Config::load(&dir());
            e.loaded = true;
        }
        e.cfg.clone()
    })
}

fn set_cfg(f: impl FnOnce(&mut Config)) {
    let mut c = cfg();
    f(&mut c);
    c.save(&dir());
    EXPORT.with(|e| {
        let mut e = e.borrow_mut();
        e.cfg = c;
        e.fingerprint = 0; // 다음 확인 때 바로 맞춤
    });
}

fn notify() {
    // 듣는 쪽(설정 화면)이 다시 EXPORT 를 빌리므로 목록을 잠깐 꺼내서 부른다
    let ls = EXPORT.with(|e| std::mem::take(&mut e.borrow_mut().listeners));
    for l in &ls {
        l();
    }
    EXPORT.with(|e| {
        let mut e = e.borrow_mut();
        let new = std::mem::take(&mut e.listeners);
        e.listeners = ls;
        e.listeners.extend(new);
    });
}

// 앱 시작 때 한 번(main.rs)
pub fn start() {
    glib::timeout_add_seconds_local(2, || {
        tick();
        glib::ControlFlow::Continue
    });
}

fn fingerprint() -> Option<u64> {
    let u = ui();
    let book = u.scrapbook.try_borrow().ok()?;
    let mut h = std::collections::hash_map::DefaultHasher::new();
    for s in &book.scraps {
        (&s.id, &s.collection, &s.memo, &s.quote, &s.quote_original, s.item.display_title(), &s.item.link).hash(&mut h);
    }
    book.collections.hash(&mut h);
    Some(h.finish())
}

fn tick() {
    let c = cfg();
    if !c.enabled || c.path.is_none() {
        return;
    }
    let Some(fp) = fingerprint() else { return };
    if EXPORT.with(|e| e.borrow().fingerprint) == fp {
        return;
    }
    sync_now();
    EXPORT.with(|e| e.borrow_mut().fingerprint = fp);
}

pub fn sync_now() {
    let mut c = cfg();
    let Some(folder) = c.folder().filter(|_| c.enabled) else { return };
    let u = ui();
    let Ok(book) = u.scrapbook.try_borrow() else { return };
    let before = c.written.clone();
    let out = se::sync(&folder, &book.scraps, &book.collections, &mut c);
    drop(book);
    // 폴더 이름이 바뀌면 예전 이름의 파일은 휴지통으로(지우지 않고 되살릴 수 있게)
    for f in &out.stale {
        if let Err(e) = gio::File::for_path(f).trash(None::<&gio::Cancellable>) {
            log::info!("[노트 폴더] 휴지통으로 보내지 못함: {e}");
        }
    }
    if c.written != before {
        c.save(&dir());
    }
    if !out.wrote.is_empty() {
        log::info!("[노트 폴더] {}개 파일을 썼습니다", out.wrote.len());
    }
    EXPORT.with(|e| {
        let mut e = e.borrow_mut();
        e.cfg = c;
        e.last_error = out.error;
    });
    notify();
}

fn choose_folder(parent: Option<gtk::Window>, done: impl Fn(bool) + 'static) {
    let dlg = gtk::FileDialog::builder().title("스크랩 폴더마다 Markdown 파일(.md)을 이 폴더에 만들고 고쳐 씁니다").accept_label("이 폴더에 저장").modal(true).build();
    if let Some(p) = cfg().folder().filter(|p| p.is_dir()) {
        dlg.set_initial_folder(Some(&gio::File::for_path(p)));
    }
    dlg.select_folder(parent.as_ref(), None::<&gio::Cancellable>, move |r| {
        let Some(path) = r.ok().and_then(|f| f.path()) else {
            done(false);
            return;
        };
        set_cfg(|c| {
            c.path = Some(path.to_string_lossy().into_owned());
            c.enabled = true;
        });
        EXPORT.with(|e| e.borrow_mut().last_error = None);
        sync_now();
        done(true);
    });
}

fn tilde(p: &Path) -> String {
    let home = dropcap_core::store::home_dir();
    match p.strip_prefix(&home) {
        Ok(rest) => format!("~/{}", rest.display()),
        Err(_) => p.display().to_string(),
    }
}

fn caption(text: &str) -> gtk::Label {
    let l = label(text, 12.0, 400, &["dc-secondary"]);
    l.set_margin_top(6);
    l
}

pub fn page() -> adw::PreferencesPage {
    let page = adw::PreferencesPage::builder().title("스크랩북").icon_name("user-bookmarks-symbolic").name("scrapbook").build();

    // 노트 폴더로 내보내기
    let g = adw::PreferencesGroup::builder().title("노트 폴더로 내보내기").build();
    let toggle = adw::SwitchRow::builder().title("스크랩할 때마다 노트 폴더에 Markdown 으로 저장").active(cfg().enabled && cfg().path.is_some()).build();
    let folder = adw::ActionRow::builder().title("폴더").subtitle_lines(1).build();
    let pick = gtk::Button::builder().valign(gtk::Align::Center).build();
    let forget = gtk::Button::builder().icon_name("window-close-symbolic").css_classes(["flat"]).valign(gtk::Align::Center).tooltip_text("폴더 잊기(자동 저장 꺼짐)").build();
    folder.add_suffix(&pick);
    folder.add_suffix(&forget);
    let error = label("", 12.0, 500, &["warning"]);
    error.set_margin_top(6);
    let now = gtk::Button::builder().label("지금 저장").valign(gtk::Align::Center).build();
    let help = adw::ActionRow::builder()
        .subtitle("스크랩 폴더마다 ‘폴더 이름.md’ 파일 하나 — Obsidian 보관소 안의 폴더를 고르면 노트로 바로 보입니다. 파일은 덮어쓰니 고쳐 쓸 노트는 다른 이름으로 두세요.")
        .subtitle_lines(4)
        .build();
    help.add_suffix(&now);
    g.add(&toggle);
    g.add(&folder);
    g.add(&help);
    g.add(&error);
    page.add(&g);

    let refresh = {
        let (toggle, folder, pick, forget, error, now) = (toggle.clone(), folder.clone(), pick.clone(), forget.clone(), error.clone(), now.clone());
        move || {
            let c = cfg();
            let exists = c.folder().map(|p| p.is_dir()).unwrap_or(false);
            folder.set_subtitle(&match c.folder() {
                Some(p) if exists => tilde(&p),
                Some(p) => format!("{} (찾지 못함)", tilde(&p)),
                None => "고르지 않음".into(),
            });
            pick.set_label(if c.path.is_none() { "고르기…" } else { "바꾸기…" });
            forget.set_visible(c.path.is_some());
            if toggle.is_active() != (c.enabled && c.path.is_some()) {
                toggle.set_active(c.enabled && c.path.is_some());
            }
            let err = EXPORT.with(|e| e.borrow().last_error.clone()).or_else(|| (c.enabled && c.path.is_some() && !exists).then(|| "폴더를 찾지 못했습니다 — 다시 골라 주세요".into()));
            error.set_text(&err.clone().map(|e| format!("⚠ {e}")).unwrap_or_default());
            error.set_visible(err.is_some());
            let has = ui().scrapbook.try_borrow().map(|b| !b.scraps.is_empty()).unwrap_or(false);
            now.set_sensitive(c.enabled && exists && has);
        }
    };
    refresh();
    let refresh = std::rc::Rc::new(refresh);
    {
        let r = refresh.clone();
        EXPORT.with(|e| e.borrow_mut().listeners.push(Box::new(move || r())));
    }
    {
        let r = refresh.clone();
        toggle.connect_active_notify(move |t| {
            let on = t.is_active();
            if on == (cfg().enabled && cfg().path.is_some()) {
                return;
            }
            if on && cfg().path.is_none() {
                let r = r.clone();
                choose_folder(t.root().and_downcast::<gtk::Window>(), move |_| r());
            } else {
                set_cfg(|c| c.enabled = on);
                if on {
                    sync_now();
                }
                r();
            }
        });
    }
    {
        let r = refresh.clone();
        pick.connect_clicked(move |b| {
            let r = r.clone();
            choose_folder(b.root().and_downcast::<gtk::Window>(), move |_| r());
        });
    }
    {
        let r = refresh.clone();
        forget.connect_clicked(move |_| {
            set_cfg(|c| {
                c.path = None;
                c.enabled = false;
                c.written.clear();
            });
            EXPORT.with(|e| e.borrow_mut().last_error = None);
            r();
        });
    }
    now.connect_clicked(|_| sync_now());

    // 아무 웹 주소나 나중에 읽기로
    let g = adw::PreferencesGroup::builder().title("아무 웹 주소나 나중에 읽기로").build();
    g.add(&adw::ActionRow::builder().title("상단바").subtitle("‘저장’ 목록 위 ‘주소로 추가…’ 칸에 붙여 넣기").build());
    let bm = adw::ActionRow::builder().title("브라우저 북마클릿").build();
    let copy = gtk::Button::builder().label("북마클릿 코드 복사").valign(gtk::Align::Center).build();
    copy.connect_clicked(|b| {
        crate::app::copy_text(BOOKMARKLET);
        b.set_label("복사했어요");
        let b = b.clone();
        crate::widgets::later(1600, move || b.set_label("북마클릿 코드 복사"));
    });
    bm.add_suffix(&copy);
    g.add(&bm);
    g.add(&adw::ActionRow::builder().title("명령줄").subtitle("dropcap --save <주소>").subtitle_selectable(true).build());
    g.add(&caption("새 북마크를 만들고 주소 칸에 복사한 코드를 붙여 넣으세요. 기사를 보다 그 북마크를 누르면 저장 전에 한 번 묻고 Dropcap 의 나중에 읽기에 담깁니다. 단축키·스크립트에서는 dropcap --save <주소> 또는 dropcap://save?url=<주소> 를 열면 됩니다."));
    page.add(&g);
    page
}

// 설정 › 일반 에 들어가는 한 묶음(맥 '위젯 · 단축어 · Spotlight')
pub fn integrations_group() -> adw::PreferencesGroup {
    let g = adw::PreferencesGroup::builder().title("데스크톱 검색 · 명령줄").build();
    let r = adw::SwitchRow::builder().title("저장한 기사·스크랩을 데스크톱 검색에서 찾기").subtitle("GNOME 검색 · KDE KRunner").active(cfg().search).build();
    r.connect_active_notify(|r| {
        let on = r.is_active();
        set_cfg(|c| c.search = on);
    });
    g.add(&r);
    g.add(&caption("GNOME 은 설정 › 검색에서 Dropcap 을 켜 두어야 보입니다. 명령줄 dropcap --latest(최신 소식) · --magazine(매거진 열기) · --save <주소>(나중에 읽기로 저장)를 데스크톱 단축키·스크립트에 연결해 쓰세요. 끄면 검색 결과에 아무것도 내놓지 않습니다."));
    g
}
