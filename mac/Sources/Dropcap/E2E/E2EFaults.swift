import AppKit
import Foundation
import SQLite3

// 시험 장치: 디버그 빌드(swift build·swift test·e2e·clicksweep)에만 들어간다. 배포 빌드(build.sh, -c release)에는 없음.
#if DEBUG

// 실패 처리 시험(scripts/e2e/faults.sh). DROPCAP_TEST_E2E_PHASE=faults 일 때만.
// 시나리오 12단계(다시 시작·깨진 상태 파일·깨진 DB) 밖의 고장에서 앱이 죽거나 멈추지 않고 회복하는지 본다:
// 출처 일부 고장(5xx·깨진 피드·빈 응답·끊김·큰 피드·미래 날짜) · 전체 끊김 · 느린 출처 · DB 잠김 · 디스크 가득(작은 볼륨에서만)
// · 잠자기/깨어나기 · 시계 바뀜. 단계마다 확인에 걸린 시간과 메인 스레드 최장 지연을 함께 적는다.
@MainActor
enum E2EFaults {
    static func run(_ r: E2ERun) async {
        let m = r.model
        m.update { $0.intervalMinutes = 24 * 60; $0.digestEnabled = false; $0.sound = false }
        let dog = MainWatchdog()
        dog.start()
        m.chooseSections(Sections.all.map(\.id)) // 출처를 많이 켜서(고장 낼 출처와 멀쩡한 출처가 겹치지 않게)
        OnboardingController.close()
        await r.until(120) { !Magazine.shared.preparing && Database.shared.itemCount > 0 }
        r.setClock(r.at(10, 0), "실패 처리 시작")
        await r.check()
        let feeds = m.allSources.filter { m.state.enabled[$0.id] == true && $0.type != "sitemap" }
        let krAll = feeds.filter(\.isDomestic), intlAll = feeds.filter { !$0.isDomestic }
        let kr = (0..<12).map { krAll[$0 % krAll.count] }, intl = (0..<12).map { intlAll[$0 % intlAll.count] } // 출처가 적으면 돌려 씀
        let baseErrors = m.state.errors.count
        r.note("켜진 출처 \(feeds.count)곳(국내 \(krAll.count) · 해외 \(intlAll.count)) · 시작 때 오류 \(baseErrors)")
        var n = 0
        // 출처 하나에 글 하나(이야기마다 다른 낱말)
        func post(_ src: Source, _ tag: String) -> String {
            n += 1
            let id = "f\(n)-\(tag)"
            let title = src.isDomestic ? "\(tag) 고장 시험 \(n)번 소식 \(SoakWords.ko[n % SoakWords.ko.count]) \(SoakWords.ko[(n * 7) % SoakWords.ko.count])"
                : "Fault test \(tag) story \(n) \(SoakWords.en[n % SoakWords.en.count]) \(SoakWords.en[(n * 7) % SoakWords.en.count])"
            E2EFeeds.post(.init(sourceId: src.id, id: id, title: title, summary: "fault", date: Date().addingTimeInterval(-60), image: nil))
            return "\(src.id)|\(id)"
        }
        func known(_ key: String) -> Bool { m.state.seen[key] != nil }
        func inDB(_ key: String) -> Bool { !Database.shared.items(keys: [key]).isEmpty }
        // 확인 한 번(최대 limit 초) — 걸린 시간·끝났는지·메인 최장 지연
        func timedCheck(_ limit: Double = 120) async -> (sec: Double, done: Bool, lag: Int) {
            _ = dog.take()
            await r.until(60) { !m.checking }
            let t0 = ProcessInfo.processInfo.systemUptime
            var finished = false
            Task { await m.checkAll(); finished = true }
            let done = await r.until(limit) { finished } // 끝나지 않으면 기다리지 않고 다음으로(실패로 적힘)
            return (ProcessInfo.processInfo.systemUptime - t0, done, Int(dog.take().max))
        }
        func fmt(_ c: (sec: Double, done: Bool, lag: Int)) -> String { String(format: "확인 %.1f초%@ · 메인 최장 %dms", c.sec, c.done ? "" : "(끝나지 않음)", c.lag) }

        // F1) 출처 일부 고장
        let broken: [(Source, E2EFeeds.Fault, String)] = [
            (kr[0], .http(503), "503"), (kr[1], .garbage, "깨진 피드"), (intl[0], .empty, "빈 응답"),
            (intl[1], .offline, "끊김"), (kr[2], .huge, "큰 피드"), (intl[2], .futureDates, "미래 날짜"),
        ]
        let healthy = [kr[3], intl[3]]
        for (s, f, _) in broken { E2EFeeds.setFault(s.id, f) }
        let bKeys = broken.map { post($0.0, "F1") }
        let hKeys = healthy.map { post($0, "F1") }
        let c1 = await timedCheck()
        let errs = broken.prefix(4).map { m.state.errors[$0.0.id] != nil }
        let arrived = [bKeys[4], bKeys[5]] + hKeys
        r.record("F1", "출처 일부 고장(503·깨진 피드·빈 응답·끊김·큰 피드·미래 날짜)",
                 expected: "확인이 끝남 · 고장 난 4곳은 오류로 적힘 · 큰 피드·미래 날짜·멀쩡한 출처의 새 글은 들어옴 · 메인 1초 넘게 멈추지 않음",
                 actual: "\(fmt(c1)) · 오류 \(zip(broken.prefix(4), errs).map { "\($0.0.2)=\($0.1)" }) · 들어옴 \(arrived.map(known)) · 미래 날짜 글 날짜 \(m.state.recent.first { $0.key == bKeys[5] }?.date.map { Int($0.timeIntervalSinceNow) } ?? -1)초",
                 pass: c1.done && errs.allSatisfy { $0 } && arrived.allSatisfy(known) && c1.lag < 1000)
        E2EFeeds.clearFaults()
        let c1b = await timedCheck()
        let recovered = bKeys.prefix(4).map(known)
        r.record("F1-회복", "고장이 풀리면 밀린 글이 들어오고 오류가 지워짐",
                 expected: "고장 났던 4곳의 글이 들어옴 · 오류 비움",
                 actual: "\(fmt(c1b)) · 들어옴 \(recovered) · 남은 오류 \(broken.prefix(4).filter { m.state.errors[$0.0.id] != nil }.count)",
                 pass: recovered.allSatisfy { $0 } && broken.prefix(4).allSatisfy { m.state.errors[$0.0.id] == nil })

        // F2) 전체 끊김 → 회복
        E2EFeeds.setFault("*", .offline)
        let offKeys = [post(kr[4], "F2"), post(intl[4], "F2")]
        let recent0 = m.state.recent.count
        let c2 = await timedCheck()
        r.record("F2", "네트워크 전체 끊김",
                 expected: "확인이 빨리 끝남 · 모든 출처 오류 · 목록 그대로 · 죽지 않음",
                 actual: "\(fmt(c2)) · 오류 \(m.state.errors.count)/\(m.allSources.filter { m.state.enabled[$0.id] == true }.count) · 목록 \(recent0)→\(m.state.recent.count)",
                 pass: c2.done && c2.sec < 30 && m.state.recent.count == recent0 && m.state.errors.count >= feeds.count)
        E2EFeeds.clearFaults()
        let c2b = await timedCheck()
        r.record("F2-회복", "다시 이어지면 밀린 글이 들어옴",
                 expected: "끊긴 동안 올라온 글 2건이 들어옴 · 오류 비움",
                 actual: "\(fmt(c2b)) · 들어옴 \(offKeys.map(known)) · 남은 오류 \(m.state.errors.count)(시작 때 \(baseErrors))",
                 pass: offKeys.allSatisfy(known) && m.state.errors.count <= baseErrors)

        // F3) 느린 출처(25초) — 확인 전체가 그만큼 늦지만 끝나고, 화면은 멈추지 않음
        E2EFeeds.setFault(intl[5].id, .slow(25))
        let slowKeys = [post(intl[5], "F3"), post(kr[5], "F3")]
        let c3 = await timedCheck()
        E2EFeeds.clearFaults()
        r.record("F3", "느린 출처 하나(25초)",
                 expected: "확인이 끝남(느린 만큼 늦음) · 두 글 모두 들어옴 · 메인 멈춤 없음",
                 actual: "\(fmt(c3)) · 들어옴 \(slowKeys.map(known))",
                 pass: c3.done && slowKeys.allSatisfy(known) && c3.lag < 1000)

        // F4) DB 잠김(다른 연결이 쓰기 잠금) — 그동안 들어온 글이 매거진에서 사라지지 않아야
        // 가: 1초(기다렸다가 넣음) · 나: 8초(기다림보다 김 → 다음 받아 넣기 때 다시 넣음)
        for (label, hold) in [("가", 1.0), ("나", 8.0)] {
            let lockKeys = [post(kr[6], "F4\(label)"), post(intl[6], "F4\(label)")]
            let locked = DBLocker(path: Database.shared.file.path).lock(seconds: hold)
            let c4 = await timedCheck()
            let during = lockKeys.map(inDB)
            await r.sleep(hold + 0.5)
            let next = [post(kr[7], "F4\(label)-뒤")]
            let c4b = await timedCheck()
            r.record("F4-\(label)", "매거진 DB 가 잠김(\(Int(hold))초)",
                     expected: "확인이 끝남 · 잠긴 동안 들어온 글도 (잠금이 풀린 뒤) 매거진 DB 에 들어감 · 메인 1초 넘게 멈추지 않음",
                     actual: "잠금 \(locked) · \(fmt(c4)) · 잠긴 동안 DB \(during) · 풀린 뒤 \(fmt(c4b)) · DB \((lockKeys + next).map(inDB)) · 상태 \(lockKeys.map(known))",
                     pass: locked && c4.done && lockKeys.allSatisfy(known) && (lockKeys + next).allSatisfy(inDB) && c4.lag < 1000)
        }

        // F5) 디스크 가득(작은 볼륨에 데이터 폴더를 둔 실행에서만 — faults.sh)
        if ProcessInfo.processInfo.environment["DROPCAP_FAULTS_FULLDISK"] != nil {
            let filler = Store.dir.appendingPathComponent("filler.bin")
            let filled = fillDisk(filler)
            let fullKeys = [post(kr[7], "F5"), post(intl[7], "F5")]
            let c5 = await timedCheck()
            Store.flush()
            let stateOK = Store.read(Store.file, backup: Store.backupFile).state.sectionsChosen != nil
            try? FileManager.default.removeItem(at: filler)
            let c5b = await timedCheck()
            let later = [post(kr[8], "F5b"), post(intl[8], "F5b")]
            let c5c = await timedCheck()
            Store.flush()
            let saved = Store.read(Store.file, backup: Store.backupFile).state
            r.record("F5", "디스크 가득 → 비우면 회복",
                     expected: "가득 찬 동안 죽지 않고 확인이 끝남 · 상태 파일이 깨지지 않음 · 비운 뒤 가득일 때 온 글과 새 글이 DB 에, 새 글이 상태 파일에 들어감",
                     actual: "채움 \(filled / 1024)KB · \(fmt(c5)) · 상태 파일 읽힘 \(stateOK) · 비운 뒤 \(fmt(c5b)) / \(fmt(c5c)) · 가득일 때 글 상태 \(fullKeys.map(known)) DB(비운 뒤) \(fullKeys.map(inDB)) · 비운 뒤 글 DB \(later.map(inDB)) 저장 \(later.map { saved.seen[$0] != nil })",
                     pass: c5.done && stateOK && (fullKeys + later).allSatisfy(inDB) && later.allSatisfy { saved.seen[$0] != nil })
        }

        // F6) 잠자기 → 깨어나기: 잠들 때 바로 저장, 깨어나면 10초 뒤 확인
        let wakeKeys = [post(kr[9], "F6")]
        await r.sleep(1) // 앞서 묶인 저장을 끝내 두고
        let probe = NewsItem(id: "sleep-probe-\(n)", title: "x", titleKo: nil, link: "", date: nil, summary: "", sourceId: "x", sourceName: "x", tier: "kr")
        m.setRead(probe, true) // 저장할 것이 생기게(묶어 쓰기 0.5초 뒤에 써짐)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        await r.sleep(0.15) // 묶어 쓰기(0.5초)보다 먼저 써졌으면 잠들기 저장이 한 것(파일 시각은 1초 단위라 내용으로 본다)
        let flushed = Store.read(Store.file, backup: Store.backupFile).state.read[probe.key] != nil
        let check0 = m.state.lastCheck
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil) // 두 번 와도 확인은 겹치지 않음
        let woke = await r.until(40) { m.state.lastCheck != check0 && !m.checking }
        r.record("F6", "잠자기 → 깨어나기",
                 expected: "잠들 때 상태 파일을 바로 씀 · 깨어나고 10초쯤 뒤 확인이 돌아 새 글이 들어옴(두 번 알려도 한 번만)",
                 actual: "바로 씀 \(flushed) · 깨어난 뒤 확인 \(woke) · 새 글 \(wakeKeys.map(known))",
                 pass: flushed && woke && wakeKeys.allSatisfy(known))

        // F7) 시계 바뀜: 이틀 뒤로 → 열흘 앞으로 → 제자리. 잠시 끄기는 시계가 앞으로 가 있던 때 켠 것이 제자리에서 열흘씩 남지 않아야
        let base = Date()
        var clockOK: [String] = []
        for (label, shift) in [("이틀 전", -2.0), ("열흘 뒤", 10.0), ("제자리", 0.0)] {
            r.setClock(base.addingTimeInterval(shift * 24 * 3600), "시계 바뀜 \(label)")
            if label == "열흘 뒤" { m.snooze(Date().addingTimeInterval(3600)) } // 1시간 잠시 끄기
            let k = [post(kr[10], "F7"), post(intl[10], "F7")]
            let c = await timedCheck()
            AppModel.minuteTimerFired()
            await r.sleep(0.5)
            clockOK.append("\(label): \(fmt(c)) 들어옴 \(k.map(known))")
            if !(c.done && k.allSatisfy(known)) { clockOK.append("✗") }
        }
        let snoozedLong = m.isSnoozed
        r.record("F7", "시계 바뀜(이틀 전 → 열흘 뒤 → 제자리)",
                 expected: "시계를 옮길 때마다 확인이 끝나고 새 글이 들어옴 · 열흘 뒤에 켠 1시간 잠시 끄기가 제자리에서는 풀림",
                 actual: clockOK.joined(separator: " / ") + " · 제자리에서 잠시 끔 \(snoozedLong)",
                 pass: !clockOK.contains("✗") && !snoozedLong)
        m.snooze(nil)

        dog.stop()
        r.note("실패 처리 끝")
    }

    // 디스크를 가득 채운다(쓰기가 실패할 때까지). 쓴 바이트 수
    static func fillDisk(_ file: URL) -> Int {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: file) else { return 0 }
        defer { try? h.close() }
        let chunk = Data(count: 1 << 20)
        var total = 0
        while (try? h.write(contentsOf: chunk)) != nil { total += chunk.count; if total > 4 << 30 { break } }
        let small = Data(count: 4096)
        while (try? h.write(contentsOf: small)) != nil { total += small.count; if total > 4 << 30 { break } }
        try? h.synchronize()
        return total
    }
}

// 다른 연결로 DB 쓰기 잠금을 잠깐 잡는다(다른 프로그램이 DB 를 쓰는 꼴)
final class DBLocker: @unchecked Sendable {
    let path: String
    init(path: String) { self.path = path }
    func lock(seconds: Double) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, sqlite3_exec(db, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK else { sqlite3_close(db); return false }
        let held = db
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            sqlite3_exec(held, "COMMIT", nil, nil, nil)
            sqlite3_close(held)
        }
        return true
    }
}

#endif
