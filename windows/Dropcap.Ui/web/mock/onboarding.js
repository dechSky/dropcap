// 미리 보기 전용(WebView2 밖에서만): 맥·브라우저에서 onboarding.html 을 열어 모양을 확인
if (!(window.chrome && window.chrome.webview)) {
  const again = /again/.test(location.hash); // #again: 설정에서 다시 연 모양(고른 분야가 있음)
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
    if (cmd !== 'ready' && cmd !== 'view') return null;
    return {
      first: !again,
      top: { id: 'top', label: '주요 뉴스', icon: 'star.fill', color: '#FF9F0A', help: '어느 분야든 여러 곳이 함께 크게 다룬 소식만 골라 알려 드려요', on: true },
      cards: S.map(([id, label, icon, color, sources, more]) => ({ id, label, icon, color, more: !!more, sources })),
      picked: again ? ['economy', 'ai', 'climate'] : [],
      showMore: again,
    };
  };
}
