import SwiftUI

// 기사 안 찾기(⌘F): 지금 보이는 글(번역이든 원문이든)에서 대소문자·악센트 구별 없이 찾고, ⌘G / ⇧⌘G 로 오간다.
enum ReaderFind {
    // 찾은 자리 하나: 몇 번째 글 조각(제목=-1, 본문 블록 번호)의 몇 번째 일치인지
    struct Match: Equatable { let block: Int; let nth: Int }

    static func ranges(in text: String, _ query: String) -> [Range<String.Index>] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !text.isEmpty else { return [] }
        var out: [Range<String.Index>] = []
        var from = text.startIndex
        while from < text.endIndex, let r = text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], range: from..<text.endIndex) {
            out.append(r)
            from = r.upperBound > r.lowerBound ? r.upperBound : text.index(after: r.lowerBound)
        }
        return out
    }

    // pieces: (조각 번호, 보이는 글) — 화면에 나오는 순서대로
    static func matches(_ pieces: [(Int, String)], _ query: String) -> [Match] {
        pieces.flatMap { id, text in ranges(in: text, query).indices.map { Match(block: id, nth: $0) } }
    }

    // 다음·이전(끝에서 처음으로 돌아감)
    static func step(_ current: Int, count: Int, forward: Bool) -> Int {
        guard count > 0 else { return 0 }
        return ((current + (forward ? 1 : -1)) % count + count) % count
    }

    // 일치한 곳을 칠한 글. current: 이 조각 안에서 지금 고른 일치(몇 번째)
    static func highlighted(_ text: String, _ query: String, current: Int?) -> AttributedString {
        var a = AttributedString(text)
        for (i, r) in ranges(in: text, query).enumerated() {
            guard let lo = AttributedString.Index(r.lowerBound, within: a), let hi = AttributedString.Index(r.upperBound, within: a) else { continue }
            a[lo..<hi].backgroundColor = i == current ? Color.orange.opacity(0.75) : Color.yellow.opacity(0.45)
            if i == current { a[lo..<hi].foregroundColor = .black }
        }
        return a
    }
}

struct ReaderFindBar: View {
    @Binding var query: String
    let count: Int
    let index: Int
    let next: () -> Void
    let prev: () -> Void
    let close: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.dsCallout)
            TextField("기사 안에서 찾기", text: $query)
                .textFieldStyle(.plain).font(.dsBody)
                .focused($focused)
                .onSubmit(next)
                .onExitCommand(perform: close)
                .frame(minWidth: 160)
            Text(query.isEmpty ? "" : count == 0 ? "없음" : "\(index + 1)/\(count)")
                .font(.dsCaption).monospacedDigit().foregroundStyle(count == 0 && !query.isEmpty ? Color.orange : .secondary)
                .frame(minWidth: 40, alignment: .trailing)
            Button(action: prev) { Image(systemName: "chevron.up") }
                .keyboardShortcut("g", modifiers: [.command, .shift]).help("이전 (⇧⌘G)").disabled(count == 0)
            Button(action: next) { Image(systemName: "chevron.down") }
                .keyboardShortcut("g", modifiers: .command).help("다음 (⌘G)").disabled(count == 0)
            Button(action: close) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .help("찾기 닫기 (esc)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, Space.m).padding(.vertical, Space.s)
        .chromeGlass(in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        .elevation(Elevation.card)
        .frame(maxWidth: 440)
        .onAppear { focused = true }
    }
}
