// 기사 안 찾기(맥 Reader/ReaderFind.swift)의 화면 없는 부분: 대소문자·악센트·전각/반각 구별 없이 찾고(Café = cafe, ＡＩ = ai),
// 다음·이전은 끝에서 처음으로 돌아간다. 화면(dropcap-gtk reader_find·reader_view)이 지금 보이는 글(번역이든 원문이든)을 넘긴다.

// 찾은 자리 하나: 몇 번째 글 조각(제목=0, 본문 조각 차례)의 몇 번째 일치인지
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Match {
    pub piece: usize,
    pub nth: usize,
}

// U+00C0~U+017F 라틴 글자의 밑글자(악센트를 뗀 것). 밑글자가 없는 것(Æ·Ð·Þ·× 등)은 그대로
const LATIN1: &str = "AAAAAAÆCEEEEIIIIÐNOOOOO×ØUUUUYÞßaaaaaaæceeeeiiiiðnooooo÷øuuuuyþy";
const LATIN_A: &str = "AaAaAaCcCcCcCcDdĐđEeEeEeEeEeGgGgGgGgHhĦħIiIiIiIiIıĲĳJjKkĸLlLlLlĿŀŁłNnNnNnŉŊŋOoOoOoŒœRrRrRrSsSsSsSsTtTtŦŧUuUuUuUuUuUuWwYyYZzZzZzſ";

// 글자 하나를 비교용으로: 전각 → 반각, 악센트 떼기, 소문자. 조합용 악센트(U+0300~036F)는 None(앞 글자에 붙임)
pub fn fold(c: char) -> Option<char> {
    let u = c as u32;
    if (0x300..=0x36F).contains(&u) {
        return None;
    }
    let c = match u {
        0xFF01..=0xFF5E => char::from_u32(u - 0xFEE0).unwrap_or(c), // 전각 영문·숫자·기호
        0x3000 => ' ',
        0xC0..=0xFF => LATIN1.chars().nth((u - 0xC0) as usize).unwrap_or(c),
        0x100..=0x17F => LATIN_A.chars().nth((u - 0x100) as usize).unwrap_or(c),
        _ => c,
    };
    Some(c.to_lowercase().next().unwrap_or(c))
}

// 비교용 글자들과 각 글자의 원래 바이트 범위(조합용 악센트는 앞 글자 범위에 넣는다)
fn folded(text: &str) -> Vec<(char, usize, usize)> {
    let mut out: Vec<(char, usize, usize)> = Vec::with_capacity(text.len());
    for (i, c) in text.char_indices() {
        let end = i + c.len_utf8();
        match fold(c) {
            Some(f) => out.push((f, i, end)),
            None => {
                if let Some(last) = out.last_mut() {
                    last.2 = end;
                }
            }
        }
    }
    out
}

// 일치하는 곳의 바이트 범위(pango 속성이 바이트 위치를 쓴다). 겹치지 않게 차례로
pub fn ranges(text: &str, query: &str) -> Vec<(usize, usize)> {
    let q: Vec<char> = folded(query.trim()).into_iter().map(|x| x.0).collect();
    if q.is_empty() || text.is_empty() {
        return vec![];
    }
    let t = folded(text);
    let mut out = vec![];
    let mut i = 0;
    while i + q.len() <= t.len() {
        if (0..q.len()).all(|k| t[i + k].0 == q[k]) {
            out.push((t[i].1, t[i + q.len() - 1].2));
            i += q.len();
        } else {
            i += 1;
        }
    }
    out
}

// pieces: 화면에 나오는 순서대로의 글
pub fn matches(pieces: &[String], query: &str) -> Vec<Match> {
    pieces.iter().enumerate().flat_map(|(p, t)| (0..ranges(t, query).len()).map(move |n| Match { piece: p, nth: n })).collect()
}

// 다음·이전(끝에서 처음으로 돌아감)
pub fn step(current: usize, count: usize, forward: bool) -> usize {
    if count == 0 {
        return 0;
    }
    let c = current as i64 + if forward { 1 } else { -1 };
    (((c % count as i64) + count as i64) % count as i64) as usize
}

// 찾기 막대의 개수 표시: 빈 칸이면 없음, 못 찾으면 '없음', 찾으면 '2/5'
pub fn count_text(query: &str, count: usize, index: usize) -> String {
    if query.trim().is_empty() {
        String::new()
    } else if count == 0 {
        "없음".into()
    } else {
        format!("{}/{}", index + 1, count)
    }
}
