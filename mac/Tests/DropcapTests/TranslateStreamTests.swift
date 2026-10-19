import Foundation
import Testing
@testable import Dropcap

// 읽기 창 흘려 받기: 네트워크 없이 가짜 엔진으로
@MainActor @Suite struct TranslateStreamTests {
    actor Calls {
        var google = 0
        var apple: [[String]] = []
        func g() { google += 1 }
        func a(_ s: [String]) { apple.append(s) }
    }

    static func blocks(_ n: Int) -> [Block] { (1...n).map { Block(type: .p, text: "Paragraph number \($0)") } }

    // 제목+첫 8문단이 먼저, 기기 내 번역은 4개씩 끝나는 대로 바꿔 끼우고 진행(n/m)을 알린다
    @Test func swapsInAsChunksArrive() async {
        let calls = Calls()
        let t = Translator(mode: .auto, google: { _ in await calls.g(); return nil }, apple: { s, _ in await calls.a(s); return s.map { "기기: " + $0 } })
        var src = Self.blocks(20)
        src.insert(Block(type: .row, text: "Name · Score", cells: ["Name", "Score"]), at: 9)
        var a = PreparedArticle(title: "Title", originalTitle: "Title")
        a.blocks = src
        var seen: [PreparedArticle] = []
        let finished = await ArticleService.translateBody(&a, blocks: src, title: "Title", translator: t) { seen.append($0) }
        #expect(finished)
        // 보낸 묶음: [제목+3] [4] [1] / 나머지 13블록(표 한 줄은 셀 2개 → 14글) [4] [4] [4] [2]
        #expect(await calls.apple.map(\.count) == [4, 4, 1, 4, 4, 4, 2])
        #expect(await calls.google == 0)
        #expect(seen.map { $0.progress ?? -1 } == [3, 7, 8, 11, 15, 19, 21])
        // 첫 바뀜: 제목과 첫 3문단만 번역, 나머지는 아직 원문
        #expect(seen[0].title == "기기: Title")
        #expect(seen[0].blocks[2].text == "기기: Paragraph number 3" && seen[0].blocks[2].original == "Paragraph number 3")
        #expect(seen[0].blocks[3].text == "Paragraph number 4" && seen[0].blocks[3].original == nil)
        #expect(seen[0].progressTotal == 21 && seen[0].translated)
        #expect(seen[0].engine == Translator.Engine.apple.rawValue)
        // 끝: 모두 번역, 표 셀도
        #expect(a.blocks.allSatisfy { $0.original != nil })
        #expect(a.blocks[9].cells == ["기기: Name", "기기: Score"] && a.blocks[9].text == "기기: Name · 기기: Score")
        #expect(a.engine == Translator.Engine.apple.rawValue)
    }

    // 창을 닫거나 J/K 로 넘기면(작업 취소) 거기서 멈춘다 — 남은 문단을 구글로 넘기지도 않는다
    @Test func cancelStopsWithoutGoogle() async {
        let calls = Calls()
        let second = AsyncStream<Void>.makeStream()
        let t = Translator(mode: .auto, google: { _ in await calls.g(); return "구글" }, apple: { s, _ in
            await calls.a(s)
            if await calls.apple.count >= 2 {
                second.continuation.yield()
                try? await Task.sleep(for: .seconds(30)) // 취소되면 바로 깨어남
                return nil // 세션이 끊기면 nil(실제 기기 내 번역과 같음)
            }
            return s.map { "기기: " + $0 }
        })
        let src = Self.blocks(12)
        let work = Task { @MainActor () -> (Bool, PreparedArticle) in
            var a = PreparedArticle(title: "Title", originalTitle: "Title")
            a.blocks = src
            let ok = await ArticleService.translateBody(&a, blocks: src, title: "Title", translator: t) { _ in }
            return (ok, a)
        }
        for await _ in second.stream { break }
        work.cancel()
        let (finished, a) = await work.value
        #expect(!finished)
        #expect(await calls.google == 0)
        #expect(await calls.apple.count == 2)
        #expect(a.blocks[2].text == "기기: Paragraph number 3")
        #expect(a.blocks[5].original == nil) // 받지 못한 문단은 원문 그대로
    }

    // 다시 열면 이미 번역한 문단은 캐시에서 한 번에(엔진 표시도 그대로)
    @Test func reopenUsesCache() async {
        let calls = Calls()
        let t = Translator(mode: .auto, apple: { s, _ in await calls.a(s); return s.map { "기기: " + $0 } })
        let src = Self.blocks(10)
        var a = PreparedArticle(title: "Title", originalTitle: "Title"); a.blocks = src
        await ArticleService.translateBody(&a, blocks: src, title: "Title", translator: t) { _ in }
        let before = await calls.apple.count
        var b = PreparedArticle(title: "Title", originalTitle: "Title"); b.blocks = src
        var seen: [PreparedArticle] = []
        await ArticleService.translateBody(&b, blocks: src, title: "Title", translator: t) { seen.append($0) }
        #expect(await calls.apple.count == before)
        #expect(seen.count == 2 && seen[0].progress == 8) // 앞 8문단이 한 번에
        #expect(b.blocks.map(\.text) == a.blocks.map(\.text))
        #expect(b.engine == Translator.Engine.apple.rawValue)
    }

    // 읽기 창이 떠날 때: 번역 중이고 보는 창이 없을 때만 멈춘다(본문 받는 중·다른 창이 보는 중이면 그대로)
    @Test func stopOnlyWhileTranslatingUnwatched() {
        #expect(ArticleService.shouldStop(stage: .translating, watchers: 0))
        #expect(!ArticleService.shouldStop(stage: .translating, watchers: 1))
        #expect(!ArticleService.shouldStop(stage: .extracting, watchers: 0))
        #expect(!ArticleService.shouldStop(stage: .done, watchers: 0))
        #expect(!ArticleService.shouldStop(stage: nil, watchers: 0))
    }
}

extension TranslateStreamTests {
    // 진행 표시: 기기 내 번역일 때만 n/m, 구글·엔진 모름은 예전 문구
    @Test func progressText() {
        let apple = Translator.Engine.apple.rawValue
        #expect(ReaderModel.translatingText(engine: apple, progress: (3, 21)) == "기기 내 번역 중 3/21 — 위에서부터 차례로 바뀝니다")
        #expect(ReaderModel.translatingText(engine: "Google 번역", progress: (3, 21)) == "한국어로 바꾸는 중 — 위에서부터 차례로 바뀝니다")
        #expect(ReaderModel.translatingText(engine: "", progress: nil) == "한국어로 바꾸는 중 — 위에서부터 차례로 바뀝니다")
    }
}
