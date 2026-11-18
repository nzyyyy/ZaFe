import AppKit
import Observation
import Quartz
import SwiftUI

@MainActor @Observable
final class AppController: NSResponder, NSWindowDelegate, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let store: LibraryStore
    let clipboard: ClipboardMonitor
    let settings: AppSettings
    let loginItems = LoginItemSettings()
    let hotKey = GlobalHotKey()
    var mainFilter: LibraryFilter? = .all
    var mainSelection: UUID?
    var mainQuery = ""
    var quickFilter: LibraryFilter = .all
    var quickQuery = ""
    var quickSelection: UUID?
    private var quickDetailID: UUID?
    var isPinned = false
    var isAdjustingPanelAppearance = false
    @ObservationIgnored private var panel: QuickPanel?
    @ObservationIgnored private var mainWindow: NSWindow?
    @ObservationIgnored private var settingsWindow: NSWindow?
    @ObservationIgnored private var previousApplication: NSRunningApplication?
    @ObservationIgnored private var localKeyMonitor: Any?
    @ObservationIgnored private var cleanupTimer: Timer?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var previewURLs: [URL] = []
    @ObservationIgnored var statusItem: NSStatusItem?

    init(store: LibraryStore, settings: AppSettings, pasteboard: NSPasteboard = .general) {
        self.store = store
        self.settings = settings
        clipboard = ClipboardMonitor(store: store, pasteboard: pasteboard)
        super.init()
        nextResponder = NSApp
        hotKey.onPress = { [weak self] in self?.toggleQuickPanel() }
        do { try hotKey.register(code: settings.hotKeyCode, modifiers: settings.hotKeyModifiers) }
        catch { store.notice = error.localizedDescription }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.handleKey(event) == nil
            }
            return consumed ? nil : event
        }
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.cleanup() }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let processIdentifier = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier,
                  processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated {
                self?.previousApplication = NSRunningApplication(processIdentifier: processIdentifier)
            }
        }
        clipboard.start()
    }

    var quickRecords: [LibraryRecord] { store.visibleRecords(query: quickQuery, filter: quickFilter) }
    var mainRecords: [LibraryRecord] { store.visibleRecords(query: mainQuery, filter: mainFilter ?? .all) }
    var quickDetail: LibraryRecord? {
        guard let quickDetailID else { return nil }
        return store.records.first { $0.id == quickDetailID && $0.deletedAt == nil }
    }

    required init?(coder: NSCoder) { return nil }

    func stop() {
        savePanelFrame()
        hotKey.stop()
        clipboard.stop()
        cleanupTimer?.invalidate()
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    func handleKey(_ event: NSEvent) -> NSEvent? {
        if NSApp.keyWindow === panel {
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            if isAdjustingPanelAppearance {
                if event.keyCode == 53 { isAdjustingPanelAppearance = false; return nil }
                return event
            }
            if quickDetail != nil {
                if event.keyCode == 53 { closeQuickDetail(); return nil }
                return event
            }
            switch event.keyCode {
            case 53: closeQuickPanel(); return nil
            case 125: moveQuickSelection(1); return nil
            case 126: moveQuickSelection(-1); return nil
            case 36, 76:
                if let record = quickRecords.first(where: { $0.id == quickSelection }) ?? quickRecords.first { activateFromQuick(record) }
                return nil
            default: return event
            }
        }
        if NSApp.keyWindow === mainWindow, event.keyCode == 49,
           !(NSApp.keyWindow?.firstResponder is NSTextView),
           let record = store.records.first(where: { $0.id == mainSelection }), record.kind == .files, record.deletedAt == nil {
            preview(record)
            return nil
        }
        return event
    }

    func moveQuickSelection(_ direction: Int) {
        let records = quickRecords
        guard !records.isEmpty else { quickSelection = nil; return }
        let current = records.firstIndex { $0.id == quickSelection } ?? (direction > 0 ? -1 : records.count)
        quickSelection = records[min(records.count - 1, max(0, current + direction))].id
    }

    func toggleQuickPanel() {
        if panel?.isVisible == true { closeQuickPanel(); return }
        showQuickPanel()
    }

    private func showQuickPanel() {
        if panel?.isVisible == true { panel?.makeKeyAndOrderFront(nil); return }
        let savedFrame = QuickPanel.savedFrame(in: settings.defaults)
        if let application = NSWorkspace.shared.frontmostApplication, application.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication = application
        }
        if panel == nil {
            let window = QuickPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 600),
                                    styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
            window.title = "ZaFe"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isFloatingPanel = true
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isMovableByWindowBackground = true
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.minSize = QuickPanel.minimumSize
            window.delegate = self
            window.nextResponder = self
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(button)?.isHidden = true }
            let glass = NSGlassEffectView(frame: window.contentView?.bounds ?? .zero)
            glass.style = .clear
            glass.cornerRadius = QuickPanel.cornerRadius
            let content = NSHostingView(rootView: QuickPanelView(controller: self))
            // The panel draws its own header across the full glass surface.
            content.safeAreaRegions = []
            content.frame = glass.bounds
            content.autoresizingMask = [.width, .height]
            glass.contentView = content
            window.contentView = glass
            panel = window
            if savedFrame == nil { positionPanel() }
        }
        if quickDetail == nil {
            quickQuery = ""
            quickSelection = nil
        }
        if let panel {
            let fallback = statusItem?.button?.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            panel.setFrame(QuickPanel.constrainedFrame(savedFrame ?? panel.frame, visibleFrames: NSScreen.screens.map(\.visibleFrame), fallback: fallback), display: false)
        }
        panel?.makeKeyAndOrderFront(nil)
        savePanelFrame()
        NotificationCenter.default.post(name: .focusQuickSearch, object: nil)
    }

    private func positionPanel() {
        guard let panel else { return }
        if let button = statusItem?.button, let window = button.window {
            let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
            let screen = window.screen ?? NSScreen.main
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let x = min(visible.maxX - panel.frame.width - 10, max(visible.minX + 10, anchor.midX - panel.frame.width / 2))
            panel.setFrameOrigin(NSPoint(x: x, y: visible.maxY - panel.frame.height - 8))
        } else { panel.center() }
    }

    func closeQuickPanel(returnFocus: Bool = true) {
        panel?.makeFirstResponder(nil)
        guard store.flush() else { return }
        savePanelFrame()
        isAdjustingPanelAppearance = false
        panel?.orderOut(nil)
        if returnFocus, let previousApplication, previousApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication.activate()
        }
    }

    func activateFromQuick(_ record: LibraryRecord) {
        if record.kind == .note { showQuickDetail(record) }
        else if clipboard.copy(record), !isPinned { closeQuickPanel() }
    }

    func windowDidResignKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === panel {
            window.makeFirstResponder(nil)
            if !isPinned, store.flush() {
                savePanelFrame()
                isAdjustingPanelAppearance = false
                window.orderOut(nil)
            }
        }
    }

    private func savePanelFrame() {
        guard let panel else { return }
        settings.defaults.set(NSStringFromRect(panel.frame), forKey: QuickPanel.frameKey)
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel, window.isVisible else { return }
        savePanelFrame()
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel, window.isVisible, !window.inLiveResize else { return }
        savePanelFrame()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        savePanelFrame()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.makeFirstResponder(nil)
        return store.flush()
    }

    func showManager() {
        closeQuickPanel(returnFocus: false)
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1140, height: 740),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "ZaFe"
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.minSize = NSSize(width: 880, height: 560)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.nextResponder = self
            window.contentView = NSHostingView(rootView: ManagerView(controller: self))
            window.center()
            mainWindow = window
        }
        NSApp.activate()
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    func showSettings() {
        closeQuickPanel(returnFocus: false)
        loginItems.refresh()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 460),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "设置"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(controller: self))
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func newNote() {
        guard let record = store.newNote() else { return }
        quickFilter = .notes
        quickQuery = ""
        showQuickDetail(record)
    }

    func showQuickDetail(_ record: LibraryRecord) {
        guard record.deletedAt == nil, record.kind == .note || record.isClipboard else { return }
        panel?.makeFirstResponder(nil)
        guard store.flush() else { return }
        quickSelection = record.id
        quickDetailID = record.id
        showQuickPanel()
    }

    func closeQuickDetail() {
        guard let id = quickDetailID else { return }
        if quickDetail != nil {
            panel?.makeFirstResponder(nil)
            guard store.flush() else { return }
        }
        quickDetailID = nil
        quickSelection = quickRecords.contains { $0.id == id } ? id : nil
    }

    func chooseFiles() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = true
        picker.allowsMultipleSelection = true
        picker.prompt = "添加"
        closeQuickPanel(returnFocus: false)
        NSApp.activate()
        picker.begin { [weak self] result in
            guard result == .OK else { return }
            MainActor.assumeIsolated { self?.addFiles(picker.urls) }
        }
    }

    func addFiles(_ urls: [URL]) {
        if let record = store.addFiles(urls) {
            mainFilter = .files
            mainQuery = ""
            mainSelection = record.id
        }
    }

    func pasteFiles() {
        guard let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else {
            store.notice = "剪贴板中没有文件。"
            return
        }
        addFiles(urls)
    }

    func relocate(_ record: LibraryRecord, reference: FileReference) {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = true
        picker.prompt = "重新关联"
        picker.message = reference.name
        picker.begin { [weak self] result in
            guard result == .OK, let url = picker.url else { return }
            MainActor.assumeIsolated { self?.store.relocate(record, referenceID: reference.id, to: url) }
        }
    }

    func openFile(_ record: LibraryRecord) {
        do {
            for url in try store.resolvedFiles(for: record) {
                if !NSWorkspace.shared.open(url) { store.notice = "无法打开 \(url.lastPathComponent)" }
            }
        } catch { store.notice = error.localizedDescription }
    }

    func revealFile(_ record: LibraryRecord) {
        do { NSWorkspace.shared.activateFileViewerSelecting(try store.resolvedFiles(for: record)) }
        catch { store.notice = error.localizedDescription }
    }

    func preview(_ record: LibraryRecord) {
        do {
            previewURLs = try store.resolvedFiles(for: record)
            mainFilter = .files
            mainQuery = ""
            mainSelection = record.id
            showManager()
            guard let previewPanel = QLPreviewPanel.shared() else { return }
            previewPanel.updateController()
            previewPanel.reloadData()
            previewPanel.makeKeyAndOrderFront(nil)
        } catch { store.notice = error.localizedDescription }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { previewURLs[index] as NSURL }

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { !previewURLs.isEmpty }
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = self; panel.delegate = self }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = nil; panel.delegate = nil }
    }

    func changeHotKey(_ combination: HotKeyCombination) -> Bool {
        if settings.hotKeyCode == combination.code && settings.hotKeyModifiers == combination.modifiers { return true }
        do {
            try hotKey.register(code: combination.code, modifiers: combination.modifiers)
            settings.hotKeyCode = combination.code
            settings.hotKeyModifiers = combination.modifiers
            settings.hotKeyLabel = combination.label
            return true
        } catch { store.notice = error.localizedDescription; return false }
    }
}

final class QuickPanel: NSPanel {
    static let minimumSize = NSSize(width: 380, height: 400)
    static let cornerRadius: CGFloat = 12
    static let frameKey = "quickPanelFrame"

    static func savedFrame(in defaults: UserDefaults) -> NSRect? {
        guard let value = defaults.string(forKey: frameKey) else { return nil }
        let frame = NSRectFromString(value)
        guard [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height].allSatisfy(\.isFinite),
              frame.size.width > 0, frame.size.height > 0 else { return nil }
        return frame
    }

    static func constrainedFrame(_ frame: NSRect, visibleFrames: [NSRect], fallback: NSRect) -> NSRect {
        let screen = visibleFrames.max {
            let lhs = $0.intersection(frame), rhs = $1.intersection(frame)
            return (lhs.isNull ? 0 : lhs.width * lhs.height) < (rhs.isNull ? 0 : rhs.width * rhs.height)
        }
        let visible = (screen.flatMap { $0.intersects(frame) ? $0 : nil } ?? fallback).insetBy(dx: 8, dy: 8)
        let size = NSSize(width: min(visible.width, max(minimumSize.width, frame.width)),
                          height: min(visible.height, max(minimumSize.height, frame.height)))
        return NSRect(x: min(max(frame.minX, visible.minX), visible.maxX - size.width),
                      y: min(max(frame.minY, visible.minY), visible.maxY - size.height),
                      width: size.width, height: size.height)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

extension Notification.Name {
    static let focusQuickSearch = Notification.Name("ZaFe.focusQuickSearch")
}

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?
    private var statusItem: NSStatusItem?

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let settings = AppSettings()
            let store = try LibraryStore(directory: LibraryStore.applicationDirectory(), settings: settings)
            let controller = AppController(store: store, settings: settings)
            self.controller = controller
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "ZaFe")
            item.button?.target = self
            item.button?.action = #selector(statusClicked)
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            item.button?.toolTip = "ZaFe · \(settings.hotKeyLabel)"
            statusItem = item
            controller.statusItem = item
            installMenu()
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法打开 ZaFe 资料库"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "退出")
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    private func installMenu() {
        let menu = NSMenu()
        let app = NSMenu()
        func add(_ title: String, _ selector: Selector, key: String = "") {
            let item = app.addItem(withTitle: title, action: selector, keyEquivalent: key)
            item.target = self
        }
        add("打开管理窗口", #selector(showManager), key: "0")
        add("新建便签", #selector(newNote), key: "n")
        add("添加文件…", #selector(addFiles), key: "o")
        app.addItem(.separator())
        add("设置…", #selector(showSettings), key: ",")
        app.addItem(.separator())
        add("退出 ZaFe", #selector(quit), key: "q")
        let root = NSMenuItem()
        root.submenu = app
        menu.addItem(root)
        let edit = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("重做", "redo:", "Z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let editRoot = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        editRoot.submenu = edit
        menu.addItem(editRoot)
        NSApp.mainMenu = menu
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp, let button = statusItem?.button,
           let menu = NSApp.mainMenu?.items.first?.submenu {
            NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent!, for: button)
        } else { controller?.toggleQuickPanel() }
    }
    @objc private func showManager() { controller?.showManager() }
    @objc private func showSettings() { controller?.showSettings() }
    @objc private func newNote() { controller?.newNote() }
    @objc private func addFiles() { controller?.chooseFiles() }
    @objc private func quit() { NSApp.terminate(nil) }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        NSApp.keyWindow?.makeFirstResponder(nil)
        guard controller?.store.flush() != false else {
            controller?.showManager()
            return .terminateCancel
        }
        controller?.stop()
        return .terminateNow
    }
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.showManager()
        return true
    }
}
