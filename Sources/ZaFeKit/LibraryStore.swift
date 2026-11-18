import AppKit
import CryptoKit
import ImageIO
import Observation
import SwiftData

enum ClipboardPayload {
    case text(String)
    case image(Data)
    case files([URL])

    var kind: RecordKind {
        switch self { case .text: .text; case .image: .image; case .files: .files }
    }
    var fingerprint: String {
        let data: Data
        switch self {
        case .text(let text): data = Data(text.utf8)
        case .image(let bytes): data = bytes
        case .files(let urls): data = (try? JSONEncoder().encode(urls.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })) ?? Data()
        }
        return kind.rawValue + ":" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor @Observable
final class LibraryStore {
    private(set) var records: [LibraryRecord] = []
    var notice: String?
    let settings: AppSettings
    @ObservationIgnored let container: ModelContainer
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored let directory: URL
    @ObservationIgnored private let writeImage: (Data, URL) throws -> Void

    init(directory: URL, settings: AppSettings, inMemory: Bool = false,
         writeImage: @escaping (Data, URL) throws -> Void = { data, url in try data.write(to: url, options: .atomic) }) throws {
        self.settings = settings
        self.directory = directory
        self.writeImage = writeImage
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Images"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let configuration = ModelConfiguration(url: directory.appendingPathComponent("Library.store"), allowsSave: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: LibraryRecord.self, configurations: inMemory
            ? ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none) : configuration)
        context = ModelContext(container)
        context.autosaveEnabled = false
        try reload()
        cleanup()
        removeOrphanedImages()
    }

    static func applicationDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("ZaFe", isDirectory: true)
    }

    func visibleRecords(query: String, filter: LibraryFilter) -> [LibraryRecord] {
        records.filter { $0.matches(query, filter: filter) }.sorted {
            let lhs = filter == .trash ? $0.deletedAt ?? $0.touchedAt : $0.touchedAt
            let rhs = filter == .trash ? $1.deletedAt ?? $1.touchedAt : $1.touchedAt
            return lhs == rhs ? $0.id.uuidString < $1.id.uuidString : lhs > rhs
        }
    }

    @discardableResult
    func flush() -> Bool {
        do { try context.save(); return true }
        catch { notice = "保存失败：\(error.localizedDescription)"; return false }
    }

    private func reload() throws {
        records = try context.fetch(FetchDescriptor<LibraryRecord>(sortBy: [SortDescriptor(\.touchedAt, order: .reverse)]))
    }

    @discardableResult
    private func change(_ action: () throws -> Void) -> Bool {
        guard flush() else { return false }
        do {
            try action()
            try context.save()
            do { try reload() }
            catch { notice = "已保存，但列表刷新失败：\(error.localizedDescription)" }
            return true
        } catch {
            context.rollback()
            try? reload()
            notice = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func capture(_ payload: ClipboardPayload, now: Date = .now) throws -> LibraryRecord {
        guard flush() else { throw CocoaError(.fileWriteUnknown) }
        switch payload {
        case .text(let text):
            guard text.utf8.count <= HistoryLimits.maximumItemBytes else { throw LibraryError.tooLarge }
            guard !text.isEmpty else { throw LibraryError.emptyClipboard }
        case .image(let data):
            guard data.count <= HistoryLimits.maximumItemBytes else { throw LibraryError.tooLarge }
            try Self.validateImage(data)
        case .files(let urls):
            guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { throw LibraryError.invalidFile }
        }
        let fingerprint = payload.fingerprint
        if let existing = records.first(where: { $0.isClipboard && $0.deletedAt == nil && $0.fingerprint == fingerprint }) {
            let previousTouchedAt = existing.touchedAt
            let previousCopiedAt = existing.lastCopiedAt
            existing.touchedAt = now
            existing.lastCopiedAt = now
            do { try context.save() }
            catch {
                existing.touchedAt = previousTouchedAt
                existing.lastCopiedAt = previousCopiedAt
                throw error
            }
            cleanup(now: now)
            return existing
        }

        var attachment: URL?
        do {
            let record: LibraryRecord
            switch payload {
            case .text(let text):
                record = try LibraryRecord(kind: .text, isClipboard: true, body: text, fingerprint: fingerprint, byteCount: text.utf8.count, now: now)
            case .image(let data):
                let name = UUID().uuidString + ".image"
                let url = try imageURL(name: name)
                attachment = url
                try writeImage(data, url)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                record = try LibraryRecord(kind: .image, isClipboard: true, imageName: name, fingerprint: fingerprint, byteCount: data.count, now: now)
            case .files(let urls):
                let references = try urls.map { try FileReference(url: $0) }
                record = try LibraryRecord(kind: .files, isClipboard: true, references: references, fingerprint: fingerprint,
                                           byteCount: try JSONEncoder().encode(references).count, now: now)
            }
            context.insert(record)
            try context.save()
            attachment = nil
            do { try reload() }
            catch {
                records.insert(record, at: 0)
                notice = "已保存，但列表刷新失败：\(error.localizedDescription)"
            }
            cleanup(now: now)
            return record
        } catch {
            context.rollback()
            if let attachment { try? FileManager.default.removeItem(at: attachment) }
            try? reload()
            throw error
        }
    }

    static func validateImage(_ data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16_384, height <= 16_384,
              width <= 40_000_000 / height else { throw LibraryError.invalidImage }
    }

    @discardableResult
    func newNote() -> LibraryRecord? {
        do {
            let record = try LibraryRecord(kind: .note, isClipboard: false)
            return change { context.insert(record) } ? record : nil
        } catch { notice = error.localizedDescription; return nil }
    }

    func updateNote(_ record: LibraryRecord, title: String? = nil, body: String? = nil) {
        guard record.kind == .note, record.deletedAt == nil else { return }
        if let title { record.title = title }
        if let body { record.body = body }
        record.touchedAt = .now
        _ = flush()
    }

    @discardableResult
    func addFiles(_ urls: [URL]) -> LibraryRecord? {
        var last: LibraryRecord?
        var failures = [String]()
        for url in urls {
            do {
                guard url.isFileURL else { throw LibraryError.invalidFile }
                if let existing = records.first(where: {
                    !$0.isClipboard && $0.kind == .files && $0.deletedAt == nil && $0.references.first?.path == url.standardizedFileURL.resolvingSymlinksInPath().path
                }) {
                    if change({ existing.touchedAt = .now }) { last = existing }
                    continue
                }
                let reference = try FileReference(url: url.standardizedFileURL)
                let record = try LibraryRecord(kind: .files, isClipboard: false, references: [reference])
                if change({ context.insert(record) }) { last = record }
                else { failures.append(url.lastPathComponent) }
            } catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        if !failures.isEmpty { notice = "部分文件未添加：" + failures.joined(separator: "；") }
        return last
    }

    func setFavorite(_ record: LibraryRecord, _ value: Bool) {
        guard record.deletedAt == nil else { return }
        if change({ record.isFavorite = value }) { cleanup() }
    }

    func delete(_ record: LibraryRecord, now: Date = .now) {
        guard record.deletedAt == nil else { return }
        if record.isProtected { _ = change { record.deletedAt = now } }
        else { permanentlyDelete([record]) }
    }

    func restore(_ record: LibraryRecord) {
        restore([record.id])
    }

    func restore(_ ids: Set<UUID>) {
        let trashed = trashedRecords(withIDs: ids)
        guard !trashed.isEmpty else { return }
        let now = Date.now
        _ = change {
            for record in trashed {
                if record.isClipboard, record.lastCopiedAt == nil { record.lastCopiedAt = record.touchedAt }
                record.deletedAt = nil
                record.touchedAt = now
            }
        }
    }

    func permanentlyDeleteTrashed(_ ids: Set<UUID>) {
        let trashed = trashedRecords(withIDs: ids)
        if !trashed.isEmpty { permanentlyDelete(trashed) }
    }

    private func trashedRecords(withIDs ids: Set<UUID>) -> [LibraryRecord] {
        records.filter { $0.deletedAt != nil && ids.contains($0.id) }
    }

    func permanentlyDelete(_ records: [LibraryRecord]) {
        let names = records.compactMap(\.imageName)
        guard change({ for record in records { context.delete(record) } }) else { return }
        for name in names {
            do {
                let url = try imageURL(name: name)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            } catch { notice = "图片清理未完成，将在下次启动重试。" }
        }
    }

    func cleanup(now: Date = .now) {
        let ids = RetentionPolicy.removals(in: records, limits: settings.limits, now: now)
        if !ids.isEmpty { permanentlyDelete(records.filter { ids.contains($0.id) }) }
    }

    func imageURL(for record: LibraryRecord) -> URL? {
        guard let name = record.imageName else { return nil }
        return try? imageURL(name: name)
    }

    private func imageURL(name: String) throws -> URL {
        guard name.hasSuffix(".image"), UUID(uuidString: String(name.dropLast(6))) != nil else { throw LibraryError.missingImage }
        return directory.appendingPathComponent("Images", isDirectory: true).appendingPathComponent(name)
    }

    func imageData(for record: LibraryRecord) throws -> Data {
        guard let url = imageURL(for: record) else { throw LibraryError.missingImage }
        return try Data(contentsOf: url)
    }

    private func removeOrphanedImages() {
        let activeNames = Set(records.compactMap(\.imageName))
        do {
            for url in try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("Images"), includingPropertiesForKeys: nil) {
                if !activeNames.contains(url.lastPathComponent), (try? imageURL(name: url.lastPathComponent)) != nil {
                    try FileManager.default.removeItem(at: url)
                }
            }
        } catch { notice = "图片清理未完成：\(error.localizedDescription)" }
    }

    func resolvedFiles(for record: LibraryRecord) throws -> [URL] {
        let references = record.references
        guard !references.isEmpty else { throw LibraryError.invalidFile }
        var refreshed = references
        let urls = try references.enumerated().map { index, reference in
            let result = try reference.resolved()
            if let update = result.refreshed { refreshed[index] = update }
            return result.url
        }
        if refreshed != references {
            let data = try JSONEncoder().encode(refreshed)
            guard change({ record.referencesData = data }) else { throw CocoaError(.fileWriteUnknown) }
        }
        return urls
    }

    func fileIsAvailable(_ reference: FileReference) -> Bool { (try? reference.resolved()) != nil }

    func relocate(_ record: LibraryRecord, referenceID: UUID, to url: URL) {
        do {
            var references = record.references
            guard let index = references.firstIndex(where: { $0.id == referenceID }) else { throw LibraryError.invalidFile }
            var newReference = try FileReference(url: url)
            newReference.id = referenceID
            references[index] = newReference
            let data = try JSONEncoder().encode(references)
            guard change({ record.referencesData = data; record.fingerprint = nil }) else { return }
        } catch { notice = error.localizedDescription }
    }
}
