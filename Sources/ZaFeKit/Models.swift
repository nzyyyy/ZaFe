import AppKit
import CryptoKit
import Observation
import SwiftData

enum RecordKind: String, Codable, CaseIterable {
    case text, image, files, note

    var symbol: String {
        switch self {
        case .text: "doc.on.clipboard"
        case .image: "photo"
        case .files: "folder"
        case .note: "note.text"
        }
    }
    var label: String {
        switch self {
        case .text: "文字"
        case .image: "图片"
        case .files: "文件"
        case .note: "便签"
        }
    }
}

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, clipboard, files, notes, favorites, trash
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "全部"
        case .clipboard: "剪贴板"
        case .files: "文件"
        case .notes: "便签"
        case .favorites: "收藏"
        case .trash: "最近删除"
        }
    }
    var symbol: String {
        switch self {
        case .all: "square.stack.3d.up"
        case .clipboard: "clipboard"
        case .files: "folder"
        case .notes: "note.text"
        case .favorites: "star"
        case .trash: "trash"
        }
    }
    static var quickFilters: [Self] { [.all, .clipboard, .files, .notes, .favorites] }
}

struct FileReference: Codable, Identifiable, Equatable {
    var id = UUID()
    var bookmark: Data
    var path: String
    var name: String
    var isDirectory: Bool

    init(url: URL) throws {
        guard url.isFileURL else { throw LibraryError.invalidFile }
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        bookmark = try canonical.bookmarkData(options: [], includingResourceValuesForKeys: [.fileResourceIdentifierKey], relativeTo: nil)
        path = canonical.path
        name = canonical.lastPathComponent
        isDirectory = (try? canonical.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    func resolved() throws -> (url: URL, refreshed: Self?) {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: url.path) else { throw LibraryError.missingFile }
        let updated = stale || path != url.path ? try Self(url: url) : nil
        return (url, updated.map { value in
            var reference = value
            reference.id = id
            return reference
        })
    }
}

@Model
final class LibraryRecord {
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var isClipboard: Bool
    var title: String
    var body: String
    var referencesData: Data
    var imageName: String?
    var fingerprint: String?
    var byteCount: Int
    var createdAt: Date
    var touchedAt: Date
    var isFavorite: Bool
    var deletedAt: Date?

    init(kind: RecordKind, isClipboard: Bool, title: String = "", body: String = "", references: [FileReference] = [],
         imageName: String? = nil, fingerprint: String? = nil, byteCount: Int = 0, now: Date = .now) throws {
        id = UUID()
        kindRaw = kind.rawValue
        self.isClipboard = isClipboard
        self.title = title
        self.body = body
        referencesData = try JSONEncoder().encode(references)
        self.imageName = imageName
        self.fingerprint = fingerprint
        self.byteCount = byteCount
        createdAt = now
        touchedAt = now
        isFavorite = false
    }

    var kind: RecordKind { RecordKind(rawValue: kindRaw) ?? .text }
    var references: [FileReference] { (try? JSONDecoder().decode([FileReference].self, from: referencesData)) ?? [] }
    var isProtected: Bool { !isClipboard || isFavorite }
    var displayTitle: String {
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        switch kind {
        case .text, .note: return body.split(whereSeparator: \.isNewline).first.map(String.init) ?? "新便签"
        case .image: return "图片"
        case .files:
            let files = references
            return files.count > 1 ? "\(files.first?.name ?? "文件") 等 \(files.count) 项" : files.first?.name ?? "文件"
        }
    }
    var subtitle: String {
        switch kind {
        case .text, .note: body.replacingOccurrences(of: "\n", with: " ")
        case .image: ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        case .files: references.map(\.path).joined(separator: " · ")
        }
    }
    func matches(_ query: String, filter: LibraryFilter) -> Bool {
        if filter == .trash {
            guard deletedAt != nil else { return false }
        } else {
            guard deletedAt == nil else { return false }
            switch filter {
            case .clipboard: if !isClipboard { return false }
            case .files: if kind != .files { return false }
            case .notes: if kind != .note { return false }
            case .favorites: if !isFavorite { return false }
            default: break
            }
        }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || ([title, body] + references.flatMap { [$0.name, $0.path] })
            .contains { $0.localizedStandardContains(query) }
    }
}

enum LibraryError: LocalizedError {
    case invalidFile, missingFile, missingImage, tooLarge, emptyClipboard, invalidImage
    var errorDescription: String? {
        switch self {
        case .invalidFile: "无法添加这个文件。"
        case .missingFile: "找不到文件，请重新定位。"
        case .missingImage: "找不到已保存的图片。"
        case .tooLarge: "内容超过 20 MB，未自动保存。"
        case .emptyClipboard: "剪贴板中没有可记录的内容。"
        case .invalidImage: "无法读取这张图片。"
        }
    }
}

struct HistoryLimits {
    var days = 30
    var count = 1_000
    var bytes = 1_000_000_000
    static let maximumItemBytes = 20_000_000
    static let trashDays = 7
}

enum RetentionPolicy {
    static func removals(in records: [LibraryRecord], limits: HistoryLimits, now: Date) -> Set<UUID> {
        var removed = Set(records.filter {
            $0.deletedAt.map { $0 <= now.addingTimeInterval(-Double(HistoryLimits.trashDays) * 86_400) } ?? false
        }.map(\.id))
        let history = records.filter { $0.deletedAt == nil && !$0.isProtected }
            .sorted { $0.touchedAt == $1.touchedAt ? $0.id.uuidString < $1.id.uuidString : $0.touchedAt > $1.touchedAt }
        var count = 0
        var bytes = 0
        var capacityReached = false
        for record in history {
            if record.touchedAt <= now.addingTimeInterval(-Double(limits.days) * 86_400)
                || capacityReached || count >= limits.count || record.byteCount > limits.bytes - bytes {
                removed.insert(record.id)
                capacityReached = true
            } else {
                count += 1
                bytes += record.byteCount
            }
        }
        return removed
    }
}

@MainActor @Observable
final class AppSettings {
    @ObservationIgnored let defaults: UserDefaults
    var historyDays: Int { didSet { defaults.set(historyDays, forKey: "historyDays") } }
    var historyCount: Int { didSet { defaults.set(historyCount, forKey: "historyCount") } }
    var historyMegabytes: Int { didSet { defaults.set(historyMegabytes, forKey: "historyMegabytes") } }
    var hotKeyCode: UInt32 { didSet { defaults.set(Int(hotKeyCode), forKey: "hotKeyCode") } }
    var hotKeyModifiers: UInt32 { didSet { defaults.set(Int(hotKeyModifiers), forKey: "hotKeyModifiers") } }
    var hotKeyLabel: String { didSet { defaults.set(hotKeyLabel, forKey: "hotKeyLabel") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        historyDays = defaults.object(forKey: "historyDays").map { _ in min(3650, max(1, defaults.integer(forKey: "historyDays"))) } ?? 30
        historyCount = defaults.object(forKey: "historyCount").map { _ in min(100_000, max(1, defaults.integer(forKey: "historyCount"))) } ?? 1000
        historyMegabytes = defaults.object(forKey: "historyMegabytes").map { _ in min(100_000, max(1, defaults.integer(forKey: "historyMegabytes"))) } ?? 1000
        hotKeyCode = UInt32(clamping: defaults.object(forKey: "hotKeyCode") == nil ? 49 : defaults.integer(forKey: "hotKeyCode"))
        hotKeyModifiers = UInt32(clamping: defaults.object(forKey: "hotKeyModifiers") == nil ? 6144 : defaults.integer(forKey: "hotKeyModifiers"))
        hotKeyLabel = defaults.string(forKey: "hotKeyLabel") ?? "⌃⌥Space"
    }
    var limits: HistoryLimits { HistoryLimits(days: historyDays, count: historyCount, bytes: historyMegabytes * 1_000_000) }
}
