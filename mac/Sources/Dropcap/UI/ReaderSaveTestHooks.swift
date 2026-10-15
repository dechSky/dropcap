import AppKit
import SwiftUI

// 시험 장치(M9): 디버그 빌드(swift build·swift test·e2e·clicksweep)에만 들어간다. 배포 빌드(build.sh, -c release)에는 없음.
#if DEBUG

// 시험용 환경 변수(화면 캡처 권한 없이 앱 안에서 찍기). 실제 기록을 건드리지 않게 DROPCAP_DATA_DIR 와 함께 쓴다.
//  DROPCAP_TEST_LOOK=sepia,serif,loose,wide,19   읽기 창 모양(바탕,글꼴,줄 간격,폭,크기)을 미리 정함
//  DROPCAP_TEST_FIND=<낱말>                       읽기 창을 찾기 막대가 열린 채로(ReaderView 가 읽음)
//  DROPCAP_TEST_PANELS=1 + DROPCAP_TEST_SHOT_DIR   모양 팝오버·주소 칸·설정 스크랩북 탭을 밝게/어둡게 찍음
//  DROPCAP_TEST_SAVEURL=<주소>                     주소로 저장해 보고 결과를 기록
//  DROPCAP_TEST_SCHEME=<dropcap://save?url=…>     주소 스킴 처리
//  DROPCAP_TEST_EXPORT_DIR=<폴더>                 스크랩 노트 폴더 자동 저장을 그 폴더로 켬
@MainActor
enum ReaderSaveTestHooks {
    static func run(_ env: [String: String]) {
        if let look = env["DROPCAP_TEST_LOOK"] {
            let p = look.split(separator: ",").map(String.init)
            let d = UserDefaults.standard
            if p.count > 0 { d.set(p[0], forKey: ReaderLook.themeKey) }
            if p.count > 1 { d.set(p[1], forKey: ReaderLook.fontKey) }
            if p.count > 2 { d.set(p[2], forKey: ReaderLook.spacingKey) }
            if p.count > 3 { d.set(p[3], forKey: ReaderLook.widthKey) }
            if p.count > 4, let v = Double(p[4]) { d.set(v, forKey: ReaderLook.fontSizeKey) }
        }
        if let dir = env["DROPCAP_TEST_EXPORT_DIR"] {
            ScrapExport.shared.setFolder(URL(fileURLWithPath: dir, isDirectory: true))
        }
        if let u = env["DROPCAP_TEST_SAVEURL"] {
            Task {
                let r = await SaveLink.save(u)
                switch r {
                case .success(let it): NSLog("[주소 저장 시험] 저장: %@ · %@ · 사진 %@", it.sourceName, it.displayTitle, it.image ?? "없음")
                case .failure(let f): NSLog("[주소 저장 시험] 실패: %@", f.message)
                }
            }
        }
        if let s = env["DROPCAP_TEST_SCHEME"], let u = URL(string: s) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { SaveLink.handle([u]) }
        }
        if env["DROPCAP_TEST_PANELS"] != nil, let dir = env["DROPCAP_TEST_SHOT_DIR"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                for dark in [false, true] {
                    let tag = dark ? "dark" : "light"
                    shoot(AnyView(ReaderLookPanel()), size: NSSize(width: 300, height: 380), dark: dark, to: "\(dir)/look-panel-\(tag).png")
                    shoot(AnyView(AddURLBar().padding(14)), size: NSSize(width: 380, height: 70), dark: dark, to: "\(dir)/addurl-\(tag).png")
                    shoot(AnyView(ScrapbookSettingsView()), size: NSSize(width: 600, height: 520), dark: dark, to: "\(dir)/settings-scrapbook-\(tag).png")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { // 견본 스크랩(DROPCAP_TEST_SCRAP, 25초) 뒤
                for dark in [false, true] {
                    shoot(AnyView(ScrollView { WeeklyQuotes().padding(20) }), size: NSSize(width: 640, height: 560), dark: dark, to: "\(dir)/weekly-\(dark ? "dark" : "light").png")
                }
            }
        }
    }

    private static var keep: [NSWindow] = []

    // 보이는 창에 띄운 뒤 그 창 그대로 찍는다(AppKit 으로 그리는 Form·Picker 도 나오게)
    static func shoot(_ view: AnyView, size: NSSize, dark: Bool, to path: String) {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "test-shot"
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.contentViewController = NSHostingController(rootView: view.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
        w.setContentSize(size)
        w.orderFrontRegardless()
        keep.append(w)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            w.orderOut(nil)
        }
    }
}

#endif
