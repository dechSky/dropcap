import Foundation
import Testing
@testable import Dropcap

// mac-crash-fix: 10-14 13:46 충돌 — 1분 타이머 안의 MainActor.assumeIsolated 단언이 실패해 앱이 끝났다.
// 타이머 처리는 어느 스레드에서 불려도 끝나지 않고, 일은 메인 액터에서 해야 한다.
@Suite struct CrashFixTests {
    @Test func minuteTimerSurvivesOffMainCall() async {
        let ranOnMain = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async { // 메인 밖에서 타이머가 불린 꼴
                AppModel.minuteTimerFired { c.resume(returning: Thread.isMainThread) }
            }
        }
        #expect(ranOnMain)
    }
}
