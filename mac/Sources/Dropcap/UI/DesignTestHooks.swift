import AppKit
import SwiftUI

// 시험 장치(M9): 디버그 빌드에만 들어간다. 배포 빌드(build.sh, -c release)에는 없음.
#if DEBUG

// DROPCAP_TEST_WINDOW_MOTION=<폴더>: 창 열기 움직임을 재어 연속 장면으로 남긴다(docs/DESIGN.md '창 열기').
//  화면 밖 자리의 창으로 WindowMotion.present 를 실제로 돌리며 1/60초마다 창의 자리·크기·투명도를 읽고,
//  창 내용 한 장과 합쳐 window-open-<n>.png(같은 크기 바탕 위에 잰 값대로) · window-open.txt(잰 값)를 쓴다.
//  앱을 앞으로 띄우지 않고(활성화 없음) 사용자 화면에도 보이지 않는다.
@MainActor
enum DesignTestHooks {
    static func run(_ env: [String: String]) {
        guard let dir = env["DROPCAP_TEST_WINDOW_MOTION"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { capture(dir) }
    }

    private struct Sample { let t: Double; let frame: CGRect; let alpha: CGFloat }

    private static func capture(_ dir: String) {
        let host = NSHostingController(rootView: MotionSample())
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.setContentSize(NSSize(width: 480, height: 320))
        // 모든 화면 밖 왼쪽 아래(보이지 않음)
        let minX = NSScreen.screens.map(\.frame.minX).min() ?? 0
        w.setFrameOrigin(NSPoint(x: minX - 4000, y: -4000))
        let target = w.frame
        var samples: [Sample] = []
        let start = CACurrentMediaTime()
        WindowMotion.present(w)
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { t in
            MainActor.assumeIsolated {
                samples.append(Sample(t: CACurrentMediaTime() - start, frame: w.frame, alpha: w.alphaValue))
                if CACurrentMediaTime() - start > Motion.Duration.standard + 0.1 { t.invalidate(); finish(w, target, samples, dir) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private static func finish(_ w: NSWindow, _ target: CGRect, _ samples: [Sample], _ dir: String) {
        guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        let content = NSImage(size: v.bounds.size); content.addRepresentation(rep)
        var log = "t(초)\t크기 배율\t투명도\n"
        let picks = [0.0, 0.05, 0.1, 0.15, 0.2, 0.25, 0.3]
        for (i, want) in picks.enumerated() {
            guard let s = samples.min(by: { abs($0.t - want) < abs($1.t - want) }) else { continue }
            let k = s.frame.width / target.width
            let canvas = NSImage(size: NSSize(width: target.width * 1.1, height: target.height * 1.1))
            canvas.lockFocus()
            NSColor(white: 0.9, alpha: 1).setFill(); NSRect(origin: .zero, size: canvas.size).fill()
            let r = NSRect(x: (canvas.size.width - target.width * k) / 2, y: (canvas.size.height - target.height * k) / 2,
                           width: target.width * k, height: target.height * k)
            content.draw(in: r, from: .zero, operation: .sourceOver, fraction: s.alpha)
            let label = String(format: "%.2f초 · 배율 %.3f · 투명도 %.2f", s.t, k, s.alpha) as NSString
            label.draw(at: NSPoint(x: 10, y: 8), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
            canvas.unlockFocus()
            if let tiff = canvas.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "\(dir)/window-open-\(i).png"))
            }
        }
        for s in samples { log += String(format: "%.3f\t%.4f\t%.3f\n", s.t, s.frame.width / target.width, s.alpha) }
        try? log.write(toFile: "\(dir)/window-open.txt", atomically: true, encoding: .utf8)
        TestLog.write("[디자인 시험] 창 열기 \(samples.count)개 재어 \(dir) 에 남김")
        w.close()
        NSApp.terminate(nil)
    }
}

// 창 안에 보일 견본(토큰만 써서 그린 작은 지면)
private struct MotionSample: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("오늘의 지면").font(.dsTitle)
            Text("창 열기 움직임 견본 — 토큰으로 그린 화면").font(.dsCallout).foregroundStyle(Palette.inkSecondary)
            HStack(spacing: Space.m) {
                ForEach(0..<3) { i in
                    VStack(alignment: .leading, spacing: Space.xs) {
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Palette.accent.opacity(0.15 + 0.15 * Double(i))).frame(height: 70)
                        Text("카드 제목 \(i + 1)").font(.dsSubheading)
                        Text("출처 · 3분").font(.dsCaption).foregroundStyle(Palette.inkSecondary)
                    }
                    .padding(Space.m)
                    .background(Palette.raised, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .elevation(Elevation.card)
                }
            }
        }
        .padding(Space.xl)
        .frame(width: 480, height: 320, alignment: .topLeading)
        .background(Palette.canvas)
    }
}

#endif
