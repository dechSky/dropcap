// 분야별 알림 정책(맥 Core/NotifyPolicy.swift · docs/research/COMPETITIVE.md (다)-3).
// 매거진에는 전부 싣고, 물방울은 분야 모드·중요도 문턱·하루 상한을 모두 지날 때만 떨어뜨린다.
use crate::sections;
use chrono::{DateTime, Local, Timelike, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum NotifyMode {
    Instant,
    Bundle,
    Magazine,
}

impl NotifyMode {
    pub const ALL: [NotifyMode; 3] = [Self::Instant, Self::Bundle, Self::Magazine];
    pub fn label(self) -> &'static str {
        match self {
            Self::Instant => "즉시",
            Self::Bundle => "묶음",
            Self::Magazine => "매거진만",
        }
    }
    pub fn help(self) -> &'static str {
        match self {
            Self::Instant => "중요한 소식(여러 곳 보도·공식 발표·꼭 알림 낱말·팔로우한 스토리)만 바로 물방울로",
            Self::Bundle => "정한 시각에 한 방울로 모아서(예: 경제 7건)",
            Self::Magazine => "알리지 않고 매거진에만",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct SectionPolicy {
    pub mode: NotifyMode,
    #[serde(rename = "bundleHour")]
    pub bundle_hour: i64, // 묶음을 보내는 시각(시)
    #[serde(rename = "dailyCap")]
    pub daily_cap: i64, // 이 분야에서 하루에 떨어뜨리는 물방울 수
    pub less: bool,     // 카드에서 '이 분야 덜 받기'를 누름 → 주요 뉴스 흐름으로도 바로 떨어뜨리지 않음(즉시로 되돌리면 풀림)
}

impl Default for SectionPolicy {
    fn default() -> Self {
        SectionPolicy { mode: NotifyMode::Bundle, bundle_hour: 18, daily_cap: 3, less: false }
    }
}

impl SectionPolicy {
    pub fn mode(mode: NotifyMode) -> SectionPolicy {
        SectionPolicy { mode, ..Default::default() }
    }
}

// 항목이 없거나 모르는 값이면 기본값(예전 파일·새 값에 안전)
impl<'de> Deserialize<'de> for SectionPolicy {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let v = Value::deserialize(d)?;
        let def = SectionPolicy::default();
        let get = |k: &str| v.get(k).cloned();
        Ok(SectionPolicy {
            mode: get("mode").and_then(|m| serde_json::from_value(m).ok()).unwrap_or(def.mode),
            bundle_hour: get("bundleHour").and_then(|m| m.as_i64()).unwrap_or(def.bundle_hour),
            daily_cap: get("dailyCap").and_then(|m| m.as_i64()).unwrap_or(def.daily_cap),
            less: get("less").and_then(|m| m.as_bool()).unwrap_or(false), // 예전 파일엔 없음 · 예전 판은 이 값을 무시
        })
    }
}

// 같은 소식을 다룬 출처 수(국내·해외)
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Coverage {
    pub kr: i64,
    pub intl: i64,
}
impl Coverage {
    pub fn total(&self) -> i64 {
        self.kr + self.intl
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PolicyLimits {
    pub total_cap: i64,      // 모든 분야를 합친 하루 물방울 수
    pub kr_threshold: i64,   // 국내 n곳 이상이 다루면 중요한 소식
    pub intl_threshold: i64, // 해외 n곳 이상
    pub big_threshold: i64,  // 국내 n곳 이상이면 상한도 넘어 알림
}
impl Default for PolicyLimits {
    fn default() -> Self {
        PolicyLimits { total_cap: 10, kr_threshold: 3, intl_threshold: 2, big_threshold: 8 }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Decision {
    Drop,  // 지금 물방울
    Pool,  // 고였다가 그 분야 묶음 시각에 한 방울
    Quiet, // 매거진에만
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Input {
    pub chosen: bool, // 사용자가 고른 분야인가
    pub policy: SectionPolicy,
    pub coverage: Coverage,
    pub lab: bool,       // 공식 발표 등급(tier lab)
    pub important: bool, // ★ 꼭 알림 낱말
    pub followed: bool,  // 팔로우한 스토리
    pub watched: bool,   // 지켜볼 낱말에 걸림(N-27)
    pub sent_in_section: i64,
    pub sent_total: i64,
}

pub fn crosses(c: Coverage, l: PolicyLimits) -> bool {
    c.kr >= l.kr_threshold || c.intl >= l.intl_threshold
}
pub fn is_big(c: Coverage, l: PolicyLimits) -> bool {
    c.kr >= l.big_threshold
}

pub fn decide(i: &Input, l: PolicyLimits) -> Decision {
    // 지켜볼 낱말: 고른 분야·모드와 상관없이 알린다(같은 이야기는 한 번 — 부르는 쪽이 스토리로 기억). 전체 상한이 차면 고임
    if i.watched {
        return if i.sent_total >= l.total_cap && !is_big(i.coverage, l) { Decision::Pool } else { Decision::Drop };
    }
    if !i.chosen {
        return Decision::Quiet;
    }
    match i.policy.mode {
        NotifyMode::Magazine => Decision::Quiet,
        NotifyMode::Bundle => Decision::Pool,
        NotifyMode::Instant => {
            let worth = crosses(i.coverage, l) || i.lab || i.important || i.followed;
            if !worth {
                return Decision::Quiet;
            }
            let full = i.sent_in_section >= i.policy.daily_cap || i.sent_total >= l.total_cap;
            if full {
                if is_big(i.coverage, l) {
                    Decision::Drop
                } else {
                    Decision::Pool
                }
            } else {
                Decision::Drop
            }
        }
    }
}

// '주요 뉴스' 흐름: 자기 분야에서 떨어지지 않은 소식이라도 문턱을 넘었으면 주요 뉴스 정책으로 한 번 더 본다
pub fn decide_with_top(i: &Input, top: Option<&Input>, l: PolicyLimits) -> (Decision, bool) {
    let own = decide(i, l);
    match top {
        // '덜 받기'한 분야는 주요 뉴스 흐름으로도 떨어뜨리지 않고 자기 정책(묶음·매거진만)대로 둔다
        Some(t) if own != Decision::Drop && !i.policy.less && crosses(i.coverage, l) => {
            let mut t = *t;
            t.coverage = i.coverage;
            if decide(&t, l) == Decision::Drop {
                (Decision::Drop, true)
            } else {
                (own, false)
            }
        }
        _ => (own, false),
    }
}

// 첫 실행 기본값: 고른 분야 중 앞의 두 개만 즉시, 나머지는 묶음(주요 뉴스 흐름은 즉시)
pub fn defaults(chosen: &[String]) -> HashMap<String, SectionPolicy> {
    let mut out = HashMap::new();
    let mut instant = 0;
    for id in chosen {
        if id == sections::TOP {
            out.insert(id.clone(), SectionPolicy::mode(NotifyMode::Instant));
            continue;
        }
        out.insert(id.clone(), SectionPolicy::mode(if instant < 2 { NotifyMode::Instant } else { NotifyMode::Bundle }));
        if instant < 2 {
            instant += 1;
        }
    }
    out
}

// 묶음을 보낼 때인가: 그 분야 묶음 시각이 지났고 오늘(그 시각 뒤에) 아직 안 보냈으면
pub fn bundle_due(hour: i64, now: DateTime<Utc>, last: Option<DateTime<Utc>>) -> bool {
    let n = now.with_timezone(&Local);
    if (n.hour() as i64) < hour {
        return false;
    }
    if let Some(l) = last {
        let l = l.with_timezone(&Local);
        if l.date_naive() == n.date_naive() && (l.hour() as i64) >= hour {
            return false;
        }
    }
    true
}
