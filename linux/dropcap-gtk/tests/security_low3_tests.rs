// 보안 점검 낮음 — 맥 SecurityLow3Tests · 윈도우 SecurityLow3Tests 와 같은 규칙.
// 여러 덩어리 모으기의 상자를 살아 있는 문서(document)에 만들면 붙인 <img> 가 받기·onerror 를 돌릴 수 있다(내용 차단 규칙이 막지만 한 겹 더).
// 추출 스크립트(reader_webkit.rs SCRIPT)는 사본(doc·fresh)·DOMParser 문서에서만 노드를 만든다.
const SRC: &str = include_str!("../src/reader_webkit.rs");

#[test]
fn extract_script_builds_only_in_inert_documents() {
    let start = SRC.find("const SCRIPT: &str = r#\"").expect("SCRIPT");
    let js = &SRC[start..start + SRC[start..].find("\"#;").expect("SCRIPT 끝")];
    for live in ["document.createElement", "document.importNode", "document.adoptNode", "document.body.append", "document.write"] {
        assert!(!js.contains(live), "{live}");
    }
    assert!(js.contains("fresh.createElement('div')"));
}
