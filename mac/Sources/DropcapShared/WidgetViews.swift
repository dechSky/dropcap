import AppKit
import SwiftUI
import WidgetKit

// 위젯 화면. 위젯 확장과 앱의 시험 훅(DROPCAP_TEST_WIDGET)이 같은 화면을 쓴다.
public struct WidgetContent {
    public var snapshot: WidgetSnapshot
    public var images: [String: NSImage]   // Entry.image 파일 이름 → 사진

    public init(snapshot: WidgetSnapshot, images: [String: NSImage] = [:]) {
        self.snapshot = snapshot; self.images = images
    }

    // 폴더에서 읽기(없거나 깨졌으면 빈 사본)
    public static func load(from dir: URL = WidgetSnapshot.defaultDirectory) -> WidgetContent {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(WidgetSnapshot.fileName)),
              let snap = WidgetSnapshot.decode(data) else { return WidgetContent(snapshot: .empty) }
        var images: [String: NSImage] = [:]
        for e in [snap.cover].compactMap({ $0 }) + snap.latest {
            guard let name = e.image, !name.contains("/"), images[name] == nil,
                  let img = NSImage(contentsOf: dir.appendingPathComponent(name)) else { continue }
            images[name] = img
        }
        return WidgetContent(snapshot: snap, images: images)
    }

    func image(_ e: WidgetSnapshot.Entry?) -> NSImage? { e?.image.flatMap { images[$0] } }
}

public enum WidgetTime {
    public static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let m = Int(now.timeIntervalSince(date) / 60)
        if m < 1 { return "방금" }
        if m < 60 { return "\(m)분 전" }
        if m < 60 * 24 { return "\(m / 60)시간 전" }
        return "\(m / 1440)일 전"
    }
}

// preview: 앱 안에서 그림 파일로 찍을 때(ImageRenderer 는 Link·위젯 배경을 그리지 못한다)
public struct DropcapSmallView: View {
    let content: WidgetContent
    let preview: Bool
    public init(_ content: WidgetContent, preview: Bool = false) { self.content = content; self.preview = preview }

    public var body: some View {
        let cover = content.snapshot.cover ?? content.snapshot.latest.first
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("오늘의 표지", systemImage: "newspaper.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10, weight: .semibold))
                Spacer()
                UnreadBadge(count: content.snapshot.unread)
            }
            .foregroundStyle(.white.opacity(0.9))
            Spacer(minLength: 0)
            if let cover {
                Text(cover.title)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(4)
                    .foregroundStyle(.white)
                Text(cover.source)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            } else {
                EmptyNote()
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
        .widgetBackground(preview: preview) { CoverBackground(image: content.image(cover)) }
        .widgetURL(cover?.openURL ?? WidgetLink.magazine)
    }
}

public struct DropcapMediumView: View {
    let content: WidgetContent
    let preview: Bool
    public init(_ content: WidgetContent, preview: Bool = false) { self.content = content; self.preview = preview }

    public var body: some View {
        let snap = content.snapshot
        let cover = snap.cover ?? snap.latest.first
        let rest = Array(snap.latest.filter { $0.key != cover?.key }.prefix(3))
        HStack(spacing: 12) {
            Tap(url: cover?.openURL ?? WidgetLink.magazine, preview: preview) {
                ZStack(alignment: .bottomLeading) {
                    CoverBackground(image: content.image(cover))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(cover?.title ?? "아직 소식이 없습니다")
                            .font(.system(size: 13, weight: .bold))
                            .lineLimit(4)
                        if let cover {
                            Text(cover.source).font(.system(size: 10, weight: .medium)).opacity(0.8).lineLimit(1)
                        }
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    .padding(10)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("최신 소식").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    UnreadBadge(count: snap.unread)
                }
                .padding(.bottom, 4)
                if rest.isEmpty {
                    Spacer()
                    EmptyNote().foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ForEach(Array(rest.enumerated()), id: \.element.key) { i, e in
                        if i > 0 { Divider().padding(.vertical, 3) }
                        Tap(url: e.openURL, preview: preview) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(2)
                                Text([e.source, WidgetTime.ago(e.date)].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .widgetBackground(preview: preview) { Rectangle().fill(.fill.tertiary) }
    }
}

// 위젯에서는 누르면 그 주소로, 미리 보기에서는 그냥 그린다
struct Tap<Label: View>: View {
    let url: URL
    let preview: Bool
    @ViewBuilder let label: () -> Label
    var body: some View {
        if preview { label() } else { Link(destination: url, label: label) }
    }
}

extension View {
    @ViewBuilder
    func widgetBackground<B: View>(preview: Bool, @ViewBuilder _ background: () -> B) -> some View {
        if preview {
            self.padding(16).background(background())
        } else {
            self.containerBackground(for: .widget, content: background)
        }
    }
}

struct UnreadBadge: View {
    let count: Int
    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor))
                .accessibilityLabel("안 읽은 소식 \(count)건")
        }
    }
}

struct EmptyNote: View {
    var body: some View {
        Text("Dropcap 을 켜 두면 소식이 여기에 나타납니다")
            .font(.system(size: 11))
            .lineLimit(3)
    }
}

struct CoverBackground: View {
    let image: NSImage?
    var body: some View {
        ZStack {
            if let image {
                // 사진 크기가 칸 크기를 정하지 않게 덮개로 그린다
                Color.clear.overlay(Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)).clipped()
            } else {
                LinearGradient(colors: [Color(red: 0.17, green: 0.24, blue: 0.42), Color(red: 0.08, green: 0.1, blue: 0.18)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
        }
    }
}
