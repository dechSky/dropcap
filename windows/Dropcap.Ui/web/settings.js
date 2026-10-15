// 설정 창(P 절·K 절·G-13). 값 고르기·검사·저장은 앱(SettingsPage.cs)이 하고 여기서는 그리기만.
(() => {
  const { ic, esc } = window.ui;
  const $ = (s) => document.querySelector(s);
  const $$ = (s) => document.querySelectorAll(s);

  // ui.js 표에 없는 아이콘(맥 기호 이름에 맞춤)
  const X = {
    grid: '<rect x="4" y="4" width="7" height="7" rx="1.5"/><rect x="13" y="4" width="7" height="7" rx="1.5"/><rect x="4" y="13" width="7" height="7" rx="1.5"/><rect x="13" y="13" width="7" height="7" rx="1.5"/>',
    antenna: '<circle cx="12" cy="10" r="1.6" fill="currentColor"/><path d="M12 11.6V21M8.5 6.5a5 5 0 0 0 0 7M15.5 6.5a5 5 0 0 1 0 7M5.7 3.7a9 9 0 0 0 0 12.6M18.3 3.7a9 9 0 0 1 0 12.6"/>',
    'filter.circle': '<circle cx="12" cy="12" r="9"/><path d="M7.5 9h9M9.5 12.5h5M11 16h2"/>',
    'bell.fill': '<path fill="currentColor" d="M6 16V11a6 6 0 0 1 12 0v5l1.5 2h-15z"/><path d="M10 20a2 2 0 0 0 4 0"/>',
    warn: '<path fill="currentColor" stroke="none" d="M10.3 4.2a2 2 0 0 1 3.4 0l7.5 13a2 2 0 0 1-1.7 3H4.5a2 2 0 0 1-1.7-3z"/><path stroke="var(--bg,#fff)" stroke-width="2" d="M12 9.5v4.5M12 17.2v.1"/>',
    'check.circle': '<circle cx="12" cy="12" r="9" fill="currentColor" stroke="none"/><path stroke="var(--bg,#fff)" stroke-width="2" d="M8 12.3l2.8 2.8L16.3 9.5"/>',
  };
  const sic = (name) => X[name]
    ? `<i class="ic"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">${X[name]}</svg></i>`
    : ic(name);
  $$('[data-sic]').forEach((el) => { el.outerHTML = sic(el.dataset.sic); });

  let view = null;
  let adding = false;
  let addError = null;
  let kwFilled = false;

  const refresh = () => bridge.send('view').then(render);
  const run = (cmd, args = {}) => bridge.send(cmd, args).then(refresh, (e) => { ui.toast(e.message); refresh(); });

  // 고르기 단추 채우기(값이 같으면 다시 만들지 않음)
  function fillSelect(key, options, value) {
    const sel = $(`select[data-set="${key}"]`);
    const html = options.map((o) => `<option value="${esc(o.id ?? o.value)}">${esc(o.label)}</option>`).join('');
    if (sel.dataset.html !== html) { sel.innerHTML = html; sel.dataset.html = html; }
    sel.value = String(value);
  }
  function setSwitch(key, on) { $(`input[data-set="${key}"]`).checked = !!on; }
  function enable(key, on) {
    const el = $(`[data-set="${key}"]`);
    el.disabled = !on;
    el.closest('.row').classList.toggle('off', !on);
  }

  function render(v) {
    view = v;
    // 일반(P-01~P-05)
    const g = v.general;
    fillSelect('style', g.styles, g.style);
    fillSelect('position', g.positions, g.position);
    fillSelect('interval', g.intervals, g.interval);
    setSwitch('sound', g.sound);
    setSwitch('pretendard', g.pretendard);
    setSwitch('launchAtLogin', g.launchAtLogin);
    // 회의·발표 중에는 조용히(N-25): 캘린더는 지원하지 않으면 꺼 두고 이유를
    setSwitch('autoQuietFullscreen', g.autoQuietFullscreen);
    setSwitch('autoQuietSharing', g.autoQuietSharing);
    setSwitch('autoQuietCalendar', g.autoQuietCalendar);
    enable('autoQuietCalendar', g.calendarSupported);
    $('#calendarNote').hidden = !g.calendarNote;
    $('#calendarNote').textContent = g.calendarNote || '';
    $('#autoQuietNote').textContent = g.autoQuietNote;
    // 내 기록(P-08)
    $('#backupIntro').textContent = g.backup.intro;
    $('#backupNote').textContent = g.backup.note;
    $('#undoImport').hidden = !g.backup.canUndo;
    $('#backupMsg').hidden = !g.backup.message;
    $('#backupMsg').textContent = g.backup.message || '';
    fillSelect('translateEngine', g.translateEngines, g.translateEngine);
    $('#engineNote').textContent = g.translationNote;
    $('#summary').textContent = g.summary;
    // 분야(G-13)
    renderSections(v.sections);
    // 스크랩북(I-05·I-06)
    renderScrapbook(v.scrapbook);
    // 구독(P-06)
    $('#sourceLists').innerHTML = sources(v.sources);
    $('#addBtn').textContent = adding ? '찾는 중…' : '구독';
    $('#addBtn').disabled = adding || !$('#newURL').value.trim();
    $('#addError').hidden = !addError;
    $('#addError').textContent = addError || '';
    // 거르기(P-07)
    const f = v.filters;
    if (!kwFilled || !document.activeElement.classList.contains('kw')) {
      $('#must').value = f.must;
      $('#mute').value = f.mute;
      $('#watch').value = f.watch;
      kwFilled = true;
    }
    setSwitch('quietEnabled', f.quietEnabled);
    fillSelect('quietStart', f.hours, f.quietStart);
    fillSelect('quietEnd', f.hours, f.quietEnd);
    enable('quietStart', f.quietEnabled);
    enable('quietEnd', f.quietEnabled);
    setSwitch('digestEnabled', f.digestEnabled);
    fillSelect('digestHour', f.digestHours, f.digestHour);
    enable('digestHour', f.digestEnabled);
    $('#hotkeys').innerHTML = f.hotkeys.map((h) => `<div class="row"><span class="lb">${esc(h.label)}</span><span class="keys">${esc(h.keys)}</span></div>`).join('');
    // 목록·매거진·읽기 창 키(H-03~H-05)
    $('#navkeys').innerHTML = f.navKeys.map((h) => `<div class="row"><span class="lb">${esc(h.label)}</span><span class="keys">${esc(h.keys)}</span></div>`).join('');
  }

  // 스크랩북 탭(맥 ScrapbookSettingsView): 켜려는데 폴더가 없으면 앱이 먼저 폴더 고르는 창을 띄운다
  let copied = null;
  function renderScrapbook(x) {
    $('#scrapExport').checked = x.enabled;
    $('#scrapFolder').textContent = x.folder;
    $('#scrapFolder').title = x.folder;
    $('#scrapFolder').classList.toggle('dim', !x.hasFolder);
    $('#chooseScrapFolder').textContent = x.choose;
    $('#forgetScrapFolder').hidden = !x.hasFolder;
    $('#scrapError').hidden = !x.error;
    $('#scrapError').innerHTML = x.error ? `${sic('warn')}<span>${esc(x.error)}</span>` : '';
    $('#scrapNote').textContent = x.exportNote;
    $('#scrapExportNow').disabled = !x.canSaveNow;
    $('#addUrlHow').textContent = x.addUrl;
    $('#bookmarkletNote').textContent = x.bookmarkletNote;
    $('#copyBookmarklet').innerHTML = copied ? `${ic('check')}<span>복사했어요</span>` : `${ic('copy')}<span>북마클릿 코드 복사</span>`;
  }
  $('#scrapExport').addEventListener('change', (e) => run('scrapExport', { on: e.target.checked }));
  ['chooseScrapFolder', 'forgetScrapFolder'].forEach((id) => $('#' + id).addEventListener('click', () => run(id)));
  $('#scrapExportNow').addEventListener('click', () => run('scrapExportNow'));
  $('#copyBookmarklet').addEventListener('click', () => {
    bridge.send('copyBookmarklet').then(() => {
      clearTimeout(copied);
      copied = setTimeout(() => { copied = null; view && renderScrapbook(view.scrapbook); }, 1600);
      view && renderScrapbook(view.scrapbook);
    });
  });

  // 분야 탭: 고른 분야마다 묶음 하나(모드 나눔 단추 + 즉시·묶음이면 묶음 시각, 즉시면 하루 상한)
  const stepper = (attrs, value, min, max) =>
    `<span class="step" ${attrs}><button data-d="-1" title="줄이기"${value <= min ? ' disabled' : ''}>−</button><button data-d="1" title="늘리기"${value >= max ? ' disabled' : ''}>+</button></span>`;

  function renderSections(x) {
    $('#secSummary').textContent = x.summary;
    $('#secRows').innerHTML = x.rows.map((r) => {
      const seg = x.modes.map((m) => `<button data-mode="${esc(m.id)}" class="${m.id === r.mode ? 'on' : ''}" title="${esc(m.help)}">${esc(m.label)}</button>`).join('');
      const hours = x.bundleHours.map((h) => `<option value="${h.value}"${h.value === r.bundleHour ? ' selected' : ''}>${esc(h.label)}</option>`).join('');
      const opts = r.mode === 'magazine' ? '' : `<div class="row sec-opts">
          <label class="row-inline" title="${esc(r.bundleHelp)}"><span class="lb2">묶음 시각</span> <select data-pol="bundleHour">${hours}</select></label>
          ${r.mode === 'instant' ? `<span class="grow"></span><span>${esc(r.capLabel)}</span>${stepper('data-pol="dailyCap"', r.dailyCap, x.capMin, x.capMax)}` : ''}
        </div>`;
      return `<div class="group sec-group" data-id="${esc(r.id)}">
        <div class="row sec">
          <span class="tile" style="--c:${esc(r.color)}">${ic(r.icon)}</span>
          <div class="body"><div class="name">${esc(r.name)}</div><div class="sub">${esc(r.sub)}</div></div>
          <span class="seg" role="radiogroup" title="${esc(r.modeHelp)}">${seg}</span>
        </div>${opts}
      </div>`;
    }).join('');
    $('#limits').innerHTML = x.limits.map((l) =>
      `<div class="row"><span class="lb">${esc(l.label)}</span>${stepper(`data-limit="${esc(l.key)}"`, l.value, l.min, l.max)}</div>`).join('');
    $('#hiddenBox').innerHTML = x.hidden.length ? `<h3>숨긴 출처</h3><div class="group">${x.hidden.map((h) =>
      `<div class="row" data-id="${esc(h.id)}"><span class="lb">${esc(h.name)}</span><button class="ib text" data-act="unhide">다시 보이기</button></div>`).join('')}</div>` : '';
  }

  function sources(s) {
    const group = (label, rows) => `<h3>${esc(label)}</h3><div class="group">${rows}</div>`;
    const custom = s.custom.length
      ? s.custom.map(sourceRow).join('')
      : '<div class="row empty-row">아래 추천 채널을 골라 보세요.</div>';
    return group(`구독 중인 채널 ${s.custom.length}`, custom)
      + s.tiers.map((t) => group(t.label, t.rows.map(sourceRow).join(''))).join('')
      + s.catalog.map((c) => group(c.label, c.rows.map(catalogRow).join(''))).join('');
  }

  const badge = (r) => r.kindLabel ? `<span class="badge">${ic('kind.' + r.kind)}${esc(r.kindLabel)}</span>` : '';

  function sourceRow(r) {
    return `<div class="row src" data-id="${esc(r.id)}">
      <span class="mono" style="--c:${esc(r.color)}">${esc(r.initial)}</span>
      <div class="body">
        <div class="name"><b>${esc(r.name)}</b>${badge(r)}${r.aiOnly ? '<span class="ai">AI 글만</span>' : ''}${r.error ? `<span class="warn" title="${esc(r.error)}">${sic('warn')}</span>` : ''}</div>
        ${r.sub ? `<div class="sub" title="${esc(r.sub)}">${esc(r.sub)}</div>` : ''}
      </div>
      <button class="ib${r.notify ? ' on' : ''}" data-act="notify" title="${esc(r.notifyHelp)}"${r.enabled ? '' : ' disabled'}>${sic(r.notify ? 'bell.fill' : 'bell.slash')}</button>
      <input type="checkbox" class="switch small" data-act="enable"${r.enabled ? ' checked' : ''} title="${r.enabled ? '켜짐' : '꺼짐'}">
      ${r.removable ? `<button class="ib del" data-act="remove" title="구독 해지">${ic('trash')}</button>` : ''}
    </div>`;
  }

  function catalogRow(r) {
    const right = r.subscribed
      ? `<span class="subbed">${sic('check.circle')}구독 중</span>`
      : `<button class="btn small" data-act="subscribe"${r.subscribing ? ' disabled' : ''}>${r.subscribing ? '확인 중…' : '구독'}</button>`;
    return `<div class="row src" data-id="${esc(r.id)}">
      <span class="mono" style="--c:${esc(r.color)}">${esc(r.initial)}</span>
      <div class="body">
        <div class="name"><b>${esc(r.name)}</b>${badge(r)}</div>
        <div class="sub">${esc(r.sub)}</div>
      </div>
      ${right}
    </div>`;
  }

  // 탭(맥 TabView). 처음 탭은 settings.html#sources 처럼 주소 뒤에, 열린 창은 앱이 'tab' 알림으로 바꾼다
  function selectTab(name) {
    if (!document.querySelector(`.tab[data-tab="${name}"]`)) name = 'general';
    $$('#tabs button').forEach((b) => b.classList.toggle('on', b.dataset.tab === name));
    $$('.tab').forEach((t) => { t.hidden = t.dataset.tab !== name; });
    $('#pane').scrollTop = 0;
  }
  $('#tabs').addEventListener('click', (e) => { const b = e.target.closest('button'); if (b) selectTab(b.dataset.tab); });
  bridge.on('tab', (t) => selectTab(t));
  selectTab(location.hash.slice(1));

  // 설정 값(고르기·켜고 끄기)
  $('#pane').addEventListener('change', (e) => {
    const el = e.target;
    if (el.dataset.set) {
      const value = el.type === 'checkbox' ? el.checked : /^\d+$/.test(el.value) ? Number(el.value) : el.value;
      run('set', { key: el.dataset.set, value });
      return;
    }
    const row = el.closest('.src');
    if (row && el.dataset.act === 'enable') run('setEnabled', { id: row.dataset.id, on: el.checked });
  });
  $('#preview').addEventListener('click', () => bridge.send('preview'));

  // 분야 탭: 모드·묶음 시각·하루 상한·알림 양·숨긴 출처·다시 고르기
  const tab = $('.tab[data-tab="sections"]');
  tab.addEventListener('click', (e) => {
    const b = e.target.closest('button');
    if (!b) return;
    const sec = b.closest('.sec-group');
    if (b.dataset.mode && sec) { if (!b.classList.contains('on')) run('setPolicy', { id: sec.dataset.id, key: 'mode', value: b.dataset.mode }); return; }
    const step = b.closest('.step');
    if (step && b.dataset.d) {
      const d = Number(b.dataset.d);
      if (step.dataset.pol && sec) {
        const r = view.sections.rows.find((x) => x.id === sec.dataset.id);
        if (r) run('setPolicy', { id: r.id, key: step.dataset.pol, value: r.dailyCap + d });
      } else if (step.dataset.limit) {
        const l = view.sections.limits.find((x) => x.key === step.dataset.limit);
        if (l) run('set', { key: l.key, value: l.value + d });
      }
      return;
    }
    if (b.dataset.act === 'unhide') run('unhide', { id: b.closest('.row').dataset.id });
  });
  tab.addEventListener('change', (e) => {
    const sec = e.target.closest('.sec-group');
    if (sec && e.target.dataset.pol) { e.stopPropagation(); run('setPolicy', { id: sec.dataset.id, key: e.target.dataset.pol, value: Number(e.target.value) }); }
  });
  $('#reonboard').addEventListener('click', () => bridge.send('onboarding'));
  $('#openMag').addEventListener('click', () => bridge.send('magazine'));

  // 출처 줄의 단추: 알림 종·해지·구독
  $('#sourceLists').addEventListener('click', (e) => {
    const b = e.target.closest('button[data-act]');
    const row = b && b.closest('.src');
    if (!row) return;
    const id = row.dataset.id;
    const r = [...view.sources.custom, ...view.sources.tiers.flatMap((t) => t.rows)].find((x) => x.id === id);
    if (b.dataset.act === 'notify' && r) run('setNotify', { id, on: !r.notify });
    else if (b.dataset.act === 'remove') run('remove', { id });
    else if (b.dataset.act === 'subscribe') {
      b.disabled = true;
      b.textContent = '확인 중…';
      bridge.send('subscribe', { id }).then((res) => { addError = res && res.error; refresh(); }, (err) => { addError = err.message; refresh(); });
    }
  });

  // 채널 추가(K-02): 실패하면 이유를 칸 아래에 빨갛게
  $('#newURL').addEventListener('input', () => { $('#addBtn').disabled = adding || !$('#newURL').value.trim(); });
  $('#addForm').addEventListener('submit', (e) => {
    e.preventDefault();
    const input = $('#newURL').value.trim();
    if (adding || !input) return;
    adding = true;
    addError = null;
    view && render(view);
    bridge.send('addChannel', { input }).then((res) => res && res.error, (err) => err.message).then((err) => {
      adding = false;
      addError = err || null;
      if (!err) $('#newURL').value = '';
      refresh();
    });
  });

  // 낱말 저장(C-14): 입력이 멈추고 0.6초 뒤 저장·이미 받은 목록에도 적용. Enter·저장 단추·칸을 떠날 때는 바로(정리한 글자로 다시 채움)
  let kwTimer;
  function saveKeywords(tidy = true) {
    clearTimeout(kwTimer);
    bridge.send('keywords', { must: $('#must').value, mute: $('#mute').value, watch: $('#watch').value }).then((r) => {
      if (tidy) {
        $('#must').value = r.must;
        $('#mute').value = r.mute;
        $('#watch').value = r.watch;
        ui.toast('저장했습니다');
      }
      refresh();
    });
  }
  $$('.kw').forEach((el) => {
    el.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); saveKeywords(); } });
    el.addEventListener('input', () => { clearTimeout(kwTimer); kwTimer = setTimeout(() => saveKeywords(false), 600); });
    el.addEventListener('blur', () => { if (kwTimer) saveKeywords(false); });
  });
  $('#saveKw').addEventListener('click', () => saveKeywords());

  // 내 기록 내보내기·가져오기·되돌리기(P-08): 대화상자는 앱이 띄우고, 결과 문구는 다시 그릴 때 보임
  ['exportBackup', 'importBackup', 'undoImport'].forEach((id) => $('#' + id).addEventListener('click', () => run(id)));

  document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !document.querySelector('.pop')) bridge.send('close'); });

  bridge.on('shown', () => bridge.send('ready').then(render));
  bridge.on('changed', refresh);
  bridge.send('ready').then(render);
})();
