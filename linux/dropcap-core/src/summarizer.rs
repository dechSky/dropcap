// 기사 3줄 요약. 리눅스는 이 컴퓨터에 Ollama 가 설치돼 돌고 있으면 그걸로 만든다(T-06).
// 안전(S 절)의 예외: 바깥 주소가 아니라 고정된 이 주소(http://127.0.0.1:11434)만, 안전 검사 없는 별도 클라이언트로 부른다.
// 피드에서 온 주소가 이 클라이언트로 가는 길은 없다. 없으면 None → 읽기 창이 요약 상자를 숨긴다.
use once_cell::sync::Lazy;
use serde_json::json;
use std::sync::Mutex;
use std::time::{Duration, Instant};

pub const OLLAMA: &str = "http://127.0.0.1:11434";

static LOCAL: Lazy<reqwest::Client> = Lazy::new(|| {
    reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none()) // 다른 곳으로 넘기지 않는다
        .timeout(Duration::from_secs(120))
        .build()
        .unwrap()
});

// (모델 이름, 확인 시각) — 1분 기억
static MODEL: Lazy<Mutex<Option<(Option<String>, Instant)>>> = Lazy::new(|| Mutex::new(None));

pub const INSTRUCTIONS: &str = "당신은 뉴스 편집자입니다. 기사를 읽고 핵심만 한국어로 세 줄 요약합니다.\n각 줄은 \"- \" 로 시작하고 60자 안팎의 한 문장입니다. 기사에 없는 내용은 쓰지 않습니다.";

// 쓸 모델: DROPCAP_OLLAMA_MODEL 이 있으면 그것, 없으면 설치된 것 중 첫 번째(임베딩 전용 제외)
pub async fn model() -> Option<String> {
    if let Some((m, at)) = MODEL.lock().unwrap().clone() {
        if at.elapsed() < Duration::from_secs(60) {
            return m;
        }
    }
    let found = async {
        let r = LOCAL.get(format!("{OLLAMA}/api/tags")).timeout(Duration::from_secs(2)).send().await.ok()?;
        let v: serde_json::Value = r.json().await.ok()?;
        let names: Vec<String> = v["models"].as_array()?.iter().filter_map(|m| m["name"].as_str().map(|s| s.to_string())).collect();
        if let Ok(want) = std::env::var("DROPCAP_OLLAMA_MODEL") {
            return names.iter().find(|n| (**n == want || n.starts_with(&format!("{want}:"))) && local_text_model(n)).cloned();
        }
        // 임베딩 전용과 Ollama 클라우드 모델(이름에 cloud — 글을 바깥 서버로 보냄)은 빼고, 이 컴퓨터에서 도는 것만
        names.into_iter().find(|n| local_text_model(n))
    }
    .await;
    *MODEL.lock().unwrap() = Some((found.clone(), Instant::now()));
    found
}

// 요약에 쓸 수 있는 이 컴퓨터 안의 글 모델인가(임베딩 전용·클라우드 모델 제외)
pub fn local_text_model(name: &str) -> bool {
    let n = name.to_lowercase();
    !n.contains("embed") && !n.contains("cloud")
}

pub async fn available() -> bool {
    model().await.is_some()
}

pub fn status_text(model: &Option<String>) -> String {
    match model {
        Some(m) => format!("Ollama({m})로 이 컴퓨터 안에서 요약합니다."),
        None => "Ollama 가 없어 3줄 요약을 숨깁니다. ollama.com 에서 설치하고 모델을 하나 받으면 켜집니다.".into(),
    }
}

pub fn body(paragraphs: &[String]) -> String {
    let mut body = String::new();
    for p in paragraphs {
        if body.chars().count() >= 6000 {
            break;
        }
        body.push_str(p);
        body.push('\n');
    }
    body
}

// 모델 답에서 "- " 줄만 3개까지
pub fn parse_lines(content: &str) -> Option<Vec<String>> {
    let lines: Vec<String> = content
        .lines()
        .map(|l| l.trim())
        .filter(|l| l.starts_with('-') || l.starts_with('•'))
        .map(|l| l.trim_start_matches(|c| c == '-' || c == '•' || c == ' ').to_string())
        .filter(|l| !l.is_empty())
        .take(3)
        .collect();
    if lines.is_empty() {
        None
    } else {
        Some(lines)
    }
}

pub async fn summarize(title: &str, paragraphs: &[String]) -> Option<Vec<String>> {
    let body = body(paragraphs);
    if body.chars().count() <= 200 {
        return None;
    }
    parse_lines(&generate(INSTRUCTIONS, &format!("제목: {title}\n\n본문:\n{body}")).await?)
}

// 이 컴퓨터의 Ollama 에 한 번 묻기(요약·저녁 정리가 같이 쓴다). 모델이 없으면 None
pub async fn generate(system: &str, prompt: &str) -> Option<String> {
    let model = model().await?;
    let req = json!({
        "model": model,
        "stream": false,
        "system": system,
        "prompt": prompt,
        "options": {"temperature": 0.2}
    });
    let r = LOCAL.post(format!("{OLLAMA}/api/generate")).json(&req).send().await.ok()?;
    let v: serde_json::Value = r.json().await.ok()?;
    v["response"].as_str().map(|s| s.to_string())
}
