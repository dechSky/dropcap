// 앱의 두뇌(맥 Core/AppModel.swift): 확인 반복, 새 글 판단, 거르기·묶기, 알림 보내기, 읽음·저장·구독.
// 화면은 UiEvent 로만 받는다. 피드·번역·DB 는 모두 tokio 작업에서 돌아 화면을 멈추지 않는다(Q-07).
use crate::article::ArticleService;
use crate::channels::{self, PALETTE};
use crate::database::Database;
use crate::feed_service::SHARED as FEEDS;
use crate::notify_policy::{self, Decision, NotifyMode, SectionPolicy};
use crate::sections;
use crate::store::{NotifyMark, PendingItem};
use crate::magazine::{self, Interest, Issue};
use crate::models::{resources, ItemKind, NewsItem, Source};
use crate::story_match;
use crate::store::{AppState, Settings, Store, Style};
use crate::translator::{looks_foreign, SHARED as TR};
use chrono::{DateTime, Duration, Local, TimeZone, Timelike, Utc};
use futures::future::join_all;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

pub const MAX_AGE_SECS: i64 = 3 * 24 * 3600; // 날짜가 3일보다 오래된 글은 새 글로 치지 않음
pub const RECENT_LIMIT: usize = 300;
pub const PREVIEW_ID: &str = "preview";
pub const INTERVALS: [i64; 5] = [2, 5, 10, 15, 30];

#[derive(Debug, Clone)]
pub enum UiEvent {
    Toast { items: Vec<NewsItem>, sound: bool },
    System { items: Vec<NewsItem>, sound: bool },
    Info { title: String, sub: String },
    Digest { count: usize },
    Welcome,
    State,     // 상태가 바뀜(목록·안 읽음 수 등)
    Checking(bool),
    Magazine,  // 새 기사가 들어옴(지면 갱신 띠)
    Images,    // 사진만 채워짐(조용히 다시 그림)
    Layout,    // 숨긴 출처·고른 분야가 바뀜(알림 띠 없이 바로 다시 엮음)
    Bundle { section: String, items: Vec<NewsItem>, sound: bool },       // 묶음 한 방울(G-07)
    SystemBundle { section: String, items: Vec<NewsItem>, sound: bool }, // 시스템 알림 방식의 묶음
    Preparing(bool),
}

type Sink = Arc<dyn Fn(UiEvent) + Send + Sync>;

pub struct AppModel {
    pub store: Store,
    state: Mutex<AppState>,
    pub db: Arc<Database>,
    pub articles: Arc<ArticleService>,
    pub first_run: bool,
    checking: AtomicBool,
    enriching: AtomicBool,
    pub preparing: AtomicBool,
    sink: Mutex<Sink>,
    loop_task: Mutex<Option<tokio::task::JoinHandle<()>>>,
    rt: tokio::runtime::Handle,
    archive: Mutex<Vec<Issue>>,
    subscribing: Mutex<std::collections::HashSet<String>>,
    grown: Mutex<Vec<(crate::database::Cluster, NewsItem)>>, // 이번에 팔로우한 스토리에 붙은 새 보도(알림 뒤 비움)
    enrich_tried: Mutex<std::collections::HashSet<String>>,   // 이번 실행에서 이미 사진을 찾아본 기사
    digest_cache: Mutex<std::collections::HashMap<String, (i64, Vec<String>)>>,
}

pub fn words(list: &[String]) -> Vec<String> {
    list.iter().map(|s| s.trim().to_lowercase()).filter(|s| !s.is_empty()).collect()
}

// '알리지 않음' 낱말이 든 소식은 빼고, '꼭 알림' 낱말이 든 소식은 중요 표시(번역 뒤 제목·한국어 제목·요약)
pub fn apply_keywords(items: Vec<NewsItem>, settings: &Settings) -> Vec<NewsItem> {
    let mute = words(&settings.mute_keywords);
    let must = words(&settings.must_keywords);
    items
        .into_iter()
        .filter_map(|mut it| {
            let text = format!("{} {} {}", it.title, it.title_ko.as_deref().unwrap_or(""), it.summary).to_lowercase();
            if mute.iter().any(|w| text.contains(w)) {
                return None;
            }
            if must.iter().any(|w| text.contains(w)) {
                it.important = Some(true);
            }
            Some(it)
        })
        .collect()
}

fn tier_rank(t: &str) -> i32 {
    match t {
        "lab" => 0,
        "press" => 1,
        "kr" => 2,
        _ => 3,
    }
}

// 여러 곳이 같은 소식을 다루면 하나만 알리고 "외 N곳"으로 묶는다. 공식 발표 > 언론 > 국내 순으로 대표.
// 하루 반(36시간) 안에 이미 알린 소식과 같으면 알리지 않고 그 소식에 출처만 더한다.
pub fn group_same_story(items: Vec<NewsItem>, recent: &mut [NewsItem], now: DateTime<Utc>) -> Vec<NewsItem> {
    let mut sorted = items;
    sorted.sort_by(|a, b| tier_rank(&a.tier).cmp(&tier_rank(&b.tier)).then(b.date_or_past().cmp(&a.date_or_past())));
    let mut kept: Vec<NewsItem> = vec![];
    let cutoff = now - Duration::hours(36);
    for it in sorted {
        if let Some(i) = kept.iter().position(|k| story_match::same(&it, k)) {
            kept[i].related.get_or_insert_with(Vec::new).push(it.source_name.clone());
            continue;
        }
        if let Some(j) = recent.iter().position(|r| r.date_or_past() > cutoff && story_match::same(&it, r)) {
            let r = &mut recent[j];
            if !r.related.as_ref().map(|x| x.contains(&it.source_name)).unwrap_or(false) && r.source_name != it.source_name {
                r.related.get_or_insert_with(Vec::new).push(it.source_name.clone());
            }
            continue;
        }
        kept.push(it);
    }
    kept.sort_by(|a, b| b.date_or_past().cmp(&a.date_or_past()));
    kept
}

// 자정을 넘는 구간(예: 23시~7시)도 처리
pub fn in_quiet(hour: i64, start: i64, end: i64) -> bool {
    if start == end {
        return false;
    }
    if start < end {
        hour >= start && hour < end
    } else {
        hour >= start || hour < end
    }
}

pub fn tomorrow_morning(now: DateTime<Local>, hour: u32) -> DateTime<Utc> {
    let d = now.date_naive() + Duration::days(1);
    Local.from_local_datetime(&d.and_hms_opt(hour, 0, 0).unwrap()).earliest().unwrap().with_timezone(&Utc)
}

// "오후 3:05"
pub fn clock(d: Option<DateTime<Utc>>) -> String {
    let Some(d) = d else { return "아직 없음".into() };
    let l = d.with_timezone(&Local);
    let (pm, h) = l.hour12();
    format!("{} {}:{:02}", if pm { "오후" } else { "오전" }, h, l.minute())
}

pub fn preview_item() -> NewsItem {
    let mut it = NewsItem::new(PREVIEW_ID, crate::texts::PREVIEW_TITLE_EN, "", "openai", "미리 보기", "lab");
    it.title_ko = Some(crate::texts::PREVIEW_TITLE_KO.into());
    it.date = Some(Utc::now());
    it
}

// 처음 켠 출처는 기존 글을 조용히 기억만, 피드에 다시 보이면 시각 갱신, 3일보다 오래된 글은 빼기
pub fn fresh_items(state: &mut AppState, items: Vec<NewsItem>, src: &Source, now: DateTime<Utc>) -> Vec<NewsItem> {
    let first_time = !state.seeded.contains(&src.id);
    let mut out = vec![];
    for it in items {
        let k = it.key();
        let known = state.seen.contains_key(&k);
        state.seen.insert(k, now.timestamp() as f64); // 피드에 남아 있는 동안은 지워지지 않게 시각 갱신
        if known || first_time {
            continue;
        }
        if let Some(d) = it.date {
            if (now - d).num_seconds() > MAX_AGE_SECS {
                continue;
            }
        }
        out.push(it);
    }
    if first_time {
        state.seeded.push(src.id.clone());
    }
    out
}

pub fn set_read_in(state: &mut AppState, key: &str, on: bool, now: f64) {
    if on {
        state.read.insert(key.to_string(), now);
    } else {
        state.read.remove(key);
    }
    // 3000개 넘으면 오래된 것부터 2000개만 남김
    if state.read.len() > 3000 {
        let mut v: Vec<(String, f64)> = state.read.iter().map(|(k, v)| (k.clone(), *v)).collect();
        v.sort_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal));
        let drop = v.len() - 2000;
        for (k, _) in v.into_iter().take(drop) {
            state.read.remove(&k);
        }
    }
}

impl AppModel {
    pub fn new(store: Store, rt: tokio::runtime::Handle) -> Arc<AppModel> {
        let first_run = !store.exists();
        let state = store.load();
        let db = Arc::new(Database::open(&store.dir));
        let articles = ArticleService::new(store.dir.clone());
        let archive = db.issues(120);
        let me = Arc::new(AppModel {
            store,
            state: Mutex::new(state),
            db,
            articles,
            first_run,
            checking: AtomicBool::new(false),
            enriching: AtomicBool::new(false),
            preparing: AtomicBool::new(false),
            sink: Mutex::new(Arc::new(|_| {})),
            loop_task: Mutex::new(None),
            rt,
            archive: Mutex::new(archive),
            subscribing: Mutex::new(Default::default()),
            grown: Mutex::new(vec![]),
            enrich_tried: Mutex::new(Default::default()),
            digest_cache: Mutex::new(Default::default()),
        });
        let weak = Arc::downgrade(&me);
        me.articles.set_pinned(Arc::new(move || weak.upgrade().map(|m| m.state().saved.iter().map(|s| s.link.clone()).collect()).unwrap_or_default()));
        me
    }

    pub fn set_sink(&self, f: Sink) {
        *self.sink.lock().unwrap() = f;
    }
    fn send(&self, e: UiEvent) {
        let s = self.sink.lock().unwrap().clone();
        s(e);
    }

    pub fn state(&self) -> AppState {
        self.state.lock().unwrap().clone()
    }
    pub fn settings(&self) -> Settings {
        self.state.lock().unwrap().settings.clone()
    }
    pub fn is_checking(&self) -> bool {
        self.checking.load(Ordering::SeqCst)
    }

    fn mutate<R>(&self, f: impl FnOnce(&mut AppState) -> R) -> R {
        let (r, snapshot) = {
            let mut s = self.state.lock().unwrap();
            let r = f(&mut s);
            (r, s.clone())
        };
        self.store.save(&snapshot);
        self.send(UiEvent::State);
        r
    }

    // MARK: 시작
    pub fn start(self: &Arc<Self>) {
        let me = self.clone();
        self.rt.spawn(async move {
            me.migrate_if_needed();
            let m3 = me.clone();
            tokio::spawn(async move {
                tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                m3.recluster_if_needed();
            });
            if !me.state().magazine_backfilled {
                let m2 = me.clone();
                tokio::spawn(async move { m2.backfill_magazine().await });
            }
        });
        self.restart_loop();
        // 1분마다: 아침 브리핑 시각인지, 잠시 끄기가 끝났는지, 지난 호 발행
        let me = self.clone();
        self.rt.spawn(async move {
            let mut t = tokio::time::interval(std::time::Duration::from_secs(60));
            t.tick().await;
            loop {
                t.tick().await;
                me.minute_tick(Utc::now());
            }
        });
        // 잠자기에서 깨면 10초 뒤 확인: 벽시계가 단조 시계보다 30초 넘게 앞서 가면 잠들었다 깬 것
        let me = self.clone();
        self.rt.spawn(async move {
            let mut wall = std::time::SystemTime::now();
            let mut mono = std::time::Instant::now();
            loop {
                tokio::time::sleep(std::time::Duration::from_secs(5)).await;
                let w = std::time::SystemTime::now().duration_since(wall).unwrap_or_default();
                let m = mono.elapsed();
                wall = std::time::SystemTime::now();
                mono = std::time::Instant::now();
                if w > m + std::time::Duration::from_secs(30) {
                    log::info!("[확인] 잠자기에서 깸 — 10초 뒤 확인");
                    tokio::time::sleep(std::time::Duration::from_secs(10)).await;
                    me.clone().check_all(false).await;
                }
            }
        });
        if self.first_run {
            self.send(UiEvent::Welcome);
        }
    }

    pub fn restart_loop(self: &Arc<Self>) {
        let me = self.clone();
        let task = self.rt.spawn(async move {
            loop {
                // 별도 작업으로 돌려, 간격을 바꿔 이 반복이 취소돼도 진행 중인 확인은 끝까지 간다
                let m = me.clone();
                let _ = tokio::spawn(async move { m.check_all(false).await }).await;
                let minutes = me.settings().interval_minutes.max(1) as u64;
                tokio::time::sleep(std::time::Duration::from_secs(minutes * 60)).await;
            }
        });
        if let Some(old) = self.loop_task.lock().unwrap().replace(task) {
            old.abort();
        }
    }

    // MARK: 확인
    pub fn all_sources(&self) -> Vec<Source> {
        let s = self.state.lock().unwrap();
        resources::CONFIG.sources.iter().cloned().chain(s.custom_sources.iter().cloned()).collect()
    }

    pub fn source(&self, id: &str) -> Option<Source> {
        self.all_sources().into_iter().find(|s| s.id == id).or_else(|| channels::CATALOG.iter().find(|s| s.id == id).cloned())
    }

    pub async fn check_all(self: Arc<Self>, manual: bool) {
        if self.checking.swap(true, Ordering::SeqCst) {
            return;
        }
        self.send(UiEvent::Checking(true));
        self.check_inner(manual).await;
        crate::source_health::BOOK.save_if_dirty();
        self.checking.store(false, Ordering::SeqCst);
        self.send(UiEvent::Checking(false));
    }

    async fn check_inner(self: &Arc<Self>, manual: bool) {
        let enabled = self.state().enabled;
        let active: Vec<Source> = self.all_sources().into_iter().filter(|s| enabled.get(&s.id) == Some(&true)).collect();
        let results = join_all(active.iter().map(|src| async move { (src.clone(), FEEDS.items(src, true).await) })).await;
        let now = Utc::now();
        let mut candidates: Vec<(Source, Vec<NewsItem>)> = vec![];
        {
            let mut st = self.state.lock().unwrap();
            for (src, res) in results {
                match res {
                    Ok(items) => {
                        st.errors.remove(&src.id);
                        if let Some(items) = items {
                            let f = fresh_items(&mut st, items, &src, now);
                            candidates.push((src, f));
                        }
                    }
                    Err(e) => {
                        st.errors.insert(src.id.clone(), e.to_string());
                    }
                }
            }
        }
        let mut found: Vec<NewsItem> = vec![];
        for (src, items) in candidates {
            for mut it in items {
                if src.is_sitemap() {
                    FEEDS.fill_title(&mut it).await;
                }
                if src.ai_only && !resources::ai_match(&format!("{} {}", it.title, it.summary)) {
                    continue;
                }
                found.push(it);
            }
        }
        found.sort_by(|a, b| b.date_or_past().cmp(&a.date_or_past()));
        if !found.is_empty() {
            let titles = TR.translate_many(&found.iter().map(|i| i.title.clone()).collect::<Vec<_>>()).await;
            for (i, t) in titles.into_iter().enumerate() {
                if t != found[i].title {
                    found[i].title_ko = Some(t);
                }
            }
        }
        found = apply_keywords(found, &self.settings()); // 번역 뒤에: 한국어 낱말도 영어 기사에 걸리게
        let hidden: std::collections::HashSet<String> = self.state().hidden_sources.into_iter().collect();
        found.retain(|it| !hidden.contains(&it.source_id)); // 숨긴 출처는 스토리 대표로도 다시 나오지 않게 처음부터 뺀다
        add_english_titles(&mut found).await;
        self.ingest(&found); // 매거진에는 묶이기 전 전부(여러 시각 비교용)
        self.notify_grown_stories();
        // 알림을 끈 채널(논문·커뮤니티 등)은 매거진에만 싣고, 목록·알림에는 넣지 않는다
        let candidates: Vec<NewsItem> = found.into_iter().filter(|it| self.notifies(&it.source_id)).collect();
        let (listed, quiet, sound, style) = {
            let mut st = self.state.lock().unwrap();
            let listed = group_same_story(candidates.clone(), &mut st.recent, now);
            let mut recent = listed.clone();
            recent.extend(st.recent.drain(..));
            recent.truncate(RECENT_LIMIT);
            st.recent = recent;
            st.unread += listed.len() as i64;
            st.last_check = Some(now);
            // 저장 파일만이 아니라 메모리의 기억도 정리(오래 켜 두면 끝없이 커지고 저장마다 정렬하던 문제)
            crate::store::trim_seen(&mut st.seen, crate::store::SEEN_LIMIT);
            // 방해 금지 시간·잠시 끄기: 알리지 않고 안 읽은 소식으로만 쌓는다
            let q = (Self::quiet_now(&st.settings) || st.snooze_until.map(|s| s > now).unwrap_or(false)) && !manual;
            (listed, q, st.settings.sound, st.settings.style)
        };
        // 분야 정책: 즉시 알릴 것 · 묶음으로 고일 것 · 매거진에만 둘 것
        let drops = self.decide(&candidates, &listed, quiet, now);
        self.store.save(&self.state());
        self.send(UiEvent::State);
        self.publish_due(); // 확인을 마친 뒤에 지난 호를 엮어 빠지는 기사가 없게
        if quiet {
            return;
        }
        if manual && drops.is_empty() && !listed.is_empty() {
            self.send(UiEvent::Info { title: format!("새 소식 {}건", listed.len()), sub: "알릴 만큼 큰 소식은 없어 목록·매거진에만 실었어요".into() });
            return;
        }
        // 중요 표시가 붙은 소식을 먼저
        let mut out = drops;
        out.sort_by_key(|i| if i.is_important() { 0 } else { 1 });
        self.deliver(out, manual, sound, style);
    }

    // MARK: 분야별 알림(G)
    pub fn needs_onboarding(&self) -> bool {
        self.state.lock().unwrap().sections_chosen.is_none()
    }
    pub fn chosen_sections(&self) -> Vec<String> {
        self.state.lock().unwrap().sections_chosen.clone().unwrap_or_default()
    }
    pub fn policy(&self, section: &str) -> SectionPolicy {
        self.state.lock().unwrap().section_policy.get(section).cloned().unwrap_or_default()
    }
    pub fn set_policy(&self, section: &str, change: impl FnOnce(&mut SectionPolicy)) {
        let mut p = self.policy(section);
        change(&mut p);
        self.mutate(|s| {
            s.section_policy.insert(section.to_string(), p);
        });
    }

    // 알림을 정할 때 쓰는 분야: 고른 분야에 걸린 칩이 있으면 그것, 없으면 대표 분야
    pub fn notify_section(&self, it: &NewsItem) -> String {
        let chosen = self.chosen_sections();
        it.section_chips().into_iter().find(|c| chosen.contains(c)).unwrap_or_else(|| it.section())
    }

    fn sent_today(st: &AppState, section: Option<&str>, now: DateTime<Utc>) -> i64 {
        let today = now.with_timezone(&Local).date_naive();
        st.notify_log.iter().filter(|m| m.at.with_timezone(&Local).date_naive() == today && section.map(|s| s == m.section).unwrap_or(true)).count() as i64
    }

    // 이번에 들어온 소식마다(같은 이야기는 하나로) 알림·고임·매거진만을 정한다. 떨어뜨릴 소식을 돌려준다.
    fn decide(&self, items: &[NewsItem], listed: &[NewsItem], quiet: bool, now: DateTime<Utc>) -> Vec<NewsItem> {
        let today = now.with_timezone(&Local).date_naive();
        let cutoff = now.timestamp() as f64 - 36.0 * 3600.0;
        {
            let mut st = self.state.lock().unwrap();
            st.notify_log.retain(|m| m.at.with_timezone(&Local).date_naive() == today);
            st.notified_stories.retain(|_, t| *t > cutoff);
            st.pending.retain(|p| (now - p.at).num_seconds() <= 36 * 3600);
        }
        let st0 = self.state();
        if items.is_empty() || st0.sections_chosen.is_none() {
            return vec![];
        }
        let chosen: std::collections::HashSet<String> = st0.sections_chosen.clone().unwrap_or_default().into_iter().collect();
        let limits = st0.settings.limits();
        let hidden: std::collections::HashSet<String> = st0.hidden_sources.iter().cloned().collect();
        // 같은 이야기끼리 모아 대표 하나(공식 발표 > 언론 > 국내, 그다음 최신)
        let mut order: Vec<String> = vec![];
        let mut groups: HashMap<String, Vec<NewsItem>> = HashMap::new();
        for it in items {
            let story = self.db.cluster_of(&it.key()).unwrap_or_else(|| format!("item:{}", it.key()));
            if !groups.contains_key(&story) {
                order.push(story.clone());
            }
            groups.entry(story).or_default().push(it.clone());
        }
        let mut drops = vec![];
        for story in order {
            let st = self.state();
            if st.notified_stories.contains_key(&story) {
                continue;
            }
            let g: &Vec<NewsItem> = &groups[&story];
            let Some(rep) = g.iter().min_by(|a, b| tier_rank(&a.tier).cmp(&tier_rank(&b.tier)).then(b.date_or_past().cmp(&a.date_or_past()))).cloned() else { continue };
            let sec = self.notify_section(&rep);
            let cov = magazine::region_coverage(&self.db, &rep, &hidden);
            let input = notify_policy::Input {
                chosen: chosen.contains(&sec),
                policy: st.section_policy.get(&sec).cloned().unwrap_or_default(),
                coverage: cov,
                lab: g.iter().any(|i| i.tier == "lab"),
                important: g.iter().any(|i: &NewsItem| i.is_important()),
                followed: st.followed_stories.contains(&story),
                sent_in_section: Self::sent_today(&st, Some(&sec), now),
                sent_total: Self::sent_today(&st, None, now),
            };
            let top = chosen.contains(sections::TOP).then(|| notify_policy::Input {
                chosen: true,
                policy: st.section_policy.get(sections::TOP).cloned().unwrap_or_default(),
                coverage: cov,
                lab: false,
                important: false,
                followed: false,
                sent_in_section: Self::sent_today(&st, Some(sections::TOP), now),
                sent_total: Self::sent_today(&st, None, now),
            });
            let (decision, via_top) = notify_policy::decide_with_top(&input, top.as_ref(), limits);
            let mut s = self.state.lock().unwrap();
            match decision {
                Decision::Drop if !quiet => {
                    let mut shown = listed.iter().find(|l| l.key() == rep.key()).cloned().unwrap_or_else(|| rep.clone());
                    if shown.related.is_none() && g.len() > 1 {
                        shown.related = Some(g.iter().filter(|i: &&NewsItem| i.key() != rep.key()).map(|i: &NewsItem| i.source_name.clone()).collect());
                    }
                    drops.push(shown);
                    s.notify_log.push(NotifyMark { section: if via_top { sections::TOP.into() } else { sec.clone() }, at: now });
                    s.notified_stories.insert(story.clone(), now.timestamp() as f64);
                    s.pending.retain(|p| p.story != story);
                }
                Decision::Pool | Decision::Drop => {
                    // 방해 금지 중에 떨어질 소식도 고였다가 다음 묶음으로
                    if !s.pending.iter().any(|p| p.story == story) {
                        s.pending.push(PendingItem { item: rep.clone(), section: sec.clone(), story: story.clone(), at: now });
                    }
                }
                Decision::Quiet => {}
            }
        }
        drops
    }

    // 묶음: 분야마다 정한 시각이 지나면 고인 소식을 한 방울로("경제 7건")
    pub fn deliver_bundles(&self, now: DateTime<Utc>) {
        let st = self.state();
        if st.pending.is_empty() || self.is_quiet_time() || self.is_snoozed() {
            return;
        }
        let mut secs: Vec<String> = st.pending.iter().map(|p| p.section.clone()).collect();
        secs.sort_by_key(|s| sections::order(s));
        secs.dedup();
        for sec in secs {
            let hour = st.section_policy.get(&sec).cloned().unwrap_or_default().bundle_hour;
            if !notify_policy::bundle_due(hour, now, st.last_bundle.get(&sec).cloned()) {
                continue;
            }
            let items: Vec<NewsItem> = st.pending.iter().filter(|p| p.section == sec).map(|p| p.item.clone()).collect();
            self.mutate(|s| {
                s.pending.retain(|p| p.section != sec);
                s.last_bundle.insert(sec.clone(), now);
            });
            match st.settings.style {
                Style::Drop => self.send(UiEvent::Bundle { section: sec.clone(), items, sound: st.settings.sound }),
                Style::System => self.send(UiEvent::SystemBundle { section: sec.clone(), items, sound: st.settings.sound }),
            }
        }
    }

    // 처음 실행: 관심 분야를 고른다(설정에서 다시 고를 수도). 고른 분야의 기본 출처를 켜고 그 분야 최근 소식으로 매거진을 채운다.
    pub fn choose_sections(self: &Arc<Self>, ids: &[String]) {
        let before: std::collections::HashSet<String> = self.chosen_sections().into_iter().collect();
        let first = self.needs_onboarding();
        let mut ordered: Vec<String> = ids.to_vec();
        ordered.sort_by_key(|s| sections::order(s));
        ordered.dedup();
        let defaults = notify_policy::defaults(&ordered);
        let mut turned_on: std::collections::HashSet<String> = Default::default();
        self.mutate(|s| {
            s.sections_chosen = Some(ordered.clone());
            for id in &ordered {
                if !s.section_policy.contains_key(id) {
                    if let Some(p) = defaults.get(id) {
                        s.section_policy.insert(id.clone(), *p);
                    }
                }
            }
            for (id, m) in sections::META.iter() {
                let Some(sec) = &m.section else { continue };
                let now_on = ordered.contains(sec);
                if now_on && (first || !before.contains(sec)) && m.default_on == Some(true) {
                    if s.enabled.get(id) != Some(&true) {
                        turned_on.insert(id.clone());
                    }
                    s.enabled.insert(id.clone(), true);
                } else if !now_on && (first || before.contains(sec)) {
                    s.enabled.insert(id.clone(), false);
                }
            }
            s.pending.retain(|p| ordered.contains(&p.section));
        });
        self.send(UiEvent::Layout);
        if !turned_on.is_empty() {
            let me = self.clone();
            self.rt.spawn(async move { me.backfill_magazine_only(Some(turned_on)).await });
        }
    }

    // 출처 수(켜짐/전체)
    pub fn source_count(&self, section: &str) -> (usize, usize) {
        let st = self.state.lock().unwrap();
        let ids: Vec<&String> = sections::META.values().filter(|m| m.section.as_deref() == Some(section)).map(|m| &m.id).collect();
        (ids.iter().filter(|id| st.enabled.get(**id) == Some(&true)).count(), ids.len())
    }

    // MARK: 카드에서 바로 줄이기(G-11)
    pub fn hide_source(&self, id: &str) {
        if self.state.lock().unwrap().hidden_sources.iter().any(|h| h == id) {
            return;
        }
        self.mutate(|s| {
            s.hidden_sources.push(id.to_string());
            s.recent.retain(|i| i.source_id != id);
            s.pending.retain(|p| p.item.source_id != id);
        });
        self.send(UiEvent::Layout);
    }
    pub fn unhide_source(&self, id: &str) {
        self.mutate(|s| s.hidden_sources.retain(|h| h != id));
        self.send(UiEvent::Layout);
    }
    pub fn less_of(&self, section: &str) {
        self.set_policy(section, |p| p.mode = if p.mode == NotifyMode::Instant { NotifyMode::Bundle } else { NotifyMode::Magazine });
    }
    pub fn mute_word(self: &Arc<Self>, word: &str) {
        let w = word.trim().to_string();
        if w.is_empty() {
            return;
        }
        let lw = w.to_lowercase();
        self.update(|st| {
            if !st.mute_keywords.contains(&w) {
                st.mute_keywords.push(w.clone());
            }
        });
        self.mutate(|s| s.pending.retain(|p| !format!("{} {}", p.item.title, p.item.title_ko.as_deref().unwrap_or("")).to_lowercase().contains(&lw)));
    }

    pub fn editorial(&self) -> magazine::Editorial {
        let st = self.state.lock().unwrap();
        magazine::Editorial {
            interest: Interest { category: st.interest_category.clone(), source: st.interest_source.clone() },
            hidden: st.hidden_sources.iter().cloned().collect(),
            chosen: st.sections_chosen.clone(),
            limits: st.settings.limits(),
        }
    }

    fn quiet_now(st: &Settings) -> bool {
        st.quiet_enabled && st.quiet_start != st.quiet_end && in_quiet(Local::now().hour() as i64, st.quiet_start, st.quiet_end)
    }

    pub fn is_quiet_time(&self) -> bool {
        Self::quiet_now(&self.settings())
    }

    pub fn is_snoozed(&self) -> bool {
        self.state().snooze_until.map(|s| s > Utc::now()).unwrap_or(false)
    }

    fn deliver(self: &Arc<Self>, items: Vec<NewsItem>, manual: bool, sound: bool, style: Style) {
        if items.is_empty() {
            if manual {
                self.send(UiEvent::Info { title: "새 소식이 없습니다".into(), sub: format!("마지막 확인 {}", clock(self.state().last_check)) });
            }
            return;
        }
        let top: Vec<NewsItem> = items.iter().take(3).cloned().collect();
        match style {
            Style::Drop => self.send(UiEvent::Toast { items, sound }),
            Style::System => self.send(UiEvent::System { items, sound }),
        }
        self.prefetch(top); // 누르기 전에 미리 본문·번역·요약 준비
    }

    pub fn prefetch(self: &Arc<Self>, items: Vec<NewsItem>) {
        let arts = self.articles.clone();
        self.rt.spawn(async move {
            for it in items.into_iter().filter(|i| i.id != PREVIEW_ID && !i.link.is_empty()) {
                arts.prepare(it, false).await;
            }
        });
    }

    // MARK: 매거진
    pub fn interest(&self) -> Interest {
        let s = self.state.lock().unwrap();
        Interest { category: s.interest_category.clone(), source: s.interest_source.clone() }
    }

    pub fn ingest(self: &Arc<Self>, items: &[NewsItem]) {
        if items.is_empty() {
            return;
        }
        let followed = self.state().followed_stories;
        let grown = magazine::ingest(&self.db, items, &followed);
        self.grown.lock().unwrap().extend(grown);
        self.db.prune(crate::database::KEEP_ITEMS);
        self.send(UiEvent::Magazine);
        self.enrich_images();
    }

    // 사진이 없는 최근 기사는 페이지에서 og:image 를 찾아 채운다(한 번에 12개, 공개 주소만)
    pub fn enrich_images(self: &Arc<Self>) {
        if self.enriching.swap(true, Ordering::SeqCst) {
            return;
        }
        let me = self.clone();
        self.rt.spawn(async move {
            let todo = {
                let mut tried = me.enrich_tried.lock().unwrap();
                if tried.len() > 5000 {
                    tried.clear(); // 오래 켜 둬도 끝없이 커지지 않게
                }
                let todo = magazine::image_todo(&me.db, &tried);
                for s in &todo {
                    tried.insert(s.item.key());
                }
                todo
            };
            let mut changed = false;
            for s in todo {
                if let Some(img) = FEEDS.og_image(&s.item.link).await {
                    me.db.set_image(&s.item.key(), &img);
                    changed = true;
                }
            }
            me.enriching.store(false, Ordering::SeqCst);
            if changed {
                me.send(UiEvent::Images);
            }
        });
    }

    // 팔로우한 스토리에 새 보도가 붙으면 알림(그 출처의 알림을 꺼 두었어도)
    fn notify_grown_stories(&self) {
        let grown: Vec<_> = std::mem::take(&mut *self.grown.lock().unwrap());
        if grown.is_empty() || self.is_quiet_time() || self.is_snoozed() {
            return;
        }
        for (c, it) in grown.into_iter().take(2) {
            self.send(UiEvent::Info { title: format!("팔로우한 스토리에 새 보도 · {}", it.source_name), sub: c.title });
        }
    }

    // 같은 소식 판정 기준이 바뀌었으면 최근 2주 스토리를 한 번 다시 묶는다(버전은 prefs.json)
    pub fn recluster_if_needed(&self) {
        let dir = self.store.dir.clone();
        let mut p = crate::store::Prefs::load(&dir);
        if p.story_rule_version >= magazine::STORY_RULE_VERSION {
            return;
        }
        p.story_rule_version = magazine::STORY_RULE_VERSION;
        p.save(&dir);
        magazine::recluster(&self.db);
        self.send(UiEvent::Magazine);
    }

    // 스토리 한눈에 요약(Ollama) — 보도 수가 같으면 다시 만들지 않음
    pub async fn story_digest(&self, c: &crate::database::Cluster) -> Option<Vec<String>> {
        if let Some((size, lines)) = self.digest_cache.lock().unwrap().get(&c.id) {
            if *size == c.size {
                return Some(lines.clone());
            }
        }
        let items: Vec<NewsItem> = self.db.items_in_cluster(&c.id).into_iter().map(|s| s.item).collect();
        if items.len() < 2 {
            return None;
        }
        let paras: Vec<String> =
            items.iter().map(|i| format!("[{}] {}. {}", i.source_name, i.display_title(), i.summary.chars().take(400).collect::<String>())).collect();
        let lines = crate::summarizer::summarize(&c.title, &paras).await?;
        self.digest_cache.lock().unwrap().insert(c.id.clone(), (c.size, lines.clone()));
        Some(lines)
    }

    pub fn coverage(&self, items: &[NewsItem]) -> std::collections::HashMap<String, i64> {
        self.db.coverage(&items.iter().map(|i| i.key()).collect::<Vec<_>>())
    }

    pub fn migrate_if_needed(self: &Arc<Self>) {
        if self.db.item_count() != 0 {
            return;
        }
        let st = self.state();
        let mut items: Vec<NewsItem> = st.recent.iter().chain(st.saved.iter()).cloned().collect();
        if items.is_empty() {
            return;
        }
        items.sort_by(|a, b| a.date_or_past().cmp(&b.date_or_past()));
        magazine::ingest(&self.db, &items, &[]);
        log::info!("[매거진] 예전 기록 {}건을 옮겼습니다", items.len());
    }

    pub fn publish_due(&self) {
        let list = magazine::publish_due(&self.db, &self.editorial(), Utc::now());
        *self.archive.lock().unwrap() = list;
    }

    pub fn archive(&self) -> Vec<Issue> {
        self.archive.lock().unwrap().clone()
    }

    pub fn live_daily(&self) -> Issue {
        magazine::live_daily(&self.db, &self.editorial())
    }
    pub fn live_weekly(&self) -> Issue {
        magazine::live_weekly(&self.db, &self.editorial())
    }

    // 처음 한 번: 켜진 출처에서 최근 3일 기사를 받아 매거진 첫 호를 채운다(알림 없음)
    pub async fn backfill_magazine(self: Arc<Self>) {
        self.backfill_magazine_only(None).await
    }

    // only: 이 출처들만(관심 분야를 고른 뒤 새로 켠 출처)
    pub async fn backfill_magazine_only(self: Arc<Self>, only: Option<std::collections::HashSet<String>>) {
        self.preparing.store(true, Ordering::SeqCst);
        self.send(UiEvent::Preparing(true));
        let cutoff = Utc::now() - Duration::days(3);
        let enabled = self.state().enabled;
        let mut all: Vec<NewsItem> = vec![];
        for src in self.all_sources().into_iter().filter(|s| enabled.get(&s.id) == Some(&true) && only.as_ref().map(|o| o.contains(&s.id)).unwrap_or(true)) {
            let Ok(Some(mut items)) = FEEDS.items(&src, false).await else { continue };
            items.retain(|i| i.date_or_past() > cutoff);
            if src.is_sitemap() {
                items.truncate(10);
                for it in items.iter_mut() {
                    FEEDS.fill_title(it).await;
                }
            }
            if src.ai_only {
                items.retain(|i| resources::ai_match(&format!("{} {}", i.title, i.summary)));
            }
            all.extend(items.into_iter().take(25));
        }
        let titles = TR.translate_many(&all.iter().map(|i| i.title.clone()).collect::<Vec<_>>()).await;
        for (i, t) in titles.into_iter().enumerate() {
            if t != all[i].title {
                all[i].title_ko = Some(t);
            }
        }
        add_english_titles(&mut all).await;
        let mut list = apply_keywords(all, &self.settings());
        list.sort_by(|a, b| a.date_or_past().cmp(&b.date_or_past()));
        let n = list.len();
        self.ingest(&list);
        self.publish_due();
        self.mutate(|s| s.magazine_backfilled = true);
        self.preparing.store(false, Ordering::SeqCst);
        self.send(UiEvent::Preparing(false));
        log::info!("[매거진] 첫 호를 {n}건으로 채웠습니다");
    }

    // MARK: 동작
    // 기사를 열 때(읽기 창은 부르는 쪽이 연다)
    pub fn open(&self, item: &NewsItem) -> bool {
        if item.id == PREVIEW_ID {
            return false;
        }
        self.mark_read();
        self.mark_opened(item);
        true
    }

    pub fn mark_opened(&self, item: &NewsItem) {
        if item.id == PREVIEW_ID {
            return;
        }
        let now = Utc::now().timestamp() as f64;
        self.mutate(|s| {
            set_read_in(s, &item.key(), true, now);
            // 관심사: 연 기사의 분야·출처를 센다
            *s.interest_category.entry(item.category().raw().to_string()).or_default() += 1.0;
            *s.interest_source.entry(item.source_id.clone()).or_default() += 1.0;
        });
    }

    // MARK: 스토리 팔로우
    pub fn is_following(&self, story: &str) -> bool {
        self.state.lock().unwrap().followed_stories.iter().any(|s| s == story)
    }
    pub fn set_following(&self, story: &str, on: bool, size: i64) {
        self.mutate(|s| {
            s.followed_stories.retain(|x| x != story);
            if on {
                s.followed_stories.push(story.to_string());
            }
            s.story_seen.insert(story.to_string(), size);
        });
    }
    pub fn mark_story_seen(&self, story: &str, size: i64) {
        if self.state.lock().unwrap().story_seen.get(story) == Some(&size) {
            return;
        }
        self.mutate(|s| {
            s.story_seen.insert(story.to_string(), size);
        });
    }
    pub fn unseen_reports(&self, c: &crate::database::Cluster) -> i64 {
        let seen = self.state.lock().unwrap().story_seen.get(&c.id).cloned().unwrap_or(c.size);
        (c.size - seen).max(0)
    }

    // 스크랩(읽기 창의 문단·기사 스크랩)
    pub fn scrap(&self, book: &mut crate::scrapbook::Scrapbook, item: &NewsItem, quote: Option<String>, original: Option<String>, collection: Option<&str>) {
        book.add(item, quote, original, "", collection);
    }

    pub fn snooze(&self, until: Option<DateTime<Utc>>) {
        self.mutate(|s| s.snooze_until = until);
    }

    pub fn minute_tick(&self, now: DateTime<Utc>) {
        if let Some(s) = self.state().snooze_until {
            if s <= now {
                self.mutate(|st| st.snooze_until = None);
            }
        }
        let local = now.with_timezone(&Local);
        if local.minute() % 30 == 0 {
            self.publish_due(); // 지난 호 발행
        }
        self.deliver_bundles(now);
        let st = self.settings();
        if !st.digest_enabled || (local.hour() as i64) < st.digest_hour {
            return;
        }
        let done_today = self.state().last_digest.map(|d| d.with_timezone(&Local).date_naive() == local.date_naive()).unwrap_or(false);
        if done_today || self.is_quiet_time() || self.is_snoozed() {
            return; // 조용한 때가 끝나면 그날 안에 다시 시도
        }
        self.mutate(|s| s.last_digest = Some(now));
        let n = self.digest_items(now).len();
        if n > 0 {
            self.send(UiEvent::Digest { count: n });
        }
    }

    // 지난 24시간 소식
    pub fn digest_items(&self, now: DateTime<Utc>) -> Vec<NewsItem> {
        let cutoff = now - Duration::hours(24);
        self.state().recent.into_iter().filter(|i| i.date_or_past() > cutoff).collect()
    }

    pub fn latest_unread(&self) -> Option<NewsItem> {
        let st = self.state();
        st.recent.iter().find(|i| !st.read.contains_key(&i.key())).or(st.recent.first()).cloned()
    }

    // MARK: 읽음·저장
    pub fn is_read(&self, item: &NewsItem) -> bool {
        self.state.lock().unwrap().read.contains_key(&item.key())
    }
    pub fn is_saved(&self, item: &NewsItem) -> bool {
        let k = item.key();
        self.state.lock().unwrap().saved.iter().any(|s| s.key() == k)
    }

    pub fn set_read(&self, item: &NewsItem, on: bool) {
        let now = Utc::now().timestamp() as f64;
        self.mutate(|s| set_read_in(s, &item.key(), on, now));
    }

    pub fn mark_all_read(&self) {
        let now = Utc::now().timestamp() as f64;
        self.mutate(|s| {
            let keys: Vec<String> = s.recent.iter().map(|i| i.key()).collect();
            for k in keys {
                s.read.entry(k).or_insert(now);
            }
            s.unread = 0;
        });
    }

    pub fn toggle_saved(self: &Arc<Self>, item: &NewsItem) {
        let k = item.key();
        let added = self.mutate(|s| {
            if s.saved.iter().any(|x| x.key() == k) {
                s.saved.retain(|x| x.key() != k);
                false
            } else {
                s.saved.insert(0, item.clone());
                true
            }
        });
        if added {
            // 오프라인으로 읽을 수 있게 번역까지 보관
            let arts = self.articles.clone();
            let it = item.clone();
            self.rt.spawn(async move {
                arts.prepare(it, true).await;
            });
        }
    }

    pub fn mark_read(&self) {
        if self.state().unread != 0 {
            self.mutate(|s| s.unread = 0);
        }
    }

    // MARK: 구독 채널
    pub fn notifies(&self, source_id: &str) -> bool {
        if let Some(v) = self.state.lock().unwrap().notify.get(source_id) {
            return *v;
        }
        self.all_sources().iter().find(|s| s.id == source_id).and_then(|s| s.notify_default).unwrap_or(true)
    }

    pub fn set_notify(&self, id: &str, on: bool) {
        self.mutate(|s| {
            s.notify.insert(id.to_string(), on);
        });
    }

    pub fn is_subscribed(&self, src: &Source) -> bool {
        self.state.lock().unwrap().custom_sources.iter().any(|s| s.id == src.id || s.url == src.url)
    }

    pub async fn subscribe(self: Arc<Self>, src: Source) -> Option<String> {
        if self.is_subscribed(&src) {
            return None;
        }
        self.add(src).await
    }

    // 아무 주소나: 알맞은 피드를 찾아 구독
    pub async fn add_channel(self: Arc<Self>, input: String, name: String) -> Option<String> {
        let f = match channels::resolve(&input).await {
            Ok(f) => f,
            Err(e) => return Some(e.to_string()),
        };
        if self.all_sources().iter().any(|s| s.url == f.feed_url) {
            return Some("이미 구독 중인 채널입니다".into());
        }
        let n = self.state().custom_sources.len();
        let src = Source {
            id: channels::custom_id(&f.feed_url),
            name: if name.trim().is_empty() { f.name.clone() } else { name.trim().to_string() },
            tier: "press".into(),
            kind_type: "feed".into(),
            url: f.feed_url.clone(),
            match_: None,
            ai_only: false,
            default_on: true,
            color: if f.kind == ItemKind::Video { "#FF0033".into() } else { PALETTE[n % PALETTE.len()].into() },
            kind: Some(f.kind.raw().into()),
            notify_default: Some(f.notify_default),
            group: Some("직접 추가".into()),
            home: f.home.clone(),
            section: None,
            lang: None,
            region: None,
        };
        self.add(src).await
    }

    // 실제로 받아 읽어 보고, 되면 추가한다. 실패하면 이유를 돌려준다.
    pub fn is_subscribing(&self, url: &str) -> bool {
        self.subscribing.lock().unwrap().contains(url)
    }

    async fn add(self: Arc<Self>, src: Source) -> Option<String> {
        if !self.subscribing.lock().unwrap().insert(src.url.clone()) {
            return None;
        }
        let r = self.clone().add_inner(src.clone()).await;
        self.subscribing.lock().unwrap().remove(&src.url);
        self.send(UiEvent::State);
        r
    }

    async fn add_inner(self: Arc<Self>, src: Source) -> Option<String> {
        // 해지 뒤 다시 구독할 때 남은 ETag 로 304 를 받지 않게 조건 없이 받는다
        let items = match FEEDS.items(&src, false).await {
            Ok(Some(items)) if !items.is_empty() => items,
            Ok(_) => return Some("글을 찾지 못했습니다".into()),
            Err(e) => return Some(format!("읽지 못했습니다: {e}")),
        };
        if self.all_sources().iter().any(|s| s.id == src.id || s.url == src.url) {
            return Some("이미 구독 중인 채널입니다".into());
        }
        // 지금 있는 글은 이 자리에서 기억해 두고(알리지 않음), 이후에 올라오는 글부터 알린다
        let now = Utc::now();
        self.mutate(|s| {
            for it in &items {
                s.seen.insert(it.key(), now.timestamp() as f64);
            }
            s.seeded.push(src.id.clone());
            s.custom_sources.push(src.clone());
            s.enabled.insert(src.id.clone(), true);
        });
        // 최근 3일 글은 매거진에 바로 싣는다(알림 없이)
        let cutoff = now - Duration::days(3);
        let limit = if src.notify_default == Some(false) { 30 } else { 15 };
        let mut recent: Vec<NewsItem> = items.into_iter().filter(|i| i.date_or_past() > cutoff).take(limit).collect();
        if !recent.is_empty() {
            let titles = TR.translate_many(&recent.iter().map(|i| i.title.clone()).collect::<Vec<_>>()).await;
            for (i, t) in titles.into_iter().enumerate() {
                if t != recent[i].title {
                    recent[i].title_ko = Some(t);
                }
            }
            recent.reverse();
            self.ingest(&recent);
        }
        None
    }

    pub fn remove_custom_source(&self, id: &str) {
        self.mutate(|s| {
            s.custom_sources.retain(|x| x.id != id);
            s.enabled.remove(id);
            s.notify.remove(id);
            s.seeded.retain(|x| x != id);
        });
    }

    pub fn set_enabled(self: &Arc<Self>, id: &str, on: bool) {
        self.mutate(|s| {
            s.enabled.insert(id.to_string(), on);
        });
        if on {
            let me = self.clone();
            self.rt.spawn(async move { me.check_all(false).await });
        }
    }

    pub fn update(self: &Arc<Self>, change: impl FnOnce(&mut Settings)) {
        let before = self.settings();
        let after = self.mutate(|s| {
            change(&mut s.settings);
            s.settings.clone()
        });
        if after.interval_minutes != before.interval_minutes {
            self.restart_loop();
        }
    }

    // 견본 카드. 실제 기사를 다시 띄우면 같은 소식이 또 온 것처럼 보이므로 쓰지 않는다
    pub fn preview(self: &Arc<Self>) {
        let st = self.settings();
        self.deliver(vec![preview_item()], false, st.sound, st.style);
    }

    pub fn check_now(self: &Arc<Self>) {
        let me = self.clone();
        self.rt.spawn(async move { me.check_all(true).await });
    }

    pub fn runtime(&self) -> tokio::runtime::Handle {
        self.rt.clone()
    }
}

// 한국어 제목 기사에 영어 제목을 붙인다(외국 기사와 같은 소식인지 비교하려고)
pub async fn add_english_titles(items: &mut [NewsItem]) {
    let idx: Vec<usize> = (0..items.len()).filter(|&i| !looks_foreign(&items[i].title) && items[i].title_en.is_none()).collect();
    if idx.is_empty() {
        return;
    }
    let en = TR.to_english(&idx.iter().map(|&i| items[i].title.clone()).collect::<Vec<_>>()).await;
    for (k, &i) in idx.iter().enumerate() {
        items[i].title_en = en[k].clone();
    }
}

// 상단바 창 '중요순'(맥 MenuView.byImportance): 꼭 알림 낱말(★) > 여러 곳이 다룬 정도 > 공식 발표 > 최근일수록 조금 더
pub fn by_importance(list: Vec<NewsItem>, coverage: &std::collections::HashMap<String, i64>, now: DateTime<Utc>) -> Vec<NewsItem> {
    let score = |it: &NewsItem| {
        let outlets = coverage.get(&it.key()).cloned().unwrap_or(1).max(it.related_count() as i64 + 1);
        let hours = ((now - it.date.unwrap_or(now)).num_seconds() as f64 / 3600.0).max(0.0);
        (if it.is_important() { 100.0 } else { 0.0 }) + (outlets - 1) as f64 * 12.0 + if it.tier == "lab" { 8.0 } else { 0.0 } + 6.0 * (-hours / 12.0).exp()
    };
    let mut v: Vec<(NewsItem, f64)> = list.into_iter().map(|i| {
        let s = score(&i);
        (i, s)
    }).collect();
    v.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal).then(b.0.date_or_past().cmp(&a.0.date_or_past())));
    v.into_iter().map(|(i, _)| i).collect()
}

// 낱말 고르기 메뉴에 보일 제목 낱말(G-11 '이 낱말 알리지 않기')
pub fn title_words(it: &NewsItem) -> Vec<String> {
    let text = [it.title_ko.as_deref(), Some(it.title.as_str())].into_iter().flatten().collect::<Vec<_>>().join(" ");
    const STOP: [&str; 17] = ["the", "and", "for", "with", "from", "that", "this", "into", "over", "after", "about", "new", "says", "its", "how", "why", "what"];
    let mut out: Vec<String> = vec![];
    for p in text.split(|c: char| !(c.is_alphanumeric() || c == '-')) {
        if p.chars().count() >= 2 && !out.iter().any(|o| o == p) && !STOP.contains(&p.to_lowercase().as_str()) && !p.chars().all(|c| c.is_numeric()) {
            out.push(p.to_string());
        }
    }
    out.truncate(12);
    out
}
