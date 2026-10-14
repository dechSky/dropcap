// 본문 추출(R-03): Readability 결과를 블록(제목·문단·목록·인용·코드·그림·캡션)으로. 맥 ArticleExtractor.script 와 같은 코드.
// 앱이 Readability.js 와 함께 격리된 칸(스크립트·바깥 요청이 모두 막힌 사본 페이지)에 넣어 돌린다(S-10·S-11).
(() => {
  const doc = document.cloneNode(true);
  doc.querySelectorAll('.sr-only, .visually-hidden, .screen-reader-text, [class*="sr-only"], [class*="visually-hidden"]').forEach((n) => n.remove());
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
      best.querySelectorAll('script, style, nav, form, button, .related-topics, [class*="related" i], [class*="share" i]').forEach((n) => n.remove());
      art = { title: document.title, content: '<div>' + best.innerHTML + '</div>' };
    }
  }
  if (!art || !art.content) return null;
  const box = new DOMParser().parseFromString(art.content, 'text/html').body;
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
  const clean = (s) => (s || '').replace(/\((opens in a new (window|tab)|새 창에서 열기)\)/gi, '').replace(/\s+/g, ' ').trim();
  const walk = (el) => {
    for (const n of el.children) {
      const tag = n.tagName.toLowerCase();
      const t = clean(n.textContent);
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
        const cap = n.querySelector('figcaption'); const c = cap && clean(cap.textContent);
        if (c) blocks.push({ type: 'cap', text: c });
      }
      else walk(n);
    }
  };
  walk(box);
  // 문단 태그 없이 맨 글자로 든 본문(GeekNews 등): 줄 단위로 문단을 만든다
  if (!blocks.some((b) => b.type === 'p' || b.type === 'li')) {
    (box.innerText || box.textContent || '').split(/\n+/).map(clean).filter((t) => t.length > 1).forEach((t) => blocks.push({ type: 'p', text: t }));
  }
  return JSON.stringify({ title: art.title, byline: art.byline, siteName: art.siteName, blocks });
})();
