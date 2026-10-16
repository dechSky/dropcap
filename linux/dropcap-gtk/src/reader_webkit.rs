// WebKitGTK 6 로 본문 추리기(webkit 기능 · 맥 Reader/ArticleExtractor.swift 와 같은 방식).
// 1) 빠른 길(R-01): 핵심이 받은 HTML 을 스크립트를 끈 웹 보기에 base 주소와 함께 넣고, 맥과 같은 Readability.js 로 추린다.
//    그림·동영상·글꼴·스타일·스크립트 등은 내용 차단 규칙으로 아예 받지 않는다(S-06·S-10).
// 2) 느린 길(R-02): 사용자가 연 기사만, 스크립트를 켠 웹 보기로 실제로 띄워 0.6초 뒤부터 0.4초마다 추리고 두 번 같으면 끝(최대 15초).
// 추출 스크립트는 페이지와 떨어진 world("dropcap")에서 돈다 — 페이지 스크립트가 건드리지 못한다(S-11).
// 웹 보기 안의 이동은 about:·data: 외에는 url_safety::resolves_public 을 통과해야 한다(S-05, 비동기 판단).
// 그와 별도로 웹 보기의 모든 요청은 핵심의 guard_proxy 를 거쳐, 하위 요청·DNS 바꿔치기도 연결 순간에 막힌다.
// 핵심(tokio 스레드)의 Extract 호출은 메인 루프로 넘겨 처리하고 결과만 돌려준다(WebKit 은 메인 스레드 전용).
use crate::app::{bg, resource, ui};
use dropcap_core::article::{Article, Extract};
use gtk::glib;
use gtk::prelude::*;
use std::cell::RefCell;
use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::time::{Duration, Instant};
use webkit6::prelude::*;

const WORLD: &str = "dropcap";
const UA: &str = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15";

const FAST_BLOCK: [&str; 11] = ["image", "media", "font", "style-sheet", "script", "raw", "svg-document", "popup", "fetch", "websocket", "other"];
const SLOW_BLOCK: [&str; 5] = ["image", "media", "font", "popup", "websocket"];

// 맥 ArticleExtractor.script 와 같은 추출 스크립트(글자째 같음 — READER-CUT.md 2단계: 본문 밖 상자·각주 빼기, articleBody 우선, 형제 덩어리 모으기,
// 일부만·유료 표시, 맨 글자 문단·<br> 빈칸, 같은 글 한 번만, 목록뿐이면 빈 본문). 웹 엔진이 없을 때는 핵심의 reader_extract 가 같은 순서로
const SCRIPT: &str = r#"(() => {
  const norm = (s) => (s || '').replace(/\s+/g, ' ').trim();
  const doc = document.cloneNode(true);
  doc.querySelectorAll('.sr-only, .visually-hidden, .screen-reader-text, [class*="sr-only"], [class*="visually-hidden"]').forEach((n) => n.remove());
  // 본문 밖 상자(기자 소개·댓글 수·공유·단추)는 미리 뺀다. 페이지 글의 30% 넘는 상자는 건드리지 않는다(본문을 지우지 않게)
  const total = norm(doc.body ? doc.body.textContent : '').length || 1;
  doc.querySelectorAll('.author-mini-bio, [class*="author-bio" i], [class*="authorbio" i], [class*="author-box" i], [class*="authorbox" i], [class*="author-card" i], [class*="about-author" i], [class*="about-the-author" i], [class*="author-info" i], [class*="bio-box" i], [class*="byline-bio" i], [class*="contributor-bio" i], .story-tools, .view-comments, [class*="comment-count" i], [class*="comments-link" i], [class*="share-bar" i], [class*="social-share" i], [class*="hide-caption" i], [class*="toggle-caption" i], button')
    .forEach((n) => { if (n.isConnected && norm(n.textContent).length < total * 0.3) n.remove(); });
  doc.querySelectorAll('a[href*="/author/" i] img, a[href*="/authors/" i] img, a[href*="/people/" i] img, a[href*="/staff/" i] img, a[href*="/reporter/" i] img').forEach((n) => n.remove()); // 기자 얼굴
  doc.querySelectorAll('sup').forEach((n) => { if (/^\[?\s*\d{1,3}\s*\]?$/.test(norm(n.textContent))) n.remove(); }); // 각주 번호
  // 기본 기준(500자)으로 못 찾으면 짧은 글(GeekNews 소개글 등)을 위해 100자 기준으로 한 번 더(parse 가 문서를 고치므로 새 사본으로)
  const fresh = doc.cloneNode(true);
  let art = new Readability(doc).parse();
  if (!art || !art.content) art = new Readability(fresh.cloneNode(true), { charThreshold: 100 }).parse();
  // 그래도 못 찾으면: 본문으로 보이는 영역(id·class 에 content·article·topic·post·entry·body 가 든 것) 가운데 글이 가장 많은 곳
  if (!art || !art.content) {
    let best = null, bestLen = 0;
    fresh.querySelectorAll('article, main, [id*="content" i], [class*="content" i], [id*="topic" i], [class*="article" i], [class*="post" i], [class*="entry" i], [itemprop="articleBody"]').forEach((el) => {
      if (el.closest('nav, header, footer, aside')) return;
      const len = (el.textContent || '').replace(/\s+/g, ' ').trim().length;
      if (len > bestLen && len < 40000) { best = el; bestLen = len; }
    });
    if (best && bestLen >= 80) {
      best = best.cloneNode(true);
      best.querySelectorAll('script, style, nav, form, button, .related-topics, [class*="related" i], [class*="share" i]').forEach((n) => n.remove());
      art = { title: document.title, content: '<div>' + best.innerHTML + '</div>' };
    }
  }
  if (!art || !art.content) return null;
  let content = art.content, partial = false;
  const parse = (h) => new DOMParser().parseFromString(h, 'text/html').body;
  const lenOf = (el) => norm(el.textContent).length;
  const longP = (el) => [...el.querySelectorAll('p')].filter((p) => lenOf(p) >= 80);
  const BAD = /related|recommend|share|social|promo|newsletter|comment|sidebar|links|tags?\b|topic|footer|nav|advert|popular|most-?read|author|byline|headline|elsewhere|features|top-?stories/i;
  const isAd = (el) => /(^|[\s_-])(ad|ads|adv|advert|advertisement|banner|sponsor)([\s_-]|$)/i.test((el.className && el.className.baseVal === undefined ? el.className : '') + ' ' + (el.id || ''));
  const label = (el) => (el.className && el.className.baseVal === undefined ? el.className : '') + ' ' + (el.getAttribute('data-component') || '') + ' ' + (el.getAttribute('data-block') || '');
  const prune = (root) => { root.querySelectorAll('script, style, nav, form, aside, iframe').forEach((n) => n.remove()); root.querySelectorAll('*').forEach((n) => { if (n.isConnected && (isAd(n) || BAD.test(label(n)))) n.remove(); }); return root; };
  // Readability 가 고른 글이 원문 문서 어디인지(첫 긴 문단으로 찾음)
  const firstOf = (body) => { const p = [...body.querySelectorAll('p')].find((x) => lenOf(x) >= 40); return p ? norm(p.textContent).slice(0, 40) : ''; };
  const first = firstOf(parse(content));
  const anchor = first ? [...fresh.querySelectorAll('p')].find((p) => norm(p.textContent).startsWith(first)) : null;
  // B: itemprop=articleBody 가 따로 있는데 고른 글이 그 밖이면(옆 상자를 고름) 그쪽을 쓴다
  const ip = [...fresh.querySelectorAll('[itemprop="articleBody"]')].find((e) => lenOf(e) >= 300);
  if (ip && !(anchor && ip.contains(anchor)) && lenOf(ip) >= lenOf(parse(content)) * 0.3) {
    content = '<div>' + prune(ip.cloneNode(true)).innerHTML + '</div>';
  } else if (anchor) {
    // A: 본문이 광고·사진을 사이에 둔 여러 덩어리면(같은 꼴의 형제) 모두 순서대로 모은다
    const firstClass = (el) => ((el.className && el.className.baseVal === undefined ? el.className : '').trim().split(/\s+/)[0] || '');
    const alike = (a, b) => a.tagName === b.tagName && ((a.hasAttribute('data-block') && b.hasAttribute('data-block')) || (a.hasAttribute('data-component') && b.hasAttribute('data-component')) || (firstClass(a) !== '' && firstClass(a) === firstClass(b)));
    // 형제가 같은 꼴이거나, 겉 포장이 달라도 안에 본문 상자와 같은 class 의 상자가 있으면(Ars: div.my-2.5 > … > .post-content) 같은 본문
    const core = anchor.parentElement, coreClass = firstClass(core);
    // 같은 class 가 겹치면 바깥 상자만(후손은 바깥 사본에 이미 들어 있다 — 겹마다 복사하면 크기·시간이 N²)
    const outer = (list) => { const r = []; for (const c of list) if (!r.length || !r[r.length - 1].contains(c)) r.push(c); return r; };
    const cores = (k, el) => k === el || alike(k, el) || !coreClass || k.classList.contains(coreClass) ? [k] : outer([...k.querySelectorAll('.' + CSS.escape(coreClass))]);
    for (let el = core, depth = 0; el && el.parentElement && depth < 6; el = el.parentElement, depth++) {
      const kids = [...el.parentElement.children].filter((k) => k === el || ((alike(k, el) || (coreClass && k.querySelector('.' + CSS.escape(coreClass)))) && !BAD.test(label(k)) && !isAd(k)));
      const texty = kids.filter((k) => longP(k).length > 0);
      if (texty.length < 2 || !texty.includes(el)) continue;
      const from = kids.indexOf(texty[0]), to = kids.indexOf(texty[texty.length - 1]);
      // 모은 상자는 비활성 사본 문서(fresh)에서 만든다 — 살아 있는 문서에 붙이면 <img> 받기·onerror 가 돌 수 있다
      const box = fresh.createElement('div');
      // 모은 글이 원문 글의 2배를 넘으면(겹친 상자를 거듭 담은 꼴) 모으기를 그만둔다
      let size = 0; const cap = fresh.body ? fresh.body.textContent.length * 2 + 1000 : 0;
      kids.slice(from, to + 1).forEach((k) => cores(k, el).forEach((c) => { size += c.textContent.length; if (size <= cap) box.appendChild(prune(c.cloneNode(true))); }));
      // 글이 15% 넘게 늘거나, 글은 비슷한데(90% 이상) 사진이 더 있으면(BBC: Readability 가 사진 블록을 버림) 모은 쪽
      const cur = parse(content), more = lenOf(box) >= lenOf(cur) * 1.15;
      const pics = lenOf(box) >= lenOf(cur) * 0.9 && box.querySelectorAll('img').length > cur.querySelectorAll('img').length;
      if (size <= cap && (more || pics)) content = '<div>' + box.innerHTML + '</div>';
      break;
    }
    // 본문 영역(itemprop·article)에 우리 글에 없는 긴 문단이 여럿 남으면 '일부만'
    const area = ip || anchor.closest('article');
    if (area) {
      const got = norm(parse(content).textContent).replace(/\s/g, '');
      const ps = longP(area).filter((p) => !BAD.test(label(p.parentElement || p)));
      const miss = ps.filter((p) => !got.includes(norm(p.textContent).replace(/\s/g, '').slice(0, 30)));
      const all = ps.reduce((s, p) => s + lenOf(p), 0), gone = miss.reduce((s, p) => s + lenOf(p), 0);
      partial = miss.length >= 2 && gone > all * 0.25;
    }
  }
  // 캐러셀·슬라이드(Google 블로그 영상·인용 카드 · swiper·slick·glide·splide·owl): Readability 가 칸을 버리고, 화면 밖 칸은 숨겨져 있다(carousel-slides).
  // 원문에서 앞 글과 뒤 글이 모두 우리 본문에 있는 것(본문 사이)만 칸마다 글·사진을 순서대로 뒤 글 앞에 넣는다 — 본문 밖 추천 캐러셀은 넣지 않음.
  // 복제 칸(무한 돌기)·같은 칸은 한 번만, 칸 글 대부분이 링크면(추천 기사 줄) 넣지 않음. 인용 카드가 속성에만 든 글(quote=·author-name=)은 인용으로
  {
    const ckl = (el) => (el.className && el.className.baseVal === undefined ? el.className : '');
    const toks = (el) => ckl(el).split(/\s+/).filter((x) => x);
    const isCar = (el) => /^carousel$/i.test(el.getAttribute('aria-roledescription') || '') || /-(carousel|slideshow)$/i.test(el.tagName)
      || toks(el).some((c) => /^(swiper|swiper-container|glide|slick-slider|splide|flickity|owl-carousel|slideshow)$/i.test(c) || /carousel/i.test(c));
    const isSlide = (el) => /^slide$/i.test(el.getAttribute('aria-roledescription') || '') || /-slide$/i.test(el.tagName)
      || toks(el).some((c) => /^(swiper-slide|glide__slide|slick-slide|splide__slide|owl-item|carousel-item|carousel-cell)$/i.test(c) || /(__|-)slide$/i.test(c));
    const isClone = (el) => toks(el).some((c) => /^(swiper-slide-duplicate|slick-cloned|cloned)$/i.test(c) || /--clone$/i.test(c));
    const outerOf = (list) => list.filter((x) => !list.some((y) => y !== x && y.contains(x)));
    const cln = (el) => norm(el.textContent).length;
    const all = [...fresh.querySelectorAll('*')];
    const roots = outerOf(all.filter(isCar)).filter((r) => !r.closest('nav, header, footer, aside') && !/related|recommend|promo|popular|most-?read|trending|ranking|newsletter/i.test(ckl(r) + ' ' + (r.getAttribute('data-component') || '')));
    if (roots.length) {
      const cur = parse(content);
      const TXT = 'p, li, h1, h2, h3, h4, h5, h6, blockquote';
      const found = new Map();
      cur.querySelectorAll(TXT).forEach((e) => { const t = norm(e.textContent); if (!found.has(t)) found.set(t, []); found.get(t).push(e); });
      // 같은 글이 차례(목차 li)에도 있으면 같은 태그를 앞세운다
      const pick = (m) => { const l = (m && found.get(norm(m.textContent))) || []; const same = l.filter((e) => e.tagName === m.tagName); return same.length ? same : l; };
      const marks = [...fresh.querySelectorAll(TXT)].filter((e) => { const n = cln(e); return (n >= 12 || (/^H/.test(e.tagName) && n >= 4)) && !roots.some((r) => r.contains(e)); });
      const before = (a, b) => !!(a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING);
      const RECO_HEAD = /^(recommended|related|read more|more on this|more from|keep reading|you may also like|also read|관련\s?기사|추천\s?기사|함께\s?(볼|읽을)|많이\s?본)/i;
      let added = false;
      roots.forEach((r) => {
        const hd = r.querySelector('h1, h2, h3, h4, h5, h6');
        if (hd && RECO_HEAD.test(norm(hd.textContent))) return;
        let prev = null, next = null;
        for (const m of marks) { if (before(m, r)) prev = m; else if (before(r, m)) { next = m; break; } }
        const pms = pick(prev), nm = pick(next).find((n) => pms.some((q) => before(q, n)));
        if (!nm) return;
        const pm = pms.filter((q) => before(q, nm)).pop();
        const every = outerOf(all.filter((s) => s !== r && r.contains(s) && isSlide(s)));
        let slides = every.filter((s) => !isClone(s));
        if (!slides.length) return;
        const idx = (s) => s.getAttribute('data-swiper-slide-index') || '';
        if (slides.every((s) => /^\d+$/.test(idx(s)))) slides = slides.map((s, i) => [s, i]).sort((a, b) => (+idx(a[0]) - +idx(b[0])) || a[1] - b[1]).map((x) => x[0]);
        const wrap = fresh.createElement('div'), keys = [], units = new Set(), srcs = new Set();
        let text = 0, link = 0;
        slides.forEach((s) => {
          const c = s.cloneNode(true);
          c.querySelectorAll('button, [role="tablist"], [class*="pagination" i], [class*="controls" i], [class*="arrow" i], [class*="dots" i]').forEach((n) => n.remove());
          c.querySelectorAll('*').forEach((n) => {
            const q = norm(n.getAttribute('quote') || n.getAttribute('data-quote') || '');
            if (q.length < 20) return;
            const bq = fresh.createElement('blockquote'); bq.textContent = q;
            const who = [n.getAttribute('author-name') || n.getAttribute('data-author-name') || n.getAttribute('author') || '', n.getAttribute('author-title') || n.getAttribute('data-author-title') || ''].map(norm).filter((x) => x).join(', ');
            n.replaceWith(bq);
            if (who) { const p = fresh.createElement('p'); p.textContent = '— ' + who; bq.after(p); }
          });
          // 사진 없는 칸의 설명 상자(앞에서 figcaption 으로 바꾼 것)는 문단으로 — 짝 잃은 설명처럼 작게 보이지 않게
          if (!c.querySelector('img, picture')) c.querySelectorAll('figcaption').forEach((f) => { const p = fresh.createElement('p'); while (f.firstChild) p.appendChild(f.firstChild); f.replaceWith(p); });
          const t = norm(c.textContent), src = [...c.querySelectorAll('img')].map((i) => i.getAttribute('src') || i.getAttribute('data-src') || '').filter((x) => x), key = t + '|' + src.join(' ');
          if (key === '|' || keys.includes(key)) return;
          keys.push(key);
          if (t) units.add(t);
          c.querySelectorAll('p, li, h1, h2, h3, h4, h5, h6, blockquote, figcaption').forEach((e) => { const u = norm(e.textContent); if (u) units.add(u); });
          src.forEach((x) => srcs.add(x));
          text += t.length; link += [...c.querySelectorAll('a')].reduce((z, a) => z + cln(a), 0);
          // 칸의 class(headline·features 등)로 prune 이 글을 지우지 않게 꼴 속성은 뗀다(사진 주소 data-src·srcset 은 남김)
          c.querySelectorAll('*').forEach((n) => ['class', 'id', 'style', 'data-component', 'data-block', 'hidden', 'aria-hidden'].forEach((a) => n.removeAttribute(a)));
          const d = fresh.createElement('div'); // 칸이 li 여도(owl·slick) 걷기가 한 줄로 뭉치지 않게 div 로
          while (c.firstChild) d.appendChild(c.firstChild);
          wrap.appendChild(d);
        });
        if (!wrap.firstChild || (text && link >= text * 0.6)) return;
        every.filter(isClone).forEach((s) => { const u = norm(s.textContent); if (u) units.add(u); s.querySelectorAll('p, li, figcaption').forEach((e) => { const v = norm(e.textContent); if (v) units.add(v); }); });
        // Readability 가 보이는 칸만 남겼으면(앞 글과 뒤 글 사이) 그것을 빼고 모든 칸을 차례대로 넣는다 — 같은 칸이 두 번·뒤섞여 나오지 않게
        const between = (e) => before(pm, e) && before(e, nm);
        cur.querySelectorAll('p, li, h1, h2, h3, h4, h5, h6, blockquote, figcaption, div').forEach((e) => { if (e.isConnected && between(e) && units.has(norm(e.textContent))) e.remove(); });
        cur.querySelectorAll('img').forEach((e) => { const u = e.getAttribute('src') || e.getAttribute('data-src') || ''; if (u && srcs.has(u) && between(e)) e.remove(); });
        nm.before(wrap);
        added = true;
      });
      if (added) content = '<div>' + cur.innerHTML + '</div>';
    }
  }
  const box = prune(parse(content));
  // 유료 표시: ld+json isAccessibleForFree=false 또는 한경 articlePayment="Y"
  // ldBody: 사이트가 ld+json articleBody 로 적은 본문 글자 수(맛보기 판정 — 맥과 같음)
  let paid = null, ldBody = null;
  document.querySelectorAll('script[type="application/ld+json"]').forEach((s) => {
    const m = (s.textContent || '').match(/"isAccessibleForFree"\s*:\s*"?(true|false)"?/i);
    if (m && paid === null) paid = m[1].toLowerCase() === 'false';
    const find = (v, d) => { if (!v || typeof v !== 'object' || d > 64) return null; if (typeof v.articleBody === 'string' && v.articleBody) return v.articleBody; for (const k in v) { const r = find(v[k], d + 1); if (r) return r; } return null; };
    try { const b = find(JSON.parse(s.textContent || ''), 0); if (b) ldBody = Math.max(ldBody || 0, norm(b.replace(/<[^>]*>/g, ' ')).length); } catch (e) {}
  });
  if (paid !== true) for (const s of document.querySelectorAll('script:not([src])')) { if (/articlePayment\s*=\s*["']Y["']/.test(s.textContent || '')) { paid = true; break; } }
  const blocks = [];
  const abs = (u) => { try { const h = new URL(u, location.href).href; return /^https?:/.test(h) ? h : null; } catch { return null; } };
  // 늦게 불러오는 사진은 src 가 빈 자리표시이고 진짜 주소는 srcset·data-* 에 있다 — 가장 큰 진짜 주소를 고른다
  const bestSrc = (img) => {
    if (!img) return null;
    const cands = [];
    const fromSet = (v) => (v || '').split(',').map(x => x.trim().split(/\s+/)).forEach(([u, d]) => {
      if (u) cands.push([u, parseFloat(d) || (d && d.endsWith('x') ? parseFloat(d) * 1000 : 1)]);
    });
    fromSet(img.getAttribute('srcset')); fromSet(img.getAttribute('data-srcset'));
    const pic = img.closest('picture');
    if (pic) pic.querySelectorAll('source').forEach(s => fromSet(s.getAttribute('srcset') || s.getAttribute('data-srcset')));
    cands.sort((a, b) => b[1] - a[1]);
    for (const [u] of cands) { const h = abs(u); if (h) return h; }
    for (const a of ['data-src', 'data-lazy-src', 'data-original', 'data-url', 'src']) {
      const v = img.getAttribute(a);
      if (v && !v.startsWith('data:')) { const h = abs(v); if (h && !/(1x1|spacer|blank|pixel)\.(gif|png)/i.test(h)) return h; }
    }
    return null;
  };
  const clean = (s) => (s || '').replace(/\((opens in a new (window|tab)|새 창에서 열기)\)/gi, '').replace(/\b(hide|toggle) caption\b/gi, '').replace(/\s+/g, ' ').trim();
  // <br> 은 빈칸으로(글이 붙지 않게)
  const tx = (n) => { const c = n.cloneNode(true); c.querySelectorAll('br').forEach((b) => b.replaceWith(' ')); return c.textContent; };
  const INLINE = new Set(['a', 'b', 'strong', 'em', 'i', 'u', 'span', 'font', 'small', 'mark', 'abbr', 'cite', 'code', 'time', 'q', 's', 'del', 'ins', 'sub', 'sup', 'label']);
  const hasBlock = (n) => !!n.querySelector('p, div, ul, ol, li, h1, h2, h3, h4, h5, h6, blockquote, figure, img, picture, table, pre, section, article');
  const walk = (el) => {
    // 요소 사이 맨 글자(동아처럼 <br><br> 로 문단을 나눈 본문)도 문단으로 모은다
    let buf = '', brs = 0;
    const flush = () => { const t = clean(buf); if (t.length > 1) blocks.push({ type: 'p', text: t }); buf = ''; brs = 0; };
    for (const n of el.childNodes) {
      if (n.nodeType === 3) { if (n.textContent.trim()) brs = 0; buf += n.textContent; continue; }
      if (n.nodeType !== 1) continue;
      const tag = n.tagName.toLowerCase();
      if (tag === 'br') { brs++; if (brs >= 2) flush(); else buf += ' '; continue; }
      if (INLINE.has(tag) && !hasBlock(n)) { buf += tx(n); brs = 0; continue; }
      flush();
      // 글은 쓰는 태그만 만든다(겹친 div 마다 하위 전체를 복사하면 깊이²)
      const t = /^(h[1-6]|p|li|blockquote|pre)$/.test(tag) ? clean(tx(n)) : '';
      if (/^h[1-6]$/.test(tag)) { if (t) blocks.push({ type: 'h', text: t }); }
      else if (tag === 'p') {
        const img = n.querySelector('img'); const src = bestSrc(img);
        if (t) blocks.push({ type: 'p', text: t });
        if (src) blocks.push({ type: 'img', src });
      }
      else if (tag === 'li') { if (t) blocks.push({ type: 'li', text: t }); }
      else if (tag === 'blockquote') { if (t) blocks.push({ type: 'quote', text: t }); }
      else if (tag === 'pre') { if (t) blocks.push({ type: 'pre', text: n.textContent }); }
      else if (tag === 'img') { const s = bestSrc(n); if (s) blocks.push({ type: 'img', src: s }); }
      else if (tag === 'picture') { const s = bestSrc(n.querySelector('img')); if (s) blocks.push({ type: 'img', src: s }); }
      else if (tag === 'figure') {
        const s = bestSrc(n.querySelector('img'));
        if (s) blocks.push({ type: 'img', src: s });
        const cap = n.querySelector('figcaption'); const c = cap && clean(tx(cap));
        if (c) blocks.push({ type: 'cap', text: c });
      }
      else walk(n);
    }
    flush();
  };
  walk(box);
  // 문단 태그 없이 맨 글자로 든 본문(GeekNews 등): 줄 단위로 문단을 만든다
  if (!blocks.some((b) => b.type === 'p' || b.type === 'li')) {
    (box.innerText || box.textContent || '').split(/\n+/).map(clean).filter((t) => t.length > 1).forEach((t) => blocks.push({ type: 'p', text: t }));
  }
  // 같은 글·같은 사진이 또 나오면 뺀다(화면 크기별로 기사를 여러 벌 싣는 사이트 — Politico, 부제·사진 설명 중복)
  const seen = new Set();
  const uniq = blocks.filter((b) => { const k = b.type === 'img' ? 'img ' + b.src : ((b.text || '').length >= 30 ? b.type + ' ' + b.text : null); if (!k) return true; if (seen.has(k)) return false; seen.add(k); return true; });
  blocks.length = 0; blocks.push(...uniq);
  // 기사 글은 거의 없고 목록(메뉴·많이 본 기사)만 많으면 본문이 아니다(사진뿐인 속보 등) — 빈 본문으로 돌려 '글 거의 없음' 안내
  const sum = (types) => blocks.filter((b) => types.includes(b.type)).reduce((s, b) => s + (b.text || '').length, 0);
  const prose = sum(['p', 'quote', 'h']), listed = sum(['li']);
  if (prose < 150 && listed > prose * 2) return JSON.stringify({ title: art.title, blocks: [] });
  return JSON.stringify({ title: art.title, byline: art.byline, siteName: art.siteName, blocks, paid, partial: partial || null, ldBody });
})();"#;

thread_local! {
    static READABILITY: String = std::fs::read_to_string(resource("Readability.js")).unwrap_or_default();
    static FILTERS: RefCell<HashMap<&'static str, webkit6::UserContentFilter>> = RefCell::new(HashMap::new());
}

type Fut = Pin<Box<dyn Future<Output = Option<Article>> + Send>>;

struct WebExtract;

// 메인 루프에서 f 를 돌리고 결과를 tokio 쪽으로
fn on_main<F, R>(f: F) -> Fut
where
    F: FnOnce() -> R + Send + 'static,
    R: Future<Output = Option<Article>> + 'static,
{
    let (tx, rx) = tokio::sync::oneshot::channel();
    glib::MainContext::default().invoke(move || {
        let fut = f();
        glib::spawn_future_local(async move {
            let _ = tx.send(fut.await);
        });
    });
    Box::pin(async move { rx.await.ok().flatten() })
}

impl Extract for WebExtract {
    fn fast(&self, html: String, base: String) -> Fut {
        on_main(move || run_fast(html, base))
    }
    fn slow(&self, url: String) -> Fut {
        on_main(move || run_slow(url, 15))
    }
    fn slow_for(&self, url: String, max_secs: u64) -> Fut {
        on_main(move || run_slow(url, max_secs))
    }
}

// 웹 보기의 모든 요청이 거치는 안전 검사 프록시의 포트(못 띄우면 웹 엔진을 쓰지 않음 — fail closed)
static PROXY_PORT: std::sync::OnceLock<u16> = std::sync::OnceLock::new();

pub fn install() {
    let ui = ui();
    match dropcap_core::guard_proxy::start() {
        Ok(port) => {
            let _ = PROXY_PORT.set(port);
            ui.core.articles.set_extractor(Arc::new(WebExtract));
        }
        Err(e) => log::warn!("[기사] 안전 검사 프록시를 띄우지 못해 웹 엔진 추출을 끔: {e}"),
    }
}

// 차단 규칙(맥 WKContentRuleList 와 같은 JSON). 한 번 만들면 이번 실행 동안 다시 쓴다.
async fn filter(id: &'static str, types: &[&str]) -> Option<webkit6::UserContentFilter> {
    if let Some(f) = FILTERS.with(|m| m.borrow().get(id).cloned()) {
        return Some(f);
    }
    let rule = serde_json::json!([{ "trigger": { "url-filter": ".*", "resource-type": types }, "action": { "type": "block" } }]);
    let dir = ui().core.store.dir.join("webkit-filters");
    let _ = std::fs::create_dir_all(&dir);
    let store = webkit6::UserContentFilterStore::new(&dir.to_string_lossy());
    match store.save_future(id, &glib::Bytes::from_owned(rule.to_string().into_bytes())).await {
        Ok(f) => {
            FILTERS.with(|m| m.borrow_mut().insert(id, f.clone()));
            Some(f)
        }
        Err(e) => {
            log::warn!("[기사] 차단 규칙을 만들지 못함: {e}");
            None
        }
    }
}

struct Web {
    view: webkit6::WebView,
    holder: gtk::Window,
}

impl Drop for Web {
    fn drop(&mut self) {
        self.view.stop_loading();
        self.holder.destroy();
    }
}

async fn make_web(js: bool, block: &[&str], id: &'static str) -> Option<Web> {
    let settings = webkit6::Settings::new();
    settings.set_enable_javascript(true); // 앱이 넣는 추출 스크립트는 돈다
    settings.set_enable_javascript_markup(js); // 꺼지면 페이지 자신의 스크립트는 돌지 않음
    settings.set_auto_load_images(false);
    settings.set_enable_media(false);
    settings.set_enable_webaudio(false);
    settings.set_media_playback_requires_user_gesture(true);
    settings.set_user_agent(Some(UA));
    let ucm = webkit6::UserContentManager::new();
    // 차단 규칙이 없으면 빠른 길은 쓰지 않는다(그림·스크립트를 받지 않는다는 약속을 지킬 수 없으므로)
    match filter(id, block).await {
        Some(f) => ucm.add_filter(&f),
        None if !js => return None,
        None => {}
    }
    // 모든 요청(이동·하위 요청·fetch·iframe)을 안전 검사 프록시로: 접속 순간 IP 검사(S-03·S-05)
    let port = *PROXY_PORT.get()?;
    let session = webkit6::NetworkSession::new_ephemeral();
    let proxy = webkit6::NetworkProxySettings::new(Some(&format!("http://127.0.0.1:{port}")), &[]);
    session.set_proxy_settings(webkit6::NetworkProxyMode::Custom, Some(&proxy));
    // 숨은 웹 보기는 아무것도 내려받지 않는다(meta refresh·첨부 응답으로 ~/Downloads 에 몰래 받기 막음)
    session.connect_download_started(|_, d| {
        log::warn!("[기사] 웹 보기의 내려받기를 막음");
        d.cancel();
    });
    let view = webkit6::WebView::builder().settings(&settings).user_content_manager(&ucm).network_session(&session).build();
    view.set_size_request(1200, 900);
    // 이동 검사(S-05): 결정을 붙잡아 두고 이름 풀기까지 마친 뒤 허락·거절
    view.connect_decide_policy(|_, decision, kind| match kind {
        webkit6::PolicyDecisionType::NewWindowAction => {
            decision.ignore(); // 새 창(팝업)은 열지 않음
            true
        }
        webkit6::PolicyDecisionType::NavigationAction => {
            let uri = decision
                .downcast_ref::<webkit6::NavigationPolicyDecision>()
                .and_then(|d| d.navigation_action())
                .and_then(|a| a.request())
                .and_then(|r| r.uri())
                .map(|u| u.to_string())
                .unwrap_or_default();
            if uri.starts_with("about:") {
                decision.use_();
                return true;
            }
            // data: 이동은 쓰지 않는다(본문 추리기에 필요 없음, 페이지가 만든 문서로 옮겨 가는 길을 막음)
            if uri.starts_with("data:") {
                decision.ignore();
                return true;
            }
            if !dropcap_core::url_safety::is_public_http(&uri) {
                decision.ignore();
                return true;
            }
            let d = decision.clone();
            bg(async move { dropcap_core::url_safety::resolves_public(&uri).await }, move |ok| if ok { d.use_() } else { d.ignore() });
            true
        }
        webkit6::PolicyDecisionType::Response => {
            // 보여 줄 수 없는 종류(파일)·첨부로 온 응답은 받지 않는다(내려받기로 바뀌지 않게)
            let Some(r) = decision.downcast_ref::<webkit6::ResponsePolicyDecision>() else {
                decision.ignore();
                return true;
            };
            if dropcap_core::url_safety::web_response_allowed(r.is_mime_type_supported(), r.response().and_then(|x| x.http_headers()).and_then(|h| h.one("Content-Disposition")).as_deref()) {
                decision.use_();
            } else {
                decision.ignore();
            }
            true
        }
        _ => false,
    });
    let holder = gtk::Window::new();
    holder.set_default_size(1200, 900);
    holder.set_child(Some(&view));
    Some(Web { view, holder })
}

// 다 뜨기(또는 실패)를 기다린다. 최대 secs 초.
async fn wait_for_load(view: &webkit6::WebView, secs: u64) {
    let (tx, rx) = async_channel::bounded::<()>(2);
    let t1 = tx.clone();
    let h1 = view.connect_load_changed(move |_, ev| {
        if ev == webkit6::LoadEvent::Finished {
            let _ = t1.try_send(());
        }
    });
    let h2 = view.connect_load_failed(move |_, _, _, _| {
        let _ = tx.try_send(());
        false
    });
    let _ = glib::future_with_timeout(Duration::from_secs(secs), rx.recv()).await;
    view.disconnect(h1);
    view.disconnect(h2);
}

// 앱이 가진 고정 스크립트(Readability.js·추출 스크립트)만 떨어진 world 에서 돌린다 — 페이지에서 온 글자를 코드로 돌리지 않음
async fn eval(view: &webkit6::WebView, script: &str) -> Option<webkit6::javascriptcore::Value> {
    let (tx, rx) = async_channel::bounded(1);
    view.evaluate_javascript(script, Some(WORLD), None, None::<&gtk::gio::Cancellable>, move |r| {
        let _ = tx.try_send(r.ok());
    });
    glib::future_with_timeout(Duration::from_secs(5), rx.recv()).await.ok()?.ok()?
}

// 페이지와 떨어진 world 에서: Readability 는 한 번만 넣고, 이후엔 짧은 추출 스크립트만 다시 돌린다
async fn try_extract(view: &webkit6::WebView) -> Option<Article> {
    let loaded = eval(view, "typeof Readability !== 'undefined'").await.map(|v| v.is_boolean() && v.to_boolean()).unwrap_or(false);
    if !loaded {
        let src = READABILITY.with(|r| r.clone());
        if src.is_empty() {
            return None;
        }
        eval(view, &format!("{src}\n;true")).await;
    }
    let v = eval(view, SCRIPT).await?;
    if !v.is_string() {
        return None;
    }
    let art: Article = serde_json::from_str(&v.to_str()).ok()?;
    art.acceptable().then_some(art)
}

async fn run_fast(html: String, base: String) -> Option<Article> {
    let web = make_web(false, &FAST_BLOCK, "dropcap-fast").await?;
    web.view.load_html(&html, Some(&base));
    wait_for_load(&web.view, 6).await;
    try_extract(&web.view).await
}

async fn run_slow(url: String, max_secs: u64) -> Option<Article> {
    if !dropcap_core::url_safety::is_public_http(&url) {
        return None;
    }
    let web = make_web(true, &SLOW_BLOCK, "dropcap-full").await?;
    web.view.load_uri(&url);
    // 다 뜨기를 기다리지 않고, 0.6초 뒤부터 0.4초마다 본문이 생겼는지 본다(최대 15초, 접근을 거부한 곳은 6초)
    let deadline = Instant::now() + Duration::from_secs(max_secs);
    glib::timeout_future(Duration::from_millis(600)).await;
    let mut last = 0usize;
    while Instant::now() < deadline {
        if let Some(art) = try_extract(&web.view).await {
            let n = art.blocks.len();
            if n >= 4 && n == last {
                return Some(art); // 두 번 연속 같으면 다 그려진 것
            }
            last = n;
        }
        glib::timeout_future(Duration::from_millis(400)).await;
    }
    try_extract(&web.view).await
}

