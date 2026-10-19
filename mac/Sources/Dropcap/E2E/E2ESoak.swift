import AppKit
import Darwin
import Foundation

// 시험 장치: 디버그 빌드(swift build·swift test·e2e·clicksweep)에만 들어간다. 배포 빌드(build.sh, -c release)에는 없음.
#if DEBUG

// 오래 켜 두기 시험(soak· scripts/e2e/soak.sh). DROPCAP_TEST_E2E_PHASE=soak 일 때만.
// 견본 피드(E2EFeeds)·시험 시계(fakeclock)로 며칠치를 빨리 돌리며, 시험 시각 1시간마다 메모리·열린 파일·스레드·DB·캐시 크기와
// 메인 스레드 멈춤(가장 긴 지연)을 soak.jsonl 에 남긴다. 사람이 쓰듯 매거진·스토리·검색·읽기 창·사진도 주기적으로 연다.
// - DROPCAP_SOAK_DAYS(기본 3) · DROPCAP_SOAK_STEP_MIN(확인 간격, 기본 10) · DROPCAP_SOAK_POSTS(확인마다 새 글, 기본 20)
// - 끝나면 soak-ready 파일을 쓰고 바깥 스크립트가 leaks·footprint 를 잴 때까지(soak-done) 기다린 뒤 끝낸다.
@MainActor
enum E2ESoak {
    static func run(_ r: E2ERun) async {
        let env = ProcessInfo.processInfo.environment
        let days = Double(env["DROPCAP_SOAK_DAYS"] ?? "") ?? 3
        let stepMin = Double(env["DROPCAP_SOAK_STEP_MIN"] ?? "") ?? 10
        let perStep = Int(env["DROPCAP_SOAK_POSTS"] ?? "") ?? 20
        let m = r.model
        m.update { $0.intervalMinutes = 24 * 60; $0.digestEnabled = true; $0.sound = false } // 확인 시점은 시험이 정한다
        let watchdog = MainWatchdog()
        watchdog.start()

        // 모든 분야를 고른다(출처를 많이 켜서 실제 147곳에 가깝게)
        m.chooseSections(Sections.all.map(\.id))
        OnboardingController.close()
        await r.until(120) { !Magazine.shared.preparing && Database.shared.itemCount > 0 }
        var t = r.at(8, 0)
        r.setClock(t, "오래 켜 두기 시작")
        await r.check() // 첫 확인: 기존 글은 기억만
        let sources = m.allSources.filter { m.state.enabled[$0.id] == true && $0.type != "sitemap" }
        r.note("켜진 출처 \(sources.count)곳 · \(days)일 · \(stepMin)분마다 확인 · 확인마다 새 글 \(perStep)건")

        let out = r.out.appendingPathComponent("soak.jsonl")
        try? Data().write(to: out)
        let file = try? FileHandle(forWritingTo: out)
        var rng = SeededRandom(seed: 20261016)
        let steps = Int(days * 24 * 60 / stepMin)
        let started = ProcessInfo.processInfo.systemUptime // 시험 시계와 무관한 실제 경과
        var storyN = 0
        var lastSample = -1
        var checkMs: [Double] = []
        var uiMs: [String: Double] = [:]
        for step in 0..<steps {
            t = t.addingTimeInterval(stepMin * 60)
            r.clock.set(t)
            // 새 글: 같은 이야기를 1~4곳이 다룸(같은 지역 출처끼리)
            var posted = 0
            while posted < perStep {
                storyN += 1
                let n = [1, 1, 1, 2, 2, 3, 4].randomElement(using: &rng)!
                let kr = Bool.random(using: &rng)
                let pool = sources.filter { $0.isDomestic == kr }
                guard !pool.isEmpty else { break }
                let title = SoakWords.title(kr: kr, n: storyN, rng: &rng)
                for (i, src) in pool.shuffled(using: &rng).prefix(n).enumerated() {
                    E2EFeeds.post(.init(sourceId: src.id, id: "k\(storyN)-\(i)", title: title + (i == 0 ? "" : (kr ? " 종합" : " - update")),
                                        summary: SoakWords.summary(kr: kr, rng: &rng), date: t.addingTimeInterval(-Double(i) * 30),
                                        image: Bool.random(using: &rng) ? "https://img.\(E2EFeeds.host)/k\(storyN)-\(i).png" : nil))
                    posted += 1
                }
            }
            E2ESoakProbe.op = "check"
            let c0 = ProcessInfo.processInfo.systemUptime
            await r.check()
            checkMs.append((ProcessInfo.processInfo.systemUptime - c0) * 1000)
            E2ESoakProbe.op = "minute"
            AppModel.minuteTimerFired()
            await r.sleep(0.05)

            // 사람이 쓰듯: 1시간마다 화면들, 6시간마다 창 여닫기
            let hour = Int(Double(step + 1) * stepMin / 60)
            if hour != lastSample {
                lastSample = hour
                uiMs = await exerciseUI(r, hour: hour, rng: &rng)
                let s = sample(r, step: step, simHours: Double(step + 1) * stepMin / 60, real: ProcessInfo.processInfo.systemUptime - started,
                               checkMs: checkMs, ui: uiMs, watchdog: watchdog)
                checkMs = []
                if let d = try? JSONSerialization.data(withJSONObject: s, options: [.sortedKeys]) { file?.write(d + Data("\n".utf8)) }
                if hour % 6 == 0 { r.note("시험 \(hour)시간: \(s["footprintMB"] ?? 0)MB · 파일 \(s["fds"] ?? 0) · 스레드 \(s["threads"] ?? 0) · DB \(s["dbKB"] ?? 0)KB · 기사 \(s["items"] ?? 0) · 메인 최장 \(s["mainMaxMs"] ?? 0)ms(\(s["mainMaxOp"] ?? ""))") }
            }
        }
        try? file?.close()
        watchdog.stop()
        Store.flush()
        // 바깥에서 leaks·footprint 를 잴 동안 기다린다(최대 5분)
        let ready = r.out.appendingPathComponent("soak-ready"), done = r.out.appendingPathComponent("soak-done")
        try? String(getpid()).write(to: ready, atomically: true, encoding: .utf8)
        await r.until(300) { FileManager.default.fileExists(atPath: done.path) }
        r.record("soak", "오래 켜 두기 \(days)일(시험 시계)", expected: "soak.jsonl 의 지표가 계속 늘지 않음",
                 actual: "확인 \(steps)번 · 실제 \(Int(ProcessInfo.processInfo.systemUptime - started))초", pass: nil)
    }

    // 사람이 쓰는 화면을 차례로 불러 걸린 시간을 잰다(ms)
    static func exerciseUI(_ r: E2ERun, hour: Int, rng: inout SeededRandom) async -> [String: Double] {
        var ms: [String: Double] = [:]
        let up = { ProcessInfo.processInfo.systemUptime }
        func time(_ k: String, _ f: () -> Void) { E2ESoakProbe.op = k; let a = up(); f(); ms[k] = (up() - a) * 1000 }
        func timeAsync(_ k: String, _ f: () async -> Void) async { E2ESoakProbe.op = k; let a = up(); await f(); ms[k] = (up() - a) * 1000 }
        let mag = Magazine.shared
        await timeAsync("today") { _ = await mag.today() }
        await timeAsync("week") { _ = await mag.week() }
        await timeAsync("section") { _ = await mag.section("economy") }
        await timeAsync("storyGroups") { _ = await mag.storyCards() }
        await timeAsync("search") { _ = await mag.search(["금리", "market", "정부", "climate"].randomElement(using: &rng)!) }
        let m = r.model
        if let it = m.visibleRecent.first {
            time("open") { m.markOpened(it) }
            await timeAsync("reader") { _ = await ArticleService.shared.prepare(it) }
            if let img = it.image { await timeAsync("image") { _ = await ImageLoader.shared.image(img) } }
            if hour % 12 == 0 { m.toggleSaved(it) }
        }
        if let c = mag.lastStoryCards.live.first { m.markStorySeen(c.id, size: c.cluster.size) }
        if hour % 6 == 0 { // 창 여닫기(조용한 모드라 화면 밖·투명)
            E2ESoakProbe.op = "windows"
            MagazineController.open()
            await r.sleep(1.5)
            NSApp.windows.first { $0.title == "Dropcap" }?.close()
            if let it = m.visibleRecent.dropFirst().first {
                ReaderController.open(it)
                await r.sleep(1.5)
                NSApp.windows.first { $0.title == it.sourceName && $0.isVisible }?.close()
            }
            if hour % 24 == 0 { m.markAllRead() }
        }
        E2ESoakProbe.op = "idle"
        return ms
    }

    // MARK: 지표
    static func sample(_ r: E2ERun, step: Int, simHours: Double, real: Double, checkMs: [Double], ui: [String: Double], watchdog: MainWatchdog) -> [String: Any] {
        let dir = Store.dir
        let m = r.model.state
        let lag = watchdog.take()
        var s: [String: Any] = [
            "step": step, "simHours": simHours.rounded(), "realSec": Int(real),
            "footprintMB": Proc.footprintMB(), "residentMB": Proc.residentMB(), "fds": Proc.openFiles(), "threads": Proc.threads(),
            "dbKB": fileKB(dir.appendingPathComponent("magazine.sqlite")), "walKB": fileKB(dir.appendingPathComponent("magazine.sqlite-wal")),
            "stateKB": fileKB(Store.file), "imagesN": dirStats(dir.appendingPathComponent("images")).n, "imagesKB": dirStats(dir.appendingPathComponent("images")).kb,
            "articlesN": dirStats(dir.appendingPathComponent("articles")).n, "articlesKB": dirStats(dir.appendingPathComponent("articles")).kb,
            "items": Database.shared.itemCount, "clusters": Database.shared.recentClusters(since: .distantPast).count, "issues": Database.shared.issues(limit: 100_000).count,
            "seen": m.seen.count, "read": m.read.count, "recent": m.recent.count, "storySeen": m.storySeen.count, "pending": m.pending.count,
            "saved": m.saved.count, "notifyLog": m.notifyLog.count, "notifiedStories": m.notifiedStories.count,
            "checkMsAvg": checkMs.isEmpty ? 0 : Int(checkMs.reduce(0, +) / Double(checkMs.count)), "checkMsMax": Int(checkMs.max() ?? 0),
            "mainMaxMs": Int(lag.max), "mainMaxOp": lag.op, "mainOver250": lag.over250, "mainOver1000": lag.over1000,
        ]
        for (k, v) in ui { s["ui_" + k] = Int(v) }
        return s
    }

    static func fileKB(_ u: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0) / 1024 }
    static func dirStats(_ u: URL) -> (n: Int, kb: Int) {
        let files = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return (files.count, files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } / 1024)
    }
}

// 지금 무엇을 하는 중인지(메인 지연이 어디서 났는지 적으려고)
enum E2ESoakProbe {
    nonisolated(unsafe) static var op = "start"
}

// 메인 스레드 지연 재기: 뒤 스레드가 100ms 마다 메인 큐에 일을 넣고, 실제로 돌기까지 걸린 시간을 잰다
final class MainWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var maxLag = 0.0, maxOp = "", over250 = 0, over1000 = 0
    private var running = false

    func start() {
        lock.lock(); running = true; lock.unlock()
        Thread.detachNewThread { [self] in
            while true {
                lock.lock(); let go = running; lock.unlock()
                guard go else { return }
                let sent = DispatchTime.now().uptimeNanoseconds
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.main.async {
                    let lag = Double(DispatchTime.now().uptimeNanoseconds - sent) / 1e6
                    self.lock.lock()
                    if lag > self.maxLag { self.maxLag = lag; self.maxOp = E2ESoakProbe.op }
                    if lag > 250 { self.over250 += 1 }
                    if lag > 1000 { self.over1000 += 1 }
                    self.lock.unlock()
                    sem.signal()
                }
                sem.wait()
                usleep(100_000)
            }
        }
    }
    func stop() { lock.lock(); running = false; lock.unlock() }
    // 지난 표본 이후 값(돌려주고 비움)
    func take() -> (max: Double, op: String, over250: Int, over1000: Int) {
        lock.lock(); defer { maxLag = 0; maxOp = ""; over250 = 0; over1000 = 0; lock.unlock() }
        return (maxLag, maxOp, over250, over1000)
    }
}

// 이 프로세스의 자원
enum Proc {
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }
    static func residentMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        return kr == KERN_SUCCESS ? Int(info.resident_size / 1_048_576) : -1
    }
    static func openFiles() -> Int {
        let size = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        return size > 0 ? Int(size) / MemoryLayout<proc_fdinfo>.size : -1
    }
    static func threads() -> Int {
        var list: thread_act_array_t?
        var n: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &n) == KERN_SUCCESS, let list else { return -1 }
        for i in 0..<Int(n) { mach_port_deallocate(mach_task_self_, list[i]) }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(n) * MemoryLayout<thread_t>.size))
        return Int(n)
    }
}

// 재현되는 무작위(같은 씨앗 → 같은 시험)
struct SeededRandom: RandomNumberGenerator {
    private var x: UInt64
    init(seed: UInt64) { x = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 { x ^= x << 13; x ^= x >> 7; x ^= x << 17; return x }
}

// 견본 제목: 이야기마다 다른 낱말 조합(같은 이야기의 여러 보도는 같은 제목 줄기)
enum SoakWords {
    static let ko = ["정부", "국회", "금리", "환율", "수출", "반도체", "배터리", "부동산", "물가", "고용", "증시", "코스피", "기업", "은행", "예산", "세금",
                     "교육", "의료", "병원", "날씨", "태풍", "지진", "선거", "외교", "회담", "협상", "관세", "무역", "에너지", "전기요금", "철도", "항공",
                     "인공지능", "데이터", "보안", "통신", "자동차", "조선", "철강", "농업", "어업", "관광", "문화", "영화", "음악", "스포츠", "야구", "축구"]
    static let en = ["government", "parliament", "rates", "currency", "exports", "chips", "battery", "housing", "inflation", "jobs", "stocks", "bank",
                     "budget", "taxes", "school", "health", "hospital", "weather", "storm", "earthquake", "election", "diplomacy", "summit", "talks",
                     "tariffs", "trade", "energy", "power", "rail", "airline", "model", "data", "security", "telecom", "carmaker", "shipyard", "steel",
                     "farming", "fishing", "tourism", "culture", "film", "music", "sport", "baseball", "football", "climate", "ocean"]
    static func title(kr: Bool, n: Int, rng: inout SeededRandom) -> String {
        let pool = kr ? ko : en
        let words = (0..<6).map { _ in pool.randomElement(using: &rng)! }
        return words.joined(separator: " ") + (kr ? " \(n)호 소식" : " report \(n)")
    }
    static func summary(kr: Bool, rng: inout SeededRandom) -> String {
        let pool = kr ? ko : en
        return (0..<18).map { _ in pool.randomElement(using: &rng)! }.joined(separator: " ")
    }
}

#endif
