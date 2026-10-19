import Foundation
import Testing
@testable import Dropcap

// 번역 2단계: 네트워크 없이 — 엔진 부르기를 가짜로 바꿔 끼운다
@Suite struct TranslatePhase2Tests {
    // 부른 횟수·받은 글을 세는 가짜 엔진
    actor Calls {
        var google: [String] = []
        var apple: [[String]] = []
        func g(_ s: String) { google.append(s) }
        func a(_ s: [String]) { apple.append(s) }
    }

    // 묶음(빈 줄로 이은 글)을 문단마다 "번역:" 을 붙여 돌려주는 구글
    static func fakeGoogle(_ calls: Calls, shift: Bool = false) -> Translator.GoogleCall {
        { text in
            await calls.g(text)
            var parts = text.components(separatedBy: "\n\n").map { "번역: " + $0 }
            if shift, parts.count > 1 { parts = Array(parts.dropFirst()) + [parts[0]] } // 문단 수는 같고 한 칸 밀림
            return parts.joined(separator: "\n\n")
        }
    }

    // MARK: 케이스 8 — 글자 없는·주소만 블록
    @Test func noLetterOrUrlOnlyIsNotForeign() {
        #expect(!Translator.looksForeign("16"))
        #expect(!Translator.looksForeign("01 /"))
        #expect(!Translator.looksForeign("|"))
        #expect(!Translator.looksForeign("https://blogs.example.com/wp-content/uploads/2026/10/demo_4k.mp4"))
        #expect(!Translator.looksForeign("  www.example.com/a  "))
        #expect(Translator.looksForeign("GPT-5"))
        #expect(Translator.looksForeign("See https://example.com for details"))
        #expect(Translator.looksForeign("OpenAI releases a new model"))
    }

    @Test func noLetterBlocksAreNotSent() async {
        let calls = Calls()
        let t = Translator(mode: .google, google: Self.fakeGoogle(calls))
        let r = await t.translateManyReporting(["2026", "https://example.com/video.mp4", "Hello world"])
        #expect(r.texts == ["2026", "https://example.com/video.mp4", "번역: Hello world"])
        #expect(await calls.google == ["Hello world"])
    }

    // MARK: 케이스 3 — 제목 끝 마침표
    @Test func titlePeriodDropped() {
        #expect(Translator.polish(source: "Sophos cuts threat investigation time by 96%", translated: "Sophos는 위협 조사 시간을 96% 단축했습니다.") == "Sophos는 위협 조사 시간을 96% 단축했습니다")
        #expect(Translator.polish(source: "It works.", translated: "작동합니다.") == "작동합니다.")
        #expect(Translator.polish(source: "Wait for it", translated: "기다려...") == "기다려...")
        #expect(Translator.polish(source: "Is it real?", translated: "진짜입니까?") == "진짜입니까?")
    }

    // MARK: 케이스 2 — 이름 되돌림
    @Test func namesRestoredOnlyWhenInSource() {
        #expect(Translator.restoreNames(source: "Introducing Claude Corps", translated: "클로드 군단을 소개합니다") == "Claude Corps을 소개합니다")
        #expect(Translator.restoreNames(source: "how people actually use Claude in these contexts", translated: "실제로 클도를 어떻게 사용하는지") == "실제로 Claude를 어떻게 사용하는지")
        #expect(Translator.restoreNames(source: "Claude Opus 5.5 scored 99%", translated: "클로드 Opus 5.5는 99%를 받았다") == "Claude Opus 5.5는 99%를 받았다")
        // 원문에 영문 이름이 없으면 건드리지 않는다
        #expect(Translator.restoreNames(source: "The painter loved water lilies", translated: "클로드는 수련을 좋아했다") == "클로드는 수련을 좋아했다")
        // 사람 이름(Claude 뒤에 제품 낱말이 아닌 대문자 낱말)이면 건드리지 않는다
        #expect(Translator.restoreNames(source: "Claude Monet painted it", translated: "클로드 모네가 그렸다") == "클로드 모네가 그렸다")
        #expect(Translator.restoreNames(source: "Copilot now writes tests", translated: "부조종사가 이제 시험을 작성합니다") == "Copilot가 이제 시험을 작성합니다")
        // 낱말 안에 든 것은 아님(예: Claudette)
        #expect(Translator.restoreNames(source: "Claudette said", translated: "클로드가 말했다") == "클로드가 말했다")
    }

    // MARK: 케이스 10 — 묶음 대조
    @Test func shiftDetection() {
        let src = ["Claude uses 250,000 conversations", "Democracy Works runs TurboVote", "NASA names a deputy in 2023"]
        let ok = ["Claude는 25만 건의 대화를 씁니다", "Democracy Works는 TurboVote를 운영합니다", "NASA는 2023년 부국장을 임명합니다"]
        #expect(!Translator.looksShifted(src, ok))
        let shifted = [ok[1], ok[2], ok[0]]
        #expect(Translator.looksShifted(src, shifted))
        // 숫자를 한국식으로 바꾸거나 영문 낱말이 없는 문단은 밀림으로 보지 않는다
        #expect(!Translator.looksShifted(["It cost $150 million", "Nothing to anchor here"], ["1억 5천만 달러가 들었다", "여기엔 기준이 없다"]))
    }

    @Test func shiftedBatchRetriedPerParagraph() async {
        let calls = Calls()
        let t = Translator(mode: .google, google: Self.fakeGoogle(calls, shift: true))
        let src = ["Alpha news from OpenAI", "Beta update from NVIDIA", "Gamma report by NASA"]
        let r = await t.translateManyReporting(src)
        #expect(r.texts == src.map { "번역: " + $0 }) // 문단별로 다시 받아 제자리
        #expect(await calls.google.count == 1 + src.count)
    }

    // MARK: 번역 방식(설정 translateEngine)
    @Test func offModeSendsNothing() async {
        let calls = Calls()
        let t = Translator(mode: .off, google: Self.fakeGoogle(calls), apple: { s, _ in await calls.a(s); return s.map { "기기: " + $0 } })
        let r = await t.translateManyReporting(["Hello world"])
        #expect(r.texts == ["Hello world"] && r.engine == .none)
        #expect(await t.toEnglish(["안녕하세요"]) == [nil])
        let (g, a) = (await calls.google, await calls.apple)
        #expect(g.isEmpty && a.isEmpty)
    }

    @Test func appleOnlyNeverFallsBackToGoogle() async {
        let calls = Calls()
        let t = Translator(mode: .apple, google: Self.fakeGoogle(calls), apple: { _, _ in nil }) // 자료 없음
        let r = await t.translateManyReporting(["Hello world"])
        #expect(r.texts == ["Hello world"] && r.engine == .none)
        #expect(await t.toEnglish(["안녕하세요"]) == [nil])
        #expect(await calls.google.isEmpty)
    }

    @Test func autoUsesAppleThenGoogleForTheRest() async {
        let calls = Calls()
        // 첫 묶음만 되고 둘째부터 기기 내 번역이 실패
        let t = Translator(mode: .auto, google: Self.fakeGoogle(calls), apple: { s, _ in
            await calls.a(s)
            return await calls.apple.count == 1 ? s.map { "기기: " + $0 } : nil
        })
        let src = (1...6).map { "Paragraph number \($0)" }
        let r = await t.translateStreaming(src, chunk: 4) { _, _ in } // 흘려 받을 때만 4문단씩
        #expect(Array(r.texts.prefix(4)) == src.prefix(4).map { "기기: " + $0 })
        #expect(Array(r.texts.suffix(2)) == src.suffix(2).map { "번역: " + $0 })
        #expect(r.engine == .apple)
    }

    @Test func modeChangeClearsCache() async {
        final class Box: @unchecked Sendable { var mode: Translator.Mode = .google }
        let box = Box(), calls = Calls()
        let t = Translator(modeSource: { box.mode }, google: Self.fakeGoogle(calls), apple: { s, _ in s.map { "기기: " + $0 } })
        #expect(await t.translateMany(["Hello world"]) == ["번역: Hello world"])
        #expect(await t.translateMany(["Hello world"]) == ["번역: Hello world"]) // 캐시
        #expect(await calls.google.count == 1)
        box.mode = .apple
        #expect(await t.translateMany(["Hello world"]) == ["기기: Hello world"]) // 예전 엔진 캐시가 섞이지 않음
    }

    // MARK: 케이스 5 — 흘려 주기
    @Test func streamingReportsAppleChunks() async {
        actor Seen { var sizes: [Int] = []; var keys: Set<Int> = []; func add(_ d: [Int: String]) { sizes.append(d.count); keys.formUnion(d.keys) } }
        let seen = Seen()
        let t = Translator(mode: .auto, apple: { s, _ in s.map { "기기: " + $0 } })
        let src = ["이미 한국어 문단입니다"] + (1...10).map { "Paragraph number \($0)" }
        let r = await t.translateStreaming(src, chunk: 4) { got, engine in
            #expect(engine == .apple)
            await seen.add(got)
        }
        #expect(await seen.sizes == [4, 4, 2])
        #expect(await seen.keys == Set(1...10)) // 원래 순서의 번호로
        #expect(r.texts[0] == src[0] && r.texts[10] == "기기: Paragraph number 10")
    }

    @Test func withoutListenerAppleGetsOneCall() async {
        let calls = Calls()
        let t = Translator(mode: .auto, apple: { s, _ in await calls.a(s); return s.map { "기기: " + $0 } })
        _ = await t.translateManyReporting((1...10).map { "Paragraph number \($0)" })
        #expect(await calls.apple.map(\.count) == [10]) // 예전처럼 세션 한 번
    }

    // MARK: 설정 저장 — 예전 파일·모르는 값은 자동
    @Test func settingDecodes() throws {
        let dec = JSONDecoder()
        #expect(try dec.decode(AppState.Settings.self, from: Data("{}".utf8)).translateEngine == .auto)
        #expect(try dec.decode(AppState.Settings.self, from: Data(#"{"translateEngine":"deepl"}"#.utf8)).translateEngine == .auto)
        var s = AppState.Settings(); s.translateEngine = .off
        let back = try dec.decode(AppState.Settings.self, from: JSONEncoder().encode(s))
        #expect(back.translateEngine == .off)
        #expect(String(decoding: try JSONEncoder().encode(s), as: UTF8.self).contains(#""translateEngine":"off""#))
    }
}
