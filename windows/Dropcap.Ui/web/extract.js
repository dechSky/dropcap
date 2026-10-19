// 본문 추출(R-03): Readability 결과를 블록(제목·문단·목록·인용·코드·그림·캡션)으로. 맥 ArticleExtractor.script 와 같은 코드(READER-CUT 2단계 포함).
// 앱이 Readability.js 와 함께 격리된 칸(스크립트·바깥 요청이 모두 막힌 사본 페이지)에 넣어 돌린다(S-10·S-11).
(() => {
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
      // 캐러셀 바깥 바로 앞 형제 제목도 본다 — 뿌리가 앞 형제 없이 감싸여 있으면 세 겹까지 올라가고, 글이 제목 하나뿐인 상자(머리말 상자)면 그 제목
      const headBefore = (r) => { let s = r; for (let i = 0; i < 3 && !s.previousElementSibling && s.parentElement; i++) s = s.parentElement; const p = s.previousElementSibling; if (!p) return null; if (/^H[1-6]$/.test(p.tagName)) return p; const h = p.querySelector('h1, h2, h3, h4, h5, h6'); return h && norm(h.textContent) === norm(p.textContent) ? h : null; };
      // 칸 글 양 상한: 본문(캐러셀 밖 글 중 우리 본문에 있는 것) 글자의 2배, 적어도 3000자 · 칸 50개
      const cap = Math.max(2 * marks.filter((m) => found.has(norm(m.textContent))).reduce((z, m) => z + cln(m), 0), 3000);
      let added = false;
      roots.forEach((r) => {
        if ([r.querySelector('h1, h2, h3, h4, h5, h6'), headBefore(r)].some((hd) => hd && RECO_HEAD.test(norm(hd.textContent)))) return;
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
          // 상한을 넘은 칸은 넣지 않되, Readability 가 남긴 같은 칸은 지우게 글·사진만 적어 둔다
          if (keys.length >= 50 || text > cap) { [s, ...s.querySelectorAll('p, li, h1, h2, h3, h4, h5, h6, blockquote, figcaption')].forEach((e) => { const u = norm(e.textContent); if (u) units.add(u); }); s.querySelectorAll('img').forEach((i) => { const x = i.getAttribute('src') || i.getAttribute('data-src') || ''; if (x) srcs.add(x); }); return; }
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
  // ldBody: 사이트가 ld+json articleBody 로 적은 본문 글자 수(맛보기 판정 — Paywall.MatchesSiteBody, 맥 ld-body-match)
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
})();
