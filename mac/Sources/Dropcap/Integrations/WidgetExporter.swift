import AppKit
import CryptoKit
import DropcapShared
import Foundation
import WidgetKit

// 위젯용 스냅숏을 쓴다: 확인이 끝날 때마다(안 읽은 수가 바뀔 때도) 표지·최신 몇 건·줄인 사진.
// 위치: Store.dir/Widget (실제 실행이면 ~/Library/Application Support/Dropcap/Widget — 위젯이 읽는 곳)
@MainActor
final class WidgetExporter {
    static let shared = WidgetExporter()
    static let enabledKey = "exportWidget"
    nonisolated static let latestCount = 5
    nonisolated static let imageWidth: CGFloat = 480

    var dir: URL { Store.dir.appendingPathComponent("Widget", isDirectory: true) }
    var enabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
    private var running: Task<Void, Never>?
    private var last: WidgetSnapshot?

    // 스냅숏 만들기(사진 파일 이름은 key 로 정해 매번 같다)
    nonisolated static func makeSnapshot(cover: NewsItem?, recent: [NewsItem], unread: Int, now: Date = Date(),
                                         image: (NewsItem) -> String? = { _ in nil }) -> WidgetSnapshot {
        func entry(_ it: NewsItem) -> WidgetSnapshot.Entry {
            WidgetSnapshot.Entry(key: it.key, title: it.displayTitle, source: it.sourceName, date: it.date,
                                 image: image(it) == nil ? nil : imageFileName(it.key))
        }
        let c = cover ?? recent.first
        var seen = Set([c?.key].compactMap { $0 })
        let latest = recent.filter { seen.insert($0.key).inserted }.prefix(latestCount).map(entry)
        return WidgetSnapshot(updated: now, unread: max(0, unread), cover: c.map(entry), latest: Array(latest))
    }

    nonisolated static func imageFileName(_ key: String) -> String {
        "img-" + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16) + ".jpg"
    }

    private static func imageURL(_ it: NewsItem) -> String? {
        [it.image, Magazine.shared.storedImage(it.key)].compactMap { $0 }.first { !ImageKey.isJunk($0) }
    }

    func scheduleExport() {
        guard enabled else { return }
        running?.cancel()
        running = Task {
            try? await Task.sleep(for: .seconds(2)) // 잇따른 변경은 한 번으로
            guard !Task.isCancelled else { return }
            await export()
        }
    }

    func export() async {
        guard enabled else { return }
        let state = AppModel.shared.state
        let today = await Magazine.shared.today()
        let cover = today.cover?.item
        // 알림 목록이 짧으면(처음 실행 등) 오늘 매거진 기사로 채운다
        var recent = Array(state.recent.prefix(Self.latestCount + 1))
        if recent.count <= Self.latestCount {
            recent += today.sections.flatMap(\.items).sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        }
        // 사진 주소는 실릴 만한 앞쪽 몇 건만 찾는다(DB 를 300번 읽지 않게)
        let pool = [cover].compactMap { $0 } + recent.prefix(Self.latestCount + 1)
        let urls = Dictionary(pool.compactMap { it in Self.imageURL(it).map { (it.key, $0) } }, uniquingKeysWith: { a, _ in a })
        let snap = Self.makeSnapshot(cover: cover, recent: recent, unread: state.unread, image: { urls[$0.key] })
        if let last, last.cover?.key == snap.cover?.key, last.latest.map(\.key) == snap.latest.map(\.key),
           last.latest.map(\.title) == snap.latest.map(\.title), last.unread == snap.unread { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // 사진: 있으면 그대로, 없으면 받아서 줄여 둔다. 받지 못한 사진은 빼고 쓴다.
        var final = snap
        func withImage(_ e: WidgetSnapshot.Entry) async -> WidgetSnapshot.Entry {
            guard let name = e.image, let u = urls[e.key] else { var e = e; e.image = nil; return e }
            let file = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: file.path) { return e }
            guard let img = await ImageLoader.shared.image(u), let jpg = Self.shrink(img) else { var e = e; e.image = nil; return e }
            try? jpg.write(to: file, options: .atomic)
            return e
        }
        if let c = final.cover { final.cover = await withImage(c) }
        var latest: [WidgetSnapshot.Entry] = []
        for e in final.latest { latest.append(await withImage(e)) }
        final.latest = latest
        guard enabled, let data = final.encoded() else { return } // 받는 동안 꺼졌으면 쓰지 않는다
        try? data.write(to: dir.appendingPathComponent(WidgetSnapshot.fileName), options: .atomic)

        // 더는 쓰지 않는 사진 정리
        let keep = Set(([final.cover].compactMap { $0 } + final.latest).compactMap(\.image))
        for f in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasPrefix("img-") && !keep.contains(f) {
            try? fm.removeItem(at: dir.appendingPathComponent(f))
        }
        last = final
        WidgetCenter.shared.reloadAllTimelines()
    }

    // 끄기: 사본을 지우고 위젯을 빈 상태로
    func clear() {
        running?.cancel()
        last = nil
        try? FileManager.default.removeItem(at: dir)
        WidgetCenter.shared.reloadAllTimelines()
    }

    nonisolated static func shrink(_ img: NSImage, width: CGFloat = imageWidth) -> Data? {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = min(width, CGFloat(cg.width))
        let h = (CGFloat(cg.height) * w / CGFloat(max(cg.width, 1))).rounded()
        guard w >= 1, h >= 1, let ctx = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
                                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: 0.78])
    }
}
