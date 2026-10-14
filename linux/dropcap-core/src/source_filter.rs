// '지금 보여 줄 출처' 판단 한 곳(S-13 · 맥 Core/SourceFilter.swift): 출처 목록에 있고 · 켜져 있고 · 숨기지 않은 출처의 글만 보인다.
// 구독을 끄거나 지우거나 분야를 빼면 그 출처 글은 목록·안 읽음 수·매거진·스토리·검색·알림 대기열에서 빠지고(지우지 않음),
// 다시 켜면 그대로 돌아온다. 저장한 기사는 사용자가 고른 것이라 이 판단을 받지 않는다.
use crate::models::{NewsItem, Source};
use crate::store::AppState;
use std::collections::HashSet;

#[derive(Debug, Clone, Default, PartialEq)]
pub struct SourceFilter {
    pub hidden: HashSet<String>,
    pub active: Option<HashSet<String>>, // None 이면 켜짐 여부를 따지지 않음(시험·예전 호 옮기기)
}

impl SourceFilter {
    pub fn hidden_only(hidden: impl IntoIterator<Item = String>) -> SourceFilter {
        SourceFilter { hidden: hidden.into_iter().collect(), active: None }
    }

    pub fn shows(&self, source_id: &str) -> bool {
        !self.hidden.contains(source_id) && self.active.as_ref().map(|a| a.contains(source_id)).unwrap_or(true)
    }

    pub fn visible(&self, items: &[NewsItem]) -> Vec<NewsItem> {
        items.iter().filter(|i| self.shows(&i.source_id)).cloned().collect()
    }

    // 앱 상태와 출처 목록으로 만든다(순수 함수 — 시험에서 그대로 씀)
    pub fn make(state: &AppState, sources: &[Source]) -> SourceFilter {
        let hidden: HashSet<String> = state.hidden_sources.iter().cloned().collect();
        let on: HashSet<String> = sources.iter().map(|s| s.id.clone()).filter(|id| state.enabled.get(id) == Some(&true) && !hidden.contains(id)).collect();
        SourceFilter { hidden, active: Some(on) }
    }
}
