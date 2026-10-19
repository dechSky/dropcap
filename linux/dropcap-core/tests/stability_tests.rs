// 오래 켜 두기·멈춤·실패 처리(맥~S8 · Tests/DropcapTests/StabilityTests.swift 를 옮긴 것).
// 모두 임시 폴더·견본 기사로 돌고 바깥 요청을 하지 않는다. (S2 의 느린 서버 시험은 net.rs 안 단위 시험)
use chrono::{Duration, Utc};
use dropcap_core::app_model::{self, AppModel};
use dropcap_core::byte_cache::{cover_size, ByteLru};
use dropcap_core::database::{Cluster, Database};
use dropcap_core::magazine;
use dropcap_core::models::NewsItem;
use dropcap_core::net::FeedError;
use dropcap_core::store::Store;
use dropcap_core::translator::{GoogleCall, GoogleStatusCall, Translator};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Instant;

fn article(src: &str, id: &str, title: &str) -> NewsItem {
    // 주소를 비워 사진 찾기(og:image)가 바깥으로 나가지 않게
    let mut it = NewsItem::new(id, title, "", src, src, "press");
    it.date = Some(Utc::now());
    it
}

// S1: 사진 메모리 캐시는 장 수가 아니라 바이트로 묶는다(최근 사용 순) — 맥 imageMemoryCacheIsBoundedInBytes
#[test]
fn image_memory_cache_is_bounded_in_bytes() {
    let mb = 1 << 20;
    let mut c: ByteLru<u32> = ByteLru::new(64 * mb);
    for i in 0..200u32 {
        c.insert(&format!("u{i}"), i, 5 * mb); // 1400px 사진 한 장 ≈ 5MB(풀린 RGBA)
        assert!(c.bytes() <= 64 * mb, "{}장째에 {}MB", i + 1, c.bytes() / mb);
    }
    assert!(c.len() <= 12);
    // 최근에 쓴 것은 남고 오래 안 쓴 것부터 빠진다
    let mut c: ByteLru<u32> = ByteLru::new(10 * mb);
    c.insert("a", 1, 4 * mb);
    c.insert("b", 2, 4 * mb);
    assert_eq!(c.get("a"), Some(1)); // a 를 다시 씀
    c.insert("c", 3, 4 * mb); // 넘침 → 가장 오래 안 쓴 b 가 빠짐
    assert_eq!(c.get("b"), None);
    assert_eq!(c.get("a"), Some(1));
    assert_eq!(c.get("c"), Some(3));
    // 같은 주소를 다시 넣으면 크기를 바꿔 센다
    c.insert("c", 4, 1 * mb);
    assert_eq!(c.bytes(), 5 * mb);
}

// S1: 카드 사진은 그릴 칸(화면 배율 포함) 크기로 줄여 둔다 — 카드마다 원본 크기 Cairo 표면 사본을 두지 않게
#[test]
fn card_surface_is_scaled_to_the_box() {
    assert_eq!(cover_size(1400, 933, 240, 160), (240, 160)); // 꽉 차게(cover): 짧은 쪽이 칸에 맞음
    assert_eq!(cover_size(1400, 700, 160, 160), (320, 160));
    assert_eq!(cover_size(100, 80, 240, 160), (100, 80)); // 작은 사진은 키우지 않음
}

// S2: 확인 한 번은 출처 하나가 끝나지 않아도 상한에서 끝난다(나머지 출처 결과는 그대로)
#[tokio::test]
async fn check_is_bounded_when_one_source_hangs() {
    use futures::future::BoxFuture;
    let jobs: Vec<BoxFuture<'static, Result<u32, FeedError>>> = vec![
        Box::pin(async { Ok(1) }),
        Box::pin(async {
            futures::future::pending::<()>().await;
            Ok(2)
        }),
        Box::pin(async { Err(FeedError::Http(503)) }),
    ];
    let started = Instant::now();
    let out = tokio::time::timeout(std::time::Duration::from_secs(5), app_model::gather_within(jobs, std::time::Duration::from_millis(300)))
        .await
        .expect("확인이 멈춤(전체 상한 없음)");
    assert!(started.elapsed() < std::time::Duration::from_secs(2));
    assert_eq!(out[0], Ok(1));
    assert!(matches!(out[1], Err(FeedError::Net(_))), "{:?}", out[1]);
    assert_eq!(out[2], Err(FeedError::Http(503)));
}

fn silent_google(calls: Arc<AtomicUsize>) -> GoogleCall {
    Arc::new(move |_t, _l| {
        calls.fetch_add(1, Ordering::SeqCst);
        Box::pin(async {
            futures::future::pending::<()>().await;
            None
        })
    })
}

// S3: 응답 없는 번역 서버 — 상한에서 원문 그대로(맥 silentTranslateServerFallsBackToOriginal)
#[tokio::test]
async fn silent_translate_server_falls_back_to_original() {
    let calls = Arc::new(AtomicUsize::new(0));
    let tr = Translator::with_google_deadline(|| "auto".into(), silent_google(calls.clone()), std::time::Duration::from_millis(200));
    let texts = vec!["OpenAI ships a new model".to_string()];
    let out = tokio::time::timeout(std::time::Duration::from_secs(5), tr.translate_many(&texts)).await.expect("번역이 멈춤");
    assert_eq!(out, texts);
}

// S3: 묶음이 상한에 걸리면 문단마다 다시 보내며 상한을 곱으로 기다리지 않고, 1분 동안은 부르지 않는다(맥 silentServerDoesNotMultiplyWaits)
#[tokio::test]
async fn silent_server_does_not_multiply_waits() {
    let calls = Arc::new(AtomicUsize::new(0));
    let tr = Translator::with_google_deadline(|| "auto".into(), silent_google(calls.clone()), std::time::Duration::from_millis(200));
    let texts: Vec<String> = (0..20).map(|i| format!("Paragraph number {i} about language models and chips")).collect();
    let started = Instant::now();
    let out = tokio::time::timeout(std::time::Duration::from_secs(10), tr.translate_many(&texts)).await.expect("번역이 멈춤");
    assert_eq!(out, texts);
    assert!(started.elapsed() < std::time::Duration::from_millis(1500), "상한을 여러 번 기다림: {:?}", started.elapsed());
    assert_eq!(calls.load(Ordering::SeqCst), 1, "상한에 걸린 뒤에는 쉬어야 함");
    // 쉬는 동안의 다른 번역(영어 제목 포함)도 바로 원문
    let more = vec!["Another headline here".to_string()];
    assert_eq!(tr.translate_many(&more).await, more);
    assert_eq!(tr.to_english(&["한국어 제목".to_string()]).await, vec![None]);
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}

// S4: 시계가 앞서 있을 때 켠 잠시 끄기(이틀보다 먼 끝)는 풀린 것으로, 1분 점검이 지운다(맥 snoozeFromFutureClockIsReleased)
#[test]
fn snooze_from_future_clock_is_released() {
    let now = Utc::now();
    assert!(app_model::snooze_active(Some(now + Duration::hours(1)), now));
    assert!(app_model::snooze_active(Some(now + Duration::hours(32)), now)); // '내일 아침 8시'
    assert!(!app_model::snooze_active(Some(now + Duration::days(10)), now));
    assert!(!app_model::snooze_active(Some(now - Duration::minutes(1)), now));
    assert!(!app_model::snooze_active(None, now));

    let rt = tokio::runtime::Runtime::new().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let core = AppModel::new(Store::new(dir.path().to_path_buf()), rt.handle().clone());
    core.snooze(Some(now + Duration::days(10)));
    assert!(!core.is_snoozed());
    core.minute_tick(now);
    assert!(core.state().snooze_until.is_none());
    core.snooze(Some(now + Duration::hours(1)));
    assert!(core.is_snoozed());
    core.minute_tick(now);
    assert!(core.state().snooze_until.is_some());
}

// S5: 스토리 목록 전체를 문장 두 번으로(스토리마다 묻지 않음), 카드에 보도를 넘긴다(맥 storyListAsksDatabaseOnce)
#[test]
fn story_list_asks_database_once() {
    let db = Database::in_memory();
    let now = Utc::now();
    for i in 0..300 {
        let id = format!("c{i}");
        db.save_cluster(&Cluster { id: id.clone(), title: format!("Story {i}"), tokens: Default::default(), first: now, last: now, size: 2 });
        db.upsert(&article("srcA", &format!("a{i}"), &format!("Story {i} a")), Some(&id), now);
        db.upsert(&article("srcB", &format!("b{i}"), &format!("Story {i} b")), Some(&id), now);
    }
    let before = db.statements();
    let (live, past) = magazine::story_cards(&db, now, &Default::default());
    let asked = db.statements() - before;
    assert_eq!(live.len() + past.len(), 300);
    assert!(live.iter().all(|c| c.items.len() == 2 && c.cluster.size == 2));
    assert_eq!(asked, 2, "스토리 300개에 문장 {asked}번");
    // 예전 함수(스토리 화면 밖에서 쓰는 것)도 같은 결과
    assert_eq!(magazine::stories(&db, &Default::default()).len(), 300);
}

fn titles(n: usize, tag: &str) -> Vec<NewsItem> {
    let words = ["Quasar", "Nimbus", "Zephyr", "Orchid", "Basalt", "Cobalt", "Juniper", "Marlin", "Tundra", "Saffron"];
    (0..n).map(|i| article("srcA", &format!("{tag}{i}"), &format!("{} {} unveils {}", words[i % 10], tag, words[(i * 3 + 1) % 10]))).collect()
}

// S7: DB 가 잠겨 못 넣은 글은 잃지 않고 다음 받아 넣기에 먼저 넣는다. 한 번 실패하면 나머지는 기다리지 않고 바로 미룬다(맥 failedIngestIsRetried)
#[test]
fn failed_ingest_is_retried() {
    let dir = tempfile::tempdir().unwrap();
    let db = Database::open_with_busy(dir.path(), 100);
    let locker = rusqlite::Connection::open(dir.path().join("magazine.sqlite")).unwrap();
    locker.execute_batch("BEGIN IMMEDIATE; INSERT INTO teasers(link,updated) VALUES('lock',1);").unwrap();
    let items = titles(8, "x");
    let mut retry = vec![];
    let started = Instant::now();
    magazine::ingest_retrying(&db, &mut retry, &items, &[]);
    assert!(started.elapsed() < std::time::Duration::from_millis(1500), "글마다 잠금을 기다림: {:?}", started.elapsed());
    assert_eq!(db.item_count(), 0);
    assert_eq!(retry.len(), 8, "못 넣은 글은 다시 넣을 목록에");
    locker.execute_batch("COMMIT").unwrap();
    // 다음 받아 넣기(새 글 없음)에서 먼저 넣는다
    magazine::ingest_retrying(&db, &mut retry, &[], &[]);
    assert_eq!(db.item_count(), 8);
    assert!(retry.is_empty());
    // 스토리 크기를 두 번 세지 않음
    let sizes: i64 = db.recent_clusters(Utc::now() - Duration::days(1)).iter().map(|c| c.size).sum();
    assert_eq!(sizes, 8);
}

// S7: 다시 넣을 목록은 끝없이 쌓이지 않는다(오래된 것부터 버림)
#[test]
fn retry_list_is_capped() {
    let dir = tempfile::tempdir().unwrap();
    let db = Database::open_with_busy(dir.path(), 10);
    let locker = rusqlite::Connection::open(dir.path().join("magazine.sqlite")).unwrap();
    locker.execute_batch("BEGIN IMMEDIATE; INSERT INTO teasers(link,updated) VALUES('lock',1);").unwrap();
    let mut retry = titles(magazine::RETRY_LIMIT, "old");
    magazine::ingest_retrying(&db, &mut retry, &titles(5, "new"), &[]);
    assert_eq!(retry.len(), magazine::RETRY_LIMIT);
    assert_eq!(retry.last().unwrap().id, "new4");
    locker.execute_batch("COMMIT").unwrap();
}

// 다시 넣을 기사 파일이 상한보다 크면 읽지 않는다(앱이 쓴 파일이 아님)
#[test]
fn oversized_retry_file_is_ignored() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join(magazine::RETRY_FILE);
    let mut data = serde_json::to_vec(&titles(1, "big")).unwrap();
    data.resize(magazine::RETRY_FILE_MAX as usize + 1, b' '); // 뒤 공백 — JSON 으로는 맞다
    std::fs::write(&file, &data).unwrap();
    assert!(magazine::load_retry(&file).is_empty());
    std::fs::write(&file, serde_json::to_vec(&titles(1, "small")).unwrap()).unwrap();
    assert_eq!(magazine::load_retry(&file).len(), 1);
}

// S7: 잠깐(0.3초) 잠긴 것은 기다렸다가 넣는다(맥 shortLockIsWaitedOut)
#[test]
fn short_lock_is_waited_out() {
    let dir = tempfile::tempdir().unwrap();
    let db = Database::open(dir.path());
    let path = dir.path().join("magazine.sqlite");
    let (tx, rx) = std::sync::mpsc::channel();
    let t = std::thread::spawn(move || {
        let locker = rusqlite::Connection::open(path).unwrap();
        locker.execute_batch("BEGIN IMMEDIATE; INSERT INTO teasers(link,updated) VALUES('lock',1);").unwrap();
        tx.send(()).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(300));
        locker.execute_batch("COMMIT").unwrap();
    });
    rx.recv().unwrap();
    let mut retry = vec![];
    magazine::ingest_retrying(&db, &mut retry, &titles(3, "y"), &[]);
    t.join().unwrap();
    assert_eq!(db.item_count(), 3);
    assert!(retry.is_empty());
}

// S7: 앱 핵심 — 확인에서 받은 글이 DB 잠김으로 빠져도 다음 받아 넣기에서 매거진에 들어간다
#[test]
fn app_ingest_retries_after_lock() {
    let rt = tokio::runtime::Runtime::new().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let core = AppModel::new(Store::new(dir.path().to_path_buf()), rt.handle().clone());
    let locker = rusqlite::Connection::open(dir.path().join("magazine.sqlite")).unwrap();
    locker.busy_timeout(std::time::Duration::from_secs(5)).unwrap();
    locker.execute_batch("BEGIN IMMEDIATE; INSERT INTO teasers(link,updated) VALUES('lock',1);").unwrap();
    core.ingest(&titles(4, "z"));
    let in_db = core.db.item_count();
    locker.execute_batch("COMMIT").unwrap();
    assert_eq!(in_db, 0);
    core.ingest(&[]);
    assert_eq!(core.db.item_count(), 4);
}

// S8: 분야 사진 고르기 — 최근 기사를 분야마다 따로 읽지 않고 한 번 읽어 나눈다
#[test]
fn section_photos_read_recent_once() {
    let db = Database::in_memory();
    let now = Utc::now();
    for (i, it) in titles(30, "s").into_iter().enumerate() {
        db.upsert(&it, None, now - Duration::minutes(i as i64));
    }
    let ids: Vec<String> = dropcap_core::sections::ALL.iter().map(|s| s.id.clone()).collect();
    assert!(ids.len() > 3);
    let before = db.statements();
    let by = magazine::section_recent(&db, &ids, now - Duration::days(3));
    assert_eq!(db.statements() - before, 1, "분야 {}개에 문장 {}번", ids.len(), db.statements() - before);
    // 결과는 분야마다 읽은 것과 같음
    let all: Vec<NewsItem> = db.items(now - Duration::days(3), None, 3000).into_iter().map(|s| s.item).collect();
    for id in &ids {
        let want: Vec<String> = all.iter().filter(|i| i.in_section(id)).map(|i| i.key()).collect();
        let got: Vec<String> = by.get(id).map(|v| v.iter().map(|i| i.key()).collect()).unwrap_or_default();
        assert_eq!(got, want, "{id}");
    }
}

// storySeen: DB 에서 지운 스토리의 '본 보도 수'는 상태에서도 지운다(맥 '남은 것' 4)
#[test]
fn story_seen_drops_deleted_stories() {
    let rt = tokio::runtime::Runtime::new().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let core = AppModel::new(Store::new(dir.path().to_path_buf()), rt.handle().clone());
    let now = Utc::now();
    core.db.save_cluster(&Cluster { id: "keep".into(), title: "Keep".into(), tokens: Default::default(), first: now, last: now, size: 1 });
    core.db.upsert(&article("srcA", "k1", "Keep story"), Some("keep"), now);
    core.mark_story_seen("keep", 1);
    core.mark_story_seen("gone", 3); // DB 에서 정리된 스토리
    core.ingest(&titles(1, "w"));
    let seen = core.state().story_seen;
    assert!(seen.contains_key("keep"));
    assert!(!seen.contains_key("gone"), "{seen:?}");
    // 저장 파일에도
    let saved = Store::new(dir.path().to_path_buf()).load().story_seen;
    assert!(!saved.contains_key("gone"));
}

// S7(맥 Fix4): 못 넣은 글은 앱을 껐다 켜도 남는다 — 자료 폴더 ingest-retry.json, 다음 실행에서 먼저 넣고 비면 파일을 지운다
#[test]
fn retry_outlives_restart() {
    let rt = tokio::runtime::Runtime::new().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("ingest-retry.json");
    {
        let core = AppModel::new(Store::new(dir.path().to_path_buf()), rt.handle().clone());
        let locker = rusqlite::Connection::open(dir.path().join("magazine.sqlite")).unwrap();
        locker.busy_timeout(std::time::Duration::from_secs(5)).unwrap();
        locker.execute_batch("BEGIN IMMEDIATE; INSERT INTO teasers(link,updated) VALUES('lock',1);").unwrap();
        core.ingest(&titles(4, "r"));
        locker.execute_batch("ROLLBACK").unwrap();
        assert_eq!(core.db.item_count(), 0);
        assert!(file.exists(), "못 넣은 글을 파일에 남겨야 함");
        let saved: Vec<NewsItem> = serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
        assert_eq!(saved.len(), 4);
    }
    // 다시 켬(같은 자료 폴더): 새 글이 없어도 남은 글을 먼저 넣는다
    let core = AppModel::new(Store::new(dir.path().to_path_buf()), rt.handle().clone());
    core.ingest(&[]);
    assert_eq!(core.db.item_count(), 4);
    assert!(!file.exists(), "다 넣었으면 파일을 지움");
    // 깨진 파일은 빈 것으로
    std::fs::write(&file, b"{not json").unwrap();
    let core2 = AppModel::new(Store::new(dir.path().to_path_buf()), rt.handle().clone());
    core2.ingest(&[]);
    assert_eq!(core2.db.item_count(), 4);
}

// 묶음 번역은 동시에 4개까지만(맥 parallelBatches) — 업데이트 뒤 첫 채우기에서 수백 건이 한꺼번에 나가지 않게
#[tokio::test]
async fn batch_translation_sends_at_most_four_at_once() {
    let live = Arc::new(AtomicUsize::new(0));
    let peak = Arc::new(AtomicUsize::new(0));
    let call: GoogleCall = {
        let (live, peak) = (live.clone(), peak.clone());
        Arc::new(move |t, _l| {
            let (live, peak) = (live.clone(), peak.clone());
            Box::pin(async move {
                let n = live.fetch_add(1, Ordering::SeqCst) + 1;
                peak.fetch_max(n, Ordering::SeqCst);
                tokio::time::sleep(std::time::Duration::from_millis(30)).await;
                live.fetch_sub(1, Ordering::SeqCst);
                Some(t)
            })
        })
    };
    let tr = Translator::with_google(|| "auto".into(), call);
    // 한 문단이 3000자 넘어 묶음 하나씩 — 묶음 20개
    let texts: Vec<String> = (0..20).map(|i| format!("Paragraph {i} {}", "word ".repeat(700))).collect();
    assert_eq!(tr.translate_many(&texts).await.len(), 20);
    assert!(peak.load(Ordering::SeqCst) <= 4, "동시 요청 {}", peak.load(Ordering::SeqCst));
    peak.store(0, Ordering::SeqCst);
    let ko: Vec<String> = (0..20).map(|i| format!("한국어 제목 {i}")).collect();
    assert_eq!(tr.to_english(&ko).await.len(), 20);
    assert!(peak.load(Ordering::SeqCst) <= 4, "영어 제목 동시 요청 {}", peak.load(Ordering::SeqCst));
}

// 429(요청이 너무 많음)를 받으면 60초 쉰다 — 문단마다 다시 보내며 요청을 늘리지 않게
#[tokio::test]
async fn too_many_requests_rests_google() {
    let calls = Arc::new(AtomicUsize::new(0));
    let call: GoogleStatusCall = {
        let calls = calls.clone();
        Arc::new(move |_t, _l| {
            calls.fetch_add(1, Ordering::SeqCst);
            Box::pin(async { Err(429) })
        })
    };
    let tr = Translator::with_google_status(|| "auto".into(), call);
    let texts: Vec<String> = (0..20).map(|i| format!("Paragraph number {i} about language models and chips")).collect();
    assert_eq!(tr.translate_many(&texts).await, texts);
    assert!(tr.resting());
    assert_eq!(calls.load(Ordering::SeqCst), 1, "429 뒤에는 쉬어야 함");
}

// 사이트맵 글 제목 채우기는 전체 시간 상한까지만 — 넘으면 남은 글은 주소로 지은 제목으로(확인이 수십 분 묶이지 않게)
#[tokio::test]
async fn sitemap_title_fill_stops_at_deadline() {
    let items = || -> Vec<NewsItem> {
        (0..5)
            .map(|i| {
                let mut it = article("sm", &format!("s{i}"), "");
                it.link = format!("https://example.com/news/slow-page-{i}");
                it
            })
            .collect()
    };
    let started = Instant::now();
    let end = tokio::time::Instant::now() + std::time::Duration::from_millis(100);
    let out = app_model::fill_titles_until(items(), end, |it| async move {
        tokio::time::sleep(std::time::Duration::from_secs(10)).await;
        it
    })
    .await;
    assert!(started.elapsed() < std::time::Duration::from_secs(1), "상한을 넘겨 기다림: {:?}", started.elapsed());
    assert_eq!(out.len(), 5);
    assert!(out.iter().all(|i| !i.title.is_empty()), "주소로 지은 제목이 있어야 함");
    // 제때 끝나면 받은 제목 그대로
    let end = tokio::time::Instant::now() + std::time::Duration::from_secs(5);
    let out = app_model::fill_titles_until(items(), end, |mut it| async move {
        it.title = "채운 제목".into();
        it
    })
    .await;
    assert!(out.iter().all(|i| i.title == "채운 제목"));
}
