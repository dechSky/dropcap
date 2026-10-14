// 분야 대표 사진 고르기(M-24) — 맥 Core/PhotoQuality.swift.
// 웹사이트 화면 캡처·글자 위주 그림·로고가 표지·분야 카드에 뽑히지 않게
// 사진 비율·크기·글자 면적·색 다양성·단색 바탕으로 점수를 매긴다. 기사 본문 사진·카드의 기사 사진에는 쓰지 않는다.
//
// 글자 면적: 맥은 Vision 글자 인식(한·일·중·영). 리눅스는 이 컴퓨터에 tesseract 가 있으면 그것으로(설치된 언어 중 kor·jpn·chi_sim·eng),
// 없으면 '글자 같은 칸' 어림(estimate_text_ratio): 16px 칸 중 한 가지 바탕색이 절반 넘게 덮고 그 위에 대비가 큰 가는 획이 있는 칸의 몫.
// 글자 인식보다 거칠지만(흰 바탕 물건 사진의 테두리도 조금 셈) 화면 캡처·글자 그림처럼 '단색 바탕 + 글자'는 잡는다.
// tesseract 에는 앱이 다시 인코딩해 둔 JPEG(images.rs)만 넘긴다(피드에서 받은 원본 파일을 그대로 넘기지 않음).
use crate::database::Database;
use crate::models::NewsItem;
use image::{imageops::FilterType, DynamicImage, GenericImageView};
use once_cell::sync::Lazy;
use std::collections::HashMap;
use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Score {
    pub aspect: f64,        // 0~1: 가로 사진(1.2~2.1)이 1
    pub size: f64,          // 0~1: 짧은 변 400px 이상이 1
    pub text_ratio: f64,    // 0~1: 글자 영역이 차지하는 면적
    pub color_variety: f64, // 0~1: 몇 가지 색이 넓게 덮으면(화면 캡처·로고) 낮음
    pub flatness: f64,      // 0~1: 이웃과 색이 똑같은 칸의 몫(단색 바탕)
    pub total: f64,
}

// 이 점수보다 낮으면 대표 사진으로 쓰지 않는다
pub const THRESHOLD: f64 = 0.55;

pub fn aspect_score(w: f64, h: f64) -> f64 {
    if w <= 0.0 || h <= 0.0 {
        return 0.0;
    }
    let r = w / h;
    if (1.2..=2.1).contains(&r) {
        1.0
    } else if r < 1.2 {
        ((r - 0.6) / 0.6).max(0.0) // 세로·정사각에 가까울수록(로고·인물 사진) 낮게
    } else {
        (1.0 - (r - 2.1) / 1.5).max(0.0) // 띠처럼 긴 배너
    }
}

pub fn size_score(w: f64, h: f64) -> f64 {
    ((w.min(h) - 150.0) / 250.0).clamp(0.0, 1.0)
}

// 글자 면적 → 점수: 사진 귀퉁이의 작은 글자(2~3%)는 거의 깎지 않고, 15% 넘으면 0
pub fn text_score(ratio: f64) -> f64 {
    (1.0 - (ratio - 0.03) / 0.12).clamp(0.0, 1.0)
}

pub fn combine(aspect: f64, size: f64, text_ratio: f64, color_variety: f64, flatness: f64) -> Score {
    let mut total = 0.15 * aspect + 0.15 * size + 0.4 * text_score(text_ratio) + 0.3 * color_variety;
    // 아래에 걸리면 다른 점수가 좋아도 기준을 넘지 못하게 반으로: 글자가 5분의 1 넘게 덮음(글자 그림) ·
    // 단색 바탕이 넓음(그래픽·여백을 붙인 그림) · 단색 바탕에 글자가 있음(웹사이트·앱 화면 캡처)
    if text_ratio >= 0.2 || flatness >= 0.35 || (flatness >= 0.25 && text_ratio >= 0.05) {
        total *= 0.5;
    }
    Score { aspect, size, text_ratio, color_variety, flatness, total }
}

fn rgba(img: &DynamicImage, n: u32) -> Vec<u8> {
    img.resize_exact(n, n, FilterType::Triangle).to_rgba8().into_raw()
}

// 48×48 로 줄여 4비트씩 나눈 색 칸 중 가장 넓은 4칸이 차지하는 몫. 사진은 작고, 흰 바탕 화면 캡처·로고는 크다.
pub fn color_variety(img: &DynamicImage) -> f64 {
    let n = 48;
    let px = rgba(img, n);
    let mut bins: HashMap<u32, usize> = HashMap::new();
    for p in px.chunks_exact(4) {
        let k = ((p[0] >> 4) as u32) << 8 | ((p[1] >> 4) as u32) << 4 | (p[2] >> 4) as u32;
        *bins.entry(k).or_default() += 1;
    }
    let mut counts: Vec<usize> = bins.into_values().collect();
    counts.sort_unstable_by(|a, b| b.cmp(a));
    let top4: usize = counts.iter().take(4).sum();
    let share = top4 as f64 / (n * n) as f64;
    ((1.0 - share) * 1.3).clamp(0.0, 1.0)
}

// 96×96 로 줄였을 때 오른쪽·아래 이웃과 색이 똑같은 칸의 몫. 화면 캡처·그래픽은 넓은 단색 바탕이 그대로 남고,
// 사진은 흐린 배경이라도 잡음·결이 있어 거의 0 이다.
pub fn flatness(img: &DynamicImage) -> f64 {
    let n = 96usize;
    let px = rgba(img, n as u32);
    let same = |a: usize, b: usize| px[a] == px[b] && px[a + 1] == px[b + 1] && px[a + 2] == px[b + 2];
    let mut flat = 0usize;
    for y in 0..n - 1 {
        for x in 0..n - 1 {
            let i = (y * n + x) * 4;
            if same(i, i + 4) && same(i, i + n * 4) {
                flat += 1;
            }
        }
    }
    flat as f64 / ((n - 1) * (n - 1)) as f64
}

// tesseract 와 쓸 수 있는 언어(한·일·중·영 중 설치된 것). 없으면 None
static TESSERACT: Lazy<Option<String>> = Lazy::new(|| {
    let out = std::process::Command::new("tesseract").arg("--list-langs").output().ok()?;
    let text = String::from_utf8_lossy(&out.stdout).to_string() + &String::from_utf8_lossy(&out.stderr);
    let have: Vec<&str> = ["kor", "jpn", "chi_sim", "eng"].into_iter().filter(|l| text.lines().any(|x| x.trim() == *l)).collect();
    (!have.is_empty()).then(|| have.join("+"))
});

pub fn ocr_available() -> bool {
    TESSERACT.is_some()
}

// tesseract TSV 에서 글자(낱말) 상자 면적의 합 / 그림 면적. 신뢰도 30 이상만(언어를 잘못 짚어도 글자가 있다는 뜻)
pub fn text_area_from_tsv(tsv: &str, w: f64, h: f64) -> f64 {
    if w <= 0.0 || h <= 0.0 {
        return 0.0;
    }
    let mut area = 0.0;
    for line in tsv.lines().skip(1) {
        let c: Vec<&str> = line.split('\t').collect();
        if c.len() < 12 || c[0] != "5" || c[11].trim().is_empty() {
            continue;
        }
        let conf: f64 = c[10].parse().unwrap_or(-1.0);
        if conf < 30.0 {
            continue;
        }
        let (bw, bh): (f64, f64) = (c[8].parse().unwrap_or(0.0), c[9].parse().unwrap_or(0.0));
        area += bw * bh;
    }
    (area / (w * h)).min(1.0)
}

// 글자 같은 칸의 몫(tesseract 가 없을 때). 칸 하나 = 16px: 바탕(가장 많은 밝기 ±6)이 55% 넘고, 바탕과 밝기 차이가 90 넘는 점이 4~45%
pub fn estimate_text_ratio(img: &DynamicImage) -> f64 {
    let g = img.to_luma8();
    let (w, h) = g.dimensions();
    let t = 16u32;
    if w < t || h < t {
        return 0.0;
    }
    let (cols, rows) = (w / t, h / t);
    let mut text = 0u32;
    for ty in 0..rows {
        for tx in 0..cols {
            let mut hist = [0u32; 256];
            for y in ty * t..ty * t + t {
                for x in tx * t..tx * t + t {
                    hist[g.get_pixel(x, y).0[0] as usize] += 1;
                }
            }
            let mode = (0..256).max_by_key(|&v| hist[v]).unwrap_or(0) as i32;
            let total = (t * t) as f64;
            let bg: u32 = (0..256i32).filter(|v| (v - mode).abs() <= 6).map(|v| hist[v as usize]).sum();
            let ink: u32 = (0..256i32).filter(|v| (v - mode).abs() > 90).map(|v| hist[v as usize]).sum();
            let (bg, ink) = (bg as f64 / total, ink as f64 / total);
            if bg >= 0.55 && (0.04..=0.45).contains(&ink) {
                text += 1;
            }
        }
    }
    text as f64 / (cols * rows) as f64
}

// 실제로 읽히는 글자가 덮는 면적(tesseract 가 없으면 어림)
pub fn text_ratio(file: &Path, img: &DynamicImage) -> f64 {
    let (w, h) = img.dimensions();
    let (w, h) = (w as f64, h as f64);
    let Some(langs) = TESSERACT.as_ref() else { return estimate_text_ratio(img) };
    let Ok(out) = std::process::Command::new("tesseract")
        .arg(file)
        .arg("stdout")
        .args(["-l", langs, "--psm", "11", "tsv"])
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
    else {
        return 0.0;
    };
    text_area_from_tsv(&String::from_utf8_lossy(&out.stdout), w, h)
}

// 무거운 일이므로 화면 줄기 밖(spawn_blocking)에서 부른다. file 은 images.rs 가 담아 둔 JPEG
pub fn score_file(file: &Path) -> Option<Score> {
    let img = image::open(file).ok()?;
    let (w, h) = img.dimensions();
    let (w, h) = (w as f64, h as f64);
    Some(combine(aspect_score(w, h), size_score(w, h), text_ratio(file, &img), color_variety(&img), flatness(&img)))
}

// 파일 없이 그림만으로(글자 면적은 따로 줌 — 시험·어림용)
pub fn score_image(img: &DynamicImage, text_ratio: f64) -> Score {
    let (w, h) = img.dimensions();
    let (w, h) = (w as f64, h as f64);
    combine(aspect_score(w, h), size_score(w, h), text_ratio, color_variety(img), flatness(img))
}

pub fn good(score: Option<f64>) -> bool {
    score.unwrap_or(1.0) >= THRESHOLD // 아직 재지 않은 사진은 막지 않는다
}

fn has_photo(it: &NewsItem) -> bool {
    it.image.is_some() && !crate::article::image_key::is_junk(it.image.as_deref())
}

// 표지 기사: 사진이 좋은(또는 아직 재지 않은) 것 중 앞, 없으면 사진 없는 것 중 앞(좋지 않은 사진을 표지에 크게 띄우지 않게)
pub fn pick_cover(ranked: &[NewsItem], scores: &HashMap<String, f64>) -> Option<String> {
    ranked
        .iter()
        .find(|it| has_photo(it) && good(scores.get(it.image.as_ref().unwrap()).cloned()))
        .or_else(|| ranked.iter().find(|it| !has_photo(it)))
        .map(|it| it.key())
}

// 분야 대표 사진: 이미 잰 점수만으로 고르기(즉시). 잰 것 중 통과한 것 먼저, 없으면 아직 재지 않은 것
pub fn best<'a>(items: &'a [NewsItem], scores: &HashMap<String, f64>) -> Option<&'a NewsItem> {
    let with: Vec<&NewsItem> = items.iter().filter(|i| has_photo(i)).collect();
    with.iter()
        .find(|i| scores.get(i.image.as_ref().unwrap()).map(|s| good(Some(*s))).unwrap_or(false))
        .or_else(|| with.iter().find(|i| good(scores.get(i.image.as_ref().unwrap()).cloned())))
        .copied()
}

// 분야 하나의 대표 사진: 앞의 사진들을 재 가며(최대 limit 장) 기준을 넘는 첫 사진. 잰 점수는 DB 에 남긴다.
// 돌려주는 것: (기사, 담아 둔 사진 파일). 없으면 None(기준 밑 사진은 대신 쓰지 않는다 — 사진 없이 색면으로)
pub async fn pick(db: &Database, items: &[NewsItem], limit: usize) -> Option<(NewsItem, std::path::PathBuf)> {
    let cands: Vec<&NewsItem> = items.iter().filter(|i| has_photo(i)).take(limit).collect();
    let known = db.image_scores(&cands.iter().map(|i| i.image.clone().unwrap()).collect::<Vec<_>>());
    for it in cands {
        let url = it.image.clone().unwrap();
        if let Some(s) = known.get(&url) {
            if !good(Some(*s)) {
                continue;
            }
        }
        let Some(file) = crate::images::shared().image(&url).await else { continue };
        let s = match known.get(&url) {
            Some(k) => *k,
            None => {
                let f = file.clone();
                let Some(sc) = tokio::task::spawn_blocking(move || score_file(&f)).await.ok().flatten() else { continue };
                db.save_image_score(&url, &sc);
                sc.total
            }
        };
        if good(Some(s)) {
            return Some((it.clone(), file));
        }
    }
    None
}

// 최근 기사 사진의 점수를 미리 잰다(표지·분야 대표 사진 고르기). 한 번에 16장, 이미 잰 것은 건너뜀. 기준 밑이 하나라도 나오면 true
pub async fn score_recent(db: &Database) -> bool {
    let since = chrono::Utc::now() - chrono::Duration::hours(36);
    let recent: Vec<NewsItem> = db
        .items_kind(since, None, 400, crate::database::KindFilter::Articles)
        .into_iter()
        .map(|s| s.item)
        .filter(has_photo)
        .collect();
    let known = db.image_scores(&recent.iter().map(|i| i.image.clone().unwrap()).collect::<Vec<_>>());
    let mut changed = false;
    for it in recent.iter().filter(|i| !known.contains_key(i.image.as_ref().unwrap())).take(16) {
        let url = it.image.clone().unwrap();
        let Some(file) = crate::images::shared().image(&url).await else { continue };
        let Some(s) = tokio::task::spawn_blocking(move || score_file(&file)).await.ok().flatten() else { continue };
        db.save_image_score(&url, &s);
        if !good(Some(s.total)) {
            changed = true;
            log::info!(
                "[사진 점수] 대표 사진에서 뺌 {:.2}(글자 {:.2}·색 {:.2}·단색 {:.2}) {}",
                s.total,
                s.text_ratio,
                s.color_variety,
                s.flatness,
                it.source_name
            );
        }
    }
    changed
}
