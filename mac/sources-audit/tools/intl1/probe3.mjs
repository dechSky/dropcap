// 유료벽 시점 보기: 같은 페이지를 열어 2·6·12초에 본문 문단 글자 수(보이는 것)
import { chromium, webkit } from 'playwright'; import { CHROME_UA } from './site.mjs'; import { WEB_UA } from './appextract.mjs';
const [eng, url, sel] = process.argv.slice(2);
const b = await (eng === 'webkit' ? webkit : chromium).launch(); const c = await b.newContext({ userAgent: eng === 'webkit' ? WEB_UA : CHROME_UA, viewport: { width: 1280, height: 900 } }); const p = await c.newPage();
const r = await p.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });
const m = () => p.evaluate((sel) => { const ps = [...document.querySelectorAll(sel + ' p')].filter(e => e.getBoundingClientRect().height > 0); return ps.length + 'p/' + ps.reduce((n, e) => n + e.innerText.trim().length, 0) + 'c'; }, sel);
const out = [r.status()]; for (const t of [2000, 4000, 6000]) { await p.waitForTimeout(t); out.push(await m()); }
console.log(eng, out.join(' '), url.slice(8, 60)); await b.close();
