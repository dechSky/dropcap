// 출처 건강(맥 FeedService.swift 의 SourceHealth): 마지막 성공 시각·마지막 새 글 시각·연속 실패 수.
// 설정의 출처 줄에 '조용함·멈춤·오류'로 보인다. 상태 파일과 따로 source-health.json(없거나 깨지면 빈 기록으로 시작).
use crate::iso;
use chrono::{DateTime, Utc};
use once_cell::sync::Lazy;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct SourceHealth {
    #[serde(rename = "lastSuccess", default, with = "iso::opt", skip_serializing_if = "Option::is_none")]
    pub last_success: Option<DateTime<Utc>>,
    #[serde(rename = "lastNew", default, with = "iso::opt", skip_serializing_if = "Option::is_none")]
    pub last_new: Option<DateTime<Utc>>, // 피드에서 가장 새 글의 시각(날짜 없는 피드는 맨 위 글이 바뀐 시각)
    #[serde(default)]
    pub failures: i64, // 연속 실패 수(성공하면 0)
    #[serde(rename = "lastError", default, skip_serializing_if = "Option::is_none")]
    pub last_error: Option<String>,
    #[serde(rename = "topID", default, skip_serializing_if = "Option::is_none")]
    pub top_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub count: Option<i64>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Status {
    Unknown,
    Ok,
    Quiet(i64),   // n일째 새 글 없음
    Stalled(i64), // 오래 새 글이 없음
    Empty,
    Failing(i64, String),
}

pub const QUIET_DAYS: i64 = 3;
pub const STALLED_DAYS: i64 = 30;
pub const FAILING_AFTER: i64 = 3;

impl SourceHealth {
    pub fn status(&self, now: DateTime<Utc>) -> Status {
        if self.failures >= FAILING_AFTER {
            return Status::Failing(self.failures, self.last_error.clone().unwrap_or_default());
        }
        if self.last_success.is_none() {
            return if self.failures > 0 { Status::Failing(self.failures, self.last_error.clone().unwrap_or_default()) } else { Status::Unknown };
        }
        if self.count == Some(0) {
            return Status::Empty;
        }
        let Some(last_new) = self.last_new else { return Status::Ok };
        let days = (now - last_new).num_seconds() / 86400;
        if days >= STALLED_DAYS {
            Status::Stalled(days)
        } else if days >= QUIET_DAYS {
            Status::Quiet(days)
        } else {
            Status::Ok
        }
    }

    pub fn success(&mut self, newest: Option<DateTime<Utc>>, top_id: Option<String>, count: i64, now: DateTime<Utc>) {
        self.last_success = Some(now);
        self.failures = 0;
        self.last_error = None;
        self.count = Some(count);
        if let Some(n) = newest {
            if self.last_new.map(|l| n > l).unwrap_or(true) {
                self.last_new = Some(n);
            }
        }
        if newest.is_none() {
            if let Some(t) = &top_id {
                if self.top_id.as_ref() != Some(t) {
                    self.last_new = Some(now); // 날짜 없는 피드: 맨 위 글이 바뀌면 새 글
                }
            }
        }
        if top_id.is_some() {
            self.top_id = top_id;
        }
    }

    pub fn failure(&mut self, message: &str) {
        self.failures += 1;
        self.last_error = Some(message.to_string());
    }
}

pub fn status_text(s: &Status) -> Option<String> {
    match s {
        Status::Unknown | Status::Ok => None,
        Status::Quiet(d) => Some(format!("{d}일째 새 글 없음")),
        Status::Stalled(d) => Some(format!("{d}일째 새 글 없음 · 주소가 바뀌었을 수 있음")),
        Status::Empty => Some("글이 없음".into()),
        Status::Failing(n, m) => Some(format!("{n}번 연속 실패: {m}")),
    }
}

pub struct HealthBook {
    file: PathBuf,
    records: Mutex<HashMap<String, SourceHealth>>,
    dirty: AtomicBool,
}

impl HealthBook {
    pub fn open(file: PathBuf) -> HealthBook {
        let records = std::fs::read(&file).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default();
        HealthBook { file, records: Mutex::new(records), dirty: AtomicBool::new(false) }
    }
    pub fn status(&self, id: &str, now: DateTime<Utc>) -> Status {
        self.records.lock().unwrap().get(id).map(|r| r.status(now)).unwrap_or(Status::Unknown)
    }
    pub fn record_success(&self, id: &str, newest: Option<DateTime<Utc>>, top_id: Option<String>, count: i64, now: DateTime<Utc>) {
        self.records.lock().unwrap().entry(id.into()).or_default().success(newest, top_id, count, now);
        self.dirty.store(true, Ordering::SeqCst);
    }
    // 304(바뀐 것 없음)도 성공이다. 새 글 시각은 그대로.
    pub fn record_unchanged(&self, id: &str, now: DateTime<Utc>) {
        let mut m = self.records.lock().unwrap();
        let r = m.entry(id.into()).or_default();
        r.last_success = Some(now);
        r.failures = 0;
        r.last_error = None;
        self.dirty.store(true, Ordering::SeqCst);
    }
    pub fn record_failure(&self, id: &str, error: &str) {
        self.records.lock().unwrap().entry(id.into()).or_default().failure(error);
        self.dirty.store(true, Ordering::SeqCst);
    }
    // 한 번 확인에 출처 수십 곳이 기록하므로 확인이 끝났을 때 모아서 쓴다
    pub fn save_if_dirty(&self) {
        if !self.dirty.swap(false, Ordering::SeqCst) {
            return;
        }
        if let Ok(d) = serde_json::to_vec(&*self.records.lock().unwrap()) {
            let _ = crate::store::write_atomic(&self.file, &d);
        }
    }
}

pub static BOOK: Lazy<HealthBook> = Lazy::new(|| HealthBook::open(crate::store::DIR.join("source-health.json")));
