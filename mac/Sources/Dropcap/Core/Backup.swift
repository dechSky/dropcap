import AppKit
import Foundation
import UniformTypeIdentifiers

// 내 기록 내보내기·가져오기(P-08 · D-14): 집·회사 Mac 사이를 옮길 때. 계정도 서버도 없이 JSON 파일 하나로.
// 담는 것: 저장(나중에 읽기) · 스크랩과 스크랩 폴더 · 구독(직접 추가한 출처·켜고 끈 출처·출처별 알림) · 고른 분야와 분야별 알림 ·
// 알림 설정·낱말(꼭 알림·알리지 않음·지켜볼 낱말) · 숨긴 출처 · 팔로우한 스토리.
// 담지 않는 것: 기사 본문·번역 캐시, 사진, 매거진 기사 기록(다시 받으면 생김), 읽음 기록·본 글 기억.
struct BackupFile: Codable, Equatable {
    static let formatName = "dropcap-backup"
    static let currentVersion = 1

    var format = Self.formatName
    var version = Self.currentVersion
    var exported: Date
    var app = "mac"
    var settings: AppState.Settings
    var sectionsChosen: [String]?
    var sectionPolicy: [String: SectionPolicy]
    var enabled: [String: Bool]
    var notify: [String: Bool]
    var customSources: [Source]
    var hiddenSources: [String]
    var followedStories: [String]
    var saved: [NewsItem]
    var scraps: [Scrap]
    var scrapFolders: [String]

    init(exported: Date, settings: AppState.Settings, sectionsChosen: [String]?, sectionPolicy: [String: SectionPolicy],
         enabled: [String: Bool], notify: [String: Bool], customSources: [Source], hiddenSources: [String],
         followedStories: [String], saved: [NewsItem], scraps: [Scrap], scrapFolders: [String]) {
        self.exported = exported; self.settings = settings; self.sectionsChosen = sectionsChosen; self.sectionPolicy = sectionPolicy
        self.enabled = enabled; self.notify = notify; self.customSources = customSources; self.hiddenSources = hiddenSources
        self.followedStories = followedStories; self.saved = saved; self.scraps = scraps; self.scrapFolders = scrapFolders
    }

    // 항목이 빠졌거나(예전·다른 앱이 만든 파일) 일부가 깨져도 나머지는 읽는다
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = (try? c.decodeIfPresent(String.self, forKey: .format)) ?? Self.formatName
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        exported = (try? c.decodeIfPresent(Date.self, forKey: .exported)) ?? Date(timeIntervalSince1970: 0)
        app = (try? c.decodeIfPresent(String.self, forKey: .app)) ?? "?"
        settings = (try? c.decodeIfPresent(AppState.Settings.self, forKey: .settings)) ?? AppState.Settings()
        sectionsChosen = try? c.decodeIfPresent([String].self, forKey: .sectionsChosen)
        sectionPolicy = (try? c.decodeIfPresent([String: SectionPolicy].self, forKey: .sectionPolicy)) ?? [:]
        enabled = (try? c.decodeIfPresent([String: Bool].self, forKey: .enabled)) ?? [:]
        notify = (try? c.decodeIfPresent([String: Bool].self, forKey: .notify)) ?? [:]
        customSources = (try? c.decodeIfPresent([Source].self, forKey: .customSources)) ?? []
        hiddenSources = (try? c.decodeIfPresent([String].self, forKey: .hiddenSources)) ?? []
        followedStories = (try? c.decodeIfPresent([String].self, forKey: .followedStories)) ?? []
        saved = (try? c.decodeIfPresent([NewsItem].self, forKey: .saved)) ?? []
        scraps = (try? c.decodeIfPresent([Scrap].self, forKey: .scraps)) ?? []
        scrapFolders = (try? c.decodeIfPresent([String].self, forKey: .scrapFolders)) ?? []
    }
}

enum Backup {
    enum Failure: LocalizedError {
        case notBackup, newerVersion(Int)
        var errorDescription: String? {
            switch self {
            case .notBackup: return "Dropcap 기록 파일이 아닙니다"
            case .newerVersion(let v): return "더 새 판 Dropcap 이 만든 기록입니다(형식 \(v)). 앱을 업데이트한 뒤 가져오세요"
            }
        }
    }

    static func make(_ s: AppState, scraps: [Scrap], folders: [String], now: Date = Date()) -> BackupFile {
        BackupFile(exported: now, settings: s.settings, sectionsChosen: s.sectionsChosen, sectionPolicy: s.sectionPolicy,
                   enabled: s.enabled, notify: s.notify, customSources: s.customSources, hiddenSources: s.hiddenSources,
                   followedStories: s.followedStories, saved: s.saved, scraps: scraps, scrapFolders: folders)
    }

    static func encode(_ b: BackupFile) throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(b)
    }

    static func decode(_ data: Data) throws -> BackupFile {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        // 형식 이름·판을 먼저 본다(다른 JSON 이거나 새 판이면 알아듣게)
        struct Head: Decodable { var format: String?; var version: Int? }
        guard let head = try? d.decode(Head.self, from: data), head.format == BackupFile.formatName else { throw Failure.notBackup }
        if let v = head.version, v > BackupFile.currentVersion { throw Failure.newerVersion(v) }
        return try d.decode(BackupFile.self, from: data)
    }

    struct Summary: Equatable {
        var saved = 0, scraps = 0, folders = 0, sources = 0, sections = 0, words = 0, hidden = 0, followed = 0
        var settingsTaken = false
        var text: String {
            var parts: [String] = []
            if saved > 0 { parts.append("저장 \(saved)") }
            if scraps > 0 { parts.append("스크랩 \(scraps)") }
            if folders > 0 { parts.append("폴더 \(folders)") }
            if sources > 0 { parts.append("구독 \(sources)") }
            if sections > 0 { parts.append("분야 \(sections)") }
            if words > 0 { parts.append("낱말 \(words)") }
            if hidden > 0 { parts.append("숨긴 출처 \(hidden)") }
            if followed > 0 { parts.append("팔로우 \(followed)") }
            if settingsTaken { parts.append("알림 설정") }
            return parts.isEmpty ? "새로 더할 것이 없었습니다(모두 이미 있음)" : parts.joined(separator: " · ") + " 더함"
        }
    }

    struct Merged {
        var state: AppState
        var newScraps: [Scrap]
        var folders: [String]
        var summary: Summary
    }

    // 합치기: 이 Mac 에 없는 것만 더하고 같은 것은 건너뛴다. 이 Mac 의 값을 지우거나 끄지 않는다.
    // 알림 설정(시각·상한 등 낱개 값)은 이 Mac 이 아직 처음 그대로일 때만 가져온 값을 쓴다(새 Mac 으로 옮길 때). 낱말 목록은 늘 합친다.
    static func merge(_ b: BackupFile, into s0: AppState, scraps: [Scrap], folders: [String]) -> Merged {
        var s = s0, sum = Summary()
        func union(_ a: [String], _ b: [String], count: inout Int) -> [String] {
            var out = a
            for x in b where !out.contains(where: { $0.lowercased() == x.lowercased() }) { out.append(x); count += 1 }
            return out
        }
        // 알림 설정
        var bare = s.settings
        bare.mustKeywords = []; bare.muteKeywords = []; bare.watchKeywords = []
        let localKeywords = (s.settings.mustKeywords, s.settings.muteKeywords, s.settings.watchKeywords)
        if bare == AppState.Settings() {
            var taken = b.settings
            taken.mustKeywords = localKeywords.0; taken.muteKeywords = localKeywords.1; taken.watchKeywords = localKeywords.2
            if taken != s.settings { sum.settingsTaken = true }
            s.settings = taken
        }
        s.settings.mustKeywords = union(s.settings.mustKeywords, b.settings.mustKeywords, count: &sum.words)
        s.settings.muteKeywords = union(s.settings.muteKeywords, b.settings.muteKeywords, count: &sum.words)
        s.settings.watchKeywords = union(s.settings.watchKeywords, b.settings.watchKeywords, count: &sum.words)
        // 분야
        if let theirs = b.sectionsChosen {
            let mine = s.sectionsChosen ?? []
            let add = theirs.filter { !mine.contains($0) }
            sum.sections = add.count
            if s.sectionsChosen == nil || !add.isEmpty { s.sectionsChosen = (mine + add).sorted { Sections.order($0) < Sections.order($1) } }
        }
        for (k, v) in b.sectionPolicy where s.sectionPolicy[k] == nil { s.sectionPolicy[k] = v }
        // 구독: 직접 추가한 출처(같은 id·주소는 건너뜀), 켜 둔 출처는 켬(끄지는 않음), 출처별 알림은 없는 것만
        for src in b.customSources where !s.customSources.contains(where: { $0.id == src.id || $0.url == src.url }) {
            s.customSources.append(src); sum.sources += 1
        }
        for (k, v) in b.enabled where v && s.enabled[k] != true { s.enabled[k] = true }
        for (k, v) in b.notify where s.notify[k] == nil { s.notify[k] = v }
        s.hiddenSources = union(s.hiddenSources, b.hiddenSources, count: &sum.hidden)
        s.followedStories = union(s.followedStories, b.followedStories, count: &sum.followed)
        // 저장(같은 기사는 건너뜀, 가져온 것은 뒤에)
        for it in b.saved where !s.saved.contains(where: { $0.key == it.key }) { s.saved.append(it); sum.saved += 1 }
        // 스크랩(같은 id, 또는 같은 기사·같은 문단·같은 폴더면 건너뜀)
        var newScraps: [Scrap] = []
        for sc in b.scraps where !(scraps + newScraps).contains(where: { $0.id == sc.id || ($0.item.key == sc.item.key && $0.quote == sc.quote && $0.collection == sc.collection) }) {
            newScraps.append(sc)
        }
        sum.scraps = newScraps.count
        var fs = folders
        for f in b.scrapFolders + newScraps.map(\.collection) where !fs.contains(f) { fs.append(f); sum.folders += 1 }
        return Merged(state: s, newScraps: newScraps, folders: fs, summary: sum)
    }

    // 되돌리기: 가져오기 전에 남긴 파일의 값으로 그 항목들을 그대로 바꾼다(가져오기로 더해진 것이 빠진다)
    static func restore(_ b: BackupFile, into s0: AppState) -> AppState {
        var s = s0
        s.settings = b.settings
        s.sectionsChosen = b.sectionsChosen
        s.sectionPolicy = b.sectionPolicy
        s.enabled = b.enabled
        s.notify = b.notify
        s.customSources = b.customSources
        s.hiddenSources = b.hiddenSources
        s.followedStories = b.followedStories
        s.saved = b.saved
        return s
    }
}

// 앱 안에서: 파일 고르기 · 가져오기 전 자동 백업 · 되돌리기
@MainActor
final class BackupManager: ObservableObject {
    static let shared = BackupManager()
    @Published private(set) var lastMessage: String?
    @Published private(set) var undoFile: URL?   // 마지막 가져오기 전에 남긴 파일(되돌리기)

    let dir: URL
    init(dir: URL = Store.dir.appendingPathComponent("backups", isDirectory: true)) {
        self.dir = dir
        undoFile = Self.latestBeforeImport(in: dir)
    }

    func current() -> BackupFile {
        Backup.make(AppModel.shared.state, scraps: Database.shared.scraps(), folders: Scrapbook.shared.collections)
    }

    static func stamp(_ d: Date = Date()) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: d)
    }

    static func latestBeforeImport(in dir: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("before-import-") }.sorted { $0.lastPathComponent < $1.lastPathComponent }.last
    }

    func export(to url: URL) {
        do {
            try Backup.encode(current()).write(to: url, options: .atomic)
            lastMessage = "내보냈습니다: \(url.lastPathComponent)"
        } catch {
            lastMessage = "내보내지 못했습니다: \(error.localizedDescription)"
        }
    }

    // 가져오기 전 지금 기록을 backups/ 에 남기고(최근 5개만), 합친다
    func importFile(_ url: URL) {
        do {
            let b = try Backup.decode(Data(contentsOf: url))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let before = dir.appendingPathComponent("before-import-\(Self.stamp()).json")
            try Backup.encode(current()).write(to: before, options: .atomic)
            prune()
            let m = Backup.merge(b, into: AppModel.shared.state, scraps: Database.shared.scraps(), folders: Scrapbook.shared.collections)
            apply(state: m.state, addScraps: m.newScraps, folders: m.folders)
            undoFile = before
            lastMessage = "가져왔습니다 — " + m.summary.text
        } catch {
            lastMessage = "가져오지 못했습니다: \(error.localizedDescription)"
        }
    }

    func undoImport() {
        guard let f = undoFile else { return }
        do {
            let b = try Backup.decode(Data(contentsOf: f))
            for s in Database.shared.scraps() where !b.scraps.contains(where: { $0.id == s.id }) { Database.shared.deleteScrap(s.id) }
            let have = Set(Database.shared.scraps().map(\.id))
            for s in b.scraps where !have.contains(s.id) { Database.shared.saveScrap(s) }
            UserDefaults.standard.set(b.scrapFolders.filter { $0 != Scrapbook.defaultCollection }, forKey: "scrapCollections")
            AppModel.shared.replaceState { Backup.restore(b, into: $0) }
            Scrapbook.shared.reload()
            try? FileManager.default.removeItem(at: f)
            undoFile = Self.latestBeforeImport(in: dir)
            lastMessage = "가져오기 전으로 되돌렸습니다"
        } catch {
            lastMessage = "되돌리지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func apply(state: AppState, addScraps: [Scrap], folders: [String]) {
        for s in addScraps { Database.shared.saveScrap(s) }
        let used = Set(Database.shared.scraps().map(\.collection))
        UserDefaults.standard.set(folders.filter { !used.contains($0) && $0 != Scrapbook.defaultCollection }, forKey: "scrapCollections")
        AppModel.shared.replaceState { _ in state }
        Scrapbook.shared.reload()
        ScrapExport.shared.syncSoon()
    }

    private func prune() {
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("before-import-") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for f in files.dropLast(5) { try? FileManager.default.removeItem(at: f) }
    }

    // MARK: 파일 고르기 창
    func chooseExport() {
        let p = NSSavePanel()
        p.allowedContentTypes = [.json]
        p.nameFieldStringValue = "Dropcap-기록-\(Self.stamp().prefix(8)).json"
        p.message = "저장·스크랩·구독·분야·알림 설정을 파일 하나로 내보냅니다(기사 캐시·사진은 빼고)"
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let u = p.url { export(to: u) }
    }

    func chooseImport() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        p.allowsMultipleSelection = false
        p.message = "다른 Mac 에서 내보낸 Dropcap 기록을 이 Mac 에 합칩니다(같은 것은 건너뜀)"
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let u = p.url { importFile(u) }
    }
}
