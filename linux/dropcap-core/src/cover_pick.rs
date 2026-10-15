// 읽기 창 표지 사진 고르기(맥 Reader/CoverPick.swift · ReaderModel.findCover):
// - 피드 사진 → 매거진 기록 → 기사 머리 대표 사진(og:image) 차례
// - 피드 사진이 작은 미리보기(가로 400px 미만)거나 못 받는 사진이면 기사 머리 대표 사진으로 바꾸고, 대신할 것도 없으면 깨진 자리를 지운다
// - 기사 머리 대표 사진을 찾을 때 og:image:type("image/jpeg")을 사진 주소로 잡지 않게 <meta …> 를 하나씩 떼어 읽는다
use std::collections::HashMap;

pub const MIN_WIDTH: u32 = 400;
const MAX_TAG: usize = 2000;
const MAX_TAGS: usize = 2000;
const HEAD_LIMIT: usize = 200_000;

pub fn big_enough(width: u32) -> bool {
    width >= MIN_WIDTH
}

// "<name" 으로 시작하는 꼬리표들의 속성 부분(이름 뒤 ~ '>' 앞, 맥 HTMLScan.tags). 이름이 더 긴 꼬리표(<metadata)는 건너뛴다.
// '>' 전에 '<' 가 나오면 닫히지 않은 꼬리표라 거기서 끊는다(조각이 겹쳐 같은 글을 되풀이해 읽지 않게)
pub fn tags(name: &str, html: &str) -> Vec<String> {
    let lower = html.to_ascii_lowercase(); // 바이트 위치가 그대로
    let open = format!("<{}", name.to_ascii_lowercase());
    let mut out = vec![];
    let mut from = 0;
    while out.len() < MAX_TAGS {
        let Some(p) = lower[from..].find(&open) else { break };
        let start = from + p + open.len();
        from = start;
        let rest = &html[start..];
        if let Some(c) = rest.chars().next() {
            if c.is_alphanumeric() || matches!(c, '-' | '_' | ':') {
                continue;
            }
        }
        let mut end = rest.len().min(MAX_TAG);
        while !rest.is_char_boundary(end) {
            end -= 1;
        }
        let window = &rest[..end];
        let stop = window.find(['>', '<']).unwrap_or(window.len());
        out.push(window[..stop].to_string());
    }
    out
}

// 꼬리표 안 속성 값(따옴표 " ' 또는 없음). data-content 같은 긴 이름은 content 로 보지 않는다(맥 HTMLScan.attr)
pub fn attr(tag: &str, name: &str) -> Option<String> {
    let s: Vec<char> = tag.chars().collect();
    let n: Vec<char> = name.to_lowercase().chars().collect();
    if n.is_empty() {
        return None;
    }
    let space = |c: char| matches!(c, ' ' | '\t' | '\n' | '\r' | '\u{0C}');
    let mut i = 0;
    while i + n.len() <= s.len() {
        let at = i;
        i += 1;
        if !(at == 0 || space(s[at - 1])) || !(0..n.len()).all(|k| s[at + k].to_ascii_lowercase() == n[k]) {
            continue;
        }
        let mut j = at + n.len();
        while j < s.len() && space(s[j]) {
            j += 1;
        }
        if j >= s.len() || s[j] != '=' {
            continue;
        }
        j += 1;
        while j < s.len() && space(s[j]) {
            j += 1;
        }
        if j >= s.len() {
            return None;
        }
        if s[j] == '"' || s[j] == '\'' {
            let q = s[j];
            let mut k = j + 1;
            while k < s.len() && s[k] != q {
                k += 1;
            }
            return (k < s.len()).then(|| s[j + 1..k].iter().collect());
        }
        let mut k = j;
        while k < s.len() && !space(s[k]) && s[k] != '"' && s[k] != '\'' && s[k] != '>' {
            k += 1;
        }
        if k > j {
            return Some(s[j..k].iter().collect());
        }
    }
    None
}

// 페이지 머리에서 대표 사진 주소: og:image(:url) → og:image:secure_url → twitter:image, 속성 순서는 어느 쪽이든. http(s) 만
pub fn og_image(html: &str, base: Option<&str>) -> Option<String> {
    let mut end = html.len().min(HEAD_LIMIT);
    while !html.is_char_boundary(end) {
        end -= 1;
    }
    let mut found: HashMap<String, String> = HashMap::new();
    for tag in tags("meta", &html[..end]) {
        let Some(key) = attr(&tag, "property").or_else(|| attr(&tag, "name")) else { continue };
        let Some(content) = attr(&tag, "content") else { continue };
        found.entry(key.to_lowercase()).or_insert(content);
    }
    let base = base.and_then(|b| url::Url::parse(b).ok());
    for k in ["og:image", "og:image:url", "og:image:secure_url", "twitter:image", "twitter:image:src"] {
        let Some(raw) = found.get(k) else { continue };
        let raw = raw.replace("&amp;", "&");
        let raw = raw.trim();
        let u = match &base {
            Some(b) => b.join(raw).ok(),
            None => url::Url::parse(raw).ok(),
        };
        if let Some(u) = u.filter(|u| u.scheme() == "https" || u.scheme() == "http") {
            return Some(u.to_string());
        }
    }
    None
}

// 기사 페이지를 받아 대표 사진 주소(공개 주소만 — feed_service 의 안전한 받기, 앞 200KB 만 읽음)
pub async fn og_image_for(link: &str) -> Option<String> {
    let data = crate::feed_service::SHARED.fetch_page(link).await.ok()??;
    let head = String::from_utf8_lossy(&data[..data.len().min(HEAD_LIMIT)]).to_string();
    og_image(&head, Some(link))
}

// 표지를 어떻게 할지(맥 findCover 의 판단만 떼어 낸 것)
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CoverChoice {
    Keep,           // 아는 사진 그대로(또는 바꿀 것이 없음)
    Use(String),    // 기사 머리 대표 사진으로
    Remove,         // 아는 사진이 깨졌고 대신할 것도 없음 — 자리를 지운다
}

// 아는 사진(피드·매거진 기록)을 받아 본 뒤 og:image 를 볼 필요가 있나: 없거나, 못 받거나, 가로 400px 미만
pub fn needs_og(known: Option<&str>, known_width: Option<u32>) -> bool {
    !(known.is_some() && known_width.map(big_enough).unwrap_or(false))
}

// known_width: 아는 사진을 받았으면 그 가로(못 받으면 None). og_width: og:image 를 받았으면 그 가로
pub fn choose(known: Option<&str>, known_width: Option<u32>, og: Option<&str>, og_width: Option<u32>, is_junk: impl Fn(&str) -> bool) -> CoverChoice {
    if !needs_og(known, known_width) {
        return CoverChoice::Keep;
    }
    let known_loads = known.is_some() && known_width.is_some();
    let ok = match (og, og_width) {
        (Some(o), Some(w)) => !is_junk(o) && Some(o) != known && (!known_loads || big_enough(w)),
        _ => false,
    };
    if ok {
        return CoverChoice::Use(og.unwrap().to_string());
    }
    if known.is_some() && !known_loads {
        CoverChoice::Remove // 깨진 사진 자리를 남기지 않는다
    } else {
        CoverChoice::Keep
    }
}
