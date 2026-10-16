// 번역 2단계(mac/TRANSLATE.md, 맥 TranslatePhase2Tests 와 같은 꼴): 네트워크 없이 — Google 부르기를 가짜로 바꿔 끼운다.
// 리눅스에는 기기 내 엔진이 없어 흘려 주기·기기 내 사례는 해당 없음(auto = Google, apple = 보내지 않음 — translate_off_tests).
use dropcap_core::translator::{self, looks_foreign, polish, restore_names, Engine, GoogleCall, Translator};
use futures::FutureExt;
use std::sync::{Arc, Mutex};

// 묶음(빈 줄로 이은 글)을 문단마다 "번역: " 을 붙여 돌려주는 Google. shift 면 문단 수는 같고 한 칸 밀림
fn fake(calls: Arc<Mutex<Vec<String>>>, shift: bool) -> GoogleCall {
    Arc::new(move |text: String, _target: String| {
        calls.lock().unwrap().push(text.clone());
        let mut parts: Vec<String> = text.split("\n\n").map(|p| format!("번역: {p}")).collect();
        if shift && parts.len() > 1 {
            parts.rotate_left(1);
        }
        async move { Some(parts.join("\n\n")) }.boxed()
    })
}

fn rt() -> tokio::runtime::Runtime {
    tokio::runtime::Runtime::new().unwrap()
}

// 케이스 8 — 글자 없는·주소만 블록
#[test]
fn no_letter_or_url_only_is_not_foreign() {
    assert!(!looks_foreign("16"));
    assert!(!looks_foreign("01 /"));
    assert!(!looks_foreign("|"));
    assert!(!looks_foreign("https://blogs.example.com/wp-content/uploads/2026/10/demo_4k.mp4"));
    assert!(!looks_foreign("  www.example.com/a  "));
    assert!(looks_foreign("GPT-5"));
    assert!(looks_foreign("See https://example.com for details"));
    assert!(looks_foreign("OpenAI releases a new model"));
}

#[test]
fn no_letter_blocks_are_not_sent() {
    let calls = Arc::new(Mutex::new(vec![]));
    let t = Translator::with_google(|| "google".into(), fake(calls.clone(), false));
    let src: Vec<String> = ["2026", "https://example.com/video.mp4", "Hello world"].map(String::from).to_vec();
    let (out, engine) = rt().block_on(t.translate_many_reporting(&src));
    assert_eq!(out, ["2026", "https://example.com/video.mp4", "번역: Hello world"]);
    assert_eq!(engine, Engine::Google);
    assert_eq!(*calls.lock().unwrap(), ["Hello world"]);
}

// 케이스 3 — 제목 끝 마침표
#[test]
fn title_period_dropped() {
    assert_eq!(polish("Sophos cuts threat investigation time by 96%", "Sophos는 위협 조사 시간을 96% 단축했습니다."), "Sophos는 위협 조사 시간을 96% 단축했습니다");
    assert_eq!(polish("It works.", "작동합니다."), "작동합니다.");
    assert_eq!(polish("Wait for it", "기다려..."), "기다려...");
    assert_eq!(polish("Is it real?", "진짜입니까?"), "진짜입니까?");
}

// 케이스 2 — 이름 되돌림
#[test]
fn names_restored_only_when_in_source() {
    assert_eq!(restore_names("Introducing Claude Corps", "클로드 군단을 소개합니다"), "Claude Corps을 소개합니다");
    assert_eq!(restore_names("how people actually use Claude in these contexts", "실제로 클도를 어떻게 사용하는지"), "실제로 Claude를 어떻게 사용하는지");
    assert_eq!(restore_names("Claude Opus 5.5 scored 99%", "클로드 Opus 5.5는 99%를 받았다"), "Claude Opus 5.5는 99%를 받았다");
    // 원문에 영문 이름이 없으면 건드리지 않는다
    assert_eq!(restore_names("The painter loved water lilies", "클로드는 수련을 좋아했다"), "클로드는 수련을 좋아했다");
    // 사람 이름(Claude 뒤에 제품 낱말이 아닌 대문자 낱말)이면 건드리지 않는다
    assert_eq!(restore_names("Claude Monet painted it", "클로드 모네가 그렸다"), "클로드 모네가 그렸다");
    assert_eq!(restore_names("Copilot now writes tests", "부조종사가 이제 시험을 작성합니다"), "Copilot가 이제 시험을 작성합니다");
    // 낱말 안에 든 것은 아님(예: Claudette)
    assert_eq!(restore_names("Claudette said", "클로드가 말했다"), "클로드가 말했다");
}

// 케이스 10 — 묶음 대조
#[test]
fn shift_detection() {
    let s = |v: &[&str]| v.iter().map(|x| x.to_string()).collect::<Vec<_>>();
    let src = s(&["Claude uses 250,000 conversations", "Democracy Works runs TurboVote", "NASA names a deputy in 2023"]);
    let ok = s(&["Claude는 25만 건의 대화를 씁니다", "Democracy Works는 TurboVote를 운영합니다", "NASA는 2023년 부국장을 임명합니다"]);
    assert!(!translator::looks_shifted(&src, &ok));
    let shifted = vec![ok[1].clone(), ok[2].clone(), ok[0].clone()];
    assert!(translator::looks_shifted(&src, &shifted));
    // 숫자를 한국식으로 바꾸거나 영문 낱말이 없는 문단은 밀림으로 보지 않는다
    assert!(!translator::looks_shifted(&s(&["It cost $150 million", "Nothing to anchor here"]), &s(&["1억 5천만 달러가 들었다", "여기엔 기준이 없다"])));
}

#[test]
fn shifted_batch_retried_per_paragraph() {
    let calls = Arc::new(Mutex::new(vec![]));
    let t = Translator::with_google(|| "google".into(), fake(calls.clone(), true));
    let src: Vec<String> = ["Alpha news from OpenAI", "Beta update from NVIDIA", "Gamma report by NASA"].map(String::from).to_vec();
    let (out, _) = rt().block_on(t.translate_many_reporting(&src));
    assert_eq!(out, src.iter().map(|x| format!("번역: {x}")).collect::<Vec<_>>()); // 문단별로 다시 받아 제자리
    assert_eq!(calls.lock().unwrap().len(), 1 + src.len());
}

// 번역 결과는 다듬어서 캐시에 남긴다(이름·마침표)
#[test]
fn results_polished() {
    let call: GoogleCall = Arc::new(|_t: String, _g: String| async { Some("클로드 코드 출시.".to_string()) }.boxed());
    let t = Translator::with_google(|| "auto".into(), call);
    assert_eq!(rt().block_on(t.translate("Claude Code launches")), "Claude Code 출시");
}

// 케이스 11 — 방식이 바뀌면 캐시 비움, 번역 안 함이면 부르지 않음
#[test]
fn mode_change_clears_cache_and_off_sends_nothing() {
    let calls = Arc::new(Mutex::new(vec![]));
    let mode = Arc::new(Mutex::new("google".to_string()));
    let m = mode.clone();
    let t = Translator::with_google(move || m.lock().unwrap().clone(), fake(calls.clone(), false));
    let r = rt();
    assert_eq!(r.block_on(t.translate_many(&["Hello world".into()])), ["번역: Hello world"]);
    assert_eq!(r.block_on(t.translate_many(&["Hello world".into()])), ["번역: Hello world"]); // 캐시
    assert_eq!(calls.lock().unwrap().len(), 1);
    *mode.lock().unwrap() = "off".into();
    assert_eq!(r.block_on(t.translate_many_reporting(&["Hello world".into()])), (vec!["Hello world".to_string()], Engine::None));
    assert_eq!(r.block_on(t.to_english(&["안녕하세요".into()])), [None]);
    assert_eq!(t.cache_len(), 0);
    assert_eq!(calls.lock().unwrap().len(), 1);
}
