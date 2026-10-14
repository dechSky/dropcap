// 기사 안 찾기(Ctrl+F, 맥 Reader/ReaderFind.swift): 지금 보이는 글(번역이든 원문이든)에서 대소문자 구별 없이 찾고,
// Ctrl+G / Shift+Ctrl+G 로 오간다. 일치한 곳은 노랗게, 지금 고른 곳은 주황으로 칠한다.

// 찾은 자리 하나: 몇 번째 글 조각(제목=0, 본문 조각 차례)의 몇 번째 일치인지
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Match {
    pub piece: usize,
    pub nth: usize,
}

fn fold(c: char) -> String {
    c.to_lowercase().collect()
}

// 일치하는 곳의 바이트 범위(pango 속성이 바이트 위치를 쓴다)
pub fn ranges(text: &str, query: &str) -> Vec<(usize, usize)> {
    let q: Vec<String> = query.trim().chars().map(fold).collect();
    if q.is_empty() || text.is_empty() {
        return vec![];
    }
    let chars: Vec<(usize, char)> = text.char_indices().collect();
    let mut out = vec![];
    let mut i = 0;
    while i + q.len() <= chars.len() {
        if (0..q.len()).all(|k| fold(chars[i + k].1) == q[k]) {
            let start = chars[i].0;
            let end = chars.get(i + q.len()).map(|c| c.0).unwrap_or(text.len());
            out.push((start, end));
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

pub fn count_text(query: &str, count: usize, index: usize) -> String {
    if query.trim().is_empty() {
        String::new()
    } else if count == 0 {
        "없음".into()
    } else {
        format!("{}/{}", index + 1, count)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn finds_case_insensitive_with_byte_ranges() {
        assert_eq!(ranges("OpenAI and openai", "OPENAI"), vec![(0, 6), (11, 17)]);
        let r = ranges("새 모델 공개, 모델", "모델");
        assert_eq!(r.len(), 2);
        assert_eq!(&"새 모델 공개, 모델"[r[0].0..r[0].1], "모델");
        assert!(ranges("abc", "  ").is_empty());
        let m = matches(&["Title AI".into(), "no".into(), "ai ai".into()], "ai");
        assert_eq!(m, vec![Match { piece: 0, nth: 0 }, Match { piece: 2, nth: 0 }, Match { piece: 2, nth: 1 }]);
        assert_eq!(step(2, 3, true), 0);
        assert_eq!(step(0, 3, false), 2);
        assert_eq!(step(0, 0, true), 0);
        assert_eq!(count_text("x", 0, 0), "없음");
        assert_eq!(count_text("x", 3, 1), "2/3");
    }
}
