// 실제 사이트 표시: 헤드리스 Chromium(화면 없음)으로 기사 페이지를 열어 본문 영역을 잰다.
export const CHROME_UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';

// 출처별 본문 영역(편집 본문만). 앞에서부터 처음 맞는 것. 없으면 일반 후보 중 글이 가장 많은 곳.
export const BODY_SELECTORS = {
  anthropic: ['[class*="Body-module"][class*="__body"]', 'article', 'main'],
  'ars-all': ['.post-content', 'article .article-content', 'article'],
  'bbc-health': ['main article', 'article'],
  'bbc-sport': ['main article', 'article'],
  'bbc-world': ['main article', 'article'],
  cnbc: ['.ArticleBody-articleBody', '[data-module="ArticleBody"]', '.ArticleBody-wrapper', 'article'],
  'google-ai': ['.article-container__content', '.uni-blog-article-container', 'article', 'main'],
  'guardian-env': ['#maincontent', '[data-gu-name="body"]', 'article'],
  'guardian-business': ['#maincontent', '[data-gu-name="body"]', 'article'],
  'mit-tr': ['[class*="gutenbergContent__content"]', '#content--body', 'article'],
  'nyt-politics': ['section[name="articleBody"]', 'article'],
  'nyt-business': ['section[name="articleBody"]', 'article'],
  'nyt-home': ['section[name="articleBody"]', 'article'],
  quanta: ['.post__content__section', '.post__content', 'article', 'main'],
  'verge-all': ['.duet--article--article-body-component', '[class*="article-body-component"]', 'article', 'main'],
  'aws-ml': ['section.blog-post-content', '.blog-post-content', 'article', 'main'],
  dw: ['.rich-text', 'article .content-area', 'article'],
  huggingface: ['.blog-content', 'div.prose', 'article', 'main'],
  marketwatch: ['#js-article__body', '.article__body', '[data-testid="article-body"]', 'article'],
  newscientist: ['.ArticleContent', '.article-content', '[class*="ArticleContent"]', 'article'],
  'npr-world': ['#storytext', '.storytext', 'article'],
  politico: ['.story-text', '.page-content', 'article'],
  stat: ['.entry-content.the-content', '.entry-content', 'article'],
  'techcrunch-all': ['.entry-content.wp-block-post-content', '.entry-content', 'article'],
  'wired-all': ['.body__inner-container', '[class*="ArticlePageChunks"]', 'article'],
};

// 페이지 안에서 돌릴 측정 함수(문자열로 넘김)
export const MEASURE = (selectors) => {
  const norm = (s) => (s || '').replace(/\s+/g, ' ').trim();
  const visible = (el) => { const r = el.getBoundingClientRect(); const cs = getComputedStyle(el); return cs.display !== 'none' && cs.visibility !== 'hidden' && (r.width > 0 || r.height > 0); };
  let region = null, used = null, parts = null;
  for (const s of selectors) {
    // 같은 선택자가 여러 덩어리면(MIT TR·Ars·Quanta·Verge·Wired 처럼 본문이 쪼개진 사이트) 바깥 것들을 모두 본문으로
    let all = [...document.querySelectorAll(s)].filter((e) => !e.parentElement?.closest(s));
    // 무한 스크롤로 붙은 다음 기사(TechCrunch 등)는 빼고 첫 기사 것만
    const art0 = all[0]?.closest('article');
    if (art0) all = all.filter((e) => e.closest('article') === art0);
    const h1s = [...document.querySelectorAll('h1')].filter((h) => h.getBoundingClientRect().height > 0);
    const top0 = all[0]?.getBoundingClientRect().top ?? 0;
    const nextH1 = h1s.find((h) => h.getBoundingClientRect().top > top0 + 400);
    if (nextH1) { const y2 = nextH1.getBoundingClientRect().top; all = all.filter((e) => e.getBoundingClientRect().top < y2); }
    if (!all.length || all.reduce((n, e) => n + norm(e.innerText).length, 0) <= 80) continue;
    used = s; parts = all;
    region = all[0];
    while (region && !all.every((e) => region.contains(e))) region = region.parentElement;
    break;
  }
  if (!region) {
    let best = null, bl = 0;
    document.querySelectorAll('article, main, [itemprop="articleBody"], [class*="article-body" i], [class*="story-body" i]').forEach((el) => { const l = norm(el.innerText).length; if (l > bl && l < 60000) { best = el; bl = l; } });
    region = best || document.body; used = best ? 'auto' : 'body'; parts = [region];
  }
  const inBody = (el) => parts.some((r) => r.contains(el));
  // 편집 본문이 아닌 상자(사이트 자체 표시에서도 본문 밖으로 치는 것)
  const junkSel = 'nav, aside, footer, form, button, [role="complementary"], [aria-hidden="true"], [class*="newsletter" i], [class*="related" i], [class*="recirc" i], [class*="promo" i], [class*="advert" i], [class*="ad-slot" i], [class*="share" i], [class*="social" i], [class*="author-bio" i], [class*="byline" i], [data-component="links-block"], [data-component="tag-list"], [data-testid*="promo" i], [class*="most-popular" i], [class*="subscribe" i], [class*="paywall" i], [class*="related" i]';
  const isJunk = (el) => !!el.closest(junkSel) && region.contains(el.closest(junkSel)) && el.closest(junkSel) !== region;
  const blocks = [];
  // 이 제목부터 뒤는 본문 밖(관련 기사·더 보기 목록)
  const stopRe = /^(explore more|more on this story|related( (stories|articles|topics|coverage|reading))?|top stories|most read|more from|read more|recommended|you might also like|more stories|further reading|latest news|popular|trending|editors'? picks|more like this|more in)\b/i;
  let stopped = false, stopEl = null;
  region.querySelectorAll('p, h2, h3, h4, li, blockquote, figcaption, pre, table').forEach((el) => {
    if (!visible(el)) return;
    // 바깥 블록 안에 든 것은 한 번만(li 안 p, blockquote 안 p 등)
    if (el.parentElement && el.parentElement.closest('p, li, blockquote, figcaption, pre, table') && region.contains(el.parentElement.closest('p, li, blockquote, figcaption, pre, table'))) return;
    const t = norm(el.innerText); if (!t) return;
    const tag = el.tagName.toLowerCase();
    if (/^h[2-4]$/.test(tag) && stopRe.test(t) && !stopped) { stopped = true; stopEl = el; }
    // 글 전체가 링크인 제목·문단은 다른 기사 카드
    const a = el.closest('a') || (el.children.length === 1 && el.firstElementChild.tagName === 'A' ? el.firstElementChild : null);
    const card = !!a && /^h|^p$/.test(tag) && norm(a.innerText).length >= t.length * 0.9 && a.getAttribute('href') && !a.getAttribute('href').startsWith('#');
    // 본문 중간의 'Related Story' 상자 뒤에 긴 문단이 다시 나오면 본문이 이어지는 것
    if (stopped && tag === 'p' && !card && t.length >= 200 && !isJunk(el)) { stopped = false; stopEl = null; for (const b of blocks) if (b.stopJunk) { b.junk = b.preJunk; } }
    const pre = card || !inBody(el) || isJunk(el);
    blocks.push({ tag, len: t.length, text: t, junk: stopped || pre, preJunk: pre, stopJunk: stopped, fig: !!el.closest('figure') });
  });
  const imgs = [];
  region.querySelectorAll('img').forEach((im) => {
    const fig = im.closest('figure');
    const cap = fig ? norm(fig.querySelector('figcaption')?.innerText) : '';
    const src = im.currentSrc || im.src || im.getAttribute('data-src') || '';
    const after = stopEl && (stopEl.compareDocumentPosition(im) & Node.DOCUMENT_POSITION_FOLLOWING);
    imgs.push({ src, w: im.naturalWidth, h: im.naturalHeight, dw: Math.round(im.getBoundingClientRect().width), cap: cap.length, junk: !!after || !inBody(im) || !!im.closest('a[href]:not([href^="#"])') || isJunk(im), alt: (im.alt || '').length });
  });
  const embeds = [...region.querySelectorAll('iframe, video, blockquote.twitter-tweet, blockquote.instagram-media, [class*="embed" i] iframe')].map((e) => {
    const s = e.src || e.getAttribute('data-src') || ''; let host = ''; try { host = new URL(s, location.href).host; } catch {}
    return e.tagName.toLowerCase() + (host ? ':' + host : (e.className ? ':' + String(e.className).slice(0, 30) : ''));
  });
  const bodyText = norm(document.body.innerText).toLowerCase();
  const wallWords = ['subscribe to continue', 'subscribe to read', 'subscribers only', 'to continue reading', 'already a subscriber', 'create a free account', 'sign in to continue', 'you have reached your limit', 'unlock this article', 'log in or create', 'this article is for subscribers', 'register for free to', 'continue reading with', 'subscribe now', 'start your free trial'];
  const walls = wallWords.filter((w) => bodyText.includes(w));
  const wallDom = [...document.querySelectorAll('[id*="paywall" i], [class*="paywall" i], [data-testid*="paywall" i], #gateway-content, [class*="regwall" i], [class*="Paywall"], [id*="piano" i], .tp-modal, [class*="meter" i]')].filter(visible).map((e) => (e.id ? '#' + e.id : '.' + String(e.className).split(' ')[0]).slice(0, 40)).slice(0, 4);
  const cookieSel = '#onetrust-banner-sdk, #onetrust-consent-sdk, .fc-consent-root, [id^="sp_message_container"], #didomi-host, .qc-cmp2-container, [class*="cookie-banner" i], [id*="cookie-banner" i], [class*="consent" i][role="dialog"], [aria-label*="cookie" i], [id*="truste" i], #bbccookies, [class*="CookieConsent" i], [id*="CybotCookiebot"]';
  const cookie = [...document.querySelectorAll(cookieSel)].filter(visible).map((e) => (e.id ? '#' + e.id : '.' + String(e.className).split(' ')[0]).slice(0, 40)).slice(0, 3);
  const more = [...region.querySelectorAll('a, button')].map((a) => norm(a.innerText)).filter((t) => /^(read more|show more|continue reading|load more|next page|see more|more)$/i.test(t) || /^page \d/i.test(t)).slice(0, 4);
  const ld = [...document.querySelectorAll('script[type="application/ld+json"]')].map((s) => { try { return JSON.parse(s.textContent); } catch { return null; } });
  const flat = (a) => Array.isArray(a) ? a.flatMap(flat) : (a && typeof a === 'object' ? [a, ...(Array.isArray(a['@graph']) ? a['@graph'].flatMap(flat) : [])] : []);
  const ldo = ld.flatMap(flat).find((o) => /Article|Posting/i.test(String(o['@type'])));
  const time = document.querySelector('time[datetime]');
  const regionTop = region.getBoundingClientRect().top + scrollY;
  const timePos = time ? (time.getBoundingClientRect().top + scrollY < regionTop ? 'before' : (region.contains(time) ? 'inside' : 'after')) : 'none';
  return {
    title: document.title, used: used + (parts.length > 1 ? ` ×${parts.length}` : ''), finalUrl: location.href,
    blocks, imgs, embeds, walls, wallDom, cookie, more, timePos,
    ld: ldo ? { type: String(ldo['@type']), body: typeof ldo.articleBody === 'string' ? ldo.articleBody.length : 0, access: ldo.isAccessibleForFree ?? null, section: ldo.articleSection ? String(ldo.articleSection).slice(0, 40) : null } : null,
    pageText: bodyText.length,
    captcha: /captcha|are you a robot|verify you are human|access denied|request blocked|just a moment/i.test(document.title + ' ' + bodyText.slice(0, 2000)),
  };
};

export async function siteMeasure(browser, url, sourceId, shotPath, ua = CHROME_UA) {
  const ctx = await browser.newContext({ userAgent: ua, viewport: { width: 1280, height: 900 }, locale: 'en-US' });
  const page = await ctx.newPage();
  const t0 = Date.now();
  let status = null, err = null, early = null;
  try {
    const resp = await page.goto(url, { timeout: 30000, waitUntil: 'domcontentloaded' });
    status = resp?.status() ?? null;
    await page.waitForTimeout(2500);
    // 처음 그려진 때(유료벽 스크립트가 본문을 자르기 전일 수 있음)
    early = await page.evaluate(MEASURE, BODY_SELECTORS[sourceId] || []).then((d) => ({ chars: d.blocks.filter((b) => !b.junk && b.tag !== 'figcaption').reduce((n, b) => n + b.len, 0), p: d.blocks.filter((b) => !b.junk && b.tag === 'p').length, blocks: d.blocks })).catch(() => null);
    await page.waitForLoadState('load', { timeout: 12000 }).catch(() => {});
    // 늦게 불러오는 사진을 위해 천천히 내려 본다
    for (let y = 0; y < 12; y++) { await page.mouse.wheel(0, 1400).catch(() => {}); await page.waitForTimeout(350); }
    await page.waitForTimeout(800);
  } catch (e) { err = e.message.slice(0, 120); }
  let data = null;
  try { data = await page.evaluate(MEASURE, BODY_SELECTORS[sourceId] || []); } catch (e) { err = (err || '') + ' measure:' + e.message.slice(0, 80); }
  if (shotPath) await page.screenshot({ path: shotPath, fullPage: false }).catch(() => {});
  await ctx.close();
  return { status, err, ms: Date.now() - t0, early, ...(data || {}) };
}
