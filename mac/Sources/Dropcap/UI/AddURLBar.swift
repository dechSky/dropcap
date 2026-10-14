import SwiftUI

// 저장 목록 위의 '주소로 추가…' 칸: 피드에 없는 기사 주소를 붙여 넣어 나중에 읽기로 저장
struct AddURLBar: View {
    var compact = true // 상단바 창(작게) · 매거진(넓게)
    @State private var text = ""
    @State private var busy = false
    @State private var message: (ok: Bool, text: String)?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "link.badge.plus").foregroundStyle(.secondary).font(.app(compact ? 11 : 13))
                TextField("주소로 추가… (기사 주소를 붙여 넣고 Return)", text: $text)
                    .textFieldStyle(.plain).font(.app(compact ? 12 : 14))
                    .focused($focused)
                    .onSubmit(add)
                    .disabled(busy)
                if busy {
                    ProgressView().controlSize(.mini)
                } else if !text.isEmpty {
                    Button("저장", action: add).buttonStyle(.borderless).font(.app(compact ? 11.5 : 13, .semibold))
                }
            }
            .padding(.horizontal, compact ? 9 : 12).padding(.vertical, compact ? 5 : 8)
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: compact ? 7 : 10, style: .continuous))
            if let m = message {
                Label(m.text, systemImage: m.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.app(compact ? 11 : 12)).foregroundStyle(m.ok ? Color.green : Color.orange)
                    .lineLimit(1).truncationMode(.middle)
                    .transition(.opacity)
            }
        }
    }

    private func add() {
        let raw = text
        guard !raw.trimmingCharacters(in: .whitespaces).isEmpty, !busy else { return }
        busy = true
        Task {
            let r = await SaveLink.save(raw)
            busy = false
            switch r {
            case .success(let it): message = (true, "저장함 · \(it.displayTitle)"); text = ""
            case .failure(let f): message = (false, f.message)
            }
            try? await Task.sleep(for: .seconds(4))
            if message?.text != nil { withAnimation { message = nil } }
        }
    }
}
