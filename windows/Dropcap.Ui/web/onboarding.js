// 첫 실행 관심 분야 고르기(G-03). 카드·주요 뉴스 스위치를 그리고 고른 것만 들고 있다가, 마치면 앱(OnboardingPage.cs)에 넘긴다.
(() => {
  const { ic, esc } = window.ui;
  const $ = (s) => document.querySelector(s);
  let view = null;
  const picked = new Set();
  let showMore = false;
  let busy = false;

  function render(v) {
    view = v;
    picked.clear();
    v.picked.forEach((id) => picked.add(id));
    showMore = v.showMore;
    // 주요 뉴스 흐름 스위치(기본 켬)
    const top = $('#top');
    top.hidden = !v.top;
    if (v.top) {
      top.style.setProperty('--c', v.top.color);
      top.querySelector('.tic').innerHTML = ic(v.top.icon);
      top.querySelector('b').textContent = v.top.label;
      top.querySelector('small').textContent = v.top.help;
      $('#topOn').checked = v.top.on;
    }
    $('#go').textContent = v.first ? '시작하기' : '저장';
    draw();
  }

  function card(c, fresh) {
    const on = picked.has(c.id);
    return `<button class="card${on ? ' on' : ''}${fresh ? ' new' : ''}" data-id="${esc(c.id)}" style="--c:${esc(c.color)}" aria-pressed="${on}" aria-label="${esc(c.label)}${on ? ', 고름' : ''}">
      <span class="top-row"><span class="sym">${ic(c.icon)}</span><span class="tick">${ic('check')}</span></span>
      <b>${esc(c.label)}</b><small>${esc(c.sources)}</small></button>`;
  }

  function draw(fresh = false) {
    const cards = view.cards.filter((c) => !c.more || showMore);
    $('#cards').innerHTML = cards.map((c) => card(c, fresh && c.more)).join('');
    $('#more').hidden = showMore || !view.cards.some((c) => c.more);
    count();
  }

  function count() {
    const n = view.cards.filter((c) => picked.has(c.id) && (!c.more || showMore)).length;
    $('#count').textContent = n === 0 ? '분야를 하나 이상 골라 주세요' : `${n}개 분야 · 설정 › 분야에서 언제든 바꿀 수 있어요`;
    $('#go').disabled = n === 0 || busy;
  }

  $('#cards').addEventListener('click', (e) => {
    const b = e.target.closest('.card');
    if (!b) return;
    const id = b.dataset.id;
    picked.has(id) ? picked.delete(id) : picked.add(id);
    const on = picked.has(id);
    b.classList.toggle('on', on);
    b.setAttribute('aria-pressed', on);
    count();
  });
  $('#more').addEventListener('click', () => { showMore = true; draw(true); });

  async function go() {
    if ($('#go').disabled) return;
    busy = true;
    count();
    const ids = view.cards.filter((c) => picked.has(c.id) && (!c.more || showMore)).map((c) => c.id);
    try {
      await bridge.send('choose', { ids, top: $('#topOn').checked });
    } catch (err) {
      ui.toast(err.message);
    }
    busy = false;
    count();
  }
  $('#go').addEventListener('click', go);
  // Enter = 시작하기(맥 .defaultAction), Esc = 닫기(첫 실행이면 다음 실행 때 다시 열림)
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.target.closest('.card, .more, .switch')) go();
    if (e.key === 'Escape') bridge.send('close');
  });

  bridge.send('ready').then(render);
})();
