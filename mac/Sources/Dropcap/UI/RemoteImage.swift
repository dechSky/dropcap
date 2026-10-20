import AppKit
import CryptoKit
import ImageIO
import SwiftUI

// 피드에서 온 사진 주소는 믿지 않으므로 AsyncImage 대신 이것을 쓴다:
// 공개 주소만(FeedService 의 안전 검사), 8MB 까지, 줄여서(최대 1400px) 메모리·디스크에 담아 둔다.
// 메모리에는 풀린 그림 크기로 64MB 까지만(오래된 것부터 버림) — 예전엔 장 수(160장)로만 묶어 큰 사진이면 수백 MB 를 붙들었다.
actor ImageLoader {
    static let shared = ImageLoader()
    static let memoryLimitBytes = 64 << 20
    private var memory = ImageMemoryCache(limitBytes: ImageLoader.memoryLimitBytes, limitCount: 160)
    private var inflight: [String: Task<NSImage?, Never>] = [:]
    private let dir: URL

    // dir 은 시험에서만 바꾼다
    init(dir: URL = Store.dir.appendingPathComponent("images", isDirectory: true)) {
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // 시험용: 메모리에 담아 둔 사진인가
    func inMemory(_ url: String) -> Bool { memory.contains(url) }
    var memoryBytes: Int { memory.bytes }

    func image(_ url: String) async -> NSImage? {
        if let m = memory.get(url) { return m }
        if let t = inflight[url] { return await t.value }
        let t = Task { await load(url) }
        inflight[url] = t
        let img = await t.value
        inflight[url] = nil
        if let img { memory.put(url, img) }
        return img
    }

    // 시험용: 디스크에 받아 둔 사진만 바로 읽기(내려받지 않음)
    nonisolated func cachedImage(_ url: String) -> NSImage? {
        (try? Data(contentsOf: file(url))).flatMap(NSImage.init(data:))
    }

    nonisolated func diskFile(_ url: String) -> URL { file(url) } // 시험용
    nonisolated private func file(_ url: String) -> URL {
        let h = SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
        return dir.appendingPathComponent("\(h).jpg")
    }

    private func load(_ url: String) async -> NSImage? {
        let f = file(url)
        if let data = try? Data(contentsOf: f), let img = NSImage(data: data) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: f.path) // 자주 보는 사진은 정리에서 늦게
            return img
        }
        guard let data = try? await FeedService.shared.fetch(url, limit: .image), // 8MB 를 넘으면 받다가 끊는다(S-12)
              let cg = Self.decode(data) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        if let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) {
            try? jpg.write(to: f, options: .atomic)
            prune()
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // 풀어도 되는 사진의 크기 상한: 받은 크기(8MB)는 작아도 풀면 수백 메가픽셀인 사진(압축 폭탄)이 있다.
    // 머리(가로·세로)만 읽어 보고 넘으면 풀지 않는다. 40메가픽셀 = 8000×5000 정도(보통 사진기 원본은 들어온다).
    static let maxPixels = 40_000_000

    static func pixelsAcceptable(_ src: CGImageSource) -> Bool {
        guard let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return false } // 크기를 모르면 풀지 않음
        return w <= 100_000 && h <= 100_000 && w * h <= maxPixels
    }

    // 받은 사진을 줄여서(최대 1400px) 푼다. 크기를 넘거나 모르면 nil.
    static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              pixelsAcceptable(src) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1400,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
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

// 풀린 그림 크기(바이트)로 묶은 최근 사용 순 기억. 넘치면 가장 오래 안 쓴 것부터 버린다.
struct ImageMemoryCache {
    let limitBytes: Int
    let limitCount: Int
    private var entries: [String: (image: NSImage, cost: Int, used: Int)] = [:]
    private var tick = 0
    private(set) var bytes = 0

    init(limitBytes: Int, limitCount: Int) { self.limitBytes = limitBytes; self.limitCount = limitCount }

    func contains(_ key: String) -> Bool { entries[key] != nil }

    mutating func get(_ key: String) -> NSImage? {
        guard let e = entries[key] else { return nil }
        tick += 1
        entries[key]?.used = tick
        return e.image
    }

    mutating func put(_ key: String, _ image: NSImage) {
        let cost = Self.cost(image)
        if let old = entries.removeValue(forKey: key) { bytes -= old.cost }
        guard cost <= limitBytes else { return } // 상한보다 큰 한 장은 담지 않는다
        tick += 1
        entries[key] = (image, cost, tick)
        bytes += cost
        while bytes > limitBytes || entries.count > limitCount, let oldest = entries.min(by: { $0.value.used < $1.value.used }) {
            entries.removeValue(forKey: oldest.key)
            bytes -= oldest.value.cost
        }
    }

    // 풀었을 때 크기: 가장 큰 표현의 화소 수 × 4
    static func cost(_ image: NSImage) -> Int {
        let px = image.representations.map { $0.pixelsWide * $0.pixelsHigh }.max() ?? 0
        return max(px > 0 ? px : Int(image.size.width * image.size.height), 1) * 4
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
                    .allowsHitTesting(false) // '채우기'로 넘친 부분이 이웃 카드·단추의 클릭을 가로채지 않게
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .task(id: url) {
            // 주소가 바뀌면(같은 칸에 다른 기사) 이전 사진을 비우고 새로 받는다
            image = nil
            shown = false
            guard let url else { return }
            if let img = await ImageLoader.shared.image(url), !Task.isCancelled {
                image = img
                withMotion(Motion.enter(Motion.Duration.slow)) { shown = true }
            }
        }
    }
}
