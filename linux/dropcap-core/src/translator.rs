// 한국어 번역. 리눅스에는 무료 기기 내 번역이 없어 Google 번역 공개 엔드포인트(gtx)를 쓴다(T-05 ⊘).
// 설정의 번역 방식(translateEngine — 맥·윈도우와 같은 키·값, mac/TRANSLATE.md)을 따른다:
//  auto·google = Google(기기 내 엔진이 없어 auto 도 Google) · off = 번역 안 함 · apple(맥에서 '기기 내만'으로 고른 기록) = 기기 밖으로 보내지 않음 → 번역 안 함.
// 'Google 로 보내지 않음'이면 기사 본문·배경 제목 번역·같은 소식 묶기용 영어 번역 모두 보내지 않는다. 실패하면 원문을 그대로 돌려준다.
use crate::net;
use futures::future::{join_all, BoxFuture};
use once_cell::sync::Lazy;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

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

// 외국어로 보이는가: 한글이 20% 미만. 글자가 하나도 없거나(숫자·기호뿐) 주소 하나뿐인 글은 번역할 것이 없다(TRANSLATE.md 케이스 8)
pub fn looks_foreign(text: &str) -> bool {
    static URL_ONLY: Lazy<regex::Regex> = Lazy::new(|| regex::Regex::new(r"(?i)^(https?://|www\.)\S+$").unwrap());
    let s: Vec<char> = text.chars().filter(|c| !c.is_whitespace()).collect();
    if s.is_empty() || !s.iter().any(|c| c.is_alphabetic()) {
        return false;
    }
    let trimmed = text.trim();
    if s.len() == trimmed.chars().count() && URL_ONLY.is_match(trimmed) {
        return false;
    }
    let hangul = s.iter().filter(|c| ('\u{AC00}'..='\u{D7A3}').contains(*c)).count();
    (hangul as f64) / (s.len() as f64) < 0.2
}

// 설정 키 translateEngine 의 값
pub const MODES: [&str; 4] = ["auto", "apple", "google", "off"];

pub fn normalize_mode(v: &str) -> &'static str {
    MODES.iter().find(|m| **m == v).copied().unwrap_or("auto") // 모르는 값은 자동(맥·윈도우와 같음)
}

// 이 방식이면 글을 Google 로 보내는가
pub fn sends(mode: &str) -> bool {
    matches!(normalize_mode(mode), "auto" | "google")
}

// 설정 화면의 번역 방식 고르기(윈도우와 같은 차림): 자동·Google·번역 안 함. 맥에서 '기기 내만'을 골라 가져온 기록이면 그 항목도 보인다
pub fn engine_options(current: &str) -> Vec<(&'static str, &'static str)> {
    let mut o = vec![("auto", "자동 (Google 번역)"), ("google", "Google 번역"), ("off", "번역 안 함")];
    if normalize_mode(current) == "apple" {
        o.insert(1, ("apple", "기기 내 번역 (이 컴퓨터에는 없어 번역하지 않음)"));
    }
    o
}

// 번역 방식 아래 안내(개인정보): 무엇이 어디로 가는지
pub fn engine_note(mode: &str) -> &'static str {
    if sends(mode) {
        "Google 번역으로 본문 문단이 전송됩니다(외국어 기사 제목·같은 소식 묶기용 영어 번역 포함). 리눅스에는 무료 기기 내 번역이 없고, Google 공개 엔드포인트는 공식 API 가 아니라 언제든 막힐 수 있습니다."
    } else {
        "아무것도 보내지 않고 외국어 기사·제목을 원문 그대로 보여 줍니다(외국 기사와 한국 기사를 같은 소식으로 묶는 정확도는 조금 낮아집니다)."
    }
}

// Google 번역 응답 크기 상한(번역 결과 JSON 은 작다 — 윈도우 maxBody 2MB 와 같음)
pub const TRANSLATE_MAX_BODY: usize = 2 << 20;

type ModeSource = Box<dyn Fn() -> String + Send + Sync>;
// Google 부르기(글, 목표 언어) — 시험에서 네트워크 없이 바꿔 끼운다
pub type GoogleCall = Arc<dyn Fn(String, String) -> BoxFuture<'static, Option<String>> + Send + Sync>;

pub struct Translator {
    cache: Mutex<HashMap<String, String>>,
    last: Mutex<Engine>,
    mode_source: Mutex<ModeSource>,
    last_mode: Mutex<Option<String>>,
    google_call: Option<GoogleCall>,
}

pub static SHARED: Lazy<Translator> = Lazy::new(|| Translator::with_mode(|| "auto".into()));

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
        Translator::with_mode(|| "auto".into())
    }

    // mode: 번역할 때마다 지금 번역 방식을 읽는 곳(앱은 AppModel 설정, 시험은 바꿔 끼움)
    pub fn with_mode(mode: impl Fn() -> String + Send + Sync + 'static) -> Translator {
        Translator {
            cache: Mutex::new(HashMap::new()),
            last: Mutex::new(Engine::None),
            mode_source: Mutex::new(Box::new(mode)),
            last_mode: Mutex::new(None),
            google_call: None,
        }
    }

    // 시험용: Google 대신 call 을 부른다
    pub fn with_google(mode: impl Fn() -> String + Send + Sync + 'static, call: GoogleCall) -> Translator {
        Translator { google_call: Some(call), ..Translator::with_mode(mode) }
    }

    async fn call(&self, text: &str, target: &str) -> Option<String> {
        match &self.google_call {
            Some(f) => f(text.to_string(), target.to_string()).await,
            None => google(text, target).await,
        }
    }

    pub fn set_mode_source(&self, mode: impl Fn() -> String + Send + Sync + 'static) {
        *self.mode_source.lock().unwrap() = Box::new(mode);
    }

    // 지금 방식. 방식이 바뀌면 캐시를 비운다(앞서 다른 방식으로 한 번역이 섞여 나오지 않게 — TRANSLATE.md 케이스 11)
    pub fn mode(&self) -> &'static str {
        let m = normalize_mode(&(self.mode_source.lock().unwrap())());
        let mut last = self.last_mode.lock().unwrap();
        if last.as_deref().is_some_and(|l| l != m) {
            self.cache.lock().unwrap().clear();
        }
        *last = Some(m.to_string());
        m
    }

    // 지금 방식이 글을 Google 로 보내는가(배경 제목 번역·같은 소식 묶기도 이것으로 가린다)
    pub fn sending(&self) -> bool {
        sends(self.mode())
    }

    pub fn cache_len(&self) -> usize {
        self.cache.lock().unwrap().len()
    }

    // 한국어 제목을 영어로(같은 소식 비교용). 실패하면 None. '번역 안 함'이면 보내지 않는다(None)
    pub async fn to_english(&self, texts: &[String]) -> Vec<Option<String>> {
        if !self.sending() {
            return vec![None; texts.len()];
        }
        join_all(texts.iter().map(|t| self.call(t, "en"))).await
    }

    pub async fn translate(&self, text: &str) -> String {
        let src = text.trim();
        if !looks_foreign(src) {
            return text.to_string();
        }
        self.translate_many(&[src.to_string()]).await.into_iter().next().unwrap_or_else(|| src.to_string())
    }

    pub async fn translate_many(&self, texts: &[String]) -> Vec<String> {
        self.translate_many_reporting(texts).await.0
    }

    // 번역과 함께 '이번 번역에 쓴 엔진'을 돌려준다(T-08 · A-24: 앱 전체에 하나인 last_engine 은 다른 번역이 동시에 돌거나
    // 캐시로 끝나면 틀리게 보였다). 새로 번역했거나 캐시에서 꺼낸 것이 있으면 그 엔진(리눅스는 Google 뿐), 번역할 것이 없으면 None
    pub async fn translate_many_reporting(&self, texts: &[String]) -> (Vec<String>, Engine) {
        if !self.sending() {
            return (texts.to_vec(), Engine::None); // 번역 안 함: 원문 그대로, 아무것도 보내지 않음
        }
        let from_cache = {
            let cache = self.cache.lock().unwrap();
            texts.iter().any(|t| cache.contains_key(t))
        };
        let (out, fresh) = self.translate_many_raw(texts).await;
        (out, if fresh || from_cache { Engine::Google } else { Engine::None })
    }

    // 문단 여러 개를 빈 줄로 이어 한 번에 보내고(요청 수를 줄여 빠르게), 묶음들은 동시에 보낸다.
    // 돌아온 문단 수가 안 맞거나, 수는 맞아도 앞뒤 문단과 엇갈려 보이면(TRANSLATE.md 케이스 10) 그 묶음만 문단별로 다시 보낸다.
    // 결과는 다듬는다(polish: 제목 끝 마침표·이름 되돌림). 순서를 지킨다. (결과, 새로 번역했나)
    async fn translate_many_raw(&self, texts: &[String]) -> (Vec<String>, bool) {
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
            return (result, false);
        }
        let batches = batches(texts, &todo, BATCH_CHARS);
        let jobs = batches.into_iter().map(|batch| async move {
            let sources: Vec<String> = batch.iter().map(|&i| texts[i].replace('\n', " ")).collect();
            if let Some(out) = self.call(&sources.join("\n\n"), "ko").await {
                let parts: Vec<String> = out.split("\n\n").map(|p| p.trim().to_string()).filter(|p| !p.is_empty()).collect();
                if parts.len() == batch.len() && !looks_shifted(&sources, &parts) {
                    return batch.into_iter().zip(parts).collect::<Vec<_>>();
                }
            }
            let mut one = Vec::new();
            for i in batch {
                if let Some(t) = self.call(&texts[i], "ko").await {
                    one.push((i, t));
                }
            }
            one
        });
        let done = join_all(jobs).await;
        for pairs in done {
            for (i, raw) in pairs {
                let t = polish(&texts[i], &raw);
                self.remember(&texts[i], &t);
                result[i] = t;
            }
        }
        *self.last.lock().unwrap() = Engine::Google;
        (result, true)
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

// 한 번에 보낼 수 있는 길이(구글 공개 엔드포인트). 이보다 긴 문단은 문장 단위로 나눠 보내고 이어 붙인다(A-25: 예전엔 뒤가 잘렸다)
pub const REQUEST_LIMIT: usize = 4500;

// 문장 경계(. ! ? 。 ！ ？ 뒤 공백, 줄바꿈)에서 max 글자 이하로 묶는다. 한 문장이 max 보다 길면 그 문장만 max 씩 자른다.
// 이어 붙이면 원문 그대로
pub fn sentence_chunks(text: &str, max: usize) -> Vec<String> {
    if text.chars().count() <= max {
        return vec![text.to_string()];
    }
    // 문장으로 나누기: 끝 표시 다음의 공백까지 그 문장에 붙인다
    let chars: Vec<char> = text.chars().collect();
    let mut sentences: Vec<String> = vec![];
    let mut cur = String::new();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        cur.push(c);
        let ends = (matches!(c, '.' | '!' | '?' | '。' | '！' | '？') && chars.get(i + 1).map(|n| n.is_whitespace()).unwrap_or(true)) || c == '\n';
        if ends {
            while i + 1 < chars.len() && chars[i + 1].is_whitespace() {
                i += 1;
                cur.push(chars[i]);
            }
            sentences.push(std::mem::take(&mut cur));
        }
        i += 1;
    }
    if !cur.is_empty() {
        sentences.push(cur);
    }
    let mut out: Vec<String> = vec![];
    let mut cur = String::new();
    let mut cur_len = 0;
    for s in sentences {
        let n = s.chars().count();
        if n > max {
            if !cur.is_empty() {
                out.push(std::mem::take(&mut cur));
            }
            let sc: Vec<char> = s.chars().collect();
            let mut rest: &[char] = &sc;
            while rest.len() > max {
                out.push(rest[..max].iter().collect());
                rest = &rest[max..];
            }
            cur = rest.iter().collect();
            cur_len = rest.len();
        } else if cur_len + n > max {
            out.push(std::mem::take(&mut cur));
            cur = s;
            cur_len = n;
        } else {
            cur.push_str(&s);
            cur_len += n;
        }
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

pub fn google_url(text: &str, target: &str) -> String {
    let q: String = text.chars().take(REQUEST_LIMIT).collect();
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
    if text.chars().count() <= REQUEST_LIMIT {
        return google_once(text, target).await;
    }
    let mut parts = vec![];
    for chunk in sentence_chunks(text, REQUEST_LIMIT) {
        parts.push(google_once(&chunk, target).await?);
    }
    Some(parts.join(" "))
}

async fn google_once(text: &str, target: &str) -> Option<String> {
    let r = tokio::time::timeout(std::time::Duration::from_secs(15), net::get(&google_url(text, target), &[], TRANSLATE_MAX_BODY)).await.ok()?.ok()?;
    if r.status != 200 {
        return None;
    }
    parse_google(&r.data)
}

// ── 다듬기(번역 결과 후처리, 맥 Translator.polish — TRANSLATE.md 2단계) ──

// 원문 끝에 마침표가 없으면(제목·소제목·목록) 번역 끝 마침표 하나를 뗀다(케이스 3, `...` 는 둠),
// 원문에 영문으로 있는 이름을 엔진이 한글로 음역·직역했으면 영문으로 되돌린다(케이스 2)
pub fn polish(source: &str, translated: &str) -> String {
    let mut t = translated.to_string();
    if let Some(last) = source.trim().chars().last() {
        if !".。!?！？…:;\"”’)".contains(last) {
            let tt = t.trim();
            if tt.ends_with('.') && !tt.ends_with("..") {
                t = tt[..tt.len() - 1].to_string();
            }
        }
    }
    restore_names(source, &t)
}

// 엔진이 잘 음역·직역하는 이름(AI 뉴스에 자주 나오는 것, 맥 nameRules 와 같은 표). 긴 꼴부터 바꾼다. 원문에 그 영문 이름이 낱말로 있을 때만.
// person_clash: 사람 이름 앞부분이 되기도 하는 이름 — 원문에서 그 이름 바로 뒤에 다른 대문자 낱말(제품 이름 아님)이 오면 건드리지 않는다
pub struct NameRule {
    pub latin: &'static str,
    pub variants: &'static [&'static str],
    pub person_clash: bool,
}

pub const NAME_RULES: &[NameRule] = &[
    NameRule { latin: "Claude Code", variants: &["클로드 코드"], person_clash: false },
    NameRule { latin: "Claude Corps", variants: &["클로드 군단", "클로드 코어스", "클로드 코프스", "클로드 코퍼스"], person_clash: false },
    NameRule { latin: "Claude", variants: &["클로드", "클도"], person_clash: true },
    NameRule { latin: "Anthropic", variants: &["앤트로픽", "앤스로픽", "안트로픽", "인류학적"], person_clash: false },
    NameRule { latin: "OpenAI", variants: &["오픈AI", "오픈에이아이", "오픈 AI"], person_clash: false },
    NameRule { latin: "ChatGPT", variants: &["챗GPT", "챗지피티"], person_clash: false },
    NameRule { latin: "Gemini", variants: &["제미니", "제미나이", "쌍둥이자리"], person_clash: false },
    NameRule { latin: "DeepMind", variants: &["딥마인드"], person_clash: false },
    NameRule { latin: "Hugging Face", variants: &["포옹하는 얼굴", "허깅 페이스", "허깅페이스"], person_clash: false },
    NameRule { latin: "Copilot", variants: &["부조종사", "코파일럿"], person_clash: false },
    NameRule { latin: "Perplexity", variants: &["당혹감", "퍼플렉시티"], person_clash: false },
];

pub const PRODUCT_WORDS: &[&str] =
    &["Code", "Corps", "Opus", "Sonnet", "Haiku", "Fable", "Mythos", "Design", "Science", "Security", "Cowork", "Enterprise", "Pro", "Max", "Team", "Ultra", "Flash", "Nano"];

// source 에서 name 이 낱말로(앞뒤가 영문자가 아님) 나오는 자리들의 끝 위치
fn word_ends(source: &str, name: &str) -> Vec<usize> {
    let mut out = vec![];
    let mut from = 0;
    while let Some(k) = source[from..].find(name) {
        let start = from + k;
        let end = start + name.len();
        let before = source[..start].chars().last().is_some_and(|c| c.is_ascii_alphabetic());
        let after = source[end..].chars().next().is_some_and(|c| c.is_ascii_alphabetic());
        if !before && !after {
            out.push(end);
        }
        from = start + 1;
        while !source.is_char_boundary(from) {
            from += 1;
        }
    }
    out
}

// 원문에서 name 바로 뒤에 제품 낱말이 아닌 대문자 낱말이 오는가(예: 사람 이름 'Claude Monet')
pub fn followed_by_other_name(source: &str, name: &str) -> bool {
    word_ends(source, name).into_iter().any(|end| {
        let rest = &source[end..];
        let Some(word) = rest.strip_prefix(' ') else { return false };
        // 맥 정규식 `name ([A-Z][a-z]+)` 과 같은 꼴
        let mut cs = word.chars();
        let Some(first) = cs.next().filter(|c| c.is_ascii_uppercase()) else { return false };
        let lower: String = cs.take_while(|c| c.is_ascii_lowercase()).collect();
        !lower.is_empty() && !PRODUCT_WORDS.contains(&format!("{first}{lower}").as_str())
    })
}

pub fn restore_names(source: &str, translated: &str) -> String {
    let mut t = translated.to_string();
    for r in NAME_RULES {
        if !r.variants.iter().any(|v| t.contains(v)) || word_ends(source, r.latin).is_empty() {
            continue;
        }
        if r.person_clash && followed_by_other_name(source, r.latin) {
            continue;
        }
        let mut vs: Vec<&str> = r.variants.to_vec();
        vs.sort_by_key(|v| std::cmp::Reverse(v.chars().count()));
        for v in vs {
            t = t.replace(v, r.latin);
        }
    }
    t
}

// 묶음 대조(케이스 10): 문단 수는 맞아도 결과가 밀렸는지. 원문 문단에만 있는(앞뒤 원문에는 없는) 영문 낱말·숫자 —
// 번역에도 그대로 남는 것 — 가 제 짝 번역보다 이웃 짝 번역에 더 많이 보이는 문단이 하나라도 있으면 밀린 것으로 본다.
// 맥 점검 표본의 실제 묶음 85개에서 오탐 1, 한 칸 밀림 84/85·가운데부터 밀림 73/83 을 잡았다. 틀리게 의심하면 그 묶음을 문단별로 다시 받을 뿐이다.
pub fn anchors(s: &str) -> std::collections::HashSet<String> {
    static RE: Lazy<regex::Regex> = Lazy::new(|| regex::Regex::new(r"[A-Za-z][A-Za-z0-9]{2,}|\d{2,}").unwrap());
    RE.find_iter(s).map(|m| m.as_str().to_lowercase()).collect()
}

pub fn looks_shifted(sources: &[String], outputs: &[String]) -> bool {
    if sources.len() != outputs.len() || sources.len() < 2 {
        return false;
    }
    let src: Vec<_> = sources.iter().map(|s| anchors(s)).collect();
    let out: Vec<_> = outputs.iter().map(|s| anchors(s)).collect();
    let n = sources.len();
    for k in 0..n {
        let mut own = src[k].clone();
        if k > 0 {
            own.retain(|w| !src[k - 1].contains(w));
        }
        if k + 1 < n {
            own.retain(|w| !src[k + 1].contains(w));
        }
        if own.is_empty() {
            continue;
        }
        let hits = |j: usize| own.iter().filter(|w| out[j].contains(*w)).count();
        let mine = hits(k);
        let next = if k + 1 < n { hits(k + 1) } else { 0 };
        let prev = if k > 0 { hits(k - 1) } else { 0 };
        if next.max(prev) > mine {
            return true;
        }
    }
    false
}
