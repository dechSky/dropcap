import AppKit
import Foundation
import Testing
@testable import Dropcap

// 읽기 창 모양·찾기, 아무 주소 저장(서비스·스킴), 스크랩 Markdown·노트 폴더 저장. 바깥 서버 없이 돈다.

@Suite struct SaveLinkParseTests {
    @Test func normalizesPlainAndBareAddresses() {
        #expect(SaveLink.normalize("  https://example.com/a/b?x=1#top \n")?.absoluteString == "https://example.com/a/b?x=1")
        #expect(SaveLink.normalize("example.com/news/1")?.absoluteString == "https://example.com/news/1")
        #expect(SaveLink.normalize("<https://example.com/a>")?.absoluteString == "https://example.com/a")
        #expect(SaveLink.normalize("example.com:8080/a")?.absoluteString == "https://example.com:8080/a")
    }

    @Test func rejectsUnsafeOrNonWeb() {
        for bad in ["http://localhost/x", "http://192.168.0.1/admin", "http://127.0.0.1:8080", "http://[::1]/", "file:///etc/passwd",
                    "javascript:alert(1)", "mailto:a@example.com", "ftp://example.com/a", "http://intranet/", "http://router.local/",
                    "https://user:pw@example.com/a", "hello world", "", "smb://example.com/share", "http://0x7f.1/"] {
            #expect(SaveLink.normalize(bad) == nil, "\(bad)")
        }
        #expect(SaveLink.normalize("https://example.com/" + String(repeating: "a", count: 3000)) == nil) // 너무 긴 주소
    }

    @Test func parsesSchemeURL() throws {
        let enc = "https%3A%2F%2Fexample.com%2Fpost%3Fid%3D3%26q%3Da%2Bb"
        let r = try #require(SaveLink.parseScheme(URL(string: "dropcap://save?url=\(enc)&title=%EC%A0%9C%EB%AA%A9")!))
        #expect(r.url.absoluteString == "https://example.com/post?id=3&q=a+b")
        #expect(r.title == "제목")
        #expect(SaveLink.parseScheme(URL(string: "dropcap:save?url=https://example.com/a")!)?.url.absoluteString == "https://example.com/a")
        #expect(SaveLink.parseScheme(URL(string: "dropcap://save?url=http%3A%2F%2F10.0.0.1%2F")!) == nil)  // 내부망
        #expect(SaveLink.parseScheme(URL(string: "dropcap://delete?url=https://example.com/a")!) == nil)  // 모르는 동작
        #expect(SaveLink.parseScheme(URL(string: "https://save?url=https://example.com/a")!) == nil)       // 다른 스킴
        #expect(SaveLink.parseScheme(URL(string: "dropcap://save")!) == nil)
    }

    @Test func picksURLFromServicePasteboard() {
        // 링크 글자를 고르면 HTML 의 href 가 먼저
        #expect(SaveLink.fromPasteboard(urls: [], html: #"<p>see <a class="x" href="https://news.example.com/a?b=1&amp;c=2">기사</a></p>"#, rtfLinks: [], text: "기사")?.absoluteString
                == "https://news.example.com/a?b=1&c=2")
        #expect(SaveLink.fromPasteboard(urls: ["https://a.example.com/1"], html: nil, rtfLinks: [], text: nil)?.absoluteString == "https://a.example.com/1")
        #expect(SaveLink.fromPasteboard(urls: [], html: nil, rtfLinks: [URL(string: "https://r.example.com/x")!], text: "x")?.absoluteString == "https://r.example.com/x")
        #expect(SaveLink.fromPasteboard(urls: [], html: nil, rtfLinks: [], text: "오늘 읽을 글 https://t.example.com/story 입니다")?.absoluteString == "https://t.example.com/story")
        // 위험한 것은 건너뛰고 다음 후보로
        #expect(SaveLink.fromPasteboard(urls: ["http://localhost/a"], html: #"<a href="javascript:x">y</a>"#, rtfLinks: [], text: "https://ok.example.com/z")?.absoluteString
                == "https://ok.example.com/z")
        #expect(SaveLink.fromPasteboard(urls: [], html: nil, rtfLinks: [], text: "주소 없음") == nil)
    }

    @Test func readsArticleHead() {
        let html = """
        <html><head><title>Fallback | Site</title>
        <meta property="og:title" content="Big &amp; New Model">
        <meta content="/img/cover.jpg" property="og:image">
        <meta property="og:site_name" content="Example News">
        <meta name="description" content="A summary.">
        </head></html>
        """
        let h = SaveLink.parseHead(html, base: URL(string: "https://example.com/a/b")!)
        #expect(h.title == "Big & New Model")
        #expect(h.image == "https://example.com/img/cover.jpg")
        #expect(h.site == "Example News")
        #expect(h.description == "A summary.")
        let h2 = SaveLink.parseHead("<title>Only Title</title><meta property=\"og:image\" content=\"http://127.0.0.1/x.png\">", base: URL(string: "https://example.com/")!)
        #expect(h2.title == "Only Title")
        #expect(h2.image == nil) // 내부망 사진 주소는 받지 않음
    }

    @Test @MainActor func makesSavedItem() {
        let u = URL(string: "https://www.example.com/2026/10/some-story")!
        let it = SaveLink.makeItem(url: u, head: .init(title: "Some Story - Example", image: nil, site: nil, description: nil))
        #expect(it.sourceName == "example.com")
        #expect(it.link == u.absoluteString && it.id == u.absoluteString)
        #expect(it.tier == SaveLink.tier)
        #expect(it.sourceId.hasPrefix(SaveLink.sourcePrefix))
        let noHead = SaveLink.makeItem(url: u, head: .init(), fallbackTitle: "북마클릿 제목")
        #expect(noHead.title == "북마클릿 제목")
        #expect(!SaveLink.makeItem(url: u, head: .init()).title.isEmpty) // 머리를 못 받아도 주소에서 제목
    }

    @Test func stripsSiteSuffixMatchingHost() {
        #expect(SaveLink.stripHostSuffix("Initial - Wikipedia", host: "en.wikipedia.org") == "Initial")
        #expect(SaveLink.stripHostSuffix("A story | The Verge", host: "www.theverge.com") == "A story")
        #expect(SaveLink.stripHostSuffix("Rock - Paper", host: "example.com") == "Rock - Paper") // 사이트 이름이 아니면 그대로
    }

    @Test func bookmarkletUsesScheme() {
        #expect(SaveLink.bookmarklet.hasPrefix("javascript:"))
        #expect(SaveLink.bookmarklet.contains("dropcap://save?url='+encodeURIComponent(location.href)"))
    }
}

@Suite struct MarkdownEscapeTests {
    private func item(_ title: String, _ link: String) -> NewsItem {
        NewsItem(id: link, title: title, titleKo: nil, link: link, date: nil, summary: "", sourceId: "x", sourceName: "X", tier: "press")
    }

    @Test func escapesBracketsInTitleAndWrapsURL() {
        let md = Scrapbook.render([Scrap(item: item("Model [beta] ships]", "https://en.example.org/wiki/Foo_(bar)"), collection: "c")], title: "c")
        #expect(md.contains(#"## [Model \[beta\] ships\]](<https://en.example.org/wiki/Foo_(bar)>)"#))
        #expect(Scrapbook.escapeLinkText(#"a\b"#) == #"a\\b"#)
        #expect(Scrapbook.escapeLinkURL("https://x.example/a b<c>") == "<https://x.example/a%20b%3Cc%3E>")
    }

    @Test func multiLineMemoStaysInOneListItem() {
        var s = Scrap(item: item("T", "https://example.com/t"), collection: "c")
        s.memo = "첫 줄\n둘째 줄"
        #expect(Scrapbook.render([s], title: "c").contains("- 메모: 첫 줄\n  둘째 줄"))
    }
}

@Suite struct ScrapExportFileTests {
    @Test func safeFileNames() {
        #expect(ScrapExport.fileName("GPT 조사") == "GPT 조사.md")
        #expect(ScrapExport.fileName("a/b:c") == "a／b：c.md")
        #expect(ScrapExport.fileName("..hidden") == "hidden.md")
        #expect(ScrapExport.fileName("   ") == "스크랩.md")
        #expect(ScrapExport.fileName(String(repeating: "가", count: 300)).count == 123)
    }

    @Test func ignoresOnlyDateLine() {
        let a = "# c\n\n_Dropcap 스크랩 · 2026-10-12 · 2건_\n\n## x\n"
        let b = "# c\n\n_Dropcap 스크랩 · 2026-10-13 · 2건_\n\n## x\n"
        let c = "# c\n\n_Dropcap 스크랩 · 2026-10-13 · 3건_\n\n## x\n"
        #expect(ScrapExport.sameIgnoringDate(a, b))
        #expect(!ScrapExport.sameIgnoringDate(a, c))
    }
}

@Suite struct ReaderLookTests {
    @Test func storedKeysStayStable() { // 이전 버전에서 기억한 글자 크기를 그대로 읽어야 한다
        #expect(ReaderLook.fontSizeKey == "readerFontSize")
        #expect(Set([ReaderLook.spacingKey, ReaderLook.widthKey, ReaderLook.themeKey, ReaderLook.fontKey]).count == 4)
    }

    @Test func valuesRoundTripThroughDefaults() {
        let d = UserDefaults(suiteName: "dropcap-test-look-\(UUID().uuidString)")!
        d.set(ReaderLook.Theme.sepia.rawValue, forKey: ReaderLook.themeKey)
        d.set(ReaderLook.Spacing.loose.rawValue, forKey: ReaderLook.spacingKey)
        d.set(ReaderLook.Width.wide.rawValue, forKey: ReaderLook.widthKey)
        d.set(ReaderLook.Face.serif.rawValue, forKey: ReaderLook.fontKey)
        #expect(ReaderLook.Theme(rawValue: d.string(forKey: ReaderLook.themeKey)!) == .sepia)
        #expect(ReaderLook.Spacing(rawValue: d.string(forKey: ReaderLook.spacingKey)!)!.factor > 1)
        #expect(ReaderLook.Width(rawValue: d.string(forKey: ReaderLook.widthKey)!)!.points > ReaderLook.Width.normal.points)
        #expect(ReaderLook.Face.resolve(d.string(forKey: ReaderLook.fontKey)!) == .serif)
    }

    @Test func unknownOrEmptyFallsBack() {
        #expect(ReaderLook.Face.resolve("") == (Typography.usePretendard ? .pretendard : .system)) // 빈 값은 앱 설정을 따름
        #expect(ReaderLook.Face.resolve("comic") == ReaderLook.Face.resolve(""))
        #expect(ReaderLook.Theme(rawValue: "neon") == nil)
        #expect(ReaderLook.clampSize(40) == 26 && ReaderLook.clampSize(2) == 13 && ReaderLook.clampSize(18) == 18)
        #expect(ReaderLook.Theme.auto.scheme == nil && ReaderLook.Theme.dark.scheme == .dark && ReaderLook.Theme.sepia.scheme == .light)
    }

    @Test @MainActor func serifFontHasKoreanFallback() {
        let f = ReaderLook.serifFont(17, bold: false)
        #expect(f.pointSize == 17)
        let cascade = f.fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor]
        #expect(cascade?.first?.object(forKey: .name) as? String == "AppleMyungjo")
    }
}

@Suite struct ReaderFindTests {
    @Test func findsCaseAndAccentInsensitive() {
        #expect(ReaderFind.ranges(in: "OpenAI and openai and Café", "OPENAI").count == 2)
        #expect(ReaderFind.ranges(in: "Café cafe", "cafe").count == 2)
        #expect(ReaderFind.ranges(in: "모델 모델모델", "모델").count == 3)
        #expect(ReaderFind.ranges(in: "aaa", "aa").count == 1) // 겹치지 않게
        #expect(ReaderFind.ranges(in: "abc", "  ").isEmpty)
    }

    @Test func matchesAcrossPiecesInOrder() {
        let m = ReaderFind.matches([(-1, "GPT 소식"), (0, "GPT-6 와 GPT-5"), (3, "없음"), (4, "gpt")], "gpt")
        #expect(m == [.init(block: -1, nth: 0), .init(block: 0, nth: 0), .init(block: 0, nth: 1), .init(block: 4, nth: 0)])
    }

    @Test func stepsWrapAround() {
        #expect(ReaderFind.step(3, count: 4, forward: true) == 0)
        #expect(ReaderFind.step(0, count: 4, forward: false) == 3)
        #expect(ReaderFind.step(0, count: 0, forward: true) == 0)
    }

    @Test func highlightsAllAndCurrent() {
        let a = ReaderFind.highlighted("ab ab ab", "ab", current: 1)
        let colored = a.runs.filter { $0.backgroundColor != nil }
        #expect(colored.count == 3)
        #expect(String(a.characters) == "ab ab ab")
    }
}

@Suite struct WeeklyQuotesTests {
    @Test func picksThisWeeksQuotesOnce() {
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        let it = NewsItem(id: "1", title: "t", titleKo: nil, link: "https://example.com", date: nil, summary: "", sourceId: "x", sourceName: "X", tier: "press")
        func s(_ q: String?, daysAgo: Double) -> Scrap { Scrap(item: it, quote: q, collection: "c", created: now.addingTimeInterval(-daysAgo * 86400)) }
        let list = [s("오래된 문장", daysAgo: 9), s("이번 주 문장", daysAgo: 2), s("이번 주 문장", daysAgo: 1), s(nil, daysAgo: 1), s("어제 문장", daysAgo: 0.5)]
        let picked = WeeklyQuotes.pick(list, now: now)
        #expect(picked.map(\.quote) == ["어제 문장", "이번 주 문장"])
    }

    @Test func sundayEveningOnly() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        func date(_ d: Int, _ h: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h))! } // 2026-10-11 은 일요일
        guard ProcessInfo.processInfo.environment["DROPCAP_TEST_WEEKLY"] == nil else { return }
        #expect(WeeklyQuotes.isSundayEvening(date(11, 18), calendar: cal))
        #expect(!WeeklyQuotes.isSundayEvening(date(11, 10), calendar: cal))
        #expect(!WeeklyQuotes.isSundayEvening(date(12, 19), calendar: cal))
    }
}
