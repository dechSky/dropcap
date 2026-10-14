import AppKit
import SwiftUI

// 분야의 '오늘 얼굴' 사진: 매거진 기록에서 그 분야의 최근 사진 기사, 없으면(처음 실행) 그 분야 기본 출처 피드를 바로 받아 고른다.
// 분야 고르기 카드·매거진 분야 머리·설정 분야 탭이 같이 쓴다. 한 번 고른 사진은 실행 동안 기억.
@MainActor
final class SectionPhotos: ObservableObject {
    static let shared = SectionPhotos()
    @Published private(set) var images: [String: NSImage] = [:]
    private var loading = false

    func load() {
        guard !loading else { return }
        loading = true
        let recent = Database.shared.items(from: Date().addingTimeInterval(-3 * 86400), limit: 3000).map(\.item)
        for s in Sections.all where images[s.id] == nil {
            Task {
                var url = recent.first { $0.inSection(s.id) && Self.usable($0.image) }?.image
                if url == nil { url = await Self.fromFeed(s.id) } // 처음 실행: 기록이 없으면 피드를 바로 받아 봄
                guard let url, let img = await ImageLoader.shared.image(url) else { return }
                withAnimation(.easeOut(duration: 0.35)) { self.images[s.id] = img }
            }
        }
    }

    static func usable(_ u: String?) -> Bool { u != nil && !ImageKey.isJunk(u) }

    // 그 분야 기본(켤) 출처부터 차례로, 사진 있는 첫 글
    private static func fromFeed(_ section: String) async -> String? {
        let ids = Sections.sources(in: section).sorted { ($0.defaultOn == true ? 0 : 1) < ($1.defaultOn == true ? 0 : 1) }.map(\.id)
        for id in ids.prefix(3) {
            guard let src = AppModel.shared.allSources.first(where: { $0.id == id }),
                  let items = try? await FeedService.shared.items(for: src, conditional: false) else { continue }
            if let u = items.first(where: { usable($0.image) })?.image { return u }
        }
        return nil
    }
}

// 분야 유리 카드(나-3): 흐린 사진 바탕 + 분야색 유리판 + 영문 섹션명·한글 이름 + 기울인 사진
struct SectionGlassCard: View {
    let section: NewsSection
    var photo: NSImage?
    var selected = false
    var subtitle: String? = nil
    var height: CGFloat = 130
    var showsCheck = true
    @State private var hover = false

    var body: some View {
        let t = section.tint
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                if let photo {
                    Image(nsImage: photo).resizable().aspectRatio(contentMode: .fill).frame(width: g.size.width, height: g.size.height)
                        .blur(radius: 10).saturation(1.2).transition(.opacity)
                } else { t }
                LinearGradient(colors: [t.opacity(0.88), SectionCardLab.shift(t, hue: 0.05, bri: -0.2).opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.1))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
                    .padding(8)
                if let photo {
                    SectionCardLab.tilted(photo, frame: true)
                        .scaleEffect(height / 130)
                        .offset(x: g.size.width - 78 * height / 130, y: g.size.height * 0.36)
                        .rotationEffect(.degrees(hover ? 2 : 0))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(SectionCardLab.english(section.id)).font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.4).opacity(0.85)
                    Text(section.name).font(.app(19, .heavy))
                    if let subtitle { Text(subtitle).font(.app(11)).opacity(0.85).lineLimit(2).frame(maxWidth: g.size.width * (g.size.width > 400 ? 0.7 : 0.55), alignment: .leading).padding(.top, 2) }
                }
                .foregroundStyle(.white).shadow(color: .black.opacity(0.2), radius: 2, y: 1).padding(16)
            }
            .frame(width: g.size.width, height: g.size.height).clipped()
        }
        .frame(height: height)
        .overlay(alignment: .bottomLeading) {
            if showsCheck { Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(selected ? 1 : 0.75)).shadow(color: .black.opacity(0.3), radius: 2).padding(14) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(selected ? 0.95 : 0), lineWidth: 2.5))
        .shadow(color: t.opacity(selected ? 0.5 : 0.28), radius: selected ? 12 : 7, y: 4)
        .scaleEffect(hover ? 1.015 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hover)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)
        .onHover { hover = $0 }
    }
}
