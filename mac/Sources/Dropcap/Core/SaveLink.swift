import AppKit
import Foundation

// 피드에 없는 기사도 '나중에 읽기'로: 서비스 메뉴 'Dropcap 에 저장', dropcap://save?url=… 주소, 저장 목록의 '주소로 추가…' 칸.
// 받은 주소는 공개 http(s) 주소인지 먼저 보고(URLSafety), 기사 머리(og:title·og:image·og:site_name)로 소식을 만들어 저장 목록에 넣는다.
// 본문은 지금의 저장과 똑같이 미리 받아(번역까지) 보관하므로 인터넷 없이도 읽힌다.
enum SaveLink {
    static let tier = "웹에서 저장"          // 출처 등급 이름표(Resources.tierLabel 이 그대로 보여 줌)
    static let sourcePrefix = "web:"
    static let maxLength = 2048

    enum Failure: Error, Equatable {
        case notURL, unsafe, tooMany
        var message: String {
            switch self {
            case .notURL: return "http(s) 기사 주소가 아닙니다"
            case .unsafe: return "내부망·특수 주소는 저장하지 않습니다"
            case .tooMany: return "잠깐 사이에 너무 많이 들어와 멈췄어요"
            }
        }
    }

    // MARK: 주소 해석(순수 함수 — 시험 대상)

    // 사람이 넣거나 서비스로 받은 글에서 저장할 주소 하나. 공개 http(s) 주소만, 조각(#…)과 앞뒤 꺾쇠·따옴표는 뗀다.
    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'“”‘’"))
        guard !s.isEmpty, s.count <= maxLength, !s.contains(where: { $0.isWhitespace }) else { return nil }
        if !s.contains("://") { // 'example.com/a' 처럼 스킴 없이 넣은 주소
            guard s.contains("."), !s.hasPrefix("/"), !s.contains(":") || s.range(of: #"^[^/]+:\d+(/|$)"#, options: .regularExpression) != nil else { return nil }
            s = "https://" + s
        }
        guard var c = URLComponents(string: s) else { return nil }
        c.fragment = nil
        guard c.user == nil, c.password == nil, let u = c.url, URLSafety.isPublicHTTP(u) else { return nil } // 아이디·암호가 든 주소는 받지 않음
        return u
    }

    // dropcap://save?url=<주소>[&title=<제목>] — 브라우저 북마클릿·단축어용
    static func parseScheme(_ url: URL) -> (url: URL, title: String?)? {
        guard url.scheme?.lowercased() == "dropcap",
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let action = (c.host ?? c.path).trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        guard action == "save" else { return nil }
        let q = c.queryItems ?? []
        guard let raw = q.first(where: { $0.name == "url" })?.value, let u = normalize(raw) else { return nil }
        let title = q.first(where: { $0.name == "title" })?.value.flatMap(cleanTitle)
        return (u, title)
    }

    // 서비스 메뉴로 받은 것: 주소 형식 → HTML 의 첫 링크 → 서식 글의 링크 → 글 속 첫 주소 순
    static func fromPasteboard(urls: [String], html: String?, rtfLinks: [URL], text: String?) -> URL? {
        for s in urls { if let u = normalize(s) { return u } }
        if let html, let u = firstHref(html) { return u }
        for l in rtfLinks { if let u = normalize(l.absoluteString) { return u } }
        if let text { return firstURL(in: text) }
        return nil
    }

    static func firstHref(_ html: String) -> URL? {
        for tag in HTMLScan.tags("a", in: html) {
            if let raw = HTMLScan.attr(tag, "href"), !raw.isEmpty, let u = normalize(Plain.decodeEntities(raw)) { return u }
        }
        return nil
    }

    static func firstURL(in text: String) -> URL? {
        if let u = normalize(text) { return u }
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for m in det.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let u = m.url, let ok = normalize(u.absoluteString) { return ok }
        }
        return nil
    }

    static func cleanTitle(_ s: String) -> String? {
        let t = Plain.clean(s)
        return t.isEmpty ? nil : String(t.prefix(300))
    }

    // 기사 머리에서 제목·사진·사이트 이름(앞 128KB 만)
    struct Head: Equatable { var title: String?; var image: String?; var site: String?; var description: String? }

    static func parseHead(_ html: String, base: URL) -> Head {
        // 꼬리표를 하나씩 떼어 본다(HTMLScan — 정규식 되풀이 훑기로 큰 페이지에서 멈추지 않게)
        func meta(_ names: [String]) -> String? { HTMLScan.meta(html, names, accept: cleanTitle) }
        var h = Head()
        h.title = meta(["og:title", "twitter:title"])
        if h.title == nil, let t = HTMLScan.title(html) { h.title = cleanTitle(t) }
        h.site = meta(["og:site_name", "application-name"])
        h.description = meta(["og:description", "description", "twitter:description"])
        if let raw = meta(["og:image", "og:image:url", "twitter:image"]),
           let u = URL(string: raw, relativeTo: base)?.absoluteURL, URLSafety.isPublicHTTP(u) { h.image = u.absoluteString }
        return h
    }

    // 사이트 이름이 없으면 주소의 이름(www. 뗌)
    static func siteName(_ head: Head, url: URL) -> String {
        if let s = head.site, !s.isEmpty { return String(s.prefix(60)) }
        var host = url.host ?? "웹"
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    static func makeItem(url: URL, head: Head, fallbackTitle: String? = nil, now: Date = Date()) -> NewsItem {
        let link = url.absoluteString
        let site = siteName(head, url: url)
        var title = head.title ?? fallbackTitle ?? Plain.titleFromSlug(url.path.isEmpty || url.path == "/" ? (url.host ?? link) : url.path)
        title = ArticleService.stripSiteName(title, source: site, feedTitle: title)
        title = stripHostSuffix(title, host: url.host ?? "")
        return NewsItem(id: link, title: title, titleKo: nil, link: link, date: now, summary: String((head.description ?? "").prefix(300)),
                        sourceId: sourcePrefix + (url.host ?? "web"), sourceName: site, tier: tier, image: head.image)
    }

    // 'Initial - Wikipedia' 처럼 끝에 붙은 사이트 이름(주소의 이름과 같은 것)을 뗀다
    static func stripHostSuffix(_ title: String, host: String) -> String {
        let h = host.lowercased().replacingOccurrences(of: "-", with: "")
        for sep in [" - ", " | ", " – ", " — ", " :: "] {
            guard let r = title.range(of: sep, options: .backwards) else { continue }
            let tail = title[r.upperBound...].lowercased().filter { $0.isLetter || $0.isNumber }
            let head = String(title[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            if tail.count >= 3, h.contains(tail), head.count >= 3 { return head }
        }
        return title
    }

    // MARK: 저장(받기 → 저장 목록 → 미리 받기)

    @MainActor private static var recent: [Date] = [] // 바깥(주소·서비스)에서 들어온 시각: 한꺼번에 몰려오면 멈춤

    @MainActor
    @discardableResult
    static func save(_ raw: String, title: String? = nil, fromOutside: Bool = false) async -> Result<NewsItem, Failure> {
        guard let u = normalize(raw) else { return .failure(.notURL) }
        return await save(u, title: title, fromOutside: fromOutside)
    }

    @MainActor
    @discardableResult
    static func save(_ url: URL, title: String? = nil, fromOutside: Bool) async -> Result<NewsItem, Failure> {
        if fromOutside {
            let now = Date()
            recent = recent.filter { now.timeIntervalSince($0) < 60 } + [now]
            guard recent.count <= 10 else { return .failure(.tooMany) } // 웹 페이지가 dropcap:// 를 마구 부르는 경우 대비
        }
        guard URLSafety.isPublicHTTP(url), await URLSafety.resolvesPublic(url) else { return .failure(.unsafe) }
        let app = AppModel.shared
        if let had = app.state.saved.first(where: { $0.link == url.absoluteString }) { return .success(had) } // 이미 저장함
        var head = Head()
        if let data = try? await FeedService.shared.fetch(url.absoluteString, limit: .page) {
            head = parseHead(String(decoding: data.prefix(131_072), as: UTF8.self), base: url)
        }
        let item = makeItem(url: url, head: head, fallbackTitle: title)
        if !app.isSaved(item) { app.toggleSaved(item) } // 저장 + 본문·번역 미리 받기(오프라인 읽기)
        return .success(item)
    }

    // 바깥에서 들어온 저장은 결과를 작은 알림으로 알린다
    @MainActor
    static func saveAndAnnounce(_ url: URL, title: String?) {
        Task {
            switch await save(url, title: title, fromOutside: true) {
            case .success(let it): ToastCenter.shared.showInfo("나중에 읽기에 저장했어요", sub: "\(it.sourceName) · \(it.displayTitle)")
            case .failure(let f): ToastCenter.shared.showInfo("저장하지 못했어요", sub: f.message)
            }
        }
    }

    // MARK: 앱에 연결(App.swift 에서 한 줄씩)

    @MainActor private static var ready = false
    @MainActor private static var early: [URL] = [] // 앱이 다 뜨기 전에 들어온 주소(dropcap:// 로 앱을 켰을 때)

    @MainActor static func install() {
        NSApp.servicesProvider = ServiceProvider.shared
        NSUpdateDynamicServices()
        ready = true
        if !early.isEmpty { let l = early; early = []; handle(l) }
    }

    @MainActor static func handle(_ urls: [URL]) {
        guard ready else { early += urls; return }
        for u in urls {
            if let (link, title) = parseScheme(u) { if confirm(link, title: title) { saveAndAnnounce(link, title: title) } }
            else { NSLog("[저장] 알 수 없는 주소: %@", u.absoluteString.prefix(200).description) }
        }
    }

    // 아무 웹 페이지나 dropcap:// 를 부를 수 있으므로(브라우저의 '항상 허용' 뒤에는 묻지 않음) 저장 전에 한 번 묻는다.
    // 서비스 메뉴는 사용자가 직접 고른 것이라 묻지 않는다. 시험(DROPCAP_TEST_SCHEME)에서는 묻지 않음.
    @MainActor static func confirm(_ url: URL, title: String?) -> Bool {
        if ProcessInfo.processInfo.environment["DROPCAP_TEST_SCHEME"] != nil { return true }
        let a = NSAlert()
        a.messageText = "이 페이지를 나중에 읽기에 저장할까요?"
        a.informativeText = [title, url.host, String(url.absoluteString.prefix(300))].compactMap { $0 }.joined(separator: "\n")
        a.addButton(withTitle: "저장")
        a.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }

    // 북마클릿: 지금 보고 있는 페이지를 Dropcap 에 저장
    static let bookmarklet = "javascript:(function(){location.href='dropcap://save?url='+encodeURIComponent(location.href)+'&title='+encodeURIComponent(document.title)})()"
}

// 서비스 메뉴 'Dropcap 에 저장'(Info.plist 의 NSServices · NSMessage=saveToDropcap)
final class ServiceProvider: NSObject {
    static let shared = ServiceProvider()

    @objc func saveToDropcap(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []).map(\.absoluteString)
            + [pboard.string(forType: .URL)].compactMap { $0 }
        let html = pboard.string(forType: .html)
        var links: [URL] = []
        if let rtf = pboard.data(forType: .rtf), let a = NSAttributedString(rtf: rtf, documentAttributes: nil) {
            a.enumerateAttribute(.link, in: NSRange(location: 0, length: a.length)) { v, _, _ in
                if let u = v as? URL { links.append(u) } else if let s = v as? String, let u = URL(string: s) { links.append(u) }
            }
        }
        let text = pboard.string(forType: .string)
        guard let u = SaveLink.fromPasteboard(urls: urls, html: html, rtfLinks: links, text: text) else {
            error.pointee = "저장할 http(s) 주소를 찾지 못했습니다" as NSString
            MainActor.assumeIsolated { ToastCenter.shared.showInfo("저장하지 못했어요", sub: "고른 글에서 기사 주소를 찾지 못했습니다") }
            return
        }
        // 링크 글자를 골랐으면 그 글자를 제목 후보로
        let title = (html != nil || !links.isEmpty) ? text.flatMap(SaveLink.cleanTitle) : nil
        MainActor.assumeIsolated { SaveLink.saveAndAnnounce(u, title: title.flatMap { SaveLink.normalize($0) == nil ? $0 : nil }) }
    }
}
