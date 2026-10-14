// 미리 보기 전용(WebView2 밖에서만): 맥·브라우저에서 onboarding.html 을 열어 모양을 확인
if (!(window.chrome && window.chrome.webview)) {
  const again = /again/.test(location.hash); // #again: 설정에서 다시 연 모양(고른 분야가 있음)
  // 분야 사진 대신 data: 그림(바깥 주소는 쓰지 않음). bridge.img 는 http(s) 만 받으므로 미리 보기에서는 data: 도 통과
  const pic = (a, b) => 'data:image/svg+xml,' + encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" width="600" height="400"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="${a}"/><stop offset="1" stop-color="${b}"/></linearGradient></defs><rect width="600" height="400" fill="url(#g)"/><circle cx="420" cy="120" r="70" fill="rgba(255,255,255,.35)"/><path d="M0 330 Q150 230 300 310 T600 280 V400 H0Z" fill="rgba(0,0,0,.25)"/></svg>`);
  const img0 = window.bridge.img;
  window.bridge.img = (u) => (u && u.startsWith('data:') ? u : img0(u));
  const EN = { politics: 'POLITICS', economy: 'ECONOMY', society: 'SOCIETY', world: 'WORLD', tech: 'TECH', ai: 'AI', science: 'SCIENCE', life: 'LIFE · HEALTH', culture: 'CULTURE', sports: 'SPORTS', climate: 'CLIMATE' };
  // 처음엔 몇 분야만 사진이 있고, 'photos' 를 물으면 나머지가 차례로 채워진다(사진을 못 찾는 분야 하나는 색면 그대로)
  const PH = { politics: pic('#1e293b', '#64748b'), economy: pic('#065f46', '#34d399'), world: pic('#1e3a8a', '#93c5fd'), ai: pic('#4c1d95', '#f472b6') };
  const LATER = { society: pic('#7c2d12', '#fdba74'), tech: pic('#0c4a6e', '#22d3ee'), science: pic('#164e63', '#a5f3fc'), life: pic('#831843', '#fda4af'), sports: pic('#14532d', '#a3e635'), climate: pic('#14532d', '#86efac') };
  let asked = 0;
  const S = [
    ['politics', '정치', 'cat.policy', '#5E5CE6', '연합뉴스 정치 · 동아일보 정치 · NYT Politics'],
    ['economy', '경제', 'cat.business', '#30C759', 'BBC Business · CNBC · 연합뉴스 마켓+'],
    ['society', '사회', 'people', '#FF6B35', '경향신문 사회 · 연합뉴스 사회 · SBS 사회'],
    ['world', '국제', 'globe', '#0A84FF', 'BBC World · Guardian World · 연합뉴스 국제'],
    ['tech', 'IT', 'desktop', '#64D2FF', 'Ars Technica · GeekNews · The Verge'],
    ['ai', 'AI', 'sparkles', '#BF5AF2', 'Anthropic · Google AI · Google DeepMind'],
    ['science', '과학', 'atom', '#32ADE6', 'BBC Science · Quanta Magazine · 동아일보 의학·과학'],
    ['life', '생활·건강', 'heart', '#FF375F', 'BBC Health · 연합뉴스 건강 · 동아일보 건강'],
    ['culture', '문화·연예', 'masks', '#FFD60A', 'Guardian Culture · 동아일보 문화 · 연합뉴스 문화'],
    ['sports', '스포츠', 'sport', '#34C759', 'BBC Sport · 연합뉴스 스포츠 · SBS 스포츠'],
    ['climate', '기후·환경', 'leaf', '#30D158', 'Carbon Brief · Guardian Environment · Inside Climate News', true],
  ];
  window.DropcapMock = (cmd, a) => {
    if (cmd === 'choose') { console.log('choose', JSON.stringify(a)); return null; }
    if (cmd === 'photos') { if (++asked >= 2) Object.assign(PH, LATER); return { ...PH }; }
    if (cmd !== 'ready' && cmd !== 'view') return null;
    return {
      first: !again,
      top: { id: 'top', label: '주요 뉴스', icon: 'star.fill', color: '#FF9F0A', help: '어느 분야든 여러 곳이 함께 크게 다룬 소식만 골라 알려 드려요', on: true },
      cards: S.map(([id, label, icon, color, sources, more]) => ({ id, label, icon, color, more: !!more, sources: id === 'climate' ? null : sources, english: EN[id], photo: PH[id] || null })),
      picked: again ? ['economy', 'ai', 'climate'] : [],
      showMore: again,
    };
  };
}
