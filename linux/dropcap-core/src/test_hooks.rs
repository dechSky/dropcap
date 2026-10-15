// 시험 훅(DROPCAP_TEST_* · DROPCAP_SECTIONS · DROPCAP_CATEGORIES): 개발 빌드(debug)나 test-hooks 기능을 켠 빌드에서만 읽는다(보안 점검 L8).
// 배포 빌드(cargo build --release --features linux)에서는 환경 변수가 있어도 꺼져 있다.
pub const ENABLED: bool = cfg!(any(debug_assertions, feature = "test-hooks"));

#[inline(always)]
pub fn var(k: &str) -> Option<String> {
    if ENABLED {
        std::env::var(k).ok()
    } else {
        None
    }
}
