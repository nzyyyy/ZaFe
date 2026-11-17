import AppKit
import Darwin
import ImageIO
import Observation

struct ClipboardChangeTracker {
    private var lastCount: Int

    init(initialCount: Int) { lastCount = initialCount }
    mutating func didWrite(changeCount: Int) { lastCount = changeCount }
    mutating func shouldCapture(changeCount: Int) -> Bool {
        guard changeCount != lastCount else { return false }
        lastCount = changeCount
        return true
    }
}

@MainActor @Observable
final class ClipboardMonitor {
    enum State: Equatable { case running, needsConsent, denied }
    enum AccessPolicy { case allowed, ask, denied }
    private(set) var state: State = .running
    @ObservationIgnored private let pasteboard: NSPasteboard
    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let accessPolicy: () -> AccessPolicy
    @ObservationIgnored private var tracker: ClipboardChangeTracker
    @ObservationIgnored private var timer: Timer?

    init(store: LibraryStore, pasteboard: NSPasteboard = .general, accessPolicy: (() -> AccessPolicy)? = nil) {
        self.store = store
        self.pasteboard = pasteboard
        tracker = ClipboardChangeTracker(initialCount: pasteboard.changeCount)
        self.accessPolicy = accessPolicy ?? {
            switch pasteboard.accessBehavior {
            case .alwaysDeny: .denied
            case .ask: .ask
            default: .allowed
            }
        }
    }

    func start() {
        updateAccessState()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func updateAccessState() {
        switch accessPolicy() {
        case .denied: state = .denied
        case .ask: state = .needsConsent
        case .allowed: state = .running
        }
    }

    func resumeByUser() {
        updateAccessState()
        if state == .denied {
            store.notice = "剪贴板访问已被系统拒绝，请在系统设置中允许后重试。"
            return
        }
        captureCurrent()
        updateAccessState()
        if state == .needsConsent { store.notice = "后台记录需要在系统设置中允许始终读取剪贴板。" }
        tracker = ClipboardChangeTracker(initialCount: pasteboard.changeCount)
    }

    func poll() {
        updateAccessState()
        guard state == .running, tracker.shouldCapture(changeCount: pasteboard.changeCount) else { return }
        captureCurrent()
    }

    private func captureCurrent() {
        do {
            guard let payload = try Self.read(from: pasteboard) else { return }
            try store.capture(payload)
        } catch { store.notice = error.localizedDescription }
        updateAccessState()
    }

    static func read(from pasteboard: NSPasteboard) throws -> ClipboardPayload? {
        let types = Set(pasteboard.types ?? [])
        if types.contains(.fileURL) {
            guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return nil }
            return .files(urls)
        }
        if let type = [NSPasteboard.PasteboardType.png, .tiff].first(where: { types.contains($0) }) {
            guard let data = pasteboard.data(forType: type) else { return nil }
            guard data.count <= HistoryLimits.maximumItemBytes else { throw LibraryError.tooLarge }
            try LibraryStore.validateImage(data)
            return .image(data)
        }
        let textType: NSPasteboard.PasteboardType = types.contains(.string) ? .string : .URL
        if types.contains(textType), let string = pasteboard.string(forType: textType), !string.isEmpty {
            guard string.utf8.count <= HistoryLimits.maximumItemBytes else { throw LibraryError.tooLarge }
            return .text(string)
        }
        return nil
    }

    @discardableResult
    func copy(_ record: LibraryRecord, pathsOnly: Bool = false) -> Bool {
        do {
            let objects: [NSPasteboardWriting]
            if pathsOnly {
                let paths = try store.resolvedFiles(for: record).map(\.path).joined(separator: "\n")
                objects = [paths as NSString]
            } else {
                switch record.kind {
                case .text: objects = [record.body as NSString]
                case .note: return false
                case .files:
                    let urls = try store.resolvedFiles(for: record)
                    // Opening without reading lets macOS request protected-folder access before sharing the URLs.
                    for url in urls {
                        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
                        guard descriptor >= 0 else {
                            let code: CocoaError.Code = errno == EACCES || errno == EPERM ? .fileReadNoPermission : .fileReadUnknown
                            throw CocoaError(code, userInfo: [NSFilePathErrorKey: url.path])
                        }
                        close(descriptor)
                    }
                    objects = urls.map { $0 as NSURL }
                case .image:
                    let data = try store.imageData(for: record)
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source) else {
                        throw LibraryError.invalidImage
                    }
                    let item = NSPasteboardItem()
                    guard item.setData(data, forType: NSPasteboard.PasteboardType(type as String)) else { throw LibraryError.invalidImage }
                    objects = [item]
                }
            }
            // Validate and load everything before replacing the user's current clipboard.
            pasteboard.clearContents()
            guard pasteboard.writeObjects(objects), pasteboard.pasteboardItems?.count == objects.count else {
                throw CocoaError(.fileWriteUnknown)
            }
            tracker.didWrite(changeCount: pasteboard.changeCount)
            return true
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            store.notice = "无权读取文件。请在系统设置的“隐私与安全性 → 文件与文件夹”中允许 ZaFe 访问，或重新选择该文件。"
            return false
        } catch { store.notice = error.localizedDescription; return false }
    }
}
