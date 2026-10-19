// 같은 소식인가(맥 AppModel.swift 의 StoryMatch 와 같은 낱말 규칙).
// 맥은 영어 제목의 '뜻'을 기기 내 문장 임베딩(NLEmbedding)으로 비교한다. 리눅스에는 같은 기능이 없어
// 윈도우와 같은 기준으로 영어 제목의 고유명사를 2개 이상 함께 쓰고,
// 그 수가 적은 쪽 고유명사의 절반 이상이면 같은 소식으로 본다(맥 시험 사례 동일 결과).
use crate::models::NewsItem;
use crate::translator::looks_foreign;
use std::collections::HashSet;

const STOP: [&str; 26] = [
    "the", "and", "for", "with", "its", "new", "into", "from", "that", "this", "are", "has", "how", "what", "why", "will", "your", "you", "our",
    "says", "after", "over", "more", "than", "about", "now",
];

fn is_hangul(c: char) -> bool {
    ('\u{AC00}'..='\u{D7A3}').contains(&c)
}

pub fn tokens(title: &str) -> HashSet<String> {
    let lowered = title.to_lowercase();
    lowered
        .split(|c: char| !c.is_alphanumeric())
        .filter(|p| {
            let n = p.chars().count();
            (n >= 3 && !STOP.contains(p)) || (n >= 2 && p.chars().any(is_hangul))
        })
        .map(|s| s.to_string())
        .collect()
}

pub fn similar(a: &HashSet<String>, b: &HashSet<String>) -> bool {
    if a.len() < 3 || b.len() < 3 {
        return false;
    }
    let inter = a.intersection(b).count();
    inter as f64 / a.len().min(b.len()) as f64 >= 0.6 && inter >= 3
}

pub fn same(a: &NewsItem, b: &NewsItem) -> bool {
    if a.source_id == b.source_id {
        return false; // 한 곳이 같은 소식을 두 번 내는 일은 드물다
    }
    if similar(&tokens(&a.title), &tokens(&b.title)) {
        return true;
    }
    if similar(&tokens(a.title_ko.as_deref().unwrap_or(&a.title)), &tokens(b.title_ko.as_deref().unwrap_or(&b.title))) {
        return true;
    }
    let ea = a.title_en.clone().or_else(|| looks_foreign(&a.title).then(|| a.title.clone()));
    let eb = b.title_en.clone().or_else(|| looks_foreign(&b.title).then(|| b.title.clone()));
    match (ea, eb) {
        (Some(ea), Some(eb)) => meaning_close(&ea, &eb),
        _ => false,
    }
}

// 뜻 비교의 대체: 고유명사 2개 이상 공유 + 적은 쪽의 절반 이상. 고유명사는 제목마다 한 번만 뽑는다(쌍마다 다시 계산하지 않음).
pub fn meaning_close(a: &str, b: &str) -> bool {
    meaning_close_sets(&entities(a), &entities(b))
}

pub fn meaning_close_sets(ea: &HashSet<String>, eb: &HashSet<String>) -> bool {
    let shared = ea.intersection(eb).count();
    let smaller = ea.len().min(eb.len());
    shared >= 2 && (shared as f64) >= (smaller as f64) / 2.0
}

// 고유명사: 영어 제목은 낱말마다 첫 글자를 대문자로 쓰는 일이 많아(Title Case) '대문자로 시작'만으로는 'Global' 같은
// 흔한 말까지 잡혀 다른 소식이 묶였다(맥 최신 규칙). 그래서 ① NVIDIA·OpenAI·GPT-6 처럼 대문자 약어·대소문자 섞임·숫자가 든 낱말
// ② Title Case 가 아닌 제목에서 대문자로 시작하는 낱말(첫 낱말 포함)만 고유명사로 본다.
// (맥은 여기에 문장 분석기(NLTagger)가 사람·조직·장소로 본 이름을 더한다 — 리눅스에는 없어 ①②만)
// 제목마다 한 번만 계산해 기억한다(쌍마다 다시 계산하지 않게, 추가 지시 2).
static ENTITY_CACHE: once_cell::sync::Lazy<std::sync::Mutex<std::collections::HashMap<String, HashSet<String>>>> =
    once_cell::sync::Lazy::new(|| std::sync::Mutex::new(std::collections::HashMap::new()));

pub fn entities(s: &str) -> HashSet<String> {
    if let Some(e) = ENTITY_CACHE.lock().unwrap().get(s) {
        return e.clone();
    }
    let e = find_entities(s);
    let mut c = ENTITY_CACHE.lock().unwrap();
    if c.len() > 5000 {
        c.clear();
    }
    c.insert(s.to_string(), e.clone());
    e
}

fn find_entities(s: &str) -> HashSet<String> {
    const COMMON: [&str; 28] = [
        "ai", "si", "the", "a", "an", "new", "how", "why", "what", "its", "it", "this", "that", "in", "on", "for", "with", "and", "is", "are", "to", "of",
        "by", "use", "ceo", "us", "uk", "eu",
    ];
    let mut out = HashSet::new();
    let words: Vec<&str> = s.split(|c: char| !(c.is_alphabetic() || c.is_ascii_digit() || c == '-')).filter(|w| !w.is_empty()).collect();
    for w in &words {
        let letters: Vec<char> = w.chars().filter(|c| c.is_alphabetic()).collect();
        let caps = letters.iter().filter(|c| c.is_uppercase()).count();
        let first = w.chars().next().unwrap();
        let acronym = letters.len() >= 2 && caps == letters.len();
        let mixed = (caps >= 2 && caps < letters.len() && first.is_uppercase()) || (first.is_lowercase() && caps >= 1);
        let digits = w.chars().any(|c| c.is_ascii_digit()) && w.chars().any(|c| c.is_alphabetic());
        if acronym || mixed || digits {
            out.insert(w.to_lowercase());
        }
    }
    let long: Vec<&&str> = words.iter().filter(|w| w.chars().count() >= 3 && w.chars().next().map(|c| c.is_alphabetic()).unwrap_or(false)).collect();
    let title_case = !long.is_empty() && long.iter().filter(|w| w.chars().next().unwrap().is_uppercase()).count() as f64 / long.len() as f64 > 0.6;
    if !title_case {
        // 문장 분석기 대신: Title Case 가 아닌 제목의 첫 낱말이 대문자면 이름일 가능성이 높다(Meta·Amazon 등)
        if let Some(w) = words.first() {
            if w.chars().count() >= 3 && w.chars().next().map(|c| c.is_uppercase()).unwrap_or(false) {
                out.insert(w.to_lowercase());
            }
        }
        for w in words.iter().skip(1) {
            if w.chars().count() >= 3 && w.chars().next().map(|c| c.is_uppercase()).unwrap_or(false) {
                out.insert(w.to_lowercase());
            }
        }
    }
    out.retain(|w| !COMMON.contains(&w.as_str()));
    out
}
