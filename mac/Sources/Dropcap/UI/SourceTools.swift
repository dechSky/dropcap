import SwiftUI
import AppKit
import UniformTypeIdentifiers

// 설정 '구독' 탭에 끼워 넣는 조각들: 출처 건강 표시, OPML 가져오기·내보내기

// 출처 줄 옆의 작은 표시: 조용함(n일째 새 글 없음) · 멈춤 · 글 없음 · 오류
struct SourceHealthBadge: View {
    let source: Source
    @ObservedObject private var book = SourceHealthBook.shared

    var body: some View {
        switch book.status(source.id) {
        case .unknown, .ok:
            EmptyView()
        case .quiet(let days):
            tag("조용함", "\(days)일째 새 글 없음", color: .secondary)
        case .stalled(let days):
            tag("멈춤", "\(days)일째 새 글이 없습니다. 주소가 바뀌었거나 피드를 닫았을 수 있습니다.", color: .orange)
        case .empty:
            tag("글 없음", "피드를 받았지만 글이 하나도 없습니다.", color: .orange)
        case .failing(let count, let message):
            tag("오류", "\(count)번 연속 확인 실패" + (message.isEmpty ? "" : ": \(message)"), color: .red)
        }
    }

    private func tag(_ label: String, _ help: String, color: Color) -> some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().strokeBorder(color.opacity(0.5), lineWidth: 0.5))
            .help(help)
    }
}

// OPML 가져오기·내보내기 묶음(설정 '구독' 탭의 한 구역)
struct OPMLSection: View {
    @StateObject private var importer = OPMLImporter()
    @ObservedObject private var model = AppModel.shared
    @State private var exportNote: String?

    var body: some View {
        Section {
            HStack {
                Button("OPML 가져오기…") { pickAndImport() }.disabled(importer.running)
                Button("OPML 내보내기…") { export() }.disabled(importer.running)
                Spacer()
                if importer.running {
                    ProgressView(value: Double(importer.done), total: Double(max(importer.total, 1)))
                        .frame(width: 120)
                    Text("\(importer.done)/\(importer.total)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if let s = importer.summary { Text(s).font(.caption).foregroundStyle(.secondary) }
            if !importer.failed.isEmpty {
                DisclosureGroup("추가하지 못한 피드 \(importer.failed.count)곳") {
                    ForEach(importer.failed, id: \.url) { f in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.title.isEmpty ? f.url : f.title).font(.caption)
                            Text(f.reason).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }.font(.caption)
            }
            if let n = exportNote { Text(n).font(.caption).foregroundStyle(.secondary) }
            Text("다른 RSS 앱에서 내보낸 OPML 파일의 피드를 하나씩 확인해 구독합니다. 내보내기는 켜 둔 출처 전부를 분야별로 담습니다.")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("OPML") }
    }

    private func pickAndImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "opml") ?? .xml, .xml]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await importer.run(url) }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "opml") ?? .xml]
        panel.nameFieldStringValue = "Dropcap.opml"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let on = model.allSources.filter { model.state.enabled[$0.id] == true }
        let names = SectionNames.load()
        do {
            try OPML.export(on, sectionName: { names[$0] ?? $0 }).write(to: url, atomically: true, encoding: .utf8)
            exportNote = "출처 \(on.count)곳을 내보냈습니다."
        } catch {
            exportNote = "저장하지 못했습니다: \(error.localizedDescription)"
        }
    }
}

@MainActor
final class OPMLImporter: ObservableObject {
    struct Failed { var title: String; var url: String; var reason: String }
    @Published var running = false
    @Published var total = 0
    @Published var done = 0
    @Published var added = 0
    @Published var skipped = 0
    @Published var failed: [Failed] = []
    @Published var summary: String?

    static let parallel = 4

    func run(_ file: URL) async {
        guard !running else { return }
        let entries: [OPML.Entry]
        do {
            entries = try OPML.parse(try Data(contentsOf: file))
        } catch {
            summary = "OPML 파일을 읽지 못했습니다: \(error.localizedDescription)"
            return
        }
        running = true
        total = entries.count; done = 0; added = 0; skipped = 0; failed = []; summary = nil
        defer { running = false }
        let model = AppModel.shared
        var start = 0
        while start < entries.count {
            let chunk = entries[start..<min(start + Self.parallel, entries.count)]
            start += chunk.count
            var todo: [OPML.Entry] = []
            for e in chunk {
                if model.allSources.contains(where: { $0.url == e.url }) { skipped += 1; done += 1 } else { todo.append(e) }
            }
            // 주소 해석기(ChannelResolver)로 실제 피드인지 확인한 뒤 사용자 출처로 추가한다(몇 곳씩 함께)
            let results = await withTaskGroup(of: (OPML.Entry, String?).self) { group in
                for e in todo { group.addTask { @MainActor in (e, await model.addChannel(e.url, name: e.title)) } }
                var out: [(OPML.Entry, String?)] = []
                for await r in group { out.append(r) }
                return out
            }
            for (e, err) in results {
                done += 1
                switch err {
                case nil: added += 1
                case "이미 구독 중인 채널입니다": skipped += 1
                case let reason?: failed.append(Failed(title: e.title, url: e.url, reason: reason))
                }
            }
        }
        summary = "\(total)곳 중 \(added)곳 추가 · \(skipped)곳은 이미 있음" + (failed.isEmpty ? "" : " · \(failed.count)곳 실패")
    }
}

// 분야 이름(shared/categories.json). 없거나 못 읽으면 id 를 그대로 쓴다.
enum SectionNames {
    private struct File: Decodable {
        struct S: Decodable { let id: String; let name: String }
        let sections: [S]
    }
    static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: Resources.url("categories.json")),
              let f = try? JSONDecoder().decode(File.self, from: data) else { return [:] }
        return Dictionary(f.sections.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    }
}
