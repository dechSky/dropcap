// 읽기 창(R 절). 본문·번역·요약·읽는 시간은 앱(ReaderPage.cs)이 만들어 보내고, 여기서는 그리기만.
// 번역/원문 전환(R-05)은 창마다 따로라서 이 화면이 들고 있는다.
(() => {
  const { ic, esc, popMenu, popUnder, closeMenu } = window.ui;
  const $ = (s) => document.querySelector(s);
  const key = new URLSearchParams(location.search).get('key') || '';
  let doc = null;          // 앱이 보낸 보기 데이터
  let showOriginal = false;
  let speaking = false;
  let speakPoll = null;
  const loaded = new Set(); // 이미 불러온 사진(다시 그려도 깜빡이지 않게)
  const broken = new Set();

  const send = (cmd, args = {}) => bridge.send(cmd, { key, ...args });

  // MARK: 그리기
  function render(d) {
    doc = d;
    if (!d.translated) showOriginal = false;
    document.title = d.item.source;
    draw();
  }

  function draw() {
    const d = doc;
    const it = d.item;
    document.body.className = `cat-${it.category}`;
    document.body.style.setProperty('--accent-c', it.color);
    document.documentElement.style.setProperty('--fs', d.fontSize + 'px');
    drawBar();
    drawCover();
    drawHead();
    drawFree();
    const c = $('#content');
    if (d.phase === 'loading') {
      // 본문을 받는 동안에도 빈 화면 대신 피드가 준 요약을 먼저 보여 준다
      if (!c.querySelector('.skeleton')) c.innerHTML = (d.feedSummary ? `<div class="lede">${esc(d.feedSummary)}</div>` : '') + skeleton('기사를 불러오는 중');
      return;
    }
    if (d.phase === 'failed') { c.innerHTML = failed(); return; }
    // 번역 중·끝: 요약 상자 → (번역 중이면 안내) → 본문
    const firstBody = !c.querySelector('.body');
    c.innerHTML = points()
      + (d.phase === 'translating' ? `<div class="working pulse">${ic('translate')}<span>한국어로 바꾸는 중 — 위에서부터 차례로 바뀝니다</span></div>` : '')
      + `<div class="body"${firstBody ? '' : ' style="animation:none"'}>${blocks()}</div>`;
    hookImages(c);
  }

  function drawBar() {
    const d = doc;
    const m = d.marks;
    $('#src').textContent = d.item.source;
    $('#lang').hidden = !d.translated;
    document.querySelectorAll('#lang button').forEach((b) => b.classList.toggle('on', (b.dataset.orig === '1') === showOriginal));
    $('#smaller').disabled = d.fontSize <= 13;
    $('#larger').disabled = d.fontSize >= 26;
    const sp = $('#speak');
    sp.disabled = d.phase === 'loading' || d.phase === 'failed';
    sp.innerHTML = ic(speaking ? 'speaker.stop' : 'speaker');
    sp.title = speaking ? '읽기 멈춤' : '소리 내어 읽기';
    sp.classList.toggle('on', speaking);
    $('#scrap').classList.toggle('done', m.scrapped);
    const sv = $('#save');
    sv.innerHTML = ic(m.saved ? 'bookmark.fill' : 'bookmark');
    sv.title = m.saved ? '저장 취소' : '나중에 읽기로 저장';
    sv.classList.toggle('on', m.saved);
  }

  // 표지: 피드의 대표 사진, 없으면 본문의 첫 사진(앱이 골라 보냄). 못 불러오면 자리째 숨김.
  function drawCover() {
    const box = $('#cover');
    const src = doc.cover && !broken.has(doc.cover) ? doc.cover : '';
    if (box.dataset.src === src) return;
    box.dataset.src = src;
    const url = bridge.img(src);
    box.className = url ? 'cover' + (loaded.has(src) ? ' loaded' : '') : '';
    box.innerHTML = url ? `<img alt="" src="${esc(url)}" data-src="${esc(src)}">` : '';
    hookImages(box);
  }

  // 사진이 오면 서서히 보이고, 못 오면 자리째 지운다(R-18)
  function hookImages(root) {
    root.querySelectorAll('img[data-src]').forEach((img) => {
      const holder = img.parentElement;
      const src = img.dataset.src;
      const ok = () => { loaded.add(src); holder.classList.add('loaded'); };
      const bad = () => {
        broken.add(src);
        if (holder.id === 'cover') { holder.className = ''; holder.innerHTML = ''; } else holder.closest('.blk').remove();
      };
      if (img.complete && img.naturalWidth) ok();
      else { img.addEventListener('load', ok, { once: true }); img.addEventListener('error', bad, { once: true }); }
    });
  }

  function drawHead() {
    const d = doc;
    const it = d.item;
    const min = showOriginal ? d.minutes.original : d.minutes.shown;
    const title = showOriginal ? d.originalTitle : d.title;
    $('#head').innerHTML = `
      <div class="meta">
        <span class="mono" style="--c:${esc(it.color)}">${esc(it.initial)}</span>
        <span class="name">${esc(it.source)}</span>
        <span class="tier">${esc(it.tierLabel)}</span>
        ${d.date ? `<span class="dim">${esc(d.date)}</span>` : ''}
        ${min ? `<span class="dim" title="읽는 시간(한국어 분당 약 500자 기준)">${ic('clock')}약 ${min}분</span>` : ''}
      </div>
      <h1>${esc(title)}</h1>
      ${!showOriginal && d.originalTitle !== d.title ? `<div class="orig">${esc(d.originalTitle)}</div>` : ''}
      ${d.byline ? `<div class="byline">${esc(d.byline)}</div>` : ''}
      ${d.translated && d.engine ? `<span class="engine">${ic('translate')}${esc(d.engine)}</span>` : ''}`;
  }

  // 같은 소식을 무료로 읽기(G-15, 맥 FreeAlternativesBox): 막힌 기사면 같은 스토리의 열리는 보도를 먼저 권한다. 원문 링크는 그대로.
  function drawFree() {
    const d = doc;
    const box = $('#free');
    const alts = d.alternatives || [];
    if (!d.freeReason || !alts.length) { box.className = ''; box.innerHTML = ''; return; }
    box.className = 'free';
    box.innerHTML = `
      <div class="why">${ic('lock.fill')}<span>${esc(d.freeReason)}</span></div>
      <div class="lead">같은 소식을 무료로 읽기: ${esc(alts.map((x) => x.source).join('·'))}</div>
      <div class="rows">${alts.map((x) => `<button class="alt" data-alt="${esc(x.key)}" title="${esc(x.title)}">
        <b style="color:${esc(x.color)}">${esc(x.source)}</b><span class="t">${esc(x.title)}</span>${ic('arrow.up.right')}</button>`).join('')}</div>
      <button class="link" data-act="openOriginal">원문 그대로 열기</button>`;
  }

  function skeleton(label) {
    const paras = [0, 1, 2].map((p) => `<div class="para">${[0, 1, 2, 3].map((l) =>
      `<div class="ln" style="${l === 3 ? `max-width:${260 + p * 60}px` : ''}"></div>`).join('')}</div>`).join('');
    return `<div class="skeleton"><div class="lbl"><span class="dots"><i></i><i></i><i></i></span>${esc(label)}</div><div class="lines">${paras}</div></div>`;
  }

  // 3줄 요약(T-06): 요약이 있거나 요약 중일 때만
  function points() {
    const d = doc;
    if (!d.summary && !d.summarizing) return '';
    const body = d.summary
      ? d.summary.map((p) => `<div class="pt"><b>•</b><span>${esc(p)}</span></div>`).join('')
      : '<div class="wait pulse">요약하는 중…</div>';
    return `<div class="points"><span class="t">${ic('sparkles')}3줄 요약</span>${body}</div>`;
  }

  const textOf = (b) => (showOriginal && b.original) || b.text;
  const scrapOf = (text) => doc.marks.scraps.find((s) => s.quote === text);

  function blocks() {
    const list = doc.blocks;
    return list.map((b, n) => {
      if (b.type === 'img') {
        if (!b.src || broken.has(b.src)) return '';
        const url = bridge.img(b.src);
        if (!url) return '';
        return `<div class="blk img"><div class="figure${loaded.has(b.src) ? ' loaded' : ''}"><img alt="" src="${esc(url)}" data-src="${esc(b.src)}"></div></div>`;
      }
      const text = textOf(b);
      const can = b.scrap && text.length > 0;
      const scrapped = can && !!scrapOf(text);
      const cls = ['blk', b.type, can ? 'can' : '', scrapped ? 'scrapped' : '', b.type === 'li' && n > 0 && list[n - 1].type === 'li' ? 'cont' : ''].join(' ');
      const cut = can ? `<button class="cut" title="${scrapped ? '스크랩한 문단 — 눌러서 폴더·메모 바꾸기' : '이 문단 스크랩'}">${ic('scissors')}</button>` : '';
      let inner;
      if (b.type === 'pre') inner = `<pre>${esc(text)}</pre>`;
      else if (b.type === 'li') inner = `<span class="dot"></span><span>${esc(text)}</span>`;
      else inner = esc(text);
      return `<div class="${cls}" data-i="${b.i}"><div class="in">${cut}${inner}</div></div>`;
    }).join('');
  }

  // 실패 화면(R-12): 요약 번역(없으면 피드 요약) + 이유 + 원문 열기(먼저) · 번역된 웹페이지(외국어 기사만)
  function failed() {
    const d = doc;
    const text = d.fallback || d.feedSummary;
    const why = d.blockedHost
      ? '이 사이트는 앱에서 본문을 가져가지 못하게 막아 두었습니다. 위는 피드가 준 요약입니다.'
      : '이 기사는 본문을 추리지 못했습니다(유료 기사·차단 등). 위는 피드가 준 요약입니다.';
    return `<div class="failed">
      ${text ? `<div class="sum">${esc(text)}</div>` : ''}
      <div class="why">${why}</div>
      <div class="btns">
        <button class="btn primary" data-act="openOriginal">원문 열기</button>
        ${d.translatedPage ? '<button class="btn" data-act="translatedPage">번역된 웹페이지로 보기</button>' : ''}
      </div></div>`;
  }

  // MARK: 저장·스크랩 표시
  // 본문을 다시 그리지 않고 표시만 바꾼다(고른 글·스크롤이 그대로 남게)
  function applyMarks(m) {
    if (!doc) return;
    doc.marks = m;
    drawBar();
    document.querySelectorAll('.blk.can').forEach((blk) => {
      const b = doc.blocks.find((x) => x.i === +blk.dataset.i);
      const on = !!(b && scrapOf(textOf(b)));
      blk.classList.toggle('scrapped', on);
      blk.querySelector('.cut').title = on ? '스크랩한 문단 — 눌러서 폴더·메모 바꾸기' : '이 문단 스크랩';
    });
  }
  const refreshMarks = () => send('marks').then(applyMarks);

  let flashTimer;
  function flash(msg) {
    const f = $('#flash');
    f.innerHTML = ic('scissors') + `<span>${esc(msg)}</span>`;
    f.hidden = false;
    f.classList.remove('out');
    f.style.animation = 'none'; void f.offsetWidth; f.style.animation = '';
    clearTimeout(flashTimer);
    flashTimer = setTimeout(() => { f.classList.add('out'); flashTimer = setTimeout(() => { f.hidden = true; }, 250); }, 2200);
  }

  function bounce() {
    const s = $('#scrap');
    s.classList.remove('bounce'); void s.offsetWidth; s.classList.add('bounce');
  }

  const scrapArticle = (collection) => send('scrapArticle', collection ? { collection } : {}).then((r) => {
    bounce();
    flash(`기사를 ‘${r.collection}’에 스크랩했어요`);
    refreshMarks();
  });

  // 끌어서 고른 글만 스크랩(Ctrl+Shift+S)
  function scrapSelection() {
    const text = String(window.getSelection() || '').trim();
    if (!text) { flash('먼저 스크랩할 글을 끌어서 고르세요'); return; }
    send('scrapSelection', { quote: text }).then((r) => {
      flash(`고른 부분을 ‘${r.collection}’에 스크랩했어요`);
      refreshMarks();
    });
  }

  // 새 스크랩 폴더(이름을 받아 만들고 그 폴더에 스크랩)
  function newFolder() {
    const v = document.createElement('div');
    v.className = 'veil';
    v.innerHTML = `<div class="dialog"><b>새 스크랩 폴더</b><input placeholder="폴더 이름" maxlength="60">
      <div class="row"><button class="btn" data-x="cancel">취소</button><button class="btn primary" data-x="ok">스크랩</button></div></div>`;
    document.body.appendChild(v);
    const input = v.querySelector('input');
    input.focus();
    const done = (ok) => {
      const n = input.value.trim();
      v.remove();
      if (ok && n) send('newCollection', { name: n }).then((r) => { if (r) { bounce(); flash(`기사를 ‘${r.collection}’에 스크랩했어요`); refreshMarks(); } });
    };
    v.addEventListener('click', (e) => { const x = e.target.closest('[data-x]'); if (x) done(x.dataset.x === 'ok'); else if (e.target === v) done(false); });
    input.addEventListener('keydown', (e) => { if (e.key === 'Enter') done(true); if (e.key === 'Escape') { e.stopPropagation(); done(false); } });
  }

  // 문단을 스크랩한 뒤: 담긴 폴더, 폴더 바꾸기, 메모, 되돌리기
  let sheet = null;
  function closeSheet(save = true) {
    if (!sheet) return;
    const { el, blk, quote, memo } = sheet;
    const m = el.querySelector('textarea');
    if (save && m && m.value !== memo) send('updateScrap', { quote, memo: m.value });
    el.remove();
    blk.classList.remove('open');
    sheet = null;
  }
  function openSheet(blk, quote) {
    closeSheet();
    const s = scrapOf(quote);
    const el = document.createElement('div');
    el.className = 'sheet';
    el.innerHTML = s ? `
      <div class="ok">${ic('check')}<span>‘${esc(s.collection)}’에 스크랩했어요</span></div>
      <label>폴더<select>${doc.marks.collections.map((c) => `<option${c === s.collection ? ' selected' : ''}>${esc(c)}</option>`).join('')}</select></label>
      <textarea placeholder="메모 (선택)">${esc(s.memo)}</textarea>
      <div class="row"><button class="btn danger" data-x="undo">되돌리기</button><span class="grow"></span><button class="btn primary" data-x="done">완료</button></div>`
      : '<div class="why">스크랩을 지웠어요</div>';
    document.body.appendChild(el);
    blk.classList.add('open');
    sheet = { el, blk, quote, memo: s ? s.memo : '' };
    // 가위 단추 오른쪽에(맥 popover 처럼), 창 밖으로 나가지 않게
    const r = blk.querySelector('.cut').getBoundingClientRect();
    const h = el.getBoundingClientRect().height;
    el.style.left = Math.min(r.right + 8, innerWidth - 288) + 'px';
    el.style.top = Math.max(8, Math.min(r.top - 10, innerHeight - h - 8)) + 'px';
    if (!s) return;
    el.querySelector('select').addEventListener('change', (e) => {
      send('updateScrap', { quote, collection: e.target.value });
      el.querySelector('.ok span').textContent = `‘${e.target.value}’에 스크랩했어요`;
    });
    el.querySelector('textarea').addEventListener('keydown', (e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); closeSheet(); } });
    el.addEventListener('click', (e) => {
      const x = e.target.closest('[data-x]');
      if (!x) return;
      if (x.dataset.x === 'undo') { send('removeScrap', { quote }); closeSheet(false); } else closeSheet();
    });
  }
  document.addEventListener('mousedown', (e) => { if (sheet && !sheet.el.contains(e.target) && !e.target.closest('.cut')) closeSheet(); }, true);

  // MARK: 누르기
  $('#content').addEventListener('click', (e) => {
    const act = e.target.closest('[data-act]');
    if (act) { send(act.dataset.act); return; }
    const cut = e.target.closest('.cut');
    if (!cut) return;
    const blk = cut.closest('.blk');
    const b = doc.blocks.find((x) => x.i === +blk.dataset.i);
    const text = textOf(b);
    if (sheet && sheet.blk === blk) { closeSheet(); return; }
    if (scrapOf(text)) { openSheet(blk, text); return; }
    send('scrapParagraph', { index: b.i, original: showOriginal }).then((r) => send('marks').then((m) => {
      applyMarks(m);
      openSheet(blk, r.quote);
    }));
  });

  $('#free').addEventListener('click', (e) => {
    const alt = e.target.closest('[data-alt]');
    if (alt) { send('openAlternative', { alt: alt.dataset.alt }); return; }
    const act = e.target.closest('[data-act]');
    if (act) send(act.dataset.act);
  });

  // 오른쪽 클릭: 고른 글이 있으면 복사·스크랩, 문단 위면 문단 스크랩·다른 폴더·복사
  $('#scroll').addEventListener('contextmenu', (e) => {
    if (!doc) return;
    const sel = String(window.getSelection() || '').trim();
    const items = sel ? [
      { label: '복사', icon: 'copy', run: () => send('copy', { text: sel }) },
      { label: '선택한 부분 스크랩 (Ctrl+Shift+S)', icon: 'scissors', run: scrapSelection },
    ] : [];
    const blk = e.target.closest('.blk.can');
    if (blk) {
      const b = doc.blocks.find((x) => x.i === +blk.dataset.i);
      const text = textOf(b);
      const s = scrapOf(text);
      const scrapTo = (collection) => send('scrapParagraph', { index: b.i, original: showOriginal, collection })
        .then((r) => { flash(`문단을 ‘${r.collection}’에 스크랩했어요`); refreshMarks(); });
      if (items.length) items.push('sep');
      items.push(
        s ? { label: '스크랩 지우기', icon: 'trash', run: () => send('removeScrap', { quote: text }) }
          : { label: '이 문단 스크랩', icon: 'scissors', run: () => scrapTo() },
        { header: '다른 폴더에 스크랩' },
        ...doc.marks.collections.map((c) => ({ label: c, icon: 'folder', run: () => scrapTo(c) })),
        'sep',
        { label: '이 문단 복사', icon: 'copy', run: () => send('copy', { text }) },
      );
    }
    if (items.length) popMenu(e.clientX, e.clientY, items);
  });

  $('#lang').addEventListener('click', (e) => {
    const b = e.target.closest('button');
    if (!b || !doc) return;
    showOriginal = b.dataset.orig === '1';
    closeSheet();
    draw();
  });

  const setFont = (delta) => {
    if (!doc) return;
    const size = Math.max(13, Math.min(26, doc.fontSize + delta));
    if (size !== doc.fontSize) send('fontSize', { size });
  };
  $('#smaller').addEventListener('click', () => setFont(-1));
  $('#larger').addEventListener('click', () => setFont(1));

  // 소리 내어 읽기(R-09): 보이는 언어로. 끝났는지는 앱에 물어 단추를 되돌린다.
  function setSpeaking(on) {
    speaking = on;
    clearInterval(speakPoll);
    if (on) speakPoll = setInterval(() => send('speaking').then((r) => { if (!r.speaking) setSpeaking(false); }), 1000);
    if (doc) drawBar();
  }
  $('#speak').addEventListener('click', () => send('speak', { original: showOriginal }).then((r) => setSpeaking(r.speaking)));

  $('#scrapMain').addEventListener('click', () => scrapArticle());
  $('#scrapMenu').addEventListener('click', () => popUnder($('#scrap'), [
    ...doc.marks.collections.map((c) => ({ label: c, icon: 'folder', run: () => scrapArticle(c) })),
    'sep',
    { label: '선택한 부분 스크랩 (Ctrl+Shift+S)', run: scrapSelection },
    { label: '새 폴더에 스크랩…', icon: 'folder.plus', run: newFolder },
  ]));
  $('#save').addEventListener('click', () => send('save').then(applyMarks));
  $('#browser').addEventListener('click', () => send('browser'));
  $('#share').addEventListener('click', () => send('share'));

  const typing = (t) => t && (t.isContentEditable || !!t.closest('input, textarea, select'));

  // J·K 다음·이전 기사(H-05, 연 목록의 순서로 같은 창에서), Esc 닫기. 입력 칸에 글을 칠 때·Ctrl/Alt/Meta 와 함께면 쓰지 않음.
  // 앞 단계(capture)에서 본다: 메뉴가 열려 있으면 ui.js 가 메뉴만 닫게 두고, 스크랩 쪽지가 열려 있으면 쪽지만 닫는다.
  document.addEventListener('keydown', (e) => {
    if (typing(e.target) || e.ctrlKey || e.altKey || e.metaKey) return;
    if (e.key === 'Escape') {
      if (document.querySelector('.pop, .veil')) return;
      e.preventDefault();
      if (sheet) closeSheet(); else send('close');
      return;
    }
    const k = (e.key || '').toLowerCase();
    if (k !== 'j' && k !== 'k') return;
    e.preventDefault();
    if (!e.repeat && doc) { closeSheet(); send('step', { dir: k === 'j' ? 1 : -1 }); }
  }, true);

  // 단축키: Ctrl+- / Ctrl+= 글자 크기(R-06), Ctrl+Shift+S 고른 부분 스크랩, Ctrl+W 창 닫기
  document.addEventListener('keydown', (e) => {
    if (typing(e.target)) return;
    if (!e.ctrlKey || e.altKey) return;
    const k = e.key.toLowerCase();
    if (k === '-' || k === '_') setFont(-1);
    else if (k === '=' || k === '+') setFont(1);
    else if (k === 's' && e.shiftKey) scrapSelection();
    else if (k === 'w') send('close');
    else return;
    e.preventDefault();
  });

  // 앱 알림: 기사 진행(번역이 위에서부터 바뀜), 저장·스크랩 바뀜, 글자 크기(열린 읽기 창 모두)
  bridge.on('article', (d) => { if (d && d.key === key) render(d); });
  bridge.on('changed', () => { if (doc) refreshMarks(); });
  bridge.on('fontSize', (d) => {
    if (!doc) return;
    doc.fontSize = d.size;
    document.documentElement.style.setProperty('--fs', d.size + 'px');
    drawBar();
  });
  window.addEventListener('blur', () => closeMenu());

  send('ready').then(render);
})();
