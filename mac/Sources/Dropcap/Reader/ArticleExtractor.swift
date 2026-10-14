import Foundation
import WebKit

struct Block: Codable, Hashable {
    enum Kind: String, Codable { case h, p, li, quote, pre, img, cap }
    var type: Kind
    var text: String?
    var src: String?
    var original: String?
}

struct Article: Codable {
    var title: String?
    var byline: String?
    var siteName: String?
    var blocks: [Block]
}

// 화면에 보이지 않는 웹 보기에 기사를 띄우고 Readability 로 본문만 추린다.
@MainActor
final class ArticleExtractor: NSObject, WKNavigationDelegate {
    private var web: WKWebView?
    private var continuation: CheckedContinuation<Void, Never>?
    private static let readability = (try? String(contentsOf: Resources.url("Readability.js"), encoding: .utf8)) ?? ""

    private static let script = """
    (() => {
      const doc = document.cloneNode(true);
      doc.querySelectorAll('.sr-only, .visually-hidden, .screen-reader-text, [class*="sr-only"], [class*="visually-hidden"]').forEach((n) => n.remove());
      // 기본 기준(500자)으로 못 찾으면 짧은 글(GeekNews 소개글 등)을 위해 100자 기준으로 한 번 더(parse 가 문서를 고치므로 새 사본으로)
      const fresh = doc.cloneNode(true);
      let art = new Readability(doc).parse();
      if (!art || !art.content) art = new Readability(fresh.cloneNode(true), { charThreshold: 100 }).parse();
      // 그래도 못 찾으면: 본문으로 보이는 영역(id·class 에 content·article·topic·post·entry·body 가 든 것) 가운데 글이 가장 많은 곳
      if (!art || !art.content) {
        let best = null, bestLen = 0;
        fresh.querySelectorAll('article, main, [id*="content" i], [class*="content" i], [id*="topic" i], [class*="article" i], [class*="post" i], [class*="entry" i], [itemprop="articleBody"]').forEach((el) => {
          if (el.closest('nav, header, footer, aside')) return;
          const len = (el.textContent || '').replace(/\\s+/g, ' ').trim().length;
          if (len > bestLen && len < 40000) { best = el; bestLen = len; }
        });
        if (best && bestLen >= 80) {
          best.querySelectorAll('script, style, nav, form, button, .related-topics, [class*="related" i], [class*="share" i]').forEach((n) => n.remove());
          art = { title: document.title, content: '<div>' + best.innerHTML + '</div>' };
        }
      }
      if (!art || !art.content) return null;
      const box = new DOMParser().parseFromString(art.content, 'text/html').body;
      const blocks = [];
      const abs = (u) => { try { const h = new URL(u, location.href).href; return /^https?:/.test(h) ? h : null; } catch { return null; } };
      // 늦게 불러오는 사진은 src 가 빈 자리표시이고 진짜 주소는 srcset·data-* 에 있다 — 가장 큰 진짜 주소를 고른다
      const bestSrc = (img) => {
        if (!img) return null;
        const cands = [];
        const fromSet = (v) => (v || '').split(',').map(x => x.trim().split(/\\s+/)).forEach(([u, d]) => {
          if (u) cands.push([u, parseFloat(d) || (d && d.endsWith('x') ? parseFloat(d) * 1000 : 1)]);
        });
        fromSet(img.getAttribute('srcset')); fromSet(img.getAttribute('data-srcset'));
        const pic = img.closest('picture');
        if (pic) pic.querySelectorAll('source').forEach(s => fromSet(s.getAttribute('srcset') || s.getAttribute('data-srcset')));
        cands.sort((a, b) => b[1] - a[1]);
        for (const [u] of cands) { const h = abs(u); if (h) return h; }
        for (const a of ['data-src', 'data-lazy-src', 'data-original', 'data-url', 'src']) {
          const v = img.getAttribute(a);
          if (v && !v.startsWith('data:')) { const h = abs(v); if (h && !/(1x1|spacer|blank|pixel)\\.(gif|png)/i.test(h)) return h; }
        }
        return null;
      };
      const clean = (s) => (s || '').replace(/\\((opens in a new (window|tab)|새 창에서 열기)\\)/gi, '').replace(/\\s+/g, ' ').trim();
      const walk = (el) => {
        for (const n of el.children) {
          const tag = n.tagName.toLowerCase();
          const t = clean(n.textContent);
          if (/^h[1-6]$/.test(tag)) { if (t) blocks.push({ type: 'h', text: t }); }
          else if (tag === 'p') {
            const img = n.querySelector('img'); const src = bestSrc(img);
            if (t) blocks.push({ type: 'p', text: t });
            if (src) blocks.push({ type: 'img', src });
          }
          else if (tag === 'li') { if (t) blocks.push({ type: 'li', text: t }); }
          else if (tag === 'blockquote') { if (t) blocks.push({ type: 'quote', text: t }); }
          else if (tag === 'pre') { if (t) blocks.push({ type: 'pre', text: n.textContent }); }
          else if (tag === 'img') { const s = bestSrc(n); if (s) blocks.push({ type: 'img', src: s }); }
          else if (tag === 'picture') { const s = bestSrc(n.querySelector('img')); if (s) blocks.push({ type: 'img', src: s }); }
          else if (tag === 'figure') {
            const s = bestSrc(n.querySelector('img'));
            if (s) blocks.push({ type: 'img', src: s });
            const cap = n.querySelector('figcaption'); const c = cap && clean(cap.textContent);
            if (c) blocks.push({ type: 'cap', text: c });
          }
          else walk(n);
        }
      };
      walk(box);
      // 문단 태그 없이 맨 글자로 든 본문(GeekNews 등): 줄 단위로 문단을 만든다
      if (!blocks.some((b) => b.type === 'p' || b.type === 'li')) {
        (box.innerText || box.textContent || '').split(/\\n+/).map(clean).filter((t) => t.length > 1).forEach((t) => blocks.push({ type: 'p', text: t }));
      }
      return JSON.stringify({ title: art.title, byline: art.byline, siteName: art.siteName, blocks });
    })();
    """

    // 1) 빠른 길: HTML 만 받아 스크립트·그림·글꼴 없이 바로 본문을 추린다(대부분의 언론사는 여기서 끝남)
    // 2) 느린 길: 스크립트로 본문을 그리는 사이트만 실제로 띄운다. 그림·동영상·글꼴은 막고, 본문이 생기는 대로 바로 꺼낸다.
    // allowScripts: 사용자가 직접 연 기사일 때만 true. 미리 받기에서는 사이트의 스크립트를 돌리지 않는다.
    func extract(_ url: URL, allowScripts: Bool = true) async -> Article? {
        guard await URLSafety.resolvesPublic(url) else { return nil }
        let t0 = Date()
        let host = url.host?.lowercased() ?? ""
        var refused = false // 사이트가 접근을 거부(401·403·429)
        var richPage = false // 받은 HTML 에 글이 이미 많다(스크립트로 그리는 빈 껍데기가 아님)
        do {
            if let got = try await FeedService.shared.fetchWithEncoding(url.absoluteString) {
                if let art = await run(data: got.data, encoding: got.encoding ?? Self.sniffCharset(got.data), base: url) {
                    NSLog("[기사] 빠른 길 %.2f초 %@", Date().timeIntervalSince(t0), host)
                    return art
                }
                richPage = Self.visibleTextLength(got.data) > 600 // 스크립트로 그리는 빈 껍데기는 보이는 글이 거의 없다
            }
        } catch FeedError.http(let code) where [401, 403, 429].contains(code) {
            refused = true
        } catch {}
        guard allowScripts else { return nil }
        // 접근을 거부하는 사이트(예: GeekNews 403)는 느린 길도 대개 막힌다: 짧게만 시도하고, 그래도 막히면 이번 실행 동안은 바로 대체 화면
        if Self.blockedHosts.contains(host) { NSLog("[기사] %@ 은 막힌 사이트라 건너뜀", host); return nil }
        // 글이 다 들어 있는데도 못 추린 페이지는 스크립트를 돌려도 같으므로 느린 길(최대 15초)을 건너뛴다
        if richPage { NSLog("[기사] 빠른 길 실패, 글이 있는 페이지라 느린 길 건너뜀 %@", host); return nil }
        let art = await run(url: url, maxWait: refused ? 6 : 15)
        if art == nil, refused { Self.blockedHosts.insert(host) }
        NSLog("[기사] 느린 길 %.2f초 %@ %@", Date().timeIntervalSince(t0), host, art == nil ? "실패" : "성공")
        return art
    }

    // 스크립트·스타일을 뺀 보이는 글자 수(대략)
    static func visibleTextLength(_ data: Data) -> Int {
        var h = String(decoding: data.prefix(800_000), as: UTF8.self)
        for tag in ["script", "style", "noscript", "svg"] {
            h = h.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        h = h.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return h.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).count
    }

    // <meta charset="euc-kr"> 처럼 문서 안에 적힌 인코딩을 찾는다
    static func sniffCharset(_ data: Data) -> String {
        let head = String(decoding: data.prefix(4096), as: UTF8.self).lowercased()
        if let r = head.range(of: #"charset=["']?([a-z0-9_\-]+)"#, options: .regularExpression) {
            let m = head[r].replacingOccurrences(of: #"charset=["']?"#, with: "", options: .regularExpression)
            return m
        }
        return "utf-8"
    }

    private static var compiled: [String: WKContentRuleList] = [:]

    private static func ruleList(_ id: String, _ types: [String]) async -> WKContentRuleList? {
        if let c = compiled[id] { return c }
        if let found = try? await WKContentRuleListStore.default().contentRuleList(forIdentifier: id) {
            compiled[id] = found
            return found
        }
        let rule: [[String: Any]] = [["trigger": ["url-filter": ".*", "resource-type": types], "action": ["type": "block"]]]
        guard let data = try? JSONSerialization.data(withJSONObject: rule), let json = String(data: data, encoding: .utf8) else { return nil }
        let list = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: id, encodedContentRuleList: json)
        compiled[id] = list
        return list
    }

    private func makeWeb(js: Bool, block: [String], id: String) async -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.mediaTypesRequiringUserActionForPlayback = .all
        cfg.defaultWebpagePreferences.allowsContentJavaScript = js // 꺼도 앱이 넣는 추출 스크립트는 돈다
        if let rules = await Self.ruleList(id, block) { cfg.userContentController.add(rules) }
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900), configuration: cfg)
        w.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        w.navigationDelegate = self
        return w
    }

    private func run(data: Data, encoding: String, base: URL) async -> Article? {
        let w = await makeWeb(js: false, block: ["image", "media", "font", "style-sheet", "script", "raw", "svg-document", "popup", "fetch", "websocket", "other"], id: "ainews-fast")
        web = w
        defer { w.stopLoading(); web = nil }
        w.load(data, mimeType: "text/html", characterEncodingName: encoding, baseURL: base)
        await waitForLoad(seconds: 6)
        return await tryExtract(w)
    }

    @MainActor static var blockedHosts: Set<String> = []

    private func run(url: URL, maxWait: TimeInterval = 15) async -> Article? {
        let w = await makeWeb(js: true, block: ["image", "media", "font", "popup", "websocket"], id: "ainews-full")
        web = w
        defer { w.stopLoading(); web = nil }
        w.load(URLRequest(url: url, timeoutInterval: 20))
        // 다 뜨기를 기다리지 않고, 0.6초 뒤부터 0.4초마다 본문이 생겼는지 본다(최대 15초)
        let deadline = Date().addingTimeInterval(maxWait)
        try? await Task.sleep(for: .milliseconds(600))
        var last = 0
        while Date() < deadline {
            if let art = await tryExtract(w) {
                let n = art.blocks.count
                if n >= 4, n == last { return art } // 두 번 연속 같으면 다 그려진 것
                last = n
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return await tryExtract(w)
    }

    // 페이지와 분리된 공간(앱 전용 world)에서 실행: 페이지 스크립트가 추출 코드를 건드리지 못한다.
    // Readability 는 한 번만 넣고, 이후엔 짧은 추출 스크립트만 다시 돌린다.
    private func tryExtract(_ w: WKWebView) async -> Article? {
        let loaded = (try? await w.evaluateJavaScript("typeof Readability !== 'undefined'", in: nil, contentWorld: .defaultClient)) as? Bool ?? false
        if !loaded { _ = try? await w.evaluateJavaScript(Self.readability + "\n;true", in: nil, contentWorld: .defaultClient) }
        if ProcessInfo.processInfo.environment["DROPCAP_DEBUG_EXTRACT"] != nil { // 진단용
            do { let r = try await w.evaluateJavaScript(Self.script, in: nil, contentWorld: .defaultClient); NSLog("[추출 진단] %@", String(describing: r).prefix(600) as CVarArg) }
            catch { NSLog("[추출 진단] 오류 %@", String(describing: error)) }
        }
        guard let json = (try? await w.evaluateJavaScript(Self.script, in: nil, contentWorld: .defaultClient)) as? String,
              let art = try? JSONDecoder().decode(Article.self, from: Data(json.utf8)),
              // 짧은 글(소개글·단신)도 받는다: 글 100자 이상이면 본문으로(예전 '2문단·280자' 기준은 GeekNews 같은 짧은 글을 버렸다)
              !art.blocks.filter({ $0.text != nil }).isEmpty,
              art.blocks.compactMap(\.text).joined().count >= 100 else { return nil }
        return art
    }

    private func waitForLoad(seconds: Double) async {
        await withTaskGroup(of: Void.self) { g in
            g.addTask { @MainActor in await withCheckedContinuation { self.continuation = $0 } }
            g.addTask { try? await Task.sleep(for: .seconds(seconds)) }
            await g.next()
            g.cancelAll()
            self.finishWait()
        }
    }

    private func finishWait() {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishWait() }

    // 페이지가 내부망 주소로 이동하거나 넘기려 하면 막는다(about:blank·data 는 허용)
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let u = action.request.url else { return .cancel }
        if u.scheme == "about" || u.scheme == "data" { return .allow }
        return await URLSafety.resolvesPublic(u) ? .allow : .cancel
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finishWait() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finishWait() }
}
