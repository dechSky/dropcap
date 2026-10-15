// INTL2 실제 사이트 표시 재기: 헤드리스 Chromium(화면·포커스 안 뺏음)으로 기사 페이지를 열어 본문 영역을 잰다.
// 쓰는 법: PW=<playwright 모듈 경로> CHROME=<헤드리스 실행 파일> node site.cjs <replay.json> <결과.json> [스크린샷 폴더]
// - 사진·영상·글꼴은 받지 않음(사이트 부담·속도), 페이지 사이 1.5초. captcha·403 이면 '차단'으로 적고 넘어감.
// - 본문 영역: nav/header/footer/aside 밖의 긴 문단(60자+) 글자의 80% 이상을 담는 가장 작은 요소.
const { chromium } = require(process.env.PW);
const fs = require('fs');
const [,, replayPath, outPath, shotDir] = process.argv;
const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function measure() {
  const norm = (s) => (s || '').replace(/\s+/g, ' ').trim();
  const out = { title: document.title, url: location.href };
  const bodyText = norm(document.body ? document.body.innerText : '');
  out.pageChars = bodyText.length;
  const low = (document.documentElement.innerHTML || '').toLowerCase();
  out.captcha = /captcha-delivery|px-captcha|cf-chl|g-recaptcha|hcaptcha|are you a robot|verify you are human/.test(low) && bodyText.length < 3000;
  out.cookie = !!document.querySelector('#onetrust-banner-sdk, #onetrust-consent-sdk, .fc-consent-root, [id^="sp_message_container"], #didomi-host, #qc-cmp2-container, [class*="cookie-banner" i], [id*="cookie-banner" i], .bbccookies-banner, #truste-consent-track, [aria-label*="cookie" i][role="dialog"]');
  const paySel = '[class*="paywall" i], [id*="paywall" i], #gateway-content, [data-testid*="paywall" i], [class*="regwall" i], [class*="meteredContent" i], .snippet-promotion, [class*="subscribe-wall" i], [class*="article-gate" i]';
  out.paywallEl = !!document.querySelector(paySel);
  out.paywallText = /(subscribe to (continue|read)|to continue reading|create a free account|already a subscriber|log in to (continue|read)|this article is for subscribers|subscriber-only|sign in to read)/i.test(bodyText);
  const bad = (el) => el.closest('nav, header:not(article header), footer, aside, form, [role="navigation"], [role="complementary"]');
  let ps = [...document.querySelectorAll('p')].filter((p) => !bad(p) && norm(p.innerText).length >= 60);
  // 끝없이 이어 붙이는 사이트(ESPN·TechCrunch): 첫 긴 문단이 든 <article> 안으로 좁힌다
  const firstArt = ps.length ? ps[0].closest('article') : null;
  if (firstArt && ps.filter((p) => firstArt.contains(p)).length >= 2) ps = ps.filter((p) => firstArt.contains(p));
  const scope = firstArt || document;
  const total = ps.reduce((a, p) => a + norm(p.innerText).length, 0);
  let region = null;
  // 1) 알려진 본문 선택자(여러 조각이면 공통 조상)
  const known = [...scope.querySelectorAll('[itemprop="articleBody"], .article-body, .body__inner-container, .duet--article--article-body-component, #storytext, .entry-content, .wp-block-post-content, .article__content, .wysiwyg, .story-body, .article-body__content, .ssrcss-pv1rh6-ArticleWrapper, [data-component="text-block"], .rich-text, #text, .article-content, .post-content, .c-entry-content')].filter((e) => !bad(e));
  if (known.length) {
    let lca = known[0];
    for (const e of known.slice(1)) { while (lca && !lca.contains(e)) lca = lca.parentElement; }
    const inK = ps.filter((p) => lca && lca.contains(p)).reduce((a, p) => a + norm(p.innerText).length, 0);
    if (lca && inK >= total * 0.5 && lca !== document.body) region = lca;
  }
  if (!region && total > 0) {
    // 2) 긴 문단마다 조상을 올라가며 담는 글자 수를 더하고, 80% 를 넘는 가장 깊은 요소를 고른다
    const acc = new Map();
    for (const p of ps) { const n = norm(p.innerText).length; for (let e = p.parentElement; e; e = e.parentElement) acc.set(e, (acc.get(e) || 0) + n); }
    let best = null, depthBest = -1;
    for (const [e, n] of acc) { if (n >= total * 0.8) { let d = 0; for (let x = e; x; x = x.parentElement) d++; if (d > depthBest) { depthBest = d; best = e; } } }
    region = best;
  }
  out.regionBy = region ? (known.length && known.some((k) => region.contains(k)) ? 'selector' : 'density') : 'none';
  if (!region) region = document.querySelector('article, main, [itemprop="articleBody"]');
  out.regionFound = !!region;
  out.longParaChars = total;
  if (!region) return out;
  out.regionTag = region.tagName.toLowerCase() + (region.id ? '#' + region.id : '') + (region.className && typeof region.className === 'string' ? '.' + region.className.trim().split(/\s+/).slice(0, 2).join('.') : '');
  const junk = (el) => el.closest('aside, nav, form, figure figcaption, [class*="related" i], [class*="newsletter" i], [class*="promo" i], [class*="recirc" i], [class*="advert" i], [class*="ad-slot" i], [class*="social" i], [class*="share" i], [class*="byline" i], [class*="author-bio" i], [class*="read-more" i], [class*="most-popular" i], [data-testid*="related" i]');
  const visible = (el) => { const r = el.getBoundingClientRect(); const st = getComputedStyle(el); return st.display !== 'none' && st.visibility !== 'hidden' && (r.height > 0 || r.width > 0); };
  const blocks = [];
  region.querySelectorAll('p, h2, h3, h4, li, blockquote, figcaption, pre, td').forEach((el) => {
    const tag = el.tagName.toLowerCase();
    if (tag === 'p' && el.closest('li, blockquote, figcaption')) return;
    if (tag === 'li' && el.closest('nav')) return;
    const t = norm(el.innerText); if (!t || !visible(el)) return;
    blocks.push({ tag, text: t, junk: !!junk(el) && tag !== 'figcaption' });
  });
  out.blocks = blocks;
  const prose = blocks.filter((b) => !b.junk && ['p', 'h2', 'h3', 'h4', 'li', 'blockquote', 'pre'].includes(b.tag));
  out.paras = prose.filter((b) => b.tag === 'p').length;
  out.chars = prose.reduce((a, b) => a + b.text.length, 0);
  out.heads = prose.filter((b) => /^h/.test(b.tag)).length;
  out.lis = prose.filter((b) => b.tag === 'li').length;
  out.quotes = region.querySelectorAll('blockquote:not(.twitter-tweet):not(.instagram-media)').length;
  out.tables = region.querySelectorAll('table').length;
  out.caps = blocks.filter((b) => b.tag === 'figcaption').length;
  const imgs = [...region.querySelectorAll('img, picture source, [role="img"]')].filter((i) => i.tagName === 'IMG');
  out.imgs = imgs.filter((i) => { const w = parseInt(i.getAttribute('width') || '0', 10) || i.getBoundingClientRect().width; return (w === 0 || w >= 150) && !i.closest('[class*="byline" i], [class*="author" i], [class*="avatar" i], aside, nav'); }).length;
  out.smallImgs = imgs.length - out.imgs;
  out.figures = region.querySelectorAll('figure').length;
  out.video = region.querySelectorAll('video, [class*="video-player" i], [data-component="video-block"], iframe[src*="youtube"], iframe[src*="vimeo"], [class*="jwplayer" i], [data-testid*="video" i]').length;
  out.social = region.querySelectorAll('.twitter-tweet, iframe[src*="twitter"], iframe[src*="x.com"], .instagram-media, iframe[src*="instagram"], iframe[src*="tiktok"], [class*="embed" i]').length;
  out.iframes = region.querySelectorAll('iframe').length;
  out.moreBtn = [...document.querySelectorAll('button, a')].filter((b) => /^(read more|show more|continue reading|load more|see more|더 보기)$/i.test(norm(b.innerText))).length;
  out.pagination = !!document.querySelector('[class*="pagination" i] a[href*="page"], a[rel="next"]');
  out.regionHasPaywall = !!region.querySelector(paySel);
  out.jsonldBodyChars = (() => { let n = 0; document.querySelectorAll('script[type="application/ld+json"]').forEach((s) => { try { const j = JSON.parse(s.textContent); const walk = (o) => { if (!o || typeof o !== 'object') return; if (Array.isArray(o)) return o.forEach(walk); if (typeof o.articleBody === 'string') n = Math.max(n, o.articleBody.length); Object.values(o).forEach(walk); }; walk(j); } catch {} }); return n; })();
  out.isAccessibleForFree = /"isAccessibleForFree"\s*:\s*"?false/i.test(low) ? false : (/"isAccessibleForFree"\s*:\s*"?true/i.test(low) ? true : null);
  return out;
}

(async () => {
  const replay = JSON.parse(fs.readFileSync(replayPath, 'utf8'));
  const prev = fs.existsSync(outPath) ? JSON.parse(fs.readFileSync(outPath, 'utf8')) : {};
  const browser = await chromium.launch({ headless: true, executablePath: process.env.CHROME, args: process.env.CHROME_ARGS ? process.env.CHROME_ARGS.split(' ') : [] });
  const ctx = await browser.newContext({ userAgent: UA, viewport: { width: 1280, height: 900 }, locale: 'en-US' });
  await ctx.route('**/*', (r) => (['image', 'media', 'font'].includes(r.request().resourceType()) ? r.abort() : r.continue()));
  const res = prev;
  for (const [i, { target: t }] of replay.entries()) {
    if (res[t.link] && !process.env.REDO) continue;
    const page = await ctx.newPage();
    const rec = { sourceId: t.sourceId };
    const t0 = Date.now();
    try {
      const resp = await page.goto(t.link, { waitUntil: 'domcontentloaded', timeout: 30000 });
      rec.status = resp ? resp.status() : null;
      await page.waitForLoadState('load', { timeout: 10000 }).catch(() => {});
      for (let y = 0; y < 3; y++) { await page.mouse.wheel(0, 1200); await sleep(400); }
      await sleep(1000);
      Object.assign(rec, await page.evaluate(measure));
      if (shotDir) await page.screenshot({ path: `${shotDir}/${t.sourceId}-${(i % 3) + 1}.png` }).catch(() => {});
    } catch (e) { rec.error = String(e).slice(0, 200); }
    rec.seconds = (Date.now() - t0) / 1000;
    res[t.link] = rec;
    console.log(i + 1, t.sourceId, rec.status, rec.chars ?? '-', rec.captcha ? 'CAPTCHA' : '', rec.error ? 'ERR' : '');
    fs.writeFileSync(outPath, JSON.stringify(res, null, 1));
    await page.close();
    await sleep(1500);
  }
  await browser.close();
})();
