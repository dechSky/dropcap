// 본문 추출 스크립트(Dropcap.Ui/web/extract.js) 시험 도우미: 머리 없는 Chromium(WebView2 와 같은 엔진)에서
// 앱의 격리 칸과 같은 조건(받은 HTML 을 원래 주소로, 페이지 스크립트·그림·바깥 요청 모두 막음)으로 돌리고 결과 JSON 을 낸다.
// 입력(표준 입력, JSON): { readability, extract, cases: [{ html, base }] } → 출력: 결과 배열(각각 추출 JSON 글자 또는 null)
// 필요: DROPCAP_PLAYWRIGHT = playwright-core 폴더. DROPCAP_CHROMIUM = 브라우저 실행 파일(없으면 Playwright 캐시에서 찾음).
// 창을 띄우지 않는다(머리 없음 — 포커스를 뺏지 않음).
import { createRequire } from 'node:module';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const require = createRequire(import.meta.url);
const { chromium } = require(process.env.DROPCAP_PLAYWRIGHT);

function findChromium() {
  if (process.env.DROPCAP_CHROMIUM) return process.env.DROPCAP_CHROMIUM;
  const roots = [path.join(os.homedir(), 'Library/Caches/ms-playwright'), path.join(os.homedir(), '.cache/ms-playwright'),
    path.join(process.env.LOCALAPPDATA || '', 'ms-playwright')];
  for (const root of roots) {
    if (!fs.existsSync(root)) continue;
    const dirs = fs.readdirSync(root).filter((d) => d.startsWith('chromium_headless_shell-')).sort().reverse();
    for (const d of dirs) {
      for (const rel of ['chrome-headless-shell-mac-arm64/chrome-headless-shell', 'chrome-headless-shell-mac-x64/chrome-headless-shell',
        'chrome-headless-shell-linux64/chrome-headless-shell', 'chrome-headless-shell-win64/chrome-headless-shell.exe']) {
        const p = path.join(root, d, rel);
        if (fs.existsSync(p)) return p;
      }
    }
  }
  return undefined;
}

const input = JSON.parse(fs.readFileSync(0, 'utf8'));
const csp = "default-src 'none'; style-src 'unsafe-inline'; img-src 'none'; font-src 'none'; script-src 'none'; connect-src 'none'; frame-src 'none'";
const browser = await chromium.launch({ headless: true, executablePath: findChromium() });
const out = [];
try {
  for (const c of input.cases) {
    const page = await browser.newPage();
    await page.route('**/*', (route) => {
      const u = route.request().url();
      if (u === c.base) route.fulfill({ status: 200, headers: { 'Content-Type': 'text/html; charset=utf-8', 'Content-Security-Policy': csp }, body: c.html });
      else route.abort();
    });
    await page.goto(c.base, { waitUntil: 'domcontentloaded' });
    out.push(await page.evaluate(input.readability + '\n;\n' + input.extract));
    await page.close();
  }
} finally {
  await browser.close();
}
process.stdout.write(JSON.stringify(out));
