import Foundation
import Testing
@testable import Dropcap

// 성능·저장·같은 소식 통합·키보드(PERF-KEYS.md). 바깥 서버·실제 기록 없이 돈다.

private func news(_ title: String, _ source: String, tier: String = "press", hoursAgo: Double = 1, ko: String? = nil) -> NewsItem {
    NewsItem(id: "\(source)-\(title.hashValue)", title: title, titleKo: ko, link: "https://\(source).com/\(abs(title.hashValue))",
             date: Date().addingTimeInterval(-hoursAgo * 3600), summary: "", sourceId: source, sourceName: source.uppercased(), tier: tier)
}

private func tempDB() throws -> (Database, URL) {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("dropcap-pk-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return (Database(file: d.appendingPathComponent("magazine.sqlite")), d)
}

// 같은 소식 판단 한 곳(R-4): 알림 목록 묶기와 매거진 스토리가 같은 판단을 쓴다
@Suite struct StoryGrouperTests {
    private let a = news("OpenAI launches GPT-6 with new reasoning features", "verge")
    private let b = news("GPT-6 launches: OpenAI reveals reasoning features", "techcrunch", hoursAgo: 2)
    private let c = news("Microsoft announces Maia 300 AI chip", "zdnet", hoursAgo: 3)
    private let sameSource = news("OpenAI launches GPT-6 with reasoning features today", "verge", hoursAgo: 0.5)

    @Test func oneJudgementForBothPaths() {
        // 예전 판단(StoryMatch.same)과 미리 계산한 판단(StoryGrouper)이 같다
        for (x, y) in [(a, b), (a, c), (b, c), (a, sameSource)] {
            #expect(StoryMatch.same(x, y) == StoryGrouper.same(StoryKey(x), StoryKey(y)))
        }
        #expect(StoryGrouper.same(StoryKey(a), StoryKey(b)))
        #expect(!StoryGrouper.same(StoryKey(a), StoryKey(sameSource))) // 같은 출처끼리는 묶지 않음
    }

    @Test func listGroupingInBatch() {
        let lab = news("OpenAI launches GPT-6 with new reasoning features", "openai", tier: "lab", hoursAgo: 3)
        let (kept, adds) = StoryGrouper.groupForList([a, b, c, lab], recent: [])
        #expect(adds.isEmpty)
        #expect(kept.count == 2)
        let rep = kept.first { $0.sourceId == "openai" } // 공식 발표가 대표
        #expect(rep?.related?.sorted() == ["TECHCRUNCH", "VERGE"])
    }

    @Test func listGroupingAgainstRecent36h() {
        let old = news("GPT-6 launches: OpenAI reveals reasoning features", "techcrunch", hoursAgo: 40)
        let fresh = news("GPT-6 launches: OpenAI reveals reasoning features", "wired", hoursAgo: 5)
        // 36시간 넘은 것은 기억에서 빠져 다시 알림, 안이면 출처만 더함(이미 있는 이름은 두 번 넣지 않음)
        var r1 = StoryGrouper.groupForList([a], recent: [old])
        #expect(r1.kept.count == 1 && r1.recentAdds.isEmpty)
        r1 = StoryGrouper.groupForList([a, news("OpenAI launches GPT-6 with new reasoning features", "verge2")], recent: [fresh])
        #expect(r1.kept.isEmpty)
        #expect(r1.recentAdds[0]?.sorted() == ["VERGE", "VERGE2"])
        var withName = fresh; withName.related = ["VERGE"]
        #expect(StoryGrouper.groupForList([a], recent: [withName]).recentAdds.isEmpty)
    }

    @Test func storyForPicksFirstMatchingRepresentative() {
        // 한국어 제목(영어 제목 없음)은 낱말 겹침만 보므로 결과가 문장 임베딩에 달려 있지 않다
        let x = news("마이크로소프트, 자체 AI 칩 마이아 300 공개", "zdnet")
        let y = news("마이크로소프트 마이아 300 공개…자체 AI 칩 확대", "etnews")
        let z = news("프로야구 한국시리즈 7차전 승리로 우승", "yna")
        let reps = [(id: "s-z", key: StoryKey(z)), (id: "s-x", key: StoryKey(x))]
        #expect(StoryGrouper.storyFor(StoryKey(y), representatives: reps) == "s-x")
        #expect(StoryGrouper.storyFor(StoryKey(news("서울 내일 오후부터 비 소식", "kbs")), representatives: reps) == nil)
    }
}

// 매거진 편집(R-1): 화면 밖 Editor 가 같은 결과를 낸다
@Suite struct EditorTests {
    @Test func representativesInOneQuery() throws {
        let (db, d) = try tempDB(); defer { try? FileManager.default.removeItem(at: d) }
        let c = Database.Cluster(id: "c1", title: "t", tokens: [], first: Date(), last: Date(), size: 2)
        db.saveCluster(c)
        let older = news("first report", "a", hoursAgo: 5), newer = news("second report", "b", hoursAgo: 1)
        db.upsert(older, cluster: "c1"); db.upsert(newer, cluster: "c1")
        let reps = db.representatives(since: Date().addingTimeInterval(-86400))
        #expect(reps["c1"]?.item.key == newer.key) // 가장 최근 보도가 대표(예전: 스토리마다 질의한 .last 와 같음)
        #expect(db.clusters(of: [older.key, newer.key, "x|y"]) == [older.key: "c1", newer.key: "c1"])
    }

    @Test func ingestGroupsAcrossOutletsAndReportsFollowed() async throws {
        let (db, d) = try tempDB(); defer { try? FileManager.default.removeItem(at: d) }
        let ed = Editor(db: db)
        let a = news("OpenAI launches GPT-6 with new reasoning features", "verge", hoursAgo: 3)
        _ = await ed.ingest([a], followed: [])
        guard let story = db.clusterOf(a.key) else { Issue.record("스토리 없음"); return }
        let b = news("GPT-6 launches: OpenAI reveals reasoning features", "techcrunch", hoursAgo: 1)
        let grown = await ed.ingest([b], followed: [story])
        #expect(db.clusterOf(b.key) == story)
        #expect(grown.count == 1 && grown.first?.0.size == 2)
        // 다시 넣어도 스토리를 다시 정하지 않음
        _ = await ed.ingest([b], followed: [])
        #expect(db.cluster(story)?.size == 2)
        let info = await ed.storyInfo([a, b], filter: SourceFilter(hidden: ["techcrunch"]))
        #expect(info[a.key]?.story == story && info[a.key]?.coverage.total == 1) // 숨긴 출처는 보도 수에서 뺌
    }

    @Test func sameIssueIsNotSavedAgain() {
        let s = Issue.Section(category: .other, keys: ["a", "b"], section: "ai")
        let x = Issue(id: "daily-1", kind: .daily, date: Date(), from: Date(), to: Date(), cover: "c", sections: [s], count: 3)
        var y = x; y.date = Date().addingTimeInterval(100) // 발행 시각만 다름
        #expect(Editor.sameContent(y, x))
        y.sections = [Issue.Section(category: .other, keys: ["b", "a"], section: "ai")]
        #expect(!Editor.sameContent(y, x))
        #expect(!Editor.sameContent(x, nil))
    }
}

// 저장 묶기(R-3)
@Suite struct StateSaverTests {
    @Test func coalescesAndFlushes() throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("dropcap-saver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("native-state.json"), bak = d.appendingPathComponent("native-state.bak.json")
        try Data(#"{"unread":1}"#.utf8).write(to: f)
        let saver = StateSaver(file: f, backup: bak, delay: 30) // 시험 중에 저절로 쓰지 않게 길게
        for n in 2...6 { var s = AppState(); s.unread = n; saver.save(s) }
        #expect(saver.writes == 0)
        saver.flush()
        #expect(saver.writes == 1) // 다섯 번 저장 → 한 번 씀
        let (s, _) = Store.read(f, backup: bak)
        #expect(s.unread == 6) // 마지막 것
        #expect(Store.read(bak, backup: f).state.unread == 1) // 첫 쓰기 전에 이전 파일을 .bak 으로
        saver.flush()
        #expect(saver.writes == 1) // 기다리는 것이 없으면 쓰지 않음
    }

    @Test func skipBackupKeepsGoodBackup() throws { // 손상 복구(A-03): 깨진 본 파일로 .bak 을 덮지 않음
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("dropcap-saver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("native-state.json"), bak = d.appendingPathComponent("native-state.bak.json")
        try Data("{broken".utf8).write(to: f)
        try Data(#"{"unread":9}"#.utf8).write(to: bak)
        let saver = StateSaver(file: f, backup: bak, delay: 30)
        saver.skipBackup()
        saver.save(AppState())
        saver.flush()
        #expect(Store.read(bak, backup: f).state.unread == 9)
    }
}

@Suite struct KeyNavTests {
    @Test func movesWithinBounds() {
        let keys = ["a", "b", "c"]
        #expect(NavKey.move(nil, in: keys, by: 1) == "a")
        #expect(NavKey.move(nil, in: keys, by: -1) == "c")
        #expect(NavKey.move("a", in: keys, by: 1) == "b")
        #expect(NavKey.move("c", in: keys, by: 1) == "c")   // 끝에서 멈춤
        #expect(NavKey.move("a", in: keys, by: -1) == "a")
        #expect(NavKey.move("gone", in: keys, by: 1) == "a") // 고른 것이 목록에서 사라졌으면 처음부터
        #expect(NavKey.move("a", in: [], by: 1) == nil)
    }
    @Test func letters() {
        #expect(NavKey.from(character: "j") == .next && NavKey.from(character: "K") == .prev)
        #expect(NavKey.from(character: "s") == .save && NavKey.from(character: "o") == .browser && NavKey.from(character: "m") == .toggleRead)
        #expect(NavKey.from(character: "x") == nil)
    }
}

@Suite struct DigestWindowTests {
    @Test func morningOnly() { // A-20: 밤에 처음 켜도 '아침 브리핑'이 뜨지 않게
        #expect(AppModel.digestWindow(hour: 9, digestHour: 9))
        #expect(AppModel.digestWindow(hour: 11, digestHour: 9))
        #expect(!AppModel.digestWindow(hour: 12, digestHour: 9))
        #expect(!AppModel.digestWindow(hour: 22, digestHour: 9))
        #expect(!AppModel.digestWindow(hour: 8, digestHour: 9))
        #expect(AppModel.digestWindow(hour: 12, digestHour: 12))  // 정오를 고르면 그 한 시간
        #expect(!AppModel.digestWindow(hour: 13, digestHour: 12))
    }
}
