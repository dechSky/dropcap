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

pub fn kind(source_id: &str, link: &str, meta: &HashMap<String, SourceMeta>, stats: &HashMap<String, ExtractStat>) -> Option<PaywallKind> {
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

pub fn looks_blocked(blocks: &[Block]) -> bool {
    let texts: Vec<&str> = blocks.iter().filter_map(|b| b.text.as_deref()).collect();
    let length: usize = texts.iter().map(|t| t.chars().count()).sum();
    if length >= TEASER_CHARS {
        return false; // 본문이 충분하면 끝의 구독 안내 문구는 무시
    }
    let lower = texts.join(" ").to_lowercase();
    WALL_PHRASES.iter().any(|p| lower.contains(p))
}

// 같은 소식 중 열리는 보도: 유료가 아니고(배운 막힘 포함), 숨긴 출처가 아니고, 자기 자신이 아닌 것.
// 출처마다 하나, 공식 발표 > 국내 > 언론, 최신 순, limit 개까지
pub fn free_alternatives(
    item: &NewsItem,
    story: &[NewsItem],
    hidden: &HashSet<String>,
    meta: &HashMap<String, SourceMeta>,
    stats: &HashMap<String, ExtractStat>,
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
                && kind(&s.source_id, &s.link, meta, stats).is_none()
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
        return Some("구독자만 읽을 수 있는 기사입니다");
    }
    match kind {
        Some(PaywallKind::Hard) => Some("유료 기사입니다"),
        Some(PaywallKind::Learned) => Some("이곳 기사는 자주 막힙니다"),
        _ => None,
    }
}

// 앱 안에서 쓰는 쪽: 출처별 기록을 기억해 두고 화면(자물쇠)·읽기 창(무료 보도 권하기)에 알려 준다
pub struct PaywallBook {
    db: Arc<Database>,
    stats: Mutex<HashMap<String, ExtractStat>>,
}

impl PaywallBook {
    pub fn new(db: Arc<Database>) -> PaywallBook {
        let stats = db.extract_stats();
        PaywallBook { db, stats: Mutex::new(stats) }
    }

    pub fn kind(&self, item: &NewsItem) -> Option<PaywallKind> {
        if item.item_kind() != ItemKind::Article || item.link.is_empty() {
            return None;
        }
        kind(&item.source_id, &item.link, &crate::sections::META, &self.stats.lock().unwrap())
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
        free_alternatives(item, &story, &HashSet::new(), &crate::sections::META, &self.stats.lock().unwrap(), 3)
    }
}
