// 바깥과 잇기(맥 Integrations/*): dropcap:// 주소 처리 · 아무 주소 나중에 읽기 저장 · 데스크톱 검색(GNOME 검색·KRunner).
// - dropcap:// 주소는 .desktop 의 x-scheme-handler/dropcap 으로 받고, 명령줄 --save·--magazine 도 이 주소로 바꿔
//   GApplication open 으로 이미 떠 있는 Dropcap 에 넘긴다(main.rs).
// - 검색: 앱의 세션 버스 연결에 org.gnome.Shell.SearchProvider2 와 org.kde.krunner1 객체를 단다. 물을 때마다 지금의
//   저장 목록·스크랩에서 찾는다(search_index). 설정에서 끄면 빈 결과.
use crate::app::{bg, ui};
use dropcap_core::models::NewsItem;
use dropcap_core::save_link::{self, Failure};
use dropcap_core::scrap_export::Config;
use dropcap_core::search_index;
use dropcap_core::url_router::{self, Route};
use gtk::prelude::*;
use gtk::{gio, glib};

// MARK: dropcap:// 주소

pub fn handle_uris(uris: &[String]) {
    for u in uris {
        let r = url_router::route(u);
        log::info!("[주소] {} 처리={}", u.chars().take(80).collect::<String>(), !matches!(r, Route::Unknown));
        match r {
            Route::Open(key) => match item_for_key(&key) {
                Some(it) => crate::app::open_item(&it, None),
                None => log::info!("[주소] 기사를 찾지 못함"),
            },
            Route::Magazine => crate::magazine::open(),
            Route::Save(link, title) => confirm_and_save(link, title),
            Route::BadSave => crate::toast::show_info("저장하지 못했어요", Failure::NotUrl.message()),
            Route::Unknown => {}
        }
    }
}

// 기사 key → 기사(최근 목록 · 나중에 읽기 · 스크랩 · 매거진 DB 순서로 찾는다)
pub fn item_for_key(key: &str) -> Option<NewsItem> {
    let u = ui();
    let st = u.core.state();
    st.recent
        .iter()
        .chain(st.saved.iter())
        .find(|i| i.key() == key)
        .cloned()
        .or_else(|| u.scrapbook.try_borrow().ok()?.scraps.iter().find(|s| s.item.key() == key).map(|s| s.item.clone()))
        .or_else(|| u.core.db.items_by_keys(&[key.to_string()]).into_iter().next().map(|s| s.item))
}

// 아무 웹 페이지나 dropcap:// 를 부를 수 있으므로(브라우저의 '항상 허용' 뒤에는 묻지 않음) 저장 전에 한 번 묻는다.
// 시험(DROPCAP_TEST_SCHEME)에서는 묻지 않음.
fn confirm_and_save(link: String, title: Option<String>) {
    if dropcap_core::test_hooks::var("DROPCAP_TEST_SCHEME").is_some() {
        save_and_announce(link, title);
        return;
    }
    let host = dropcap_core::url_safety::host_of(&link);
    let detail = [title.clone(), host, Some(link.chars().take(300).collect())].into_iter().flatten().collect::<Vec<_>>().join("\n");
    let d = gtk::AlertDialog::builder()
        .message("이 페이지를 나중에 읽기에 저장할까요?")
        .detail(detail)
        .buttons(["취소", "저장"])
        .cancel_button(0)
        .default_button(1)
        .modal(true)
        .build();
    d.choose(None::<&gtk::Window>, None::<&gio::Cancellable>, move |r| {
        if r == Ok(1) {
            save_and_announce(link, title);
        }
    });
}

// 바깥에서 들어온 저장은 결과를 작은 알림으로 알린다
fn save_and_announce(link: String, title: Option<String>) {
    save(&link, title, true, |r| match r {
        Ok(it) => crate::toast::show_info("나중에 읽기에 저장했어요", &format!("{} · {}", it.source_name, it.display_title())),
        Err(f) => crate::toast::show_info("저장하지 못했어요", f.message()),
    });
}

// 받기 → 저장 목록 → 미리 받기(본문·번역). 이미 저장한 주소면 그 소식.
pub fn save(raw: &str, title: Option<String>, from_outside: bool, done: impl FnOnce(Result<NewsItem, Failure>) + 'static) {
    let already = ui().core.state().saved;
    let raw = raw.to_string();
    bg(async move { save_link::fetch_item(&raw, title, from_outside, already).await }, move |r| {
        let r = r.map(|(it, _)| {
            let core = ui().core.clone();
            if !core.is_saved(&it) {
                core.toggle_saved(&it); // 저장 + 본문·번역 미리 받기(오프라인 읽기)
            }
            it
        });
        done(r)
    });
}

// MARK: 데스크톱 검색

pub const SEARCH_PATH: &str = "/io/github/dechsky/Dropcap/SearchProvider";
pub const KRUNNER_PATH: &str = "/io/github/dechsky/Dropcap/KRunner";

const SEARCH_XML: &str = r#"<node>
  <interface name="org.gnome.Shell.SearchProvider2">
    <method name="GetInitialResultSet"><arg type="as" name="terms" direction="in"/><arg type="as" name="results" direction="out"/></method>
    <method name="GetSubsearchResultSet"><arg type="as" name="previous_results" direction="in"/><arg type="as" name="terms" direction="in"/><arg type="as" name="results" direction="out"/></method>
    <method name="GetResultMetas"><arg type="as" name="identifiers" direction="in"/><arg type="aa{sv}" name="metas" direction="out"/></method>
    <method name="ActivateResult"><arg type="s" name="identifier" direction="in"/><arg type="as" name="terms" direction="in"/><arg type="u" name="timestamp" direction="in"/></method>
    <method name="LaunchSearch"><arg type="as" name="terms" direction="in"/><arg type="u" name="timestamp" direction="in"/></method>
  </interface>
  <interface name="org.kde.krunner1">
    <method name="Actions"><arg type="a(sss)" name="matches" direction="out"/></method>
    <method name="Match"><arg type="s" name="query" direction="in"/><arg type="a(sssida{sv})" name="matches" direction="out"/></method>
    <method name="Run"><arg type="s" name="matchId" direction="in"/><arg type="s" name="actionId" direction="in"/></method>
  </interface>
</node>"#;

fn enabled() -> bool {
    Config::load(&ui().core.store.dir).search
}

fn current_docs() -> (Vec<NewsItem>, Vec<dropcap_core::scrapbook::Scrap>) {
    let u = ui();
    let scraps = u.scrapbook.try_borrow().map(|b| b.scraps.clone()).unwrap_or_default();
    (u.core.state().saved, scraps)
}

fn find(terms: &[String]) -> Vec<String> {
    if !enabled() {
        return vec![];
    }
    let (saved, scraps) = current_docs();
    search_index::search(&search_index::docs(&saved, &scraps), terms)
}

fn activate(id: &str) {
    let (saved, scraps) = current_docs();
    if let Some(it) = search_index::item_for(id, &saved, &scraps) {
        crate::app::open_item(&it, None);
    }
}

fn metas(ids: &[String]) -> glib::Variant {
    let (saved, scraps) = current_docs();
    let docs = search_index::docs(&saved, &scraps);
    let list: Vec<glib::VariantDict> = ids
        .iter()
        .filter_map(|id| docs.iter().find(|d| &d.id == id))
        .map(|d| {
            let v = glib::VariantDict::new(None);
            v.insert_value("id", &d.id.to_variant());
            v.insert_value("name", &d.title.to_variant());
            v.insert_value("description", &search_index::description(d).to_variant());
            v.insert_value("gicon", &crate::APP_ID.to_variant());
            v
        })
        .collect();
    let arr: Vec<glib::Variant> = list.iter().map(|d| d.end()).collect();
    glib::Variant::tuple_from_iter([glib::Variant::array_from_iter_with_type(glib::VariantTy::VARDICT, arr)])
}

fn search_call(method: &str, params: &glib::Variant) -> Option<glib::Variant> {
    match method {
        "GetInitialResultSet" => {
            let (terms,) = params.get::<(Vec<String>,)>()?;
            Some((find(&terms),).to_variant())
        }
        "GetSubsearchResultSet" => {
            let (_, terms) = params.get::<(Vec<String>, Vec<String>)>()?;
            Some((find(&terms),).to_variant())
        }
        "GetResultMetas" => {
            let (ids,) = params.get::<(Vec<String>,)>()?;
            Some(metas(&ids))
        }
        "ActivateResult" => {
            let (id, _, _) = params.get::<(String, Vec<String>, u32)>()?;
            activate(&id);
            Some(().to_variant())
        }
        "LaunchSearch" => {
            // 결과 목록 대신 앱으로: 매거진 검색 지면을 그 낱말로
            let (terms, _) = params.get::<(Vec<String>, u32)>()?;
            crate::magazine::search_for(&terms.join(" "));
            Some(().to_variant())
        }
        // KRunner: 결과 = (id, 글자, 아이콘, 종류 30=가능한 결과, 관련도, 속성)
        "Actions" => Some((Vec::<(String, String, String)>::new(),).to_variant()),
        "Match" => {
            let (q,) = params.get::<(String,)>()?;
            let terms: Vec<String> = q.split_whitespace().map(String::from).collect();
            let ids = find(&terms);
            let (saved, scraps) = current_docs();
            let docs = search_index::docs(&saved, &scraps);
            let n = ids.len().max(1) as f64;
            let out: Vec<(String, String, String, i32, f64, glib::VariantDict)> = ids
                .iter()
                .enumerate()
                .filter_map(|(i, id)| docs.iter().find(|d| &d.id == id).map(|d| (i, d)))
                .map(|(i, d)| {
                    let props = glib::VariantDict::new(None);
                    props.insert_value("subtext", &search_index::description(d).to_variant());
                    (d.id.clone(), d.title.clone(), crate::APP_ID.to_string(), 30, 0.9 - 0.4 * (i as f64 / n), props)
                })
                .collect();
            let arr: Vec<glib::Variant> = out
                .into_iter()
                .map(|(a, b, c, d, e, p)| glib::Variant::tuple_from_iter([a.to_variant(), b.to_variant(), c.to_variant(), d.to_variant(), e.to_variant(), p.end()]))
                .collect();
            let ty = glib::VariantTy::new("(sssida{sv})").ok()?;
            Some(glib::Variant::tuple_from_iter([glib::Variant::array_from_iter_with_type(ty, arr)]))
        }
        "Run" => {
            let (id, _) = params.get::<(String, String)>()?;
            activate(&id);
            Some(().to_variant())
        }
        _ => None,
    }
}

// 앱이 세션 버스 이름을 얻은 뒤(startup) 부른다
pub fn install_search(app: &adw::Application) {
    let Some(conn) = app.dbus_connection() else {
        log::info!("[검색] 세션 버스가 없어 데스크톱 검색을 켜지 않습니다");
        return;
    };
    let Ok(node) = gio::DBusNodeInfo::for_xml(SEARCH_XML) else { return };
    for (path, iface) in [(SEARCH_PATH, "org.gnome.Shell.SearchProvider2"), (KRUNNER_PATH, "org.kde.krunner1")] {
        let Some(info) = node.lookup_interface(iface) else { continue };
        let r = conn
            .register_object(path, &info)
            .method_call(|_, _, _, _, method, params, inv| match search_call(method, &params) {
                Some(v) => inv.return_value(Some(&v)),
                None => inv.return_error(gio::DBusError::InvalidArgs, "잘못된 인자"),
            })
            .build();
        if let Err(e) = r {
            log::warn!("[검색] {iface} 등록 실패: {e}");
        }
    }
}
