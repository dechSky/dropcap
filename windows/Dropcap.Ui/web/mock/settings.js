// 미리 보기 전용(WebView2 밖에서만): 맥·브라우저에서 settings.html 을 열어 모양을 확인
if (!(window.chrome && window.chrome.webview)) {
  const st = { style: 'drop', position: 'center', sound: true, interval: 5, pretendard: true, launchAtLogin: false, autoQuietFullscreen: true, autoQuietSharing: true,
    watch: '엔비디아', must: 'GPT-6, Claude', mute: '', quietEnabled: false, quietStart: 23, quietEnd: 7, digestEnabled: true, digestHour: 9 };
  const enabled = { openai: true, anthropic: true, deepmind: true, nvidia: true, verge: true, aitimes: true, 'custom-1': true, 'custom-2': false };
  const notify = { 'custom-2': false };
  const subscribed = new Set(['cat-yt-2mp']);
  // 분야 탭(G-13)
  const secs = [
    ['top', '주요 뉴스', 'star.fill', '#FF9F0A', true, 0, 0], ['economy', '경제', 'cat.business', '#30C759', false, 4, 6],
    ['world', '국제', 'globe', '#0A84FF', false, 3, 5], ['ai', 'AI', 'sparkles', '#BF5AF2', false, 7, 9],
    ['culture', '문화·연예', 'masks', '#FFD60A', false, 0, 0],
  ];
  const policy = { top: { mode: 'instant', bundleHour: 18, dailyCap: 3 }, economy: { mode: 'instant', bundleHour: 18, dailyCap: 3 },
    world: { mode: 'bundle', bundleHour: 18, dailyCap: 3 }, ai: { mode: 'bundle', bundleHour: 21, dailyCap: 3 }, culture: { mode: 'magazine', bundleHour: 18, dailyCap: 3 } };
  Object.assign(st, { totalDailyCap: 10, krThreshold: 3, intlThreshold: 2, bigThreshold: 8 });
  let hidden = [['yna', '연합뉴스'], ['custom-2', 'r/LocalLLaMA']];
  const modes = [['instant', '즉시', '중요한 소식(여러 곳 보도·공식 발표·꼭 알림 낱말·팔로우한 스토리)만 바로 물방울로'],
    ['bundle', '묶음', '정한 시각에 한 방울로 모아서(예: 경제 7건)'], ['magazine', '매거진만', '알리지 않고 매거진에만']];
  const limitLabel = { totalDailyCap: (n) => `하루 전체 물방울 ${n}번까지`, krThreshold: (n) => `국내 ${n}곳 이상 보도면 중요`,
    intlThreshold: (n) => `해외 ${n}곳 이상 보도면 중요`, bigThreshold: (n) => `국내 ${n}곳 이상이면 상한을 넘어도 알림` };
  const sections = () => ({
    summary: `고른 분야 ${secs.filter((x) => x[0] !== 'top').length}개`,
    rows: secs.map(([id, name, icon, color, flow, on, all]) => {
      const p = policy[id];
      return { id, name, icon, color, sourcesOn: on, sourcesAll: all, mode: p.mode, modeHelp: modes.find((m) => m[0] === p.mode)[2],
        sub: flow ? '어느 분야든 크게 다룬 소식' : all > 0 ? `출처 ${on}/${all}곳 켜짐` : '구독 탭에서 출처를 켜고 끕니다',
        bundleHour: p.bundleHour, dailyCap: p.dailyCap, capLabel: `하루 ${p.dailyCap}번까지`,
        bundleHelp: p.mode === 'instant' ? '하루 상한을 넘어 고인 소식을 보내는 시각' : '모아 둔 소식을 한 방울로 보내는 시각' };
    }),
    modes: modes.map(([id, label, help]) => ({ id, label, help })),
    bundleHours: Array.from({ length: 18 }, (_, i) => ({ value: i + 6, label: `${String(i + 6).padStart(2, '0')}:00` })),
    capMin: 1, capMax: 10,
    limits: [['totalDailyCap', 1, 30], ['krThreshold', 1, 10], ['intlThreshold', 1, 10], ['bigThreshold', 2, 20]]
      .map(([key, min, max]) => ({ key, label: limitLabel[key](st[key]), value: st[key], min, max })),
    hidden: hidden.map(([id, name]) => ({ id, name })),
  });
  const row = (id, name, tier, color, extra = {}) => ({ id, name, tier, initial: name.replace('The ', '')[0].toUpperCase(), color, kind: 'article', kindLabel: null, aiOnly: false, error: null, sub: null, removable: false, ...extra });
  const custom = [
    row('custom-1', 'Simon Willison', 'press', '#6E56CF', { sub: 'https://simonwillison.net/atom/everything/', removable: true }),
    row('custom-2', 'r/LocalLLaMA', 'press', '#0090FF', { kind: 'post', kindLabel: '커뮤니티', sub: 'https://www.reddit.com/r/LocalLLaMA/', removable: true, error: '확인 실패: 429 Too Many Requests' }),
  ];
  // 기본 출처(분야·지역·유료 표시는 설정 › 구독 정리 미리 보기용)
  const src = (id, name, tier, color, section, region, extra = {}) => row(id, name, tier, color, { section, region, ...extra });
  const base = [
    src('openai', 'OpenAI', 'lab', '#10A37F', 'ai', 'intl'), src('anthropic', 'Anthropic', 'lab', '#D97757', 'ai', 'intl'),
    src('deepmind', 'Google DeepMind', 'lab', '#4285F4', 'ai', 'intl'), src('nvidia', 'NVIDIA', 'lab', '#76B900', 'ai', 'intl', { aiOnly: true }),
    src('verge', 'The Verge', 'press', '#5200FF', 'tech', 'intl', { paywall: 'metered' }), src('wired', 'WIRED', 'press', '#3A3A3C', 'tech', 'intl', { paywall: 'metered' }),
    src('nyt-home', 'The New York Times', 'press', '#000000', 'top', 'intl', { paywall: 'hard' }), src('nyt-politics', 'NYT Politics', 'press', '#000000', 'politics', 'intl', { paywall: 'hard' }),
    src('bbc-world', 'BBC World', 'press', '#BB1919', 'world', 'intl'), src('bbc-business', 'BBC Business', 'press', '#BB1919', 'economy', 'intl'),
    src('aitimes', 'AI타임스', 'kr', '#0057B8', 'ai', 'kr', { aiOnly: true }),
    src('yna-latest', '연합뉴스 최신', 'kr', '#0068B7', 'top', 'kr'), src('yna-politics', '연합뉴스 정치', 'kr', '#0068B7', 'politics', 'kr'),
    src('yna-economy', '연합뉴스 경제', 'kr', '#0068B7', 'economy', 'kr'), src('yna-world', '연합뉴스 국제', 'kr', '#0068B7', 'world', 'kr'),
    src('yna-sports', '연합뉴스 스포츠', 'kr', '#0068B7', 'sports', 'kr'), src('hani', '한겨레', 'kr', '#1F6F43', 'society', 'kr'),
  ];
  Object.assign(enabled, { 'yna-politics': true, 'yna-economy': true, 'bbc-world': true });
  custom.forEach((c) => Object.assign(c, { section: 'ai', region: 'intl' }));
  // 설정 › 구독 정리(Core/SourceDirectory.cs 규칙을 줄여 옮김)
  const secOrder = [['top', '주요'], ['politics', '정치'], ['economy', '경제'], ['society', '사회'], ['world', '국제'], ['tech', 'IT'], ['ai', 'AI'],
    ['science', '과학'], ['life', '생활'], ['culture', '문화'], ['sports', '스포츠'], ['climate', '기후']];
  const secName = (id) => (secOrder.find((x) => x[0] === id) || [id, id])[1];
  const regionLabel = (r) => r.region === 'kr' ? '국내' : '해외';
  const fold = (t) => String(t || '').toLowerCase().replace(/\s+/g, '');
  const matches = (r, q) => !fold(q) || [r.name, r.sub, secName(r.section), regionLabel(r)].some((h) => fold(h).includes(fold(q)));
  const sortKey = (name, kr) => (kr ? '0' : '1') + name.toLowerCase();
  const sorted = (list) => [...list].sort((a, b) => sortKey(a.name, a.region === 'kr') < sortKey(b.name, b.region === 'kr') ? -1 : 1);
  const mediaName = (m) => {
    const names = m.map((x) => x.name);
    if (new Set(names).size === 1) return names[0];
    const heads = names.map((n) => n.split(' ')[0]);
    if (heads[0] && heads.every((h) => h === heads[0])) return heads[0];
    const rep = m.find((x) => x.id === x.id.split('-')[0] || x.id === x.id.split('-')[0] + '-home');
    return rep ? rep.name : [...names].sort((a, b) => a.length - b.length || (a < b ? -1 : 1))[0];
  };
  const dir = { query: '', status: 'all', layout: 'media' };
  const paywallHelp = { hard: '구독해야 읽을 수 있음', metered: '한 달 몇 건 무료' };
  const directory = (live) => {
    const on = (id) => !!enabled[id];
    const pass = (r) => (dir.status === 'all' || (dir.status === 'on') === on(r.id)) && matches(r, dir.query);
    const decorate = (r, media) => ({ ...live(r), shortName: media && r.name.startsWith(media + ' ') ? r.name.slice(media.length + 1) : r.name,
      sectionName: secName(r.section), region: regionLabel(r), paywall: r.paywall || null, paywallHelp: paywallHelp[r.paywall] || null });
    const shown = base.filter(pass);
    const mine = sorted(custom.filter(pass));
    const searching = !!fold(dir.query);
    const buckets = [];
    const add = (id, title, members) => {
      const list = sorted(members.filter((m) => shown.includes(m)));
      if (list.length) buckets.push({ id, title, members, list });
    };
    if (dir.layout === 'media') {
      const keys = [...new Set(base.map((r) => r.id.split('-')[0]))];
      keys.forEach((k) => { const m = base.filter((r) => r.id.split('-')[0] === k); add('media:' + k, mediaName(m), m); });
      buckets.sort((a, b) => sortKey(a.title, a.list[0].region === 'kr') < sortKey(b.title, b.list[0].region === 'kr') ? -1 : 1);
    } else if (dir.layout === 'section') {
      secOrder.forEach(([id, name]) => add('section:' + id, name, base.filter((r) => r.section === id)));
    } else {
      add('region:kr', '국내', base.filter((r) => r.region === 'kr'));
      add('region:intl', '해외', base.filter((r) => r.region !== 'kr'));
    }
    const onAll = [...base, ...custom].filter((r) => on(r.id));
    const bySec = secOrder.map(([id, name]) => [name, onAll.filter((r) => r.section === id).length]).filter((x) => x[1]);
    const total = base.length + custom.length;
    const count = shown.length + mine.length;
    const recCount = cat.filter((c) => !fold(dir.query) || fold(c[2]).includes(fold(dir.query))).length;
    return {
      query: dir.query, searching, layout: dir.layout, status: dir.status,
      layouts: [['media', '매체별'], ['section', '분야별'], ['region', '지역별']].map(([id, label]) => ({ id, label })),
      statuses: [['all', '전체'], ['on', '켠 것'], ['off', '끈 것']].map(([id, label]) => ({ id, label })),
      summary: onAll.length ? `켠 출처 ${onAll.length}곳 · ` + bySec.map(([n, c]) => `${n} ${c}`).join(' · ') : '켠 출처 없음',
      count: count === total ? `${total}곳` : `${total}곳 중 ${count}곳`,
      empty: !shown.length && !mine.length && !recCount,
      emptyText: "찾는 출처가 없습니다. 이름·주소를 다시 확인하거나 위 '채널 추가'에 주소를 넣어 보세요.",
      mine: { show: mine.length > 0 || (!searching && dir.status === 'all'), label: `내 채널 ${custom.length}`, rows: mine.map((r) => decorate(r)) },
      groups: buckets.map((b) => {
        const allOn = b.list.every((r) => on(r.id));
        const n = b.members.filter((r) => on(r.id)).length;
        const media = dir.layout === 'media' ? b.title : null;
        return { id: b.id, title: b.title, on: n, total: b.members.length, countLabel: `${n}/${b.members.length} 켬`,
          single: dir.layout === 'media' && b.members.length === 1, allOn, bulk: allOn ? '모두 끄기' : '모두 켜기',
          bulkHelp: b.list.length < b.members.length ? `보이는 ${b.list.length}곳에만` : `이 묶음 ${b.members.length}곳 모두`,
          ids: b.list.map((r) => r.id), initial: b.title.replace('The ', '')[0].toUpperCase(), color: b.list[0].color,
          rows: b.list.map((r) => decorate(r, media)) };
      }),
      recommended: (() => {
        const hit = cat.filter((c) => !fold(dir.query) || fold(c[2]).includes(fold(dir.query)));
        return { label: `추천 채널 ${hit.length}`, count: hit.length,
          groups: [...new Set(hit.map((c) => c[0]))].map((g) => ({ label: g, rows: hit.filter((c) => c[0] === g).map(catRow) })) };
      })(),
    };
  };
  const cat = [
    ['YouTube', 'cat-yt-openai', 'OpenAI (YouTube)', '#FF0033', 'video', '영상', true],
    ['YouTube', 'cat-yt-2mp', 'Two Minute Papers', '#FF0033', 'video', '영상', true],
    ['뉴스레터·블로그', 'cat-importai', 'Import AI', '#3D5AFE', 'article', null, true],
    ['논문', 'cat-arxiv-ai', 'arXiv cs.AI', '#B31B1B', 'paper', '논문', false],
    ['오픈소스 릴리스', 'cat-gh-ollama-ollama', 'Ollama', '#6E7681', 'release', '릴리스', true],
  ];
  const catRow = ([, id, name, color, kind, kindLabel, n]) => ({ id, name, initial: name[0], color, kind, kindLabel,
    sub: n ? '새 글이 오면 알림' : '글이 많아 알림 없이 매거진에만 실림', subscribed: subscribed.has(id), subscribing: false });
  const view = () => {
    const live = (r) => ({ ...r, enabled: !!enabled[r.id], notify: notify[r.id] ?? true,
      notifyHelp: (notify[r.id] ?? true) ? '새 글 알림 켜짐 (끄면 매거진에만 실림)' : '알림 꺼짐 — 매거진에만 실림' });
    return {
      general: {
        style: st.style, styles: [{ id: 'drop', label: '물방울 (앱이 직접 그림)' }, { id: 'system', label: '시스템 알림 센터' }],
        position: st.position, positions: [{ id: 'center', label: '위쪽 가운데' }, { id: 'right', label: '오른쪽 위' }],
        sound: st.sound, interval: st.interval, intervals: [2, 5, 10, 15, 30].map((m) => ({ value: m, label: `${m}분` })),
        translateEngine: st.translateEngine || 'auto', translateEngines: [{ id: 'auto', label: '자동 (Google 번역)' }, { id: 'google', label: 'Google 번역' }, { id: 'off', label: '번역 안 함' }],
        translationNote: '번역을 켜 두면 Google 번역으로 본문 문단이 전송됩니다(외국어 기사 제목·같은 소식 묶기용 영어 번역 포함). 윈도우에는 무료로 쓸 수 있는 기기 내 번역이 없습니다. \'번역 안 함\'이면 아무것도 보내지 않고 원문을 보여 줍니다.',
        pretendard: st.pretendard, summary: 'Ollama 가 없어 요약 칸을 숨깁니다', summaryOn: false, launchAtLogin: st.launchAtLogin,
        autoQuietFullscreen: st.autoQuietFullscreen, autoQuietSharing: st.autoQuietSharing, autoQuietCalendar: false, calendarSupported: false,
        autoQuietNote: "이때 온 소식은 물방울 없이 '안 읽음'에 쌓이고, 알릴 만한 소식은 그 분야 묶음으로 모입니다.",
        backup: { intro: '계정도 서버도 없습니다. 모든 기록은 이 PC 안에만 있습니다.', note: '다른 PC·Mac 으로 옮길 때: … JSON 파일 하나로 내보내고, 다른 기기에서 가져오면 없는 것만 더합니다.', canUndo: !!st.imported, message: st.backupMsg || null },
        calendarNote: '윈도우 판은 설치 없이 푸는 앱이라 윈도우 캘린더(일정) 권한을 받을 수 없어 쓸 수 없습니다.',
      },
      sections: sections(),
      sources: {
        custom: custom.map(live),
        tiers: [['lab', '공식 발표'], ['press', '언론'], ['kr', '국내']].map(([t, l]) => ({ label: `기본 출처 · ${l}`, rows: base.filter((r) => r.tier === t).map(live) })),
        catalog: [...new Set(cat.map((c) => c[0]))].map((g) => ({ label: `추천 · ${g}`, rows: cat.filter((c) => c[0] === g).map(catRow) })),
        directory: directory(live),
      },
      // 스크랩북 탭(I-05·I-06): 폴더는 미리 보기용 가상 경로
      scrapbook: {
        enabled: !!st.scrapExport && !!st.scrapFolder, folder: st.scrapFolder || '고르지 않음', hasFolder: !!st.scrapFolder, choose: st.scrapFolder ? '바꾸기…' : '고르기…',
        error: null, canSaveNow: !!st.scrapExport && !!st.scrapFolder,
        exportNote: '스크랩 폴더마다 ‘폴더 이름.md’ 파일 하나 — Obsidian 보관소 안의 폴더를 고르면 노트로 바로 보입니다. 파일은 덮어쓰니 고쳐 쓸 노트는 다른 이름으로 두세요.',
        addUrl: '‘저장’ 목록 위 ‘주소로 추가…’ 칸에 붙여 넣기',
        bookmarkletNote: '새 북마크를 만들고 주소 칸에 복사한 코드를 붙여 넣으세요. 기사를 보다 그 북마크를 누르면 Dropcap 의 나중에 읽기에 담깁니다. 다른 프로그램에서는 dropcap://save?url=<주소> 를 열거나 Dropcap.exe --save <주소> 로 부르면 됩니다.',
      },
      filters: {
        must: st.must, mute: st.mute, watch: st.watch, quietEnabled: st.quietEnabled, quietStart: st.quietStart, quietEnd: st.quietEnd,
        hours: Array.from({ length: 24 }, (_, h) => ({ value: h, label: `${String(h).padStart(2, '0')}:00` })),
        digestEnabled: st.digestEnabled, digestHour: st.digestHour,
        digestHours: [5, 6, 7, 8, 9, 10, 11, 12].map((h) => ({ value: h, label: h === 12 ? '낮 12시' : `오전 ${h}시` })),
        hotkeys: [{ label: '가장 최근 안 읽은 소식 열기', keys: 'Ctrl+Alt+N' }, { label: '매거진 열기', keys: 'Ctrl+Alt+M' }],
        navKeys: [{ keys: '↓ / J · ↑ / K', label: '다음·이전 소식 고르기 (트레이 창 목록·매거진 카드)' }, { keys: 'Enter', label: '고른 소식 열기' },
          { keys: 'Ctrl+[ · Ctrl+]', label: '매거진 이전·다음 지면' }, { keys: 'Esc (읽기 창)', label: '창 닫기' }],
      },
    };
  };
  const split = (s) => s.split(/[,\n]/).map((w) => w.trim()).filter(Boolean).join(', ');
  window.DropcapMock = (cmd, a) => {
    switch (cmd) {
      case 'ready': case 'view':
        if (a && 'query' in a) dir.query = a.query;
        if (a && a.status) dir.status = a.status;
        if (a && a.layout) dir.layout = a.layout;
        return view();
      case 'setEnabledMany': a.ids.forEach((id) => { enabled[id] = a.on; }); return null;
      case 'set': st[a.key] = a.value; return null;
      case 'exportBackup': st.backupMsg = '내보냈습니다'; return null;
      case 'importBackup': st.imported = true; st.backupMsg = '가져왔습니다 — 새로 더할 것이 없었습니다(모두 이미 있음)'; return null;
      case 'undoImport': st.imported = false; st.backupMsg = '가져오기 전으로 되돌렸습니다'; return null;
      case 'keywords': st.must = split(a.must); st.mute = split(a.mute); st.watch = split(a.watch || ''); return { must: st.must, mute: st.mute, watch: st.watch };
      case 'setEnabled': enabled[a.id] = a.on; return null;
      case 'setNotify': notify[a.id] = a.on; return null;
      case 'setPolicy': policy[a.id][a.key] = a.value; return null;
      case 'unhide': hidden = hidden.filter((h) => h[0] !== a.id); return null;
      case 'subscribe': return new Promise((r) => setTimeout(() => { subscribed.add(a.id); r({ error: null }); }, 600));
      case 'scrapExport': if (a.on && !st.scrapFolder) st.scrapFolder = 'D:\\Notes\\Obsidian\\Dropcap 스크랩'; st.scrapExport = !!a.on; return null;
      case 'chooseScrapFolder': st.scrapFolder = 'D:\\Notes\\Obsidian\\Dropcap 스크랩'; st.scrapExport = true; return null;
      case 'forgetScrapFolder': st.scrapFolder = null; st.scrapExport = false; return null;
      case 'addChannel': return new Promise((r) => setTimeout(() => r({ error: '이 주소에서 피드를 찾지 못했습니다' }), 600));
      default: return null;
    }
  };
}
