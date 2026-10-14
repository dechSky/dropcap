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
  const base = [
    row('openai', 'OpenAI', 'lab', '#10A37F'), row('anthropic', 'Anthropic', 'lab', '#D97757'), row('deepmind', 'Google DeepMind', 'lab', '#4285F4'),
    row('nvidia', 'NVIDIA', 'lab', '#76B900', { aiOnly: true }), row('verge', 'The Verge', 'press', '#5200FF'), row('wired', 'WIRED', 'press', '#3A3A3C'),
    row('aitimes', 'AI타임스', 'kr', '#0057B8', { aiOnly: true }),
  ];
  const cat = [
    ['YouTube', 'cat-yt-openai', 'OpenAI (YouTube)', '#FF0033', 'video', '영상', true],
    ['YouTube', 'cat-yt-2mp', 'Two Minute Papers', '#FF0033', 'video', '영상', true],
    ['뉴스레터·블로그', 'cat-importai', 'Import AI', '#3D5AFE', 'article', null, true],
    ['논문', 'cat-arxiv-ai', 'arXiv cs.AI', '#B31B1B', 'paper', '논문', false],
    ['오픈소스 릴리스', 'cat-gh-ollama-ollama', 'Ollama', '#6E7681', 'release', '릴리스', true],
  ];
  const view = () => {
    const live = (r) => ({ ...r, enabled: !!enabled[r.id], notify: notify[r.id] ?? true,
      notifyHelp: (notify[r.id] ?? true) ? '새 글 알림 켜짐 (끄면 매거진에만 실림)' : '알림 꺼짐 — 매거진에만 실림' });
    return {
      general: {
        style: st.style, styles: [{ id: 'drop', label: '물방울 (앱이 직접 그림)' }, { id: 'system', label: '시스템 알림 센터' }],
        position: st.position, positions: [{ id: 'center', label: '위쪽 가운데' }, { id: 'right', label: '오른쪽 위' }],
        sound: st.sound, interval: st.interval, intervals: [2, 5, 10, 15, 30].map((m) => ({ value: m, label: `${m}분` })),
        translation: 'Google 번역', translationNote: '윈도우에는 무료로 쓸 수 있는 기기 내 번역이 없어 Google 번역을 씁니다.',
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
        catalog: [...new Set(cat.map((c) => c[0]))].map((g) => ({
          label: `추천 · ${g}`,
          rows: cat.filter((c) => c[0] === g).map(([, id, name, color, kind, kindLabel, n]) => ({ id, name, initial: name[0], color, kind, kindLabel,
            sub: n ? '새 글이 오면 알림' : '글이 많아 알림 없이 매거진에만 실림', subscribed: subscribed.has(id), subscribing: false })),
        })),
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
      case 'ready': case 'view': return view();
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
      case 'addChannel': return new Promise((r) => setTimeout(() => r({ error: '이 주소에서 피드를 찾지 못했습니다' }), 600));
      default: return null;
    }
  };
}
