import AppKit
import CryptoKit
import ImageIO
import SwiftUI

// 피드에서 온 사진 주소는 믿지 않으므로 AsyncImage 대신 이것을 쓴다:
// 공개 주소만(FeedService 의 안전 검사), 8MB 까지, 줄여서(최대 1400px) 메모리·디스크에 담아 둔다.
actor ImageLoader {
    static let shared = ImageLoader()
    private let memory = NSCache<NSString, NSImage>()
    private var inflight: [String: Task<NSImage?, Never>] = [:]
    private let dir: URL = {
        let d = Store.dir.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    init() { memory.countLimit = 160 }

    func image(_ url: String) async -> NSImage? {
        if let m = memory.object(forKey: url as NSString) { return m }
        if let t = inflight[url] { return await t.value }
        let t = Task { await load(url) }
        inflight[url] = t
        let img = await t.value
        inflight[url] = nil
        if let img { memory.setObject(img, forKey: url as NSString) }
        return img
    }

    private func file(_ url: String) -> URL {
        let h = SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
        return dir.appendingPathComponent("\(h).jpg")
    }

    private func load(_ url: String) async -> NSImage? {
        let f = file(url)
        if let data = try? Data(contentsOf: f), let img = NSImage(data: data) { return img }
        guard let data = try? await FeedService.shared.fetch(url), data.count < 8 << 20,
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1400,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        if let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) {
            try? jpg.write(to: f, options: .atomic)
            prune()
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private var writes = 0
    private func prune() {
        writes += 1
        guard writes % 20 == 0 else { return }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]), files.count > 600 else { return }
        let sorted = files.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        sorted.prefix(files.count - 500).forEach { try? fm.removeItem(at: $0) }
    }
}

// 사진 칸: 불러오는 동안·사진이 없을 때는 분야 색의 은은한 그라데이션과 기호
struct RemoteImage: View {
    let url: String?
    var category: NewsCategory = .other
    var accent: Color = .accentColor
    @State private var image: NSImage?
    @State private var shown = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [accent.opacity(0.35), category.color.opacity(0.25), accent.opacity(0.12)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(Image(systemName: category.symbol).font(.app(28, .light)).foregroundStyle(.white.opacity(0.55)))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .opacity(shown ? 1 : 0)
                    .scaleEffect(shown ? 1 : 1.04)
            }
        }
        .clipped()
        .task(id: url) {
            // 주소가 바뀌면(같은 칸에 다른 기사) 이전 사진을 비우고 새로 받는다
            image = nil
            shown = false
            guard let url else { return }
            if let img = await ImageLoader.shared.image(url), !Task.isCancelled {
                image = img
                withAnimation(.easeOut(duration: 0.5)) { shown = true }
            }
        }
    }
}
