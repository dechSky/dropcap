// 본문 칸 찾기 도우미: 문단(p)을 직접 많이 품은 요소들의 선택자·글자 수
import { chromium } from 'playwright'; import { CHROME_UA } from './site.mjs';
const b = await chromium.launch();
for (const url of process.argv.slice(2)) {
  const c = await b.newContext({ userAgent: CHROME_UA, viewport: { width: 1280, height: 900 } }); const p = await c.newPage();
  try { const r = await p.goto(url, { timeout: 30000, waitUntil: 'domcontentloaded' }); await p.waitForTimeout(4000);
  const out = await p.evaluate(() => { const m = new Map();
    document.querySelectorAll('p').forEach(x => { const par = x.parentElement; if (!par) return; const k = m.get(par) || { n: 0, len: 0 }; k.n++; k.len += (x.innerText||'').trim().length; m.set(par, k); });
    const d = (e) => { let s = e.tagName.toLowerCase(); if (e.id) s += '#' + e.id; if (e.className && typeof e.className === 'string') s += '.' + e.className.trim().split(/\s+/).slice(0, 3).join('.'); return s; };
    return [...m.entries()].filter(([, v]) => v.n >= 2).sort((a, b) => b[1].len - a[1].len).slice(0, 6).map(([e, v]) => `${v.n}p ${v.len}c  ${d(e)}  < ${e.parentElement ? d(e.parentElement) : ''}`); });
  console.log('##', r?.status(), url); out.forEach(x => console.log('  ', x)); } catch (e) { console.log('ERR', url, e.message.slice(0, 80)); }
  await c.close(); await new Promise(r => setTimeout(r, 1500));
}
await b.close();
