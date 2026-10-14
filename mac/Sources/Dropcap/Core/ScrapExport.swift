import AppKit
import Foundation

// 스크랩 → 노트 폴더(Obsidian 보관소 등) 자동 저장.
// 켜 두면 스크랩이 바뀔 때마다 폴더별 `<고른 폴더>/<스크랩 폴더 이름>.md` 를 지금의 Markdown 내보내기 형식으로 덮어쓴다(원자적 쓰기).
// 고른 폴더는 보안 범위 북마크로 기억한다. 다른 Mac 으로 옮겨 북마크가 풀리지 않으면 쓰지 않고 '다시 골라 주세요'를 보인다.
// 끄기 스위치: 설정 > 스크랩북 의 토글(scrapExportEnabled). 끄면 아무 파일도 건드리지 않는다.
@MainActor
final class ScrapExport: ObservableObject {
    static let shared = ScrapExport()
    static let enabledKey = "scrapExportEnabled"
    static let bookmarkKey = "scrapExportBookmark"
    static let pathKey = "scrapExportPath" // 표시용(북마크가 풀리지 않을 때 어느 폴더였는지 알려 줌)

    @Published private(set) var folder: URL?
    @Published private(set) var lastError: String?
    @Published private(set) var lastWrite: Date?
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey); if enabled { syncSoon() } }
    }

    private var pending: Task<Void, Never>?

    private init() {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        folder = resolve()
    }

    var savedPath: String? { UserDefaults.standard.string(forKey: Self.pathKey) }

    // MARK: 폴더 고르기·기억

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.allowsMultipleSelection = false
        p.prompt = "이 폴더에 저장"
        p.message = "스크랩 폴더마다 Markdown 파일(.md)을 이 폴더에 만들고 고쳐 씁니다."
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK, let u = p.url else { return }
        setFolder(u)
    }

    func setFolder(_ u: URL) {
        let data = (try? u.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? u.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)) // 샌드박스 밖 임시 서명 대비
        guard let data else { lastError = "폴더를 기억하지 못했습니다"; return }
        UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        UserDefaults.standard.set(u.path, forKey: Self.pathKey)
        folder = u
        lastError = nil
        if !enabled { enabled = true } else { syncSoon() }
    }

    func forgetFolder() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        UserDefaults.standard.removeObject(forKey: Self.pathKey)
        folder = nil
        enabled = false
    }

    private func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return nil }
        var stale = false
        let u = (try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale))
        guard let u else { lastError = "폴더를 찾지 못했습니다 — 다시 골라 주세요"; return nil }
        if stale, let fresh = try? u.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
        }
        return u
    }

    // MARK: 쓰기

    // 스크랩이 바뀌면 부른다. 잇따른 변경은 잠깐 모아서 한 번에 쓴다.
    func syncSoon(renamed: (from: String, to: String)? = nil) {
        guard enabled, folder != nil else { return }
        if let r = renamed { trashOld(r.from) }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.syncNow()
        }
    }

    func syncNow() {
        guard enabled, let dir = folder ?? resolve() else { return }
        let book = Scrapbook.shared
        let scoped = dir.startAccessingSecurityScopedResource()
        defer { if scoped { dir.stopAccessingSecurityScopedResource() } }
        var failed: String?
        for c in book.collections {
            let list = book.scraps.filter { $0.collection == c }
            let file = dir.appendingPathComponent(Self.fileName(c))
            // 비어 있는 폴더는, 전에 써 둔 파일이 있을 때만 비운 내용으로 덮는다(새 빈 파일을 만들지 않음)
            if list.isEmpty && !FileManager.default.fileExists(atPath: file.path) { continue }
            let text = Scrapbook.render(list, title: c)
            if let old = try? String(contentsOf: file, encoding: .utf8), Self.sameIgnoringDate(old, text) { continue } // 바뀐 게 없으면 손대지 않음(동기화 앱이 덜 바쁘게)
            do { try Data(text.utf8).write(to: file, options: .atomic) } catch { failed = error.localizedDescription }
        }
        lastError = failed.map { "쓰지 못했습니다: \($0)" }
        if failed == nil { lastWrite = Date() }
    }

    // 폴더 이름이 바뀌면 예전 이름의 파일은 휴지통으로(지우지 않고 되살릴 수 있게)
    private func trashOld(_ name: String) {
        guard let dir = folder else { return }
        let scoped = dir.startAccessingSecurityScopedResource()
        defer { if scoped { dir.stopAccessingSecurityScopedResource() } }
        let f = dir.appendingPathComponent(Self.fileName(name))
        if FileManager.default.fileExists(atPath: f.path) { try? FileManager.default.trashItem(at: f, resultingItemURL: nil) }
    }

    // 파일 이름으로 쓸 수 없는 글자(/ : 맨 앞 .)를 바꾸고 너무 길면 자른다
    nonisolated static func fileName(_ collection: String) -> String {
        var n = collection.replacingOccurrences(of: "/", with: "／").replacingOccurrences(of: ":", with: "：")
        n = n.components(separatedBy: .controlCharacters).joined()
        while n.hasPrefix(".") { n.removeFirst() }
        n = n.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { n = "스크랩" } // Scrapbook.defaultCollection(메인 액터 밖이라 글자로)
        return String(n.prefix(120)) + ".md"
    }

    // 머리의 날짜 줄만 다르면 같은 내용으로 본다
    nonisolated static func sameIgnoringDate(_ a: String, _ b: String) -> Bool {
        func strip(_ s: String) -> String {
            s.replacingOccurrences(of: #"(?m)^_Dropcap 스크랩 · \d{4}-\d{2}-\d{2} · "#, with: "_Dropcap 스크랩 · ", options: .regularExpression)
        }
        return strip(a) == strip(b)
    }
}
