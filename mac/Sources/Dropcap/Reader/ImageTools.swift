import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Vision

// 기사 속 사진 다루기: 사진 속 글자 번역 · 복사 · 저장.
// 사진에 마우스를 올리면 오른쪽 위에 작은 단추가 뜨고, 오른쪽 클릭 메뉴에도 같은 기능이 있다.
struct ImageActions: ViewModifier {
    let image: NSImage?
    let url: String
    var title: String = ""
    @State private var hover = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if let image, hover {
                    HStack(spacing: Space.xs) {
                        tool("character.bubble", "사진 속 글자 번역") { ImageTranslateWindow.open(image, url: url, title: title) }
                        tool("doc.on.doc", "사진 복사") { ImageTools.copy(image) }
                        tool("square.and.arrow.down", "사진 저장…") { ImageTools.save(image, url: url) }
                    }
                    .padding(Space.s)
                    .transition(Motion.fade)
                }
            }
            .onHover { h in withMotion(Motion.snap) { hover = h } }
            .contextMenu {
                if let image {
                    Button("사진 속 글자 번역") { ImageTranslateWindow.open(image, url: url, title: title) }
                    Divider()
                    Button("사진 복사") { ImageTools.copy(image) }
                    Button("사진 저장…") { ImageTools.save(image, url: url) }
                }
                Button("사진 주소 복사") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                }
            }
    }

    private func tool(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.dsBodyStrong)
                .frame(width: 28, height: 26)
                .chromeGlass(in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

extension View {
    func imageActions(_ image: NSImage?, url: String, title: String = "") -> some View {
        modifier(ImageActions(image: image, url: url, title: title))
    }
}

@MainActor
enum ImageTools {
    static func copy(_ image: NSImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    static func save(_ image: NSImage, url: String) {
        let panel = NSSavePanel()
        var name = URL(string: url)?.deletingPathExtension().lastPathComponent ?? "image"
        if name.isEmpty || name.count > 80 { name = "image" }
        panel.nameFieldStringValue = name + ".png"
        panel.allowedContentTypes = [.png, .jpeg]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url,
              let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
        let jpeg = ["jpg", "jpeg"].contains(dest.pathExtension.lowercased())
        let data = rep.representation(using: jpeg ? .jpeg : .png, properties: jpeg ? [.compressionFactor: 0.92] : [:])
        try? data?.write(to: dest)
    }

    // 사진 속 글자 줄(정규화 좌표: 왼쪽 위 원점 0~1)
    struct Line: Identifiable {
        let id = UUID()
        let text: String
        let box: CGRect
        var translated: String?
        var background: NSColor = .white
    }

    // 기기 안에서 글자 읽기(Vision). 영어·일본어·중국어·한국어 등
    nonisolated static func recognize(_ image: NSImage) async -> [Line] {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        return await withCheckedContinuation { cont in
            // Vision 은 실패할 때 완료 처리기와 throw 를 둘 다 낼 수 있다 — 한 번만 돌려준다(두 번이면 앱이 멈춤)
            let once = ResumeOnce(cont)
            let req = VNRecognizeTextRequest { req, _ in
                let obs = (req.results as? [VNRecognizedTextObservation]) ?? []
                let lines = obs.compactMap { o -> Line? in
                    guard let t = o.topCandidates(1).first, t.confidence > 0.3 else { return nil }
                    let b = o.boundingBox // 왼쪽 아래 원점
                    let box = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
                    return Line(text: t.string, box: box, background: averageColor(cg, box))
                }
                once.resume(lines)
            }
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            req.automaticallyDetectsLanguage = true
            let handler = VNImageRequestHandler(cgImage: cg)
            DispatchQueue.global(qos: .userInitiated).async {
                do { try handler.perform([req]) } catch { once.resume([]) }
            }
        }
    }

    // 글자 상자 바로 바깥(위·아래 띠)의 평균 색 = 글자 뒤 바탕색(글자 자체 색이 섞이지 않게)
    nonisolated static func averageColor(_ cg: CGImage, _ box: CGRect) -> NSColor {
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        let x = box.minX * W, w = max(1, box.width * W), band = max(2, box.height * H * 0.18)
        let strips = [CGRect(x: x, y: box.minY * H - band - 1, width: w, height: band),
                      CGRect(x: x, y: box.maxY * H + 1, width: w, height: band)]
            .map { $0.intersection(CGRect(x: 0, y: 0, width: W, height: H)).integral }
            .filter { !$0.isNull && $0.width >= 1 && $0.height >= 1 }
        var sum = [CGFloat](repeating: 0, count: 3), n: CGFloat = 0
        for r in strips {
            guard let crop = cg.cropping(to: r) else { continue }
            var px = [UInt8](repeating: 0, count: 4)
            guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.interpolationQuality = .medium
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            for k in 0..<3 { sum[k] += CGFloat(px[k]) / 255 }
            n += 1
        }
        guard n > 0 else { return .white }
        return NSColor(red: sum[0] / n, green: sum[1] / n, blue: sum[2] / n, alpha: 1)
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<[ImageTools.Line], Never>?
    init(_ c: CheckedContinuation<[ImageTools.Line], Never>) { cont = c }
    func resume(_ v: [ImageTools.Line]) {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        c?.resume(returning: v)
    }
}

// MARK: 사진 번역 창
@MainActor
final class ImageTranslateModel: ObservableObject {
    let image: NSImage
    let url: String
    @Published var lines: [ImageTools.Line] = []
    @Published var stage: Stage = .reading
    @Published var showTranslation = true
    enum Stage { case reading, translating, done, noText, alreadyKorean }

    init(image: NSImage, url: String) { self.image = image; self.url = url }

    func run() async {
        let found = await ImageTools.recognize(image)
        lines = found
        guard !found.isEmpty else { stage = .noText; return }
        let foreign = found.indices.filter { Translator.looksForeign(found[$0].text) }
        guard !foreign.isEmpty else { stage = .alreadyKorean; return }
        stage = .translating
        let out = await Translator.shared.translateMany(foreign.map { found[$0].text })
        for (k, i) in foreign.enumerated() where k < out.count { lines[i].translated = out[k] }
        stage = .done
    }
}

struct ImageTranslateView: View {
    @ObservedObject var model: ImageTranslateModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    picture
                    if !model.lines.isEmpty { list }
                }
                .padding(Space.xl)
            }
            Divider()
            bar
        }
        .frame(minWidth: 520, minHeight: 420)
        .task { await model.run() }
    }

    private var picture: some View {
        Image(nsImage: model.image).resizable().aspectRatio(contentMode: .fit)
            .overlay {
                GeometryReader { g in
                    if model.showTranslation {
                        ForEach(model.lines) { l in
                            if let t = l.translated { overlayText(t, l, g.size) }
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .frame(maxWidth: .infinity)
    }

    // 원래 글자 자리를 사진 색으로 덮고 그 위에 번역문(상자에 맞춰 글자 크기를 줄임)
    private func overlayText(_ t: String, _ l: ImageTools.Line, _ size: CGSize) -> some View {
        let rect = CGRect(x: l.box.minX * size.width, y: l.box.minY * size.height, width: l.box.width * size.width, height: l.box.height * size.height)
        let bg = l.background.usingColorSpace(.deviceRGB) ?? .white
        let lum = 0.299 * bg.redComponent + 0.587 * bg.greenComponent + 0.114 * bg.blueComponent
        return Text(t)
            .font(.app(max(9, rect.height * 0.78), .semibold))
            .minimumScaleFactor(0.3)
            .lineLimit(2)
            .foregroundStyle(lum > 0.55 ? Color.black : Color.white)
            .padding(.horizontal, Space.xxs)
            .frame(width: rect.width + 6, height: rect.height + 4, alignment: .leading)
            .background(Color(nsColor: bg), in: RoundedRectangle(cornerRadius: Radius.xs))
            .position(x: rect.midX + 1, y: rect.midY)
            .textSelection(.enabled)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("읽은 글자").font(.dsBodyStrong).foregroundStyle(.secondary)
            ForEach(model.lines) { l in
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(l.translated ?? l.text).font(.app(14))
                    if l.translated != nil { Text(l.text).font(.dsCallout).foregroundStyle(.secondary) }
                }
                .textSelection(.enabled)
            }
        }
    }

    private var bar: some View {
        HStack(spacing: Space.m) {
            switch model.stage {
            case .reading: ProgressView().controlSize(.small); Text("사진 속 글자를 읽는 중…")
            case .translating: ProgressView().controlSize(.small); Text("번역하는 중…")
            case .noText: Label("사진에서 글자를 찾지 못했습니다", systemImage: "text.magnifyingglass")
            case .alreadyKorean: Label("이미 한국어 글자입니다", systemImage: "checkmark.circle")
            case .done: Label("\(model.lines.filter { $0.translated != nil }.count)줄 번역", systemImage: "character.bubble")
            }
            Spacer()
            if model.stage == .done {
                Picker("", selection: $model.showTranslation) {
                    Text("번역").tag(true)
                    Text("원본").tag(false)
                }
                .pickerStyle(.segmented).frame(width: 130).labelsHidden()
                Button("번역문 복사") {
                    let text = model.lines.map { $0.translated ?? $0.text }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            Button("사진 복사") { ImageTools.copy(model.image) }
            Button("저장…") { ImageTools.save(model.image, url: model.url) }
        }
        .font(.dsCallout)
        .padding(.horizontal, Space.l).padding(.vertical, Space.m)
    }
}

@MainActor
enum ImageTranslateWindow {
    private static var windows: [NSWindow] = []

    static func open(_ image: NSImage, url: String, title: String) {
        let model = ImageTranslateModel(image: image, url: url)
        let w = NSWindow(contentViewController: NSHostingController(rootView: ImageTranslateView(model: model)))
        w.title = title.isEmpty ? "사진 번역" : "사진 번역 — \(title)"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        let s = image.size, maxW: CGFloat = 900, maxH: CGFloat = 640
        let k = min(1, maxW / max(1, s.width), maxH / max(1, s.height))
        w.setContentSize(NSSize(width: max(560, s.width * k + 40), height: min(860, s.height * k + 260)))
        w.isReleasedWhenClosed = false
        w.center()
        windows.append(w)
        // 닫으면 바로 놓아 사진째 메모리에 남지 않게(A-35)
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak w] _ in
            MainActor.assumeIsolated {
                windows.removeAll { $0 === w }
                if let token { NotificationCenter.default.removeObserver(token) }
                w?.contentViewController = nil
            }
        }
        WindowMotion.present(w)
        NSApp.activate(ignoringOtherApps: true)
    }
}
