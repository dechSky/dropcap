// 사진 속 글자 읽기(맥 Reader/ImageTools.swift 의 recognize · averageColor).
// 맥은 기기 안 Vision 글자 인식. 리눅스는 이 컴퓨터에 tesseract 가 있으면 그것으로(설치된 언어 중 kor·jpn·chi_sim·eng — photo_quality 와 같은 길),
// 없으면 읽지 않고 화면에 설치 안내를 보인다. tesseract 에는 앱이 다시 인코딩해 둔 JPEG(images.rs)만 넘긴다.
use image::{DynamicImage, GenericImageView};
use once_cell::sync::Lazy;
use std::path::Path;

// 사진 속 글자 줄(정규화 좌표: 왼쪽 위 원점 0~1)
#[derive(Debug, Clone, PartialEq)]
pub struct Line {
    pub text: String,
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
    pub translated: Option<String>,
    pub background: (u8, u8, u8),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OcrError {
    NoTesseract, // 글자 인식 도구가 없음
    Failed,      // 사진을 열지 못했거나 도구가 실패
}

pub const NO_TESSERACT: &str = "글자 인식 도구(tesseract)가 없어 사진 속 글자를 읽을 수 없습니다. 배포판 꾸러미에서 tesseract-ocr(한국어 kor 포함)을 설치하세요";

// tesseract 와 쓸 수 있는 언어(한·일·중·영 중 설치된 것). 없으면 None
static LANGS: Lazy<Option<String>> = Lazy::new(|| {
    let out = std::process::Command::new("tesseract").arg("--list-langs").stdin(std::process::Stdio::null()).output().ok()?;
    let text = String::from_utf8_lossy(&out.stdout).to_string() + &String::from_utf8_lossy(&out.stderr);
    let have: Vec<&str> = ["kor", "jpn", "chi_sim", "eng"].into_iter().filter(|l| text.lines().any(|x| x.trim() == *l)).collect();
    (!have.is_empty()).then(|| have.join("+"))
});

pub fn available() -> bool {
    LANGS.is_some()
}

// tesseract TSV 에서 글자 줄: 낱말(level 5)을 (덩어리·문단·줄) 번호로 묶고 상자를 합친다. 신뢰도 30 이상만(맥 Vision 0.3 과 같은 몫).
// 한·중·일 글자 사이 띄어쓰기는 tesseract 가 낱자마다 띄우므로 붙인다
pub fn lines_from_tsv(tsv: &str, w: f64, h: f64) -> Vec<Line> {
    if w <= 0.0 || h <= 0.0 {
        return vec![];
    }
    let mut out: Vec<((String, String, String), Vec<String>, (f64, f64, f64, f64))> = vec![];
    for row in tsv.lines().skip(1) {
        let c: Vec<&str> = row.split('\t').collect();
        if c.len() < 12 || c[0] != "5" || c[11].trim().is_empty() {
            continue;
        }
        if c[10].parse::<f64>().unwrap_or(-1.0) < 30.0 {
            continue;
        }
        let n = |k: usize| c[k].parse::<f64>().unwrap_or(0.0);
        let (l, t, bw, bh) = (n(6), n(7), n(8), n(9));
        let key = (c[2].to_string(), c[3].to_string(), c[4].to_string());
        match out.last_mut() {
            Some((k, words, b)) if *k == key => {
                words.push(c[11].trim().to_string());
                let (x0, y0) = (b.0.min(l), b.1.min(t));
                let (x1, y1) = ((b.0 + b.2).max(l + bw), (b.1 + b.3).max(t + bh));
                *b = (x0, y0, x1 - x0, y1 - y0);
            }
            _ => out.push((key, vec![c[11].trim().to_string()], (l, t, bw, bh))),
        }
    }
    out.into_iter()
        .map(|(_, words, b)| Line {
            text: join_words(&words),
            x: (b.0 / w).clamp(0.0, 1.0),
            y: (b.1 / h).clamp(0.0, 1.0),
            w: (b.2 / w).clamp(0.0, 1.0),
            h: (b.3 / h).clamp(0.0, 1.0),
            translated: None,
            background: (255, 255, 255),
        })
        .collect()
}

fn cjk(c: char) -> bool {
    matches!(c as u32, 0x3040..=0x30FF | 0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xAC00..=0xD7A3)
}

fn join_words(words: &[String]) -> String {
    let mut s = String::new();
    for w in words {
        let glue = matches!((s.chars().last(), w.chars().next()), (Some(a), Some(b)) if cjk(a) && cjk(b) && w.chars().count() == 1);
        if !s.is_empty() && !glue {
            s.push(' ');
        }
        s.push_str(w);
    }
    s
}

// 글자 상자 바로 바깥(위·아래 띠)의 평균 색 = 글자 뒤 바탕색(글자 자체 색이 섞이지 않게). 띠 두께는 상자 높이의 18%(최소 2px)
pub fn average_color(img: &DynamicImage, l: &Line) -> (u8, u8, u8) {
    let (iw, ih) = img.dimensions();
    let (fw, fh) = (iw as f64, ih as f64);
    let x = (l.x * fw).floor().max(0.0);
    let w = (l.w * fw).max(1.0);
    let band = (l.h * fh * 0.18).max(2.0);
    let strips = [(l.y * fh - band - 1.0, band), ((l.y + l.h) * fh + 1.0, band)];
    let mut sum = [0f64; 3];
    let mut n = 0f64;
    let rgb = img.to_rgb8();
    for (y, bh) in strips {
        let (y0, y1) = (y.max(0.0).floor() as u32, (y + bh).min(fh).floor() as u32);
        let (x0, x1) = (x as u32, (x + w).min(fw).floor() as u32);
        if y1 <= y0 || x1 <= x0 {
            continue;
        }
        let mut s = [0f64; 3];
        let mut c = 0f64;
        for yy in y0..y1 {
            for xx in x0..x1 {
                let p = rgb.get_pixel(xx, yy).0;
                for k in 0..3 {
                    s[k] += p[k] as f64;
                }
                c += 1.0;
            }
        }
        for k in 0..3 {
            sum[k] += s[k] / c;
        }
        n += 1.0;
    }
    if n == 0.0 {
        return (255, 255, 255);
    }
    ((sum[0] / n).round() as u8, (sum[1] / n).round() as u8, (sum[2] / n).round() as u8)
}

// 바탕이 밝으면 검은 글자, 어두우면 흰 글자(맥 overlayText 의 밝기 0.55 기준)
pub fn dark_text_on(bg: (u8, u8, u8)) -> bool {
    let lum = (0.299 * bg.0 as f64 + 0.587 * bg.1 as f64 + 0.114 * bg.2 as f64) / 255.0;
    lum > 0.55
}

// 무거운 일이므로 화면 줄기 밖(spawn_blocking)에서 부른다. file 은 images.rs 가 담아 둔 JPEG
pub fn recognize(file: &Path) -> Result<Vec<Line>, OcrError> {
    let Some(langs) = LANGS.as_ref() else { return Err(OcrError::NoTesseract) };
    let img = image::open(file).map_err(|_| OcrError::Failed)?;
    let (w, h) = img.dimensions();
    let out = std::process::Command::new("tesseract")
        .arg(file)
        .arg("stdout")
        .args(["-l", langs, "--psm", "11", "tsv"])
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .map_err(|_| OcrError::Failed)?;
    let mut lines = lines_from_tsv(&String::from_utf8_lossy(&out.stdout), w as f64, h as f64);
    for l in lines.iter_mut() {
        l.background = average_color(&img, l);
    }
    Ok(lines)
}

// 번역 창 아래 막대 글(맥 ImageTranslateView.bar)
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stage {
    Reading,
    Translating,
    Done,
    NoText,
    AlreadyKorean,
    NoTool,
    Failed,
}

pub fn stage_text(stage: Stage, translated_lines: usize) -> String {
    match stage {
        Stage::Reading => "사진 속 글자를 읽는 중…".into(),
        Stage::Translating => "번역하는 중…".into(),
        Stage::Done => format!("{translated_lines}줄 번역"),
        Stage::NoText => "사진에서 글자를 찾지 못했습니다".into(),
        Stage::AlreadyKorean => "이미 한국어 글자입니다".into(),
        Stage::NoTool => NO_TESSERACT.into(),
        Stage::Failed => "사진 속 글자를 읽지 못했습니다".into(),
    }
}

// 번역할 줄 번호(외국어로 보이는 줄만, 맥 ImageTranslateModel.run)
pub fn foreign_lines(lines: &[Line]) -> Vec<usize> {
    (0..lines.len()).filter(|&i| crate::translator::looks_foreign(&lines[i].text)).collect()
}

// 저장할 때 기본 이름: 주소 마지막 조각(확장자 뺌), 비거나 80자 넘으면 image. 맥과 같이 .png
pub fn save_name(url: &str) -> String {
    let path = url::Url::parse(url).map(|u| u.path().to_string()).unwrap_or_default();
    let last = path.rsplit('/').next().unwrap_or("");
    let last = urldecode(last);
    let stem = match last.rfind('.') {
        Some(d) if d > 0 => &last[..d],
        _ => last.as_str(),
    };
    let name = if stem.is_empty() || stem.chars().count() > 80 { "image" } else { stem };
    format!("{name}.png")
}

fn urldecode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let Some(v) = std::str::from_utf8(&b[i + 1..i + 3]).ok().and_then(|h| u8::from_str_radix(h, 16).ok()) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).replace(['/', '\\'], "_")
}
