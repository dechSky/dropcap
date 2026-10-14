// 지켜볼 낱말(N-27 · D-6 · 맥 Core/WatchWords.swift): 회사·인물·법안 이름을 적어 두면 그 낱말이 든 소식은 스토리마다 한 번 알리고,
// 하루 한 번(아침 브리핑 시각) "오늘 ○○ 소식 3건" 정리 물방울을 띄운다. 누르면 매거진 검색 결과.
// 영어 낱말은 낱말 경계로(Apple 이 pineapple 에, GPT-6 이 GPT-60 에 걸리지 않게), 한국어·일본어·중국어는 조사가 붙으므로 부분 일치.
use crate::models::NewsItem;
use std::collections::HashSet;

// 앞뒤 공백을 떼고, 빈 것·대소문자만 다른 것은 한 번만(적은 순서 유지)
pub fn normalized(list: &[String]) -> Vec<String> {
    let mut out: Vec<String> = vec![];
    for w in list.iter().map(|w| w.trim()) {
        if !w.is_empty() && !out.iter().any(|o| o.to_lowercase() == w.to_lowercase()) {
            out.push(w.to_string());
        }
    }
    out
}

fn cjk(c: char) -> bool {
    ('가'..='힣').contains(&c) || ('ぁ'..='ん').contains(&c) || ('ァ'..='ン').contains(&c) || ('一'..='龥').contains(&c)
}

pub fn matches(word: &str, text: &str) -> bool {
    let w = word.to_lowercase();
    let t = text.to_lowercase();
    if w.is_empty() {
        return false;
    }
    if w.chars().any(cjk) {
        return t.contains(&w);
    }
    // 낱말 경계: 앞뒤 글자가 글자·숫자가 아니어야 한다
    let mut start = 0;
    while let Some(pos) = t[start..].find(&w) {
        let a = start + pos;
        let b = a + w.len();
        let before = t[..a].chars().next_back();
        let after = t[b..].chars().next();
        if !before.map(|c| c.is_alphanumeric()).unwrap_or(false) && !after.map(|c| c.is_alphanumeric()).unwrap_or(false) {
            return true;
        }
        start = a + t[a..].chars().next().map(|c| c.len_utf8()).unwrap_or(1);
    }
    false
}

fn text_of(it: &NewsItem) -> String {
    format!("{} {} {}", it.title, it.title_ko.as_deref().unwrap_or(""), it.summary)
}

// 걸린 첫 낱말(적은 순서)
pub fn first_match(it: &NewsItem, words: &[String]) -> Option<String> {
    let text = text_of(it);
    words.iter().find(|w| matches(w, &text)).cloned()
}

// 하루 정리: 낱말마다 걸린 기사(같은 기사는 한 번, 최신 순). 걸린 것이 없는 낱말은 뺀다
pub fn digest(items: &[NewsItem], words: &[String]) -> Vec<(String, Vec<NewsItem>)> {
    let mut sorted: Vec<&NewsItem> = items.iter().collect();
    sorted.sort_by(|a, b| b.date_or_past().cmp(&a.date_or_past()));
    words
        .iter()
        .filter_map(|w| {
            let mut seen = HashSet::new();
            let hit: Vec<NewsItem> = sorted.iter().filter(|it| matches(w, &text_of(it)) && seen.insert(it.key())).map(|it| (*it).clone()).collect();
            (!hit.is_empty()).then(|| (w.clone(), hit))
        })
        .collect()
}
