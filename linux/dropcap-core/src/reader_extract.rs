// 본문 추리기의 앞뒤 손질(맥 ArticleExtractor 추출 스크립트의 2단계).
// 웹 엔진 없이 도는 빠른 길(dom_smoothie)도 맥 스크립트와 같은 순서로:
//  ① 추리기 전에 본문 밖 상자(기자 소개·댓글 수·공유·단추)·기자 얼굴·각주 번호를 뺀다(pre_clean)
//  ② Readability 결과를 원문에서 찾아 B: itemprop=articleBody 우선(옆 상자를 고른 경우), A: 같은 꼴 형제 덩어리 모으기,
//     본문 영역에 우리 글에 없는 긴 문단이 많이 남으면 '일부만'(gather)
//  ③ 블록으로 바꿀 때 요소 사이 맨 글자·<br><br> 문단, <br> 은 빈칸(walk), 같은 글·사진은 한 번만,
//     기사 글은 거의 없고 목록만 많으면 '글 거의 없음'(finish)
use crate::article::{best_src, clean_text, Block, BlockKind};
use dom_query::{Document, NodeRef, Selection};
use once_cell::sync::Lazy;
use regex::Regex;
use std::collections::HashSet;

pub fn norm(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn len_of(n: &NodeRef) -> usize {
    norm(&n.text()).chars().count()
}

fn body_of(doc: &Document) -> Option<NodeRef<'_>> {
    doc.select("body").nodes().first().cloned()
}

fn doc_len(html: &str) -> usize {
    let d = Document::from(html);
    body_of(&d).map(|b| len_of(&b)).unwrap_or(0)
}

fn doc_imgs(html: &str) -> usize {
    Document::from(html).select("img").length()
}

const SR_ONLY: &str = crate::article::SR_ONLY;
// 본문 밖 상자(맥 스크립트와 같은 목록)
const JUNK_BOX: &str = r#".author-mini-bio, [class*="author-bio" i], [class*="authorbio" i], [class*="author-box" i], [class*="authorbox" i], [class*="author-card" i], [class*="about-author" i], [class*="about-the-author" i], [class*="author-info" i], [class*="bio-box" i], [class*="byline-bio" i], [class*="contributor-bio" i], .story-tools, .view-comments, [class*="comment-count" i], [class*="comments-link" i], [class*="share-bar" i], [class*="social-share" i], [class*="hide-caption" i], [class*="toggle-caption" i], button"#;
const AUTHOR_IMG: &str = r#"a[href*="/author/" i] img, a[href*="/authors/" i] img, a[href*="/people/" i] img, a[href*="/staff/" i] img, a[href*="/reporter/" i] img"#;

static FOOTNOTE: Lazy<Regex> = Lazy::new(|| Regex::new(r"^\[?\s*\d{1,3}\s*\]?$").unwrap());
static BAD: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"(?i)related|recommend|share|social|promo|newsletter|comment|sidebar|links|tags?\b|topic|footer|nav|advert|popular|most-?read|author|byline|headline|elsewhere|features|top-?stories").unwrap()
});
static AD: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)(^|[\s_-])(ad|ads|adv|advert|advertisement|banner|sponsor)([\s_-]|$)").unwrap());

// ① 추리기 전 손질. 페이지 글의 30% 넘는 상자는 건드리지 않는다(본문을 지우지 않게)
pub fn pre_clean(doc: &Document) {
    doc.select(SR_ONLY).remove();
    let total = body_of(doc).map(|b| len_of(&b)).unwrap_or(0).max(1) as f64;
    // 지운 상자 안의 상자는 건너뛰고(겹친 상자마다 하위 글을 세면 N²), 센 글이 페이지 글의 8배를 넘으면 그만
    let mut gone = HashSet::new();
    let mut budget = total * 8.0 + 10_000.0;
    for n in doc.select(JUNK_BOX).nodes() {
        if gone.contains(&n.id) {
            continue;
        }
        let len = len_of(n) as f64;
        budget -= len;
        if budget < 0.0 {
            break;
        }
        if len < total * 0.3 {
            gone.extend(n.descendants_it().map(|d| d.id));
            n.remove_from_parent();
        }
    }
    doc.select(AUTHOR_IMG).remove(); // 기자 얼굴
    for n in doc.select("sup").nodes() {
        if FOOTNOTE.is_match(&norm(&n.text())) {
            n.remove_from_parent(); // 각주 번호
        }
    }
}

fn attr(n: &NodeRef, a: &str) -> String {
    n.attr(a).map(|s| s.to_string()).unwrap_or_default()
}
fn label(n: &NodeRef) -> String {
    format!("{} {} {}", attr(n, "class"), attr(n, "data-component"), attr(n, "data-block"))
}
fn is_ad(n: &NodeRef) -> bool {
    AD.is_match(&format!("{} {}", attr(n, "class"), attr(n, "id")))
}
fn first_class(n: &NodeRef) -> String {
    attr(n, "class").split_whitespace().next().unwrap_or("").to_string()
}
fn tag(n: &NodeRef) -> String {
    n.node_name().map(|t| t.to_lowercase()).unwrap_or_default()
}
fn alike(a: &NodeRef, b: &NodeRef) -> bool {
    let fa = first_class(a);
    tag(a) == tag(b)
        && ((a.has_attr("data-block") && b.has_attr("data-block"))
            || (a.has_attr("data-component") && b.has_attr("data-component"))
            || (!fa.is_empty() && fa == first_class(b)))
}
fn long_p<'a>(n: &NodeRef<'a>) -> Vec<NodeRef<'a>> {
    Selection::from(n.clone()).select("p").nodes().iter().filter(|p| len_of(p) >= 80).cloned().collect()
}
fn has_class_inside(n: &NodeRef, class: &str) -> bool {
    n.descendants_it().any(|d| d.is_element() && d.has_class(class))
}
fn contains(outer: &NodeRef, inner: &NodeRef) -> bool {
    outer.id == inner.id || inner.ancestors_it(None).any(|a| a.id == outer.id)
}
// 안쪽에서 class 를 가진 가장 바깥 상자들(문서 순서) — 찾은 상자 안으로는 더 내려가지 않는다
fn outer_with_class<'a>(root: &NodeRef<'a>, class: &str) -> Vec<NodeRef<'a>> {
    let mut out = vec![];
    let mut stack: Vec<NodeRef> = root.element_children().into_iter().rev().collect();
    while let Some(n) = stack.pop() {
        if n.has_class(class) {
            out.push(n);
        } else {
            stack.extend(n.element_children().into_iter().rev());
        }
    }
    out
}

// 파싱 전에 대략 센 겹침 깊이(여는 표지 +1, 센 여는 표지가 남은 이름의 닫는 표지 −1 — 짝 없는 닫는 표지로 줄이지 못하게;
// 빈 요소·닫는 표지를 흔히 빼는 요소·주석·script 안은 셈하지 않음).
// html5ever 는 깊게 겹친 div 에서 파싱 자체가 깊이²라(2MB 면 몇 분) 이 값이 MAX_PARSE_DEPTH 를 넘는 페이지는 추리지 않는다
pub const MAX_PARSE_DEPTH: usize = 20_000;
pub fn rough_depth(html: &str) -> usize {
    const SKIP: &[&str] = &["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr", "p", "li", "dt", "dd", "option", "optgroup", "tr", "td", "th", "tbody", "thead", "tfoot", "colgroup", "rb", "rt", "rp", "rtc"];
    const RAW: &[&str] = &["script", "style", "textarea", "title", "xmp", "noscript", "iframe", "noembed", "noframes"];
    let b = html.as_bytes();
    let find = |from: usize, pat: &str| -> Option<usize> {
        let p = pat.as_bytes();
        (from..b.len().saturating_sub(p.len() - 1)).find(|&j| b[j..j + p.len()].eq_ignore_ascii_case(p))
    };
    let name_at = |i: usize| -> String {
        let n = b[i..].iter().position(|c| !c.is_ascii_alphanumeric() && *c != b'-').unwrap_or(b.len() - i);
        String::from_utf8_lossy(&b[i..i + n]).to_ascii_lowercase()
    };
    let mut open: std::collections::HashMap<String, usize> = Default::default();
    let (mut i, mut depth, mut max) = (0usize, 0usize, 0usize);
    while let Some(off) = b[i..].iter().position(|&c| c == b'<') {
        i += off + 1;
        if b[i..].starts_with(b"!--") {
            i = find(i, "-->").map(|j| j + 3).unwrap_or(b.len());
            continue;
        }
        if b.get(i) == Some(&b'/') {
            if let Some(c) = open.get_mut(&name_at(i + 1)).filter(|c| **c > 0) {
                *c -= 1;
                depth -= 1;
            }
            continue;
        }
        if !b.get(i).is_some_and(|c| c.is_ascii_alphabetic()) {
            continue;
        }
        let name = name_at(i);
        let end = b[i..].iter().position(|&c| c == b'>').map(|e| i + e).unwrap_or(b.len());
        if RAW.contains(&name.as_str()) {
            i = find(end, &format!("</{name}")).map(|j| j + 2 + name.len()).unwrap_or(b.len());
            continue;
        }
        if SKIP.contains(&name.as_str()) || (end > 0 && b.get(end - 1) == Some(&b'/')) {
            continue;
        }
        *open.entry(name).or_default() += 1;
        depth += 1;
        max = max.max(depth);
    }
    max
}

// 겹침 깊이 상한(Chromium HTML 파서와 같은 512). 더 깊은 요소 가운데 안에 요소를 품은 것은 풀어(자식은 그 자리에) 평평하게 —
// dom_smoothie·walk 의 재귀가 스택(spawn_blocking 2MB)을 넘어 프로세스가 죽지 않게
pub const MAX_DEPTH: usize = 512;
pub fn flatten_deep(root: &NodeRef) {
    let mut stack: Vec<(NodeRef, usize)> = root.element_children().into_iter().map(|c| (c, 1)).collect();
    while let Some((n, d)) = stack.pop() {
        let kids = n.element_children();
        if d > MAX_DEPTH && !kids.is_empty() {
            for c in n.children_it(false).collect::<Vec<_>>() {
                n.insert_before(&c);
            }
            n.remove_from_parent();
            stack.extend(kids.into_iter().map(|c| (c, d)));
        } else {
            stack.extend(kids.into_iter().map(|c| (c, d + 1)));
        }
    }
}

// 맥 prune: script·style·nav·form·aside·iframe 를 빼고, full 이면 광고·관련·공유·기자 꼴의 하위 요소도 뺀다(뿌리는 그대로).
// (맥 스크립트에서 문서에 붙지 않은 사본은 isConnected 가 거짓이라 두 번째 단계가 돌지 않는다 — 같은 결과가 되게 full 로 가림)
fn prune(root: &NodeRef, full: bool) {
    Selection::from(root.clone()).select("script, style, nav, form, aside, iframe").remove();
    if !full {
        return;
    }
    let all: Vec<NodeRef> = root.descendants_it().filter(|n| n.is_element()).collect();
    for n in all {
        if is_ad(&n) || BAD.is_match(&label(&n)) {
            n.remove_from_parent();
        }
    }
}

// 요소 하나를 떼어 손질한 HTML(outer: 요소째, 아니면 안쪽만)
fn pruned_copy(n: &NodeRef, outer: bool) -> String {
    let d = Document::from(n.html().to_string().as_str());
    let Some(body) = body_of(&d) else { return String::new() };
    let Some(root) = body.first_element_child() else { return String::new() };
    prune(&root, false);
    if outer {
        root.html().to_string()
    } else {
        root.inner_html().to_string()
    }
}

// ② Readability 가 고른 글(content)을 원문(fresh — pre_clean 을 거친 문서)에서 찾아 B·A 를 적용한다. (새 content, 일부만)
pub fn gather(content: &str, fresh: &Document) -> (String, bool) {
    let mut content = content.to_string();
    let mut partial = false;
    let first: String = {
        let d = Document::from(content.as_str());
        let x = d.select("p").nodes().iter().find(|p| len_of(p) >= 40).map(|p| norm(&p.text()).chars().take(40).collect()).unwrap_or_default();
        x
    };
    let ps = fresh.select("p");
    let anchor = if first.is_empty() { None } else { ps.nodes().iter().find(|p| norm(&p.text()).starts_with(&first)).cloned() };
    let ips = fresh.select(r#"[itemprop="articleBody"]"#);
    let ip = ips.nodes().iter().find(|e| len_of(e) >= 300).cloned();
    // B: itemprop=articleBody 가 따로 있는데 고른 글이 그 밖이면(옆 상자를 고름) 그쪽을 쓴다
    if let Some(ip) = ip.as_ref().filter(|ip| {
        !anchor.as_ref().is_some_and(|a| contains(ip, a)) && len_of(ip) as f64 >= doc_len(&content) as f64 * 0.3
    }) {
        return (format!("<div>{}</div>", pruned_copy(ip, false)), false);
    }
    let Some(anchor) = anchor else { return (content, false) };
    // A: 본문이 광고·사진을 사이에 둔 여러 덩어리면(같은 꼴의 형제) 모두 순서대로 모은다.
    // 형제가 같은 꼴이거나, 겉 포장이 달라도 안에 본문 상자와 같은 class 의 상자가 있으면(Ars: div.my-2.5 > … > .post-content) 같은 본문
    if let Some(core) = anchor.parent() {
        let core_class = first_class(&core);
        let cores = |k: &NodeRef<'_>, el: &NodeRef<'_>| -> Vec<String> {
            if k.id == el.id || alike(k, el) || core_class.is_empty() || k.has_class(&core_class) {
                vec![pruned_copy(k, true)]
            } else {
                // 같은 class 가 겹치면 바깥 상자만(후손은 바깥 사본에 이미 들어 있다 — 겹마다 복사하면 크기·시간이 N²)
                outer_with_class(k, &core_class).iter().map(|c| pruned_copy(c, true)).collect()
            }
        };
        let mut el = core.clone();
        let mut depth = 0;
        while depth < 6 {
            let Some(parent) = el.parent().filter(|p| p.is_element()) else { break };
            let kids: Vec<NodeRef> = parent
                .element_children()
                .into_iter()
                .filter(|k| {
                    k.id == el.id
                        || ((alike(k, &el) || (!core_class.is_empty() && has_class_inside(k, &core_class))) && !BAD.is_match(&label(k)) && !is_ad(k))
                })
                .collect();
            let texty: Vec<usize> = (0..kids.len()).filter(|&i| !long_p(&kids[i]).is_empty()).collect();
            if texty.len() >= 2 && texty.iter().any(|&i| kids[i].id == el.id) {
                let (from, to) = (texty[0], *texty.last().unwrap());
                let boxed: String = kids[from..=to].iter().flat_map(|k| cores(k, &el)).collect();
                // 모은 글이 원문 글의 2배를 넘으면(겹친 상자를 거듭 담은 꼴) 모으기를 그만둔다
                let cap = fresh.select("body").nodes().first().map(|b| b.text().len()).unwrap_or(0) * 2 + 1000;
                // 글이 15% 넘게 늘거나, 글은 비슷한데(90% 이상) 사진이 더 있으면(BBC: Readability 가 사진 블록을 버림) 모은 쪽
                let (cur, got) = (doc_len(&content) as f64, doc_len(&boxed) as f64);
                let more = got >= cur * 1.15;
                let pics = got >= cur * 0.9 && doc_imgs(&boxed) > doc_imgs(&content);
                if got as usize <= cap && (more || pics) {
                    content = format!("<div>{boxed}</div>");
                }
                break;
            }
            el = parent;
            depth += 1;
        }
    }
    // 본문 영역(itemprop·article)에 우리 글에 없는 긴 문단이 여럿 남으면 '일부만'
    let area = ip.or_else(|| anchor.ancestors_it(None).find(|a| a.is_element() && tag(a) == "article"));
    if let Some(area) = area {
        let got: String = {
            let d = Document::from(content.as_str());
            let x = body_of(&d).map(|b| b.text().chars().filter(|c| !c.is_whitespace()).collect()).unwrap_or_default();
            x
        };
        let ps: Vec<NodeRef> = long_p(&area).into_iter().filter(|p| !BAD.is_match(&label(&p.parent().unwrap_or(p.clone())))).collect();
        let key = |p: &NodeRef| -> String { norm(&p.text()).chars().filter(|c| !c.is_whitespace()).take(30).collect() };
        let miss: Vec<&NodeRef> = ps.iter().filter(|p| !got.contains(&key(p))).collect();
        let all: usize = ps.iter().map(len_of).sum();
        let gone: usize = miss.iter().map(|p| len_of(p)).sum();
        partial = miss.len() >= 2 && gone as f64 > all as f64 * 0.25;
    }
    (content, partial)
}

// 캐러셀·슬라이드(맥 추출 스크립트 carousel-slides): Readability 가 칸을 버리고, 화면 밖 칸은 숨겨져 있다.
// 원문(fresh)에서 앞 글과 뒤 글이 모두 우리 본문에 있는 것(본문 사이)만 칸마다 글·사진을 순서대로 뒤 글 앞에 넣는다 — 본문 밖 추천 캐러셀은 넣지 않음.
// 복제 칸(무한 돌기)·같은 칸은 한 번만, 칸 글 대부분이 링크면(추천 기사 줄) 넣지 않음. 인용 카드가 속성에만 든 글(quote=·author-name=)은 인용으로
static CAR_TOK: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)^(swiper|swiper-container|glide|slick-slider|splide|flickity|owl-carousel|slideshow)$|carousel").unwrap());
static SLIDE_TOK: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)^(swiper-slide|glide__slide|slick-slide|splide__slide|owl-item|carousel-item|carousel-cell)$|(__|-)slide$").unwrap());
static CLONE_TOK: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)^(swiper-slide-duplicate|slick-cloned|cloned)$|--clone$").unwrap());
static CAR_TAG: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)-(carousel|slideshow)$").unwrap());
static SLIDE_TAG: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)-slide$").unwrap());
static CAR_BAD: Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)related|recommend|promo|popular|most-?read|trending|ranking|newsletter").unwrap());
static RECO_HEAD: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"(?i)^(recommended|related|read more|more on this|more from|keep reading|you may also like|also read|관련\s?기사|추천\s?기사|함께\s?(볼|읽을)|많이\s?본)").unwrap()
});
const CAR_TXT: &str = "p, li, h1, h2, h3, h4, h5, h6, blockquote";

fn esc(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}
fn is_car(n: &NodeRef) -> bool {
    attr(n, "aria-roledescription").eq_ignore_ascii_case("carousel") || CAR_TAG.is_match(&tag(n)) || attr(n, "class").split_whitespace().any(|c| CAR_TOK.is_match(c))
}
fn is_slide(n: &NodeRef) -> bool {
    attr(n, "aria-roledescription").eq_ignore_ascii_case("slide") || SLIDE_TAG.is_match(&tag(n)) || attr(n, "class").split_whitespace().any(|c| SLIDE_TOK.is_match(c))
}
fn is_clone(n: &NodeRef) -> bool {
    attr(n, "class").split_whitespace().any(|c| CLONE_TOK.is_match(c))
}
// 요소를 문서 순서(앞 순회)로 — 순서 번호로 앞뒤를 견준다
fn in_order<'a>(root: &NodeRef<'a>) -> Vec<NodeRef<'a>> {
    let mut out = vec![];
    let mut stack: Vec<NodeRef> = root.element_children().into_iter().rev().collect();
    while let Some(n) = stack.pop() {
        stack.extend(n.element_children().into_iter().rev());
        out.push(n);
    }
    out
}
// 바깥 것만(안에 든 같은 꼴은 바깥 것에 이미 들어 있다)
fn outer_only<'a>(list: Vec<NodeRef<'a>>) -> Vec<NodeRef<'a>> {
    let ids: HashSet<_> = list.iter().map(|n| n.id).collect();
    list.into_iter().filter(|n| !n.ancestors_it(None).any(|a| ids.contains(&a.id))).collect()
}

// 캐러셀 바깥 바로 앞 형제 제목(보안 낮음 L2) — 뿌리가 앞 형제 없이 감싸여 있으면 세 겹까지 올라가 본다.
// 앞 형제가 제목이거나, 글이 제목 하나뿐인 상자(머리말 상자)면 그 제목
fn head_before<'a>(r: &NodeRef<'a>) -> Option<NodeRef<'a>> {
    let mut s = r.clone();
    for _ in 0..3 {
        if s.prev_element_sibling().is_some() {
            break;
        }
        s = s.parent()?;
    }
    let p = s.prev_element_sibling()?;
    if matches!(tag(&p).as_str(), "h1" | "h2" | "h3" | "h4" | "h5" | "h6") {
        return Some(p);
    }
    let h = Selection::from(p.clone()).select("h1, h2, h3, h4, h5, h6").nodes().first().cloned()?;
    (norm(&h.text()) == norm(&p.text())).then_some(h)
}

pub fn carousel(content: &str, fresh: &Document) -> String {
    let Some(fbody) = body_of(fresh) else { return content.to_string() };
    let all = in_order(&fbody);
    let order: std::collections::HashMap<_, usize> = all.iter().enumerate().map(|(i, n)| (n.id, i)).collect();
    let roots: Vec<NodeRef> = outer_only(all.iter().filter(|n| is_car(n)).cloned().collect())
        .into_iter()
        .filter(|r| {
            !std::iter::once(r.clone()).chain(r.ancestors_it(None)).any(|a| matches!(tag(&a).as_str(), "nav" | "header" | "footer" | "aside"))
                && !CAR_BAD.is_match(&format!("{} {}", attr(r, "class"), attr(r, "data-component")))
        })
        .collect();
    if roots.is_empty() {
        return content.to_string();
    }
    let cur = Document::from(content);
    let Some(cbody) = body_of(&cur) else { return content.to_string() };
    let mut found: std::collections::HashMap<String, Vec<NodeRef>> = std::collections::HashMap::new();
    for e in cur.select(CAR_TXT).nodes() {
        found.entry(norm(&e.text())).or_default().push(e.clone());
    }
    // 같은 글이 차례(목차 li)에도 있으면 같은 태그를 앞세운다
    let pick = |m: &NodeRef| -> Vec<NodeRef> {
        let l = found.get(&norm(&m.text())).cloned().unwrap_or_default();
        let same: Vec<NodeRef> = l.iter().filter(|e| tag(e) == tag(m)).cloned().collect();
        if same.is_empty() { l } else { same }
    };
    let marks: Vec<NodeRef> = fresh
        .select(CAR_TXT)
        .nodes()
        .iter()
        .filter(|e| {
            let n = len_of(e);
            (n >= 12 || (tag(e).starts_with('h') && n >= 4)) && !roots.iter().any(|r| contains(r, e))
        })
        .cloned()
        .collect();
    // 칸 글 양 상한(보안 낮음 L3): 본문(캐러셀 밖 글 중 우리 본문에 있는 것) 글자의 2배, 적어도 3000자 · 칸 50개
    let body_len: usize = marks.iter().filter(|m| found.contains_key(&norm(&m.text()))).map(len_of).sum();
    let cap = (body_len * 2).max(3000);
    let mut added = false;
    for r in &roots {
        if [Selection::from(r.clone()).select("h1, h2, h3, h4, h5, h6").nodes().first().cloned(), head_before(r)]
            .iter()
            .flatten()
            .any(|hd| RECO_HEAD.is_match(&norm(&hd.text())))
        {
            continue;
        }
        // 순서 표는 캐러셀마다 새로(보안 낮음 L5) — 앞 캐러셀을 넣으며 지운 요소를 앞뒤 글로 고르지 않게
        let corder: std::collections::HashMap<_, usize> = in_order(&cbody).iter().enumerate().map(|(i, n)| (n.id, i)).collect();
        let cbefore = |a: &NodeRef, b: &NodeRef| corder.get(&a.id).zip(corder.get(&b.id)).is_some_and(|(x, y)| x < y);
        let ro = order[&r.id];
        let mut prev = None;
        let mut next = None;
        for m in &marks {
            let mo = order[&m.id];
            if mo < ro {
                prev = Some(m.clone());
            } else if mo > ro {
                next = Some(m.clone());
                break;
            }
        }
        let (Some(prev), Some(next)) = (prev, next) else { continue };
        let pms = pick(&prev);
        let Some(nm) = pick(&next).into_iter().find(|n| pms.iter().any(|q| cbefore(q, n))) else { continue };
        let Some(pm) = pms.iter().filter(|q| cbefore(q, &nm)).last().cloned() else { continue };
        let every = outer_only(in_order(r).into_iter().filter(|s| is_slide(s)).collect());
        let mut slides: Vec<NodeRef> = every.iter().filter(|s| !is_clone(s)).cloned().collect();
        if slides.is_empty() {
            continue;
        }
        let idx = |s: &NodeRef| attr(s, "data-swiper-slide-index").parse::<usize>().ok();
        if slides.iter().all(|s| idx(s).is_some()) {
            slides.sort_by_key(|s| idx(s)); // 안정 정렬 — 같은 번호는 문서 순서대로
        }
        let (mut wrap, mut keys, mut units, mut srcs) = (String::new(), Vec::<String>::new(), HashSet::<String>::new(), HashSet::<String>::new());
        let (mut text, mut link) = (0usize, 0usize);
        for s in &slides {
            // 상한을 넘은 칸은 넣지 않되, Readability 가 남긴 같은 칸은 지우게 글·사진만 적어 둔다
            if keys.len() >= 50 || text > cap {
                for e in std::iter::once(s.clone()).chain(Selection::from(s.clone()).select("p, li, h1, h2, h3, h4, h5, h6, blockquote, figcaption").nodes().iter().cloned()) {
                    let u = norm(&e.text());
                    if !u.is_empty() {
                        units.insert(u);
                    }
                }
                srcs.extend(Selection::from(s.clone()).select("img").nodes().iter().filter_map(|i| i.attr("src").or_else(|| i.attr("data-src")).map(|v| v.to_string())).filter(|v| !v.is_empty()));
                continue;
            }
            let d = Document::from(s.html().to_string().as_str());
            let Some(c) = body_of(&d).and_then(|b| b.first_element_child()) else { continue };
            Selection::from(c.clone())
                .select(r#"button, [role="tablist"], [class*="pagination" i], [class*="controls" i], [class*="arrow" i], [class*="dots" i]"#)
                .remove();
            for n in in_order(&c) {
                let q = norm(&n.attr("quote").or_else(|| n.attr("data-quote")).map(|v| v.to_string()).unwrap_or_default());
                if q.chars().count() < 20 {
                    continue;
                }
                let first = |a: &[&str]| a.iter().map(|k| attr(&n, k)).find(|v| !v.is_empty()).unwrap_or_default();
                let who: Vec<String> = [first(&["author-name", "data-author-name", "author"]), first(&["author-title", "data-author-title"])]
                    .iter()
                    .map(|v| norm(v))
                    .filter(|v| !v.is_empty())
                    .collect();
                let mut h = format!("<blockquote>{}</blockquote>", esc(&q));
                if !who.is_empty() {
                    h += &format!("<p>— {}</p>", esc(&who.join(", ")));
                }
                n.replace_with_html(h);
            }
            // 사진 없는 칸의 설명 상자는 문단으로 — 짝 잃은 설명처럼 작게 보이지 않게
            if Selection::from(c.clone()).select("img, picture").length() == 0 {
                for f in Selection::from(c.clone()).select("figcaption").nodes() {
                    f.replace_with_html(format!("<p>{}</p>", f.inner_html()));
                }
            }
            let t = norm(&c.text());
            let src: Vec<String> = Selection::from(c.clone())
                .select("img")
                .nodes()
                .iter()
                .map(|i| i.attr("src").or_else(|| i.attr("data-src")).map(|v| v.to_string()).unwrap_or_default())
                .filter(|v| !v.is_empty())
                .collect();
            let key = format!("{t}|{}", src.join(" "));
            if key == "|" || keys.contains(&key) {
                continue;
            }
            keys.push(key);
            if !t.is_empty() {
                units.insert(t.clone());
            }
            for e in Selection::from(c.clone()).select("p, li, h1, h2, h3, h4, h5, h6, blockquote, figcaption").nodes() {
                let u = norm(&e.text());
                if !u.is_empty() {
                    units.insert(u);
                }
            }
            srcs.extend(src);
            text += t.chars().count();
            link += Selection::from(c.clone()).select("a").nodes().iter().map(len_of).sum::<usize>();
            // 칸의 class(headline·features 등)로 손질이 글을 지우지 않게 꼴 속성은 뗀다(사진 주소 data-src·srcset 은 남김)
            for n in in_order(&c) {
                n.remove_attrs(&["class", "id", "style", "data-component", "data-block", "hidden", "aria-hidden"]);
            }
            wrap += &format!("<div>{}</div>", c.inner_html());
        }
        if wrap.is_empty() || (text > 0 && link as f64 >= text as f64 * 0.6) {
            continue;
        }
        for s in every.iter().filter(|s| is_clone(s)) {
            for e in std::iter::once(s.clone()).chain(Selection::from(s.clone()).select("p, li, figcaption").nodes().iter().cloned()) {
                let u = norm(&e.text());
                if !u.is_empty() {
                    units.insert(u);
                }
            }
        }
        // Readability 가 보이는 칸만 남겼으면(앞 글과 뒤 글 사이) 그것을 빼고 모든 칸을 차례대로 넣는다 — 같은 칸이 두 번·뒤섞여 나오지 않게
        let between = |e: &NodeRef| cbefore(&pm, e) && cbefore(e, &nm);
        for e in cur.select("p, li, h1, h2, h3, h4, h5, h6, blockquote, figcaption, div").nodes() {
            if between(e) && units.contains(&norm(&e.text())) {
                e.remove_from_parent();
            }
        }
        for e in cur.select("img").nodes() {
            let u = e.attr("src").or_else(|| e.attr("data-src")).map(|v| v.to_string()).unwrap_or_default();
            if !u.is_empty() && srcs.contains(&u) && between(e) {
                e.remove_from_parent();
            }
        }
        nm.before_html(format!("<div>{wrap}</div>"));
        added = true;
    }
    if added {
        format!("<div>{}</div>", cbody.inner_html())
    } else {
        content.to_string()
    }
}

// 손질을 마친 본문 HTML(뿌리 body 아래 전부 — 광고·관련 꼴까지 뺀 것)
pub fn pruned_body(content: &str) -> String {
    let d = Document::from(content);
    let Some(body) = body_of(&d) else { return String::new() };
    prune(&body, true);
    body.inner_html().to_string()
}

// <br> 은 빈칸으로(글이 붙지 않게) 이은 글
// (재귀 대신 스택 — 깊게 겹친 인라인 요소에서 스택이 넘치지 않게)
fn tx(n: &NodeRef) -> String {
    let mut out = String::new();
    let mut stack = vec![n.clone()];
    while let Some(c) = stack.pop() {
        if c.is_text() {
            out.push_str(&c.text());
        } else if c.is_element() {
            if tag(&c) == "br" {
                out.push(' ');
            } else {
                stack.extend(c.children_it(true));
            }
        }
    }
    out
}

const INLINE: &[&str] = &["a", "b", "strong", "em", "i", "u", "span", "font", "small", "mark", "abbr", "cite", "code", "time", "q", "s", "del", "ins", "sub", "sup", "label"];
const BLOCKISH: &[&str] = &["p", "div", "ul", "ol", "li", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "figure", "img", "picture", "table", "pre", "section", "article"];

fn has_block(n: &NodeRef) -> bool {
    n.descendants_it().any(|d| d.is_element() && BLOCKISH.contains(&tag(&d).as_str()))
}

// ③ 블록으로(맥 스크립트의 walk): 요소 사이 맨 글자(동아처럼 <br><br> 로 문단을 나눈 본문)도 문단으로 모은다
pub fn walk(el: &NodeRef, abs: &dyn Fn(Option<String>) -> Option<String>, out: &mut Vec<Block>) {
    let mut buf = String::new();
    let mut brs = 0;
    let flush = |buf: &mut String, brs: &mut i32, out: &mut Vec<Block>| {
        let t = clean_text(buf);
        if t.chars().count() > 1 {
            out.push(Block::text(BlockKind::P, t));
        }
        buf.clear();
        *brs = 0;
    };
    let first_img = |n: &NodeRef| -> Option<String> { Selection::from(n.clone()).select("img").nodes().first().and_then(|i| best_src(i, abs)) };
    for n in el.children_it(false) {
        if n.is_text() {
            let s = n.text();
            if !s.trim().is_empty() {
                brs = 0;
            }
            buf.push_str(&s);
            continue;
        }
        if !n.is_element() {
            continue;
        }
        let tg = tag(&n);
        if tg == "br" {
            brs += 1;
            if brs >= 2 {
                flush(&mut buf, &mut brs, out);
            } else {
                buf.push(' ');
            }
            continue;
        }
        if INLINE.contains(&tg.as_str()) && !has_block(&n) {
            buf.push_str(&tx(&n));
            brs = 0;
            continue;
        }
        flush(&mut buf, &mut brs, out);
        // 글은 쓰는 태그만 만든다(겹친 div 마다 하위 전체를 훑으면 깊이²)
        let t = if matches!(tg.as_str(), "h1" | "h2" | "h3" | "h4" | "h5" | "h6" | "p" | "li" | "blockquote" | "pre") { clean_text(&tx(&n)) } else { String::new() };
        match tg.as_str() {
            "h1" | "h2" | "h3" | "h4" | "h5" | "h6" => {
                if !t.is_empty() {
                    out.push(Block::text(BlockKind::H, t))
                }
            }
            "p" => {
                let src = first_img(&n);
                if !t.is_empty() {
                    out.push(Block::text(BlockKind::P, t))
                }
                if let Some(s) = src {
                    out.push(Block::img(s))
                }
            }
            "li" => {
                if !t.is_empty() {
                    out.push(Block::text(BlockKind::Li, t))
                }
            }
            "blockquote" => {
                if !t.is_empty() {
                    out.push(Block::text(BlockKind::Quote, t))
                }
            }
            "pre" => {
                if !t.is_empty() {
                    out.push(Block::text(BlockKind::Pre, n.text().to_string()))
                }
            }
            "img" => {
                if let Some(s) = best_src(&n, abs) {
                    out.push(Block::img(s))
                }
            }
            "picture" => {
                if let Some(s) = first_img(&n) {
                    out.push(Block::img(s))
                }
            }
            "figure" => {
                if let Some(s) = first_img(&n) {
                    out.push(Block::img(s))
                }
                let caps = Selection::from(n.clone()).select("figcaption");
                if let Some(cap) = caps.nodes().first() {
                    let c = clean_text(&tx(cap));
                    if !c.is_empty() {
                        out.push(Block::text(BlockKind::Cap, c))
                    }
                }
            }
            _ => walk(&n, abs, out),
        }
    }
    flush(&mut buf, &mut brs, out);
}

// 같은 글(30자 이상)·같은 사진이 또 나오면 뺀다(화면 크기별로 기사를 여러 벌 싣는 Politico, 부제·사진 설명 중복)
pub fn dedupe(blocks: Vec<Block>) -> Vec<Block> {
    let mut seen = HashSet::new();
    blocks
        .into_iter()
        .filter(|b| {
            let key = if b.kind == BlockKind::Img {
                Some(format!("img {}", b.src.as_deref().unwrap_or("")))
            } else {
                let t = b.text.as_deref().unwrap_or("");
                (t.chars().count() >= 30).then(|| format!("{:?} {t}", b.kind))
            };
            key.map(|k| seen.insert(k)).unwrap_or(true)
        })
        .collect()
}

// 기사 글은 거의 없고 목록(메뉴·많이 본 기사)만 많으면 본문이 아니다(사진뿐인 속보 등) — '글 거의 없음'
pub fn only_lists(blocks: &[Block]) -> bool {
    let sum = |kinds: &[BlockKind]| -> usize { blocks.iter().filter(|b| kinds.contains(&b.kind)).map(|b| b.text.as_deref().map(|t| t.chars().count()).unwrap_or(0)).sum() };
    let prose = sum(&[BlockKind::P, BlockKind::Quote, BlockKind::H]);
    let listed = sum(&[BlockKind::Li]);
    prose < 150 && listed > prose * 2
}

// 사이트가 유료 기사라고 적었나: ld+json "isAccessibleForFree": false · 한경 articlePayment = "Y"(앞 1MB만 봄, 맥 paidFlag)
pub fn paid_flag(html: &str) -> Option<bool> {
    static FREE: Lazy<Regex> = Lazy::new(|| Regex::new(r#""isAccessibleForFree"\s*:\s*"?(true|false|True|False)"#).unwrap());
    static PAY: Lazy<Regex> = Lazy::new(|| Regex::new(r#"articlePayment\s*=\s*["']Y["']"#).unwrap());
    let mut end = html.len().min(1_000_000);
    while !html.is_char_boundary(end) {
        end -= 1;
    }
    let h = &html[..end];
    if let Some(c) = FREE.captures(h) {
        return Some(c[1].eq_ignore_ascii_case("false"));
    }
    PAY.is_match(h).then_some(true)
}

// 사이트가 ld+json articleBody 로 적은 본문 글자 수(앞 1MB만, 여러 스크립트면 가장 긴 것 — 맥 ArticleExtractor.ldBodyLength).
// 맛보기 판정이 우리 본문과 견준다(paywall::matches_site_body). JSON 깊이는 serde_json 이 128 에서 막고, 찾기는 64 단계까지만
pub fn ld_body_length(html: &str) -> Option<usize> {
    fn find(v: &serde_json::Value, depth: usize) -> Option<&str> {
        if depth > 64 {
            return None;
        }
        match v {
            serde_json::Value::Object(m) => {
                if let Some(serde_json::Value::String(b)) = m.get("articleBody") {
                    if !b.is_empty() {
                        return Some(b);
                    }
                }
                m.values().find_map(|x| find(x, depth + 1))
            }
            serde_json::Value::Array(a) => a.iter().find_map(|x| find(x, depth + 1)),
            _ => None,
        }
    }
    let mut end = html.len().min(1_000_000);
    while !html.is_char_boundary(end) {
        end -= 1;
    }
    let lower = html[..end].to_ascii_lowercase(); // 아스키만 바꿔 바이트 자리가 그대로
    let h = &html[..end];
    let mut best: Option<usize> = None;
    let mut from = 0;
    while let Some(i) = lower[from..].find("application/ld+json") {
        let start = from + i + "application/ld+json".len();
        let Some(gt) = lower[start..].find('>') else { break };
        let open = start + gt + 1;
        let Some(close) = lower[open..].find("</script>") else { break };
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(&h[open..open + close]) {
            if let Some(b) = find(&v, 0) {
                let n = crate::feed_parser::plain::clean(b).chars().count();
                best = Some(best.unwrap_or(0).max(n));
            }
        }
        from = open + close + "</script>".len();
    }
    best
}
