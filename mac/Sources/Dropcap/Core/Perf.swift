import AppKit
import Foundation

// 메인 스레드(화면 줄기) 막힘 재기: 뒤 스레드가 5ms 마다 메인에 빈 일을 던지고 돌아오기까지 걸린 시간을 잰다.
// 16ms(한 프레임)를 넘게 늦으면 그만큼 화면이 멈춘 것으로 센다.
final class MainStallMonitor: @unchecked Sendable {
    struct Report: CustomStringConvertible {
        var blockedMs: Double = 0   // 16ms 넘게 늦은 핑들의 늦은 시간 합
        var maxMs: Double = 0       // 가장 길게 멈춘 한 번
        var stalls = 0              // 16ms 넘게 멈춘 횟수
        var wallMs: Double = 0      // 잰 구간 전체 시간
        var description: String { String(format: "멈춤 합 %.0fms · 최장 %.0fms · %d번 · 전체 %.0fms", blockedMs, maxMs, stalls, wallMs) }
    }
    private let lock = NSLock()
    private var running = false
    private var report = Report()
    private var started = Date()

    func start() {
        lock.lock(); running = true; report = Report(); started = Date(); lock.unlock()
        Thread.detachNewThread { [self] in
            while true {
                lock.lock(); let go = running; lock.unlock()
                guard go else { break }
                let t0 = DispatchTime.now().uptimeNanoseconds
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { sem.signal() }
                sem.wait()
                let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                if ms > 16 {
                    lock.lock(); report.blockedMs += ms; report.maxMs = max(report.maxMs, ms); report.stalls += 1; lock.unlock()
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
    }

    func stop() -> Report {
        lock.lock(); running = false; var r = report; r.wallMs = Date().timeIntervalSince(started) * 1000; lock.unlock()
        return r
    }

    // 구간 하나를 재기(메인에서 부름 — 재는 동안 메인이 잠깐 비어야 핑이 돌아오므로 시작 뒤 한 번 쉰다)
    @MainActor static func measure(_ work: () async -> Void) async -> Report {
        let m = MainStallMonitor()
        m.start()
        try? await Task.sleep(for: .milliseconds(30))
        await work()
        try? await Task.sleep(for: .milliseconds(60)) // 마지막 핑이 돌아오게
        var r = m.stop()
        r.wallMs -= 90
        return r
    }
}

// 시험용: DROPCAP_TEST_PERF=<폴더> 면 시작 뒤 정해진 일들을 하며 메인 막힘을 재고 perf.txt 로 남긴 뒤 끝낸다.
@MainActor
enum PerfHarness {
    static func run(dir: String) {
        // 재는 동안 물방울 알림이 뜨면 창 서버 동기화 대기가 섞이므로 알림을 잠시 끈다
        AppModel.shared.snooze(Date().addingTimeInterval(3600))
        Task {
            // 첫 호 엮기·시작 확인이 끝나기를 기다림
            for _ in 0..<600 where AppModel.shared.checking || Magazine.shared.preparing { try? await Task.sleep(for: .milliseconds(200)) }
            try? await Task.sleep(for: .seconds(3))
            var lines: [String] = []
            func log(_ name: String, _ r: MainStallMonitor.Report, _ extra: String = "") {
                let l = "\(name): \(r)\(extra.isEmpty ? "" : " · " + extra)"
                lines.append(l)
                NSLog("[성능] %@", l)
            }
            let db = Database.shared
            lines.append("기사 \(db.itemCount)건 · 최근 7일 스토리 \(db.recentClusters(since: Date().addingTimeInterval(-7 * 86400)).count)개")
            for i in 1...3 { log("오늘 호 그리기 #\(i)", await MainStallMonitor.measure { _ = await PerfProbe.today() }) }
            log("이번 주 호 그리기", await MainStallMonitor.measure { _ = await PerfProbe.week() })
            // 새 기사 30건이 들어온 것처럼(최근 기사 30건을 id 만 바꿔) 매거진에 넣기
            let sample = db.items(from: Date().addingTimeInterval(-2 * 86400), limit: 30).map { s -> NewsItem in
                var it = s.item; it.id += "-perf\(Int(Date().timeIntervalSince1970))"; return it
            }
            log("새 기사 \(sample.count)건 넣기", await MainStallMonitor.measure { await PerfProbe.ingest(sample) })
            log("지난 호 발행", await MainStallMonitor.measure { await PerfProbe.publish() })
            log("같은 소식 묶기 \(sample.count)건", await MainStallMonitor.measure { _ = await PerfProbe.group(sample) })
            log("검색 '정부'", await MainStallMonitor.measure { _ = await PerfProbe.search("정부") })
            let before = AppModel.shared.state.recent.count
            log("확인 한 번", await MainStallMonitor.measure { await AppModel.shared.checkAll() }, "목록 +\(AppModel.shared.state.recent.count - before)")
            try? lines.joined(separator: "\n").write(toFile: "\(dir)/perf.txt", atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
}

// 잴 일들. 구조를 바꿔도 이 이름으로 부르면 전후를 같은 방법으로 잰다.
@MainActor
enum PerfProbe {
    static func today() async -> Int { await Magazine.shared.today().sections.count }
    static func week() async -> Int { await Magazine.shared.week().sections.count }
    static func ingest(_ items: [NewsItem]) async { await Magazine.shared.ingest(items) }
    static func publish() async { await Magazine.shared.publishDue() }
    static func group(_ items: [NewsItem]) async -> Int { await AppModel.shared.groupForProbe(items).count }
    static func search(_ q: String) async -> Int { await Magazine.shared.search(q).count }
}
