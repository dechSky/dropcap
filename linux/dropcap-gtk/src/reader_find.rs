// 기사 안 찾기(Ctrl+F, 맥 Reader/ReaderFind.swift): 지금 보이는 글(번역이든 원문이든)에서 대소문자·악센트 구별 없이 찾고,
// Ctrl+G / Shift+Ctrl+G 로 오간다. 일치한 곳은 노랗게, 지금 고른 곳은 주황으로 칠한다(reader_view.update_find).
// 찾는 셈은 화면 없는 쪽(dropcap_core::reader_find)에 두고 시험한다(tests/reader_catchup_tests.rs).
pub use dropcap_core::reader_find::*;
