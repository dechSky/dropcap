// 번역 방식 고르기(L4 · 맥·윈도우와 같은 설정 키 translateEngine = auto|apple|google|off — mac/TRANSLATE.md).
// '번역 안 함'(과 기기 내 엔진이 없는 리눅스의 apple)이면 기사 본문·배경 제목 번역·같은 소식 묶기용 영어 번역 모두 Google 로 보내지 않는다.
// 네트워크 없이: 번역 캐시에 미리 넣은 것으로 '자동'의 길을 보고, '번역 안 함'은 캐시도 쓰지 않고 원문·엔진 없음이어야 한다.
use dropcap_core::app_model::{add_english_titles, AppModel};
use dropcap_core::models::NewsItem;
use dropcap_core::store::{AppState, Settings, Store};
use dropcap_core::translator::{self, Engine, Translator};
use std::sync::{Arc, Mutex};

fn switchable(start: &str) -> (Translator, Arc<Mutex<String>>) {
    let mode = Arc::new(Mutex::new(start.to_string()));
    let m = mode.clone();
    (Translator::with_mode(move || m.lock().unwrap().clone()), mode)
}

#[test]
fn modes_match_mac_and_windows() {
    assert_eq!(translator::MODES, ["auto", "apple", "google", "off"]);
    assert_eq!(translator::normalize_mode("off"), "off");
    assert_eq!(translator::normalize_mode("deepl"), "auto"); // 모르는 값은 자동
    assert!(translator::sends("auto") && translator::sends("google"));
    assert!(!translator::sends("off") && !translator::sends("apple")); // 리눅스엔 기기 내 엔진이 없어 apple = 보내지 않음
}

#[test]
fn off_sends_nothing_and_keeps_original() {
    let rt = tokio::runtime::Runtime::new().unwrap();
    let (tr, mode) = switchable("auto");
    tr.remember("Hello world", "안녕 세상");
    // 자동: 캐시에 있는 번역(Google 것)
    let (out, used) = rt.block_on(tr.translate_many_reporting(&["Hello world".into()]));
    assert_eq!((out[0].as_str(), used), ("안녕 세상", Engine::Google));
    // 번역 안 함: 원문 그대로, 엔진 없음(캐시의 Google 번역도 쓰지 않음)
    *mode.lock().unwrap() = "off".into();
    let (out, used) = rt.block_on(tr.translate_many_reporting(&["Hello world".into(), "Another paragraph here".into()]));
    assert_eq!(out, ["Hello world", "Another paragraph here"]);
    assert_eq!(used, Engine::None);
    assert_eq!(rt.block_on(tr.translate("Hello world")), "Hello world");
    // 같은 소식 묶기용 영어 번역도 보내지 않음
    assert_eq!(rt.block_on(tr.to_english(&["삼성전자 새 칩 공개".into()])), [None]);
    // 방식이 바뀌면 캐시를 비운다(다른 방식의 번역이 섞이지 않게)
    assert_eq!(tr.cache_len(), 0);
    // 맥에서 가져온 apple 도 보내지 않음
    *mode.lock().unwrap() = "apple".into();
    let (_, used) = rt.block_on(tr.translate_many_reporting(&["Hello world".into()]));
    assert_eq!(used, Engine::None);
}

#[test]
fn setting_key_and_old_files() {
    // 예전 파일(키 없음) → 자동, 모르는 값 → 자동, 저장 키 이름은 translateEngine
    let old: Settings = serde_json::from_str(r#"{"intervalMinutes":5}"#).unwrap();
    assert_eq!(old.translate_engine, "auto");
    let odd: Settings = serde_json::from_str(r#"{"translateEngine":"deepl"}"#).unwrap();
    assert_eq!(odd.translate_engine, "auto");
    let mut s = Settings::default();
    s.translate_engine = "off".into();
    let j = serde_json::to_value(&s).unwrap();
    assert_eq!(j["translateEngine"], "off");
    let back: Settings = serde_json::from_value(j).unwrap();
    assert_eq!(back.translate_engine, "off");
    // 가져온 기록의 이상한 값도 묶임(clamp)
    let mut st = AppState::default();
    st.settings.translate_engine = "x".into();
    st.settings.clamp();
    assert_eq!(st.settings.translate_engine, "auto");
}

#[test]
fn settings_options_and_privacy_note() {
    let o: Vec<&str> = translator::engine_options("auto").into_iter().map(|(m, _)| m).collect();
    assert_eq!(o, ["auto", "google", "off"]);
    let o: Vec<&str> = translator::engine_options("apple").into_iter().map(|(m, _)| m).collect();
    assert_eq!(o, ["auto", "apple", "google", "off"]);
    assert!(translator::engine_note("auto").contains("Google 번역으로 본문 문단이 전송됩니다"));
    assert!(translator::engine_note("google").contains("Google 번역으로 본문 문단이 전송됩니다"));
    assert!(translator::engine_note("off").contains("아무것도 보내지 않고"));
}

#[test]
fn response_size_is_capped() {
    assert!(translator::TRANSLATE_MAX_BODY <= 2 << 20);
    assert!(translator::TRANSLATE_MAX_BODY < dropcap_core::net::MAX_BODY);
}

// 앱 전체: 설정에서 '번역 안 함'을 고르면 공유 번역기(배경 제목 번역·읽기 창·영어 제목)가 바로 따른다
#[test]
fn app_setting_drives_shared_translator() {
    let rt = tokio::runtime::Runtime::new().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let core = AppModel::new(Store::new(dir.path().to_path_buf()), rt.handle().clone());
    let tr = &*translator::SHARED;
    assert_eq!(tr.mode(), "auto");
    core.update(|s| s.translate_engine = "off".into());
    assert_eq!(tr.mode(), "off");
    let (out, used) = rt.block_on(tr.translate_many_reporting(&["Breaking: new chip unveiled".into()]));
    assert_eq!((out[0].as_str(), used), ("Breaking: new chip unveiled", Engine::None));
    let mut items = vec![NewsItem::new("1", "삼성전자 새 칩 공개", "https://kr.example/1", "kr", "kr", "kr")];
    rt.block_on(add_english_titles(&mut items));
    assert!(items[0].title_en.is_none());
    // 상태 파일에도 남음
    let saved = std::fs::read_to_string(dir.path().join("native-state.json")).unwrap_or_default();
    assert!(saved.contains("\"translateEngine\":\"off\"") || saved.contains("\"translateEngine\": \"off\""), "{saved}");
}
