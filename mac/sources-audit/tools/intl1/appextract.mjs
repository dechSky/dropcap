// 앱(mac/Sources/Dropcap/Reader/ArticleExtractor.swift)의 본문 추리기를 헤드리스 WebKit 으로 그대로 따라 한다.
// - 추출 스크립트와 Readability.js 는 앱 소스에서 그때그때 읽는다(앱이 바뀌면 같이 바뀜).
// - 빠른 길: HTML 만 받아 스크립트 끄고 띄움 → Readability → 못 찾으면 실린 본문 자료(EmbeddedArticle) → 글이 많으면 느린 길 건너뜀
// - 느린 길: 스크립트 켜고 그림·영상·글꼴 막고 띄워 0.6초 뒤부터 0.4초마다(두 번 연속 같은 블록 수·4개 이상이면 끝), 최대 15초(거절이면 6초)
// - 다듬기: BodyCleanup(기자 줄·짝 잃은 설명) · ImageKey.isJunk · 표지와 같은 첫 사진(+뒤 설명) 빼기 · Paywall.looksBlocked
// 다른 점(보고서에 적음): 받기는 URLSession 대신 node fetch(TLS 지문이 달라 봇 막기 판정이 다를 수 있음), 접속 IP 검사 없음.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const mac = path.resolve(here, '../../..');
const swift = fs.readFileSync(path.join(mac, 'Sources/Dropcap/Reader/ArticleExtractor.swift'), 'utf8');
const m = swift.match(/private static let script = """\n([\s\S]*?)\n\s*"""/);
if (!m) throw new Error('앱 추출 스크립트를 찾지 못함');
// Swift 여러 줄 문자열의 \\ → \ (스크립트 안에는 다른 이스케이프가 없음)
export const EXTRACT_JS = m[1].replace(/\\\\/g, '\\');
export const READABILITY = fs.readFileSync(path.join(mac, 'Resources/Readability.js'), 'utf8');
export const APP_UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Dropcap/1.0';
export const WEB_UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15';
const ACCEPT = 'application/rss+xml, application/atom+xml, application/xml, text/xml, text/html;q=0.8';
const PAGE_LIMIT = 2_097_152;

export async function appFetch(url, limit = PAGE_LIMIT, ua = APP_UA) {
  const t0 = Date.now();
  try {
    const r = await fetch(url, { headers: { 'User-Agent': ua, Accept: ACCEPT }, redirect: 'follow', signal: AbortSignal.timeout(20000) });
    if (!r.ok) { try { await r.body?.cancel(); } catch {} return { status: r.status, finalUrl: r.url, ms: Date.now() - t0 }; }
    const len = Number(r.headers.get('content-length') || 0);
    if (len > limit) { try { await r.body?.cancel(); } catch {} return { status: r.status, error: 'tooLarge', finalUrl: r.url, ms: Date.now() - t0 }; }
    const buf = Buffer.from(await r.arrayBuffer());
    if (buf.length > limit) return { status: r.status, error: 'tooLarge', finalUrl: r.url, ms: Date.now() - t0 };
    const ct = r.headers.get('content-type') || '';
    return { status: r.status, finalUrl: r.url, buf, contentType: ct, ms: Date.now() - t0 };
  } catch (e) {
    return { error: String(e.cause?.code || e.name || e.message), ms: Date.now() - t0 };
  }
}

// ArticleExtractor.visibleTextLength 와 같은 뜻(스크립트·스타일·noscript·svg 뺀 보이는 글자, 공백 묶음 = 1)
export function visibleTextLength(buf) {
  let h = buf.subarray(0, 800_000).toString('utf8');
  h = h.replace(/<(script|style|noscript|svg)\b[\s\S]*?<\/\1\s*>/gi, ' ');
  h = h.replace(/<[^>]*>/g, ' ');
  let n = 0, space = true;
  for (const c of h) { if (/\s/.test(c)) { if (!space) { n++; space = true; } } else { n++; space = false; } }
  return n;
}

function sniffCharset(buf, contentType) {
  const fromHeader = /charset=["']?([\w-]+)/i.exec(contentType || '');
  if (fromHeader) return fromHeader[1];
  const head = buf.subarray(0, 4096).toString('utf8').toLowerCase();
  const mm = /charset=["']?([a-z0-9_-]+)/.exec(head);
  return mm ? mm[1] : 'utf-8';
}

async function tryExtract(page) {
  const loaded = await page.evaluate(() => typeof Readability !== 'undefined').catch(() => false);
  if (!loaded) await page.evaluate(READABILITY + '\n;true').catch(() => {});
  const json = await page.evaluate(EXTRACT_JS).catch(() => null);
  if (typeof json !== 'string') return { art: null };
  const art = JSON.parse(json);
  const textLen = art.blocks.filter((b) => b.text != null).map((b) => b.text).join('').length;
  if (!art.blocks.some((b) => b.text != null) || textLen < 100) return { art: null, shortText: textLen };
  return { art };
}

// ---- EmbeddedArticle 포트 ----
function plain(s) {
  let t = (s || '').replace(/<br\s*\/?>/gi, ' ').replace(/<[^>]{0,500}>/g, '');
  for (const [k, v] of [['&nbsp;', ' '], ['&lt;', '<'], ['&gt;', '>'], ['&quot;', '"'], ['&#39;', "'"], ['&apos;', "'"], ['&middot;', '·'], ['&amp;', '&']]) t = t.split(k).join(v);
  t = t.replace(/&#(x?)([0-9a-fA-F]{1,6});/g, (w, x, n) => { try { return String.fromCodePoint(parseInt(n, x ? 16 : 10)); } catch { return w; } });
  return t.replace(/\s+/g, ' ').trim();
}
const tlen = (blocks) => blocks.filter((b) => b.text != null).map((b) => b.text).join('').length;
function balancedObject(s) {
  const start = s.search(/\S/); if (start < 0 || s[start] !== '{') return null;
  let depth = 0, inStr = false, esc = false;
  for (let i = start; i < s.length; i++) {
    const c = s[i];
    if (inStr) { if (esc) esc = false; else if (c === '\\') esc = true; else if (c === '"') inStr = false; }
    else if (c === '"') inStr = true; else if (c === '{') depth++; else if (c === '}') { depth--; if (depth === 0) return s.slice(start, i + 1); }
  }
  return null;
}
function flatten(a) { if (Array.isArray(a)) return a.flatMap(flatten); if (!a || typeof a !== 'object') return []; return [a, ...(Array.isArray(a['@graph']) ? a['@graph'].flatMap(flatten) : [])]; }
export function embedded(html) {
  html = html.slice(0, 3_000_000);
  const fi = html.indexOf('Fusion.globalContent=');
  if (fi >= 0) {
    try {
      const obj = JSON.parse(balancedObject(html.slice(fi + 21)));
      const blocks = [];
      for (const e of obj.content_elements || []) {
        if (e.type === 'text') { const t = plain(e.content); if (t) blocks.push({ type: /^<(b|strong)>[\s\S]*<\/(b|strong)>$/.test((e.content || '').trim()) ? 'h' : 'p', text: t }); }
        else if (e.type === 'header') { const t = plain(e.content); if (t) blocks.push({ type: 'h', text: t }); }
        else if (e.type === 'list') for (const it of e.items || []) { const t = plain(it.content); if (t) blocks.push({ type: 'li', text: t }); }
        else if (e.type === 'image' && /^https?:\/\//.test(e.url || '')) { blocks.push({ type: 'img', src: e.url }); const c = plain(e.caption); if (c) blocks.push({ type: 'cap', text: c }); }
      }
      if (tlen(blocks) >= 100) return { kind: 'fusion', blocks };
    } catch {}
  }
  const re = /application\/ld\+json[^>]*>([\s\S]*?)<\/script>/gi;
  let mm;
  while ((mm = re.exec(html))) {
    let any; try { any = JSON.parse(mm[1]); } catch { continue; }
    for (const o of flatten(any)) {
      if (typeof o.articleBody !== 'string') continue;
      const blocks = o.articleBody.split(/[\r\n]+/).map(plain).filter(Boolean).map((t) => ({ type: 'p', text: t }));
      if (tlen(blocks) >= 100) return { kind: 'ldjson', blocks };
    }
  }
  return null;
}

// ld+json articleBody 가 있으면 길이만(실린 자료로 바꾸면 얼마나 얻는지 보려고)
export function ldBodyLength(html) {
  const re = /application\/ld\+json[^>]*>([\s\S]*?)<\/script>/gi; let mm, best = 0;
  while ((mm = re.exec(html))) { let any; try { any = JSON.parse(mm[1]); } catch { continue; } for (const o of flatten(any)) if (typeof o.articleBody === 'string') best = Math.max(best, plain(o.articleBody).length); }
  return best;
}

// ---- 다듬기(읽기 창 hiddenBlocks · BodyCleanup) ----
const bylineKo = /^\s*(?:\[[^\]]{1,20}\]\s*)?([가-힣]{2,4})\s?(기자|특파원|에디터|선임기자|객원기자|논설위원)(?:\s*[=·,]?\s*[\w.+-]+@[\w-]+(?:\.[\w-]+)+)?(?:\s*Powered by [\w .]{1,40})?\s*$/;
const bylineEn = /^\s*By\s+[A-Z][a-z]+(?:\s+[A-Z][a-z.]+){0,3}\s*$/;
const orphanCap = /^\s*[\(\[]?\s*(?:AI\s?생성\s?(?:영상|이미지|사진)|(?:사진|영상|이미지|그래픽|자료)\s?(?:=|제공|출처|:)[^.。]{0,30})\s*[\)\]]?\s*$/;
export function isJunk(u) {
  if (!u) return true;
  const name = u.toLowerCase().split('?')[0];
  return /(default[-_]?user|avatar|profile|reporter|byline|author|gravatar|\/logo|logo[-_.]|favicon|\/icons?\/|icon[-_.]|spacer|blank\.|1x1|pixel\.|badge|sprite|emoji|\/ads?\/)/.test(name);
}
export function imageKey(url) {
  let u = url.toLowerCase().split(/[?#]/)[0];
  let name = u.split('/').pop() || u;
  const dot = name.lastIndexOf('.');
  if (dot >= 0 && name.length - dot <= 5) name = name.slice(0, dot);
  return name.replace(/([-_](v?\d{2,4}(x\d{2,4})?|thumb(nail)?|small|medium|large|scaled|crop(ped)?|resize[d]?|\d{2,4}w))+$/, '');
}
const sameImage = (a, b) => !!a && !!b && (a === b || (imageKey(a).length >= 6 && imageKey(a) === imageKey(b)));
export function cleanup(blocks, cover) {
  const hidden = new Set(); let byline = false;
  blocks.forEach((b, i) => {
    if (b.type !== 'p') return;
    const t = b.text || '';
    if (bylineKo.test(t) || bylineEn.test(t)) { hidden.add(i); byline = true; return; }
    const nextImg = blocks[i + 1]?.type === 'img';
    if (!nextImg && t.length <= 40 && orphanCap.test(t)) hidden.add(i);
  });
  if (cover) { const d = blocks.findIndex((b) => b.type === 'img' && sameImage(b.src, cover)); if (d >= 0) hidden.add(d); }
  blocks.forEach((b, i) => { if (b.type === 'img' && isJunk(b.src)) hidden.add(i); });
  for (const i of [...hidden]) if (blocks[i]?.type === 'img' && blocks[i + 1]?.type === 'cap') hidden.add(i + 1);
  return { shown: blocks.filter((_, i) => !hidden.has(i)), hiddenCount: hidden.size, bylineFound: byline };
}
const wallPhrases = ['subscribe to continue', 'subscribe to read', 'subscribers only', 'subscriber-only', 'to continue reading', 'sign in to continue', 'already a subscriber', 'create a free account to continue', 'this article is for subscribers', 'unlock this article', 'become a member to read', '유료 회원', '구독자 전용', '로그인 후 이용', '유료 기사', '프리미엄 회원'];
export function looksBlocked(blocks) {
  const texts = blocks.filter((b) => b.text != null).map((b) => b.text);
  if (texts.join('').length >= 1500) return false;
  const lower = texts.join(' ').toLowerCase();
  return wallPhrases.some((p) => lower.includes(p));
}

export function ogImage(html) {
  const found = {};
  for (const tag of html.slice(0, 200_000).match(/<meta\b[^>]*>/gi) || []) {
    const a = (n) => { const r = new RegExp(`\\b${n}\\s*=\\s*("([^"]*)"|'([^']*)'|([^\\s>]+))`, 'i').exec(tag); return r ? (r[2] ?? r[3] ?? r[4]) : null; };
    const k = (a('property') || a('name') || '').toLowerCase(); const c = a('content');
    if (k && c && !(k in found)) found[k] = c;
  }
  for (const k of ['og:image', 'og:image:url', 'og:image:secure_url', 'twitter:image', 'twitter:image:src']) if (found[k]) return found[k].replace(/&amp;/g, '&').trim();
  return null;
}

// 앱과 같은 순서로 본문을 얻는다. browser = 헤드리스 webkit
export async function appExtract(browser, url) {
  const trace = { path: 'none', http: null, fetchError: null, visible: 0, shortText: null, skipped: null, fastMs: 0, slowMs: 0, ldBody: 0 };
  const t0 = Date.now();
  const got = await appFetch(url);
  let refused = false, richPage = false, html = '';
  if (got.buf) {
    html = got.buf.toString('utf8');
    trace.ldBody = ldBodyLength(html);
    trace.og = ogImage(html);
    const ctx = await browser.newContext({ javaScriptEnabled: false, userAgent: WEB_UA, viewport: { width: 1200, height: 900 } });
    const page = await ctx.newPage();
    const enc = sniffCharset(got.buf, got.contentType);
    await page.route('**/*', (r) => (r.request().isNavigationRequest() && r.request().frame() === page.mainFrame()
      ? r.fulfill({ status: 200, body: Buffer.concat([Buffer.from(`<meta charset="${enc}">`), got.buf]), contentType: `text/html; charset=${enc}` }) : r.abort()));
    // Playwright 의 fulfill 은 charset 머리를 무시하고 이 Mac 의 기본(EUC-KR)으로 읽는다 — 앱은 load(data, characterEncodingName:) 로 넘기므로 meta 를 앞에 붙여 맞춘다
    let res = { art: null };
    try { await page.goto(got.finalUrl || url, { timeout: 8000, waitUntil: 'load' }); res = await tryExtract(page); } catch (e) { trace.fetchError = 'fastLoad:' + e.message.slice(0, 60); }
    await ctx.close();
    trace.fastMs = Date.now() - t0;
    trace.visible = visibleTextLength(got.buf);
    if (res.art) { trace.path = 'fast'; return { trace, art: res.art, html }; }
    if (res.shortText != null) trace.shortText = res.shortText;
    const emb = embedded(html);
    if (emb) { trace.path = 'embedded'; trace.embeddedKind = emb.kind; return { trace, art: { blocks: emb.blocks }, html }; }
    richPage = trace.visible > 600;
  } else if (got.status) {
    trace.http = got.status; refused = [401, 403, 429].includes(got.status);
    if (got.error) trace.fetchError = got.error;
  } else trace.fetchError = got.error;
  if (!trace.fastMs) trace.fastMs = Date.now() - t0;
  if ([404, 410].includes(trace.http)) { trace.skipped = 'gone'; return { trace, art: null, html }; }
  if (richPage) { trace.skipped = 'richPage'; return { trace, art: null, html }; }
  // 느린 길
  trace.path = 'slow';
  const t1 = Date.now();
  const ctx = await browser.newContext({ javaScriptEnabled: true, userAgent: WEB_UA, viewport: { width: 1200, height: 900 } });
  const page = await ctx.newPage();
  await page.route('**/*', (r) => (['image', 'media', 'font', 'websocket'].includes(r.request().resourceType()) ? r.abort() : r.continue()));
  page.goto(url, { timeout: 20000, waitUntil: 'commit' }).catch(() => {});
  const deadline = Date.now() + (refused ? 6000 : 15000);
  await new Promise((r) => setTimeout(r, 600));
  let last = 0, art = null;
  while (Date.now() < deadline) {
    const r = await tryExtract(page).catch(() => ({ art: null }));
    if (r.art) { const n = r.art.blocks.length; if (n >= 4 && n === last) { art = r.art; break; } last = n; }
    else if (r.shortText != null) trace.shortText = r.shortText;
    await new Promise((r) => setTimeout(r, 400));
  }
  if (!art) { const r = await tryExtract(page).catch(() => ({ art: null })); art = r.art; }
  if (art) trace.shortText = null;
  trace.slowStatus = await page.evaluate(() => document.title).catch(() => null);
  await ctx.close();
  trace.slowMs = Date.now() - t1;
  return { trace, art, html };
}
