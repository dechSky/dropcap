// 화면 문구 중 '무엇에 대한 앱인가'가 드러나는 것은 여기에만 둔다(추가 지시 2).
// 맥이 일반 뉴스 쪽 문구로 먼저 바꿨으므로 그에 맞춘다(상단바 창 머리는 "Dropcap", 매거진 머리는 "매거진").
pub const NEWS: &str = "새 소식"; // "새 소식 N건 더" 등
pub const MAGAZINE: &str = "매거진"; // 매거진 머리
#[allow(dead_code)] // 매거진 화면에서 씀(지금은 쓰지 않는 것도 남겨 둠)
pub const APP_COMMENT: &str = "공신력 있는 소식을 모아 알려 주고 매거진으로 엮어 줍니다";
pub const PREVIEW_TITLE_KO: &str = dropcap_core::texts::PREVIEW_TITLE_KO;

// "새 소식 3건 더"
pub fn more(n: usize) -> String {
    format!("{NEWS} {n}건 더")
}
