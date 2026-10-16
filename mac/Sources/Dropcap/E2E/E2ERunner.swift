import AppKit
import Combine
import SwiftUI

// 시험 장치(M9): 디버그 빌드(swift build·swift test·e2e·clicksweep)에만 들어간다. 배포 빌드(build.sh, -c release)에는 없음.
#if DEBUG

// 사용자 흐름 시나리오 시험(끝에서 끝까지). DROPCAP_TEST_E2E=<결과 폴더> 일 때만 돈다(mac/scripts/e2e/run.sh).
// 사람이 쓰는 순서대로 단계를 밟으며 단계마다 기대값을 검사하고(통과/실패) 스냅샷·로그를 남긴다.
// - 피드: E2EFeeds(견본, 네트워크 없음) · 시계: fakeclock.dylib(DROPCAP_CLOCK_FILE 의 초만큼 앞당김)
// - 단계(DROPCAP_TEST_E2E_PHASE): main(1~11·12 준비) · restart(다시 시작해 상태 유지) · recover(깨진 상태 파일·DB 복구)
// 앱 기능 코드는 고치지 않고 내부 API(AppModel·Magazine·Scrapbook 등)만 부른다.
@MainActor
enum E2ERunner {
    static func startIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["DROPCAP_TEST_E2E"] else { return }
        E2EFeeds.installOffline()
        E2EQuietUI.install() // 사용자 화면·포커스를 건드리지 않게(DROPCAP_TEST_REAL_UI=1 이면 끔)
        let run = E2ERun(out: URL(fileURLWithPath: out, isDirectory: true), phase: env["DROPCAP_TEST_E2E_PHASE"] ?? "main")
        E2ERun.current = run
        run.prepareClock()
        if run.phase == "clicks" { // 창이 생기기 전에 손쉬운 사용 나무를 켜 둔다
            E2EClickSweep.primeAccessibility()
        }
        Task { await run.start() }
    }
}

// MARK: - 시험용 시계(fakeclock.dylib 와 짝)
@MainActor
struct E2EClock {
    let file: URL?
    private(set) var offset: Double = 0
    private(set) var working = false

    init() {
        file = ProcessInfo.processInfo.environment["DROPCAP_CLOCK_FILE"].map { URL(fileURLWithPath: $0) }
        if let file, let s = try? String(contentsOf: file, encoding: .utf8), let v = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) { offset = v }
        working = offset != 0 && ProcessInfo.processInfo.environment["DYLD_INSERT_LIBRARIES"]?.contains("fakeclock") == true // 앞 실행이 옮긴 시각을 이어 씀
    }

    // 앱의 '지금'을 target 으로. 끼워 넣기가 없으면 working = false(시각에 기대는 검사는 '확인 못 함')
    mutating func set(_ target: Date) {
        guard let file else { working = false; return }
        let real = Date().addingTimeInterval(working || offset != 0 ? -offset : 0)
        offset = (target.timeIntervalSince(real)).rounded()
        try? String(format: "%.0f", offset).write(to: file, atomically: true, encoding: .utf8)
        usleep(120_000) // 라이브러리가 50ms 마다 다시 읽음
        working = abs(Date().timeIntervalSince(target)) < 5
    }
    // 처음 실행: 끼워 넣기가 실제로 되는지 확인(오늘 10:00 로 옮겨 봄)
    mutating func probe(_ target: Date) {
        guard let file else { return }
        try? "0".write(to: file, atomically: true, encoding: .utf8)
        usleep(120_000)
        let real = Date()
        offset = target.timeIntervalSince(real).rounded()
        try? String(format: "%.0f", offset).write(to: file, atomically: true, encoding: .utf8)
        usleep(120_000)
        working = abs(Date().timeIntervalSince(target)) < 5
    }
}

// MARK: - 결과
struct E2EStep: Codable {
    var id: String
    var title: String
    var expected: String
    var actual: String = ""
    var pass: Bool? = nil          // nil = 자동으로 확인 못 함
    var shots: [String] = []
    var at: String = ""            // 시험 시계 시각
}

@MainActor
final class E2ERun {
    static var current: E2ERun?

    let out: URL
    let phase: String
    let model = AppModel.shared
    var clock = E2EClock()
    private var steps: [E2EStep] = []
    private var log: FileHandle?
    private var toastSub: AnyCancellable?
    private var seenToasts: Set<UUID> = []
    private(set) var toastLog: [(at: Date, kind: Toast.Kind)] = []
    private let cal = Calendar.current
    private var day0: Date { cal.startOfDay(for: Date()) }   // 지금(시험 시계) 날짜

    init(out: URL, phase: String) {
        self.out = out
        self.phase = phase
        try? FileManager.default.createDirectory(at: out.appendingPathComponent("shots"), withIntermediateDirectories: true)
        let lf = out.appendingPathComponent("e2e.log")
        if !FileManager.default.fileExists(atPath: lf.path) { FileManager.default.createFile(atPath: lf.path, contents: nil) }
        log = try? FileHandle(forWritingTo: lf)
        log?.seekToEndOfFile()
    }

    func prepareClock() {
        guard phase == "main" else { return } // 다시 시작한 실행은 앞 실행이 남긴 시각을 이어 씀
        let real = Date()
        clock.probe(cal.date(bySettingHour: 10, minute: 0, second: 0, of: real)!)
    }

    // MARK: 기록
    private static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"; return f }()
    func note(_ s: String) {
        let line = "[\(phase) \(Self.stamp.string(from: Date()))] \(s)\n"
        log?.write(Data(line.utf8))
        NSLog("[E2E] %@", s)
    }

    @discardableResult
    func record(_ id: String, _ title: String, expected: String, actual: String, pass: Bool?, shots: [String] = []) -> Bool {
        steps.append(E2EStep(id: id, title: title, expected: expected, actual: actual, pass: pass, shots: shots, at: Self.stamp.string(from: Date())))
        note("\(pass.map { $0 ? "통과" : "실패" } ?? "확인 못 함") \(id) \(title) — \(actual)")
        save()
        return pass ?? false
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(steps) { try? d.write(to: out.appendingPathComponent("results-\(phase).json")) }
    }

    // MARK: 알림 지켜보기
    func watchToasts() {
        toastSub = ToastCenter.shared.$toasts.sink { [weak self] list in
            MainActor.assumeIsolated {
                guard let self else { return }
                for t in list where !self.seenToasts.contains(t.id) {
                    self.seenToasts.insert(t.id)
                    self.toastLog.append((Date(), t.kind))
                    self.note("  물방울: \(Self.describe(t.kind))")
                }
            }
        }
    }
    static func describe(_ k: Toast.Kind) -> String {
        switch k {
        case .news(let it): return "소식 [\(it.sourceName)] \(it.displayTitle)\(it.related.map { " (+\($0.count)곳)" } ?? "")"
        case .info(let a, let b): return "안내 \(a) / \(b)"
        case .more(let n): return "더 \(n)건"
        case .digest(let n): return "브리핑 \(n)건"
        case .bundle(let s, let items): return "묶음 \(Sections.name(s)) \(items.count)건: \(items.prefix(2).map(\.displayTitle).joined(separator: " · "))"
        case .watch(let w, let items): return "지켜볼 낱말 \(w) \(items.count)건"
        }
    }
    var toastMark: Int { toastLog.count }
    func toasts(since m: Int) -> [Toast.Kind] { Array(toastLog.dropFirst(m).map(\.kind)) }
    func newsToasts(since m: Int) -> [NewsItem] { toasts(since: m).compactMap { if case .news(let it) = $0 { return it }; return nil } }

    // MARK: 도우미
    func sleep(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

    @discardableResult
    func until(_ timeout: Double, _ cond: () -> Bool) async -> Bool {
        var waited = 0.0 // 벽시계 대신 기다린 횟수로 센다(시험 시계가 옮겨져도 그대로)
        while !cond() {
            if waited >= timeout { return false }
            await sleep(0.25); waited += 0.25
        }
        return true
    }

    // 앱의 자동 확인과 겹치지 않게 기다렸다가 한 번 확인
    func check() async {
        await until(60) { !model.checking }
        await model.checkAll()
        await sleep(1.2) // 물방울은 0.32초 간격으로 떨어진다
    }

    func setClock(_ d: Date, _ why: String) {
        clock.set(d)
        note("시계 → \(Self.stamp.string(from: d)) (\(why)) \(clock.working ? "" : "※ 시계 끼워 넣기 안 됨")")
    }
    func at(day: Int = 0, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(bySettingHour: h, minute: m, second: 0, of: cal.date(byAdding: .day, value: day, to: baseDay)!)!
    }
    private var baseDay = Date()

    func key(_ src: String, _ id: String) -> String { "\(src)|\(id)" }
    func story(_ src: String, _ id: String) -> String? { Database.shared.clusterOf(key(src, id)) }

    // 이야기 하나를 여러 출처에 올린다. 앞 출처일수록 최신(대표가 되게).
    func publish(_ s: E2EStory, at now: Date, offsetMinutes: Double = 0) {
        for (i, src) in s.sources.enumerated() {
            let title = s.title(for: i)
            E2EFeeds.post(.init(sourceId: src, id: s.id + "-" + src, title: title, summary: s.summary,
                                date: now.addingTimeInterval(-offsetMinutes * 60 - Double(i) * 20), image: "https://img.\(E2EFeeds.host)/\(s.id)-\(src).png"))
        }
    }
    func storyOf(_ s: E2EStory) -> String? { story(s.sources[0], s.id + "-" + s.sources[0]) }
    func notified(_ s: E2EStory) -> Bool { storyOf(s).map { model.state.notifiedStories[$0] != nil } ?? false }
    func pending(_ s: E2EStory) -> String? {
        guard let st = storyOf(s) else { return nil }
        return model.state.pending.first { $0.story == st }?.section
    }
    func coverage(_ s: E2EStory) async -> Coverage? {
        let k = key(s.sources[0], s.id + "-" + s.sources[0])
        guard let it = Database.shared.items(keys: [k]).first?.item else { return nil }
        return await Magazine.shared.storyInfo([it])[k]?.coverage
    }
    func dropped(_ s: E2EStory, in items: [NewsItem]) -> Bool {
        let st = storyOf(s)
        return items.contains { $0.id.hasPrefix(s.id + "-") || (st != nil && Database.shared.clusterOf($0.key) == st) }
    }

    // MARK: 스냅샷
    func shotPath(_ name: String) -> String { out.appendingPathComponent("shots/\(phase)-\(name).png").path }
    @discardableResult
    func toastShot(_ name: String) async -> String {
        await sleep(2.5) // 물방울이 맺혔다 떨어져 자리 잡은 뒤
        let p = shotPath(name)
        ToastCenter.shared.snapshot(to: p)
        return FileManager.default.fileExists(atPath: p) ? "shots/\((p as NSString).lastPathComponent)" : "(찍지 못함)"
    }
    @discardableResult
    func windowShot(_ match: (NSWindow) -> Bool, _ name: String) -> String {
        guard let v = NSApp.windows.first(where: { $0.isVisible && match($0) })?.contentView,
              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return "(창 없음)" }
        v.cacheDisplay(in: v.bounds, to: rep)
        let p = shotPath(name)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: p))
        return "shots/\((p as NSString).lastPathComponent)"
    }
    @discardableResult
    func render<V: View>(_ view: V, _ name: String) -> String {
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let cg = r.cgImage else { return "(그리지 못함)" }
        let p = shotPath(name)
        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: p))
        return "shots/\((p as NSString).lastPathComponent)"
    }

    // MARK: 시작
    func start() async {
        model.update { $0.sound = false } // 시험 물방울이 소리를 내지 않게(사용자 작업 방해 금지)
        watchToasts()
        note("=== \(phase) 시작 · 시험 시계 \(clock.working ? "작동" : "없음(실제 시각)") · 데이터 \(Store.dir.path)")
        baseDay = cal.startOfDay(for: Date())
        if let s = try? String(contentsOf: out.appendingPathComponent("base-day.txt"), encoding: .utf8), let t = Double(s) {
            baseDay = Date(timeIntervalSince1970: t)
        } else {
            try? String(baseDay.timeIntervalSince1970).write(to: out.appendingPathComponent("base-day.txt"), atomically: true, encoding: .utf8)
        }
        switch phase {
        case "restart": await E2EPhases.restart(self)
        case "recover": await E2EPhases.recover(self)
        case "clicks": await E2EClickPhase.run(self)
        case "header": await E2EHeaderPhase.run(self) // 창 머리 겹침 스냅샷(scripts/e2e/header.sh)
        case "soak": await E2ESoak.run(self) // 오래 켜 두기(scripts/e2e/soak.sh · STABILITY.md)
        case "faults": await E2EFaults.run(self) // 실패 처리(scripts/e2e/faults.sh · STABILITY.md)
        case "probe": await E2EProbe.run(self) // 시작 시간·첫 화면(scripts/e2e/startup.sh · STABILITY.md)
        default: await E2EPhases.main(self)
        }
        note("=== \(phase) 끝: \(steps.filter { $0.pass == true }.count) 통과 · \(steps.filter { $0.pass == false }.count) 실패 · \(steps.filter { $0.pass == nil }.count) 확인 못 함")
        save()
        Store.flush()
        try? log?.synchronize()
        await sleep(1)
        exit(0)
    }

    var stepsSoFar: [E2EStep] { steps }
}

// MARK: - 견본 이야기(같은 소식을 여러 곳이 다룸)
struct E2EStory {
    let id: String
    let base: String              // 모든 출처가 쓰는 제목 줄기(낱말이 많이 겹쳐 같은 소식으로 묶임)
    let tails: [String]           // 출처마다 덧붙이는 말
    let sources: [String]
    var summary = "시나리오 시험 견본 기사"
    func title(for i: Int) -> String { tails.isEmpty ? base : base + " " + tails[i % tails.count] }
}

enum E2EStories {
    static let extraKr = ["yna-politics", "donga-politics", "yna-society"] // 국내 8곳을 채우려고 더 켜는 출처(고르지 않은 분야)
    static let kr3 = ["yna-market", "hk-finance", "sbs-top"]
    static let koTails = ["종합", "속보", "분석", "해설", "현장", "정리", "전망", "여파"]
    static let enTails = ["", "- live", "report"]

    // 4) 새 글 도착
    static let s1 = E2EStory(id: "s1", base: "한국은행 기준금리 인하 결정 가계대출 부담", tails: koTails, sources: kr3)          // 국내 3곳 → 즉시
    static let s2 = E2EStory(id: "s2", base: "코스닥 바이오 종목 일제히 급등 거래대금 증가", tails: koTails, sources: ["yna-market", "hk-finance"]) // 국내 2곳 → 매거진만
    static let s3 = E2EStory(id: "s3", base: "Pacific island nations sign ocean treaty at regional summit", tails: enTails, sources: ["bbc-world", "guardian-world"]) // 해외 2곳 → 즉시
    static let s4 = E2EStory(id: "s4", base: "Sample research note on evaluation methods for language systems", tails: [], sources: ["openai"]) // AI(묶음) → 고임
    // 5) 하루 상한
    static let caps: [E2EStory] = [
        E2EStory(id: "e1", base: "원달러 환율 급락 수출기업 환차손 우려 확산", tails: koTails, sources: kr3),
        E2EStory(id: "e2", base: "부동산 거래량 석달째 감소 매매가격 하락 지속", tails: koTails, sources: kr3),
        E2EStory(id: "e3", base: "소비자물가 상승률 둔화 식료품 가격 안정세", tails: koTails, sources: kr3),
        E2EStory(id: "e4", base: "국제유가 급등 정유업계 실적 개선 기대감", tails: koTails, sources: kr3),
        E2EStory(id: "e5", base: "법인세 개편안 발표 중소기업 세부담 완화 매출", tails: koTails, sources: kr3),
        E2EStory(id: "e6", base: "가상자산 거래소 규제 강화 투자자 보호 증시", tails: koTails, sources: kr3),
    ]
    static let big = E2EStory(id: "b8", base: "정부 인공지능 반도체 특별법 국회 통과 대규모 보조금", tails: koTails,
                              sources: ["yna-market", "hk-finance", "sbs-top", "yna-world", "aitimes"] + extraKr) // 국내 8곳 → 상한 무시
    // 7) 재보도·팔로우
    static let s1again = E2EStory(id: "s1", base: s1.base, tails: ["후속"], sources: ["yna-world"])
    static let s2follow = E2EStory(id: "s2", base: s2.base, tails: ["마감"], sources: ["sbs-top"])
    static let s1late = E2EStory(id: "s1", base: s1.base, tails: ["사흘째"], sources: ["yna-politics"])
    // 8) 방해 금지·잠시 끄기
    static let q1 = E2EStory(id: "q1", base: "Arctic research station records unusual winter warmth", tails: enTails, sources: ["bbc-world", "guardian-world"])
    static let q2 = E2EStory(id: "q2", base: "Mountain rescue teams adopt new avalanche drones", tails: enTails, sources: ["bbc-world", "guardian-world"])
    // 11) 줄이기
    static let hidden = E2EStory(id: "h1", base: "중앙은행 디지털화폐 시범사업 착수 금융권 참여", tails: koTails, sources: ["hk-finance", "yna-market", "sbs-top"])
    static let less = E2EStory(id: "w2", base: "Coral reef survey finds rapid recovery in protected zones", tails: enTails, sources: ["bbc-world", "guardian-world"])
    static let krVisible = ["yna-market", "sbs-top", "yna-world"] // 11단계에서 hk-finance 를 숨긴 뒤에 쓰는 국내 3곳
    static let muted = E2EStory(id: "m1", base: "희토류 수출 통제 확대 배터리 업계 비상", tails: koTails, sources: krVisible)
    static let control = E2EStory(id: "c1", base: "공공요금 인상 시기 조정 서민 부담 경감 물가", tails: koTails, sources: krVisible)
    // 12) 복구 뒤 새 글
    static let after = E2EStory(id: "r1", base: "항공업계 겨울 성수기 증편 계획 발표 환율", tails: koTails, sources: krVisible)
}

#endif
