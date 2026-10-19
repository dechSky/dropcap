import Foundation
import WebKit

// 본문 완전성 점검: 우리가 추린 본문이 원문 페이지에 보이는 본문을 얼마나 담았나.
// ReadSweep 에 DROPCAP_TEST_READSWEEP_FULL=1 을 함께 주면 기사마다 원문을 스크립트까지 다 띄워(그림·영상만 막음)
// Readability 와 다른 방법(itemprop·article·문단이 몰린 곳)으로 본문 영역을 골라 글자 수를 재고, 우리 글에 없는 문단을 센다.
// 기록에는 숫자만 남긴다(기사 글은 남기지 않음).
struct FullCheck: Codable {
    var ours = 0              // 우리 본문 글자 수(읽기 창이 빼는 기자 줄·짝 잃은 설명을 뺀 뒤)
    var oursRaw = 0           // 빼기 전
    var ref = 0               // 원문 페이지 본문 영역의 보이는 글자 수
    var refHow = ""           // 본문 영역을 고른 방법: itemprop · article · cluster · body
    var refParas = 0          // 본문 영역의 보이는 문단(60자 이상) 수
    var missParas = 0         // 그 가운데 우리 글에 없는 문단 수
    var missChars = 0         // 그 글자 수
    var missFirst: Double?    // 처음 빠진 문단의 자리(0=맨 앞, 1=맨 끝)
    var missRun = 0           // 빠진 문단이 이어진 가장 긴 길이
    var renderedChars = 0     // 렌더된 페이지 전체 보이는 글자 수
    var htmlBytes = 0         // 렌더된 문서 HTML 크기
    var wallPhrase: String?   // 보이는 글에서 찾은 구독 권유 문구(유료벽 신호)
    var wallNode: String?     // paywall·piano·meter 꼴 요소(유료벽 신호)
    var freeFlag: Bool?       // ld+json isAccessibleForFree
    var moreButton: String?   // 본문 영역 안 '더 보기'·'Read more' 단추
    var pager = false         // 여러 쪽 기사(rel=next·쪽 번호)
    var loginWall = false     // 로그인·가입 권유 요소
    var captcha = false       // 봇 확인 화면(captcha·DataDome·Cloudflare)
    var loadSeconds = 0.0
    var finalHost: String?    // 띄운 뒤의 주소 호스트(다른 곳으로 넘어갔나)
    var finalPath: String?
    var lang: String?         // 문서 언어(지역에 따라 다른 말로 내주는 사이트)
    var debugMiss: String?    // [로컬 진단 전용 · 커밋 금지] 처음 빠진 문단 앞부분
    var error: String?

    var ratio: Double? { ref > 0 ? Double(ours) / Double(ref) : nil }
}

@MainActor
final class ReadFull: NSObject, WKNavigationDelegate {
    private var done = false
    private var waiter: CheckedContinuation<Void, Never>?

    private static let script = """
    const norm = (s) => (s || '').replace(/\\s+/g, ' ').trim();
    const bad = 'nav, header, footer, aside, form, [role=navigation], [role=complementary], [class*="related" i], [class*="recommend" i], [class*="comment" i], [class*="newsletter" i], [class*="promo" i], [id*="related" i], [class*="sidebar" i], [class*="popular" i], [class*="share" i], [class*="ad-" i], [id*="ad-" i]';
    const shown = (el) => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
    const textOf = (el) => {
      let n = norm(el.innerText).length;
      el.querySelectorAll(bad).forEach((b) => { if (!b.parentElement || !b.parentElement.closest(bad) || !el.contains(b.parentElement.closest(bad))) n -= norm(b.innerText).length; });
      return Math.max(0, n);
    };
    // 1) itemprop=articleBody 2) 글이 가장 많은 article 3) 보이는 문단이 가장 많이 몰린 곳(부모 + 조부모 절반)
    let box = null, how = '';
    // 문서 순서로 첫 것: 끝없이 이어 붙는 다음 기사(무한 스크롤)를 고르지 않게
    const ip = [...document.querySelectorAll('[itemprop="articleBody"]')].find((e) => shown(e) && textOf(e) >= 200);
    if (ip) { box = ip; how = 'itemprop'; }
    const paras = [...document.querySelectorAll('p, div, li')].filter((p) => {
      if (p.closest(bad) || !shown(p)) return false;
      if (p.tagName === 'DIV' && p.querySelector('p, div, li, table')) return false; // 글자만 든 div(br 로 문단을 나누는 국내 사이트)
      return norm(p.innerText).length >= 60;
    });
    if (!box) {
      const arts = [...document.querySelectorAll('article')].filter((a) => shown(a) && !a.closest(bad));
      const best = arts.find((a) => textOf(a) >= 400 && paras.filter((p) => a.contains(p)).length >= 2 && !arts.some((o) => o !== a && a.contains(o) && textOf(o) >= 400));
      if (best) { box = best; how = 'article'; }
    }
    if (!box) {
      const score = new Map();
      for (const p of paras) {
        const n = norm(p.innerText).length;
        if (p.parentElement) score.set(p.parentElement, (score.get(p.parentElement) || 0) + n);
        if (p.parentElement && p.parentElement.parentElement) score.set(p.parentElement.parentElement, (score.get(p.parentElement.parentElement) || 0) + n / 2);
      }
      let top = null, s = 0;
      for (const [el, v] of score) if (v > s) { top = el; s = v; }
      if (top) { box = top; how = 'cluster'; }
    }
    if (!box) { box = document.body; how = 'body'; }
    const inBox = paras.filter((p) => box.contains(p) && !(p.tagName !== 'P' && p.querySelector('p')));
    // 문단 안에 문단(li 안 p 등)은 바깥만
    const units = inBox.filter((p) => !inBox.some((q) => q !== p && q.contains(p)));
    const oursN = norm(ours).replace(/[\\s"'“”‘’]/g, '');
    const key = (t) => norm(t).replace(/[\\s"'“”‘’]/g, '');
    let dbg = null, miss = 0, missC = 0, first = null, run = 0, best = 0;
    units.forEach((p, i) => {
      const k = key(p.innerText);
      const probe = [k.slice(0, 30), k.slice(Math.max(0, Math.floor(k.length / 2) - 15), Math.floor(k.length / 2) + 15), k.slice(-30)];
      const hit = probe.filter((x) => x.length >= 10 && oursN.includes(x)).length >= 1;
      if (!hit) { if (!dbg) dbg = k.slice(0, 40); miss++; missC += norm(p.innerText).length; if (first === null) first = units.length > 1 ? i / (units.length - 1) : 0; run++; best = Math.max(best, run); }
      else run = 0;
    });
    const bodyText = norm(document.body ? document.body.innerText : '');
    const lower = bodyText.toLowerCase();
    const phrases = ['subscribe to continue', 'subscribe to read', 'subscribers only', 'subscriber-only', 'to continue reading', 'sign in to continue',
      'already a subscriber', 'create a free account', 'this article is for subscribers', 'unlock this article', 'become a member', 'subscribe now',
      'you have reached your limit', 'free articles', 'register to read', 'log in to read', '유료 회원', '구독자 전용', '로그인 후 이용', '유료 기사',
      '프리미엄 회원', '구독하고 계속', '로그인하고 계속', '회원 전용', '전체 기사를 보시려면', '구독 후 이용'];
    const wp = phrases.find((x) => lower.includes(x)) || null;
    const wn = document.querySelector('[class*="paywall" i], [id*="paywall" i], [class*="piano" i], [id*="piano" i], .tp-modal, .tp-container-inner, [class*="meter" i][class*="wall" i], [class*="regwall" i], [class*="premium-wall" i], [class*="subscribe-wall" i], [data-paywall]');
    let free = null;
    document.querySelectorAll('script[type="application/ld+json"]').forEach((s) => {
      const m = (s.textContent || '').match(/"isAccessibleForFree"\\s*:\\s*"?(true|false|True|False)"?/);
      if (m && free === null) free = m[1].toLowerCase() === 'true';
    });
    const more = [...box.querySelectorAll('button, a, [role=button]')].find((b) => shown(b) && /^(\\s*)(더 ?보기|기사 ?더 ?보기|본문 ?더 ?보기|전체 ?보기|펼치기|read more|continue reading|show more|load more|keep reading|expand)/i.test(norm(b.innerText)));
    const pager = !!document.querySelector('link[rel=next], a[rel=next]') || [...box.querySelectorAll('a')].some((a) => /^(next page|다음 ?페이지|›|»|2)$/i.test(norm(a.innerText)) && /page|pg|p=/.test(a.getAttribute('href') || ''));
    const login = !!document.querySelector('[class*="regwall" i], [class*="login-wall" i], [class*="loginwall" i], [class*="signin-wall" i], [class*="register-wall" i]') || /(log in|sign in|register|로그인|회원가입)[^.]{0,30}(to (read|continue)|하고|후)/i.test(bodyText.slice(-3000));
    const cap = /captcha|datadome|cf-chl|challenge-platform|verify you are human|are you a robot|잠시만 기다리십시오/i.test(document.documentElement.outerHTML.slice(0, 200000));
    return JSON.stringify({ ours: 0, oursRaw: 0, loadSeconds: 0, ref: textOf(box), refHow: how, refParas: units.length, missParas: miss, missChars: missC, missFirst: first, missRun: best,
      renderedChars: bodyText.length, htmlBytes: document.documentElement.outerHTML.length, wallPhrase: wp, wallNode: wn ? (wn.tagName.toLowerCase() + '.' + String(wn.className || wn.id).slice(0, 40)) : null,
      freeFlag: free, finalHost: location.host, finalPath: location.pathname.slice(0, 120), lang: document.documentElement.lang || null, debugMiss: dbg, moreButton: more ? norm(more.innerText).slice(0, 20) : null, pager, loginWall: login, captcha: cap });
    """

    // 기사 하나: 원문을 스크립트까지 띄워 안정될 때까지(최대 maxWait) 기다린 뒤, 끝까지 내려 늦게 그리는 글도 부르고 잰다
    func measure(_ url: URL, ours: [Block], maxWait: TimeInterval = 18) async -> FullCheck {
        var c = FullCheck()
        let skip = BodyCleanup.analyze(ours).skip
        c.oursRaw = ours.compactMap(\.text).joined().count
        let kept = ours.enumerated().filter { !skip.contains($0.offset) }.compactMap(\.element.text)
        c.ours = kept.joined().count
        guard await URLSafety.resolvesPublic(url) else { c.error = "unsafe"; return c }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.mediaTypesRequiringUserActionForPlayback = .all
        let rule: [[String: Any]] = [["trigger": ["url-filter": ".*", "resource-type": ["image", "media", "font", "popup"]], "action": ["type": "block"]]]
        if let d = try? JSONSerialization.data(withJSONObject: rule), let json = String(data: d, encoding: .utf8),
           let list = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "dropcap-readfull", encodedContentRuleList: json) {
            cfg.userContentController.add(list)
        }
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900), configuration: cfg)
        w.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        w.navigationDelegate = self
        defer { w.stopLoading(); w.navigationDelegate = nil }
        let t0 = Date()
        done = false
        w.load(URLRequest(url: url, timeoutInterval: 20))
        await withTaskGroup(of: Void.self) { g in
            g.addTask { @MainActor in await withCheckedContinuation { k in if self.done { k.resume() } else { self.waiter = k } } }
            g.addTask { try? await Task.sleep(for: .seconds(maxWait)) }
            await g.next(); g.cancelAll()
            self.finish()
        }
        // 늦게 그리는 글(스크롤하면 불러옴)까지: 몇 번 끝까지 내렸다가 글 양이 그대로면 멈춤
        // 끝까지 내리면 다음 기사가 이어 붙는 사이트(TechCrunch·ESPN·ZDNet 등)가 있어 기본은 내리지 않음
        var last = -1
        for _ in 0..<(ProcessInfo.processInfo.environment["DROPCAP_TEST_READSWEEP_SCROLL"] == nil ? 0 : 6) {
            let n = (try? await w.evaluateJavaScript("window.scrollTo(0, document.body ? document.body.scrollHeight : 0); document.body ? document.body.innerText.length : 0")) as? Int ?? 0
            if n == last { break }
            last = n
            try? await Task.sleep(for: .milliseconds(700))
        }
        c.loadSeconds = Date().timeIntervalSince(t0)
        let oursText = kept.joined(separator: " ")
        do {
            let r = try await w.callAsyncJavaScript(Self.script, arguments: ["ours": oursText], in: nil, contentWorld: .defaultClient)
            if let s = r as? String, let d = s.data(using: .utf8), let got = try? JSONDecoder().decode(FullCheck.self, from: d) {
                let (o, raw, secs) = (c.ours, c.oursRaw, c.loadSeconds)
                c = got
                c.ours = o; c.oursRaw = raw; c.loadSeconds = secs
            } else { c.error = "no result" }
        } catch { c.error = String(describing: error).prefix(120).description }
        return c
    }

    private func finish() { done = true; waiter?.resume(); waiter = nil }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish() }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let u = action.request.url else { return .cancel }
        if u.scheme == "about" || u.scheme == "data" { return .allow }
        return await URLSafety.resolvesPublic(u) ? .allow : .cancel
    }
}
