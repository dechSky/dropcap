import Foundation
import Testing
@testable import Dropcap

@Suite struct StoryMatchTests {
    @Test func cachedMeaningDistanceMatchesEmbedding() { // 기억해 둔 벡터로 잰 거리가 NLEmbedding 과 같아야 판정이 그대로다
        let pairs = [("OpenAI releases GPT-6 model", "OpenAI unveils its GPT-6 model"),
                     ("Nvidia earnings beat expectations", "EU passes new AI safety law")]
        for (a, b) in pairs {
            guard let raw = StoryMatch.rawDistance(a, b), let cached = StoryMatch.meaningDistance(a, b) else { continue }
            #expect(abs(raw - cached) < 0.01)
        }
    }
    @Test func sameStoryDifferentOutlets() {
        let a = StoryMatch.tokens("OpenAI launches GPT-6 with new reasoning features")
        let b = StoryMatch.tokens("GPT-6 launches: OpenAI reveals reasoning features")
        #expect(StoryMatch.similar(a, b))
    }

    @Test func differentStories() {
        let a = StoryMatch.tokens("Microsoft announces Maia 300 AI chip")
        let b = StoryMatch.tokens("Meta releases its first frontier model, Muse Wonder")
        #expect(!StoryMatch.similar(a, b))
    }

    @Test func shortTitlesNeverMatch() {
        #expect(!StoryMatch.similar(StoryMatch.tokens("AI news"), StoryMatch.tokens("AI news")))
    }

    @Test func koreanTitles() {
        let a = StoryMatch.tokens("마이크로소프트, 자체 AI 칩 마이아 300 공개")
        let b = StoryMatch.tokens("마이크로소프트 마이아 300 공개…자체 AI 칩 확대")
        #expect(StoryMatch.similar(a, b))
    }
}

@Suite struct QuietHoursTests {
    @Test func overnight() {
        #expect(AppModel.inQuiet(hour: 23, start: 23, end: 7))
        #expect(AppModel.inQuiet(hour: 3, start: 23, end: 7))
        #expect(!AppModel.inQuiet(hour: 7, start: 23, end: 7))
        #expect(!AppModel.inQuiet(hour: 12, start: 23, end: 7))
    }
    @Test func sameDay() {
        #expect(AppModel.inQuiet(hour: 13, start: 12, end: 14))
        #expect(!AppModel.inQuiet(hour: 14, start: 12, end: 14))
    }
    @Test func emptyRange() { #expect(!AppModel.inQuiet(hour: 5, start: 5, end: 5)) }
}

@Suite struct FeedParserTests {
    @Test func rss() throws {
        let xml = """
        <?xml version="1.0"?><rss version="2.0"><channel><title>x</title>
        <item><title><![CDATA[Hello &amp; <b>world</b>]]></title><link>https://a.com/1</link><guid>g1</guid>
        <pubDate>Mon, 12 Oct 2026 10:00:00 +0000</pubDate><description>&lt;p&gt;Sum&lt;/p&gt;</description></item>
        </channel></rss>
        """
        let e = try FeedParser.parseFeed(Data(xml.utf8))
        #expect(e.count == 1)
        #expect(e[0].id == "g1")
        #expect(e[0].title == "Hello & world")
        #expect(e[0].date != nil)
        #expect(e[0].summary == "Sum")
    }

    @Test func atomPrefersAlternateLink() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom"><entry><id>tag:1</id><title>T</title>
        <link rel="self" href="https://a.com/self"/><link rel="alternate" href="https://a.com/post"/>
        <updated>2026-10-12T10:00:00Z</updated></entry></feed>
        """
        let e = try FeedParser.parseFeed(Data(xml.utf8))
        #expect(e.first?.link == "https://a.com/post")
    }

    @Test func sitemapFiltersByPattern() throws {
        let xml = """
        <urlset><url><loc>https://www.anthropic.com/news/claude-x</loc><lastmod>2026-10-01T00:00:00Z</lastmod></url>
        <url><loc>https://www.anthropic.com/careers</loc></url></urlset>
        """
        let re = try NSRegularExpression(pattern: "^https:\\/\\/www\\.anthropic\\.com\\/news\\/[^/]+$")
        let e = try FeedParser.parseSitemap(Data(xml.utf8), match: re)
        #expect(e.map(\.link) == ["https://www.anthropic.com/news/claude-x"])
    }

    @Test func garbageThrows() {
        #expect(throws: (any Error).self) { try FeedParser.parseFeed(Data("<html><body>nope</body></html>".utf8)) }
    }
}

@Suite struct StoreTests {
    // 예전 파일(새 항목 없음, position "auto")도 그대로 읽혀야 한다 — 업데이트해도 기록이 날아가지 않게
    @Test func decodesOldStateFile() throws {
        let old = """
        {"seen":{"openai|x":1},"seeded":["openai"],"enabled":{"openai":true},"recent":[],"errors":{},"unread":2,
         "settings":{"style":"drop","sound":false,"intervalMinutes":10,"position":"auto"}}
        """
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let s = try d.decode(AppState.self, from: Data(old.utf8))
        #expect(s.seen["openai|x"] == 1)
        #expect(s.unread == 2)
        #expect(s.settings.sound == false)
        #expect(s.settings.intervalMinutes == 10)
        #expect(s.settings.position == .center)
        #expect(s.saved.isEmpty && s.read.isEmpty && s.customSources.isEmpty)
    }

    @Test func decodesOldReadList() throws {
        let s = try JSONDecoder().decode(AppState.self, from: Data(#"{"read":["x|1","y|2"]}"#.utf8))
        #expect(s.read.keys.sorted() == ["x|1", "y|2"])
    }

    @Test func roundTrip() throws {
        var s = AppState()
        s.settings.mustKeywords = ["GPT"]
        s.read = ["a|b": 1]
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let back = try d.decode(AppState.self, from: e.encode(s))
        #expect(back.settings.mustKeywords == ["GPT"])
        #expect(back.read == ["a|b": 1])
    }
}

@Suite struct MiscTests {
    @Test func gzipInflate() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        p.arguments = ["-c"]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe
        try p.run()
        inPipe.fileHandleForWriting.write(Data("<rss>hello</rss>".utf8)); inPipe.fileHandleForWriting.closeFile()
        let gz = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        #expect(String(decoding: Gzip.inflateIfNeeded(gz), as: UTF8.self) == "<rss>hello</rss>")
        #expect(Gzip.inflateIfNeeded(Data("plain".utf8)) == Data("plain".utf8))
    }

    @Test func looksForeign() {
        #expect(Translator.looksForeign("OpenAI releases a new model"))
        #expect(!Translator.looksForeign("오픈AI가 새 모델을 공개했다"))
        #expect(!Translator.looksForeign("   "))
    }

    @Test func dates() {
        #expect(Dates.parse("Tue, 13 Oct 2026 01:02:03 GMT") != nil)
        #expect(Dates.parse("2026-10-13T01:02:03.123Z") != nil)
        #expect(Dates.parse("garbage") == nil)
    }
}

@Suite struct CategoryTests {
    @Test func classifies() {
        #expect(NewsCategory.classify("OpenAI launches GPT-6") == .model)
        #expect(NewsCategory.classify("Anthropic raises $5B at $200B valuation") == .business)
        #expect(NewsCategory.classify("EU AI Act enforcement begins, regulators say") == .policy)
        #expect(NewsCategory.classify("New jailbreak exploit hits chatbots") == .security)
        #expect(NewsCategory.classify("Researchers publish benchmark for reasoning") == .research)
        #expect(NewsCategory.classify("정부, AI 기본법 시행령 발표") == .policy)
        #expect(NewsCategory.classify("업스테이지, 1000억 투자 유치") == .business)
        #expect(NewsCategory.classify("Weekend reading list") == .other)
    }
}

@Suite struct URLSafetyTests {
    @Test func allowsPublic() {
        for u in ["https://openai.com/news/x", "http://www.aitimes.com/a?b=1", "https://8.8.8.8/x", "https://[2606:4700::1111]/"] {
            #expect(URLSafety.isPublicHTTP(URL(string: u)), "\(u)")
        }
    }
    @Test func blocksPrivateAndOddSchemes() {
        for u in ["http://localhost:8080/", "http://127.0.0.1/", "http://192.168.0.1/admin", "http://10.1.2.3/", "http://172.20.0.5/",
                  "http://169.254.169.254/latest/meta-data", "http://router.local/", "http://intranet/", "http://[::1]/", "http://[fd00::1]/",
                  "http://[::ffff:192.168.1.1]/", "file:///etc/passwd", "smb://server/share", "javascript:alert(1)", "http://0.0.0.0/",
                  // 숫자 표기 꼼수
                  "http://2130706433/", "http://0x7f.1/", "http://127.1/", "http://0177.0.0.1/", "http://0x7f000001/",
                  "http://[0:0:0:0:0:0:0:1]/", "http://[::ffff:7f00:1]/", "http://[64:ff9b::7f00:1]/", "http://[2002:c0a8:0101::]/",
                  "http://localhost./", "http://[fe80::1]/"] {
            #expect(!URLSafety.isPublicHTTP(URL(string: u)), "\(u)")
        }
    }
}


@Suite(.enabled(if: ProcessInfo.processInfo.environment["DROPCAP_LIVE_TESTS"] == "1"))
struct URLSafetyDNSTests {
    // 이름이 내부망 IP 로 풀리면 거절(실제 DNS 조회, 네트워크 필요)
    @Test func nameResolvingToLoopbackIsBlocked() async {
        #expect(!(await URLSafety.resolvesPublic(URL(string: "http://127.0.0.1.nip.io/"))))
        #expect(!(await URLSafety.resolvesPublic(URL(string: "http://localtest.me/"))))
    }
    @Test func publicNameAllowed() async {
        #expect(await URLSafety.resolvesPublic(URL(string: "https://openai.com/")))
    }
}

@Suite struct SameStoryMeaningTests {
    @Test func entitiesSkipTitleCaseWords() {
        let e = StoryMatch.entities("OCP Global Summit: Amid Ecosystem Adoption, NVIDIA Opens Vera Rubin Architecture")
        #expect(e.contains("nvidia") && e.contains("ocp") && !e.contains("global") && !e.contains("summit"))
        #expect(StoryMatch.entities("OpenAI launches GPT-6 for iPhone").isSuperset(of: ["openai", "gpt-6", "iphone"]))
    }

    private func item(_ title: String, en: String? = nil, source: String? = nil) -> NewsItem {
        NewsItem(id: title, title: title, titleKo: nil, link: "https://x.com/" + title.prefix(8), date: nil, summary: "",
                 sourceId: source ?? UUID().uuidString, sourceName: "S", tier: "press", titleEn: en)
    }

    @Test func sameOutletNeverMerges() {
        #expect(!StoryMatch.same(item("OpenAI launches GPT-6 with new reasoning", source: "a"), item("OpenAI launches GPT-6 with new reasoning", source: "a")))
    }

    @Test func groupsAcrossLanguages() {
        let ko = item("메타, 자체 최고 모델 ‘뮤즈 원더’ 출시로 프런티어 경쟁 합류", en: "Meta joins frontier competition by launching its own top model 'Muse Wonder'")
        let en = item("Meta has some Wonder Full new AI models")
        #expect(StoryMatch.same(ko, en))
        let ko2 = item("\"AI 대신 SI 써라\"...트럼프 압박에 실리콘밸리 굴복", en: "\"Use SI instead of AI\"... Silicon Valley succumbs to Trump pressure")
        #expect(StoryMatch.same(ko2, item("Silicon Valley is falling in line with Trump’s attempt to rename AI")))
    }

    @Test func keepsDifferentStoriesApart() {
        // Title Case 의 흔한 말('Global')을 고유명사로 오인해 묶이던 사례
        #expect(!StoryMatch.same(item("OCP Global Summit: Amid Ecosystem Adoption, NVIDIA Opens Vera Rubin Architecture to Help Scale AI Factories Worldwide"),
                                 item("AI 업무 플랫폼 '팔레트 에이전트' 글로벌 출시", en: "Global launch of AI business platform ‘Palette Agent’… “Integrated support from planning to app production”")))
        #expect(!StoryMatch.same(item("Microsoft’s new AI chip makes it less reliant on Nvidia’s GPUs"), item("Meta has some Wonder Full new AI models")))
        #expect(!StoryMatch.same(item("Anthropic is cutting off its internal evaluations from the internet"),
                                 item("Anthropic's Claude AI submitted false murder tip to Philadelphia police")))
        #expect(!StoryMatch.same(item("Learning to use local AI is exciting, overwhelming, and frustrating"),
                                 item("AI agent makers are promising privacy — will they deliver?")))
    }
}

@Suite struct SameStoryFalsePositiveTests {
    private func item(_ title: String, en: String? = nil) -> NewsItem {
        NewsItem(id: title, title: title, titleKo: nil, link: "https://x.com/" + title.prefix(8), date: nil, summary: "",
                 sourceId: UUID().uuidString, sourceName: "S", tier: "press", titleEn: en)
    }
    @Test func unrelatedKoreanTranslationsStayApart() {
        #expect(!StoryMatch.same(item("Epic Games reportedly pivoting to \"AI first\" game development model"),
                                 item("[AI리더의 서가] Physical AI 데이터의 새로운 법칙", en: "[AI Leader's Bookshelf] New Rules of Physical AI Data")))
        #expect(!StoryMatch.same(item("Amazon has over 1 million robot workers. What’s next for human employees?"),
                                 item("포스코DX, AI 스타트업 인핸스에 20억 투자", en: "POSCO DX invests 2 billion won in AI startup Enhance")))
    }
}

@Suite struct ScrapExportTests {
    @Test func markdownGroupsByArticle() {
        let it = NewsItem(id: "1", title: "Meta has new AI models", titleKo: "메타의 새 AI 모델", link: "https://example.com/a",
                          date: Date(timeIntervalSince1970: 1_791_800_000), summary: "", sourceId: "verge", sourceName: "The Verge", tier: "press")
        let a = Scrap(item: it, quote: "메타가 새 모델을 공개했다.", quoteOriginal: "Meta released a new model.", memo: "보고서 1장", collection: "조사")
        let b = Scrap(item: it, quote: nil, memo: "", collection: "조사")
        let md = Scrapbook.render([b, a], title: "조사")
        #expect(md.hasPrefix("# 조사"))
        #expect(md.components(separatedBy: "## [메타의 새 AI 모델](https://example.com/a)").count == 2) // 기사는 한 번만
        #expect(md.contains("> 메타가 새 모델을 공개했다."))
        #expect(md.contains("> _Meta released a new model._"))
        #expect(md.contains("- 메모: 보고서 1장"))
        #expect(md.contains("원제: Meta has new AI models"))
    }
}


@Suite struct ImageKeyTests {
    @Test func junkImages() {
        #expect(ImageKey.isJunk("https://cdn.aitimes.com/image/newsroom/default-user.png"))
        #expect(ImageKey.isJunk("https://x.com/assets/logo.svg"))
        #expect(ImageKey.isJunk("https://secure.gravatar.com/avatar/abc?s=96"))
        #expect(!ImageKey.isJunk("https://cdn.aitimes.com/news/photo/202610/216198_220220_302.jpg"))
        #expect(!ImageKey.isJunk("https://x.com/wp-content/uploads/2026/10/catalog-hero.jpg"))
    }
    @Test func sameImageDifferentSizes() {
        #expect(ImageKey.same("https://cdn.aitimes.com/news/photo/202610/216199_220221_5549.jpg", "https://cdn.aitimes.com/news/thumbnail/202610/216199_220221_5549_v150.jpg"))
        #expect(ImageKey.same("https://x.com/wp-content/uploads/2026/10/gpt6-hero-1024x576.png", "https://x.com/wp-content/uploads/2026/10/gpt6-hero.png?w=1200"))
        #expect(ImageKey.same("https://x.com/a/launch-photo-scaled.jpg", "https://x.com/a/launch-photo.jpg"))
    }
    @Test func differentImages() {
        #expect(!ImageKey.same("https://cdn.aitimes.com/news/photo/202610/216199_220221_5549.jpg", "https://cdn.aitimes.com/news/photo/202610/216199_220222_5550.jpg"))
        #expect(!ImageKey.same("https://x.com/img/1.jpg", "https://y.com/img/1.jpg")) // 짧은 이름은 주소가 같을 때만 같은 사진
        #expect(!ImageKey.same("https://x.com/img/a.jpg", "https://x.com/other/a.jpg"))
    }
}


@Suite struct SiteNameTests {
    @Test func strips() {
        #expect(ArticleService.stripSiteName("AI 업무 플랫폼 '팔레트 에이전트' 글로벌 출시 - AI타임스", source: "AI타임스", feedTitle: "x") == "AI 업무 플랫폼 '팔레트 에이전트' 글로벌 출시")
        #expect(ArticleService.stripSiteName("OpenAI ships GPT-6 | The Verge", source: "The Verge", feedTitle: "x") == "OpenAI ships GPT-6")
    }
    @Test func keepsRealDashes() {
        #expect(ArticleService.stripSiteName("GPT-6 - what changed", source: "The Verge", feedTitle: "x") == "GPT-6 - what changed")
    }
}

@Suite struct ImportanceSortTests {
    private func item(_ id: String, hoursAgo: Double, tier: String = "press") -> NewsItem {
        NewsItem(id: id, title: id, titleKo: nil, link: "https://x.com/" + id, date: Date().addingTimeInterval(-hoursAgo * 3600), summary: "",
                 sourceId: "s", sourceName: "S", tier: tier)
    }
    @Test func coverageBeatsRecency() { // 여러 곳이 다룬 기사가 방금 나온 단독 기사보다 앞
        let fresh = item("fresh", hoursAgo: 0.1), big = item("big", hoursAgo: 20), lab = item("lab", hoursAgo: 5, tier: "lab")
        let out = MenuView.byImportance([fresh, big, lab], coverage: [big.key: 4])
        #expect(out.map(\.id) == ["big", "lab", "fresh"])
    }
    @Test func differsFromNewestWithoutStars() { // ★·외 N곳이 없어도 최신순과 다르게 정렬
        let a = item("a", hoursAgo: 1), b = item("b", hoursAgo: 30, tier: "lab")
        #expect(MenuView.byImportance([a, b], coverage: [:]).first?.id == "b")
    }
}
