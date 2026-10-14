// 앱(윈도우 WebView2)과 화면 사이의 다리.
//   bridge.send(cmd, args) → Promise(data)   화면 → 앱 명령
//   bridge.on(event, fn)                      앱 → 화면 알림(changed, article 등)
// WebView2 밖(맥·브라우저에서 미리 보기)에서는 window.DropcapMock(cmd, args) 가 대신 답한다(mock/*.js).
(() => {
  const host = window.chrome && window.chrome.webview;
  let seq = 0;
  const waiting = new Map();
  const handlers = new Map();

  function deliver(msg) {
    if (msg && msg.id != null && waiting.has(msg.id)) {
      const { resolve, reject } = waiting.get(msg.id);
      waiting.delete(msg.id);
      msg.ok ? resolve(msg.data) : reject(new Error(msg.error || '실패'));
      return;
    }
    if (msg && msg.event) (handlers.get(msg.event) || []).forEach((fn) => { try { fn(msg.data); } catch (e) { console.error(e); } });
  }

  if (host) host.addEventListener('message', (e) => deliver(e.data));

  window.bridge = {
    page: document.documentElement.dataset.page || '',
    send(cmd, args = {}) {
      const id = ++seq;
      return new Promise((resolve, reject) => {
        waiting.set(id, { resolve, reject });
        if (host) host.postMessage({ id, page: this.page, cmd, args });
        else if (window.DropcapMock) {
          Promise.resolve().then(() => window.DropcapMock(cmd, args)).then(
            (data) => deliver({ id, ok: true, data }),
            (e) => deliver({ id, ok: false, error: String(e && e.message || e) }));
        } else deliver({ id, ok: false, error: 'no host' });
      });
    },
    on(event, fn) {
      if (!handlers.has(event)) handlers.set(event, []);
      handlers.get(event).push(fn);
    },
    // 미리 보기(mock)에서 앱 알림을 흉내 낼 때
    emit(event, data) { deliver({ event, data }); },
    // 사진은 앱의 안전 로더로만(S-07·R-18): 공개 http(s) 만, 8MB, 1400px
    img(url) {
      if (!url || !/^https?:\/\//i.test(url)) return '';
      return host ? 'https://img.dropcap.example/?u=' + encodeURIComponent(url) : url;
    },
  };

  // 글꼴 설정(P-03): <html class="system-font"> 이면 시스템 글꼴
  // 움직임 줄이기(N-24·N-17): <html class="reduce-motion">
  window.bridge.on('appearance', (a) => {
    document.documentElement.classList.toggle('system-font', !a.pretendard);
    document.documentElement.classList.toggle('reduce-motion', !!a.reduceMotion);
  });

  // 기본 웹 동작 막기: 오른쪽 클릭 메뉴(각 화면이 자기 메뉴를 그림), 끌어 놓기, 파일 놓기
  document.addEventListener('contextmenu', (e) => { if (!e.target.closest('input, textarea')) e.preventDefault(); });
  document.addEventListener('dragover', (e) => e.preventDefault());
  document.addEventListener('drop', (e) => e.preventDefault());
})();
