// 맥 SourceDirectoryTests.swift 를 옮긴 것: 설정 › 구독 목록 정리 — 매체 묶음 키·이름 · 찾기(이름·주소·분야·지역·대소문자·띄어쓰기) ·
// 켠 것 거르기 · 정렬 · 묶음 켠 수 · 요약. 그리고 묶음 켜기·끄기가 한 번에 저장되는지(set_enabled_many)
use dropcap_core::app_model::AppModel;
use dropcap_core::models::{resources, Source};
use dropcap_core::source_directory::{self as sd, Layout, Status};
use dropcap_core::store::Store;
use std::collections::HashSet;

fn src(id: &str, name: &str, section: &str, region: &str, url: Option<&str>, home: Option<&str>) -> Source {
    Source {
        id: id.into(),
        name: name.into(),
        tier: if region == "kr" { "kr" } else { "press" }.into(),
        kind_type: "feed".into(),
        url: url.map(str::to_string).unwrap_or_else(|| format!("https://{id}.example/rss")),
        match_: None,
        ai_only: false,
        default_on: false,
        color: "#000000".into(),
        kind: None,
        notify_default: None,
        group: None,
        home: home.map(str::to_string),
        section: Some(section.into()),
        lang: None,
        region: Some(region.into()),
        paywall: None,
    }
}

fn kr(id: &str, name: &str) -> Source {
    src(id, name, "economy", "kr", None, None)
}

fn set(ids: &[&str]) -> HashSet<String> {
    ids.iter().map(|s| s.to_string()).collect()
}

#[test]
fn media_key_and_name() {
    let yna = vec![src("yna-politics", "연합뉴스 정치", "politics", "kr", None, None), kr("yna-market", "연합뉴스 마켓+"), src("yna-latest", "연합뉴스 최신", "top", "kr", None, None)];
    assert_eq!(yna.iter().map(sd::media_key).collect::<HashSet<_>>(), HashSet::from(["yna"]));
    assert_eq!(sd::media_name(&yna), "연합뉴스");
    assert_eq!(sd::short_name(&yna[1], "연합뉴스"), "마켓+");
    // 첫 낱말이 다르면 대표 피드(id == 묶음 키)의 이름
    let nyt = vec![
        src("nyt", "The New York Times", "economy", "intl", None, None),
        src("nyt-politics", "NYT Politics", "economy", "intl", None, None),
        src("nyt-arts", "NYT Arts", "economy", "intl", None, None),
    ];
    assert_eq!(sd::media_name(&nyt), "The New York Times"); // 'NYT Arts'(가장 짧은 이름)가 아님
    assert_eq!(sd::media_name(&nyt[1..]), "NYT");
    // 실제 sources.json 은 'nyt' 가 없고 'nyt-home' 이 대표 피드
    let nyt_home = vec![
        src("nyt-home", "The New York Times", "economy", "intl", None, None),
        src("nyt-politics", "NYT Politics", "economy", "intl", None, None),
        src("nyt-arts", "NYT Arts", "economy", "intl", None, None),
    ];
    assert_eq!(sd::media_name(&nyt_home), "The New York Times");
    // 대표 피드도 없으면 가장 짧은 이름(글자 수, 같으면 사전순)
    assert_eq!(sd::media_name(&[kr("x-a", "Alpha One"), kr("x-b", "Beta")]), "Beta");
    assert_eq!(sd::media_name(&[kr("x-a", "Delta"), kr("x-b", "Gamma")]), "Delta");
    assert_eq!(sd::short_name(&nyt[1], "The New York Times"), "NYT Politics");
    // 같은 이름 둘(Ars Technica 두 피드)은 그 이름 그대로, 짧은 이름도 그대로
    let ars = vec![src("ars", "Ars Technica", "economy", "intl", None, None), src("ars-ai", "Ars Technica", "economy", "intl", None, None)];
    assert_eq!(sd::media_name(&ars), "Ars Technica");
    assert_eq!(sd::short_name(&ars[0], "Ars Technica"), "Ars Technica");
    // 기본 출처: 연합뉴스·BBC 피드가 한 묶음
    let all = &resources::CONFIG.sources;
    let groups = sd::groups(all, all, Layout::Media, |_| false);
    let yna = groups.iter().find(|g| g.id == "media:yna").expect("media:yna");
    assert_eq!(yna.title, "연합뉴스");
    assert!(yna.total >= 10, "{}", yna.total);
    assert_eq!(groups.iter().find(|g| g.id == "media:bbc").map(|g| g.title.as_str()), Some("BBC"));
    assert_eq!(groups.iter().map(|g| g.total).sum::<usize>(), all.len()); // 빠짐·겹침 없음
}

#[test]
fn search_matches_name_url_section_region_ignoring_case_and_spaces() {
    let list = vec![
        src("bbc-world", "BBC World", "world", "intl", Some("https://feeds.bbci.co.uk/news/world/rss.xml"), None),
        src("hk-it", "한국경제 IT", "tech", "kr", None, Some("https://www.hankyung.com/it")),
        kr("yna-market", "연합뉴스 마켓+"),
    ];
    let q = |s: &str| -> Vec<String> { sd::filter(&list, s, Status::All, |_| true).into_iter().map(|x| x.id).collect() };
    assert_eq!(q("bbc world"), ["bbc-world"]); // 대소문자·띄어쓰기 무시
    assert_eq!(q("BBCWORLD"), ["bbc-world"]);
    assert_eq!(q("bbci.co.uk"), ["bbc-world"]); // 주소
    assert_eq!(q("hankyung"), ["hk-it"]); // 사람이 보는 주소(home)
    assert_eq!(q("국제"), ["bbc-world"]); // 분야 이름
    assert_eq!(q("해외"), ["bbc-world"]); // 지역
    assert_eq!(q("국내"), ["hk-it", "yna-market"]);
    assert_eq!(q("  ").len(), 3); // 빈 찾기는 전부
    assert!(q("없는출처").is_empty());
}

#[test]
fn status_filter() {
    let list = vec![kr("a", "가"), kr("b", "나"), kr("c", "다")];
    let on = set(&["a", "c"]);
    let ids = |q: &str, st: Status| -> Vec<String> { sd::filter(&list, q, st, |id| on.contains(id)).into_iter().map(|x| x.id).collect() };
    assert_eq!(ids("", Status::On), ["a", "c"]);
    assert_eq!(ids("", Status::Off), ["b"]);
    assert!(ids("나", Status::On).is_empty());
}

#[test]
fn sorting_domestic_first_then_abc() {
    let list = vec![
        src("x", "Zeta", "economy", "intl", None, None),
        kr("y", "한겨레"),
        src("z", "alpha", "economy", "intl", None, None),
        kr("w", "경향신문"),
    ];
    let names: Vec<String> = sd::sorted(&list).into_iter().map(|s| s.name).collect();
    assert_eq!(names, ["경향신문", "한겨레", "alpha", "Zeta"]);
}

#[test]
fn group_counts_and_bulk_targets_only_shown() {
    let all = vec![
        kr("yna-a", "연합뉴스 경제"),
        src("yna-b", "연합뉴스 정치", "politics", "kr", None, None),
        src("yna-c", "연합뉴스 국제", "world", "kr", None, None),
        src("bbc-a", "BBC World", "world", "intl", None, None),
    ];
    let on = set(&["yna-a", "yna-b"]);
    let en = |id: &str| on.contains(id);
    let shown = sd::filter(&all, "국제", Status::All, en);
    let media = sd::groups(&all, &shown, Layout::Media, en);
    // 국내 먼저, 묶음 켠 수는 묶음 전체(2/3), 보이는 것은 거른 것만(묶음 켜기·끄기는 이것에만)
    assert_eq!(media.iter().map(|g| g.id.as_str()).collect::<Vec<_>>(), ["media:yna", "media:bbc"]);
    assert_eq!((media[0].on, media[0].total), (2, 3));
    assert_eq!(media[0].sources.iter().map(|s| s.id.as_str()).collect::<Vec<_>>(), ["yna-c"]);
    let sections = sd::groups(&all, &all, Layout::Section, en);
    assert_eq!(sections.iter().map(|g| g.id.as_str()).collect::<Vec<_>>(), ["section:politics", "section:economy", "section:world"]); // categories.json 순서
    assert_eq!(sections.last().map(|g| (g.on, g.total)), Some((0, 2)));
    let regions = sd::groups(&all, &all, Layout::Region, en);
    assert_eq!(regions.iter().map(|g| g.title.as_str()).collect::<Vec<_>>(), ["국내", "해외"]);
}

#[test]
fn summary() {
    let all = vec![kr("a", "가"), src("b", "나", "politics", "kr", None, None), kr("c", "다"), src("d", "라", "world", "kr", None, None)];
    let on = set(&["a", "b", "c"]);
    assert_eq!(sd::summary_text(&all, |id| on.contains(id)), "켠 출처 3곳 · 정치 1 · 경제 2");
    assert_eq!(sd::summary_text(&all, |_| false), "켠 출처 없음");
    assert_eq!(sd::count_text(12, 147), "147곳 중 12곳");
    assert_eq!(sd::count_text(147, 147), "147곳");
}

#[test]
fn layout_raw_round_trip() {
    for l in Layout::ALL {
        assert_eq!(Layout::from_raw(l.raw()), l);
    }
    assert_eq!(Layout::from_raw("엉뚱한 값"), Layout::Media); // 기본은 매체별
}

// 묶음 끄기: 여러 출처를 한 번에(저장·다시 계산 한 번). 켜기는 새로 확인을 돌리므로 끄기만 본다
#[test]
fn bulk_turn_off_applies_to_all_given_ids_only() {
    let rt = tokio::runtime::Runtime::new().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let core = AppModel::new(Store::new(dir.path().to_path_buf()), rt.handle().clone());
    let ids: Vec<String> = resources::CONFIG.sources.iter().take(3).map(|s| s.id.clone()).collect();
    let keep = ids[2].clone();
    core.replace_state(|s| {
        let mut s = s.clone();
        for id in &ids {
            s.enabled.insert(id.clone(), true);
        }
        s
    });
    core.set_enabled_many(&ids[..2], false);
    let st = core.state();
    assert_eq!(st.enabled.get(&ids[0]), Some(&false));
    assert_eq!(st.enabled.get(&ids[1]), Some(&false));
    assert_eq!(st.enabled.get(&keep), Some(&true));
    core.set_enabled_many(&[], true); // 빈 목록은 아무것도 안 함
    assert_eq!(core.state().enabled.get(&ids[0]), Some(&false));
}
