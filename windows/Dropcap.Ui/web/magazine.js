// 매거진 창(M 절). 호 엮기·분야 거르기·정렬·검색·묶기는 앱(MagazinePage.cs)이 하고 여기서는 그리기만.
(() => {
  const { esc, popMenu, popUnder, toast, lock, navKey, navMove, scrollToCenter } = window.ui;
  const $ = (s, r = document) => r.querySelector(s);
  const detail = $('#detail');

  // ui.js 에 아직 없는 기호(맥 SF Symbols 이름에 맞춤)
  const X = {
    calendar: '<rect x="4" y="5.5" width="16" height="14.5" rx="2"/><path d="M4 10h16M8.5 3.5v4M15.5 3.5v4"/>',
    stories: '<circle cx="5.5" cy="17.5" r="2"/><circle cx="12" cy="6" r="2"/><circle cx="18.5" cy="17.5" r="2"/><path d="M6.5 15.7l4.5-7.9M13 7.8l4.5 7.9M7.5 17.5h9" stroke-dasharray="1.6 1.8"/>',
    books: '<rect x="4" y="4" width="4" height="16" rx="1"/><rect x="9.5" y="4" width="4" height="16" rx="1"/><path d="M15.5 5.3l3.6-1 3 15.3-3.6 1z"/>',
    'doc.rich': '<path d="M6.5 3.5h7l4 4v13h-11z"/><path d="M13.5 3.5v4h4"/><circle cx="10" cy="11" r="1.3"/><path d="M8.5 17l2.5-2.5 2 2 1.5-1.5 1.5 2"/>',
    'arrow.up': '<path d="M12 19V5M6 11l6-6 6 6"/>',
    'chevron.left': '<path d="M15 5l-7 7 7 7"/>',
    'doc.text': '<path d="M6.5 3.5h7l4 4v13h-11z"/><path d="M13.5 3.5v4h4M9 12h6M9 15.5h6"/>',
    'folder.fill': '<path fill="currentColor" d="M3.5 7a1.5 1.5 0 0 1 1.5-1.5h4l2 2h8a1.5 1.5 0 0 1 1.5 1.5v8.5A1.5 1.5 0 0 1 19 19H5a1.5 1.5 0 0 1-1.5-1.5z"/>',
    kept: '<circle cx="12" cy="12" r="9" fill="currentColor" stroke="none"/><path stroke="var(--paper,#fff)" d="M12 7.5v8M8.5 12.5l3.5 3.5 3.5-3.5"/>',
    split: '<rect x="3.5" y="5.5" width="17" height="13" rx="2"/><path d="M9.2 5.5v13M14.8 5.5v13"/>',
    wave: '<path d="M4 12h2M8 8v8M12 5v14M16 8v8M20 11v2"/>',
    'bell.fill': '<path fill="currentColor" d="M6 16V11a6 6 0 0 1 12 0v5l1.5 2h-15z"/><path d="M10 20a2 2 0 0 0 4 0"/>',
    house: '<path d="M4 11l8-6.5 8 6.5"/><path d="M6 9.5V20h12V9.5"/><path d="M10 20v-5.5h4V20"/>',
    lines: '<path d="M4 6.5h16M4 10.5h11M4 14.5h16M4 18.5h9"/>',
  };
  const ic = (name, cls = '') => X[name]
    ? `<i class="ic ${cls}"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">${X[name]}</svg></i>`
    : window.ui.ic(name, cls);
  // html 의 <i data-ic> 중 위 기호는 여기서 먼저 채운다(나머지는 ui.js 가)
  document.querySelectorAll('[data-ic]').forEach((el) => { if (X[el.dataset.ic]) el.outerHTML = ic(el.dataset.ic); });

  // 라이트·다크 두 벌 색(앱이 #RRGGBB 만 보냄) → CSS .tint 가 --t 로 고른다
  const tint = (o) => `--tl:${esc(o.light)};--td:${esc(o.dark)}`;

  const SORTS = [
    { id: 'recommended', label: '추천순', icon: 'sparkles' },
    { id: 'newest', label: '최신순', icon: 'clock' },
    { id: 'coverage', label: '많이 보도된 순', icon: 'people' },
    { id: 'source', label: '출처별', icon: 'building' },
  ];

  // MARK: 지면 상태
  let side = null;              // 옆 목록(저장 수·스크랩 수·분야·지난 호)
  let page = 'today';           // today · week · section:<id> · stories · story:<id> · saved · scrapbook · search · issue:<id>
  let current = null;           // 지금 지면의 DOM(.page)
  let view = null;              // 지금 지면의 데이터
  let seen = { revision: 0, imageRevision: 0, layoutRevision: 0 };
  let focus = null;             // 분야 칩으로 고른 한 분야(section:<id> 지면이면 처음부터)
  let sub = null;               // AI 안의 하위 칩
  let folder = null;            // 스크랩북에서 보던 폴더
  let query = '';
  let gen = 0;                  // 지면을 넘기면 늦게 온 답은 버림
  let wasPreparing = false;     // 첫 호를 엮는 중이었나(다 엮이면 바로 채움)
  let selected = null;          // 키보드로 고른 카드(H-03)

  const isIssue = (p) => p === 'today' || p === 'week' || p.startsWith('issue:') || p.startsWith('section:');
  const isLive = (p) => p === 'today' || p === 'week' || p.startsWith('section:');
  const issueSource = (p) => p.startsWith('issue:') ? p.slice(6) : p.startsWith('section:') ? 'today' : p;
  const issueArgs = (extra = {}) => ({ source: issueSource(page), focus, sub, ...extra });

  // 넘김 방향(맥 order): 뒤 지면으로 가면 앞으로 넘기고, 앞 지면이면 거꾸로
  function order(p) {
    const o = { today: 0, week: 1, stories: 2, saved: 4, scrapbook: 5, search: 7 };
    if (p in o) return o[p];
    if (p.startsWith('section:')) return 1;
    if (p.startsWith('story:')) return 3;
    if (p.startsWith('issue:')) return 100 + Math.max(0, (side ? side.archive : []).findIndex((a) => a.id === p.slice(6)));
    return 0;
  }

  // MARK: 옆 목록(M-01): 이번 호 · 분야 · 모아 보기 · 지난 호
  function renderSide(s) {
    side = s;
    $('#nSaved').textContent = `저장 ${s.saved}`;
    $('#nScraps').textContent = `스크랩북 ${s.scraps}`;
    $('#secs').innerHTML = s.sections.length ? '<div class="sh">분야</div>' + s.sections.map((x) =>
      `<button class="nav tint" style="${tint(x)}" data-go="section:${esc(x.id)}">${ic(x.icon)}<span>${esc(x.name)}</span></button>`).join('') : '';
    $('#archive').innerHTML = s.archive.length ? '<div class="sh">지난 호</div>' + s.archive.map((a) =>
      `<button class="nav" data-go="issue:${esc(a.id)}" title="${esc(a.title)}">${ic(a.weekly ? 'books' : 'doc.rich')}<span>${esc(a.title)}</span></button>`).join('') : '';
    markSide();
  }
  function markSide() {
    const key = page.startsWith('story:') ? 'stories' : page;
    document.querySelectorAll('.side .nav').forEach((b) => b.classList.toggle('on', b.dataset.go === key));
  }
  $('#side').addEventListener('click', (e) => { const b = e.target.closest('[data-go]'); if (b) go(b.dataset.go); });

  // MARK: 지면 넘기기(M-19)
  function go(p, opts = {}) {
    if (p === page && current && !opts.force) return;
    hideFresh();
    const forward = order(p) >= order(page);
    page = p;
    focus = p.startsWith('section:') ? p.slice(8) : null;
    sub = null;
    selected = null;
    markSide();
    const old = current;
    const el = document.createElement('section');
    el.className = 'page';
    detail.appendChild(el);
    current = el;
    view = null;
    if (old && !document.documentElement.classList.contains('reduce-motion')) {
      old.className = 'page ' + (forward ? 'out-fwd' : 'out-back');
      el.classList.add(forward ? 'in-fwd' : 'in-back');
      setTimeout(() => old.remove(), 620);
      setTimeout(() => el.classList.remove('in-fwd', 'in-back'), 620);
    } else if (old) old.remove();
    load(true);
  }

  // 지금 지면을 (다시) 그린다. fresh=처음 그림(움직임 있음), 아니면 조용히.
  async function load(fresh) {
    const my = ++gen;
    const el = current;
    const p = page;
    try {
      if (isIssue(p)) {
        const v = await bridge.send('issue', issueArgs());
        if (my !== gen) return;
        if (!v) { go('today'); return; }  // 지난 호가 정리돼 없어졌으면 오늘 호로
        drawIssue(el, v, fresh);
      } else if (p === 'stories') drawStories(el, await bridge.send('stories'), fresh, my);
      else if (p.startsWith('story:')) drawStory(el, await bridge.send('story', { id: p.slice(6) }), my);
      else if (p === 'saved') drawSaved(el, await bridge.send('saved'), fresh, my);
      else if (p === 'search') drawSearch(el, fresh);
      else if (p === 'scrapbook') drawScrapbook(el, await bridge.send('scrapbook', { folder, repick: !fresh }), fresh, my);
    } catch (e) { console.error(e); }
  }

  // MARK: 사진 칸(M-21: 칸마다 새로 그리므로 다른 기사 사진이 남지 않음)
  function ph(it, inner = '') {
    const src = bridge.img(it.image);
    return `<div class="ph cat-${esc(it.category)}" style="--c:${esc(it.color)}"><div class="glyph">${ic('cat.' + it.category)}</div>
      <div class="pic">${src ? `<img src="${esc(src)}" alt="" draggable="false">` : ''}</div>${inner}</div>`;
  }
  // 사진은 다 받아진 뒤에 부드럽게(못 받으면 그라데이션 그대로)
  function wireImages(root) {
    root.querySelectorAll('.ph img:not([data-w])').forEach((img) => {
      img.dataset.w = '1';
      const ok = () => img.classList.add('ok');
      if (img.complete && img.naturalWidth) ok(); else { img.addEventListener('load', ok); img.addEventListener('error', () => img.remove()); }
    });
  }

  // 분야 표시(N-05 TopicChip: AI 분야는 'AI·모델'처럼 하위 분류까지)
  const topicTag = (t) => t ? `<span class="topic tint" style="${tint(t)}">${ic(t.icon)}${esc(t.label)}</span>` : '';

  // MARK: 카드(M-08). o.topic: 분야 표시, o.region: 해외·국내 두 줄(G-12)
  function card(it, i, extra = '', o = {}) {
    const kind = it.kind !== 'article'
      ? `<span class="kbadge kind-${esc(it.kind)}">${ic('kind.' + it.kind)}<span>${esc(it.kindLabel)}</span></span>` : '';
    const play = it.kind === 'video' || it.kind === 'podcast' ? `<span class="play">${ic(it.kind === 'video' ? 'play' : 'wave')}</span>` : '';
    const rg = o.region ? `<div class="rg"><div><b>해외에서는</b><span>${esc(o.region.intl.join(' · '))}</span></div><div><b>국내에서는</b><span>${esc(o.region.kr.join(' · '))}</span></div></div>` : '';
    // 사진이 없으면 사진 자리를 만들지 않고 글만(맥 StoryCard)
    return `<div class="cell" style="--d:${Math.min(i * 0.05, 0.4)}s" data-key="${esc(it.key)}">${extra}
      <button class="card${it.key === selected ? ' kbsel' : ''}" data-open="${esc(it.key)}" data-nav="${esc(it.key)}">
        ${it.image ? ph(it, play + kind) : ''}
        <div class="body">
          ${!it.image && kind ? `<div class="kline">${kind}</div>` : ''}
          <div class="src">${it.important ? `<span class="star">${ic('star.fill')}</span>` : ''}<b>${esc(it.source)}</b>${lock(it)}${it.related ? `<span class="rel">외 ${it.related}곳</span>` : ''}<span class="t">${esc(it.time)}</span></div>
          ${o.topic ? `<div>${topicTag(o.topic)}</div>` : ''}
          <div class="tt">${esc(it.title)}</div>
          ${rg}
          ${it.read ? `<span class="rd">${ic('check')}읽음</span>` : ''}
        </div>
      </button></div>`;
  }

  // 카드 공용 동작: 누르면 열기, 오른쪽 클릭 메뉴, 마우스 따라 사진 시차
  const itemIndex = new Map();   // key → 기사(메뉴용)
  const clusterOf = new Map();   // key → 스토리 id
  function remember(items, clusters = {}) {
    items.forEach((it) => itemIndex.set(it.key, it));
    Object.entries(clusters).forEach(([k, c]) => clusterOf.set(k, c));
  }
  detail.addEventListener('click', (e) => {
    const o = e.target.closest('[data-open]');
    if (o) { open(o.dataset.open, o.closest('.brief, .timeline, .regions') || current); return; }
    const s = e.target.closest('[data-story]');
    if (s) go('story:' + s.dataset.story);
  });
  // 기사 열기: 읽기 창 J·K 가 이 지면 순서대로 넘기게(H-05) — 지면(또는 저녁 정리 근거 기사)에 보이는 순서의 key 를 함께
  function open(key, scope = current) {
    const seq = scope ? [...new Set([...scope.querySelectorAll('[data-open]')].map((b) => b.dataset.open))] : [];
    bridge.send('open', { key, seq });
  }

  // 오른쪽 클릭: 나중에 읽기 · 여러 시각 · 브라우저 + 바로 줄이기(G-11, 맥 ReduceMenu)
  detail.addEventListener('contextmenu', async (e) => {
    const c = e.target.closest('.card[data-open]');
    if (!c) return;
    const it = itemIndex.get(c.dataset.open);
    if (!it) return;
    const x = e.clientX, y = e.clientY;
    const cl = clusterOf.get(it.key);
    let r = null;
    try { r = await bridge.send('reduce', { key: it.key }); } catch (err) { console.error(err); }
    popMenu(x, y, [
      { label: it.saved ? '저장 취소' : '나중에 읽기', run: () => bridge.send('toggleSaved', { key: it.key }) },
      ...(cl && isIssue(page) ? [{ label: '여러 시각 보기', run: () => go('story:' + cl) }] : []),
      { label: '브라우저에서 열기', run: () => bridge.send('browser', { key: it.key }) },
      ...(r ? [
        'sep',
        { label: r.hide, run: () => bridge.send('hideSource', { key: it.key }) },
        ...(r.less ? [{ label: r.less, run: () => bridge.send('lessOf', { key: it.key }).then(() => toast('알림을 줄였습니다')) }] : []),
        ...(r.words.length ? [{ label: '이 낱말 알리지 않기…', run: () => popMenu(x, y, [{ header: '이 낱말 알리지 않기' },
          ...r.words.map((w) => ({ label: w, run: () => bridge.send('muteWord', { key: it.key, word: w }).then(() => toast(`‘${w}’ 낱말은 알리지 않습니다`)) }))]) }] : []),
      ] : []),
    ]);
  });
  detail.addEventListener('mousemove', (e) => {
    const c = e.target.closest('.card');
    if (!c) return;
    const pic = c.querySelector('.ph > .pic');
    if (!pic) return;
    const r = c.getBoundingClientRect();
    pic.style.setProperty('--tx', (((e.clientX - r.left) / Math.max(r.width, 1)) - 0.5) * 8 + 'px');
    pic.style.setProperty('--ty', (((e.clientY - r.top) / 220) - 0.5) * 6 + 'px');
  });
  detail.addEventListener('mouseout', (e) => {
    const c = e.target.closest('.card');
    if (c && !c.contains(e.relatedTarget)) { const pic = c.querySelector('.ph > .pic'); if (pic) { pic.style.removeProperty('--tx'); pic.style.removeProperty('--ty'); } }
  });

  // 스크롤할 때 들어오며 또렷해짐(M-09): 화면에 다 들어온 카드만 또렷하게
  let watcher = null;
  function watch(root) {
    if (watcher) watcher.disconnect();
    watcher = new IntersectionObserver((ents) => ents.forEach((en) => en.target.classList.toggle('dim', en.intersectionRatio < 0.75)),
      { root: current, threshold: [0, 0.25, 0.5, 0.75, 1] });
    root.querySelectorAll('.cell').forEach((c) => watcher.observe(c));
  }

  // MARK: 마지막 줄에 카드 한 장만 남지 않게(맥 BalancedGrid — MagazinePage.Columns 와 같은 규칙)
  function columns(fit, count) {
    fit = Math.max(1, fit);
    if (count <= fit || count % fit !== 1) return Math.min(fit, Math.max(count, 1));
    if (fit + 1 <= 4 && count % (fit + 1) !== 1 && count >= fit + 1) return fit + 1;
    if (fit > 2 && count % (fit - 1) !== 1) return fit - 1;
    return fit;
  }
  function balance(root = current) {
    if (!root) return;
    root.querySelectorAll('.grid.bal').forEach((g) => {
      const fit = Math.floor((g.clientWidth + 18) / (230 + 18));
      g.style.gridTemplateColumns = `repeat(${columns(fit, g.children.length)}, minmax(200px, 360px))`;
    });
  }
  new ResizeObserver(() => balance()).observe(detail);

  // MARK: 한 호(M-06~M-11·M-22) · 분야 칩 줄(G-09) · 분야 지면(G-10)
  function chipBar(v) {
    if (!v.chips.length) return '';
    const chip = (attr, id, on, t, icon, label, count, small) =>
      `<button class="schip tint${on ? ' on' : ''}${small ? ' small' : ''}" style="${tint(t)}" ${attr}="${esc(id)}">${ic(icon)}<span>${esc(label)}</span>${count > 0 ? `<small>${count}</small>` : ''}</button>`;
    return `<div class="chipbar">
      <div class="crow">${chip('data-chip', '', !v.focus, { light: '#007AFF', dark: '#0A84FF' }, 'grid', '전체', 0)}
        ${v.chips.map((c) => chip('data-chip', c.id, v.focus === c.id, c, c.icon, c.label, c.count)).join('')}</div>
      ${v.subChips.length ? `<div class="crow sub">${v.subChips.map((c) => chip('data-subchip', c.id, v.sub === c.id, c, c.icon, c.label, 0, true)).join('')}</div>` : ''}
    </div>`;
  }

  function drawIssue(el, v, fresh) {
    const scroll = el.scrollTop;
    view = v;
    seen = { revision: v.revision, imageRevision: v.imageRevision, layoutRevision: v.layoutRevision };
    wasPreparing = v.preparing;
    focus = v.focus || null;
    sub = v.sub || null;
    const all = [];
    if (v.cover) all.push(v.cover.item);
    v.sections.forEach((s) => all.push(...s.items));
    remember(all, v.clusters);
    const sort = SORTS.find((s) => s.id === v.sort) || SORTS[0];
    const c = v.cover;
    // 사진이 없으면 사진 자리를 만들지 않고 글자 표지로(지어낸 그림은 쓰지 않음)
    const coverHtml = c ? `<div class="cover${c.item.image ? '' : ' plain'}${c.item.key === selected ? ' kbsel' : ''}" data-nav="${esc(c.item.key)}">
        ${c.item.image ? `${ph(c.item)}<div class="shade"></div>` : ''}
        <div class="in">
          <div class="meta"><span class="badge">표지</span>${v.topics[c.item.key] ? `<span class="catl">${ic(v.topics[c.item.key].icon)}${esc(v.topics[c.item.key].label)}</span>` : ''}<span>${esc(c.item.source)} · ${esc(c.item.time)}</span>${lock(c.item)}</div>
          <h2>${esc(c.item.title)}</h2>
          ${c.item.translated ? `<div class="orig">${esc(c.item.original)}</div>` : ''}
          <div class="acts">
            <button class="pill solid" data-open="${esc(c.item.key)}">${ic('book')}기사 읽기</button>
            ${c.cluster && c.size >= 2 ? `<button class="pill glass" data-story="${esc(c.cluster)}">${ic('split')}여러 시각 ${c.size}곳</button>` : ''}
          </div>
        </div></div>`
      : v.empty ? `<div class="empty-issue">${v.empty.preparing ? '<div class="spinner"></div>' : ic('newspaper')}<b>${esc(v.empty.title)}</b><span>${esc(v.empty.sub)}</span></div>` : '';
    el.classList.toggle('calm', !fresh);
    el.innerHTML = `
      <header class="mast">
        <div class="logo"><span class="mark"><b>D</b><span>ROPCAP</span></span><span class="sub">매거진</span>${v.live ? '<span class="live">발행 중</span>' : ''}</div>
        <div class="title">${esc(v.title)}</div>
        <div class="count">소식 ${v.count}건 · 분야 ${v.sectionCount}개</div>
        <div class="rule"></div>
        <button class="sortbtn" title="지면 안의 기사 순서">${ic(sort.icon)}<span>${esc(sort.label)}</span>${ic('chevronDown', 'chev')}</button>
      </header>
      ${v.today ? `<div class="today-slot">${todayHtml(v.today)}</div>` : ''}
      ${chipBar(v)}
      ${v.brief ? briefHtml(v.brief) : ''}
      ${coverHtml}
      ${v.sections.map((s) => `<section class="sec tint" style="${tint(s)}">
        ${s.glass ? glassHtml(s) : `<div class="sec-h">${ic(s.icon)}<b>${esc(s.label)}</b><small>${s.items.length}</small><span class="line"></span></div>`}
        <div class="grid bal">${s.items.map((it, i) => card(it, i, '', { topic: s.showTopic ? v.topics[it.key] : null, region: v.regions[it.key] })).join('')}</div></section>`).join('')}
      <div class="copyright">기사 저작권은 각 언론사·기업에 있습니다. 제목·요약·사진은 원문으로 이어 주기 위한 것입니다.</div>`;
    balance(el);
    if (!fresh) el.scrollTop = scroll;
    wireImages(el);
    watch(el);
    if (selected && !el.querySelector(`[data-nav="${CSS.escape(selected)}"]`)) selected = null;
    $('.sortbtn', el).addEventListener('click', (e) => popUnder(e.currentTarget, SORTS.map((s) => ({
      label: s.label, icon: s.icon, on: s.id === v.sort,
      run: () => bridge.send('issue', issueArgs({ sort: s.id })).then((nv) => nv && drawIssue(current, nv, false)),
    }))));
  }

  // 분야 지면 머리의 유리 띠(맥 SectionGlassCard 높이 92): 흐린 사진 바탕 + 분야색 유리판 + 기울인 사진 + 영문·한글 이름 + 'N건 · 첫 기사'
  function glassHtml(s) {
    const g = s.glass;
    const src = g.photo ? bridge.img(g.photo) : '';
    return `<div class="gcard strip${src ? '' : ' nophoto'}" data-glass="${esc(s.section)}" style="--c:var(--t)">
      ${src ? `<img class="bg" src="${esc(src)}" alt="" draggable="false">` : ''}<span class="gl"></span><span class="panel"></span>
      ${src ? `<span class="tilt"><img src="${esc(src)}" alt="" draggable="false"></span>` : ''}
      <span class="tx"><small class="en">${esc(g.english)}</small><b>${esc(s.label)}</b><span class="gs">${esc(g.sub)}</span></span></div>`;
  }
  // 분야 사진을 찾으면(앱 'photos') 유리 띠만 바꿔 끼운다
  function patchPhotos(map) {
    if (!view || !view.sections || !current) return;
    view.sections.forEach((s) => {
      if (!s.glass || s.glass.photo || !map[s.section]) return;
      s.glass.photo = map[s.section];
      const el = current.querySelector(`[data-glass="${CSS.escape(s.section)}"]`);
      if (el) el.outerHTML = glassHtml(s);
    });
  }

  // 오늘 호 완독(M-23): 대표 기사 n/m 막대, 다 읽으면 마무리 띠 + 다음 호 안내
  function todayHtml(t) {
    if (t.done) return `<div class="today-done">${ic('checkmark.seal')}<div><b>오늘 호를 다 읽었어요</b><span>${esc(t.next)}</span></div></div>`;
    if (!t.keys.length) return '';
    const pct = Math.round((t.read / Math.max(t.keys.length, 1)) * 100);
    return `<div class="today-prog" title="표지와 주요 뉴스·고른 분야의 첫 줄을 다 읽으면 오늘 호가 끝납니다">
      <span>오늘 호 대표 기사 ${t.read}/${t.keys.length}</span><span class="bar"><i style="width:${pct}%"></i></span></div>`;
  }
  // 읽음이 바뀌면 막대만 다시(지면은 그대로)
  async function refreshToday() {
    if (!view || !view.today || !current) return;
    const el = current;
    const t = await bridge.send('todayProgress', { keys: view.today.keys });
    if (!t || el !== current || !view.today) return;
    const was = view.today.done;
    view.today = t;
    if (t.done) { view.todayDone = true; hideFresh(); }
    const slot = $('.today-slot', el);
    if (slot) { slot.innerHTML = todayHtml(t); if (t.done && !was) slot.firstElementChild && slot.firstElementChild.classList.add('pop'); }
  }

  // 저녁 정리(N-26): 기기 안 요약임을 밝히고, 줄마다 근거 번호, 아래에 근거 기사 원제목 · 출처(누르면 읽기 창)
  function briefHtml(b) {
    return `<div class="brief tint" style="${tint(b)}">
      <div class="bh">${ic('moon.stars')}<b>${esc(b.title)}</b><span class="at">${esc(b.time)}</span>
        <span class="ai" title="${esc(b.help)}">${ic('sparkles')}기기 안 요약 · 원문을 확인하세요</span></div>
      ${b.lines.map((l) => `<div class="bl"><span class="dot">•</span><span class="bt">${esc(l.text)}</span>${l.refs.map((r) => `<span class="ref">[${r}]</span>`).join('')}</div>`).join('')}
      <div class="bdiv"></div>
      <div class="bis">${b.items.map((it, i) => `<button class="bi" data-open="${esc(it.key)}" title="${esc(it.link)}"><span class="ref">[${i + 1}]</span><span class="bt">${esc(it.title)}</span><span class="bs">— ${esc(it.source)}</span></button>`).join('')}</div>
    </div>`;
  }

  // 분야 칩: 같은 칩을 다시 누르면 '전체'로. AI 하위 칩도 같은 식
  detail.addEventListener('click', async (e) => {
    const c = e.target.closest('[data-chip], [data-subchip]');
    if (!c || !isIssue(page)) return;
    if (c.dataset.chip != null) { const id = c.dataset.chip || null; focus = focus === id ? null : id; sub = null; }
    else { const id = c.dataset.subchip; sub = sub === id ? null : id; }
    const my = ++gen;
    const el = current;
    const v = await bridge.send('issue', issueArgs());
    if (my === gen && v && el === current) { el.scrollTop = 0; drawIssue(el, v, false); }
  });

  // 새 소식 띠(M-11): 누르면 다시 엮고 맨 위로
  function showFresh() {
    if (!current || $('.fresh', detail)) return;
    const b = document.createElement('button');
    b.className = 'fresh';
    b.innerHTML = `${ic('arrow.up')}<span>새 소식이 들어왔어요 · 새로 보기</span>`;
    b.addEventListener('click', async () => {
      b.remove();
      const v = await bridge.send('issue', issueArgs());
      if (v && isIssue(page)) { current.scrollTo({ top: 0, behavior: 'smooth' }); drawIssue(current, v, true); }
    });
    detail.appendChild(b);
  }
  const hideFresh = () => { const f = $('.fresh', detail); if (f) f.remove(); };

  // 사진만 새로 채워졌을 때: 같은 지면이면 사진 칸만 바꿔 끼운다(움직임 없이)
  async function quietImages() {
    const v = await bridge.send('issue', issueArgs());
    if (!v || !isIssue(page) || !view) return;
    const keys = (x) => JSON.stringify([x.cover && x.cover.item.key, x.sections.map((s) => s.items.map((i) => i.key))]);
    // 사진 자리가 새로 생기는 카드가 있으면 통째로 조용히 다시 그린다(사진이 없던 카드는 사진 자리가 없음)
    const hadPic = new Set([...current.querySelectorAll('.cell[data-key]')].filter((c) => $('.ph', c)).map((c) => c.dataset.key));
    const gained = v.sections.some((s) => s.items.some((i) => i.image && !hadPic.has(i.key)))
      || (v.cover && v.cover.item.image && !$('.cover .ph', current));
    if (keys(v) !== keys(view) || gained) { drawIssue(current, v, false); return; }
    view = v;
    seen.imageRevision = v.imageRevision;
  }

  // 읽음·저장 표시만 다시(지면은 그대로)
  async function refreshMarks() {
    const cells = [...current.querySelectorAll('.cell[data-key]')];
    if (!cells.length) return;
    const m = await bridge.send('marks', { keys: cells.map((c) => c.dataset.key) });
    const read = new Set(m.read), saved = new Set(m.saved);
    cells.forEach((c) => {
      const k = c.dataset.key;
      const it = itemIndex.get(k);
      if (it) it.saved = saved.has(k);
      const body = $('.body', c);
      const has = $('.rd', body);
      if (read.has(k) && !has) body.insertAdjacentHTML('beforeend', `<span class="rd">${ic('check')}읽음</span>`);
      else if (!read.has(k) && has) has.remove();
    });
  }

  // MARK: 스토리(M-14): 지금 커지는 스토리 · 지난 스토리
  function storyCard(c, big, i) {
    const pic = c.photo ? bridge.img(c.photo) : '';
    const color = c.topic ? c.topic.light : '#8E8E93';
    return `<button class="scard stag${big ? ' big' : ''}" style="--d:${Math.min(i * 0.05, 0.5)}s" data-story="${esc(c.id)}">
      ${pic ? `<div class="ph" style="--c:${esc(color)};--cat:${esc(color)}"><div class="pic"><img src="${esc(pic)}" alt="" draggable="false"></div></div>` : ''}
      <div class="tx">
        <div class="meta">${topicTag(c.topic)}<span class="n">${c.size}곳 보도</span>${c.fresh > 0 ? `<span class="new">새 보도 ${c.fresh}</span>` : ''}${c.following ? `<span class="fol" title="팔로우 중">${ic('bell.fill')}</span>` : ''}</div>
        <b class="t">${esc(c.title)}</b>
        <div class="srcs"><span class="monos">${c.sources.map((s) => `<span class="mono" style="--c:${esc(s.color)}" title="${esc(s.name)}">${esc(s.initial)}</span>`).join('')}</span>
          <span class="names">${esc(c.sources.map((s) => s.name).join(' · '))}</span></div>
        <div class="times">${esc(c.times)}</div>
      </div></button>`;
  }
  function drawStories(el, v, fresh, my) {
    if (my !== gen) return;
    el.classList.toggle('calm', !fresh);
    const scroll = el.scrollTop;
    const head = (t, s) => `<div class="sgh"><b>${esc(t)}</b><span>${esc(s)}</span></div>`;
    el.innerHTML = `<div class="wrap narrow">
      <h1 class="h1">스토리</h1>
      <p class="lead">여러 곳이 함께 다룬 소식을 한 줄기로 묶었습니다. 팔로우하면 새 보도가 붙을 때 알려 드립니다.</p>
      ${v.live.length || v.past.length ? '' : '<div class="note">아직 여러 곳이 함께 다룬 소식이 없습니다. 출처를 더 구독하면 스토리가 늘어납니다.</div>'}
      ${v.live.length ? head('지금 커지는 스토리', '최근 24시간') + v.live.map((c, i) => storyCard(c, i === 0, i)).join('') : ''}
      ${v.past.length ? head('지난 스토리', '최근 2주') + v.past.map((c, i) => storyCard(c, false, i + v.live.length)).join('') : ''}
    </div>`;
    if (!fresh) el.scrollTop = scroll;
    wireImages(el);
  }

  // 한 스토리: 한눈에 요약 → 해외·국내 두 칸 → 보도 줄기(선이 그려지며 각 보도가 차례로) · 팔로우
  function drawStory(el, s, my) {
    if (my !== gen) return;
    view = s;
    remember(s.items.map((r) => r.item));
    const n = Math.max(s.items.length, 1);
    const dur = 0.4 + 0.18 * s.items.length;
    const col = (c) => `<div class="rcol"><div class="rh">${ic(c.icon)}${esc(c.title)} ${c.count}곳</div>
      ${c.items.map((it) => `<button class="ri" data-open="${esc(it.key)}"><b style="--c:${esc(it.color)}">${esc(it.source)}</b><span>${esc(it.title)}</span>${it.translated ? `<small>${esc(it.original)}</small>` : ''}</button>`).join('')}</div>`;
    el.innerHTML = `<div class="wrap narrow">
      <button class="back" data-go-back>${ic('chevron.left')}스토리</button>
      <h1 class="story-h">${esc(s.title)}</h1>
      <div class="story-bar"><span class="story-sub">${esc(s.sub)}</span><button class="follow" title="새 보도가 이 스토리에 붙으면 알림"></button></div>
      <div class="digest" hidden></div>
      ${s.intl && s.kr ? `<div class="regions">${col(s.intl)}${col(s.kr)}</div>` : ''}
      <div class="timeline" style="--dur:${dur}s"><div class="spine"></div>
      ${s.items.map((r, i) => {
        const d = (dur * ((i + 1) / n) * 0.9).toFixed(2);
        return `${r.gap ? `<div class="gap" style="--d:${d}s">${esc(r.gap)}</div>` : ''}<div class="tl" style="--c:${esc(r.item.color)};--d:${d}s">
        <span class="dot${r.first ? ' first' : ''}"></span>
        <div class="col">
          <div class="who"><span class="mono" style="--c:${esc(r.item.color)}">${esc(r.item.initial)}</span><b>${esc(r.item.source)}</b>
            <span class="tier">${esc(r.item.tierLabel)}</span>${lock(r.item)}<span>· ${esc(r.when)}</span>${r.first ? '<span class="first">첫 보도</span>' : ''}</div>
          <button class="box" data-open="${esc(r.item.key)}"><div class="bt"><b>${esc(r.item.title)}</b>${r.lede ? `<span>${esc(r.lede)}</span>` : ''}</div>${r.item.image ? ph(r.item) : ''}</button>
        </div></div>`;
      }).join('')}
      </div></div>`;
    $('[data-go-back]', el).addEventListener('click', () => go('stories'));
    const fb = $('.follow', el);
    const paint = (on) => { fb.classList.toggle('on', on); fb.innerHTML = `${ic(on ? 'bell.fill' : 'bell')}<span>${on ? '팔로우 중' : '이 스토리 팔로우'}</span>`; };
    paint(s.following);
    fb.addEventListener('click', async () => {
      const r = await bridge.send('follow', { id: s.id, on: !fb.classList.contains('on') });
      if (r) paint(r.following);
    });
    wireImages(el);
    digest(el, s.id, my);
  }

  // 한눈에 요약: 이 PC 에 Ollama 가 있을 때만 칸을 띄운다
  async function digest(el, id, my) {
    const box = $('.digest', el);
    try {
      if (!(await bridge.send('canDigest')) || my !== gen) return;
      box.hidden = false;
      box.innerHTML = `<div class="dh">${ic('lines')}한눈에</div><div class="busy"><div class="spinner"></div>여러 보도를 합쳐 요약하는 중…</div>`;
      const lines = await bridge.send('digest', { id });
      if (my !== gen) return;
      if (!lines || !lines.length) { box.hidden = true; return; }
      box.innerHTML = `<div class="dh">${ic('lines')}한눈에</div>${lines.map((l) => `<div class="dl">${esc(l)}</div>`).join('')}
        <div class="df">여러 보도를 이 PC 의 Ollama 로 합쳐 요약했습니다.</div>`;
    } catch (e) { box.hidden = true; }
  }

  // MARK: 저장(M-15)
  function drawSaved(el, v, fresh, my) {
    if (my !== gen) return;
    remember(v.items);
    const kept = new Set(v.archived);
    el.classList.toggle('calm', !fresh);
    const scroll = el.scrollTop;
    el.innerHTML = `<div class="wrap" style="padding:0 32px 40px">
      <h1 class="h1">저장</h1>
      <p class="lead">저장한 기사는 번역까지 이 PC 에 보관돼 인터넷 없이도 읽을 수 있습니다.</p>
      ${v.items.length ? '' : '<div class="note">아직 저장한 기사가 없습니다. 카드를 오른쪽 클릭해 \'나중에 읽기\'로 저장하세요.</div>'}
      <div class="grid" style="margin-top:14px">${v.items.map((it, i) => card(it, i, kept.has(it.key) ? `<span class="kept">${ic('kept')}보관됨</span>` : '', { topic: v.topics[it.key] })).join('')}</div>
    </div>`;
    if (!fresh) el.scrollTop = scroll;
    wireImages(el);
    watch(el);
  }

  // MARK: 검색(M-16): 2글자부터 입력이 멈추면(0.25초) 바로, Enter 면 곧바로
  let typing = null;
  function drawSearch(el, fresh) {
    if (!fresh && $('.searchbox', el)) { runSearch(false); return; }
    el.innerHTML = `<div class="wrap" style="padding:0 32px 40px">
      <h1 class="h1">검색</h1>
      <label class="searchbox">${ic('search')}<input id="sq" placeholder="모든 기록에서 제목·출처·요약 검색" autocomplete="off" spellcheck="false"></label>
      <div class="found" hidden></div>
      <div class="grid results"></div></div>`;
    const input = $('#sq', el);
    input.value = query;
    input.addEventListener('input', () => { query = input.value; clearTimeout(typing); typing = setTimeout(() => runSearch(false), 250); if (!query) runSearch(false); });
    input.addEventListener('keydown', (e) => { if (e.key === 'Enter') { clearTimeout(typing); runSearch(true); } });
    setTimeout(() => input.focus(), 30);
    if (query) runSearch(false);
  }
  async function runSearch(submit) {
    const el = current, q = query;
    const r = await bridge.send('search', { q, submit });
    if (page !== 'search' || el !== current || q !== query || !r.items) return;
    remember(r.items);
    const f = $('.found', el);
    f.hidden = !q;
    f.textContent = `${r.items.length}건`;
    const g = $('.results', el);
    g.innerHTML = r.items.map((it, i) => card(it, i, '', { topic: (r.topics || {})[it.key] })).join('');
    wireImages(g);
    watch(g);
  }

  // MARK: 스크랩북(M-17·M-18)
  function drawScrapbook(el, v, fresh, my) {
    if (my !== gen) return;
    // 메모를 쓰는 중이면 다시 그리지 않는다(쓰던 글이 날아가지 않게)
    if (!fresh && el.contains(document.activeElement) && document.activeElement.tagName === 'TEXTAREA') return;
    folder = v.folder;
    view = v;
    remember(v.groups.map((g) => g.item));
    const empty = !v.groups.length;
    const scroll = el.scrollTop;
    el.classList.toggle('calm', !fresh);
    el.innerHTML = `<div class="wrap" style="max-width:860px">
      <div class="sb-h"><h1 class="h1">스크랩북</h1>
        <button class="btn" id="copyMd" ${empty ? 'disabled' : ''}>${ic('copy')}<span>Markdown 복사</span></button>
        <button class="btn" id="saveMd" ${empty ? 'disabled' : ''}>${ic('download')}<span>파일로 저장</span></button></div>
      <p class="lead" style="margin-top:18px">읽기 창에서 문단에 마우스를 올려 ✂︎ 를 누르거나, 도구막대의 스크랩으로 기사를 모아 두세요. 폴더째 Markdown 으로 내보낼 수 있습니다.</p>
      <div class="chips">${v.folders.map((f) => `<button class="chip${f.name === v.folder ? ' on' : ''}" data-folder="${esc(f.name)}">${ic(f.name === v.folder ? 'folder.fill' : 'folder')}${esc(f.name)} ${f.count}</button>`).join('')}
        <button class="chip add" id="newFolder">${ic('plus')}새 폴더</button></div>
      ${empty ? `<div class="sb-empty">${ic('scissors')}<b>이 폴더는 비어 있습니다</b></div>` : ''}
      ${v.groups.map((g, i) => `<div class="group stag" style="--d:${Math.min(i * 0.05, 0.4)}s">
        <button class="head" data-open="${esc(g.item.key)}">${g.item.image ? ph(g.item) : ''}<div><b>${esc(g.item.title)}</b><span>${esc(g.item.source)} · ${esc(g.item.time)}</span></div></button>
        ${g.scraps.map(scrapRow).join('')}</div>`).join('')}
    </div>`;
    if (!fresh) el.scrollTop = scroll;
    wireImages(el);
    el.querySelectorAll('.memo textarea').forEach(grow);
  }

  function scrapRow(s) {
    return `<div class="scrap" data-scrap="${esc(s.id)}">
      ${s.quote != null ? `<div class="quote"><p>${esc(s.quote)}</p>${s.original != null && s.original !== s.quote ? `<p class="o">${esc(s.original)}</p>` : ''}</div>`
        : `<span class="whole">${ic('doc.text')}기사 전체를 스크랩</span>`}
      <div class="memo">${ic('pencil')}<textarea rows="1" placeholder="메모 남기기" spellcheck="false" data-memo="${esc(s.memo)}">${esc(s.memo)}</textarea>
        <button class="more" title="더 보기">${ic('ellipsis')}</button></div></div>`;
  }

  const grow = (t) => { t.style.height = 'auto'; t.style.height = t.scrollHeight + 'px'; };
  // 메모: 칸을 벗어나거나 Enter 면 저장(Shift+Enter 는 줄바꿈)
  function saveMemo(t) {
    const id = t.closest('[data-scrap]').dataset.scrap;
    if (t.value === t.dataset.memo) return;
    t.dataset.memo = t.value;
    bridge.send('memo', { id, memo: t.value });
  }
  detail.addEventListener('input', (e) => { if (e.target.matches('.memo textarea')) grow(e.target); });
  detail.addEventListener('focusout', (e) => { if (e.target.matches('.memo textarea')) saveMemo(e.target); });
  detail.addEventListener('keydown', (e) => {
    if (e.target.matches('.memo textarea') && e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); e.target.blur(); }
  });

  detail.addEventListener('click', (e) => {
    if (page !== 'scrapbook' || !view) return;
    const chip = e.target.closest('[data-folder]');
    if (chip) { folder = chip.dataset.folder; reloadScrapbook(); return; }
    if (e.target.closest('#newFolder')) {
      ask('새 스크랩 폴더', '', '만들기', async (name) => {
        const r = await bridge.send('newFolder', { name });
        if (r.ok) { folder = r.folder; reloadScrapbook(); }
      });
      return;
    }
    if (e.target.closest('#copyMd')) {
      const b = e.target.closest('#copyMd');
      bridge.send('copyMarkdown', { folder });
      b.innerHTML = `${ic('check')}<span>복사됨</span>`;
      setTimeout(() => { if (b.isConnected) b.innerHTML = `${ic('copy')}<span>Markdown 복사</span>`; }, 1500);
      return;
    }
    if (e.target.closest('#saveMd')) { bridge.send('saveMarkdown', { folder }).then((ok) => ok && toast('저장했습니다')); return; }
    const more = e.target.closest('.memo .more');
    if (more) {
      const row = more.closest('[data-scrap]');
      const id = row.dataset.scrap;
      const memo = $('textarea', row).value;
      popUnder(more, [
        ...view.folders.filter((f) => f.name !== view.folder).map((f) => ({ label: `‘${f.name}’로 옮기기`, run: () => bridge.send('moveScrap', { id, to: f.name, memo }) })),
        'sep',
        { label: '스크랩 지우기', run: () => bridge.send('deleteScrap', { id }) },
      ]);
    }
  });
  detail.addEventListener('contextmenu', (e) => {
    const chip = e.target.closest('[data-folder]');
    if (!chip || page !== 'scrapbook') return;
    const from = chip.dataset.folder;
    popMenu(e.clientX, e.clientY, [{ label: '이름 바꾸기', run: () => {
      folder = from;
      ask('폴더 이름 바꾸기', from, '바꾸기', async (to) => {
        const r = await bridge.send('renameFolder', { from, to });
        folder = r.folder;
        reloadScrapbook();
      });
    } }]);
  });
  async function reloadScrapbook() {
    const my = ++gen;
    drawScrapbook(current, await bridge.send('scrapbook', { folder }), false, my);
  }

  // 이름 묻는 작은 창(맥 alert + TextField)
  function ask(title, value, okLabel, done) {
    const m = document.createElement('div');
    m.className = 'modal';
    m.innerHTML = `<div class="box"><b>${esc(title)}</b><input placeholder="폴더 이름" spellcheck="false">
      <div class="row"><button class="no">취소</button><button class="ok">${esc(okLabel)}</button></div></div>`;
    document.body.appendChild(m);
    const input = $('input', m);
    input.value = value;
    const close = () => m.remove();
    const ok = () => { const v = input.value; close(); if (v.trim()) done(v); };
    $('.ok', m).addEventListener('click', ok);
    $('.no', m).addEventListener('click', close);
    m.addEventListener('mousedown', (e) => { if (e.target === m) close(); });
    input.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && !e.isComposing) ok();
      if (e.key === 'Escape') { e.stopPropagation(); close(); }
    });
    setTimeout(() => { input.focus(); input.select(); }, 20);
  }

  // MARK: 앱 알림
  let pending = null;
  bridge.on('changed', (sig) => {
    clearTimeout(pending);
    pending = setTimeout(() => onChanged(sig || {}), 150);  // 읽음·저장 하나에 여러 번 와도 한 번만
  });
  async function onChanged(sig) {
    bridge.send('sidebar').then(renderSide);
    const p = page;
    if (isIssue(p)) {
      const finished = wasPreparing && !sig.preparing;
      wasPreparing = !!sig.preparing;
      // 숨긴 출처·고른 분야가 바뀌었으면 띠 없이 바로 다시 엮는다
      if (sig.layoutRevision != null && sig.layoutRevision !== seen.layoutRevision) { load(false); return; }
      // 지면이 비었거나 표지가 없거나 첫 호를 엮는 중이면 알림 없이 바로 채운다
      if (isLive(p) && (!view || (!view.cover && !view.focus) || view.count === 0 || sig.preparing || finished)) { load(false); return; }
      // 오늘 호를 다 읽었으면 새 소식을 더 밀어 넣지 않는다(M-23)
      if (isLive(p) && sig.revision > seen.revision && !(view && view.todayDone)) showFresh();
      refreshMarks();
      refreshToday();
    } else if (p === 'scrapbook') {
      const my = ++gen;
      drawScrapbook(current, await bridge.send('scrapbook', { folder, repick: true }), false, my);
    } else if (p === 'search') {
      if (current.querySelector('.cell')) refreshMarks();
    } else if (!p.startsWith('story:')) load(false);
  }
  bridge.on('images', (sig) => {
    // 사진만 새로 채워졌으면 조용히 반영(새 소식 띠가 떠 있으면 그대로 둠)
    if (!isIssue(page) || $('.fresh', detail)) return;
    if (isLive(page) && sig && sig.revision !== seen.revision) return;
    quietImages();
  });
  // 열린 창을 다른 지면으로(묶음 알림을 누르면 section:<id>)
  bridge.on('go', (p) => { hideFresh(); go(String(p || 'today')); });
  bridge.on('shown', () => bridge.send('sidebar').then(renderSide));
  bridge.on('photos', (map) => { if (isIssue(page) && map) patchPhotos(map); });

  // MARK: 키보드 탐색(H-03, 맥 NavKey): ↓/J ↑/K 고르기(끝에서 멈춤) · ⏎ 열기 · S 나중에 읽기 · O 브라우저(읽음 처리) · M 읽음/안 읽음
  // 고를 수 있는 것은 지면에 보이는 순서의 표지·카드(data-nav). 메뉴·이름 묻는 창이 떠 있으면 하지 않는다
  document.addEventListener('keydown', (e) => {
    if (e.defaultPrevented || e.isComposing || document.querySelector('.modal')) return;
    const k = navKey(e);
    if (!k || !current) return;
    const navs = [...current.querySelectorAll('[data-nav]')];
    if (!navs.length) return;
    const keys = navs.map((n) => n.dataset.nav);
    if (k === 'next' || k === 'prev') {
      e.preventDefault();
      if (e.target.matches && e.target.matches('input')) e.target.blur();   // 검색칸에서 ↓ 면 결과로
      selected = navMove(selected, keys, k === 'next' ? 1 : -1);
      navs.forEach((n) => n.classList.toggle('kbsel', n.dataset.nav === selected));
      scrollToCenter(navs.find((n) => n.dataset.nav === selected));
      return;
    }
    const key = keys.includes(selected) ? selected : (k === 'open' ? keys[0] : null);
    if (!key) return;
    // ⏎ 는 버튼에 포커스가 있으면 그 버튼이 먼저(선택이 없을 때만 첫 카드)
    if (k === 'open' && !keys.includes(selected) && e.target.closest && e.target.closest('button')) return;
    e.preventDefault();
    if (k === 'open') open(key);
    else if (k === 'save') bridge.send('toggleSaved', { key });
    else if (k === 'browser') bridge.send('browser', { key, read: true });
    else if (k === 'toggleRead') bridge.send('toggleRead', { key });
  });

  // MARK: 단축키(M-20): Ctrl+1 오늘 · 2 이번 주 · 3 스토리 · 4 스크랩북 · F 검색 · R 지금 확인 · [ ] 지면 넘기기(H-04)
  document.addEventListener('keydown', (e) => {
    if (!e.ctrlKey || e.altKey || e.shiftKey || e.metaKey) return;
    // H-04: Ctrl+[ · Ctrl+] 옆 목록 순서대로 이전·다음 지면(끝이면 앱이 경고음)
    if (e.code === 'BracketLeft' || e.code === 'BracketRight') {
      e.preventDefault();
      bridge.send('flip', { page, back: e.code === 'BracketLeft' }).then((to) => { if (to) go(to); });
      return;
    }
    const k = e.key.toLowerCase();
    const to = { 1: 'today', 2: 'week', 3: 'stories', 4: 'scrapbook', f: 'search' }[k];
    if (to) { e.preventDefault(); if (to === 'search' && page === 'search') { const i = $('#sq', current); if (i) i.focus(); } else go(to); }
    else if (k === 'r') { e.preventDefault(); bridge.send('check'); }
  }, true);

  // 첫 지면: 주소 ?page=… (앱이 열 때 정함 — 묶음 알림이면 section:<id>), 없으면 오늘
  const first = new URLSearchParams(location.search).get('page') || 'today';
  bridge.send('ready').then((s) => { renderSide(s); go(first, { force: true }); });
})();
