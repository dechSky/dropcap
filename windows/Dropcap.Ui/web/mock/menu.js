// 미리 보기 전용(WebView2 밖에서만): 맥·브라우저에서 menu.html 을 열어 모양을 확인
if (!(window.chrome && window.chrome.webview)) {
  const now = Date.now();
  const H = 3600e3;
  // 사진은 data: 주소(미리 보기에서 바깥에 나가지 않게) — 분야 색 띠 그림
  const pic = (a, b) => 'data:image/svg+xml,' + encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" width="320" height="180"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="${a}"/><stop offset="1" stop-color="${b}"/></linearGradient></defs><rect width="320" height="180" fill="url(#g)"/><circle cx="240" cy="60" r="44" fill="rgba(255,255,255,.25)"/></svg>`);
  const img0 = window.bridge.img;
  window.bridge.img = (u) => (u && u.startsWith('data:image/svg') ? u : img0(u)); // 미리 보기의 가짜 사진만 그대로
  // 분야(Sections.Builtin 과 같은 색·아이콘) · AI 하위 분류(ai-topics.json)
  const SEC = {
    top: ['주요 뉴스', 'star.fill', '#FF9F0A'], economy: ['경제', 'cat.business', '#30C759'], ai: ['AI', 'sparkles', '#BF5AF2'],
    world: ['국제', 'globe', '#0A84FF'], sports: ['스포츠', 'sport', '#34C759'], politics: ['정치', 'cat.policy', '#5E5CE6'],
  };
  const TOP = [['model', '모델·제품', 'cat.model', '#007AFF', '#0A84FF'], ['research', '연구', 'cat.research', '#AF52DE', '#BF5AF2'],
    ['policy', '정책·규제', 'cat.policy', '#5856D6', '#5E5CE6'], ['business', '투자·기업', 'cat.business', '#34C759', '#30D158'], ['security', '보안', 'cat.security', '#FF3B30', '#FF453A']];
  const chosen = ['top', 'economy', 'ai', 'world', 'sports'];
  const mode = { top: 'instant', economy: 'instant', ai: 'bundle', world: 'bundle', sports: 'bundle' };
  const hidden = new Set();
  const muted = [];
  const topic = (sec, sub) => {
    if (sec === 'ai') { const t = TOP.find((x) => x[0] === sub); return { topicLabel: 'AI·' + t[1], topicIcon: t[2], topicLight: t[3], topicDark: t[4] }; }
    const [label, icon, c] = SEC[sec];
    return { topicLabel: label, topicIcon: icon, topicLight: c, topicDark: c };
  };
  const items = [
    { key: 'yna|1', title: '한은, 기준금리 연 2.50% 동결…"물가 경로 더 지켜봐야"', source: '연합뉴스 경제', sourceId: 'yna-economy', initial: '연', color: '#0F62FE', sec: 'economy', chips: ['economy', 'top'], related: 4, time: '5분 전', date: now - 5 * 60e3, important: true, read: false, saved: false, thumb: pic('#0f766e', '#1e3a8a') },
    { key: 'openai|2', title: 'OpenAI, 추론 기능 강화한 GPT-6 공개', source: 'OpenAI', sourceId: 'openai', initial: 'O', color: '#10A37F', sec: 'ai', sub: 'model', chips: ['ai'], related: 2, time: '32분 전', date: now - 32 * 60e3, read: false, saved: true, thumb: pic('#4c1d95', '#be185d') },
    { key: 'bbc|3', title: '유엔 안보리, 가자 휴전 결의안 표결 연기', source: 'BBC World', sourceId: 'bbc-world', initial: 'B', color: '#BB1919', sec: 'world', chips: ['world'], related: 0, time: '2시간 전', date: now - 2 * H, read: true, saved: false },
    { key: 'kr|4', title: '정부, AI 기본법 시행령 발표…고위험 AI 범위 확정', source: 'AI타임스', sourceId: 'aitimes', initial: 'A', color: '#0057B8', sec: 'ai', sub: 'policy', chips: ['ai', 'politics'], related: 1, time: '5시간 전', date: now - 5 * H, read: true, saved: false, thumb: pic('#334155', '#0ea5e9') },
    { key: 'sport|5', title: '손흥민 시즌 7호골…토트넘 3연승', source: '연합뉴스 스포츠', sourceId: 'yna-sports', initial: '연', color: '#0F62FE', sec: 'sports', chips: ['sports'], related: 0, time: '1일 전', date: now - 26 * H, read: false, saved: false },
    { key: 'cnbc|6', title: '코스피 2,900 회복…외국인 사흘째 순매수', source: 'CNBC', sourceId: 'cnbc', initial: 'C', color: '#005594', sec: 'economy', chips: ['economy'], related: 0, time: '3일 전', date: now - 72 * H, read: true, saved: false },
    { key: 'arxiv|7', title: '작은 모델로 긴 문맥을 다루는 새 주의 방식', source: 'arXiv', sourceId: 'arxiv', initial: 'a', color: '#B31B1B', sec: 'ai', sub: 'research', chips: ['ai'], related: 0, time: '3일 전', date: now - 75 * H, read: false, saved: false },
  ].map((i) => ({ ...i, ...topic(i.sec, i.sub) }));
  const words = (t) => [...new Set(t.split(/[^\p{L}\p{N}-]+/u).filter((w) => w.length >= 2 && !/^\d+$/.test(w)))].slice(0, 12);
  const chipOf = (id) => ({ id, label: SEC[id][0], icon: SEC[id][1], light: SEC[id][2], dark: SEC[id][2] });
  // 시간 묶음(MenuPage.TimeSection 과 같은 규칙)
  const bucket = (d) => {
    if (!d) return '이전';
    if (now - d < H) return '방금';
    const day = new Date(d).toDateString(), t = new Date(now);
    if (day === t.toDateString()) return '오늘';
    t.setDate(t.getDate() - 1);
    return day === t.toDateString() ? '어제' : '이전';
  };
  window.DropcapMock = (cmd, a) => {
    const find = () => items.find((i) => i.key === a.key);
    if (cmd === 'reduceInfo') {
      const it = find(), sec = it.chips.find((c) => chosen.includes(c)) || it.sec, m = mode[sec] || 'bundle';
      const can = chosen.includes(sec) && m !== 'magazine';
      return { source: it.source, section: sec, sectionName: SEC[sec][0], mode: m, canLess: can, next: can ? (m === 'instant' ? 'bundle' : 'magazine') : null,
        lessLabel: can ? `${SEC[sec][0]} 덜 받기 — ${m === 'instant' ? '묶음으로' : '매거진에만'}` : null, hideLabel: `이 출처 숨기기 — ${it.source}`, words: words(it.title) };
    }
    if (cmd === 'hideSource') { hidden.add(find().sourceId); return null; }
    if (cmd === 'lessOf') { const it = find(), sec = it.chips.find((c) => chosen.includes(c)) || it.sec; mode[sec] = mode[sec] === 'instant' ? 'bundle' : 'magazine'; return null; }
    if (cmd === 'muteWord') { muted.push(a.word); return null; }
    if (cmd !== 'ready' && cmd !== 'view') return null;
    const sort = a.sort || 'newest';
    const section = chosen.includes(a.section) ? a.section : null;
    const sub = section === 'ai' && a.topic ? a.topic : null;
    let list = items.filter((i) => !hidden.has(i.sourceId));
    list = a.tab === 'unread' ? list.filter((i) => !i.read) : a.tab === 'saved' ? list.filter((i) => i.saved) : list;
    if (section) list = list.filter((i) => (section === 'top' ? i.related > 0 || i.important : i.chips.includes(section)));
    if (sub) list = list.filter((i) => i.sub === sub);
    if (a.query) list = list.filter((i) => (i.title + i.source).toLowerCase().includes(a.query.toLowerCase()));
    if (sort === 'source') list.sort((x, y) => x.source.localeCompare(y.source) || y.date - x.date);
    else if (sort === 'important') list.sort((x, y) => (y.important ? 100 : 0) + y.related * 12 - ((x.important ? 100 : 0) + x.related * 12) || y.date - x.date);
    else list.sort((x, y) => y.date - x.date);
    const count = (s) => list.filter((i) => i.source === s).length;
    const rows = list.map((it, i) => {
      const prev = list[i - 1];
      const head = sort === 'source' && (!prev || prev.source !== it.source);
      const sec = sort !== 'source' && i > 0 && bucket(it.date) !== bucket(prev.date) ? bucket(it.date) : null;
      return { item: it, thumb: it.thumb || null, hero: i === 0, section: sec, sectionFirst: i === 1,
        sourceHead: head ? it.source : null, sourceCount: head ? count(it.source) : 0, sourceFirst: i === 0,
        topicLabel: it.topicLabel, topicIcon: it.topicIcon, topicLight: it.topicLight, topicDark: it.topicDark };
    });
    return {
      header: { title: 'Dropcap', checking: false, status: '마지막 확인 오후 3:05', quiet: true, snoozed: false, snoozeHelp: '알림 잠시 끄기' },
      unread: items.filter((i) => !i.read).length, sort, sortLabel: sort === 'important' ? '중요순' : sort === 'source' ? '출처별' : null, rows,
      empty: { icon: a.tab === 'saved' ? 'bookmark' : 'newspaper', title: a.query || section ? '맞는 소식이 없습니다' : '저장한 소식이 없습니다', sub: '새 글이 올라오면 물방울이 떨어지듯 알려 드려요' },
      section, topic: sub, chips: chosen.map(chipOf),
      topics: section === 'ai' ? TOP.map(([id, label, icon, light, dark]) => ({ id, label, icon, light, dark })) : [],
      hotkey: 'Ctrl+Alt+M',
    };
  };
}
