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
        let want = Sections.all.map(\.id).filter { images[$0] == nil }
        Task {
            // 기록 읽기(최근 3000건)와 분야 나누기(낱말 분류)는 화면 줄기 밖에서 — 기록이 많으면 매거진을 열 때 메인이 몇 초 멈췄다
            let bySection = await Task.detached(priority: .userInitiated) {
                Self.candidates(Database.shared.items(from: Date().addingTimeInterval(-3 * 86400), limit: 3000).map(\.item), sections: want)
            }.value
            for id in want {
                Task {
                    // 사진 점수(화면 캡처·글자 위주 그림·로고 거름)를 넘는 첫 사진. 기록에 없으면(처음 실행) 피드를 바로 받아 봄
                    var got = await SectionPhoto.pick(bySection[id] ?? [])
                    if got == nil { got = await SectionPhoto.pick(await Self.feedItems(id)) }
                    guard let img = got?.image else { return }
                    withMotion(Motion.enter(Motion.Duration.slow)) { self.images[id] = img }
                }
            }
        }
    }

    // 분야마다 사진 있는 최근 기사(기록 순서 그대로) — 분야 칩이 그 분야인 것
    nonisolated static func candidates(_ recent: [NewsItem], sections: [String]) -> [String: [NewsItem]] {
        let want = Set(sections)
        var out: [String: [NewsItem]] = [:]
        for it in recent where usable(it.image) {
            for c in it.sectionChips where want.contains(c) { out[c, default: []].append(it) }
        }
        return out
    }

    nonisolated static func usable(_ u: String?) -> Bool { u != nil && !ImageKey.isJunk(u) }

    // 그 분야 기본(켤) 출처부터 차례로 받은 글들(사진 있는 글이 나올 때까지 최대 세 곳)
    private static func feedItems(_ section: String) async -> [NewsItem] {
        let ids = Sections.sources(in: section).sorted { ($0.defaultOn == true ? 0 : 1) < ($1.defaultOn == true ? 0 : 1) }.map(\.id)
        var out: [NewsItem] = []
        for id in ids.prefix(3) {
            guard let src = AppModel.shared.allSources.first(where: { $0.id == id }),
                  let items = try? await FeedService.shared.items(for: src, conditional: false) else { continue }
            out += items
            if out.filter({ usable($0.image) }).count >= 4 { break }
        }
        return out
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
                        .blur(radius: 10).saturation(1.2).transition(Motion.fade)
                        .allowsHitTesting(false) // '채우기' 사진은 띠 밖으로 크게 넘친다. 잘려 보여도 클릭 영역은 남아 위 표지 단추를 막았다
                } else { t }
                LinearGradient(colors: [t.opacity(0.88), SectionCardLab.shift(t, hue: 0.05, bri: -0.2).opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(.white.opacity(0.1))
                    .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
                    .padding(Space.s)
                if let photo {
                    SectionCardLab.tilted(photo, frame: true)
                        .scaleEffect(height / 130)
                        .offset(x: g.size.width - 78 * height / 130, y: g.size.height * 0.36)
                        .rotationEffect(.degrees(hover ? 2 : 0))
                        .allowsHitTesting(false)
                }
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(SectionCardLab.english(section.id)).font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.4).opacity(0.85)
                    Text(section.name).font(.app(19, .heavy))
                    if let subtitle { Text(subtitle).font(.dsCaption).opacity(0.85).lineLimit(2).frame(maxWidth: g.size.width * (g.size.width > 400 ? 0.7 : 0.55), alignment: .leading).padding(.top, Space.xxs) }
                }
                .foregroundStyle(.white).shadow(color: .black.opacity(0.2), radius: 2, y: 1).padding(Space.l)
            }
            .frame(width: g.size.width, height: g.size.height).clipped()
        }
        .frame(height: height)
        .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)) // 클릭은 보이는 띠 안에서만
        .overlay(alignment: .bottomLeading) {
            if showsCheck { Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(selected ? 1 : 0.75)).shadow(color: .black.opacity(0.3), radius: 2).padding(Space.l) }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(.white.opacity(selected ? 0.95 : 0), lineWidth: 2.5))
        .shadow(color: t.opacity(selected ? 0.5 : 0.28), radius: selected ? 12 : 7, y: 4)
        .scaleEffect(hover ? 1.015 : 1)
        .motion(Motion.snap, value: hover)
        .motion(Motion.snap, value: selected)
        .onHover { hover = $0 }
    }
}
