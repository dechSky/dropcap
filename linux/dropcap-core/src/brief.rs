// 분야별 저녁 정리(N-26 · D-13) — 맥 Summarizer.briefing · SectionBrief.
// 모드가 '묶음'인 분야는 묶음을 보낼 때 그 묶음 기사(8건까지)의 원제목·요약만 보고 "오늘 이 분야에서 무슨 일이 · 왜" 3줄.
// 줄마다 근거 기사 번호를 달게 하고, 번호 없는 줄·범위 밖 번호는 버린다. 알림 문구는 그대로 원제목(D-7).
// 리눅스의 기기 안 모델은 Ollama(T-06 과 같은 127.0.0.1:11434). 없으면 요약 없이 근거만 남고 매거진에 상자를 띄우지 않는다.
use crate::models::NewsItem;
use chrono::{DateTime, Local, Utc};
use once_cell::sync::Lazy;
use regex::Regex;
use serde::{Deserialize, Serialize};

pub const MAX_ITEMS: usize = 8;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Line {
    pub text: String,
    pub refs: Vec<usize>, // items 의 번호(0부터)
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SectionBrief {
    pub section: String,
    #[serde(with = "crate::iso")]
    pub at: DateTime<Utc>,
    pub items: Vec<NewsItem>, // 근거 기사(원제목·링크)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lines: Option<Vec<Line>>, // 기기 안 모델이 없으면 None — 매거진에는 싣지 않음
}

impl SectionBrief {
    // 오늘 만든 것이고 요약이 있는가(그날만 보인다)
    pub fn shown_on(&self, now: DateTime<Utc>) -> bool {
        self.lines.is_some() && self.at.with_timezone(&Local).date_naive() == now.with_timezone(&Local).date_naive()
    }
}

pub const INSTRUCTIONS: &str = "당신은 뉴스 편집자입니다. 번호가 붙은 기사 제목과 요약만 읽고, 오늘 이 분야에서 무슨 일이 있었고 왜 중요한지 한국어 세 줄로 정리합니다.\n각 줄은 \"- \" 로 시작하는 60자 안팎의 한 문장이고, 줄 끝에 근거가 된 기사 번호를 [1] 이나 [1][3] 처럼 붙입니다.\n기사에 없는 내용·추측·평가는 쓰지 않습니다.";

static SPACES: Lazy<Regex> = Lazy::new(|| Regex::new(r"\s+").unwrap());
static REF: Lazy<Regex> = Lazy::new(|| Regex::new(r"\[(\d+)\]").unwrap());

pub fn prompt(section: &str, items: &[NewsItem]) -> String {
    let mut out = format!("분야: {section}\n");
    for (i, it) in items.iter().enumerate() {
        let ko = match &it.title_ko {
            Some(k) if *k != it.title => format!(" ({k})"),
            _ => String::new(),
        };
        out += &format!("\n[{}] {}{} — {}\n", i + 1, it.title, ko, it.source_name);
        let s: String = SPACES.replace_all(&it.summary, " ").chars().take(300).collect();
        if !s.is_empty() {
            out += &s;
            out += "\n";
        }
    }
    out
}

// 모델 답을 줄로: "- 문장 [1][3]" → (문장, [0, 2]). 근거 번호가 없거나 범위를 벗어난 줄은 버린다(근거 없는 요약은 싣지 않음)
pub fn parse(text: &str, count: usize) -> Option<Vec<Line>> {
    let mut out = vec![];
    for raw in text.split('\n') {
        let line = raw.trim();
        if !(line.starts_with('-') || line.starts_with('•')) {
            continue;
        }
        let body = line.trim_start_matches(|c| c == '-' || c == '•' || c == ' ');
        let mut refs = vec![];
        for c in REF.captures_iter(body) {
            if let Ok(n) = c[1].parse::<usize>() {
                if (1..=count).contains(&n) && !refs.contains(&(n - 1)) {
                    refs.push(n - 1);
                }
            }
        }
        let clean = REF.replace_all(body, "").trim().to_string();
        if refs.is_empty() || clean.is_empty() {
            continue;
        }
        out.push(Line { text: clean, refs });
    }
    if out.is_empty() {
        None
    } else {
        out.truncate(3);
        Some(out)
    }
}

pub async fn briefing(section: &str, items: &[NewsItem]) -> Option<Vec<Line>> {
    if items.len() < 2 {
        return None;
    }
    let content = crate::summarizer::generate(INSTRUCTIONS, &prompt(section, items)).await?;
    parse(&content, items.len())
}
