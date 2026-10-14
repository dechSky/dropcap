import SwiftUI

// 설정 > 스크랩북: 노트 폴더 자동 저장 · 아무 주소나 나중에 읽기로 보내는 방법(서비스 메뉴·북마클릿·주소)
struct ScrapbookSettingsView: View {
    @ObservedObject private var export = ScrapExport.shared
    @ObservedObject private var book = Scrapbook.shared
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                Toggle("스크랩할 때마다 노트 폴더에 Markdown 으로 저장", isOn: Binding(
                    get: { export.enabled },
                    set: { on in if on && export.folder == nil { export.chooseFolder() } else { export.enabled = on } }))
                LabeledContent("폴더") {
                    HStack(spacing: 8) {
                        Text(export.folder.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? export.savedPath.map { "\(($0 as NSString).abbreviatingWithTildeInPath) (찾지 못함)" } ?? "고르지 않음")
                            .foregroundStyle(export.folder == nil ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.middle)
                        Button(export.folder == nil ? "고르기…" : "바꾸기…") { export.chooseFolder() }
                        if export.folder != nil {
                            Button { export.forgetFolder() } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.borderless).help("폴더 잊기(자동 저장 꺼짐)")
                        }
                    }
                }
                if let e = export.lastError {
                    Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Text("스크랩 폴더마다 ‘폴더 이름.md’ 파일 하나 — Obsidian 보관소 안의 폴더를 고르면 노트로 바로 보입니다. 파일은 덮어쓰니 고쳐 쓸 노트는 다른 이름으로 두세요.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("지금 저장") { export.syncNow() }.disabled(!export.enabled || export.folder == nil || book.scraps.isEmpty)
                }
            } header: { Text("노트 폴더로 내보내기") }

            Section {
                LabeledContent("서비스 메뉴") {
                    Text("다른 앱에서 주소·링크를 고르고 오른쪽 클릭 › 서비스 › Dropcap 에 저장").foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
                LabeledContent("상단바·매거진") {
                    Text("‘저장’ 목록 위 ‘주소로 추가…’ 칸에 붙여 넣기").foregroundStyle(.secondary)
                }
                LabeledContent("브라우저 북마클릿") {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(SaveLink.bookmarklet, forType: .string)
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(1.6)); copied = false }
                    } label: { Label(copied ? "복사했어요" : "북마클릿 코드 복사", systemImage: copied ? "checkmark" : "doc.on.doc") }
                }
                Text("새 북마크를 만들고 주소 칸에 복사한 코드를 붙여 넣으세요. 기사를 보다 그 북마크를 누르면 Dropcap 의 나중에 읽기에 담깁니다. 단축어에서는 dropcap://save?url=<주소> 를 열면 됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("아무 웹 주소나 나중에 읽기로") }
        }
        .formStyle(.grouped)
    }
}
