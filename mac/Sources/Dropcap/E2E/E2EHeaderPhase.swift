import AppKit

// 시험 장치: 디버그 빌드(swift build·swift test·e2e·clicksweep)에만 들어간다. 배포 빌드(build.sh, -c release)에는 없음.
#if DEBUG

// 창 머리 겹침 확인(DROPCAP_TEST_E2E_PHASE=header): 분야 고르기·매거진 창을 조용한 모드로 띄워
// 맨 위와 스크롤한 뒤를 밝게·어둡게 찍는다. 제목줄까지 들어가게 창 틀(테마 프레임)을 통째로 그린다.
// 결과: shots/header-<창>-<지면>-<밝기>-<위|스크롤>.png
@MainActor
enum E2EHeaderPhase {
    static func run(_ r: E2ERun) async {
        let m = AppModel.shared
        let onboard: () -> NSWindow? = { NSApp.windows.first { $0.isVisible && $0.title == "관심 분야 고르기" } }
        await r.until(15) { onboard() != nil }
        await r.until(30) { SectionPhotos.shared.images.count >= 10 }
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            if onboard() == nil { OnboardingController.open() }
            await r.sleep(1.5)
            if let w = onboard() { await pair(r, w, "onboard", dark) }
        }
        OnboardingController.close()

        m.chooseSections(["top", "economy", "world", "ai"])
        await r.until(60) { !Magazine.shared.preparing && Database.shared.itemCount > 0 }
        await r.check()
        await Magazine.shared.publishDue()
        let mag: () -> NSWindow? = { NSApp.windows.first { $0.isVisible && $0.title == "Dropcap" } }
        MagazineController.open()
        await r.sleep(5)
        mag()?.setContentSize(NSSize(width: 1180, height: 820))
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for (name, page) in [("today", MagazineView.Page.today), ("economy", .section("economy")), ("stories", .stories)] {
                MagazineController.open(page: page)
                await r.sleep(2.5)
                if let w = mag() { await pair(r, w, "mag-" + name, dark) }
            }
        }
        NSApp.appearance = nil
        r.note("[머리] 스냅샷을 shots/header-* 로 남김")
    }

    // 맨 위 한 장, 내용이 머리 밑으로 들어가게 내린 뒤 한 장
    private static func pair(_ r: E2ERun, _ w: NSWindow, _ name: String, _ dark: Bool) async {
        let tone = dark ? "dark" : "light"
        scroll(w, to: 0); await r.sleep(0.6)
        shot(r, w, "\(name)-\(tone)-top")
        scroll(w, to: 260); await r.sleep(0.6)
        shot(r, w, "\(name)-\(tone)-scrolled")
        scroll(w, to: 0)
    }

    // 가장 긴 스크롤 영역을 위에서 y 만큼 내린다
    static func scroll(_ w: NSWindow, to y: CGFloat) {
        func all(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? [] + v.subviews.flatMap(all) }
        guard let cv = w.contentView, let sv = all(cv).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }),
              let doc = sv.documentView else { return }
        let top = doc.isFlipped ? -sv.contentInsets.top : max(0, doc.frame.height - sv.contentView.bounds.height)
        sv.contentView.scroll(to: NSPoint(x: 0, y: doc.isFlipped ? top + y : top - y))
        sv.reflectScrolledClipView(sv.contentView)
    }

    // 두 장: 창 틀째(제목줄 포함 — 화면 밖 그리기라 제목줄 재질은 불투명하게 나옴)와
    // 내용만(-content: 제목줄 밑으로 지나가는 내용이 그대로 보여 겹침을 확인할 수 있음)
    static func shot(_ r: E2ERun, _ w: NSWindow, _ name: String) {
        for (v, suffix) in [(w.contentView?.superview, ""), (w.contentView, "-content")] {
            guard let v, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: r.shotPath(name + suffix)))
        }
    }
}

#endif
