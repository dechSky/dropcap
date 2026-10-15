// KR1 출처 점검 3단계: 헤드리스 브라우저(화면·포커스를 쓰지 않음)로 기사 페이지를 열어 실제 본문 영역을 잰다.
// 쓰기: node site.mjs <feeds.json> <결과 폴더> <스크린샷 폴더> [출처 id,…]
// 필요: playwright(NODE_PATH 또는 PW_REQUIRE 로 위치), 헤드리스 셸(PW_EXEC). 요청 사이 1.5초.
import { createRequire } from 'module';
import fs from 'fs';
const require = createRequire(process.env.PW_REQUIRE || import.meta.url);
const { chromium } = require('playwright');
const [feedsPath, out, shots, onlyArg] = process.argv.slice(2);
const only = onlyArg ? new Set(onlyArg.split(',')) : null;
const feeds = JSON.parse(fs.readFileSync(feedsPath, 'utf8'));

// 출처 사이트별 본문 영역(앞에서부터 처음 맞는 것). 못 찾으면 아래 measure 의 일반 규칙.
const SEL = {
  'aitimes.com': ['#article-view-content-div'], 'thelec.kr': ['#article-view-content-div'],
  'donga.com': ['section.news_view', '.news_view', '.article_txt'],
  'hankyung.com': ['#articletxt', '.article-body'],
  'news.sbs.co.kr': ['.text_area', '.main_text', '[itemprop=articleBody]'],
  'yna.co.kr': ['article.story-news', '.story-news', '#articleWrap .article'],
  'chosun.com': ['section.article-body', '.article-body'],
  'etnews.com': ['#articleBody', '.article_body', '.article_txt'],
  'hani.co.kr': ['.article-text', '[class*="article-text"]', '[class*="ArticleDetailView_textArea"]', '[class*="articleContent"]'],
  'koreaherald.com': ['#articleText', '.news_text', '.article-text', '.view_con_t'],
  'khan.co.kr': ['#articleBody', '.art_body', '.article_txt'],
  'kormedi.com': ['.entry-content', '.article-content', 'article .content'],
  'mk.co.kr': ['.news_cnt_detail_wrap', '[itemprop=articleBody]'],
  'nocutnews.co.kr': ['#pnlContent', '.viewbox'],
  'sedaily.com': ['#article-body', '.article_view', '.article_con', '.article-view', '#v-article'],
};

async function measure(page, sels) {
  return await page.evaluate((sels) => {
    const vis = (el) => { const s = getComputedStyle(el); const r = el.getBoundingClientRect(); return s.display !== 'none' && s.visibility !== 'hidden' && (r.width > 0 || r.height > 0); };
    let body = null, how = '';
    for (const s of sels) { const e = document.querySelector(s); if (e && (e.innerText || '').trim().length > 50) { body = e; how = s; break; } }
    if (!body) { // 일반 규칙: 기사 본문 후보 가운데 문단 글이 가장 많은 곳
      let best = 0;
      document.querySelectorAll('[itemprop="articleBody"], article, [id*="article" i], [class*="article" i], [id*="content" i], [class*="content" i]').forEach((e) => {
        if (e.closest('nav, header, footer, aside') || !vis(e)) return;
        const n = [...e.querySelectorAll('p')].reduce((a, p) => a + (p.innerText || '').length, 0) + (e.innerText || '').length * 0.1;
        const t = (e.innerText || '').length; if (t > 40000) return;
        if (n > best) { best = n; body = e; how = 'auto:' + e.tagName.toLowerCase() + (e.id ? '#' + e.id : '') + (e.className && typeof e.className === 'string' ? '.' + e.className.trim().split(/\s+/).slice(0, 2).join('.') : ''); }
      });
    }
    const meta = (p) => document.querySelector(`meta[property="${p}"], meta[name="${p}"]`)?.getAttribute('content') || null;
    const pageText = (document.body?.innerText || '');
    const flags = {
      paywall: /(유료\s?(기사|회원|구독)|구독\s?(후|하시면|회원)|프리미엄\s?(기사|회원)|로그인\s?(후|하시면)\s?(이용|보실|읽)|회원\s?전용)/.test(pageText),
      consent: !!document.querySelector('[id*="consent" i], [class*="consent" i], [id*="cookie" i][class*="banner" i], .fc-consent-root, #onetrust-banner-sdk'),
      captcha: /captcha|보안\s?문자|자동입력\s?방지|Access Denied|차단되었습니다/i.test(pageText.slice(0, 3000)) && pageText.length < 3000,
    };
    if (!body) return { found: false, how: 'none', flags, title: document.title, pageLen: pageText.length };
    const imgs = [...body.querySelectorAll('img')].filter(vis).map((i) => ({ w: i.naturalWidth || i.width, h: i.naturalHeight || i.height, src: (i.currentSrc || i.src || '').slice(0, 300), alt: (i.alt || '').slice(0, 60) }));
    const big = imgs.filter((i) => i.w >= 200 || i.w === 0);
    const caps = [...body.querySelectorAll('figcaption, [class*="caption" i], [class*="photo_desc" i], [class*="img_desc" i], .desc')].filter(vis).map((c) => (c.innerText || '').trim()).filter(Boolean);
    const heads = [...body.querySelectorAll('h2, h3, h4, [class*="subtitle" i], [class*="sub_title" i], [class*="subhead" i]')].filter(vis).map((h) => (h.innerText || '').trim()).filter(Boolean);
    const lis = [...body.querySelectorAll('li')].filter(vis).map((l) => (l.innerText || '').trim()).filter(Boolean);
    const embeds = [...body.querySelectorAll('iframe, video, blockquote.twitter-tweet, blockquote.instagram-media')].map((e) => e.tagName.toLowerCase() + ':' + ((e.src || e.getAttribute('data-src') || e.className || '') + '').slice(0, 80));
    const more = [...document.querySelectorAll('button, a')].filter(vis).map((b) => (b.innerText || '').trim()).filter((t) => /^(기사\s?)?(더\s?보기|전체\s?보기|본문\s?더보기|이어\s?보기)$/.test(t)).slice(0, 3);
    const pages = !!document.querySelector('.pagination, [class*="paging" i]') && /\b2\b/.test((document.querySelector('.pagination, [class*="paging" i]')?.innerText || ''));
    const text = (body.innerText || '').replace(/ /g, ' ');
    const lines = text.split(/\n+/).map((s) => s.replace(/\s+/g, ' ').trim()).filter((s) => s.length > 0);
    return {
      found: true, how, flags, title: document.title, pageLen: pageText.length,
      chars: text.replace(/\s+/g, '').length, charsSp: text.replace(/\s+/g, ' ').trim().length,
      pTags: [...body.querySelectorAll('p')].filter((p) => vis(p) && (p.innerText || '').trim().length > 0).length,
      lines, imgs, bigImgs: big.length, caps, heads, lis: lis.length, quotes: body.querySelectorAll('blockquote').length,
      tables: body.querySelectorAll('table').length, embeds, more, pages,
      og: { image: meta('og:image'), section: meta('article:section'), author: meta('author') || meta('article:author') || meta('dable:author'), published: meta('article:published_time') },
    };
  }, sels);
}

const browser = await chromium.launch({ headless: true, executablePath: process.env.PW_EXEC || undefined });
const ctx = await browser.newContext({ viewport: { width: 1280, height: 1600 }, locale: 'ko-KR',
  userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36' });
for (const f of feeds) {
  if (only && !only.has(f.id)) continue;
  const rows = [];
  for (const [i, p] of (f.picked || []).entries()) {
    const page = await ctx.newPage();
    const row = { link: p.link };
    try {
      const resp = await page.goto(p.link, { waitUntil: 'domcontentloaded', timeout: 25000 });
      row.status = resp?.status(); row.finalUrl = page.url();
      await page.waitForTimeout(2500);
      await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight / 2)); // 늦게 불러오는 사진
      await page.waitForTimeout(800);
      const host = new URL(page.url()).hostname.replace(/^www\./, '').replace(/^m\./, '');
      const key = Object.keys(SEL).find((k) => host === k || host.endsWith('.' + k));
      Object.assign(row, await measure(page, key ? SEL[key] : []));
      await page.evaluate(() => window.scrollTo(0, 0));
      await page.screenshot({ path: `${shots}/${f.id}-${i + 1}.png` });
      row.shot = `${f.id}-${i + 1}.png`;
    } catch (e) { row.error = String(e).slice(0, 200); }
    console.log(f.id, i + 1, row.status, row.how, row.chars, row.error || '');
    rows.push(row);
    await page.close();
    await new Promise((r) => setTimeout(r, 1500));
  }
  fs.writeFileSync(`${out}/site-${f.id}.json`, JSON.stringify(rows, null, 1));
}
await browser.close();
