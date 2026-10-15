// 실제 사이트 표시 재기: 헤드리스 Chromium 으로 기사 페이지를 열어 본문 영역을 잰다(화면·포커스 안 씀).
//   NODE_PATH=<playwright 가 있는 node_modules> node sitemeasure.js <targets.json> <출력.json> <스크린샷 폴더>
// - targets.json 은 ReadSweep 의 Replay 꼴([{target:{sourceId,link,…}}]) — 앱이 연 것과 같은 기사.
// - 요청 사이 1.5초. 같은 출처가 이어지지 않게 targets 는 출처를 돌아가며 놓인 순서 그대로 연다.
// - 출력에는 비교용 본문 줄(text)이 들어간다 → 저장소 밖(scratchpad)에만 둔다. 저장소에는 숫자만 옮긴다.
const { chromium } = require('playwright');
const fs = require('fs');

// 출처별 본문 영역(사이트가 기사 글을 담는 상자). 없으면 문단 밀도로 고른다.
const BODY = {
  'bloter.net': '#article-view-content-div',
  'techm.kr': '#article-view-content-div',
  'donga.com': '.news_view',
  'hada.io': '#topic_contents',
  'khan.co.kr': '#articleBody, .art_body',
  'yna.co.kr': 'article.story-news, .story-news',
  'chosun.com': 'section.article-body',
  'etnews.com': '#articleBody, .article_body',
  'hani.co.kr': '[class*="article-text"], .article-text',
  'hankyung.com': '#articletxt',
  'mk.co.kr': '.news_cnt_detail_wrap',
  'nocutnews.co.kr': '#pnlContent',
  'sbs.co.kr': '[itemprop="articleBody"], .text_area',
  'sedaily.com': '.article_view, .article',
  'zdnet.co.kr': '#articleBody, .view_cont',
};

function selFor(url) {
  const h = new URL(url).hostname;
  for (const k of Object.keys(BODY)) if (h === k || h.endsWith('.' + k)) return BODY[k];
  return null;
}

async function measure(page, url) {
  const sel = selFor(url);
  return page.evaluate((sel) => {
    const vis = (el) => { const s = getComputedStyle(el); return s.display !== 'none' && s.visibility !== 'hidden' && el.getClientRects().length > 0; };
    let box = null, how = 'none';
    if (sel) { for (const s of sel.split(',')) { const e = document.querySelector(s.trim()); if (e && e.innerText.trim().length > 50) { box = e; how = 'selector'; break; } } }
    if (!box) { // 글 많은 <p>·<br> 를 가장 많이 직접 품은 상자
      let best = 0;
      for (const e of document.querySelectorAll('article, section, div, main')) {
        if (!vis(e)) continue;
        let n = 0;
        for (const c of e.children) if (c.tagName === 'P') n += c.innerText.length;
        for (const t of e.childNodes) if (t.nodeType === 3) n += t.textContent.trim().length;
        if (n > best) { best = n; box = e; }
      }
      how = box ? 'density' : 'none';
    }
    const body = document.body.innerText || '';
    const pageInfo = {
      title: document.title.length,
      cookie: /쿠키|cookie/i.test(body.slice(0, 3000) + body.slice(-3000)) && !!document.querySelector('[id*="cookie" i],[class*="cookie" i],[id*="consent" i],[class*="consent" i]'),
      paywall: /구독자 전용|유료 회원|로그인 후 (이용|보기|열람)|프리미엄 기사|구독하고 계속|이 기사는 .{0,10}(회원|구독)/.test(body),
      loginWall: !!document.querySelector('[class*="paywall" i],[id*="paywall" i],[class*="premium-lock" i]'),
      captcha: /captcha|보안 문자|자동 입력 방지/i.test(body.slice(0, 2000)) || !!document.querySelector('iframe[src*="captcha"]'),
    };
    if (!box) return { how, page: pageInfo };
    const imgs = [...box.querySelectorAll('img')].filter(vis).map((i) => ({ w: i.naturalWidth, h: i.naturalHeight, dw: Math.round(i.getBoundingClientRect().width), alt: (i.alt || '').length }));
    const caps = [...box.querySelectorAll('figcaption, .caption, [class*="caption"], .img_desc, .photo_txt')].filter(vis).map((c) => c.innerText.trim()).filter(Boolean);
    const text = box.innerText.split('\n').map((s) => s.trim()).filter(Boolean);
    const q = (s) => [...box.querySelectorAll(s)].filter(vis).length;
    const more = [...box.querySelectorAll('a,button')].filter((a) => vis(a) && /더\s?보기|기사 전체|다음 페이지|계속 읽/.test(a.innerText)).length;
    return {
      how, page: pageInfo,
      paras: q('p') || text.length, lines: text.length,
      chars: text.join('').replace(/\s/g, '').length,
      captionChars: caps.join('').replace(/\s/g, '').length,
      imgs, caps: caps.length, capsText: caps,
      heads: q('h2, h3, h4, strong.sub_tit, .sub_title, b.sub'),
      quotes: q('blockquote'), lists: q('ul li, ol li'), tables: q('table'),
      embeds: [...box.querySelectorAll('iframe, video, blockquote.twitter-tweet, blockquote.instagram-media')].map((e) => (e.src || e.className || e.tagName).toString().replace(/^https?:\/\//, '').split(/[/?]/)[0]),
      more,
      text, // 비교용(저장소 밖에만)
    };
  }, sel);
}

(async () => {
  const [,, inFile, outFile, shotDir] = process.argv;
  const targets = JSON.parse(fs.readFileSync(inFile, 'utf8')).map((x) => x.target);
  const out = fs.existsSync(outFile) ? JSON.parse(fs.readFileSync(outFile, 'utf8')) : {};
  fs.mkdirSync(shotDir, { recursive: true });
  const browser = await chromium.launch({ headless: true });
  const ctx = await browser.newContext({ locale: 'ko-KR', viewport: { width: 1280, height: 900 },
    userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36' });
  let i = 0;
  for (const t of targets) {
    i++;
    if (out[t.link] && !out[t.link].error) continue;
    const page = await ctx.newPage();
    const r = { sourceId: t.sourceId };
    try {
      const resp = await page.goto(t.link, { waitUntil: 'domcontentloaded', timeout: 30000 });
      r.http = resp ? resp.status() : null;
      r.finalUrl = page.url();
      await page.waitForLoadState('load', { timeout: 8000 }).catch(() => {});
      await page.waitForTimeout(1500);
      Object.assign(r, await measure(page, t.link));
      const shot = `${t.sourceId}-${i}.png`;
      await page.screenshot({ path: `${shotDir}/${shot}`, fullPage: false }).catch(() => {});
      r.shot = shot;
    } catch (e) {
      r.error = String(e.message || e).split('\n')[0].slice(0, 200);
    }
    await page.close();
    out[t.link] = r;
    fs.writeFileSync(outFile, JSON.stringify(out, null, 1));
    console.log(i, targets.length, t.sourceId, r.http, r.how, r.chars, r.error || '');
    await new Promise((s) => setTimeout(s, 1500));
  }
  await browser.close();
})();
