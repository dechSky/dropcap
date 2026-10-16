import SwiftUI

// 매거진 머리 아래: 오늘 호 대표 기사 진행률, 다 읽으면 마무리 띠(M-23)
struct TodayProgressView: View {
    let keys: [String]
    var onDone: () -> Void = {}
    @ObservedObject private var app = AppModel.shared

    private var readCount: Int { keys.filter { app.state.read[$0] != nil }.count }
    private var done: Bool { TodayIssue.isMarkedDone() || (!keys.isEmpty && readCount >= keys.count) }

    var body: some View {
        Group {
            if done {
                HStack(spacing: Space.m) {
                    Image(systemName: "checkmark.seal.fill").font(.app(22)).foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("오늘 호를 다 읽었어요").font(.dsSubheading)
                        Text(TodayIssue.nextIssueText(digestEnabled: app.state.settings.digestEnabled, digestHour: app.state.settings.digestHour))
                            .font(.dsCallout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Space.l).padding(.vertical, Space.m)
                .background(Color.green.opacity(0.09), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.green.opacity(0.25), lineWidth: 0.5))
                .transition(Motion.pop)
            } else if !keys.isEmpty {
                HStack(spacing: Space.m) {
                    Text("오늘 호 대표 기사 \(readCount)/\(keys.count)").font(.dsCaption).foregroundStyle(.secondary).monospacedDigit()
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.primary.opacity(0.08))
                            Capsule().fill(Color.accentColor.opacity(0.8)).frame(width: g.size.width * CGFloat(readCount) / CGFloat(max(keys.count, 1)))
                        }
                    }
                    .frame(width: 120, height: 4)
                }
                .help("표지와 주요 뉴스·고른 분야의 첫 줄을 다 읽으면 오늘 호가 끝납니다")
            }
        }
        .motion(Motion.settle, value: done)
        .task(id: readCount) {
            if !keys.isEmpty, readCount >= keys.count, !TodayIssue.isMarkedDone() { TodayIssue.markDone(); onDone() }
        }
    }
}

// 분야 지면 위: 저녁 정리(N-26). 기기 안 요약임을 밝히고, 줄마다 근거 기사 번호, 아래에 근거 기사 원제목·링크
struct EveningBriefBox: View {
    let brief: SectionBrief

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s) {
                Image(systemName: "moon.stars.fill").foregroundStyle(Sections.byID(brief.section)?.tint ?? .indigo)
                Text("저녁 정리 · \(Sections.name(brief.section))").font(.dsSubheading)
                Text(brief.at.formatted(.dateTime.locale(Locale(identifier: "ko_KR")).hour().minute())).font(.dsCaption).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Label("기기 안 요약 · 원문을 확인하세요", systemImage: "sparkles")
                    .font(.dsCaption).foregroundStyle(.secondary)
                    .help("이 Mac 의 Apple Intelligence 가 아래 기사들의 제목·요약만 보고 만든 정리입니다. 틀릴 수 있어 근거 기사를 함께 둡니다.")
            }
            ForEach(Array((brief.lines ?? []).enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text("•").foregroundStyle(.secondary)
                    Text(line.text).font(.app(14)).fixedSize(horizontal: false, vertical: true)
                    ForEach(line.refs, id: \.self) { r in
                        Text("[\(r + 1)]").font(.dsChip).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            Divider().padding(.vertical, Space.xxs)
            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(Array(brief.items.enumerated()), id: \.element.key) { i, it in
                    Button {
                        AppModel.shared.markOpened(it)
                        ReaderController.open(it, sequence: brief.items)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                            Text("[\(i + 1)]").font(.dsChip).foregroundStyle(.secondary).monospacedDigit()
                            Text(it.title).font(.dsCallout).lineLimit(1) // 원제목 그대로
                            Text("— \(it.sourceName)").font(.dsCaption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(it.link)
                }
            }
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
    }
}
