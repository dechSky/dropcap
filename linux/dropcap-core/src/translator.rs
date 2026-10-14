// 한국어 번역. 리눅스에는 무료 기기 내 번역이 없어 Google 번역 공개 엔드포인트(gtx)를 쓴다(T-05 ⊘).
// 실패하면 원문을 그대로 돌려준다.
use crate::net::{self, MAX_BODY};
use futures::future::join_all;
use once_cell::sync::Lazy;
use std::collections::HashMap;
use std::sync::Mutex;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Engine {
    Google,
    None,
}

impl Engine {
    pub fn label(self) -> &'static str {
        match self {
            Engine::Google => "Google 번역",
            Engine::None => "번역 안 함",
        }
    }
}

pub fn looks_foreign(text: &str) -> bool {
    let s: Vec<char> = text.chars().filter(|c| !c.is_whitespace()).collect();
    if s.is_empty() {
        return false;
    }
    let hangul = s.iter().filter(|c| ('\u{AC00}'..='\u{D7A3}').contains(*c)).count();
    (hangul as f64) / (s.len() as f64) < 0.2
}

pub struct Translator {
    cache: Mutex<HashMap<String, String>>,
    last: Mutex<Engine>,
}

pub static SHARED: Lazy<Translator> = Lazy::new(|| Translator { cache: Mutex::new(HashMap::new()), last: Mutex::new(Engine::None) });

pub const CACHE_LIMIT: usize = 4000;
pub const BATCH_CHARS: usize = 3800;

impl Translator {
    pub fn last_engine(&self) -> Engine {
        *self.last.lock().unwrap()
    }

    // 오래 켜 둬도 무한히 커지지 않게 4000개에 닿으면 비운다(기사 본문 번역도 여기로 모이므로 이 한 곳에서 지킨다)
    pub fn remember(&self, source: &str, translated: &str) {
        let mut c = self.cache.lock().unwrap();
        if c.len() >= CACHE_LIMIT {
            c.clear();
        }
        c.insert(source.to_string(), translated.to_string());
    }

    pub fn new_for_test() -> Translator {
        Translator { cache: Mutex::new(HashMap::new()), last: Mutex::new(Engine::None) }
    }

    pub fn cache_len(&self) -> usize {
        self.cache.lock().unwrap().len()
    }

    // 한국어 제목을 영어로(같은 소식 비교용). 실패하면 None.
    pub async fn to_english(&self, texts: &[String]) -> Vec<Option<String>> {
        join_all(texts.iter().map(|t| google(t, "en"))).await
    }

    pub async fn translate(&self, text: &str) -> String {
        let src = text.trim();
        if !looks_foreign(src) {
            return text.to_string();
        }
        self.translate_many(&[src.to_string()]).await.into_iter().next().unwrap_or_else(|| src.to_string())
    }

    // 문단 여러 개를 빈 줄로 이어 한 번에 보내고(요청 수를 줄여 빠르게), 묶음들은 동시에 보낸다.
    // 돌아온 문단 수가 안 맞으면 그 묶음만 문단별로 다시 보낸다. 순서를 지킨다.
    pub async fn translate_many(&self, texts: &[String]) -> Vec<String> {
        let mut result = texts.to_vec();
        let todo: Vec<usize> = {
            let cache = self.cache.lock().unwrap();
            for (i, t) in texts.iter().enumerate() {
                if let Some(c) = cache.get(t) {
                    result[i] = c.clone();
                }
            }
            (0..texts.len()).filter(|&i| looks_foreign(&texts[i]) && !cache.contains_key(&texts[i])).collect()
        };
        if todo.is_empty() {
            return result;
        }
        let batches = batches(texts, &todo, BATCH_CHARS);
        let jobs = batches.into_iter().map(|batch| async move {
            let joined = batch.iter().map(|&i| texts[i].replace('\n', " ")).collect::<Vec<_>>().join("\n\n");
            if let Some(out) = google(&joined, "ko").await {
                let parts: Vec<String> = out.split("\n\n").map(|p| p.trim().to_string()).filter(|p| !p.is_empty()).collect();
                if parts.len() == batch.len() {
                    return batch.into_iter().zip(parts).collect::<Vec<_>>();
                }
            }
            let mut one = Vec::new();
            for i in batch {
                if let Some(t) = google(&texts[i], "ko").await {
                    one.push((i, t));
                }
            }
            one
        });
        let done = join_all(jobs).await;
        for pairs in done {
            for (i, t) in pairs {
                self.remember(&texts[i], &t);
                result[i] = t;
            }
        }
        *self.last.lock().unwrap() = Engine::Google;
        result
    }
}

// 3800자 묶음으로 나누기(문단 사이 빈 줄 2자 포함)
pub fn batches(texts: &[String], todo: &[usize], limit: usize) -> Vec<Vec<usize>> {
    let mut out: Vec<Vec<usize>> = vec![vec![]];
    let mut size = 0;
    for &i in todo {
        let n = texts[i].chars().count();
        if size + n > limit && !out.last().unwrap().is_empty() {
            out.push(vec![]);
            size = 0;
        }
        out.last_mut().unwrap().push(i);
        size += n + 2;
    }
    out.retain(|b| !b.is_empty());
    out
}

pub fn google_url(text: &str, target: &str) -> String {
    let q: String = text.chars().take(4500).collect();
    let mut u = url::Url::parse("https://translate.googleapis.com/translate_a/single").unwrap();
    u.query_pairs_mut()
        .append_pair("client", "gtx")
        .append_pair("sl", "auto")
        .append_pair("tl", target)
        .append_pair("dt", "t")
        .append_pair("q", &q);
    u.to_string()
}

pub fn parse_google(data: &[u8]) -> Option<String> {
    let json: serde_json::Value = serde_json::from_slice(data).ok()?;
    let segs = json.as_array()?.first()?.as_array()?;
    let out: String = segs.iter().filter_map(|s| s.as_array()?.first()?.as_str().map(|s| s.to_string())).collect();
    if out.is_empty() {
        None
    } else {
        Some(out)
    }
}

async fn google(text: &str, target: &str) -> Option<String> {
    let r = tokio::time::timeout(std::time::Duration::from_secs(15), net::get(&google_url(text, target), &[], MAX_BODY)).await.ok()?.ok()?;
    if r.status != 200 {
        return None;
    }
    parse_google(&r.data)
}
