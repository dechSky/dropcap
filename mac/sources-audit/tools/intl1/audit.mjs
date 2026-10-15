// 출처 점검 INTL1: 피드 → 앱 추출(appextract) → 실제 사이트(site) → 비교. 결과 JSON 은 저장소 밖(기사 본문이 들어 있음).
//   node audit.mjs [출처id ...]     (없으면 배정 목록 전부)
//   OUT=<자료 폴더> SHOTS=<스크린샷 폴더> 로 바꿀 수 있음
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { webkit, chromium } from 'playwright';
import { appFetch, appExtract, cleanup, looksBlocked, imageKey, isJunk, WEB_UA } from './appextract.mjs';
import { siteMeasure } from './site.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../../../..');
const OUT = process.env.OUT || path.resolve(repo, '../srcaudit-shots/intl1/data');
const SHOTS = process.env.SHOTS || path.resolve(repo, '../srcaudit-shots/intl1');
const ASSIGN = path.resolve(repo, '../assign/srcaudit-INTL1.txt');
fs.mkdirSync(OUT, { recursive: true });
const sources = JSON.parse(fs.readFileSync(path.join(repo, 'shared/sources.json'), 'utf8')).sources;
const assigned = fs.readFileSync(ASSIGN, 'utf8').trim().split('\n').map((l) => l.split('\t')[0]);
const ids = process.argv.slice(2).length ? process.argv.slice(2) : assigned;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const pause = () => sleep(1200 + Math.random() * 800);

// ---- 피드 읽기(헤드리스 페이지의 DOMParser) ----
const PARSE = (xml) => {
  const doc = new DOMParser().parseFromString(xml, 'text/xml');
  const kids = (el, name) => [...el.children].filter((c) => c.localName === name || c.nodeName === name);
  const val = (el, ...names) => { for (const n of names) { const c = kids(el, n)[0]; if (c) return c.textContent; } return null; };
  const tagNames = (s) => (s ? [...new Set((s.match(/<([a-z][a-z0-9]*)\b/gi) || []).map((x) => x.slice(1).toLowerCase()))] : []);
  const txt = (s) => { if (!s) return ''; const d = new DOMParser().parseFromString(s, 'text/html'); return (d.body.textContent || '').replace(/\s+/g, ' ').trim(); };
  const imgsIn = (s) => (s ? (s.match(/<img\b/gi) || []).length : 0);
  const root = doc.documentElement;
  const out = { kind: root.localName, items: [] };
  if (root.localName === 'urlset') {
    for (const u of kids(root, 'url')) out.items.push({ link: (val(u, 'loc') || '').trim(), date: val(u, 'lastmod'), title: null, sitemap: true, images: kids(u, 'image').length });
    return out;
  }
  const items = root.localName === 'feed' ? kids(root, 'entry') : [...doc.getElementsByTagName('item')];
  for (const it of items) {
    let link = val(it, 'link');
    if (root.localName === 'feed') { const l = kids(it, 'link').find((x) => !x.getAttribute('rel') || x.getAttribute('rel') === 'alternate'); link = l?.getAttribute('href') || link; }
    if (!link) link = it.getAttribute('rdf:about');
    const desc = val(it, 'description', 'summary');
    const content = val(it, 'encoded', 'content');
    const media = [...it.getElementsByTagName('*')].filter((e) => ['content', 'thumbnail', 'enclosure'].includes(e.localName) && (e.getAttribute('url') || e.getAttribute('href')))
      .map((e) => ({ el: e.localName, url: e.getAttribute('url') || e.getAttribute('href'), w: Number(e.getAttribute('width')) || null, type: e.getAttribute('type') || e.getAttribute('medium') }));
    const cats = kids(it, 'category').map((c) => c.textContent || c.getAttribute('term')).concat(kids(it, 'subject').map((c) => c.textContent)).filter(Boolean);
    out.items.push({
      title: (val(it, 'title') || '').trim(), link: (link || '').trim(),
      date: val(it, 'pubDate', 'published', 'updated', 'date'),
      descLen: txt(desc).length, descTags: tagNames(desc), descImgs: imgsIn(desc),
      contentLen: txt(content).length, contentTags: tagNames(content), contentImgs: imgsIn(content), contentText: txt(content).slice(0, 200000),
      media, cats: cats.length, catSample: cats.slice(0, 3).map((c) => c.slice(0, 30)),
      author: !!(val(it, 'creator', 'author')), guid: !!val(it, 'guid', 'id'),
    });
  }
  return out;
};

function pick(items, n = 3) {
  const sorted = items.filter((i) => i.link).map((i) => ({ ...i, t: Date.parse(i.date) || 0 })).sort((a, b) => b.t - a.t).slice(0, 15);
  const chosen = [];
  const add = (x, why) => { if (x && !chosen.some((c) => c.link === x.link)) chosen.push({ ...x, why }); };
  add(sorted[0], '최신');
  // 긴 글 후보: 피드 본문·요약이 가장 긴 것, 사진 많은 후보: 피드 그림 수, 짧은 속보 후보: live·breaking·video 꼴 주소 또는 요약이 가장 짧은 것
  const rest = sorted.slice(1);
  add([...rest].sort((a, b) => (b.contentLen || b.descLen || 0) - (a.contentLen || a.descLen || 0))[0], '피드 글 가장 김');
  add(rest.find((i) => /live|breaking|video|\/av\//i.test(i.link)) || [...rest].filter((i) => !chosen.some((c) => c.link === i.link)).sort((a, b) => (a.descLen || 0) - (b.descLen || 0))[0], '짧은 글·속보 후보');
  for (const x of rest) { if (chosen.length >= n) break; add(x, '다음 최신'); }
  return chosen.slice(0, n);
}

const normTxt = (s) => (s || '').toLowerCase().replace(/[‘’“”"'`]/g, '').replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
function compare(ours, site) {
  const ourText = normTxt(ours.filter((b) => b.text).map((b) => b.text).join(' '));
  const body = site.blocks.filter((b) => !b.junk && b.tag !== 'figcaption');
  const siteAll = normTxt(site.blocks.map((b) => b.text).join(' '));
  const siteChars = body.filter((b) => b.tag !== 'table').reduce((s, b) => s + b.len, 0);
  const ourChars = ours.filter((b) => b.text && b.type !== 'cap').reduce((s, b) => s + b.text.length, 0);
  const found = (t, hay) => { const n = normTxt(t); if (n.length < 12) return true; const k = n.slice(0, 60); return hay.includes(k) || hay.includes(n.slice(-50)); };
  const missing = body.filter((b) => b.len >= 30 && !found(b.text, ourText)).map((b) => ({ tag: b.tag, len: b.len, idx: body.indexOf(b), n: body.length, text: b.text.slice(0, 160) }));
  const extra = ours.filter((b) => b.text && b.text.length >= 15 && !found(b.text, siteAll)).map((b, i) => ({ type: b.type, len: b.text.length, idx: ours.indexOf(b), n: ours.length, text: b.text.slice(0, 160), kind: classify(b.text) }));
  const siteImgs = site.imgs.filter((i) => !i.junk && (i.w >= 200 || i.dw >= 200));
  const ourImgs = ours.filter((b) => b.type === 'img');
  const siteKeys = siteImgs.map((i) => imageKey(i.src));
  const ourKeys = ourImgs.map((b) => imageKey(b.src));
  const commonOrder = ourKeys.filter((k) => siteKeys.includes(k));
  const orderOk = commonOrder.every((k, i) => i === 0 || siteKeys.indexOf(k) >= siteKeys.indexOf(commonOrder[i - 1]));
  const ourCaps = ours.filter((b) => b.type === 'cap').length;
  const capOrphans = ours.filter((b, i) => b.type === 'cap' && ours[i - 1]?.type !== 'img').length;
  const count = (arr, f) => arr.filter(f).length;
  return {
    ourChars, siteChars, pct: siteChars ? Math.round((ourChars / siteChars) * 100) : null,
    missing, extra,
    imgs: { site: siteImgs.length, ours: ourImgs.length, matched: commonOrder.length, orderOk, siteCaps: count(siteImgs, (i) => i.cap > 0), ourCaps, capOrphans, smallOurs: 0 },
    shape: {
      siteH: count(body, (b) => /^h/.test(b.tag)), ourH: count(ours, (b) => b.type === 'h'),
      siteLi: count(body, (b) => b.tag === 'li'), ourLi: count(ours, (b) => b.type === 'li'),
      siteQuote: count(body, (b) => b.tag === 'blockquote'), ourQuote: count(ours, (b) => b.type === 'quote'),
      siteTable: count(site.blocks, (b) => b.tag === 'table'), sitePre: count(body, (b) => b.tag === 'pre'), ourPre: count(ours, (b) => b.type === 'pre'),
      siteP: count(body, (b) => b.tag === 'p'), ourP: count(ours, (b) => b.type === 'p'),
    },
  };
}
function classify(t) {
  const s = t.toLowerCase();
  if (/newsletter|sign up|inbox|subscribe/.test(s)) return '뉴스레터·구독 권유';
  if (/related|read more|more from|most read|recommended|you may also|further reading|top stories/.test(s)) return '관련 기사';
  if (/ is (a|an|the) .*(reporter|editor|correspondent|writer|journalist)|covers? |writes about|follow (him|her|them)/.test(s)) return '기자 소개';
  if (/comment/.test(s)) return '댓글';
  if (/advert|sponsored/.test(s)) return '광고';
  if (/share|facebook|twitter|whatsapp|copy link/.test(s)) return '공유 단추';
  if (/getty|reuters|ap photo|afp|image credit|photograph:|credit:|\bphoto\b/.test(s)) return '사진 출처';
  if (/cookie|privacy/.test(s)) return '쿠키·개인정보';
  return '기타';
}

async function auditSource(src, wk, cr) {
  const res = { id: src.id, name: src.name, type: src.type, defaultOn: !!src.defaultOn, paywall: src.paywall || null, url: src.url, articles: [] };
  let f = await appFetch(src.url, 10_485_760);
  res.feedStatus = f.status ?? f.error;
  if (!f.buf) { // 앱 UA 로 못 받으면 점검을 이어 가려고 다른 UA 로 한 번 더(앱은 여기서 실패 — 보고서에 적음)
    await pause();
    const g = await appFetch(src.url, 10_485_760, 'Dropcap/1.0');
    if (g.buf) { res.feedRetry = 'Dropcap/1.0 로는 ' + g.status; f = g; }
  }
  if (!f.buf) { res.feedError = f.error || f.status; return res; }
  const pg = await (await wk.newContext()).newPage();
  let feed;
  try { feed = await pg.evaluate(PARSE, f.buf.toString('utf8')); } catch (e) { res.feedError = 'parse:' + e.message.slice(0, 80); return res; }
  await pg.context().close();
  if (src.type === 'sitemap' && src.match) {
    const re = new RegExp(src.match);
    feed.items = feed.items.filter((i) => re.test(i.link));
  }
  res.feedKind = feed.kind; res.feedItems = feed.items.length;
  const chosen = pick(feed.items);
  for (const it of chosen) {
    await pause();
    const a = { link: it.link, why: it.why, feed: { ...it, contentText: undefined } };
    const t0 = Date.now();
    let ex;
    try { ex = await appExtract(wk, it.link); } catch (e) { ex = { trace: { path: 'error', err: e.message.slice(0, 100) }, art: null }; }
    a.appMs = Date.now() - t0;
    a.trace = ex.trace;
    const feedImg = it.media?.find((m) => /image|jpg|jpeg|png|webp/i.test((m.type || '') + m.url))?.url;
    const cover = feedImg && !isJunk(feedImg) ? feedImg : ex.trace?.og;
    if (ex.art) {
      const c = cleanup(ex.art.blocks, cover);
      a.ours = c.shown; a.hiddenCount = c.hiddenCount; a.oursRaw = ex.art.blocks.length; a.bylineFound = c.bylineFound;
      a.paywalled = looksBlocked(ex.art.blocks);
    }
    await pause();
    const shot = path.join(SHOTS, `${src.id}-${chosen.indexOf(it) + 1}.png`);
    try { a.site = await siteMeasure(cr, it.link, src.id, shot); a.shot = path.basename(shot); } catch (e) { a.site = { err: e.message.slice(0, 120), blocks: [], imgs: [] }; }
    if ([401, 403, 429].includes(a.site.status) || a.site.captcha || /captcha-delivery/.test((a.site.embeds || []).join())) {
      // 헤드리스 Chromium 이 봇 막기에 걸리면 WebKit(Safari UA)으로 한 번 더 — 사람 브라우저에 가까운 표시를 보려고
      await pause();
      const first = { status: a.site.status, embeds: a.site.embeds };
      try { a.site = await siteMeasure(wk, it.link, src.id, shot, WEB_UA); a.site.chromeBlocked = first; } catch (e) { a.site.retryErr = e.message.slice(0, 80); }
    }
    // 처음 그려진 본문이 나중 것보다 훨씬 길면(유료벽이 몇 초 뒤 잘라냄) 처음 것을 '사이트 전문'으로 비교하고 잘림을 따로 적는다
    if (a.site?.early && a.site.blocks) {
      const late = a.site.blocks.filter((b) => !b.junk && b.tag !== 'figcaption').reduce((n, b) => n + b.len, 0);
      a.site.lateChars = late; a.site.earlyChars = a.site.early.chars;
      if (a.site.early.chars > late * 1.3 && a.site.early.chars - late > 300) { a.site.truncatedAfterLoad = true; a.site.blocks = a.site.early.blocks; }
      delete a.site.early.blocks;
    }
    if (a.ours && a.site?.blocks?.length) a.cmp = compare(a.ours, a.site);
    // 피드가 전문을 주는지: 피드 본문 글자 / 사이트 글자
    if (a.site?.blocks?.length) {
      const sc = a.site.blocks.filter((b) => !b.junk && b.tag !== 'figcaption').reduce((s, b) => s + b.len, 0);
      a.feedFullPct = sc ? Math.round((Math.max(it.contentLen || 0, it.descLen || 0) / sc) * 100) : null;
    }
    res.articles.push(a);
    console.log(`[${src.id}] ${a.trace?.path} ${a.cmp ? a.cmp.ourChars + '/' + a.cmp.siteChars + ' ' + a.cmp.pct + '%' : (a.site?.err || 'no-cmp')} site=${a.site?.status} ${it.link}`);
  }
  return res;
}

const wk = await webkit.launch();
const cr = await chromium.launch();
const queue = sources.filter((s) => ids.includes(s.id));
const CONC = Number(process.env.CONC || 3);
await Promise.all(Array.from({ length: CONC }, async () => {
  while (queue.length) {
    const src = queue.shift();
    let r;
    try { r = await auditSource(src, wk, cr); } catch (e) { r = { id: src.id, name: src.name, fatal: e.message.slice(0, 200) }; }
    fs.writeFileSync(path.join(OUT, `${src.id}.json`), JSON.stringify(r, null, 1));
    console.log(`== ${src.id} 끝 (${r.articles?.length ?? 0}건)`);
  }
}));
await wk.close(); await cr.close();
