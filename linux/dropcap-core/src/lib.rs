//! Dropcap 리눅스 판의 화면 없는 핵심: 수집·안전·번역·저장·매거진. 맥 앱(mac/Sources/Dropcap/Core)과 같은 동작.
pub mod category;
pub mod channels;
pub mod database;
pub mod feed_parser;
pub mod feed_service;
pub mod iso;
pub mod magazine;
pub mod models;
pub mod net;
pub mod scrapbook;
pub mod store;
pub mod story_match;
pub mod summarizer;
pub mod translator;
pub mod url_safety;
pub mod app_model;
pub mod archive; // 지난 기사 보관함(맥 Archive)
pub mod article;
pub mod images;
pub mod system;
pub mod texts;
pub mod guard_proxy;
pub mod notify_policy;
pub mod sections;
pub mod source_health;
pub mod paywall;
pub mod photo_quality;
pub mod focus_guard;
pub mod today_issue;
pub mod brief;
pub mod watch_words;
pub mod backup;
pub mod source_filter;
pub mod source_directory; // 설정 › 구독 찾기·묶음(맥 SourceDirectory)
pub mod reader_find;
pub mod reader_extract;
pub mod cover_pick;
pub mod image_text;
// 바깥과 잇기(I-02~I-06): 아무 주소 저장 · dropcap:// 주소·명령줄 · 데스크톱 검색 · 스크랩 노트 폴더
pub mod save_link;
pub mod url_router;
pub mod search_index;
pub mod scrap_export;
pub mod test_hooks;
pub mod byte_cache;
