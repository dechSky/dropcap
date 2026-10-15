// 출처 추가 점검 3단계(실제 사이트 표시): 헤드리스 Chromium(화면 없음)으로 기사 페이지를 열어 본문 영역 글자 수·유료벽·쿠키창을 잰다.
// 측정 함수는 srcaudit-intl1 의 site.mjs 와 같다(같은 기준으로 비교하려고). 출처별 선택자는 이 파일의 BODY_SELECTORS.
// 쓰기: PW_FROM=<playwright 가 깔린 폴더> node site.mjs <app 결과 폴더> <id,…|all>
//  → <결과 폴더>/site-<id>.json  (글자 수·꼴만. 본문은 저장하지 않음)
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

const { chromium } = createRequire(path.join(process.env.PW_FROM || process.cwd(), 'x.js'))('playwright');
export const CHROME_UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';
export const BODY_SELECTORS = {
  reuters: ['[data-testid="ArticleBody"]', 'article'],
  ft: ['#article-body', '.article__content-body', 'article'],
  economist: ['[data-test-id="Article"] section', 'main article', 'article'],
  'bloomberg-markets': ['.body-content', '[class*="body-content"]', 'article'],
  'bloomberg-tech': ['.body-content', '[class*="body-content"]', 'article'],
  axios: ['.DraftjsBlocks', '[data-cy="story-body"]', 'article'],
  atlantic: ['[class*="ArticleBody_root"]', 'article'],
  'nikkei-asia': ['[data-trackable="bodytext"]', '[class*="ArticleBody"]', 'article'],
  scmp: ['[data-qa="GenericArticle-Body"]', 'article'],
  'lemonde-en': ['.article__content', 'article'],
  france24: ['.t-content__body', 'article'],
  'pbs-newshour': ['.body-text', 'article'],
  propublica: ['.article-body', 'article'],
  nature: ['.c-article-body', '.article__body', 'article'],
  'science-news': ['.news-article__body', '.article__body', 'article'],
  sciam: ['[class*="article__content"]', '[class*="ArticleContent"]', 'article'],
  'ieee-spectrum': ['.widget__body', '.body-description', 'article'],
  restofworld: ['.post-content', 'article'],
  'guardian-tech': ['#maincontent', '[data-gu-name="body"]', 'article'],
  'kbs-news': ['#cont_newstext', '.detail-body', 'article'],
  'jtbc-news': ['#ijam_content', '.article_content', 'article'],
  ytn: ['#CmAdContent', '.paragraph', 'article'],
  joongang: ['#article_body', 'article'],
  hankook: ['.col-main .article-body', '.end-body', 'article'],
  munhwa: ['.article-body', '#article-body', 'article'],
  kmib: ['#articleBody', '.article_body', 'article'],
  segye: ['#article_txt', '.viewBox2 article', 'article'],
  seoul: ['.viewContent', '#articleContent', 'article'],
  news1: ['#articleBodyContent', '[class*="article-body"]', 'article'],
  newsis: ['.viewer article', '.viewer', 'article'],
  pressian: ['.article_body', 'article'],
  ohmynews: ['.at_contents', '#articleBody', 'article'],
  'hani-politics': ['.article-text', '[class*="article-text"]', 'article'],
  'hani-economy': ['.article-text', '[class*="article-text"]', 'article'],
  edaily: ['.news_body', 'article'],
  mt: ['#textBody', '.view_text', 'article'],
  'bok-stats': ['.bdView .dbdata', '.bd-view', '.dbdata'],
};

export const MEASURE = (selectors) => {
  const norm = (s) => (s || '').replace(/\s+/g, ' ').trim();
  const visible = (el) => { const r = el.getBoundingClientRect(); const cs = getComputedStyle(el); return cs.display !== 'none' && cs.visibility !== 'hidden' && (r.width > 0 || r.height > 0); };
  let region = null, used = null;
  for (const s of selectors) {
    const all = [...document.querySelectorAll(s)];
    if (!all.length) continue;
    // 같은 선택자가 여러 개면(BBC 블록 등) 글이 가장 많은 것
    all.sort((a, b) => norm(b.innerText).length - norm(a.innerText).length);
    if (norm(all[0].innerText).length > 80) { region = all[0]; used = s; break; }
  }
  if (!region) {
    let best = null, bl = 0;
    document.querySelectorAll('article, main, [itemprop="articleBody"], [class*="article-body" i], [class*="story-body" i]').forEach((el) => { const l = norm(el.innerText).length; if (l > bl && l < 60000) { best = el; bl = l; } });
    region = best || document.body; used = best ? 'auto' : 'body';
  }
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
    blocks.push({ tag, len: t.length, text: t, junk: stopped || card || isJunk(el), fig: !!el.closest('figure') });
  });
  const imgs = [];
  region.querySelectorAll('img').forEach((im) => {
    const fig = im.closest('figure');
    const cap = fig ? norm(fig.querySelector('figcaption')?.innerText) : '';
    const src = im.currentSrc || im.src || im.getAttribute('data-src') || '';
    const after = stopEl && (stopEl.compareDocumentPosition(im) & Node.DOCUMENT_POSITION_FOLLOWING);
    imgs.push({ src, w: im.naturalWidth, h: im.naturalHeight, dw: Math.round(im.getBoundingClientRect().width), cap: cap.length, junk: !!after || !!im.closest('a[href]:not([href^="#"])') || isJunk(im), alt: (im.alt || '').length });
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
    title: document.title, used, finalUrl: location.href,
    blocks, imgs, embeds, walls, wallDom, cookie, more, timePos,
    ld: ldo ? { type: String(ldo['@type']), body: typeof ldo.articleBody === 'string' ? ldo.articleBody.length : 0, access: ldo.isAccessibleForFree ?? null, section: ldo.articleSection ? String(ldo.articleSection).slice(0, 40) : null } : null,
    pageText: bodyText.length,
    captcha: /captcha|are you a robot|verify you are human|access denied|request blocked|just a moment/i.test(document.title + ' ' + bodyText.slice(0, 2000)),
  };
};

// 선택자가 빗나갔을 때(본문 200자 미만): 문단(p)이 가장 많이 모인 부모를 본문으로 본다
const DENSE = () => {
  const norm = (s) => (s || '').replace(/\s+/g, ' ').trim();
  const score = new Map();
  document.querySelectorAll('p, br').forEach((el) => {
    const host = el.tagName === 'BR' ? el.parentElement : el.parentElement;
    if (!host) return;
    const l = el.tagName === 'BR' ? 0 : norm(el.innerText).length;
    if (l < 15 && el.tagName !== 'BR') return;
    score.set(host, (score.get(host) || 0) + l + (el.tagName === 'BR' ? 1 : 0));
  });
  let best = null, bs = 0;
  for (const [el, s] of score) if (s > bs) { best = el; bs = s; }
  if (!best) return null;
  // <br> 로 문단을 나누는 국내 기사: p 가 없으면 상자 안 글 전체
  const ps = [...best.querySelectorAll(':scope > p, :scope > h2, :scope > h3, :scope > ul > li')];
  const chars = ps.length >= 2 ? ps.reduce((n, e) => n + norm(e.innerText).length, 0) : norm(best.innerText).length;
  const name = best.tagName.toLowerCase() + (best.id ? '#' + best.id : '') + (best.className ? '.' + String(best.className).trim().split(/\s+/)[0] : '');
  return { chars, used: 'dense:' + name.slice(0, 50), paras: ps.filter((e) => e.tagName === 'P').length };
};

async function measure(browser, url, sourceId) {
  const ctx = await browser.newContext({ userAgent: CHROME_UA, viewport: { width: 1280, height: 900 }, locale: sourceId.match(/^(reuters|ft|economist|bloomberg|axios|atlantic|nikkei|scmp|lemonde|france24|pbs|propublica|nature|science|sciam|ieee|restofworld|guardian)/) ? 'en-US' : 'ko-KR' });
  const page = await ctx.newPage();
  const t0 = Date.now();
  let status = null, err = null;
  try {
    const resp = await page.goto(url, { timeout: 30000, waitUntil: 'domcontentloaded' });
    status = resp?.status() ?? null;
    await page.waitForLoadState('load', { timeout: 12000 }).catch(() => {});
    for (let y = 0; y < 10; y++) { await page.mouse.wheel(0, 1400).catch(() => {}); await page.waitForTimeout(300); }
    await page.waitForTimeout(800);
  } catch (e) { err = e.message.slice(0, 120); }
  let data = null, dense = null;
  try { data = await page.evaluate(MEASURE, BODY_SELECTORS[sourceId] || []); } catch (e) { err = (err || '') + ' measure:' + e.message.slice(0, 80); }
  try { dense = await page.evaluate(DENSE); } catch {}
  await ctx.close();
  if (data) {
    const body = data.blocks.filter((b) => !b.junk);
    data.chars = body.filter((b) => b.tag !== 'figcaption').reduce((n, b) => n + b.len, 0);
    data.paras = body.filter((b) => b.tag === 'p').length;
    data.heads = body.filter((b) => /^h/.test(b.tag)).length;
    data.lists = body.filter((b) => b.tag === 'li').length;
    data.caps = body.filter((b) => b.tag === 'figcaption').length;
    data.photos = data.imgs.filter((i) => !i.junk && (i.dw >= 200)).length;
    delete data.blocks; delete data.imgs; // 본문·사진 주소는 남기지 않음
    if (dense && (data.chars < 200 || data.chars < 0.5 * dense.chars || data.used === 'body' || data.used === 'auto')) { data.selectorChars = data.chars; data.chars = dense.chars; data.paras = dense.paras; data.used = dense.used; }
  }
  return { url, status, err, ms: Date.now() - t0, ...(data || {}) };
}

const [dir, which] = process.argv.slice(2);
const ids = which === 'all' ? fs.readdirSync(dir).filter((f) => /^app-.*\.json$/.test(f)).map((f) => f.slice(4, -5)) : which.split(',');
const browser = await chromium.launch({ headless: true });
for (const id of ids) {
  const app = JSON.parse(fs.readFileSync(path.join(dir, `app-${id}.json`), 'utf8'));
  const rows = [];
  for (const a of app.articles) {
    rows.push(await measure(browser, a.link, id));
    console.log(id, rows.at(-1).status, rows.at(-1).chars, rows.at(-1).walls?.join('|') || '', rows.at(-1).captcha ? 'CAPTCHA' : '');
    await new Promise((r) => setTimeout(r, 1500));
  }
  fs.writeFileSync(path.join(dir, `site-${id}.json`), JSON.stringify(rows, null, 1));
}
await browser.close();
