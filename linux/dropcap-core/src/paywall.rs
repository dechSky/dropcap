// 유료 기사 표시(G-14)와 같은 소식의 무료 보도 안내(G-15 · D-9) — 맥 Core/Paywall.swift.
// ① sources.json 의 paywall(hard·metered) ② 직접 추가한 출처는 주소의 도메인(알려진 곳) ③ 사용자가 연 기사의 본문 추리기 결과를
// 출처별로 쌓아 실패율이 높으면 '막힌 곳'으로 배운다. 원문 링크는 언제나 남긴다.
use crate::article::Block;
use crate::database::{Database, ExtractStat};
use crate::models::{ItemKind, NewsItem};
use crate::sections::SourceMeta;
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PaywallKind {
    Hard,    // 구독해야만 읽힘
    Metered, // 한 달 몇 건까지 무료
    Learned, // 표시는 없지만 여기서 열어 보면 자주 막힘
    Teaser,  // 이 기사를 미리 받아 보니 맛보기(앞부분만)였음(is_teaser) — 출처·피드 표시보다 앞선다
}

impl PaywallKind {
    pub fn from_raw(s: &str) -> Option<PaywallKind> {
        match s {
            "hard" => Some(PaywallKind::Hard),
            "metered" => Some(PaywallKind::Metered),
            "learned" => Some(PaywallKind::Learned),
            _ => None,
        }
    }
    pub fn label(&self) -> &'static str {
        match self {
            PaywallKind::Hard => "유료 기사",
            PaywallKind::Metered => "일부 유료(무료 건수 제한)",
            PaywallKind::Learned => "자주 막히는 곳",
            PaywallKind::Teaser => "앞부분만 공개된 기사",
        }
    }
    // 목록·카드에서 자물쇠 옆에 붙는 짧은 글(맛보기만 — 다른 자물쇠와 구분)
    pub fn short_text(&self) -> Option<&'static str> {
        if *self == PaywallKind::Teaser {
            Some("앞부분만")
        } else {
            None
        }
    }
    // 아이콘(Adwaita): metered 는 열린 자물쇠, 나머지는 잠긴 자물쇠
    pub fn icon(&self) -> &'static str {
        if *self == PaywallKind::Metered {
            "changes-allow-symbolic"
        } else {
            "changes-prevent-symbolic"
        }
    }
    // 열기 전에 다른 보도를 먼저 권할 만큼 막히는가
    pub fn blocks(&self) -> bool {
        *self != PaywallKind::Metered
    }
    // 마우스를 올리면 보이는 이유
    pub fn tooltip(&self) -> String {
        if *self == PaywallKind::Teaser {
            return "미리 받아 보니 사이트가 앞부분만 공개한 기사예요 — 열면 같은 소식의 무료 보도를 먼저 권합니다".to_string();
        }
        if self.blocks() {
            format!("{} — 열면 같은 소식의 무료 보도를 먼저 권합니다", self.label())
        } else {
            self.label().to_string()
        }
    }
}

// sources.json 에 없는(직접 추가한) 출처도 알아보게: 널리 알려진 유료 매체
pub const KNOWN_DOMAINS: &[(&str, PaywallKind)] = &[
    ("ft.com", PaywallKind::Hard),
    ("economist.com", PaywallKind::Hard),
    ("wsj.com", PaywallKind::Hard),
    ("bloomberg.com", PaywallKind::Hard),
    ("barrons.com", PaywallKind::Hard),
    ("thetimes.co.uk", PaywallKind::Hard),
    ("thetimes.com", PaywallKind::Hard),
    ("theinformation.com", PaywallKind::Hard),
    ("nikkei.com", PaywallKind::Hard),
    ("asia.nikkei.com", PaywallKind::Hard),
    ("nytimes.com", PaywallKind::Metered),
    ("washingtonpost.com", PaywallKind::Metered),
    ("theatlantic.com", PaywallKind::Metered),
    ("newyorker.com", PaywallKind::Metered),
    ("wired.com", PaywallKind::Metered),
    ("marketwatch.com", PaywallKind::Metered),
    ("telegraph.co.uk", PaywallKind::Metered),
    ("newscientist.com", PaywallKind::Metered),
    ("statnews.com", PaywallKind::Metered),
    ("businessinsider.com", PaywallKind::Metered),
    ("foreignpolicy.com", PaywallKind::Metered),
    ("hbr.org", PaywallKind::Metered),
];

// 배워서 '막히는 곳'으로 보는 기준: 5번 이상 열었고 60% 넘게 막힘
pub const LEARN_MIN_TRIES: i64 = 5;
pub const LEARN_FAIL_RATE: f64 = 0.6;
// 이보다 짧은 본문에 구독 권유 문구가 있으면 맛보기(막힘)
pub const TEASER_CHARS: usize = 1500;

pub fn domain_kind(link: &str) -> Option<PaywallKind> {
    let host = url::Url::parse(link).ok()?.host_str()?.to_lowercase();
    let host = host.strip_prefix("www.").unwrap_or(&host).to_string();
    // 하위 도메인(edition.ft.com 등)은 뒤에서부터 맞춰 본다
    let mut parts: Vec<&str> = host.split('.').collect();
    while parts.len() >= 2 {
        let h = parts.join(".");
        if let Some((_, k)) = KNOWN_DOMAINS.iter().find(|(d, _)| *d == h) {
            return Some(*k);
        }
        parts.remove(0);
    }
    None
}

// paid: 피드가 이 기사에 적은 표시(NewsItem.paid) — 출처 값보다 앞선다. true 면 구독해야만(Hard), false 면 무료로 풀린 기사
// teaser: 이 기사를 받아 보니 맛보기였음(PaywallBook 의 teasers) — 무엇보다 앞선다
pub fn kind(
    source_id: &str,
    link: &str,
    paid: Option<bool>,
    teaser: bool,
    meta: &HashMap<String, SourceMeta>,
    stats: &HashMap<String, ExtractStat>,
) -> Option<PaywallKind> {
    if teaser {
        return Some(PaywallKind::Teaser);
    }
    if let Some(p) = paid {
        return if p { Some(PaywallKind::Hard) } else { None };
    }
    if let Some(p) = meta.get(source_id).and_then(|m| m.paywall.as_deref()) {
        return PaywallKind::from_raw(p);
    }
    if let Some(k) = domain_kind(link) {
        return Some(k);
    }
    match stats.get(source_id) {
        Some(s) if s.tries >= LEARN_MIN_TRIES && s.fail_rate() >= LEARN_FAIL_RATE => Some(PaywallKind::Learned),
        _ => None,
    }
}

// 본문은 추렸지만 맛보기만 나오고 구독을 권하는 글(유료벽 뒤)인가
pub const WALL_PHRASES: &[&str] = &[
    "subscribe to continue",
    "subscribe to read",
    "subscribers only",
    "subscriber-only",
    "to continue reading",
    "sign in to continue",
    "already a subscriber",
    "create a free account to continue",
    "this article is for subscribers",
    "unlock this article",
    "become a member to read",
    "유료 회원",
    "구독자 전용",
    "로그인 후 이용",
    "유료 기사",
    "프리미엄 회원",
];

// 길이와 상관없이 맛보기로 보는 강한 문구(STAT+ 맛보기는 구독 권유 줄까지 1,500자를 넘는다 — 맥 Paywall.strongWall)
static STRONG_WALL: once_cell::sync::Lazy<regex::Regex> = once_cell::sync::Lazy::new(|| {
    regex::Regex::new(r"(?i)exclusive (?:to|for) [^.]{0,30}subscribers|read the rest of this (?:story|article)|this article is for (?:paid )?subscribers|unlock this article|구독자 전용|유료 회원 전용|한경 프리미엄9?의 모든 콘텐츠").unwrap()
});
pub const PAID_TEASER_CHARS: usize = 1500; // 사이트가 유료라고 적었을 때
pub const HARD_TEASER_CHARS: usize = 2500; // 하드 유료 출처일 때

// 맛보기(유료벽 뒤 앞부분만)인가 — 맥 Paywall.isTeaser. 지금의 문구 판정에 더해
// 사이트가 유료라고 적었고(isAccessibleForFree=false · 한경 articlePayment) 본문이 1,500자 미만, 하드 유료 출처인데 2,500자 미만, 끝쪽에 강한 문구
// ld_body: 사이트가 ld+json articleBody 로 적은 본문 글자 수. 우리 본문과 거의 같으면(±10%) 그 길이가 기사 전부다 —
// 늘 isAccessibleForFree=false 라고 적지만 전문을 주는 사이트(Verge)의 짧은 기사를 맛보기로 잘못 보지 않게 '유료+1,500자' 규칙을 쓰지 않는다
// (하드 유료 2,500자·강한 문구·구독 권유 문구 판정은 그대로 — 맥 ld-body-match)
pub const LD_BODY_SLACK: f64 = 0.1;
pub fn matches_site_body(length: usize, ld_body: Option<usize>) -> bool {
    match ld_body {
        Some(ld) if ld > 0 => (length as f64 - ld as f64).abs() <= ld as f64 * LD_BODY_SLACK,
        _ => false,
    }
}

pub fn is_teaser(blocks: &[Block], paid: Option<bool>, kind: Option<PaywallKind>, ld_body: Option<usize>) -> bool {
    if looks_blocked(blocks) {
        return true;
    }
    let texts: Vec<&str> = blocks.iter().filter_map(|b| b.original.as_deref().or(b.text.as_deref())).collect();
    let length: usize = texts.iter().map(|t| t.chars().count()).sum();
    if STRONG_WALL.is_match(&texts[texts.len().saturating_sub(4)..].join(" ")) {
        return true;
    }
    // ld 본문과는 군더더기(기자 소개·'Follow topics…')를 뺀 길이로도 견준다(Verge: 뺀 뒤 899자 = ld 902자)
    let cleaned: usize = crate::article::body_cleanup::drop_junk(blocks)
        .iter()
        .filter_map(|b| b.original.as_deref().or(b.text.as_deref()))
        .map(|t| t.chars().count())
        .sum();
    if paid == Some(true) && length < PAID_TEASER_CHARS && !matches_site_body(length, ld_body) && !matches_site_body(cleaned, ld_body) {
        return true;
    }
    kind == Some(PaywallKind::Hard) && length < HARD_TEASER_CHARS
}

pub fn looks_blocked(blocks: &[Block]) -> bool {
    let texts: Vec<&str> = blocks.iter().filter_map(|b| b.text.as_deref()).collect();
    let length: usize = texts.iter().map(|t| t.chars().count()).sum();
    if length >= TEASER_CHARS {
        return false; // 본문이 충분하면 끝의 구독 안내 문구는 무시
    }
    let lower = texts.join(" ").to_lowercase();
    WALL_PHRASES.iter().any(|p| lower.contains(p))
}

// 읽기 창 문구(맥 PaywallViews TeaserBanner·CutEndNote 그대로 — A②)
pub const TEASER_TITLE: &str = "구독자만 전체를 볼 수 있는 기사예요";
pub const TEASER_DETAIL: &str = "아래는 사이트가 공개한 앞부분입니다.";
pub const TEASER_END: &str = "— 여기까지가 공개된 부분입니다";
pub const TEASER_CONTINUE: &str = "원문에서 이어 읽기";
pub const PARTIAL_END: &str = "본문 일부만 가져왔을 수 있어요";
pub const OPEN_ORIGINAL: &str = "원문 열기";
pub const RELOAD: &str = "다시 받기";

// 같은 소식 중 열리는 보도: 유료가 아니고(배운 막힘 포함), 숨긴 출처가 아니고, 자기 자신이 아닌 것.
// 출처마다 하나, 공식 발표 > 국내 > 언론, 최신 순, limit 개까지
pub fn free_alternatives(
    item: &NewsItem,
    story: &[NewsItem],
    hidden: &HashSet<String>,
    meta: &HashMap<String, SourceMeta>,
    stats: &HashMap<String, ExtractStat>,
    teasers: &HashSet<String>,
    limit: usize,
) -> Vec<NewsItem> {
    let rank = |t: &str| match t {
        "lab" => 0,
        "kr" => 1,
        "press" => 2,
        _ => 3,
    };
    let mut cands: Vec<&NewsItem> = story
        .iter()
        .filter(|s| {
            s.key() != item.key()
                && !hidden.contains(&s.source_id)
                && !s.link.is_empty()
                && s.item_kind() == ItemKind::Article
                && kind(&s.source_id, &s.link, s.paid, teasers.contains(&s.link), meta, stats).is_none()
        })
        .collect();
    cands.sort_by(|a, b| rank(&a.tier).cmp(&rank(&b.tier)).then_with(|| b.date_or_past().cmp(&a.date_or_past())));
    let mut seen: HashSet<String> = HashSet::from([item.source_id.clone()]);
    cands.into_iter().filter(|s| seen.insert(s.source_id.clone())).take(limit).cloned().collect()
}

// 읽기 창이 무료 보도를 먼저 권할 때와 그 이유: 유료로 알려진 곳이거나, 열어 보니 막혔을 때
pub fn free_reason(has_alternatives: bool, failed: bool, paywalled: bool, kind: Option<PaywallKind>) -> Option<&'static str> {
    if !has_alternatives {
        return None;
    }
    if failed {
        return Some("본문을 열지 못했습니다");
    }
    if paywalled {
        return Some("다른 곳 보도로 전체를 읽을 수 있어요"); // 맛보기 안내는 본문 위 띠(TEASER_*)가 따로 맡는다
    }
    match kind {
        Some(PaywallKind::Hard) => Some("유료 기사입니다"),
        Some(PaywallKind::Learned) => Some("이곳 기사는 자주 막힙니다"),
        Some(PaywallKind::Teaser) => Some("앞부분만 공개된 기사예요"),
        _ => None,
    }
}

// 앱 안에서 쓰는 쪽: 출처별 기록을 기억해 두고 화면(자물쇠)·읽기 창(무료 보도 권하기)에 알려 준다
// 맛보기로 판정된 기사(teasers)는 DB 에 남겨 목록·카드·물방울이 열기 전부터 '앞부분만'을 보이게 한다
pub struct PaywallBook {
    db: Arc<Database>,
    stats: Mutex<HashMap<String, ExtractStat>>,
    teasers: Mutex<HashSet<String>>,
}

impl PaywallBook {
    pub fn new(db: Arc<Database>) -> PaywallBook {
        let stats = db.extract_stats();
        let teasers = db.teaser_links(chrono::Utc::now());
        PaywallBook { db, stats: Mutex::new(stats), teasers: Mutex::new(teasers) }
    }

    // 화면 표시용: 맛보기 판정 > 피드의 기사 표시 > 출처 값 > 배운 막힘
    pub fn kind(&self, item: &NewsItem) -> Option<PaywallKind> {
        if item.item_kind() != ItemKind::Article || item.link.is_empty() {
            return None;
        }
        let teaser = self.teasers.lock().unwrap().contains(&item.link);
        kind(&item.source_id, &item.link, item.paid, teaser, &crate::sections::META, &self.stats.lock().unwrap())
    }

    // 맛보기 판정(is_teaser)·읽기 창에 넘기는 값: 지난 판정은 빼고 피드·출처만 본다(다시 받을 때 지난 판정에 끌려가지 않게)
    pub fn source_kind(&self, item: &NewsItem) -> Option<PaywallKind> {
        if item.item_kind() != ItemKind::Article || item.link.is_empty() {
            return None;
        }
        kind(&item.source_id, &item.link, item.paid, false, &crate::sections::META, &self.stats.lock().unwrap())
    }

    pub fn teasers(&self) -> HashSet<String> {
        self.teasers.lock().unwrap().clone()
    }

    // 본문을 받은 기사(미리 받기 포함)의 맛보기 판정을 남긴다 — 맛보기가 아니면 지난 기록을 지운다.
    // 다시 맛보기로 판정되면 시각만 새로 써서 30일·2,000건 정리에서 계속 맛보기인 기사가 빠지지 않게 한다.
    // 돌려주는 값: 화면 표시가 바뀌었나(목록·카드를 다시 그릴지)
    pub fn record_teaser(&self, item: &NewsItem, teaser: bool) -> bool {
        if item.id == crate::app_model::PREVIEW_ID || item.link.is_empty() {
            return false;
        }
        let mut t = self.teasers.lock().unwrap();
        let had = t.contains(&item.link);
        if !teaser && !had {
            return false;
        }
        self.db.mark_teaser(&item.link, teaser, chrono::Utc::now());
        if teaser {
            t.insert(item.link.clone());
        } else {
            t.remove(&item.link);
        }
        teaser != had
    }

    // 사용자가 연 기사의 결과(미리 받기는 스크립트 없이 해서 실패가 잦으므로 세지 않는다)
    pub fn record(&self, item: &NewsItem, failed: bool, blocked: bool) {
        if item.id == crate::app_model::PREVIEW_ID || item.source_id.is_empty() {
            return;
        }
        self.db.record_extract(&item.source_id, failed, blocked);
        *self.stats.lock().unwrap() = self.db.extract_stats();
    }

    // 같은 스토리에서 무료로 읽을 수 있는 보도
    // 지금 보이는 출처(꺼진·지운·숨긴 출처 제외, S-13)의 보도만
    pub fn alternatives(&self, item: &NewsItem, filter: &crate::source_filter::SourceFilter) -> Vec<NewsItem> {
        let Some(c) = self.db.cluster_of(&item.key()) else { return vec![] };
        let story: Vec<NewsItem> = filter.visible(&self.db.items_in_cluster(&c).into_iter().map(|s| s.item).collect::<Vec<_>>());
        let teasers = self.teasers();
        free_alternatives(item, &story, &HashSet::new(), &crate::sections::META, &self.stats.lock().unwrap(), &teasers, 3)
    }
}
