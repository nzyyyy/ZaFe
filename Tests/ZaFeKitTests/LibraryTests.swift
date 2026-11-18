import AppKit
import SwiftData
import Testing
@testable import ZaFeKit

private final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { values[key] }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
}

@MainActor
private struct TestLibrary {
    let root: URL
    let settings = AppSettings(defaults: MemoryDefaults())
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("ZaFeTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func store(inMemory: Bool = true) throws -> LibraryStore {
        try LibraryStore(directory: root.appendingPathComponent("Library"), settings: settings, inMemory: inMemory)
    }
    func file(_ name: String = "example.txt", text: String = "original") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

@Suite(.serialized) @MainActor
struct LibraryTests {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func quickPanelTransparencyDefaultsPersistsAndValidatesStoredValues() {
        let defaults = MemoryDefaults()
        let settings = AppSettings(defaults: defaults)
        #expect(settings.quickPanelTransparency == 0.65)
        for value in [0.0, 0.42, 1.0] {
            settings.quickPanelTransparency = value
            #expect(AppSettings(defaults: defaults).quickPanelTransparency == value)
        }
        for (stored, expected) in [(-0.5, 0.0), (1.5, 1.0), (.nan, 0.65), (.infinity, 0.65), (-.infinity, 0.65)] {
            defaults.set(stored, forKey: "quickPanelTransparency")
            #expect(AppSettings(defaults: defaults).quickPanelTransparency == expected)
        }
        defaults.set("invalid", forKey: "quickPanelTransparency")
        #expect(AppSettings(defaults: defaults).quickPanelTransparency == 0.65)
    }

    @Test func duplicateClipboardUpdatesExistingButNeverMergesNotes() throws {
        let library = try TestLibrary(); defer { library.clean() }
        let store = try library.store()
        let first = try store.capture(.text("hello"), now: now)
        #expect(first.lastCopiedAt == now)
        let note = try #require(store.newNote())
        #expect(note.lastCopiedAt == nil)
        store.updateNote(note, body: "hello")
        let next = try store.capture(.text("hello"), now: now.addingTimeInterval(5))
        #expect(first.id == next.id)
        #expect(next.touchedAt == now.addingTimeInterval(5))
        #expect(next.lastCopiedAt == now.addingTimeInterval(5))
        #expect(store.records.count == 2)
        #expect(note.body == "hello")
        store.delete(next)
        let replacement = try store.capture(.text("hello"), now: now.addingTimeInterval(10))
        #expect(replacement.id != first.id)
    }

    @Test func clipboardCopyTimeSurvivesRestoreAndReopening() throws {
        let library = try TestLibrary(); defer { library.clean() }
        let firstCopy = Date.now.addingTimeInterval(-60)
        let lastCopy = firstCopy.addingTimeInterval(10)
        try autoreleasepool {
            let store = try library.store(inMemory: false)
            try store.capture(.text("重复文本"), now: firstCopy)
            let record = try store.capture(.text("重复文本"), now: lastCopy)
            store.setFavorite(record, true)
            store.delete(record)
            store.restore(record)
            #expect(record.touchedAt > lastCopy)
            #expect(record.lastCopiedAt == lastCopy)

            let legacy = try store.capture(.text("旧记录"), now: firstCopy)
            legacy.lastCopiedAt = nil
            store.setFavorite(legacy, true)
            store.delete(legacy)
            store.restore(legacy)
            #expect(legacy.lastCopiedAt == firstCopy)
        }
        try autoreleasepool {
            let store = try library.store(inMemory: false)
            #expect(store.records.count == 2)
            #expect(store.records.first { $0.body == "重复文本" }?.lastCopiedAt == lastCopy)
            #expect(store.records.first { $0.body == "旧记录" }?.lastCopiedAt == firstCopy)
        }
    }

    @Test func cleanupEnforcesAgeCountAndBytesAndProtectsManualContent() throws {
        let old = try LibraryRecord(kind: .text, isClipboard: true, body: "old", byteCount: 1, now: now.addingTimeInterval(-31 * 86_400))
        let recent = try LibraryRecord(kind: .text, isClipboard: true, body: "new", byteCount: 6, now: now)
        let older = try LibraryRecord(kind: .text, isClipboard: true, body: "older", byteCount: 5, now: now.addingTimeInterval(-1))
        let oldest = try LibraryRecord(kind: .text, isClipboard: true, body: "oldest", byteCount: 1, now: now.addingTimeInterval(-2))
        let favorite = try LibraryRecord(kind: .image, isClipboard: true, byteCount: 1_000_000, now: old.createdAt)
        favorite.isFavorite = true
        let note = try LibraryRecord(kind: .note, isClipboard: false, body: "keep", now: old.createdAt)
        let file = try LibraryRecord(kind: .files, isClipboard: false, now: old.createdAt)
        let records = [old, recent, older, oldest, favorite, note, file]
        #expect(RetentionPolicy.removals(in: records, limits: HistoryLimits(), now: now) == [old.id])
        #expect(RetentionPolicy.removals(in: records, limits: HistoryLimits(count: 1), now: now) == [old.id, older.id, oldest.id])
        #expect(RetentionPolicy.removals(in: records, limits: HistoryLimits(bytes: 10), now: now) == [old.id, older.id, oldest.id])
    }

    @Test func deletingAndRestoringProtectedItemsAndExpiringTrash() throws {
        let library = try TestLibrary(); defer { library.clean() }
        let store = try library.store()
        let note = try #require(store.newNote())
        store.updateNote(note, title: "keep", body: "important")
        store.delete(note, now: now)
        #expect(store.visibleRecords(query: "", filter: .notes).isEmpty)
        #expect(store.visibleRecords(query: "", filter: .trash).count == 1)
        store.restore(note)
        #expect(note.deletedAt == nil)
        #expect(note.body == "important")
        store.delete(note, now: now)
        store.cleanup(now: now.addingTimeInterval(7 * 86_400))
        #expect(store.records.isEmpty)
    }

    @Test func ordinaryHistoryIsDeletedImmediatelyAndFavoriteGoesToTrash() throws {
        let library = try TestLibrary(); defer { library.clean() }
        let store = try library.store()
        let ordinary = try store.capture(.text("temporary"), now: now)
        store.delete(ordinary)
        #expect(store.records.isEmpty)
        let favorite = try store.capture(.text("saved"), now: now)
        store.setFavorite(favorite, true)
        store.delete(favorite, now: now)
        #expect(store.records.count == 1)
        #expect(favorite.deletedAt == now)
    }

    @Test func cancellingFavoriteReappliesRetention() throws {
        let library = try TestLibrary(); defer { library.clean() }
        let store = try library.store()
        let record = try store.capture(.text("keep"))
        store.setFavorite(record, true)
        record.touchedAt = Date.now.addingTimeInterval(-31 * 86_400)
        #expect(store.flush())
        store.cleanup()
        #expect(store.records.count == 1)
        store.setFavorite(record, false)
        #expect(store.records.isEmpty)
    }

    @Test func savedNotesAndImagesSurviveReopening() throws {
        let library = try TestLibrary(); defer { library.clean() }
        var noteID: UUID!
        var imageID: UUID!
        let png = try samplePNG()
        try autoreleasepool {
            let store = try library.store(inMemory: false)
            let note = try #require(store.newNote())
            store.updateNote(note, title: "标题", body: "长期内容\n第二行")
            noteID = note.id
            let image = try store.capture(.image(png))
            store.setFavorite(image, true)
            imageID = image.id
        }
        try autoreleasepool {
            let store = try library.store(inMemory: false)
            let note = try #require(store.records.first { $0.id == noteID })
            #expect(note.title == "标题")
            #expect(note.body == "长期内容\n第二行")
            store.updateNote(note, title: "修改后的标题", body: "再次编辑\n保留换行")
            let image = try #require(store.records.first { $0.id == imageID })
            #expect(try store.imageData(for: image) == png)
        }
        try autoreleasepool {
            let store = try library.store(inMemory: false)
            let note = try #require(store.records.first { $0.id == noteID })
            #expect(note.title == "修改后的标题")
            #expect(note.body == "再次编辑\n保留换行")
        }
    }

    @Test func failedImageWriteLeavesNoRecordOrAttachment() throws {
        let library = try TestLibrary(); defer { library.clean() }
        let directory = library.root.appendingPathComponent("Library")
        let store = try LibraryStore(directory: directory, settings: library.settings, inMemory: true) { data, url in
            try data.write(to: url)
            throw CocoaError(.fileWriteOutOfSpace)
        }
        #expect(throws: (any Error).self) { try store.capture(.image(try samplePNG())) }
        #expect(store.records.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Images").path).isEmpty)
    }

    @Test func imageDeletionOnlyPurgesAttachmentAfterPermanentDelete() throws {
        let library = try TestLibrary(); defer { library.clean() }
        let store = try library.store()
        let record = try store.capture(.image(try samplePNG()))
        let url = try #require(store.imageURL(for: record))
        store.setFavorite(record, true)
        store.delete(record)
        #expect(FileManager.default.fileExists(atPath: url.path))
        store.restore(record)
        #expect(try store.imageData(for: record) == samplePNG())
        store.permanentlyDelete([record])
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func missingFileCanBeReassociatedAndDeletingReferenceKeepsOriginal() throws {
        let library = try TestLibrary(); defer { library.clean() }
        let store = try library.store()
        let original = try library.file()
        let record = try #require(store.addFiles([original]))
        let reference = try #require(record.references.first)
        try FileManager.default.removeItem(at: original)
        #expect(throws: (any Error).self) { try store.resolvedFiles(for: record) }
        #expect(record.references.first?.path == original.path)
        let replacement = try library.file("replacement.txt")
        store.relocate(record, referenceID: reference.id, to: replacement)
        let resolved = try store.resolvedFiles(for: record)
        #expect(resolved.first?.path == replacement.path)
        #expect(record.references.first?.id == reference.id)
        store.delete(record)
        store.permanentlyDelete([record])
        #expect(try String(contentsOf: replacement, encoding: .utf8) == "original")
    }

    @Test func movedFileBookmarkFindsOriginalAndRefreshesPath() throws {
        let library = try TestLibrary(); defer { library.clean() }
        let store = try library.store()
        let original = try library.file()
        let record = try #require(store.addFiles([original]))
        let moved = library.root.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: original, to: moved)
        let resolved = try store.resolvedFiles(for: record)
        #expect(resolved.first?.path == moved.path)
        #expect(record.references.first?.path == moved.path)
    }

    @Test func searchIncludesTextTitlesAndPathsButNotTrash() throws {
        let library = try TestLibrary(); defer { library.clean() }
        let store = try library.store()
        let note = try #require(store.newNote())
        store.updateNote(note, title: "旅行", body: "Café\nbooking")
        #expect(store.visibleRecords(query: "cafe", filter: .notes).count == 1)
        #expect(store.visibleRecords(query: "旅行", filter: .all).count == 1)
        let file = try library.file("project.pdf")
        _ = store.addFiles([file])
        #expect(store.visibleRecords(query: "project.pdf", filter: .files).count == 1)
        #expect(store.visibleRecords(query: library.root.path, filter: .files).count == 1)
        store.delete(note)
        #expect(store.visibleRecords(query: "旅行", filter: .all).isEmpty)
        #expect(store.visibleRecords(query: "旅行", filter: .trash).count == 1)
    }

    @Test func duplicateManualFilesRemainSeparateFromTemporaryClipboardHistory() throws {
        let library = try TestLibrary(); defer { library.clean() }
        let store = try library.store()
        let url = try library.file()
        let first = try #require(store.addFiles([url]))
        let second = try #require(store.addFiles([url]))
        #expect(first.id == second.id)
        let history = try store.capture(.files([url]))
        #expect(first.id != history.id)
        store.delete(history)
        #expect(store.records.count == 1)
        #expect(first.isProtected)
    }

    @Test func oversizedOrInvalidImagesNeverEnterLibrary() throws {
        let library = try TestLibrary(); defer { library.clean() }
        let store = try library.store()
        #expect(throws: (any Error).self) { try store.capture(.text(String(repeating: "a", count: HistoryLimits.maximumItemBytes + 1))) }
        #expect(throws: (any Error).self) { try store.capture(.image(Data(repeating: 1, count: HistoryLimits.maximumItemBytes + 1))) }
        #expect(throws: (any Error).self) { try store.capture(.image(Data("invalid".utf8))) }
        #expect(store.records.isEmpty)
    }

    @Test func clipboardChangeTrackerSuppressesOwnWritesAndAllowsLaterUserCopies() {
        var tracker = ClipboardChangeTracker(initialCount: 1)
        #expect(tracker.shouldCapture(changeCount: 1) == false)
        #expect(tracker.shouldCapture(changeCount: 2) == true)
        tracker.didWrite(changeCount: 3)
        #expect(tracker.shouldCapture(changeCount: 3) == false)
        #expect(tracker.shouldCapture(changeCount: 4) == true)
        #expect(tracker.shouldCapture(changeCount: 4) == false)
    }

    @Test func clipboardRoundTripSupportsTextImageAndFileGroups() throws {
        let library = try TestLibrary(); defer { library.clean() }
        let store = try library.store()
        let pasteboard = NSPasteboard(name: .init("ZaFeTests-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)
        let text = try store.capture(.text("text\n链接 https://example.com"))
        #expect(monitor.copy(text))
        #expect(pasteboard.string(forType: .string) == text.body)
        if case .text(let value) = try ClipboardMonitor.read(from: pasteboard) { #expect(value == text.body) }
        else { Issue.record("Expected a text clipboard snapshot") }
        monitor.poll()
        #expect(store.records.count == 1)
        let png = try samplePNG()
        let image = try store.capture(.image(png))
        #expect(monitor.copy(image))
        #expect(pasteboard.data(forType: .png) == png)
        if case .image(let data) = try ClipboardMonitor.read(from: pasteboard) { #expect(data == png) }
        else { Issue.record("Expected an image clipboard snapshot") }
        let folder = library.root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = try [library.file("文件 with spaces.txt"), library.file("two.txt"), folder]
        let files = try store.capture(.files(urls))
        let copiedFiles = monitor.copy(files)
        #expect(copiedFiles)
        let pasted = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        #expect(pasted?.map { $0.standardizedFileURL.resolvingSymlinksInPath().path } == urls.map(\.path))
        if case .files(let files) = try ClipboardMonitor.read(from: pasteboard) {
            #expect(files.map { $0.standardizedFileURL.resolvingSymlinksInPath().path } == urls.map(\.path))
        } else { Issue.record("Expected a grouped file clipboard snapshot") }
        #expect(monitor.copy(files, pathsOnly: true))
        #expect(pasteboard.string(forType: .string) == urls.map(\.path).joined(separator: "\n"))
    }

    @Test func quickNotesStayInPanelAndEditingKeysDoNotActivateListActions() throws {
        let application = NSApplication.shared
        let library = try TestLibrary(); defer { library.clean() }
        let store = try library.store()
        let pasteboard = NSPasteboard(name: .init("ZaFeTests-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("保留剪贴板", forType: .string)
        let existingWindows = Set(application.windows.map(ObjectIdentifier.init))
        let controller = AppController(store: store, settings: library.settings, pasteboard: pasteboard)
        controller.clipboard.stop()
        defer {
            controller.stop()
            for window in application.windows where !existingWindows.contains(ObjectIdentifier(window)) { window.close() }
        }
        controller.newNote()
        let note = try #require(controller.quickDetail)
        let windows = application.windows.filter { !existingWindows.contains(ObjectIdentifier($0)) }
        #expect(windows.count == 1)
        let panel = try #require(windows.first as? QuickPanel)
        #expect(panel.isVisible)
        try #require(application.keyWindow === panel)
        #expect(controller.quickSelection == note.id)
        for adjusting in [false, true] {
            controller.isAdjustingPanelAppearance = adjusting
            for code: UInt16 in [36, 76, 125, 126] {
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                        windowNumber: panel.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code))
                #expect(controller.handleKey(event) === event)
                #expect(controller.quickDetail?.id == note.id)
            }
        }
        let appearanceEscape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                           windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        #expect(controller.handleKey(appearanceEscape) == nil)
        #expect(!controller.isAdjustingPanelAppearance)
        #expect(controller.quickDetail?.id == note.id)
        store.updateNote(note, title: "标题", body: "正文\n第二行")
        controller.closeQuickDetail()
        #expect(controller.quickDetail == nil)
        #expect(panel.isVisible)
        controller.activateFromQuick(note)
        #expect(controller.quickDetail?.body == "正文\n第二行")
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        #expect(controller.handleKey(escape) == nil)
        #expect(controller.quickDetail == nil)
        #expect(panel.isVisible)
        controller.showQuickDetail(note)
        store.delete(note)
        #expect(controller.quickDetail == nil)
        #expect(store.visibleRecords(query: "", filter: .notes).isEmpty)
        #expect(store.visibleRecords(query: "", filter: .trash).first?.id == note.id)
        #expect(pasteboard.string(forType: .string) == "保留剪贴板")
    }

    @Test func clipboardDetailsStayInPanelAndListReturnCopies() throws {
        let application = NSApplication.shared
        let library = try TestLibrary(); defer { library.clean() }
        let store = try library.store()
        let text = try store.capture(.text("标题\n完整正文"))
        let image = try store.capture(.image(samplePNG()))
        let files = try store.capture(.files([library.file()]))
        let pasteboard = NSPasteboard(name: .init("ZaFeTests-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("保留剪贴板", forType: .string)
        let changeCount = pasteboard.changeCount
        let controller = AppController(store: store, settings: library.settings, pasteboard: pasteboard)
        controller.clipboard.stop()
        defer {
            controller.stop()
            for window in application.windows where window.delegate === controller { window.close() }
        }
        controller.isPinned = true
        controller.toggleQuickPanel()
        let panel = try #require(application.windows.first { $0 is QuickPanel && $0.delegate === controller })
        controller.quickFilter = .clipboard
        for record in [image, files] {
            controller.showQuickDetail(record)
            #expect(controller.quickDetail?.id == record.id)
            #expect(panel.isVisible)
            #expect(pasteboard.changeCount == changeCount)
            controller.closeQuickDetail()
            #expect(controller.quickDetail == nil)
        }

        controller.quickQuery = "完整正文"
        controller.showQuickDetail(text)
        #expect(controller.quickDetail?.id == text.id)
        #expect(application.windows.filter { $0.delegate === controller } == [panel])
        #expect(pasteboard.string(forType: .string) == "保留剪贴板")
        try #require(application.keyWindow === panel)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: panel.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        #expect(controller.handleKey(enter) === enter)
        #expect(pasteboard.changeCount == changeCount)
        #expect(controller.handleKey(escape) == nil)
        #expect(controller.quickDetail == nil)
        #expect(controller.quickSelection == text.id)
        #expect(controller.quickFilter == .clipboard)
        #expect(controller.quickQuery == "完整正文")
        #expect(panel.isVisible)
        #expect(controller.handleKey(enter) == nil)
        #expect(pasteboard.string(forType: .string) == text.body)

        controller.showQuickDetail(text)
        store.delete(text)
        #expect(controller.quickDetail == nil)
        #expect(panel.isVisible)
    }

    @Test func quickPanelFrameValidationAndScreenConstraints() {
        let defaults = MemoryDefaults()
        #expect(QuickPanel.savedFrame(in: defaults) == nil)
        for value in ["invalid", "{{0, 0}, {0, 600}}", "{{nan, 0}, {460, 600}}", "{{0, 0}, {-460, 600}}"] {
            defaults.set(value, forKey: QuickPanel.frameKey)
            #expect(QuickPanel.savedFrame(in: defaults) == nil)
        }
        let main = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let secondary = NSRect(x: -1280, y: 100, width: 1280, height: 800)
        let frame = NSRect(x: -1000, y: 200, width: 600, height: 650)
        defaults.set(NSStringFromRect(frame), forKey: QuickPanel.frameKey)
        #expect(QuickPanel.savedFrame(in: defaults) == frame)
        #expect(QuickPanel.constrainedFrame(frame, visibleFrames: [main, secondary], fallback: main) == frame)
        let recovered = QuickPanel.constrainedFrame(frame, visibleFrames: [main], fallback: main)
        #expect(main.insetBy(dx: 8, dy: 8).contains(recovered))
        #expect(recovered.size == frame.size)
        let oversized = QuickPanel.constrainedFrame(NSRect(x: -50, y: -50, width: 3000, height: 2000), visibleFrames: [main], fallback: main)
        #expect(oversized == main.insetBy(dx: 8, dy: 8))
        let small = QuickPanel.constrainedFrame(NSRect(x: 200, y: 200, width: 100, height: 100), visibleFrames: [main], fallback: main)
        #expect(small.size == QuickPanel.minimumSize)
        let partial = QuickPanel.constrainedFrame(NSRect(x: 1300, y: 800, width: 460, height: 600), visibleFrames: [main], fallback: main)
        #expect(main.insetBy(dx: 8, dy: 8).contains(partial))
    }

    @Test func quickPanelRestoresFrameWithoutAutomaticallySelectingRecords() throws {
        let application = NSApplication.shared
        let library = try TestLibrary(); defer { library.clean() }
        let store = try library.store()
        _ = try store.capture(.text("first"))
        _ = try store.capture(.text("second"))
        let pasteboard = NSPasteboard(name: .init("ZaFeTests-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let existingWindows = Set(application.windows.map(ObjectIdentifier.init))
        defer {
            for window in application.windows where !existingWindows.contains(ObjectIdentifier(window)) { window.close() }
        }
        let screen = try #require(NSScreen.main).visibleFrame
        let target = QuickPanel.constrainedFrame(NSRect(x: screen.midX - 260, y: screen.midY - 240, width: 520, height: 480),
                                                visibleFrames: [screen], fallback: screen)
        do {
            let controller = AppController(store: store, settings: library.settings, pasteboard: pasteboard)
            controller.clipboard.stop()
            defer { controller.stop() }
            controller.toggleQuickPanel()
            #expect(controller.quickSelection == nil)
            controller.moveQuickSelection(1)
            #expect(controller.quickSelection == controller.quickRecords.first?.id)
            controller.moveQuickSelection(1)
            #expect(controller.quickSelection == controller.quickRecords.last?.id)
            controller.moveQuickSelection(-1)
            #expect(controller.quickSelection == controller.quickRecords.first?.id)
            let panel = try #require(application.windows.first { $0 is QuickPanel && $0.delegate === controller })
            #expect(panel.styleMask.contains(.resizable))
            #expect(!panel.isOpaque)
            #expect(panel.backgroundColor == .clear)
            #expect(panel.alphaValue == 1)
            let glass = try #require(panel.contentView as? NSGlassEffectView)
            #expect(glass.style == .clear)
            #expect(glass.cornerRadius == QuickPanel.cornerRadius)
            let content = try #require(glass.contentView)
            #expect(!content.isOpaque)
            #expect(content.alphaValue == 1)
            panel.setFrame(target, display: false)
            panel.contentView?.layoutSubtreeIfNeeded()
            #expect(content.frame == glass.bounds)
            controller.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: panel))
            #expect(QuickPanel.savedFrame(in: library.settings.defaults) == target)
            controller.newNote()
            #expect(panel.frame == target)
            controller.closeQuickDetail()
            #expect(panel.frame == target)
            controller.isAdjustingPanelAppearance = true
            library.settings.quickPanelTransparency = 0.42
            let selection = controller.quickSelection
            for code: UInt16 in [36, 76, 123, 124, 125, 126] {
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                        windowNumber: panel.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code))
                #expect(controller.handleKey(event) === event)
                #expect(controller.quickSelection == selection)
                #expect(panel.isVisible)
                #expect(pasteboard.types?.isEmpty != false)
            }
            let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            #expect(controller.handleKey(escape) == nil)
            #expect(!controller.isAdjustingPanelAppearance)
            #expect(panel.isVisible)
            let down = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125))
            #expect(controller.handleKey(down) == nil)
            #expect(controller.quickSelection == controller.quickRecords.first?.id)
            controller.isAdjustingPanelAppearance = true
            controller.closeQuickPanel(returnFocus: false)
            #expect(!controller.isAdjustingPanelAppearance)
            controller.toggleQuickPanel()
            #expect(!controller.isAdjustingPanelAppearance)
            #expect(panel.frame == target)
            #expect(controller.quickSelection == nil)
            controller.closeQuickPanel(returnFocus: false)
        }
        let settings = AppSettings(defaults: library.settings.defaults)
        #expect(settings.quickPanelTransparency == 0.42)
        let controller = AppController(store: store, settings: settings, pasteboard: pasteboard)
        controller.clipboard.stop()
        defer { controller.stop() }
        controller.toggleQuickPanel()
        #expect(controller.quickSelection == nil)
        let panel = try #require(application.windows.first { $0 is QuickPanel && $0.delegate === controller })
        #expect(panel.frame == target)
        controller.closeQuickPanel(returnFocus: false)
    }

    @Test func notesDoNotWriteToClipboard() throws {
        let library = try TestLibrary(); defer { library.clean() }
        let store = try library.store()
        let note = try #require(store.newNote())
        let pasteboard = NSPasteboard(name: .init("ZaFeTests-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard, accessPolicy: { .allowed })
        pasteboard.setString("保留剪贴板", forType: .string)
        let changeCount = pasteboard.changeCount
        store.updateNote(note, title: "标题", body: "正文\n第二行")
        #expect(!monitor.copy(note))
        #expect(pasteboard.changeCount == changeCount)
        #expect(pasteboard.string(forType: .string) == "保留剪贴板")
    }

    @Test func invalidCopyDoesNotEraseCurrentClipboard() throws {
        let library = try TestLibrary(); defer { library.clean() }
        let store = try library.store()
        let pasteboard = NSPasteboard(name: .init("ZaFeTests-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("keep clipboard", forType: .string)
        let file = try library.file()
        let record = try #require(store.addFiles([file]))
        try FileManager.default.removeItem(at: file)
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)
        #expect(!monitor.copy(record))
        #expect(pasteboard.string(forType: .string) == "keep clipboard")
    }

    @Test func unreadableFileCopyPreservesClipboardAndRecoversWhenAccessReturns() throws {
        let library = try TestLibrary(); defer { library.clean() }
        let store = try library.store()
        let file = try library.file()
        let record = try #require(store.addFiles([file]))
        let pasteboard = NSPasteboard(name: .init("ZaFeTests-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("keep clipboard", forType: .string)
        let changeCount = pasteboard.changeCount
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard, accessPolicy: { .allowed })
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        try #require(!FileManager.default.isReadableFile(atPath: file.path))
        let copiedWithoutAccess = monitor.copy(record)
        #expect(!copiedWithoutAccess)
        #expect(pasteboard.changeCount == changeCount)
        #expect(pasteboard.string(forType: .string) == "keep clipboard")
        #expect(store.notice != nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(monitor.copy(record))
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        #expect(urls?.map { $0.standardizedFileURL.resolvingSymlinksInPath().path } == [file.path])
        monitor.poll()
        #expect(store.records.count == 1)
    }

    @Test func deniedAndAskPoliciesNeverReadAutomaticallyAndCanRecover() throws {
        let library = try TestLibrary(); defer { library.clean() }
        let store = try library.store()
        let pasteboard = NSPasteboard(name: .init("ZaFeTests-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        var policy: ClipboardMonitor.AccessPolicy = .denied
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard, accessPolicy: { policy })
        pasteboard.clearContents()
        pasteboard.setString("not yet", forType: .string)
        monitor.poll()
        #expect(monitor.state == .denied)
        #expect(store.records.isEmpty)
        policy = .ask
        monitor.poll()
        #expect(monitor.state == .needsConsent)
        #expect(store.records.isEmpty)
        policy = .allowed
        monitor.poll()
        #expect(monitor.state == .running)
        #expect(store.records.first?.body == "not yet")
    }

    @Test func hotKeyConflictPreservesPreviousRegistration() throws {
        let first = GlobalHotKey()
        let second = GlobalHotKey()
        let probe = GlobalHotKey()
        defer { first.stop(); second.stop(); probe.stop() }
        try first.register(code: 79, modifiers: 6912)
        try second.register(code: 80, modifiers: 6912)
        #expect(throws: (any Error).self) { try second.register(code: 79, modifiers: 6912) }
        #expect(throws: (any Error).self) { try probe.register(code: 80, modifiers: 6912) }
        second.stop()
        try probe.register(code: 80, modifiers: 6912)
    }

    @Test func hotKeyRecorderUsesStandardButtonActionAndDoesNotPostKeyboardEvents() throws {
        let button = RecorderButton(frame: .zero)
        button.label = "⌃⌥Space"
        var captured: HotKeyCombination?
        button.onChange = { captured = $0; return true }
        button.performClick(nil)
        #expect(button.recording)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .option], timestamp: 0,
                                                windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        button.keyDown(with: event)
        #expect(captured?.code == 49)
        #expect(captured?.modifiers == 6144)
        #expect(captured?.label == "⌃⌥Space")
        #expect(!button.recording)
    }

    private func samplePNG() throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
        rep.bitmapData?.initialize(repeating: 255, count: 16)
        return try #require(rep.representation(using: .png, properties: [:]))
    }
}
