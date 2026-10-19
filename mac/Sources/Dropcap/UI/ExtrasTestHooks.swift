import AppKit
import SwiftUI

// 시험 장치(M9): 디버그 빌드(swift build·swift test·e2e·clicksweep)에만 들어간다. 배포 빌드(build.sh, -c release)에는 없음.
#if DEBUG

// 시험용 환경 변수(남은 개선 묶음). 실제 기록을 건드리지 않게 DROPCAP_DATA_DIR 와 함께 쓴다.
//  DROPCAP_TEST_EXTRAS=<폴더>        피드를 받은 뒤(DROPCAP_TEST_EXTRAS_WAIT 초, 기본 100) 아래를 찍는다
//    · 유료 기사 읽기 창(같은 스토리의 무료 보도 권하기) → paywall-reader.png
//    · 매거진 오늘 호(진행률) → today-progress.png, 대표 기사를 모두 읽음으로 → today-done.png
//    · 묶음 분야 저녁 정리 → brief.png (Apple Intelligence 가 없으면 '시험 견본' 문장으로 화면만 확인)
//    · 분야 대표 사진 점수: 분야마다 고른 사진과 뺀 사진을 photo-*.jpg 로 남기고 점수를 기록
//  DROPCAP_TEST_EXTRAS2=<폴더>       지켜볼 낱말 정리 물방울(watch.png)·설정 일반 탭(settings.png)·내보내기→가져오기 왕복(backup.json, 기록에 결과)
//  DROPCAP_TEST_ENABLE=<출처 id,…>   그 출처를 켜고 최근 글을 매거진에 바로 싣는다(유료 출처 확인용)
//  DROPCAP_TEST_PHOTO_FILES=<폴더>  폴더의 사진을 모두 재어 점수를 기록
//  DROPCAP_TEST_FOCUS=fullscreen|sharing|calendar|none  자동 조용히 감지 결과를 정해 둔다
@MainActor
enum ExtrasTestHooks {
    static func run(_ env: [String: String]) {
        if let d = env["DROPCAP_TEST_PHOTO_FILES"] { // 시험용: 폴더의 jpg·png 를 모두 재어 기록
            Task.detached {
                let files = ((try? FileManager.default.contentsOfDirectory(atPath: d)) ?? []).filter { $0.hasSuffix(".jpg") || $0.hasSuffix(".png") }.sorted()
                for f in files {
                    guard let img = NSImage(contentsOfFile: d + "/" + f), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                    let s = PhotoQuality.score(cg)
                    NSLog("[사진 재기] %@ %.2f(글자 %.2f·색 %.2f·단색 %.3f) %@", PhotoQuality.good(s.total) ? "ok" : "no", s.total, s.textRatio, s.colorVariety, s.flatness, f)
                }
                NSLog("[사진 재기] 끝")
            }
        }
        if let f = env["DROPCAP_TEST_FOCUS"] { FocusMonitor.shared.override = .some(FocusReason(rawValue: f)) }
        if let ids = env["DROPCAP_TEST_ENABLE"] {
            Task {
                try? await Task.sleep(for: .seconds(3))
                for id in ids.split(separator: ",").map(String.init) {
                    guard let src = AppModel.shared.allSources.first(where: { $0.id == id }) else { continue }
                    AppModel.shared.setEnabled(id, true)
                    if let items = try? await FeedService.shared.items(for: src, conditional: false) {
                        let recent = items.filter { ($0.date ?? .distantPast) > Date().addingTimeInterval(-3 * 24 * 3600) }
                        await Magazine.shared.ingest(Array(recent.prefix(25)).reversed())
                        NSLog("[시험] %@ %d건 실음", id, min(recent.count, 25))
                    }
                }
            }
        }
        if let dir = env["DROPCAP_TEST_EXTRAS2"] { extras2(dir, env) }
        guard let dir = env["DROPCAP_TEST_EXTRAS"] else { return }
        let wait = Double(env["DROPCAP_TEST_EXTRAS_WAIT"] ?? "100") ?? 100
        Task {
            try? await Task.sleep(for: .seconds(wait))
            await photos(dir)
            await paywallReader(dir)
            try? await Task.sleep(for: .seconds(10))
            await today(dir)
            await brief(dir)
            NSLog("[시험] 남은 개선 묶음 찍기 끝")
        }
    }

    // 2차: 지켜볼 낱말 정리 물방울 · 설정 '일반'(내 기록) · 내보내기→가져오기 왕복
    static func extras2(_ dir: String, _ env: [String: String]) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let samples = ["엔비디아, 새 AI 칩 공개", "엔비디아 시가총액 5조 달러 돌파", "엔비디아·삼성전자 HBM 공급 계약"].enumerated().map { i, t in
                NewsItem(id: AppModel.previewID, title: t, titleKo: nil, link: "", date: Date(), summary: "", sourceId: "s\(i)", sourceName: "견본", tier: "kr")
            }
            ToastCenter.shared.showWatch(word: "엔비디아", items: samples)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { ToastCenter.shared.snapshot(to: "\(dir)/watch.png") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { // 상단바 앱에서는 설정 창 동작이 열리지 않아, 같은 화면을 시험 창에 띄운다
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "settings-test"
            w.makeKeyAndOrderFront(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
            shot("settings-test", "\(dir)/settings.png")
            let out = URL(fileURLWithPath: "\(dir)/backup.json")
            BackupManager.shared.export(to: out)
            NSLog("[시험] %@", BackupManager.shared.lastMessage ?? "")
            BackupManager.shared.importFile(out)
            NSLog("[시험] %@", BackupManager.shared.lastMessage ?? "")
            NSLog("[시험] 2차 끝")
        }
    }

    static func shot(_ title: String, _ path: String) {
        guard let v = NSApp.windows.first(where: { $0.isVisible && $0.title == title })?.contentView,
              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { NSLog("[시험] 창 없음: %@", title); return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    // 유료 출처 기사 중 같은 스토리에 무료 보도가 있는 것을 읽기 창으로
    static func paywallReader(_ dir: String) async {
        let recent = Database.shared.items(from: Date().addingTimeInterval(-3 * 24 * 3600), limit: 3000).map(\.item)
        let walled = recent.filter { PaywallBook.shared.kind($0) != nil }
        NSLog("[시험] 유료 표시 기사 %d건 / %d건", walled.count, recent.count)
        let pick = walled.first { !PaywallBook.shared.alternatives($0).isEmpty && PaywallBook.shared.kind($0)?.blocks == true }
            ?? walled.first { !PaywallBook.shared.alternatives($0).isEmpty }
        guard let it = pick else { NSLog("[시험] 무료 보도가 있는 유료 기사를 찾지 못함"); return }
        NSLog("[시험] 유료 기사 %@ · 무료 보도 %@", it.sourceName, PaywallBook.shared.alternatives(it).map(\.sourceName).joined(separator: ","))
        ReaderController.open(it)
        try? await Task.sleep(for: .seconds(12))
        shot(it.sourceName, "\(dir)/paywall-reader.png")
        NSApp.windows.first { $0.title == it.sourceName }?.close()
    }

    static func today(_ dir: String) async {
        MagazineController.open()
        try? await Task.sleep(for: .seconds(6))
        shot("Dropcap", "\(dir)/today-progress.png")
        let r = await Magazine.shared.today()
        let keys = TodayIssue.keys(cover: r.cover?.item.key, sections: r.sections, chosen: AppModel.shared.chosenSections)
        let all = ([r.cover?.item].compactMap { $0 } + r.sections.flatMap(\.items))
        for k in keys { if let it = all.first(where: { $0.key == k }) { AppModel.shared.setRead(it, true) } }
        NSLog("[시험] 오늘 호 대표 기사 %d건 읽음 처리", keys.count)
        try? await Task.sleep(for: .seconds(3))
        shot("Dropcap", "\(dir)/today-done.png")
    }

    static func brief(_ dir: String) async {
        let r = await Magazine.shared.today()
        guard let page = r.sections.first(where: { $0.section.section != nil && $0.section.section != Sections.top && $0.items.count >= 3 }),
              let sec = page.section.section else { NSLog("[시험] 저녁 정리할 분야 없음"); return }
        let items = Array(page.items.prefix(6))
        AppModel.shared.makeBrief(sec, items: items)
        try? await Task.sleep(for: .seconds(25))
        if AppModel.shared.brief(sec) == nil { // 이 Mac 에 Apple Intelligence 가 없으면 화면 확인용 견본 문장
            NSLog("[시험] 기기 안 요약 없음 → 견본 문장으로 화면만 확인")
            AppModel.shared.testBrief(sec, items: items, lines: [
                .init(text: "(시험 견본) 첫 기사와 셋째 기사가 같은 흐름을 다룬다", refs: [0, 2]),
                .init(text: "(시험 견본) 둘째 기사의 발표가 오늘 이 분야의 큰 소식이다", refs: [1]),
                .init(text: "(시험 견본) 넷째 기사는 그 배경을 설명한다", refs: [3]),
            ])
        } else {
            NSLog("[시험] 기기 안 요약: %@", (AppModel.shared.brief(sec)?.lines ?? []).map(\.text).joined(separator: " / "))
        }
        NotificationCenter.default.post(name: .magazineGo, object: MagazineView.Page.section(sec))
        try? await Task.sleep(for: .seconds(4))
        shot("Dropcap", "\(dir)/brief.png")
    }

    // 분야마다 사진 후보 점수: 고른 것·뺀 것을 파일로
    static func photos(_ dir: String) async {
        await Magazine.shared.scoreImages()
        let r = await Magazine.shared.today()
        for page in r.sections where page.section.section != nil {
            let sec = page.section.section!
            let cands = page.items.filter { $0.image != nil && !ImageKey.isJunk($0.image) }.prefix(8)
            for (i, it) in cands.enumerated() {
                guard let img = await ImageLoader.shared.image(it.image!), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                let s = await PhotoQuality.scoreAsync(cg)
                Database.shared.saveImageScore(it.image!, s)
                let tag = PhotoQuality.good(s.total) ? "ok" : "no"
                NSLog("[사진 시험] %@ %d %@ %.2f(비율 %.2f·크기 %.2f·글자 %.2f·색 %.2f·단색 %.2f) %@", sec, i, tag, s.total, s.aspect, s.size, s.textRatio, s.colorVariety, s.flatness, it.displayTitle)
                if let jpg = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.6]) {
                    try? jpg.write(to: URL(fileURLWithPath: "\(dir)/photo-\(sec)-\(i)-\(tag)-\(String(format: "%.2f", s.total)).jpg"))
                }
            }
            if let best = await SectionPhoto.pick(Array(page.items)) { NSLog("[사진 시험] %@ 대표 사진: %@", sec, best.item.displayTitle) }
        }
    }
}

extension AppModel {
    // 시험용: 기기 안 요약이 없는 Mac 에서 저녁 정리 화면만 확인
    func testBrief(_ sec: String, items: [NewsItem], lines: [SectionBrief.Line]) {
        makeBrief(sec, items: items)
        setBriefLines(sec, lines)
    }
}

#endif
