import AppKit
import Darwin
import Foundation

// 시험 장치: 디버그 빌드(swift build·swift test·e2e·clicksweep)에만 들어간다. 배포 빌드(build.sh, -c release)에는 없음.
#if DEBUG

// 시작 시간·첫 화면 재기(scripts/e2e/startup.sh). DROPCAP_TEST_E2E_PHASE=probe 일 때만.
// 켠 순간(프로세스 시작) → 앱 준비(didFinishLaunching) → 첫 확인 끝까지, 그동안 메인 스레드 최장 지연,
// 그 뒤 매거진 창·스토리 화면을 열 때 메인 최장 지연을 probe.json 에 남긴다. 바깥 스크립트가 창을 여는 동안 sample 을 뜬다.
@MainActor
enum E2EProbe {
    static func run(_ r: E2ERun) async {
        let m = r.model
        let dog = MainWatchdog()
        dog.start()
        let started = processStartUptime()
        let ready = ProcessInfo.processInfo.systemUptime - started
        let check0 = m.state.lastCheck
        // AppModel.start 가 첫 확인을 곧바로 시작한다. 분야를 아직 고르지 않은 첫 실행은 켜진 출처가 없어 바로 끝난다
        let firstCheck = await r.until(240) { m.state.lastCheck != check0 && !m.checking }
        let checked = ProcessInfo.processInfo.systemUptime - started
        let startLag = dog.take()
        var out: [String: Any] = [
            "readySec": round3(ready), "firstCheckSec": firstCheck ? round3(checked) : -1, "startMainMaxMs": Int(startLag.max), "startMainMaxOp": startLag.op,
            "items": Database.shared.itemCount, "enabled": m.allSources.filter { m.state.enabled[$0.id] == true }.count,
            "seen": m.state.seen.count, "footprintMB": Proc.footprintMB(),
        ]
        // 매거진 창(오늘 두 번)·스토리 화면. 스토리를 열기 전에 바깥 sample 이 뜨게 표시를 남김
        let mark = r.out.appendingPathComponent("probe-sample")
        var opens: [Int] = []
        for i in 0..<3 {
            if i == 2 { try? String(getpid()).write(to: mark, atomically: true, encoding: .utf8); await r.sleep(1) }
            _ = dog.take()
            E2ESoakProbe.op = "magazine-\(i)"
            MagazineController.open(page: i == 2 ? .stories : .today)
            await r.sleep(i == 2 ? 12 : 3)
            opens.append(Int(dog.take().max))
            NSApp.windows.first { $0.title == "Dropcap" }?.close()
            await r.sleep(0.5)
        }
        out["magazineOpenMainMaxMs"] = opens // [첫 열기(오늘), 다시 열기(오늘), 스토리]
        try? FileManager.default.removeItem(at: mark)
        dog.stop()
        if let d = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .prettyPrinted]) {
            try? d.write(to: r.out.appendingPathComponent("probe-\(ProcessInfo.processInfo.environment["DROPCAP_PROBE_NAME"] ?? "run").json"))
        }
        r.note("시작 재기: \(out)")
    }

    static func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

    // 프로세스가 시작된 때(부팅 뒤 경과 초). 커널의 시작 시각(벽시계)을 지금 벽시계와 비교한다 — 시험 시계와 무관하게 실제 시계로
    static func processStartUptime() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return ProcessInfo.processInfo.systemUptime }
        let st = info.kp_proc.p_un.__p_starttime
        let start = Double(st.tv_sec) + Double(st.tv_usec) / 1e6
        var tv = timeval()
        realGettimeofday(&tv)
        let now = Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6
        return ProcessInfo.processInfo.systemUptime - (now - start)
    }

    // fakeclock 이 끼운 gettimeofday 를 거치지 않는 실제 벽시계(mach 절대 시계 기준 — CLOCK_REALTIME 은 끼워 넣기 대상)
    static func realGettimeofday(_ tv: inout timeval) {
        let offset = ProcessInfo.processInfo.environment["DYLD_INSERT_LIBRARIES"]?.contains("fakeclock") == true ? E2ERun.current?.clock.offset ?? 0 : 0
        gettimeofday(&tv, nil)
        tv.tv_sec -= Int(offset)
    }
}

#endif
