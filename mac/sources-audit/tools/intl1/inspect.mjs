// 점검 결과 한 출처를 사람이 보기 쉽게(터미널 전용 — 본문 조각이 나오므로 저장소에 남기지 않음)
import fs from 'node:fs'; import path from 'node:path';
const OUT = process.env.OUT || path.resolve(import.meta.dirname, '../../../../../srcaudit-shots/intl1/data');
for (const id of process.argv.slice(2)) {
  const r = JSON.parse(fs.readFileSync(path.join(OUT, id + '.json'), 'utf8'));
  console.log(`### ${r.id} feed=${r.feedStatus} kind=${r.feedKind} items=${r.feedItems} ${r.feedError || ''} ${r.fatal || ''}`);
  for (const a of r.articles || []) {
    const f = a.feed;
    console.log(`\n-- ${a.link}\n why=${a.why} feed: desc=${f.descLen} tags=${f.descTags} content=${f.contentLen} ctags=${(f.contentTags||[]).slice(0,8)} cimgs=${f.contentImgs} media=${JSON.stringify((f.media||[]).map(m=>[m.el,m.w,(m.url||'').slice(-40)]))} cats=${f.cats}${JSON.stringify(f.catSample)} author=${f.author} date=${f.date} fullPct=${a.feedFullPct}`);
    console.log(` trace=${JSON.stringify(a.trace)} appMs=${a.appMs} raw=${a.oursRaw} hidden=${a.hiddenCount} byline=${a.bylineFound} paywalled=${a.paywalled}`);
    const s = a.site || {};
    console.log(` site: status=${s.status} used=${s.used} title=${(s.title||'').slice(0,60)} walls=${s.walls} wallDom=${s.wallDom} cookie=${s.cookie} more=${s.more} embeds=${s.embeds} time=${s.timePos} ld=${JSON.stringify(s.ld)} captcha=${s.captcha} err=${s.err||''}`);
    if (a.cmp) { const c = a.cmp; console.log(` cmp: ${c.ourChars}/${c.siteChars} ${c.pct}% imgs=${JSON.stringify(c.imgs)} shape=${JSON.stringify(c.shape)}`);
      for (const m of c.missing) console.log(`   MISS ${m.tag} ${m.idx}/${m.n} ${m.len}: ${m.text.slice(0,110)}`);
      for (const x of c.extra) console.log(`   EXTRA ${x.type} ${x.idx}/${x.n} ${x.len} [${x.kind}]: ${x.text.slice(0,110)}`); }
    if (process.env.BLOCKS) { console.log(' OURS:'); (a.ours||[]).forEach(b=>console.log(`   ${b.type} ${b.text? b.text.slice(0,90): b.src}`)); console.log(' SITE:'); (s.blocks||[]).forEach(b=>console.log(`   ${b.tag}${b.junk?'(junk)':''}${b.fig?'(fig)':''} ${b.text.slice(0,90)}`)); (s.imgs||[]).forEach(i=>console.log(`   IMG ${i.w}x${i.h} d${i.dw} cap${i.cap} ${i.junk?'junk':''} ${i.src.slice(-60)}`)); }
  }
}
