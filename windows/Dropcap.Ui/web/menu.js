// 트레이 창(U 절). 거르기·정렬은 앱(MenuPage.cs)이 하고 여기서는 그리기만.
(() => {
  const { ic, esc, popMenu, popUnder, lock } = window.ui;
  const $ = (s) => document.querySelector(s);
  const state = { tab: 'all', query: '', section: '', topic: '', sort: null };
  let view = null;
  let sel = null; // 키보드로 고른 소식(H-03)

  const ask = (cmd) => bridge.send(cmd, { ...state }).then(render);
  const run = (cmd, args = {}) => bridge.send(cmd, args).then(() => refresh());
  const refresh = () => ask('view');

  function render(v) {
    view = v;
    state.sort = v.sort;
    // 고른 분야가 바뀌어 칩이 사라졌으면 '전체'로
    state.section = v.section || '';
    state.topic = v.topic || '';
    // 머리(U-02)
    $('.row1 b').textContent = v.header.title;
    $('#status').textContent = v.header.status;
    // 회의·발표 중(N-25)이면 그 이유, 아니면 방해 금지 달
    const hush = $('#hush');
    hush.hidden = !v.header.autoQuiet;
    hush.title = v.header.autoQuietHelp || '';
    hush.setAttribute('aria-label', v.header.autoQuiet || '');
    $('#quiet').hidden = !v.header.quiet || !!v.header.autoQuiet;
    const sn = $('#snooze');
    sn.classList.toggle('snoozed', v.header.snoozed);
    sn.innerHTML = ic(v.header.snoozed ? 'bell.slash' : 'bell');
    sn.title = v.header.snoozeHelp;
    const ck = $('#check');
    ck.classList.toggle('spin', v.header.checking);
    ck.disabled = v.header.checking;
    // 탭(U-03)
    document.querySelector('[data-tab="unread"]').textContent = `안 읽음 ${v.unread}`;
    document.querySelectorAll('#tabs button').forEach((b) => b.classList.toggle('on', b.dataset.tab === state.tab));
    // 분야 칩 줄(G-09)
    chips(v);
    // 정렬: 지금 정렬이 무엇인지 보이게(최신순이 아닐 때는 이름까지)
    const so = $('#sort');
    so.classList.toggle('on', !!v.sortLabel);
    so.innerHTML = ic(v.sort === 'important' ? 'star' : v.sort === 'source' ? 'building' : 'sort') + (v.sortLabel ? `<span>${esc(v.sortLabel)}</span>` : '');
    $('#hk').textContent = v.hotkey;
    // 목록(U-05·U-06)
    const list = $('#list');
    if (!v.rows.length) {
      list.innerHTML = `<div class="empty">${ic(v.empty.icon)}<b>${esc(v.empty.title)}</b><span>${esc(v.empty.sub)}</span></div>`;
      return;
    }
    list.innerHTML = v.rows.map(row).join('');
    if (sel && !v.rows.some((r) => r.item.key === sel)) sel = null;
    mark(false);
  }

  // 칩 하나(맥 SectionChip). 색은 앱이 보낸 #RRGGBB(라이트·다크)
  const colors = (c) => `--tl:${esc(c.light)};--td:${esc(c.dark)}`;
  const chip = (c, on, kind) => `<button class="chip${on ? ' on' : ''}" data-${kind}="${esc(c.id)}" style="${colors(c)}" aria-pressed="${on}">${ic(c.icon)}<span>${esc(c.label)}</span></button>`;
  function chips(v) {
    const bar = $('#chips');
    const keep = bar.scrollLeft;
    bar.innerHTML = `<button class="chip all${state.section ? '' : ' on'}" data-section="" aria-pressed="${!state.section}">${ic('grid')}<span>전체</span></button>`
      + v.chips.map((c) => chip(c, state.section === c.id, 'section')).join('');
    bar.scrollLeft = keep;
    const sub = $('#topics');
    sub.hidden = !v.topics.length;   // 숨겼다 보일 때만 CSS 로 살짝 내려옴
    sub.innerHTML = v.topics.map((c) => chip(c, state.topic === c.id, 'topic')).join('');
  }

  // 사진 자리: 사진은 앱의 안전 로더로만(bridge.img). 못 받으면 아래의 출처 색 자리가 보인다
  function thumb(r) {
    const src = r.thumb ? bridge.img(r.thumb) : '';
    return `<span class="th"><span class="ini">${esc(r.item.initial)}</span>${src ? `<img src="${esc(src)}" alt="" loading="lazy" decoding="async">` : ''}</span>`;
  }

  // 이름표(출처별이면 출처, 아니면 시간 묶음) + 첫 소식은 크게, 나머지는 작은 카드(맥 listStyle2 = "hero")
  function row(r) {
    const it = r.item;
    let head = '';
    if (r.sourceHead) head = `<div class="srch${r.sourceFirst ? ' first' : ''}"><b>${esc(r.sourceHead)}</b><small>${r.sourceCount}</small></div>`;
    else if (r.section) head = `<div class="sec${r.sectionFirst ? ' first' : ''}">${esc(r.section)}</div>`;
    const attrs = `data-key="${esc(it.key)}" style="--c:${esc(it.color)};--tl:${esc(r.topicLight)};--td:${esc(r.topicDark)}"`;
    if (r.hero) {
      return head + `<div class="hero item" ${attrs}>${thumb(r)}<span class="shade"></span>
        <div class="cap"><div class="tag"><span class="pill">${esc(r.topicLabel)}</span><span class="src">${esc(it.source)} · ${esc(it.time)}</span>${lock(it)}</div>
        <div class="t">${esc(it.title)}</div></div></div>`;
    }
    return head + `<div class="card item${it.read ? ' read' : ''}" ${attrs}>${thumb(r)}
      <div class="body"><div class="t">${esc(it.title)}</div>
        <div class="meta">${it.important ? `<span class="imp">${ic('star.fill')}</span>` : it.watch ? `<span class="wt" title="지켜볼 낱말: ${esc(it.watch)}">${ic('eye')}</span>` : ''}<span class="src">${esc(it.source)}</span>${lock(it)}<span class="cat">${esc(r.topicLabel)}</span><span class="tm">${esc(it.time)}</span>${it.saved ? `<span class="bm">${ic('bookmark.fill')}</span>` : ''}</div></div>
      ${it.read ? '' : '<span class="dot"></span>'}
    </div>`;
  }

  const itemOf = (key) => { const r = view && view.rows.find((x) => x.item.key === key); return r && r.item; };

  // 사진을 못 받으면 지워서 출처 색 자리가 보이게(인라인 onerror 는 CSP 로 막혀 여기서)
  $('#list').addEventListener('error', (e) => { if (e.target.tagName === 'IMG') e.target.remove(); }, true);
  $('#list').addEventListener('click', (e) => {
    const r = e.target.closest('.item');
    if (r) bridge.send('open', { key: r.dataset.key });
  });
  // 오른쪽 클릭(U-05): 나중에 읽기·읽음/안 읽음·브라우저·링크 복사 + 바로 줄이기(G-11, 맥 ReduceMenu)
  $('#list').addEventListener('contextmenu', async (e) => {
    const r = e.target.closest('.item');
    if (!r) return;
    const it = itemOf(r.dataset.key);
    const { clientX: x, clientY: y } = e;
    let rd = null;
    try { rd = await bridge.send('reduceInfo', { key: it.key }); } catch { /* 기사가 막 사라졌으면 줄이기 없이 */ }
    const items = [
      { label: it.saved ? '저장 취소' : '나중에 읽기', run: () => run('toggleSaved', { key: it.key }) },
      { label: it.read ? '안 읽음으로 표시' : '읽음으로 표시', run: () => run('setRead', { key: it.key, on: !it.read }) },
      'sep',
      { label: '브라우저에서 열기', run: () => bridge.send('browser', { key: it.key }) },
      { label: '링크 복사', run: () => bridge.send('copyLink', { key: it.key }) },
    ];
    if (rd) {
      items.push('sep', { label: rd.hideLabel, run: () => run('hideSource', { key: it.key }) });
      if (rd.canLess) items.push({ label: rd.lessLabel, run: () => run('lessOf', { key: it.key }) });
      // 하위 메뉴 대신: 누르면 같은 자리에 제목 낱말 고르기 메뉴
      if (rd.words.length) {
        items.push({ label: '이 낱말 알리지 않기…', run: () => popMenu(x, y, [
          { header: '알리지 않을 낱말' },
          ...rd.words.map((w) => ({ label: w, run: () => run('muteWord', { word: w }).then(() => ui.toast(`'${w}' 낱말은 알리지 않습니다`)) })),
        ]) });
      }
    }
    popMenu(x, y, items);
  });

  $('#tabs').addEventListener('click', (e) => {
    const b = e.target.closest('button');
    if (!b) return;
    state.tab = b.dataset.tab;
    refresh();
  });
  let typing;
  $('#q').addEventListener('input', (e) => {
    state.query = e.target.value;
    $('#clear').hidden = !state.query;
    clearTimeout(typing);
    typing = setTimeout(refresh, 80);
  });
  $('#clear').addEventListener('click', () => { $('#q').value = ''; state.query = ''; $('#clear').hidden = true; refresh(); });
  // 분야 칩: 같은 칩을 다시 누르면 '전체'로, 분야를 바꾸면 하위 칩은 풀린다(맥 SectionChipBar)
  $('#chipbar').addEventListener('click', (e) => {
    const b = e.target.closest('.chip');
    if (!b) return;
    if (b.dataset.section !== undefined) {
      const id = b.dataset.section;
      state.section = id && state.section !== id ? id : '';
      state.topic = '';
    } else {
      state.topic = state.topic === b.dataset.topic ? '' : b.dataset.topic;
    }
    refresh();
  });
  $('#sort').addEventListener('click', (e) => popUnder(e.currentTarget, [
    { label: '최신순', icon: 'clock', on: state.sort === 'newest', run: () => { state.sort = 'newest'; refresh(); } },
    { label: '중요·많이 보도된 순', icon: 'star', on: state.sort === 'important', run: () => { state.sort = 'important'; refresh(); } },
    { label: '출처별', icon: 'building', on: state.sort === 'source', run: () => { state.sort = 'source'; refresh(); } },
  ]));
  // 알림 잠시 끄기(C-20)
  $('#snooze').addEventListener('click', (e) => popUnder(e.currentTarget, view.header.snoozed
    ? [{ label: '다시 알림 켜기', run: () => run('snooze', { mode: 'off' }) }]
    : [
      { label: '1시간 동안', run: () => run('snooze', { mode: '1h' }) },
      { label: '3시간 동안', run: () => run('snooze', { mode: '3h' }) },
      { label: '내일 아침 8시까지', run: () => run('snooze', { mode: 'morning' }) },
    ]));
  $('#check').addEventListener('click', () => { $('#check').classList.add('spin'); run('check'); });
  $('#mag').addEventListener('click', () => bridge.send('magazine'));
  $('#settings').addEventListener('click', () => bridge.send('settings'));
  $('#more').addEventListener('click', (e) => popUnder(e.currentTarget, [
    { label: '모두 읽음으로 표시', run: () => run('markAllRead') },
    { label: '알림 미리 보기', run: () => bridge.send('preview') },
    'sep',
    { label: 'Dropcap 종료', run: () => bridge.send('quit') },
  ]));
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !document.querySelector('.pop')) bridge.send('close'); });

  // 키보드 탐색(H-03, 맥 MenuView): ↓/J·↑/K 고르기(끝에서 멈춤), ⏎ 열기, S 나중에 읽기, O 브라우저(읽음 처리), M 읽음/안 읽음.
  // 창을 열면 목록이 키를 받고, 검색칸에서 ↓ 로 목록으로 내려온다.
  function mark(scroll) {
    document.querySelectorAll('#list .kbsel').forEach((n) => n.classList.remove('kbsel'));
    if (!sel) return;
    const el = [...document.querySelectorAll('#list .item')].find((n) => n.dataset.key === sel);
    if (!el) return;
    el.classList.add('kbsel');
    if (scroll) ui.scrollToCenter(el);
  }
  document.addEventListener('keydown', (e) => {
    if (document.querySelector('.pop') || !view) return;
    const k = ui.navKey(e);
    if (!k) return;
    const keys = view.rows.map((r) => r.item.key);
    if (k === 'next' || k === 'prev') {
      if (e.target === $('#q')) $('#q').blur();
      sel = ui.navMove(sel, keys, k === 'next' ? 1 : -1);
      mark(true);
      e.preventDefault();
      return;
    }
    const it = sel && itemOf(sel);
    if (!it) return;
    e.preventDefault();
    if (k === 'open') bridge.send('open', { key: it.key });
    else if (k === 'save') run('toggleSaved', { key: it.key });
    else if (k === 'browser') run('browser', { key: it.key, read: true });
    else if (k === 'toggleRead') run('setRead', { key: it.key, on: !it.read });
  });

  // 창이 다시 보일 때마다 새로(입력 칸에 커서를 넣지 않음)
  bridge.on('shown', () => { document.activeElement && document.activeElement.blur(); sel = null; bridge.send('ready', { ...state }).then(render); });
  bridge.on('changed', refresh);
  bridge.send('ready', { ...state }).then(render);
})();
