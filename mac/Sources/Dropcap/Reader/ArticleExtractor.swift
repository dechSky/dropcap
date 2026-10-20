import Foundation
import WebKit

struct Block: Codable, Hashable {
    enum Kind: String, Codable { case h, p, li, quote, pre, img, cap, row }
    var type: Kind
    var text: String?          // row: 셀을 ' · ' 로 이은 글(찾기·요약·군더더기 규칙이 그대로 본다)
    var src: String?
    var original: String?
    var cells: [String]? = nil // row: 표 한 줄의 셀(번역됐으면 번역문)
    var head: Bool? = nil      // row: 머리행
}

struct Article: Codable {
    var title: String?
    var byline: String?
    var siteName: String?
    var blocks: [Block]
    var paid: Bool? = nil     // 사이트가 유료 기사라고 적음(ld+json isAccessibleForFree=false · 한경 articlePayment="Y")
    var partial: Bool? = nil  // 본문 일부만 가져왔을 수 있음(앞 문단이 본문 영역에 더 있음)
    var ldBody: Int? = nil    // 사이트가 ld+json articleBody 로 적은 본문 글자 수(맛보기 판정 — Paywall.matchesSiteBody)
}

// 한 번의 본문 추리기가 어떻게 흘러갔는지(전수 점검 READSWEEP 와 기록용)
struct ExtractTrace: Codable {
    var path = "none"          // fast · slow · none
    var http: Int?             // 빠른 길에서 받은 거절 코드
    var fetchError: String?    // 빠른 길에서 받기 자체가 실패한 까닭
    var offline = false        // 그 까닭이 연결 문제(URLError: 끊김·시간 초과·이름 못 찾음)
    var visible = 0            // 받은 HTML 의 보이는 글자 수(대략)
    var shortText: Int?        // 추렸지만 글이 너무 짧아 버린 길이
    var skipped: String?       // 느린 길을 건너뛴 까닭
    var fastSeconds = 0.0
    var slowSeconds = 0.0

    // 못 추렸을 때 읽기 창에 알릴 까닭(ReaderFailure)
    var failure: ReaderFailure {
        if let c = http { return [401, 403, 429].contains(c) ? .blocked : ([404, 410].contains(c) ? .gone : .unknown) }
        if skipped == "blockedHost" { return .blocked }
        if shortText != nil { return .noText }
        if offline { return .network }
        return .unknown
    }
}

enum ReaderFailure: String, Codable {
    case blocked, gone, noText, network, unknown

    var message: String {
        switch self {
        case .blocked: return "이 사이트는 앱에서 본문을 가져가지 못하게 막아 두었습니다. 위는 피드가 준 요약입니다."
        case .gone: return "기사 페이지가 없어졌습니다(지워졌거나 주소가 바뀜). 위는 피드가 준 요약입니다."
        case .noText: return "본문 글이 거의 없는 기사입니다(영상·사진 기사 등). 원문에서 보세요."
        case .network: return "기사 페이지를 받지 못했습니다(연결 문제). 잠시 뒤 다시 시도해 보세요."
        case .unknown: return "이 기사는 본문을 추리지 못했습니다(유료 기사·차단 등). 위는 피드가 준 요약입니다."
        }
    }
    var retryable: Bool { self == .network || self == .unknown }
}

// 화면에 보이지 않는 웹 보기에 기사를 띄우고 Readability 로 본문만 추린다.
@MainActor
final class ArticleExtractor: NSObject, WKNavigationDelegate {
    private var web: WKWebView?
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var trace = ExtractTrace()
    private var loadDone = false // 이번 기다림이 끝났다(다 뜸·실패·시간 초과) — 늦게 등록된 기다림은 바로 깨운다(A-22)
    private static let readability = (try? String(contentsOf: Resources.url("Readability.js"), encoding: .utf8)) ?? ""

    static let script = """
    (() => {
      const norm = (s) => (s || '').replace(/\\s+/g, ' ').trim();
      const doc = document.cloneNode(true);
      doc.querySelectorAll('.sr-only, .visually-hidden, .screen-reader-text, [class*="sr-only"], [class*="visually-hidden"]').forEach((n) => n.remove());
      // 본문 밖 상자(기자 소개·댓글 수·공유·단추)는 미리 뺀다. 페이지 글의 30% 넘는 상자는 건드리지 않는다(본문을 지우지 않게)
      const total = norm(doc.body ? doc.body.textContent : '').length || 1;
      doc.querySelectorAll('.author-mini-bio, [class*="author-bio" i], [class*="authorbio" i], [class*="author-box" i], [class*="authorbox" i], [class*="author-card" i], [class*="about-author" i], [class*="about-the-author" i], [class*="author-info" i], [class*="bio-box" i], [class*="byline-bio" i], [class*="contributor-bio" i], .story-tools, .view-comments, [class*="comment-count" i], [class*="comments-link" i], [class*="share-bar" i], [class*="social-share" i], [class*="hide-caption" i], [class*="toggle-caption" i], button')
        .forEach((n) => { if (n.isConnected && norm(n.textContent).length < total * 0.3) n.remove(); });
      doc.querySelectorAll('a[href*="/author/" i] img, a[href*="/authors/" i] img, a[href*="/people/" i] img, a[href*="/staff/" i] img, a[href*="/reporter/" i] img').forEach((n) => n.remove()); // 기자 얼굴
      doc.querySelectorAll('sup').forEach((n) => { if (/^\\[?\\s*\\d{1,3}\\s*\\]?$/.test(norm(n.textContent))) n.remove(); }); // 각주 번호
      const klass = (el) => (el.className && el.className.baseVal === undefined ? el.className : '');
      const ln = (el) => norm(el.textContent).length;
      // 본문 중간 추천 상자(ZDNet '관련기사' + .news_box · Al Jazeera 'Recommended Stories'): 그 제목 + 바로 뒤(또는 감싼 상자)의 링크 목록을 상자째 뺀다.
      // 링크 글이 60% 넘는 2,000자 미만 상자만, 모두 합쳐 페이지 글의 30% 미만일 때만
      const RECO = /^(recommended( stories| reading| for you)?|related( stories| articles| coverage| content| posts| news)?|read more|more on this( story)?|keep reading|you may also like|also read|관련\\s?기사|추천\\s?기사|함께\\s?(볼|읽을|보면 좋은)\\s?기사|이 기사와 함께 (본|읽은) 기사)\\s*:?$/i;
      const linky = (el) => { const t = el ? ln(el) : 0; if (!t || t >= 2000 || el.querySelector('img + p, figure')) return false; const a = [...el.querySelectorAll('a')].reduce((s, x) => s + ln(x), 0); return a >= t * 0.6; };
      let recoCut = 0;
      doc.querySelectorAll('h2, h3, h4, h5, h6, p, strong, b, span, div').forEach((hd) => {
        if (!hd.isConnected || ln(hd) > 40 || !RECO.test(norm(hd.textContent))) return;
        let head = hd;
        while (head.parentElement && head.parentElement !== doc.body && ln(head.parentElement) === ln(hd)) head = head.parentElement;
        const next = head.nextElementSibling, wrap = head.parentElement;
        let gone = null;
        if (next && linky(next)) gone = [head, next];
        else if (wrap && wrap !== doc.body && ln(wrap) < 2000 && [...wrap.querySelectorAll('a')].reduce((s, x) => s + ln(x), 0) >= (ln(wrap) - ln(head)) * 0.6 && wrap.querySelector('a')) gone = [wrap];
        if (!gone) return;
        const cut = gone.reduce((s, x) => s + ln(x), 0);
        if (recoCut + cut >= total * 0.3) return;
        recoCut += cut;
        gone.forEach((x) => x.remove());
      });
      // 사진 설명·출처 상자(figcaption 밖 — 경향 p.caption · 노컷 span.fr-inner · CNBC InlineImage-imageEmbedCaption/Credit · NPR .credit-caption):
      // Readability 가 class 와 data-* 를 지우므로 figcaption 으로 바꿔 두고(그건 남는다) 걷기에서 설명(cap)으로 낸다
      doc.querySelectorAll('[class]').forEach((n) => {
        if (n.tagName === 'FIGCAPTION' || !/caption|cutline|credit|img_?desc|photo_?desc|desc_?img|fr-inner/i.test(klass(n))) return;
        if (!n.isConnected || (n.parentElement && n.parentElement.closest('figcaption'))) return;
        if (n.querySelector('img, picture, video, figure, table, ul, ol, h1, h2, h3, h4, h5, h6') || n.querySelectorAll('p').length > 1 || ln(n) > 400) return;
        const f = doc.createElement('figcaption');
        while (n.firstChild) f.appendChild(n.firstChild);
        n.replaceWith(f);
      });
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
          best = best.cloneNode(true);
          best.querySelectorAll('script, style, nav, form, button, .related-topics, [class*="related" i], [class*="share" i]').forEach((n) => n.remove());
          art = { title: document.title, content: '<div>' + best.innerHTML + '</div>' };
        }
      }
      if (!art || !art.content) return null;
      let content = art.content, partial = false;
      const parse = (h) => new DOMParser().parseFromString(h, 'text/html').body;
      const lenOf = (el) => norm(el.textContent).length;
      const longP = (el) => [...el.querySelectorAll('p')].filter((p) => lenOf(p) >= 80);
      const BAD = /related|recommend|share|social|promo|newsletter|comment|sidebar|links|tags?\\b|topic|footer|nav|advert|popular|most-?read|author|byline|headline|elsewhere|features|top-?stories/i;
      const isAd = (el) => /(^|[\\s_-])(ad|ads|adv|advert|advertisement|banner|sponsor)([\\s_-]|$)/i.test((el.className && el.className.baseVal === undefined ? el.className : '') + ' ' + (el.id || ''));
      const label = (el) => (el.className && el.className.baseVal === undefined ? el.className : '') + ' ' + (el.getAttribute('data-component') || '') + ' ' + (el.getAttribute('data-block') || '');
      const prune = (root) => { root.querySelectorAll('script, style, nav, form, aside, iframe').forEach((n) => n.remove()); root.querySelectorAll('*').forEach((n) => { if (n.isConnected && (isAd(n) || BAD.test(label(n)))) n.remove(); }); return root; };
      // Readability 가 고른 글이 원문 문서 어디인지(첫 긴 문단으로 찾음)
      const firstOf = (body) => { const p = [...body.querySelectorAll('p')].find((x) => lenOf(x) >= 40); return p ? norm(p.textContent).slice(0, 40) : ''; };
      const first = firstOf(parse(content));
      const anchor = first ? [...fresh.querySelectorAll('p')].find((p) => norm(p.textContent).startsWith(first)) : null;
      // B: itemprop=articleBody 가 따로 있는데 고른 글이 그 밖이면(옆 상자를 고름) 그쪽을 쓴다
      const ip = [...fresh.querySelectorAll('[itemprop="articleBody"]')].find((e) => lenOf(e) >= 300);
      if (ip && !(anchor && ip.contains(anchor)) && lenOf(ip) >= lenOf(parse(content)) * 0.3) {
        content = '<div>' + prune(ip.cloneNode(true)).innerHTML + '</div>';
      } else if (anchor) {
        // A: 본문이 광고·사진을 사이에 둔 여러 덩어리면(같은 꼴의 형제) 모두 순서대로 모은다
        const firstClass = (el) => ((el.className && el.className.baseVal === undefined ? el.className : '').trim().split(/\\s+/)[0] || '');
        const alike = (a, b) => a.tagName === b.tagName && ((a.hasAttribute('data-block') && b.hasAttribute('data-block')) || (a.hasAttribute('data-component') && b.hasAttribute('data-component')) || (firstClass(a) !== '' && firstClass(a) === firstClass(b)));
        // 형제가 같은 꼴이거나, 겉 포장이 달라도 안에 본문 상자와 같은 class 의 상자가 있으면(Ars: div.my-2.5 > … > .post-content) 같은 본문
        const core = anchor.parentElement, coreClass = firstClass(core);
        // 같은 class 가 겹치면 바깥 상자만(후손은 바깥 사본에 이미 들어 있다 — 겹마다 복사하면 크기·시간이 N²)
        const outer = (list) => { const r = []; for (const c of list) if (!r.length || !r[r.length - 1].contains(c)) r.push(c); return r; };
        const cores = (k, el) => k === el || alike(k, el) || !coreClass || k.classList.contains(coreClass) ? [k] : outer([...k.querySelectorAll('.' + CSS.escape(coreClass))]);
        for (let el = core, depth = 0; el && el.parentElement && depth < 6; el = el.parentElement, depth++) {
          const kids = [...el.parentElement.children].filter((k) => k === el || ((alike(k, el) || (coreClass && k.querySelector('.' + CSS.escape(coreClass)))) && !BAD.test(label(k)) && !isAd(k)));
          const texty = kids.filter((k) => longP(k).length > 0);
          if (texty.length < 2 || !texty.includes(el)) continue;
          const from = kids.indexOf(texty[0]), to = kids.indexOf(texty[texty.length - 1]);
          // 모은 상자는 비활성 사본 문서(fresh)에서 만든다 — 살아 있는 문서에 붙이면 <img> 받기·onerror 가 돌 수 있다
          const box = fresh.createElement('div');
          // 모은 글이 원문 글의 2배를 넘으면(겹친 상자를 거듭 담은 꼴) 모으기를 그만둔다
          let size = 0; const cap = fresh.body ? fresh.body.textContent.length * 2 + 1000 : 0;
          kids.slice(from, to + 1).forEach((k) => cores(k, el).forEach((c) => { size += c.textContent.length; if (size <= cap) box.appendChild(prune(c.cloneNode(true))); }));
          // 글이 15% 넘게 늘거나, 글은 비슷한데(90% 이상) 사진이 더 있으면(BBC: Readability 가 사진 블록을 버림) 모은 쪽
          const cur = parse(content), more = lenOf(box) >= lenOf(cur) * 1.15;
          const pics = lenOf(box) >= lenOf(cur) * 0.9 && box.querySelectorAll('img').length > cur.querySelectorAll('img').length;
          if (size <= cap && (more || pics)) content = '<div>' + box.innerHTML + '</div>';
          break;
        }
        // 본문 영역(itemprop·article)에 우리 글에 없는 긴 문단이 여럿 남으면 '일부만'
        const area = ip || anchor.closest('article');
        if (area) {
          const got = norm(parse(content).textContent).replace(/\\s/g, '');
          const ps = longP(area).filter((p) => !BAD.test(label(p.parentElement || p)));
          const miss = ps.filter((p) => !got.includes(norm(p.textContent).replace(/\\s/g, '').slice(0, 30)));
          const all = ps.reduce((s, p) => s + lenOf(p), 0), gone = miss.reduce((s, p) => s + lenOf(p), 0);
          partial = miss.length >= 2 && gone > all * 0.25;
        }
      }
            // 캐러셀·슬라이드(Google 블로그 영상·인용 카드 · swiper·slick·glide·splide·owl): Readability 가 칸을 버리고, 화면 밖 칸은 숨겨져 있다(carousel-slides).
      // 원문에서 앞 글과 뒤 글이 모두 우리 본문에 있는 것(본문 사이)만 칸마다 글·사진을 순서대로 뒤 글 앞에 넣는다 — 본문 밖 추천 캐러셀은 넣지 않음.
      // 복제 칸(무한 돌기)·같은 칸은 한 번만, 칸 글 대부분이 링크면(추천 기사 줄) 넣지 않음. 인용 카드가 속성에만 든 글(quote=·author-name=)은 인용으로
      {
        const ckl = (el) => (el.className && el.className.baseVal === undefined ? el.className : '');
        const toks = (el) => ckl(el).split(/\\s+/).filter((x) => x);
        const isCar = (el) => /^carousel$/i.test(el.getAttribute('aria-roledescription') || '') || /-(carousel|slideshow)$/i.test(el.tagName)
          || toks(el).some((c) => /^(swiper|swiper-container|glide|slick-slider|splide|flickity|owl-carousel|slideshow)$/i.test(c) || /carousel/i.test(c));
        const isSlide = (el) => /^slide$/i.test(el.getAttribute('aria-roledescription') || '') || /-slide$/i.test(el.tagName)
          || toks(el).some((c) => /^(swiper-slide|glide__slide|slick-slide|splide__slide|owl-item|carousel-item|carousel-cell)$/i.test(c) || /(__|-)slide$/i.test(c));
        const isClone = (el) => toks(el).some((c) => /^(swiper-slide-duplicate|slick-cloned|cloned)$/i.test(c) || /--clone$/i.test(c));
        const outerOf = (list) => list.filter((x) => !list.some((y) => y !== x && y.contains(x)));
        const cln = (el) => norm(el.textContent).length;
        const all = [...fresh.querySelectorAll('*')];
        const roots = outerOf(all.filter(isCar)).filter((r) => !r.closest('nav, header, footer, aside') && !/related|recommend|promo|popular|most-?read|trending|ranking|newsletter/i.test(ckl(r) + ' ' + (r.getAttribute('data-component') || '')));
        if (roots.length) {
          const cur = parse(content);
          const TXT = 'p, li, h1, h2, h3, h4, h5, h6, blockquote';
          const found = new Map();
          cur.querySelectorAll(TXT).forEach((e) => { const t = norm(e.textContent); if (!found.has(t)) found.set(t, []); found.get(t).push(e); });
          // 같은 글이 차례(목차 li)에도 있으면 같은 태그를 앞세운다 · 앞 캐러셀을 넣으며 지운 요소는 빼고(떨어진 노드와의 앞뒤는 정해져 있지 않다 — review-4 L5)
          const pick = (m) => { const l = ((m && found.get(norm(m.textContent))) || []).filter((e) => e.isConnected); const same = l.filter((e) => e.tagName === m.tagName); return same.length ? same : l; };
          const marks = [...fresh.querySelectorAll(TXT)].filter((e) => { const n = cln(e); return (n >= 12 || (/^H/.test(e.tagName) && n >= 4)) && !roots.some((r) => r.contains(e)); });
          const before = (a, b) => !!(a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING);
          const RECO_HEAD = /^(recommended|related|read more|more on this|more from|keep reading|you may also like|also read|관련\\s?기사|추천\\s?기사|함께\\s?(볼|읽을)|많이\\s?본)/i;
          // 캐러셀 바깥 바로 앞 형제 제목도 본다 — 뿌리가 앞 형제 없이 감싸여 있으면 세 겹까지 올라가고, 글이 제목 하나뿐인 상자(머리말 상자)면 그 제목
          const headBefore = (r) => { let s = r; for (let i = 0; i < 3 && !s.previousElementSibling && s.parentElement; i++) s = s.parentElement; const p = s.previousElementSibling; if (!p) return null; if (/^H[1-6]$/.test(p.tagName)) return p; const h = p.querySelector('h1, h2, h3, h4, h5, h6'); return h && norm(h.textContent) === norm(p.textContent) ? h : null; };
          // 칸 글 양 상한: 본문(캐러셀 밖 글 중 우리 본문에 있는 것) 글자의 2배, 적어도 3000자 · 칸 50개
          const cap = Math.max(2 * marks.filter((m) => found.has(norm(m.textContent))).reduce((z, m) => z + cln(m), 0), 3000);
          let added = false;
          roots.forEach((r) => {
            if ([r.querySelector('h1, h2, h3, h4, h5, h6'), headBefore(r)].some((hd) => hd && RECO_HEAD.test(norm(hd.textContent)))) return;
            let prev = null, next = null;
            for (const m of marks) { if (before(m, r)) prev = m; else if (before(r, m)) { next = m; break; } }
            const pms = pick(prev), nm = pick(next).find((n) => pms.some((q) => before(q, n)));
            if (!nm) return;
            const pm = pms.filter((q) => before(q, nm)).pop();
            const every = outerOf(all.filter((s) => s !== r && r.contains(s) && isSlide(s)));
            let slides = every.filter((s) => !isClone(s));
            if (!slides.length) return;
            const idx = (s) => s.getAttribute('data-swiper-slide-index') || '';
            if (slides.every((s) => /^\\d+$/.test(idx(s)))) slides = slides.map((s, i) => [s, i]).sort((a, b) => (+idx(a[0]) - +idx(b[0])) || a[1] - b[1]).map((x) => x[0]);
            const wrap = fresh.createElement('div'), keys = [], units = new Set(), srcs = new Set();
            let text = 0, link = 0;
            slides.forEach((s) => {
              // 상한을 넘은 칸은 넣지 않되, Readability 가 남긴 같은 칸은 지우게 글·사진만 적어 둔다
              if (keys.length >= 50 || text > cap) { [s, ...s.querySelectorAll('p, li, h1, h2, h3, h4, h5, h6, blockquote, figcaption')].forEach((e) => { const u = norm(e.textContent); if (u) units.add(u); }); s.querySelectorAll('img').forEach((i) => { const x = i.getAttribute('src') || i.getAttribute('data-src') || ''; if (x) srcs.add(x); }); return; }
              const c = s.cloneNode(true);
              c.querySelectorAll('button, [role="tablist"], [class*="pagination" i], [class*="controls" i], [class*="arrow" i], [class*="dots" i]').forEach((n) => n.remove());
              c.querySelectorAll('*').forEach((n) => {
                const q = norm(n.getAttribute('quote') || n.getAttribute('data-quote') || '');
                if (q.length < 20) return;
                const bq = fresh.createElement('blockquote'); bq.textContent = q;
                const who = [n.getAttribute('author-name') || n.getAttribute('data-author-name') || n.getAttribute('author') || '', n.getAttribute('author-title') || n.getAttribute('data-author-title') || ''].map(norm).filter((x) => x).join(', ');
                n.replaceWith(bq);
                if (who) { const p = fresh.createElement('p'); p.textContent = '— ' + who; bq.after(p); }
              });
              // 사진 없는 칸의 설명 상자(앞에서 figcaption 으로 바꾼 것)는 문단으로 — 짝 잃은 설명처럼 작게 보이지 않게
              if (!c.querySelector('img, picture')) c.querySelectorAll('figcaption').forEach((f) => { const p = fresh.createElement('p'); while (f.firstChild) p.appendChild(f.firstChild); f.replaceWith(p); });
              const t = norm(c.textContent), src = [...c.querySelectorAll('img')].map((i) => i.getAttribute('src') || i.getAttribute('data-src') || '').filter((x) => x), key = t + '|' + src.join(' ');
              if (key === '|' || keys.includes(key)) return;
              keys.push(key);
              if (t) units.add(t);
              c.querySelectorAll('p, li, h1, h2, h3, h4, h5, h6, blockquote, figcaption').forEach((e) => { const u = norm(e.textContent); if (u) units.add(u); });
              src.forEach((x) => srcs.add(x));
              text += t.length; link += [...c.querySelectorAll('a')].reduce((z, a) => z + cln(a), 0);
              // 칸의 class(headline·features 등)로 prune 이 글을 지우지 않게 꼴 속성은 뗀다(사진 주소 data-src·srcset 은 남김)
              c.querySelectorAll('*').forEach((n) => ['class', 'id', 'style', 'data-component', 'data-block', 'hidden', 'aria-hidden'].forEach((a) => n.removeAttribute(a)));
              const d = fresh.createElement('div'); // 칸이 li 여도(owl·slick) 걷기가 한 줄로 뭉치지 않게 div 로
              while (c.firstChild) d.appendChild(c.firstChild);
              wrap.appendChild(d);
            });
            if (!wrap.firstChild || (text && link >= text * 0.6)) return;
            every.filter(isClone).forEach((s) => { const u = norm(s.textContent); if (u) units.add(u); s.querySelectorAll('p, li, figcaption').forEach((e) => { const v = norm(e.textContent); if (v) units.add(v); }); });
            // Readability 가 보이는 칸만 남겼으면(앞 글과 뒤 글 사이) 그것을 빼고 모든 칸을 차례대로 넣는다 — 같은 칸이 두 번·뒤섞여 나오지 않게
            const between = (e) => before(pm, e) && before(e, nm);
            cur.querySelectorAll('p, li, h1, h2, h3, h4, h5, h6, blockquote, figcaption, div').forEach((e) => { if (e.isConnected && between(e) && units.has(norm(e.textContent))) e.remove(); });
            cur.querySelectorAll('img').forEach((e) => { const u = e.getAttribute('src') || e.getAttribute('data-src') || ''; if (u && srcs.has(u) && between(e)) e.remove(); });
            nm.before(wrap);
            added = true;
          });
          if (added) content = '<div>' + cur.innerHTML + '</div>';
        }
      }
      const box = prune(parse(content));
      // 유료 표시: ld+json isAccessibleForFree=false 또는 한경 articlePayment="Y"
      let paid = null, ldBody = null;
      document.querySelectorAll('script[type="application/ld+json"]').forEach((s) => {
        const m = (s.textContent || '').match(/"isAccessibleForFree"\\s*:\\s*"?(true|false)"?/i);
        if (m && paid === null) paid = m[1].toLowerCase() === 'false';
        const find = (v) => { if (!v || typeof v !== 'object') return null; if (typeof v.articleBody === 'string' && v.articleBody) return v.articleBody; for (const k in v) { const r = find(v[k]); if (r) return r; } return null; };
        try { const b = find(JSON.parse(s.textContent || '')); if (b) ldBody = Math.max(ldBody || 0, norm(b.replace(/<[^>]*>/g, ' ')).length); } catch (e) {}
      });
      if (paid !== true) for (const s of document.querySelectorAll('script:not([src])')) { if (/articlePayment\\s*=\\s*["']Y["']/.test(s.textContent || '')) { paid = true; break; } }
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
      const clean = (s) => (s || '').replace(/\\((opens in a new (window|tab)|새 창에서 열기)\\)/gi, '').replace(/\\b(hide|toggle) caption\\b/gi, '').replace(/\\s+/g, ' ').trim();
      // <br> 은 빈칸으로(글이 붙지 않게)
      const tx = (n) => { const c = n.cloneNode(true); c.querySelectorAll('br').forEach((b) => b.replaceWith(' ')); return c.textContent; };
      const INLINE = new Set(['a', 'b', 'strong', 'em', 'i', 'u', 'span', 'font', 'small', 'mark', 'abbr', 'cite', 'code', 'time', 'q', 's', 'del', 'ins', 'sub', 'sup', 'label']);
      const hasBlock = (n) => !!n.querySelector('p, div, ul, ol, li, h1, h2, h3, h4, h5, h6, blockquote, figure, img, picture, table, pre, section, article');
      // 표(AWS·Hugging Face 벤치마크 표): 행마다 한 블록(셀은 따로, 글은 ' · ' 로 이음). 머리행은 thead·th 뿐이거나 첫 행 셀이 모두 굵은 글.
      // 칸이 하나뿐이거나 안에 사진·목록·소제목·긴 셀이 든 표는 자리 잡기용이라 안을 그대로 걷는다
      const table = (t) => {
        const cellsOf = (tr) => [...tr.children].filter((c) => c.tagName === 'TD' || c.tagName === 'TH');
        const rows = [...t.querySelectorAll('tr')].filter((tr) => tr.closest('table') === t && cellsOf(tr).length > 0);
        if (rows.length < 2 || Math.max(...rows.map((r) => cellsOf(r).length)) < 2) return false;
        if (t.querySelector('table table, img, picture, figure, pre, ul, ol, blockquote, h1, h2, h3, h4, h5, h6')) return false;
        if (rows.some((r) => cellsOf(r).some((c) => lenOf(c) > 400))) return false;
        const bold = (c) => { const t = norm(c.textContent); return !t || [...c.querySelectorAll('strong, b')].map((x) => norm(x.textContent)).join(' ') === t; };
        const cap = t.querySelector('caption'); const ct = cap && clean(tx(cap));
        if (ct) blocks.push({ type: 'cap', text: ct });
        rows.forEach((tr, k) => {
          const cs = cellsOf(tr), cells = cs.map((c) => clean(tx(c)));
          if (!cells.some((c) => c)) return;
          const head = !!tr.closest('thead') || cs.every((c) => c.tagName === 'TH') || (k === 0 && cs.every(bold));
          blocks.push({ type: 'row', text: cells.join(' · '), cells, head: head || null });
        });
        return true;
      };
      const walk = (el) => {
        // 요소 사이 맨 글자(동아처럼 <br><br> 로 문단을 나눈 본문)도 문단으로 모은다
        let buf = '', brs = 0;
        const flush = () => { const t = clean(buf); if (t.length > 1) blocks.push({ type: 'p', text: t }); buf = ''; brs = 0; };
        for (const n of el.childNodes) {
          if (n.nodeType === 3) { if (n.textContent.trim()) brs = 0; buf += n.textContent; continue; }
          if (n.nodeType !== 1) continue;
          const tag = n.tagName.toLowerCase();
          if (tag === 'br') { brs++; if (brs >= 2) flush(); else buf += ' '; continue; }
          if (tag === 'figcaption') { flush(); const c = clean(tx(n)); if (c) blocks.push({ type: 'cap', text: c }); continue; }
          if (INLINE.has(tag) && !hasBlock(n)) { buf += tx(n); brs = 0; continue; }
          flush();
          // 글은 쓰는 태그만 만든다(겹친 div 마다 하위 전체를 복사하면 깊이²)
          const t = /^(h[1-6]|p|li|blockquote|pre)$/.test(tag) ? clean(tx(n)) : '';
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
            const c = [...n.querySelectorAll('figcaption')].map((x) => clean(tx(x))).filter((x) => x).join(' · ');
            if (c) blocks.push({ type: 'cap', text: c });
          }
          else if (tag === 'table') { if (!table(n)) walk(n); }
          else walk(n);
        }
        flush();
      };
      walk(box);
      // 문단 태그 없이 맨 글자로 든 본문(GeekNews 등): 줄 단위로 문단을 만든다
      if (!blocks.some((b) => b.type === 'p' || b.type === 'li')) {
        (box.innerText || box.textContent || '').split(/\\n+/).map(clean).filter((t) => t.length > 1).forEach((t) => blocks.push({ type: 'p', text: t }));
      }
      // 같은 글·같은 사진이 또 나오면 뺀다(화면 크기별로 기사를 여러 벌 싣는 사이트 — Politico, 부제·사진 설명 중복)
      const seen = new Set();
      const uniq = blocks.filter((b) => { const k = b.type === 'img' ? 'img ' + b.src : ((b.text || '').length >= 30 ? b.type + ' ' + b.text : null); if (!k) return true; if (seen.has(k)) return false; seen.add(k); return true; });
      blocks.length = 0; blocks.push(...uniq);
      // 사진 설명·출처가 문단으로 온 것(경향 '… 제공'·CNBC '| Getty Images'·NPR 'for NPR'·'/AP'): 사진 바로 뒤의 짧은 출처 줄은 설명으로,
      // 사진 바로 앞이면(노컷) 사진 뒤로 옮겨 설명으로. 이어진 설명은 하나로 합친다
      const CREDIT = /(\\|\\s*(Getty Images|AP|AFP|Reuters|Bloomberg|EPA)\\b|(Getty Images|\\/\\s?(AP|AFP|Reuters|EPA|Bloomberg|Getty)|for NPR|via Getty Images|via AP)\\s*\\)?\\.?$|^(Photo|Photograph|Credit|Illustration|Image)( credit)?\\s*:|^[(\\[]?(사진|그래픽|자료|이미지)\\s*[=:]|(제공|연합뉴스|뉴스1|뉴시스|게티이미지(뱅크|코리아)?|AFP|AP|로이터|EPA)(\\s*[=\\/]\\s*\\S+)?\\s*[)\\]]?\\.?$)/;
      for (let i = 0; i < blocks.length; i++) {
        const b = blocks[i];
        if (b.type !== 'p' || b.text.length > 150 || !CREDIT.test(b.text)) continue;
        const prev = blocks[i - 1], next = blocks[i + 1];
        if (prev && (prev.type === 'img' || (prev.type === 'cap' && blocks[i - 2] && blocks[i - 2].type === 'img'))) b.type = 'cap';
        else if (prev && prev.type === 'p' && prev.text.length <= 200 && blocks[i - 2] && blocks[i - 2].type === 'img') { prev.type = 'cap'; b.type = 'cap'; } // 설명 문장 + 출처 줄
        else if (next && next.type === 'img') { b.type = 'cap'; blocks[i] = next; blocks[i + 1] = b; i++; }
      }
      for (let i = blocks.length - 1; i > 0; i--) {
        const a = blocks[i - 1], b = blocks[i];
        if (a.type === 'cap' && b.type === 'cap') { if (!a.text.includes(b.text)) a.text = a.text + ' · ' + b.text; blocks.splice(i, 1); }
      }
      // 기사 글은 거의 없고 목록(메뉴·많이 본 기사)만 많으면 본문이 아니다(사진뿐인 속보 등) — 빈 본문으로 돌려 '글 거의 없음' 안내
      const sum = (types) => blocks.filter((b) => types.includes(b.type)).reduce((s, b) => s + (b.text || '').length, 0);
      const prose = sum(['p', 'quote', 'h']), listed = sum(['li']);
      if (prose < 150 && listed > prose * 2) return JSON.stringify({ title: art.title, blocks: [] });
      return JSON.stringify({ title: art.title, byline: art.byline, siteName: art.siteName, blocks, paid, partial: partial || null, ldBody });
    })();
    """

    // 1) 빠른 길: HTML 만 받아 스크립트·그림·글꼴 없이 바로 본문을 추린다(대부분의 언론사는 여기서 끝남)
    // 2) 느린 길: 스크립트로 본문을 그리는 사이트만 실제로 띄운다. 그림·동영상·글꼴은 막고, 본문이 생기는 대로 바로 꺼낸다.
    // allowScripts: 사용자가 직접 연 기사일 때만 true. 미리 받기에서는 사이트의 스크립트를 돌리지 않는다.
    func extract(_ url: URL, allowScripts: Bool = true) async -> Article? {
        trace = ExtractTrace()
        guard await URLSafety.resolvesPublic(url) else { trace.skipped = "unsafe"; return nil }
        let t0 = Date()
        defer { if trace.path == "slow" || trace.skipped != nil { trace.slowSeconds = Date().timeIntervalSince(t0) - trace.fastSeconds } }
        let host = url.host?.lowercased() ?? ""
        var refused = false // 사이트가 접근을 거부(401·403·429)
        var richPage = false // 받은 HTML 에 글이 이미 많다(스크립트로 그리는 빈 껍데기가 아님)
        do {
            if let got = try await FeedService.shared.fetchWithEncoding(url.absoluteString, limit: .page) {
                let art = await run(data: got.data, encoding: got.encoding ?? Self.sniffCharset(got.data), base: url)
                trace.fastSeconds = Date().timeIntervalSince(t0)
                trace.visible = Self.visibleTextLength(got.data)
                if var art {
                    if art.paid == nil { art.paid = Self.paidFlag(got.data) } // 스크립트를 끈 빠른 길에서는 페이지의 <script> 를 못 읽는다
                    if art.ldBody == nil { art.ldBody = Self.ldBodyLength(got.data) }
                    trace.path = "fast"
                    NSLog("[기사] 빠른 길 %.2f초 %@", Date().timeIntervalSince(t0), host)
                    return art
                }
                if var art = EmbeddedArticle.extract(got.data) { // 스크립트로 그리는 사이트가 HTML 에 실어 보낸 본문 자료
                    art.paid = Self.paidFlag(got.data)
                    art.ldBody = Self.ldBodyLength(got.data)
                    trace.path = "embedded"
                    trace.fastSeconds = Date().timeIntervalSince(t0)
                    NSLog("[기사] 실린 본문 자료 %.2f초 %@", trace.fastSeconds, host)
                    return art
                }
                richPage = trace.visible > 600 // 스크립트로 그리는 빈 껍데기는 보이는 글이 거의 없다
            }
        } catch FeedError.http(let code) where [401, 403, 429].contains(code) {
            refused = true
            trace.http = code
        } catch {
            if case FeedError.http(let code) = error { trace.http = code } else { trace.fetchError = error.localizedDescription }
            trace.offline = error is URLError
        }
        if trace.fastSeconds == 0 { trace.fastSeconds = Date().timeIntervalSince(t0) }
        guard allowScripts else { trace.skipped = "noScripts"; return nil }
        if let c = trace.http, [404, 410].contains(c) { trace.skipped = "gone"; return nil } // 없어진 페이지는 띄워 봐도 같다
        // 접근을 거부하는 사이트(예: GeekNews 403)는 느린 길도 대개 막힌다: 짧게만 시도하고, 그래도 막히면 이번 실행 동안은 바로 대체 화면
        if Self.blockedHosts.contains(host) { trace.skipped = "blockedHost"; NSLog("[기사] %@ 은 막힌 사이트라 건너뜀", host); return nil }
        // 글이 다 들어 있는데도 못 추린 페이지는 스크립트를 돌려도 같으므로 느린 길(최대 15초)을 건너뛴다
        if richPage { trace.skipped = "richPage"; NSLog("[기사] 빠른 길 실패, 글이 있는 페이지라 느린 길 건너뜀 %@", host); return nil }
        trace.path = "slow"
        let art = await run(url: url, maxWait: Self.slowWait(refused: refused, host: host))
        Self.noteSlow(host: host, refused: refused, ok: art != nil)
        NSLog("[기사] 느린 길 %.2f초 %@ %@", Date().timeIntervalSince(t0), host, art == nil ? "실패" : "성공")
        return art
    }

    // 받은 HTML 로 빠른 길만(시험·점검용): 스크립트 없이 추리고, 못 찾으면 실린 본문 자료
    func extractHTML(_ html: String, base: URL) async -> Article? {
        let data = Data(html.utf8)
        guard var art = await run(data: data, encoding: "utf-8", base: base) ?? EmbeddedArticle.extract(data) else { return nil }
        if art.paid == nil { art.paid = Self.paidFlag(data) }
        if art.ldBody == nil { art.ldBody = Self.ldBodyLength(data) }
        return art
    }

    // ld+json 의 articleBody 글자 수(빈칸을 하나로 — 우리 본문 글자 수와 같은 셈). 앞 1MB의 ld+json 만 본다
    nonisolated static func ldBodyLength(_ data: Data) -> Int? {
        let h = String(decoding: data.prefix(1_000_000), as: UTF8.self)
        var rest = h[...], best: Int?
        func find(_ v: Any) -> String? {
            if let d = v as? [String: Any] {
                if let b = d["articleBody"] as? String, !b.isEmpty { return b }
                for x in d.values { if let b = find(x) { return b } }
            } else if let a = v as? [Any] {
                for x in a { if let b = find(x) { return b } }
            }
            return nil
        }
        while let start = rest.range(of: "application/ld+json", options: .caseInsensitive) {
            guard let gt = rest[start.upperBound...].firstIndex(of: ">"),
                  let close = rest[gt...].range(of: "</script>", options: .caseInsensitive) else { break }
            let json = rest[rest.index(after: gt)..<close.lowerBound]
            if let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)), let body = find(obj) {
                let n = Plain.clean(body).count
                best = max(best ?? 0, n)
            }
            rest = rest[close.upperBound...]
        }
        return best
    }

    // 사이트가 유료 기사라고 적었나: ld+json "isAccessibleForFree": false · 한경 articlePayment = "Y"(앞 1MB만 봄)
    nonisolated static func paidFlag(_ data: Data) -> Bool? {
        let h = String(decoding: data.prefix(1_000_000), as: UTF8.self)
        if let r = h.range(of: #""isAccessibleForFree"\s*:\s*"?(true|false|True|False)"#, options: .regularExpression) {
            return h[r].lowercased().hasSuffix("false")
        }
        if h.range(of: #"articlePayment\s*=\s*["']Y["']"#, options: .regularExpression) != nil { return true }
        return nil
    }

    // 스크립트·스타일을 뺀 보이는 글자 수(대략)
    // 정규식 대신 한 번 훑기: 닫히지 않은 <script 가 많은 페이지에서 정규식이 끝까지 되풀이해 훑는 일(시간 폭증)을 막는다(윈도우판과 같음)
    nonisolated static func visibleTextLength(_ data: Data) -> Int {
        let h = Array(String(decoding: data.prefix(800_000), as: UTF8.self).unicodeScalars)
        let skip = ["script", "style", "noscript", "svg"].map { Array($0.unicodeScalars) }
        func lower(_ c: Unicode.Scalar) -> Unicode.Scalar { c.value >= 65 && c.value <= 90 ? Unicode.Scalar(c.value + 32)! : c }
        func find(_ needle: [Unicode.Scalar], from: Int) -> Int? { // 대소문자 무시
            guard needle.count <= h.count - from else { return nil }
            var i = from
            while i + needle.count <= h.count {
                var k = 0
                while k < needle.count, lower(h[i + k]) == needle[k] { k += 1 }
                if k == needle.count { return i }
                i += 1
            }
            return nil
        }
        var count = 0, space = true, i = 0
        while i < h.count {
            let c = h[i]
            if c == "<" {
                guard let close = h[i...].firstIndex(of: ">") else { break } // 닫히지 않은 꼬리표 뒤는 글이 아님
                let tag = h[(i + 1)..<close]
                let name = skip.first { t in
                    tag.count >= t.count && zip(tag, t).allSatisfy { lower($0) == $1 }
                        && (tag.count == t.count || !(tag[tag.startIndex + t.count].properties.isAlphabetic || tag[tag.startIndex + t.count].properties.numericType != nil))
                }
                i = close + 1
                if let name {
                    guard let end = find(Array("</".unicodeScalars) + name, from: i) else { break } // 끝까지 스크립트
                    i = end + 2 + name.count
                    i = h[i...].firstIndex(of: ">").map { $0 + 1 } ?? h.count
                }
                if !space { count += 1; space = true }
                continue
            }
            if c.properties.isWhitespace { if !space { count += 1; space = true } } else { count += 1; space = false }
            i += 1
        }
        return count
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

    // 내부망·내 Mac 주소: 느린 길은 자바스크립트가 켜져 있어 이동은 막아도 페이지 스크립트의 fetch·XHR·사진 요청이
    // 내부망으로 나갈 수 있다. 그런 주소로 가는 요청은 종류와 상관없이 막는다. WebKit 규칙 정규식은 '|'·'{n}' 를 못 써서 하나씩.
    // 10진수·16진수 IP 표기는 WebKit 이 주소를 읽을 때 점 네 칸으로 바꿔 둔다.
    nonisolated static let privateNetworkFilters: [String] = {
        let head = "^[a-z][a-z0-9+.-]*://([^/?#]*@)?"
        let v4 = ["127\\.", "10\\.", "0\\.", "192\\.168\\.", "169\\.254\\.", "172\\.1[6-9]\\.", "172\\.2[0-9]\\.", "172\\.3[01]\\.",
                  "100\\.6[4-9]\\.", "100\\.[7-9][0-9]\\.", "100\\.1[01][0-9]\\.", "100\\.12[0-7]\\."].map { head + $0 }
        let names = ["localhost[.]?[:/?#]", "localhost[.]?$", "[^/?#:]*\\.localhost[.]?[:/?#]", "[^/?#:]*\\.localhost[.]?$",
                     "[^/?#:]*\\.local[.]?[:/?#]", "[^/?#:]*\\.local[.]?$"].map { head + $0 }
        let v6 = ["\\[::\\]", "\\[::1\\]", "\\[f[cd][0-9a-f]*:", "\\[fe[89ab][0-9a-f]*:", "\\[::ffff:"].map { head + $0 }
        return v4 + names + v6
    }()

    nonisolated static func rules(block types: [String]) -> [[String: Any]] {
        [["trigger": ["url-filter": ".*", "resource-type": types], "action": ["type": "block"]]]
            + privateNetworkFilters.map { ["trigger": ["url-filter": $0, "url-filter-is-case-sensitive": false], "action": ["type": "block"]] }
    }

    // 컴파일한 규칙은 id 로 디스크에 남는다: 규칙을 바꾸면 id 끝 숫자를 올린다(예전 규칙을 다시 꺼내 쓰지 않게)
    private static func ruleList(_ id: String, _ types: [String]) async -> WKContentRuleList? {
        if let c = compiled[id] { return c }
        if let found = try? await WKContentRuleListStore.default().contentRuleList(forIdentifier: id) {
            compiled[id] = found
            return found
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rules(block: types)), let json = String(data: data, encoding: .utf8) else { return nil }
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
        let w = await makeWeb(js: false, block: ["image", "media", "font", "style-sheet", "script", "raw", "svg-document", "popup", "fetch", "websocket", "other"], id: "ainews-fast-2")
        web = w
        defer { w.stopLoading(); web = nil }
        loadDone = false
        scriptTimedOut = false
        w.load(data, mimeType: "text/html", characterEncodingName: encoding, baseURL: base)
        await waitForLoad(seconds: 6)
        return await tryExtract(w)
    }

    @MainActor static var blockedHosts: Set<String> = []
    @MainActor static var slowWorks: Set<String> = []        // 느린 길로 열린 적이 있는 사이트(NYT 처럼 빠른 길만 403)
    @MainActor static var refusedFails: [String: Int] = [:]  // 거절된 뒤 느린 길도 못 연 횟수(이어서)

    // 거절(401·403·429)한 사이트는 느린 길도 대개 막히니 짧게. 단, 느린 길로 열린 적이 있으면 넉넉히(READSWEEP: NYT 6초 넘는 기사 하나)
    @MainActor static func slowWait(refused: Bool, host: String) -> TimeInterval {
        !refused ? 15 : (slowWorks.contains(host) ? 10 : 6)
    }

    // 막힌 사이트로 기억(이번 실행 동안 바로 대체 화면)은 느린 길로 열린 적이 없고 두 번 이어서 못 열었을 때만 — 기사 하나 실패로 사이트 전체를 막지 않는다
    @MainActor static func noteSlow(host: String, refused: Bool, ok: Bool) {
        if ok { slowWorks.insert(host); refusedFails[host] = nil; return }
        guard refused, !slowWorks.contains(host) else { return }
        refusedFails[host, default: 0] += 1
        if refusedFails[host]! >= 2 { blockedHosts.insert(host) }
    }

    private func run(url: URL, maxWait: TimeInterval = 15) async -> Article? {
        let w = await makeWeb(js: true, block: ["image", "media", "font", "popup", "websocket"], id: "ainews-full-2")
        web = w
        defer { w.stopLoading(); web = nil }
        scriptTimedOut = false
        w.load(URLRequest(url: url, timeoutInterval: 20))
        // 다 뜨기를 기다리지 않고, 0.6초 뒤부터 0.4초마다 본문이 생겼는지 본다(최대 15초)
        let deadline = Date().addingTimeInterval(maxWait)
        try? await Task.sleep(for: .milliseconds(600))
        var last = 0
        while Date() < deadline, !scriptTimedOut {
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
        guard !scriptTimedOut else { return nil }
        let loaded = await evaluate(w, "typeof Readability !== 'undefined'") as? Bool ?? false
        if !loaded { _ = await evaluate(w, Self.readability + "\n;true") }
        if ProcessInfo.processInfo.environment["DROPCAP_DEBUG_EXTRACT"] != nil { // 진단용
            do { let r = try await w.evaluateJavaScript(Self.script, in: nil, contentWorld: .defaultClient); NSLog("[추출 진단] %@", String(describing: r).prefix(600) as CVarArg) }
            catch { NSLog("[추출 진단] 오류 %@", String(describing: error)) }
        }
        guard let json = await evaluate(w, Self.script) as? String,
              let art = try? JSONDecoder().decode(Article.self, from: Data(json.utf8)) else { return nil }
        let textLen = art.blocks.compactMap(\.text).joined().count
        guard // 짧은 글(소개글·단신)도 받는다: 글 100자 이상이면 본문으로(예전 '2문단·280자' 기준은 GeekNews 같은 짧은 글을 버렸다)
              !art.blocks.filter({ $0.text != nil }).isEmpty,
              textLen >= 100 else { trace.shortText = textLen; return nil }
        trace.shortText = nil
        return art
    }

    // 추출 스크립트 시간 제한: 넘으면 이 기사만 실패로(스크립트는 멈출 수 없으니 기다리지 않고, 이 웹 보기에서는 더 돌리지 않는다)
    private var scriptTimedOut = false
    nonisolated static let scriptSeconds: Double = 8
    private func evaluate(_ w: WKWebView, _ js: String) async -> Any? {
        await withCheckedContinuation { c in
            var done = false
            let finish = { (v: Any?) in
                guard !done else { return }
                done = true
                c.resume(returning: v)
            }
            w.evaluateJavaScript(js, in: nil, in: .defaultClient) { r in finish(try? r.get()) }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.scriptSeconds) { [weak self] in
                guard !done else { return }
                self?.scriptTimedOut = true
                NSLog("[기사] 추출 스크립트 %.0f초 넘음 — 이 기사는 실패로", Self.scriptSeconds)
                finish(nil)
            }
        }
    }

    private func waitForLoad(seconds: Double) async {
        await withTaskGroup(of: Void.self) { g in
            g.addTask { @MainActor in
                await withCheckedContinuation { c in
                    if self.loadDone { c.resume() } else { self.continuation = c }
                }
            }
            g.addTask { try? await Task.sleep(for: .seconds(seconds)) }
            await g.next()
            g.cancelAll()
            self.finishWait()
        }
    }

    private func finishWait() {
        loadDone = true
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
