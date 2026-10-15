// 시험용 환경 변수(남은 개선 묶음 · 맥 UI/ExtrasTestHooks.swift 와 같은 이름). 실제 기록을 건드리지 않게 DROPCAP_DATA_DIR 와 함께 쓴다.
//  DROPCAP_TEST_EXTRAS=<폴더>       피드를 받은 뒤(DROPCAP_TEST_EXTRAS_WAIT 초, 기본 100) 아래를 찍는다
//    · 유료 기사 읽기 창(같은 스토리의 무료 보도 권하기) → paywall-reader.png
//    · 매거진 오늘 호(진행률) → today-progress.png, 대표 기사를 모두 읽음으로 → today-done.png
//    · 묶음 분야 저녁 정리 → brief.png (Ollama 가 없으면 '시험 견본' 문장으로 화면만 확인)
//  DROPCAP_TEST_ENABLE=<출처 id,…>  그 출처를 켜고 최근 글을 매거진에 바로 싣는다(유료 출처 확인용)
//  DROPCAP_TEST_EXTRAS2=<폴더>      내 기록 내보내기 → 같은 파일 가져오기 왕복(backup.json · 결과는 로그), 지켜볼 낱말 정리 물방울
//                                   (DROPCAP_TEST_SHOT_DIR 이 있으면 toast-*.png · settings-*.png)
//  DROPCAP_TEST_FOCUS=fullscreen|sharing|calendar|none  자동 조용히 감지 결과를 정해 둔다(핵심이 읽음)
use crate::app::{bg, ui};
use gtk::prelude::*;
use dropcap_core::brief::Line;
use dropcap_core::models::NewsItem;
use std::path::PathBuf;
use std::time::Duration;

fn env(k: &str) -> Option<String> {
    dropcap_core::test_hooks::var(k).filter(|s| !s.is_empty()) // 개발 빌드에서만(L8)
}

async fn sleep(s: u64) {
    gtk::glib::timeout_future(Duration::from_secs(s)).await;
}

pub fn run() {
    if let Some(ids) = env("DROPCAP_TEST_ENABLE") {
        let core = ui().core.clone();
        ui().rt.spawn(async move {
            tokio::time::sleep(Duration::from_secs(3)).await;
            for id in ids.split(',') {
                let Some(src) = core.source(id) else { continue };
                core.set_enabled(id, true);
                if let Ok(Some(items)) = dropcap_core::feed_service::SHARED.items(&src, false).await {
                    let cutoff = chrono::Utc::now() - chrono::Duration::days(3);
                    let recent: Vec<NewsItem> = items.into_iter().filter(|i| i.date_or_past() > cutoff).take(25).collect();
                    log::info!("[시험] {id} {}건 실음", recent.len());
                    core.ingest(&recent.into_iter().rev().collect::<Vec<_>>());
                }
            }
        });
    }
    if let Some(d) = env("DROPCAP_TEST_EXTRAS2").map(PathBuf::from) {
        gtk::glib::spawn_future_local(extras2(d));
    }
    if let Some(d) = env("DROPCAP_TEST_KEYNAV").map(PathBuf::from) {
        gtk::glib::spawn_future_local(keynav(d));
    }
    let Some(dir) = env("DROPCAP_TEST_EXTRAS").map(PathBuf::from) else { return };
    let _ = std::fs::create_dir_all(&dir);
    if ui().core.needs_onboarding() {
        let ids: Vec<String> = ["top", "economy", "politics", "world", "tech"].iter().map(|s| s.to_string()).collect();
        ui().core.choose_sections(&ids);
    }
    let wait: u64 = env("DROPCAP_TEST_EXTRAS_WAIT").and_then(|s| s.parse().ok()).unwrap_or(100);
    gtk::glib::spawn_future_local(async move {
        sleep(wait).await;
        paywall_reader(&dir).await;
        sleep(4).await;
        today(&dir).await;
        brief(&dir).await;
        log::info!("[시험] 남은 개선 묶음 찍기 끝");
    });
}

// 내 기록 왕복 · 지켜볼 낱말 정리 물방울(P-08 · N-27)
async fn extras2(dir: PathBuf) {
    let _ = std::fs::create_dir_all(&dir);
    sleep(4).await;
    let file = dir.join("backup.json");
    log::info!("[시험] {}", crate::backup_ui::export(&file));
    log::info!("[시험] {}", crate::backup_ui::import(&file));
    log::info!("[시험] 되돌리기 파일 {:?}", crate::backup_ui::undo_file().map(|p| p.file_name().map(|n| n.to_string_lossy().to_string())));
    log::info!("[시험] {}", crate::backup_ui::undo());
    // 지켜볼 낱말 정리: 기록에 있는 소식 제목의 첫 낱말로 견본
    let core = ui().core.clone();
    let recent: Vec<NewsItem> = core.db.items(chrono::Utc::now() - chrono::Duration::days(3), None, 500).into_iter().map(|s| s.item).collect();
    let word = recent.iter().find_map(|i| i.display_title().split_whitespace().find(|w| w.chars().count() >= 3).map(|w| w.to_string())).unwrap_or_else(|| "엔비디아".into());
    let items: Vec<NewsItem> = dropcap_core::watch_words::digest(&recent, std::slice::from_ref(&word)).into_iter().next().map(|d| d.1).unwrap_or_default();
    log::info!("[시험] 지켜볼 낱말 '{word}' {}건", items.len());
    crate::toast::show_watch(&word, items, false);
    crate::settings::open(None);
}

// 키보드 탐색(H-03·H-04): 상단바 목록에서 ↓ 세 번, 매거진 카드에서 ↓ 네 번, 지면 넘기기 → 찍기
async fn keynav(dir: PathBuf) {
    use crate::keynav::NavKey;
    let _ = std::fs::create_dir_all(&dir);
    sleep(8).await;
    crate::menu::open();
    sleep(2).await;
    let mut w = None;
    for _ in 0..3 {
        w = crate::menu::test_key(NavKey::Next);
        sleep(1).await;
    }
    if let Some(w) = w {
        crate::shots::save(&w, &dir.join("menu-keynav.png"));
        w.set_visible(false);
    }
    crate::magazine::open();
    sleep(5).await;
    for _ in 0..4 {
        crate::magazine::test_key(Some(NavKey::Next), 0);
        sleep(1).await;
    }
    if let Some(w) = crate::magazine::window() {
        crate::shots::save(&w, &dir.join("magazine-keynav.png"));
    }
    crate::magazine::test_key(None, 1); // Ctrl+] → 이번 주
    sleep(3).await;
    if let Some(w) = crate::magazine::window() {
        crate::shots::save(&w, &dir.join("magazine-flip.png"));
    }
    // 매거진에서 고른 카드를 ⏎ 로 열고, 읽기 창에서 J(다음 기사) — 같은 창에서 바뀌는지
    crate::magazine::test_key(None, -1);
    sleep(3).await;
    crate::magazine::test_key(Some(NavKey::Next), 0);
    crate::magazine::test_key(Some(NavKey::Open), 0);
    sleep(5).await;
    if let Some(w) = crate::reader::last_window() {
        crate::shots::save(&w, &dir.join("reader-open.png"));
        crate::reader::test_step(1);
        sleep(5).await;
        crate::shots::save(&w, &dir.join("reader-j.png"));
    }
    log::info!("[시험] 키보드 탐색 찍기 끝");
}

// 유료 출처 기사 중 같은 스토리에 무료 보도가 있는 것을 읽기 창으로
async fn paywall_reader(dir: &std::path::Path) {
    let (tx, rx) = async_channel::bounded(1);
    let core = ui().core.clone();
    bg(
        async move {
            let filter = core.source_filter();
            let recent: Vec<NewsItem> = core.db.items(chrono::Utc::now() - chrono::Duration::days(3), None, 3000).into_iter().map(|s| s.item).collect();
            let walled: Vec<NewsItem> = recent.iter().filter(|i| core.paywall.kind(i).is_some()).cloned().collect();
            log::info!("[시험] 유료 표시 기사 {}건 / {}건", walled.len(), recent.len());
            let with_alts: Vec<NewsItem> = walled.into_iter().filter(|i| !core.paywall.alternatives(i, &filter).is_empty()).collect();
            with_alts.iter().find(|i| core.paywall.kind(i).map(|k| k.blocks()).unwrap_or(false)).cloned().or_else(|| with_alts.first().cloned())
        },
        move |pick| {
            let _ = tx.try_send(pick);
        },
    );
    let Ok(Some(it)) = rx.recv().await else {
        log::info!("[시험] 무료 보도가 있는 유료 기사를 찾지 못함");
        return;
    };
    log::info!("[시험] 유료 기사 {} · {}", it.source_name, it.display_title());
    crate::reader::open(&it, None);
    sleep(12).await;
    if let Some(w) = crate::reader::last_window() {
        crate::shots::save(&w, &dir.join("paywall-reader.png"));
        w.close();
    }
}

async fn today(dir: &std::path::Path) {
    crate::magazine::open();
    sleep(6).await;
    let Some(w) = crate::magazine::window() else { return };
    crate::shots::save(&w, &dir.join("today-progress.png"));
    let core = ui().core.clone();
    let ed = core.editorial();
    let issue = dropcap_core::magazine::live_daily(&core.db, &ed);
    let r = dropcap_core::magazine::resolve(&core.db, &issue, &ed.filter);
    let keys = dropcap_core::today_issue::keys(r.cover.as_ref().map(|c| c.item.key()).as_deref(), &r.sections, &core.chosen_sections());
    let all: Vec<NewsItem> = r.cover.iter().map(|c| c.item.clone()).chain(r.sections.iter().flat_map(|(_, i)| i.clone())).collect();
    for k in &keys {
        if let Some(it) = all.iter().find(|i| i.key() == *k) {
            core.set_read(it, true);
        }
    }
    log::info!("[시험] 오늘 호 대표 기사 {}건 읽음 처리", keys.len());
    sleep(3).await;
    crate::shots::save(&w, &dir.join("today-done.png"));
}

async fn brief(dir: &std::path::Path) {
    let core = ui().core.clone();
    let ed = core.editorial();
    let issue = dropcap_core::magazine::live_daily(&core.db, &ed);
    let r = dropcap_core::magazine::resolve(&core.db, &issue, &ed.filter);
    let Some((sec, items)) = r
        .sections
        .iter()
        .find(|(s, i)| s.section.is_some() && s.section.as_deref() != Some(dropcap_core::sections::TOP) && i.len() >= 3)
        .map(|(s, i)| (s.section.clone().unwrap(), i.iter().take(6).cloned().collect::<Vec<_>>()))
    else {
        log::info!("[시험] 저녁 정리할 분야 없음");
        return;
    };
    core.make_brief(&sec, &items, chrono::Utc::now());
    sleep(25).await;
    if core.brief(&sec).is_none() {
        log::info!("[시험] 기기 안 요약 없음 → 견본 문장으로 화면만 확인");
        core.set_brief_lines(
            &sec,
            vec![
                Line { text: "(시험 견본) 첫 기사와 셋째 기사가 같은 흐름을 다룬다".into(), refs: vec![0, 2] },
                Line { text: "(시험 견본) 둘째 기사의 발표가 오늘 이 분야의 큰 소식이다".into(), refs: vec![1] },
                Line { text: "(시험 견본) 넷째 기사는 그 배경을 설명한다".into(), refs: vec![3] },
            ],
        );
    } else {
        log::info!("[시험] 기기 안 요약: {:?}", core.brief(&sec).and_then(|b| b.lines).unwrap_or_default());
    }
    crate::magazine::open_section(&sec);
    sleep(4).await;
    if let Some(w) = crate::magazine::window() {
        crate::shots::save(&w, &dir.join("brief.png"));
    }
}
