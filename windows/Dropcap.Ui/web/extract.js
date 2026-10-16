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
      const box = document.createElement('div');
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
  const box = prune(parse(content));
  // 유료 표시: ld+json isAccessibleForFree=false 또는 한경 articlePayment="Y"
  let paid = null;
  document.querySelectorAll('script[type="application/ld+json"]').forEach((s) => {
    const m = (s.textContent || '').match(/"isAccessibleForFree"\s*:\s*"?(true|false)"?/i);
    if (m && paid === null) paid = m[1].toLowerCase() === 'false';
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
  return JSON.stringify({ title: art.title, byline: art.byline, siteName: art.siteName, blocks, paid, partial: partial || null });
})();
