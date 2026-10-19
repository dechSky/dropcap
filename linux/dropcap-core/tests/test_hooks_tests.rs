// 시험 훅(DROPCAP_TEST_*)은 개발 빌드(debug)나 test-hooks 기능을 켠 빌드에서만 듣는다.
// `cargo test --release -p dropcap-core --test test_hooks_tests` 로 배포 빌드 쪽을 확인한다.
use chrono::{TimeZone, Utc};
use dropcap_core::magazine::is_sunday_evening;

#[test]
fn test_hooks_only_in_dev_builds() {
    let monday_noon = Utc.with_ymd_and_hms(2026, 10, 12, 3, 0, 0).unwrap(); // 일요일 저녁이 아님
    std::env::set_var("DROPCAP_TEST_WEEKLY", "1");
    let hooks = cfg!(debug_assertions) || cfg!(feature = "test-hooks");
    assert_eq!(is_sunday_evening(&monday_noon), hooks, "배포 빌드에서는 시험 훅이 꺼져 있어야 함");
}
