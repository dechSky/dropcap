// 미리 보기 전용(WebView2 밖에서만): reader.html?key=x 를 열어 모양을 확인.
// ?phase=loading|translating|failed 로 단계별 화면, ?cover=0 으로 표지 없이.
// ?free=1 로 '같은 소식을 무료로 읽기' 상자(유료 기사), ?blocked=1 로 본문을 막아 둔 사이트의 실패 문구.
if (!(window.chrome && window.chrome.webview)) {
  const q = new URLSearchParams(location.search);
  const phase = q.get('phase') || 'done';
  // 사진은 data: 주소로(미리 보기에서도 바깥 요청 없이)
  const svg = (w, h, a, b) => 'data:image/svg+xml,' + encodeURIComponent(
    `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="${a}"/><stop offset="1" stop-color="${b}"/></linearGradient></defs><rect width="100%" height="100%" fill="url(#g)"/><circle cx="${w * 0.7}" cy="${h * 0.4}" r="${h * 0.22}" fill="rgba(255,255,255,.35)"/></svg>`);
  const img = window.bridge.img;
  window.bridge.img = (u) => (u && u.startsWith('data:image/svg') ? u : img(u)); // 미리 보기의 가짜 사진만 그대로
  const B = (type, text, original, extra = {}) => ({ type, text, original, src: null, scrap: ['p', 'li', 'quote', 'h'].includes(type), ...extra });
  const blocks = [
    B('p', 'OpenAI가 새 추론 모델 GPT-6를 공개했다. 회사는 이 모델이 수학·코딩 시험에서 이전 모델보다 크게 나아졌고, 긴 문서를 읽고 계획을 세우는 능력도 좋아졌다고 밝혔다.', 'OpenAI on Tuesday released GPT-6, a new reasoning model. The company said it improves substantially on math and coding benchmarks and is better at reading long documents and planning.'),
    B('p', '샘 올트먼 최고경영자는 발표 자리에서 "이번 모델은 사람이 하루 걸리는 일을 몇 분 만에 끝낸다"고 말했다.', 'CEO Sam Altman said at the launch event that "this model finishes in minutes what takes a person a day."'),
    B('img', null, null, { src: svg(1200, 700, '#10A37F', '#0F62FE'), scrap: false }),
    B('cap', '발표 행사장의 모습', 'The launch event'),
    B('h', '무엇이 달라졌나', 'What changed'),
    B('li', '수학 경시 문제 정답률 92%', '92% on competition math'),
    B('li', '코드 고치기 시험 통과율 두 배', 'Twice the pass rate on code repair'),
    B('li', '100만 토큰 문맥', '1M-token context'),
    B('quote', '"안전 시험은 출시 전 석 달 동안 바깥 기관과 함께 했다."', '"We ran safety testing with outside groups for three months before launch."'),
    B('pre', 'curl https://api.example.com/v1/models', null, { scrap: false }),
    B('p', '가격은 이전 모델과 같으며, 이번 주부터 유료 사용자에게 차례로 열린다. 무료 사용자는 다음 달부터 하루 몇 번씩 쓸 수 있다.', 'Pricing is unchanged, and it rolls out to paid users this week. Free users get limited daily access next month.'),
  ].map((b, i) => ({ ...b, i }));
  const translating = phase === 'translating';
  const free = q.get('free') === '1';
  const doc = {
    key: q.get('key') || 'x',
    item: { key: 'x', title: 'OpenAI, 추론 기능 강화한 GPT-6 공개', source: 'The Verge', initial: 'V', color: '#E1306C', tier: 'press', tierLabel: '언론', category: 'model', link: 'https://www.theverge.com/ai/openai-gpt-6' },
    phase,
    title: translating ? 'OpenAI launches GPT-6 with new reasoning features' : 'OpenAI, 추론 기능 강화한 GPT-6 공개',
    originalTitle: 'OpenAI launches GPT-6 with new reasoning features',
    translated: phase === 'done',
    engine: 'Google 번역',
    summary: translating ? null : ['GPT-6는 수학·코딩 시험에서 크게 나아졌다.', '긴 문서를 읽고 계획을 세우는 능력이 좋아졌다.', '가격은 그대로이며 이번 주 유료 사용자부터 열린다.'],
    summarizing: false,
    fallback: phase === 'failed' ? 'OpenAI가 추론 기능을 강화한 새 모델 GPT-6를 공개했다. 수학과 코딩 성능이 크게 좋아졌다고 회사는 밝혔다.' : '',
    translatedPage: true,
    feedSummary: 'OpenAI가 수학·코딩 성능을 크게 끌어올린 새 추론 모델 GPT-6를 공개했다. 가격은 이전 모델과 같다.',
    blockedHost: q.get('blocked') === '1',
    paywall: free ? 'hard' : null,
    paywalled: false,
    alternatives: free ? [
      { key: 'a1', source: 'OpenAI', title: 'GPT-6 소개: 더 깊이 생각하는 모델', color: '#10A37F' },
      { key: 'a2', source: 'AI타임스', title: '오픈AI, 추론 강화한 GPT-6 출시… 가격은 동결', color: '#0F62FE' },
    ] : [],
    freeReason: free ? (phase === 'failed' ? '본문을 열지 못했습니다' : '유료 기사입니다') : null,
    cover: q.get('cover') === '0' ? null : svg(1600, 900, '#E1306C', '#5856D6'),
    date: '10월 13일 오후 3:05',
    minutes: { shown: 2, original: 1 },
    koreanTitle: true,
    blocks: translating ? blocks.map((b, i) => (i < 4 ? b : { ...b, text: b.original || b.text, original: null })) : blocks,
    marks: { saved: false, scrapped: false, scraps: [], collections: ['스크랩', '모델 동향'], lastCollection: '스크랩' },
    fontSize: 17,
  };
  const marks = doc.marks;
  const textOf = (i, orig) => { const b = blocks[i]; return (orig && b.original) || b.text; };
  const add = (quote, collection) => {
    const c = collection || marks.lastCollection;
    if (!marks.scraps.some((s) => s.quote === quote)) marks.scraps.push({ quote, collection: c, memo: '' });
    marks.lastCollection = c;
    marks.scrapped = true;
    return { quote, collection: c };
  };
  let speaking = false;
  window.DropcapMock = (cmd, a) => {
    switch (cmd) {
      case 'ready': case 'view': return JSON.parse(JSON.stringify(doc));
      case 'marks': return JSON.parse(JSON.stringify(marks));
      case 'fontSize': doc.fontSize = a.size; setTimeout(() => bridge.emit('fontSize', { size: a.size })); return { size: a.size };
      case 'speak': speaking = !speaking; return { speaking };
      case 'speaking': return { speaking };
      case 'save': marks.saved = !marks.saved; return JSON.parse(JSON.stringify(marks));
      case 'scrapArticle': marks.scrapped = true; marks.lastCollection = a.collection || marks.lastCollection; return { collection: marks.lastCollection };
      case 'newCollection': marks.collections.push(a.name); marks.scrapped = true; marks.lastCollection = a.name; return { collection: a.name };
      case 'scrapParagraph': return add(textOf(a.index, a.original), a.collection);
      case 'scrapSelection': return add(a.quote);
      case 'updateScrap': { const s = marks.scraps.find((x) => x.quote === a.quote); if (s) { if (a.collection) s.collection = a.collection; if (a.memo != null) s.memo = a.memo; } return null; }
      case 'removeScrap': marks.scraps = marks.scraps.filter((x) => x.quote !== a.quote); setTimeout(() => bridge.emit('changed')); return null;
      case 'step': console.log('mock step', a.dir); return { moved: false };
      default: console.log('mock', cmd, a); return null;
    }
  };
}
