// 화면 공용 도우미: 아이콘(맥 SF Symbols 대신 직접 그린 선 아이콘), 글자 이스케이프, 띄우는 메뉴
(() => {
  // 24×24 선 아이콘. 맥 기호 이름과 맞춰 둔다.
  const P = {
    newspaper: '<path d="M4 5h12v14H6a2 2 0 0 1-2-2z"/><path d="M16 9h4v8a2 2 0 0 1-4 0"/><path d="M7 8h6M7 11h6M7 14h4"/>',
    'newspaper.fill': '<path fill="currentColor" d="M4 5h12v14H6a2 2 0 0 1-2-2z"/><path d="M16 9h4v8a2 2 0 0 1-4 0"/><path stroke="var(--bg,#fff)" d="M7 8h6M7 11h6M7 14h4"/>',
    bell: '<path d="M6 16V11a6 6 0 0 1 12 0v5l1.5 2h-15z"/><path d="M10 20a2 2 0 0 0 4 0"/>',
    'bell.slash': '<path d="M6 16V11a6 6 0 0 1 9.5-4.9M18 11v5l1.5 2H8"/><path d="M10 20a2 2 0 0 0 4 0"/><path d="M4 4l16 16"/>',
    refresh: '<path d="M20 12a8 8 0 1 1-2.3-5.6"/><path d="M20 4v5h-5"/>',
    gear: '<circle cx="12" cy="12" r="3"/><path d="M12 2.5v3M12 18.5v3M2.5 12h3M18.5 12h3M5.3 5.3l2.1 2.1M16.6 16.6l2.1 2.1M5.3 18.7l2.1-2.1M16.6 7.4l2.1-2.1"/>',
    ellipsis: '<circle cx="12" cy="12" r="9"/><circle cx="8" cy="12" r=".9" fill="currentColor"/><circle cx="12" cy="12" r=".9" fill="currentColor"/><circle cx="16" cy="12" r=".9" fill="currentColor"/>',
    search: '<circle cx="11" cy="11" r="6"/><path d="M20 20l-4.5-4.5"/>',
    xmark: '<path d="M6 6l12 12M18 6L6 18"/>',
    'xmark.circle': '<circle cx="12" cy="12" r="9" fill="currentColor" stroke="none"/><path stroke="var(--bg,#fff)" d="M9 9l6 6M15 9l-6 6"/>',
    star: '<path d="M12 3.5l2.6 5.4 5.9.8-4.3 4.1 1 5.8L12 16.8l-5.2 2.8 1-5.8-4.3-4.1 5.9-.8z"/>',
    'star.fill': '<path fill="currentColor" d="M12 3.5l2.6 5.4 5.9.8-4.3 4.1 1 5.8L12 16.8l-5.2 2.8 1-5.8-4.3-4.1 5.9-.8z"/>',
    bookmark: '<path d="M7 3.5h10v17l-5-3.5-5 3.5z"/>',
    'bookmark.fill': '<path fill="currentColor" d="M7 3.5h10v17l-5-3.5-5 3.5z"/>',
    moon: '<path fill="currentColor" d="M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z"/>',
    filter: '<path d="M4 6h16M7 12h10M10 18h4"/>',
    sort: '<path d="M8 4v16M4 8l4-4 4 4M16 20V4M12 16l4 4 4-4"/>',
    clock: '<circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 2"/>',
    building: '<path d="M4 20V6l8-3v17M12 9l8 3v8M3 20h18M7 9h2M7 13h2M7 17h2"/>',
    book: '<path d="M4 5.5C6 4.5 9 4.5 12 6c3-1.5 6-1.5 8-.5V19c-2-1-5-1-8 .5-3-1.5-6-1.5-8-.5z"/><path d="M12 6v13.5"/>',
    grid: '<rect x="4" y="4" width="6.5" height="6.5" rx="1.5"/><rect x="13.5" y="4" width="6.5" height="6.5" rx="1.5"/><rect x="4" y="13.5" width="6.5" height="6.5" rx="1.5"/><rect x="13.5" y="13.5" width="6.5" height="6.5" rx="1.5"/>',
    globe: '<circle cx="12" cy="12" r="8.5"/><path d="M3.5 12h17M12 3.5c2.5 2.5 3.5 5.5 3.5 8.5s-1 6-3.5 8.5c-2.5-2.5-3.5-5.5-3.5-8.5s1-6 3.5-8.5z"/>',
    share: '<path d="M12 15V3.5M8 7.5l4-4 4 4"/><path d="M6 11v8.5h12V11"/>',
    scissors: '<circle cx="6.5" cy="7" r="2.5"/><circle cx="6.5" cy="17" r="2.5"/><path d="M8.6 8.4L20 17M8.6 15.6L20 7"/>',
    speaker: '<path d="M4 9.5h3.5L12 5.5v13l-4.5-4H4z"/><path d="M15.5 9a4 4 0 0 1 0 6M18 6.5a7.5 7.5 0 0 1 0 11"/>',
    'speaker.stop': '<path d="M4 9.5h3.5L12 5.5v13l-4.5-4H4z"/><rect x="15" y="9" width="6" height="6" rx="1" fill="currentColor"/>',
    textsize: '<path d="M3.5 18l4-11 4 11M5 14h5"/><path d="M13 18l3-8 3 8M14 15.5h4"/>',
    translate: '<path d="M4 6h8M8 4v2M5.5 6c.5 3 2.5 5.5 5.5 6.5M10.5 6c-.5 3-2.5 5.5-5.5 6.5"/><path d="M13 20l3.5-8 3.5 8M14 17.5h5"/>',
    folder: '<path d="M3.5 7a1.5 1.5 0 0 1 1.5-1.5h4l2 2h8a1.5 1.5 0 0 1 1.5 1.5v8.5A1.5 1.5 0 0 1 19 19H5a1.5 1.5 0 0 1-1.5-1.5z"/>',
    'folder.plus': '<path d="M3.5 7a1.5 1.5 0 0 1 1.5-1.5h4l2 2h8a1.5 1.5 0 0 1 1.5 1.5v8.5A1.5 1.5 0 0 1 19 19H5a1.5 1.5 0 0 1-1.5-1.5z"/><path d="M12 10.5v5M9.5 13h5"/>',
    trash: '<path d="M4.5 7h15M9.5 7V4.5h5V7M6.5 7l1 13h9l1-13"/>',
    pencil: '<path d="M4 20l1-4L16 5l3 3L8 19z"/>',
    copy: '<rect x="8" y="8" width="11.5" height="11.5" rx="2"/><path d="M16 8V5.5A1.5 1.5 0 0 0 14.5 4h-9A1.5 1.5 0 0 0 4 5.5v9A1.5 1.5 0 0 0 5.5 16H8"/>',
    download: '<path d="M12 4v11M7.5 10.5L12 15l4.5-4.5"/><path d="M5 19.5h14"/>',
    play: '<path fill="currentColor" d="M8 5.5v13l10.5-6.5z"/>',
    'play.circle': '<circle cx="12" cy="12" r="9" fill="rgba(0,0,0,.45)" stroke="#fff"/><path fill="#fff" stroke="none" d="M10 8v8l6-4z"/>',
    chevronRight: '<path d="M9 5l7 7-7 7"/>',
    chevronDown: '<path d="M5 9l7 7 7-7"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    check: '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
    link: '<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1.2 1.2"/><path d="M14 10a4 4 0 0 0-5.7 0l-3 3A4 4 0 0 0 11 18.7l1.2-1.2"/>',
    'arrow.up.right': '<path d="M7 17L17 7M9 7h8v8"/>',
    sparkles: '<path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8z"/><path d="M18.5 15.5l.7 2 2 .7-2 .7-.7 2-.7-2-2-.7 2-.7z"/>',
    drop: '<path d="M12 3.5c3 4 6 7.2 6 10.5a6 6 0 0 1-12 0c0-3.3 3-6.5 6-10.5z"/>',
    // 일반 뉴스 분야(shared/categories.json 의 기호 → Sections.IconFor)
    'people': '<circle cx="12" cy="8" r="3"/><circle cx="5.5" cy="10" r="2.2"/><circle cx="18.5" cy="10" r="2.2"/><path d="M6.5 19a5.5 5.5 0 0 1 11 0M2 18a3.6 3.6 0 0 1 4.5-3.4M22 18a3.6 3.6 0 0 0-4.5-3.4"/>',
    'desktop': '<rect x="3" y="4.5" width="18" height="12" rx="2"/><path d="M9 20h6M12 16.5V20"/>',
    'atom': '<circle cx="12" cy="12" r="1.6" fill="currentColor"/><ellipse cx="12" cy="12" rx="9" ry="3.6"/><ellipse cx="12" cy="12" rx="9" ry="3.6" transform="rotate(60 12 12)"/><ellipse cx="12" cy="12" rx="9" ry="3.6" transform="rotate(120 12 12)"/>',
    'heart': '<rect x="3.5" y="3.5" width="17" height="17" rx="3"/><path d="M12 16.5s-4-2.6-4-5.2a2.2 2.2 0 0 1 4-1.2 2.2 2.2 0 0 1 4 1.2c0 2.6-4 5.2-4 5.2z"/>',
    'masks': '<path d="M3.5 5.5c3-1.3 6-1.3 9 0v5c0 3-2 5.5-4.5 5.5S3.5 13.5 3.5 10.5z"/><path d="M11.5 9.5c3-1.3 6-1.3 9 0v5c0 3-2 5.5-4.5 5.5-1.5 0-2.9-.9-3.7-2.3"/><path d="M6 9h.01M10 9h.01M6.2 12.5c1 .8 2.6.8 3.6 0"/>',
    'sport': '<rect x="3" y="5" width="18" height="14" rx="1.5"/><path d="M12 5v14"/><circle cx="12" cy="12" r="2.6"/><path d="M3 9.5h2.5v5H3M21 9.5h-2.5v5H21"/>',
    'leaf': '<path d="M5 19c0-8 5-13 15-14-1 10-6 15-14 15"/><path d="M5 19c3-4 6-7 10-9"/>',
    // AI 하위 분류(Category.symbol)
    'cat.model': '<path d="M12 3l8 4.5v9L12 21l-8-4.5v-9z"/><path d="M4 7.5l8 4.5 8-4.5M12 12v9"/>',
    'cat.research': '<path d="M9.5 3.5h5M10.5 3.5v6L5 19a1.3 1.3 0 0 0 1.1 2h11.8a1.3 1.3 0 0 0 1.1-2l-5.5-9.5v-6"/><path d="M7.5 15h9"/>',
    'cat.policy': '<path d="M3.5 9.5L12 4l8.5 5.5z"/><path d="M5.5 10v8M9.5 10v8M14.5 10v8M18.5 10v8M3.5 20h17"/>',
    'cat.business': '<path d="M4 19l5-6 4 3 7-9"/><path d="M15 7h5v5"/>',
    'cat.security': '<path d="M12 3.5l7.5 3v5.5c0 4.5-3.2 7.8-7.5 9-4.3-1.2-7.5-4.5-7.5-9V6.5z"/><rect x="9" y="11" width="6" height="5" rx="1"/><path d="M10 11V9.5a2 2 0 0 1 4 0V11"/>',
    'cat.other': '<circle cx="8" cy="8" r="2.5"/><circle cx="16" cy="8" r="2.5"/><circle cx="8" cy="16" r="2.5"/><circle cx="16" cy="16" r="2.5"/>',
    // 종류(ItemKind.symbol)
    'kind.article': '<path d="M6.5 3.5h7l4 4v13h-11z"/><path d="M13.5 3.5v4h4M9 12h6M9 15.5h6"/>',
    'kind.video': '<rect x="3.5" y="5.5" width="17" height="13" rx="2.5"/><path fill="currentColor" d="M10 9v6l5-3z"/>',
    'kind.paper': '<path d="M6.5 3.5h7l4 4v13h-11z"/><path d="M13.5 3.5v4h4M9 11h6M9 14h6M9 17h3"/>',
    'kind.release': '<path d="M12 3l8 4.5v9L12 21l-8-4.5v-9z"/><path d="M4 7.5l8 4.5 8-4.5M12 12v9M8 5.3l8 4.5"/>',
    'kind.post': '<path d="M4 6.5a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2V11a2 2 0 0 1-2 2H9l-3 2.5V13H6a2 2 0 0 1-2-2z"/><path d="M16 8.5h2a2 2 0 0 1 2 2V15a2 2 0 0 1-2 2v2.5L15 17h-3a2 2 0 0 1-2-1.5"/>',
    'kind.podcast': '<path d="M4 12h2M8 8v8M12 5v14M16 8v8M20 11v2"/>',
  };

  const ic = (name, cls = '') => `<i class="ic ${cls}"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">${P[name] || P['cat.other']}</svg></i>`;

  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  function fillIcons(root = document) {
    root.querySelectorAll('[data-ic]').forEach((el) => { el.outerHTML = ic(el.dataset.ic, el.className.replace(/\bic\b/, '')); });
  }

  // 띄우는 메뉴. items: [{label, icon?, on?, disabled?, run}] · 'sep' · {header}
  let open = null;
  function closeMenu() { if (open) { open.remove(); open = null; } }
  function popMenu(x, y, items) {
    closeMenu();
    const m = document.createElement('div');
    m.className = 'pop';
    for (const it of items) {
      if (it === 'sep') { m.insertAdjacentHTML('beforeend', '<div class="sep"></div>'); continue; }
      if (it.header) { m.insertAdjacentHTML('beforeend', `<div class="hd">${esc(it.header)}</div>`); continue; }
      const d = document.createElement('div');
      d.className = 'mi' + (it.on ? ' on' : '') + (it.disabled ? ' disabled' : '');
      d.innerHTML = (it.icon ? ic(it.icon) : '') + `<span>${esc(it.label)}</span>`;
      d.addEventListener('click', (e) => { e.stopPropagation(); closeMenu(); it.run && it.run(); });
      m.appendChild(d);
    }
    document.body.appendChild(m);
    const r = m.getBoundingClientRect();
    m.style.left = Math.max(4, Math.min(x, innerWidth - r.width - 4)) + 'px';
    m.style.top = Math.max(4, Math.min(y, innerHeight - r.height - 4)) + 'px';
    open = m;
  }
  // 단추 아래에 메뉴 띄우기
  function popUnder(el, items) {
    const r = el.getBoundingClientRect();
    popMenu(r.left, r.bottom + 4, items);
  }
  document.addEventListener('mousedown', (e) => { if (open && !open.contains(e.target)) closeMenu(); }, true);
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeMenu(); });
  window.addEventListener('blur', closeMenu);

  // 자리 비움 알림(띄우는 작은 안내)
  function toast(text) {
    const t = document.createElement('div');
    t.textContent = text;
    t.style.cssText = 'position:fixed;left:50%;bottom:24px;transform:translateX(-50%);background:var(--bg-elev);box-shadow:var(--shadow);padding:8px 14px;border-radius:9px;font-size:12.5px;z-index:2000;transition:opacity .3s';
    document.body.appendChild(t);
    setTimeout(() => { t.style.opacity = '0'; setTimeout(() => t.remove(), 300); }, 1600);
  }

  window.ui = { ic, esc, fillIcons, popMenu, popUnder, closeMenu, toast };
  document.addEventListener('DOMContentLoaded', () => fillIcons());
})();
