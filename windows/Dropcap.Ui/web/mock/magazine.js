// 미리 보기 전용(WebView2 밖에서만): 맥·브라우저에서 magazine.html 을 열어 모양을 확인
// magazine.html?page=today|week|section:economy|section:ai|stories|story:s1|saved|scrapbook|search|issue:daily-2026-10-12
if (!(window.chrome && window.chrome.webview)) {
  const now = Date.now();
  // 사진 대신 data: 그림(바깥 주소는 쓰지 않음)
  const pic = (a, b) => 'data:image/svg+xml,' + encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" width="800" height="500"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="${a}"/><stop offset="1" stop-color="${b}"/></linearGradient></defs><rect width="800" height="500" fill="url(#g)"/><circle cx="600" cy="140" r="90" fill="rgba(255,255,255,.25)"/><path d="M0 420 Q200 300 400 400 T800 360 V500 H0Z" fill="rgba(0,0,0,.18)"/></svg>`);
  // bridge.img 는 http(s) 만 받으므로 미리 보기에서는 data: 도 통과시킨다
  const img0 = window.bridge.img;
  window.bridge.img = (u) => (u && u.startsWith('data:') ? u : img0(u));
  const kinds = { article: '기사', video: '영상', paper: '논문', release: '릴리스', post: '커뮤니티', podcast: '팟캐스트' };
  // 분야(shared/categories.json 과 같은 이름·색·아이콘)
  const SEC = {
    top: ['주요 뉴스', 'star.fill', '#FF9F0A'], politics: ['정치', 'cat.policy', '#5E5CE6'], economy: ['경제', 'cat.business', '#30C759'],
    society: ['사회', 'people', '#FF6B35'], world: ['국제', 'globe', '#0A84FF'], tech: ['IT', 'desktop', '#64D2FF'], ai: ['AI', 'sparkles', '#BF5AF2'],
    science: ['과학', 'atom', '#32ADE6'], life: ['생활·건강', 'heart', '#FF375F'], culture: ['문화·연예', 'masks', '#FFD60A'], sports: ['스포츠', 'sport', '#34C759'],
  };
  const AI = { model: ['모델·제품', 'cat.model', '#007AFF', '#0A84FF'], research: ['연구', 'cat.research', '#AF52DE', '#BF5AF2'], policy: ['정책·규제', 'cat.policy', '#5856D6', '#5E5CE6'],
    business: ['투자·기업', 'cat.business', '#34C759', '#30D158'], security: ['보안', 'cat.security', '#FF3B30', '#FF453A'] };
  const topicOf = (sec, cat) => sec === 'ai' && AI[cat]
    ? { label: 'AI·' + AI[cat][0], icon: AI[cat][1], light: AI[cat][2], dark: AI[cat][3] }
    : { label: SEC[sec][0], icon: SEC[sec][1], light: SEC[sec][2], dark: SEC[sec][2] };
  let n = 0;
  const topics = {};
  // 유료 기사 자물쇠(G-14) 이유 — Core PaywallKinds.Help 와 같은 문구
  const PW = { hard: '유료 기사 — 열면 같은 소식의 무료 보도를 먼저 권합니다', metered: '일부 유료(무료 건수 제한)', learned: '본문이 자주 막히는 곳 — 열면 같은 소식의 무료 보도를 먼저 권합니다' };
  const it = (title, source, color, sec, o = {}) => {
    n++;
    const kind = o.kind || 'article';
    const category = o.category || 'other';
    const key = `${source}|${n}`;
    topics[key] = topicOf(sec, category);
    return {
      key, title, original: o.original || title, translated: !!o.original, link: 'https://example.com/' + n, source, sourceId: source.toLowerCase(),
      initial: source[0], color, tier: o.kr ? 'kr' : 'press', tierLabel: o.tier || (o.kr ? '국내' : '언론'), category, categoryLabel: '', kind, kindLabel: kinds[kind],
      external: kind === 'video' || kind === 'podcast', related: o.related || 0, relatedNames: [], time: o.time || `${n * 7}분 전`, date: now - n * 420000,
      summary: '', image: o.image, important: !!o.important, read: !!o.read, saved: !!o.saved,
      paywall: o.paywall || null, paywallHelp: o.paywall ? PW[o.paywall] : null,
    };
  };
  const cover = it('한국은행, 기준금리 연 2.75%로 동결…“물가·환율 더 지켜볼 것”', '연합뉴스', '#0F62FE', 'economy',
    { image: pic('#0f766e', '#1e3a8a'), related: 4, important: true, kr: true });
  const top = [
    it('미 연준 의장 “금리 인하 서두르지 않겠다”', 'NYT', '#000000', 'world', { image: pic('#7c2d12', '#f59e0b'), related: 6, paywall: 'metered' }),
    it('국회, 내년 예산안 처리 시한 넘겨…여야 협상 계속', 'KBS', '#1C3F94', 'politics', { kr: true, related: 3 }),
    it('OpenAI, 추론 기능을 크게 강화한 새 모델 공개', 'The Verge', '#E1306C', 'ai', { category: 'model', image: pic('#7c3aed', '#db2777'), related: 5,
      original: 'OpenAI launches a new model with much stronger reasoning' }),
  ];
  const economy = [
    it('코스피 2,900 회복…외국인 사흘째 순매수', '한국경제', '#0B3B8C', 'economy', { kr: true, image: pic('#065f46', '#34d399') }),
    it('환율 1,380원대로 내려와', '매일경제', '#E60012', 'economy', { kr: true, read: true }),
    it('수출 석 달째 늘어…반도체가 이끌어', '조선비즈', '#003F87', 'economy', { kr: true, image: pic('#1e3a8a', '#60a5fa') }),
    it('Global markets rally as inflation cools', 'Bloomberg', '#000000', 'economy', { image: pic('#111827', '#6b7280'), paywall: 'hard' }),
  ];
  const ai = [
    it('구글, 제미니 새 판 공개…긴 문맥 1천만 토큰', 'TechCrunch', '#0A9E01', 'ai', { category: 'model', image: pic('#0369a1', '#22d3ee'), related: 2 }),
    it('작은 모델이 큰 모델을 가르치는 새 방법', 'MIT Tech Review', '#A31F34', 'ai', { category: 'research' }),
    it('EU AI 법 시행 첫 주…기업들 대응 분주', 'AI타임스', '#0F62FE', 'ai', { category: 'policy', kr: true }),
  ];
  const sports = [
    it('프로야구 한국시리즈 1차전, 9회 끝내기 홈런', 'SBS', '#00A0E9', 'sports', { kr: true, image: pic('#14532d', '#84cc16') }),
    it('손흥민, 시즌 5호 골…팀은 2-1 승리', '스포츠조선', '#D7000F', 'sports', { kr: true }),
  ];
  const other = [
    it('가을 단풍 절정 시기 예년보다 늦어', '한겨레', '#00A1E9', 'life', { kr: true }),
    it('Attention Is All You Need, 다시 읽기', 'arXiv', '#b31b1b', 'ai', { category: 'research', kind: 'paper' }),
  ];
  const videos = [
    it('기준금리 동결 기자회견 전체 영상', 'YouTube · 한국은행', '#FF0000', 'economy', { kind: 'video', image: pic('#111827', '#ef4444') }),
  ];
  const S = (sec) => ({ light: SEC[sec][2], dark: SEC[sec][2] });
  // 분야 유리 띠(맥 SectionGlassCard 높이 92): 사진은 처음엔 몇 분야만, 4초 뒤 'photos' 알림으로 스포츠가 채워짐(AI 는 색면 그대로)
  const EN = { top: 'TOP', economy: 'ECONOMY', ai: 'AI', sports: 'SPORTS' };
  const PHOTOS = { top: pic('#7c2d12', '#fbbf24'), economy: pic('#065f46', '#34d399') };
  const section = (id, label, icon, c, items, showTopic, tone) => {
    const sec = id === 'other' || id === 'video' ? undefined : id;
    return { id, section: sec, label, icon, tone: tone || 'cat-other', light: c.light, dark: c.dark, showTopic, items,
      glass: sec ? { english: EN[sec], sub: `${items.length}건 · ${items[0].title}`, photo: PHOTOS[sec] || null } : undefined };
  };
  const allSections = [
    section('top', '주요 뉴스', 'star.fill', S('top'), top, true),
    section('economy', '경제', 'cat.business', S('economy'), economy, false),
    section('ai', 'AI', 'sparkles', S('ai'), ai, false),
    section('sports', '스포츠', 'sport', S('sports'), sports, false),
    section('other', '그 밖의 소식', 'cat.other', { light: '#8E8E93', dark: '#8E8E93' }, other, true),
    section('video', '영상', 'kind.video', { light: '#FF3B30', dark: '#FF453A' }, videos, false, 'kind-video'),
  ];
  const regions = { [top[0].key]: { intl: ['Reuters', 'Bloomberg', 'AP'], kr: ['연합뉴스', '한국경제'] }, [economy[0].key]: { intl: ['Bloomberg'], kr: ['한국경제', '매일경제'] } };
  const chipsAll = allSections.filter((s) => s.section).map((s) => ({ id: s.id, label: s.label, icon: s.icon, light: s.light, dark: s.dark, count: s.items.length }));
  const issue = (title, live, focus, sub) => {
    let sections = allSections;
    if (focus) {
      sections = allSections.filter((s) => s.section === focus)
        .map((s) => ({ ...s, items: sub ? s.items.filter((i) => i.category === sub) : s.items })).filter((s) => s.items.length);
    }
    return {
      id: live ? 'live-daily' : 'daily-2026-10-12', title, live, count: 42, sectionCount: allSections.length, sort: localStorage.magSort || 'recommended',
      head: `소식 42건 중 ${1 + sections.reduce((n, x) => n + x.items.length, 0)}건 실음 · 분야 ${sections.filter((x) => x.tone !== 'kind-video').length}개`,
      kicker: live ? '오늘' : '지난 호', chipsGo: live && !focus,
      cover: focus ? undefined : { item: cover, cluster: 's1', size: 5 },
      empty: focus && !sections.length ? { preparing: false, title: '이번 호에는 아직 이 분야 소식이 없습니다', sub: '새 소식이 들어오는 대로 지면이 채워집니다.' } : undefined,
      sections, clusters: { [cover.key]: 's1', [top[0].key]: 's1' }, revision: 3, imageRevision: 1, layoutRevision: 0, preparing: false,
      focus, sub, chips: chipsAll, subChips: focus === 'ai' ? Object.entries(AI).map(([id, a]) => ({ id, label: a[0], icon: a[1], light: a[2], dark: a[3], count: 0 })) : [],
      topics, regions,
      // 오늘 호 완독(M-23): 오늘 호 · 분야를 고르지 않았을 때만. #done 이면 다 읽은 모양
      today: live && !focus ? today() : undefined, todayDone: live && done,
      // 저녁 정리(N-26): 오늘 호의 경제 지면 맨 위
      brief: live && focus === 'economy' ? brief : undefined,
    };
  };
  let done = /done/.test(location.hash);
  const read = new Set([cover.key]);
  const todayKeys = () => [cover, ...top.slice(0, 3), ...economy.slice(0, 3), ...ai.slice(0, 3), ...sports.slice(0, 3)].map((i) => i.key);
  const today = (keys = todayKeys()) => {
    const r = done ? keys.length : keys.filter((k) => read.has(k)).length;
    if (keys.length && r >= keys.length) done = true;
    return { keys, read: r, done, next: '다음 호는 내일 오전 9시 브리핑으로 알려 드릴게요' };
  };
  const brief = {
    section: 'economy', title: '저녁 정리 · 경제', time: '오후 6:00', light: '#30C759', dark: '#30C759',
    help: '이 PC 의 Ollama 가 아래 기사들의 제목·요약만 보고 만든 정리입니다. 틀릴 수 있어 근거 기사를 함께 둡니다.',
    lines: [
      { text: '한국은행이 기준금리를 연 2.75%로 묶고 물가·환율 흐름을 더 보기로 했다.', refs: [1] },
      { text: '외국인 순매수가 사흘째 이어지며 코스피가 2,900 선을 되찾았다.', refs: [2, 3] },
      { text: '반도체 수출이 석 달째 늘어 하반기 경기 회복 기대가 커졌다.', refs: [4] },
    ],
    items: [cover, economy[0], economy[1], economy[2]].map((i) => ({ key: i.key, title: i.original, source: i.source, link: i.link })),
  };
  const src = (name, initial, color) => ({ name, initial, color });
  const scraps = [
    { id: 'a', quote: '한국은행은 물가와 환율 흐름을 더 지켜보겠다고 밝혔다.', original: null, memo: '다음 금통위 날짜 확인', collection: '스크랩' },
    { id: 'b', quote: null, original: null, memo: '', collection: '스크랩' },
  ];
  let folders = [{ name: '스크랩', count: 2 }, { name: '경제 메모', count: 0 }];
  let following = false;
  let mockRecent = ['기준금리'];
  // 보관 기사(가짜): 경제·AI 번갈아
  let mockArchive = true;
  const archRows = (q, offset, limit) => Array.from({ length: 260 }, (_, i) => {
    const eco = i % 2 === 0;
    return { key: `archive|https://old.example/${i}`, id: `https://old.example/${i}|${i}`, title: eco ? `기준금리 동결 ${i}` : `새 모델 공개 ${i}`, original: eco ? null : `New model ${i}`,
      source: eco ? '연합뉴스' : 'The Verge', section: eco ? 'economy' : 'ai', sectionName: eco ? '경제' : 'AI', light: eco ? '#30C759' : '#BF5AF2', dark: eco ? '#30C759' : '#BF5AF2',
      when: `9/${(i % 28) + 1} 0${i % 10}:15` };
  }).filter((r) => !q || r.title.includes(q) || r.source.includes(q)).slice(offset, offset + limit);
  window.DropcapMock = (cmd, a) => {
    switch (cmd) {
      case 'ready': case 'sidebar':
        return { saved: 3, scraps: 2, sort: 'recommended', sections: ['top', 'economy', 'ai', 'sports'].map((id) => ({ id, name: SEC[id][0], icon: SEC[id][1], light: SEC[id][2], dark: SEC[id][2] })),
          archive: [
            { id: 'daily-2026-10-12', title: '10월 12일 일요일 호', weekly: false },
            { id: 'daily-2026-10-11', title: '10월 11일 토요일 호', weekly: false, thin: true, count: 3 },
            { id: 'weekly-2026-W40', title: '주간 · 10월 4일–10월 10일', weekly: true },
          ],
          groups: [
            { id: 'this', title: '지난 호 · 이번 주', folded: false, emptyDays: 0, rows: [{ id: 'daily-2026-10-12', title: '10월 12일 일요일 호', weekly: false }] },
            { id: 'last', title: '지난주', folded: false, emptyDays: 2, rows: [
              { id: 'daily-2026-10-11', title: '10월 11일 토요일 호', weekly: false, thin: true, count: 3, reason: '기록 적음 — 앱을 쓰기 전이거나 켠 출처가 적던 때라 모인 소식이 3건뿐입니다' },
              { id: 'weekly-2026-W40', title: '주간 · 10월 4일–10월 10일', weekly: true }] },
          ],
          checking: false, lastCheck: '마지막 확인 3분 전' };
      case 'issue':
        if (a.sort) localStorage.magSort = a.sort;
        if (a.source === 'week') return { ...issue('주간 · 10월 6일–10월 13일', true), cover: undefined, sections: [], count: 0, sectionCount: 0, chips: [],
          empty: { preparing: true, title: '첫 호를 엮는 중…', sub: '구독한 출처에서 최근 일주일 소식을 모으고 번역하고 있어요. 잠시면 됩니다.' }, preparing: true };
        // 분야 지면(M-25): 그 분야만으로 따로 엮은 호 — 표지도 그 분야, 칩은 AI 하위 칩만(건수 합 = 실린 수)
        if (a.source.startsWith('section:')) {
          const id = a.source.slice(8);
          const pool = [cover, ...top, ...economy, ...ai, ...sports, ...other].filter((i) => (topics[i.key] || {}).label && (id === 'ai' ? topics[i.key].label.startsWith('AI') : topics[i.key].label === SEC[id][0]));
          const sub = id === 'ai' ? a.sub || undefined : undefined;
          const shown = pool.filter((i) => !sub || i.category === sub);
          const [c0, ...rest] = shown;
          const outlets = new Set(shown.map((i) => i.source)).size;
          const subChips = id === 'ai' ? Object.entries(AI).map(([cid, x]) => ({ id: cid, label: x[0], icon: x[1], light: x[2], dark: x[3], count: pool.filter((i) => i.category === cid).length })).filter((c) => c.count) : [];
          return { ...issue(SEC[id][0], true), sectionPage: id, focus: undefined, sub, chips: [], subChips, chipsGo: false, today: undefined, brief: id === 'economy' ? brief : undefined,
            kicker: '오늘 호의 분야 지면 · 10월 13일 월요일', count: pool.length + 3,
            head: `${SEC[id][0]} 소식 ${pool.length + 3}건 중 ${shown.length}건 실음 · 출처 ${outlets}곳`,
            cover: c0 ? { item: c0, cluster: null, size: 1 } : undefined,
            empty: c0 ? undefined : { preparing: false, title: `이번 호에는 아직 ${SEC[id][0]} 소식이 없습니다`, sub: '새 소식이 들어오는 대로 지면이 채워집니다.' },
            sections: rest.length ? [{ ...section(id, SEC[id][0], SEC[id][1], S(id), rest, false), glass: undefined }] : [] };
        }
        return issue(a.source === 'today' ? '10월 13일 월요일 호' : '10월 12일 일요일 호', a.source === 'today', a.focus || undefined, a.focus === 'ai' ? a.sub || undefined : undefined);
      case 'stories':
        return {
          live: [
            { id: 's1', title: '한국은행 기준금리 동결', size: 7, fresh: 2, following, photo: pic('#0f766e', '#1e3a8a'), topic: topicOf('economy'),
              sources: [src('연합뉴스', '연', '#0F62FE'), src('Reuters', 'R', '#FF8000'), src('한국경제', '한', '#0B3B8C'), src('Bloomberg', 'B', '#000000')], times: '첫 보도 3시간 전 · 최근 12분 전' },
            { id: 's2', title: '국회 예산안 처리 시한 넘겨', size: 3, fresh: 0, following: false, topic: topicOf('politics'),
              sources: [src('KBS', 'K', '#1C3F94'), src('한겨레', '한', '#00A1E9')], times: '첫 보도 5시간 전 · 최근 1시간 전' },
          ],
          past: [
            { id: 's3', title: 'OpenAI 새 모델 공개', size: 5, fresh: 0, following: true, photo: pic('#7c3aed', '#db2777'), topic: topicOf('ai', 'model'),
              sources: [src('The Verge', 'T', '#E1306C'), src('TechCrunch', 'T', '#0A9E01'), src('AI타임스', 'A', '#0F62FE')], times: '첫 보도 3일 전 · 최근 2일 전' },
          ],
        };
      case 'story':
        return { id: a.id, title: '한국은행 기준금리 동결', sub: '3곳 보도 · 3시간에 걸친 보도', following,
          items: [
            { item: cover, when: '오전 9:02', first: true, lede: '한국은행 금융통화위원회는 13일 기준금리를 연 2.75%로 동결했다. 물가 상승률은 안정됐지만 환율 변동성이 크다는 판단이다.' },
            { item: top[0], when: '오전 10:40', first: false, gap: '2시간 뒤', lede: 'The Fed chair said policymakers would not rush to cut rates as inflation remains above target.' },
            { item: economy[0], when: '오후 12:15', first: false, gap: '2시간 뒤' },
          ],
          intl: { title: '해외에서는', icon: 'globe', count: 1, items: [top[0]] },
          kr: { title: '국내에서는', icon: 'house', count: 2, items: [cover, economy[0]] } };
      case 'follow': following = !!a.on; return { following };
      case 'canDigest': return true;
      case 'digest': return new Promise((r) => setTimeout(() => r(['한국은행이 기준금리를 연 2.75%로 묶었다.', '물가는 안정됐지만 환율 변동성을 더 지켜보겠다는 판단이다.', '시장은 연내 한 차례 인하를 내다본다.']), 1200));
      case 'reduce': return { hide: '이 출처 숨기기 — ' + (a.key || '').split('|')[0], less: '경제 덜 받기 — 묶음으로', words: ['한국은행', '기준금리', '동결', '물가', '환율'] };
      case 'saved': return { items: [economy[0], ai[0], cover], archived: [economy[0].key], topics, count: 3 };
      case 'clearRecentSearches': mockRecent = []; return { q: '', items: [], watch: ['한국은행', '엔비디아'], recent: [] };
      case 'search': {
        if (a.submit && a.q && a.q.length >= 2) mockRecent = [a.q, ...mockRecent.filter((x) => x !== a.q)].slice(0, 8);
        if (!a.q) return { q: '', items: [], watch: ['한국은행', '엔비디아'], recent: mockRecent };
        if (a.q.length < 2 && !a.submit) return { q: a.q };
        if (a.archive != null) mockArchive = a.archive;
        const items = [cover, ...top, ...economy, ...ai].filter((i) => i.title.includes(a.q) || i.source.includes(a.q));
        const older = mockArchive ? archRows(a.q, 0, 200) : [];
        return { q: a.q, items, topics, archive: mockArchive, older, olderMore: older.length >= 200, olderNext: older.length,
          found: older.length ? `최근 ${items.length}건 · 오래된 기사 ${older.length}${older.length >= 200 ? '건 넘음' : '건'}` : `${items.length}건` };
      }
      case 'searchMore': { const older = archRows(a.q, a.offset, 200); return { older, olderMore: older.length >= 200, olderNext: a.offset + older.length, found: `최근 ${a.recent}건 · 오래된 기사 ${a.shown + older.length}건` }; }
      // 보관함: 미리 보기에서는 기간과 관계없이 같은 가짜 기사
      case 'archive': {
        const period = a.period || 'month';
        const all = archRows('', 0, 260).filter((r) => (!a.section || r.section === a.section) && (!a.source || r.source === a.source));
        const items = all.slice(0, a.limit || 100);
        const days = period === 'year' ? 365 : period === 'month' ? 31 : 0;
        const bars = days ? Array.from({ length: days }, (_, i) => ({ key: `2026-10-${String(i % 31 + 1).padStart(2, '0')}`, label: `10월 ${i % 31 + 1}일`, count: (i * 37) % 23 })) : null;
        return { period, periods: [['day', '일'], ['week', '주'], ['month', '월'], ['year', '연']].map(([id, label]) => ({ id, label })), anchor: a.anchor || '2026-10-01',
          title: { day: '2026년 10월 12일(일)', week: '2026년 10월 11일 – 10월 17일', month: '2026년 10월', year: '2026년' }[period],
          head: `기사 ${all.length}건` + (all.length > items.length ? ` · 최신순 ${items.length}건 보는 중` : ''), canPrev: true, canNext: false, atToday: !a.anchor,
          items, more: all.length > items.length, total: all.length, limit: a.limit || 100, bars, peak: 22, barFrom: '2026. 10. 01', barTo: '2026. 10. 31',
          section: a.section || null, sectionLabel: a.section ? SEC[a.section][0] : '모든 분야', source: a.source || null, sourceLabel: a.source || '모든 출처',
          sections: [['economy', 140], ['ai', 120]].map(([id, count]) => ({ id, label: SEC[id][0], count })),
          sources: [['연합뉴스', 130], ['The Verge', 130]].map(([id, count]) => ({ id, label: id, count })),
          dayIssue: period === 'day' ? { id: 'daily-2026-10-12', title: '10월 12일 일요일 호' } : null,
          empty: items.length ? null : '거른 조건에 맞는 기사가 없습니다.' };
      }
      case 'archiveShift': return a.anchor || '2026-10-01';
      case 'scrapbook': {
        const f = folders.some((x) => x.name === a.folder) ? a.folder : '스크랩';
        // 이번 주 모은 문장(M-27): 미리 보기에서는 #weekly 이면 보임(앱은 일요일 17시부터)
        const weekly = /weekly/.test(location.hash) ? { count: '2개 · 지난 7일', items: [
          { key: cover.key, quote: '한국은행은 물가와 환율 흐름을 더 지켜보겠다고 밝혔다.', source: cover.source, title: cover.title, color: cover.color },
          { key: ai[1].key, quote: '작은 모델이 큰 모델의 추론 과정을 따라 하도록 가르치면, 적은 계산으로도 비슷한 성능을 낼 수 있다는 결과가 나왔다.', source: ai[1].source, title: ai[1].title, color: ai[1].color },
        ] } : undefined;
        return { folder: f, folders, total: 2, groups: f === '스크랩' ? [{ item: cover, scraps }, { item: economy[1], scraps: [scraps[1]] }] : [], weekly };
      }
      case 'newFolder': folders = [...folders, { name: a.name.trim(), count: 0 }]; return { ok: true, folder: a.name.trim() };
      case 'renameFolder': folders = folders.map((f) => (f.name === a.from ? { ...f, name: a.to.trim() } : f)); return { ok: true, folder: a.to.trim() };
      case 'marks': return { read: [...read], saved: [] };
      // 주소로 추가(I-05): 미리 보기에서는 http(s) 처럼 보이면 저장한 것으로
      case 'addUrl': return new Promise((r) => setTimeout(() => r(/^(https?:\/\/)?[^\s/]+\.[^\s]+$/.test((a.url || '').trim()) && !/localhost|127\.0|192\.168/.test(a.url)
        ? { ok: true, message: '저장함 · ' + a.url.trim().replace(/^https?:\/\//, '') } : { ok: false, message: (a.url || '').includes('192.168') ? '내부망·특수 주소는 저장하지 않습니다' : 'http(s) 기사 주소가 아닙니다' }), 700));
      case 'open': read.add(a.key); console.log('open', a.key, 'seq', (a.seq || []).length); setTimeout(() => window.bridge.emit('changed', { revision: 3, imageRevision: 1, layoutRevision: 0 }), 50); return null;
      case 'toggleRead': read.has(a.key) ? read.delete(a.key) : read.add(a.key); setTimeout(() => window.bridge.emit('changed', { revision: 3, imageRevision: 1, layoutRevision: 0 }), 50); return null;
      case 'todayProgress': return today(a.keys);
      case 'flip': {
        const order = ['today', 'week', 'section:top', 'section:economy', 'section:ai', 'section:sports', 'stories', 'saved', 'scrapbook', 'search',
          'issue:daily-2026-10-12', 'issue:daily-2026-10-11', 'issue:weekly-2026-W40'];
        const i = order.indexOf(a.page.startsWith('story:') ? 'stories' : a.page);
        const to = order[i + (a.back ? -1 : 1)];
        if (i < 0 || !to) { console.log('beep'); return null; }
        return to;
      }
      default: return null;
    }
  };
  // 미리 보기에서 분야 사진이 늦게 찾아지는 모양: 4초 뒤 스포츠 사진
  setTimeout(() => { PHOTOS.sports = pic('#14532d', '#a3e635'); window.bridge.emit('photos', { ...PHOTOS }); }, 4000);
  // 미리 보기에서 새 소식 띠 확인: 3초 뒤 새 판(#done 이면 오늘 호를 다 읽어 띠가 뜨지 않음)
  setTimeout(() => window.bridge.emit('changed', { revision: 4, imageRevision: 1, layoutRevision: 0, preparing: false }), 3000);
}
