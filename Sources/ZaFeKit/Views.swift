import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

private enum Appearance {
    static let iconSize: CGFloat = 38
    static let corner: CGFloat = 10
}

struct RecordRow: View {
    let record: LibraryRecord
    let store: LibraryStore
    var compact = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: Appearance.corner).fill(.quaternary.opacity(0.65))
                if record.kind == .image, let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                        .frame(width: Appearance.iconSize, height: Appearance.iconSize).clipped()
                } else {
                    Image(systemName: record.kind.symbol).font(.system(size: 17, weight: .regular)).foregroundStyle(.secondary)
                }
            }
            .frame(width: Appearance.iconSize, height: Appearance.iconSize)
            .clipShape(RoundedRectangle(cornerRadius: Appearance.corner))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(record.displayTitle).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if record.isFavorite { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.secondary) }
                }
                Text(record.subtitle.isEmpty ? record.kind.label : record.subtitle)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(compact ? 1 : 2)
            }
            Spacer(minLength: 3)
            if !compact {
                Text(record.touchedAt, format: .dateTime.month(.twoDigits).day(.twoDigits))
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, compact ? 5 : 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var thumbnail: NSImage? {
        guard let url = store.imageURL(for: record),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 100,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}

struct RecordMenu: View {
    let record: LibraryRecord
    let controller: AppController
    var body: some View {
        if record.deletedAt != nil {
            Button("恢复", systemImage: "arrow.uturn.backward") { controller.store.restore(record) }
        } else {
            Button("复制", systemImage: "doc.on.doc") { _ = controller.clipboard.copy(record) }
            if record.kind == .files {
                Button("打开", systemImage: "arrow.up.forward.app") { controller.openFile(record) }
                Button("快速查看", systemImage: "eye") { controller.preview(record) }
                Button("在 Finder 中显示", systemImage: "folder") { controller.revealFile(record) }
                Button("复制路径", systemImage: "link") { _ = controller.clipboard.copy(record, pathsOnly: true) }
            }
            Divider()
            Button(record.isFavorite ? "取消收藏" : "收藏", systemImage: record.isFavorite ? "star.slash" : "star") {
                controller.store.setFavorite(record, !record.isFavorite)
            }
            Button("删除", systemImage: "trash", role: .destructive) { controller.store.delete(record) }
        }
    }
}

struct StatusArea: View {
    let controller: AppController
    var body: some View {
        VStack(spacing: 0) {
            if controller.clipboard.state != .running {
                HStack(spacing: 8) {
                    Image(systemName: "clipboard").foregroundStyle(.secondary)
                    Text(controller.clipboard.state == .denied ? "剪贴板访问被拒绝" : "剪贴板等待授权").font(.caption)
                    Spacer()
                    Button(controller.clipboard.state == .denied ? "重试" : "开启记录") { controller.clipboard.resumeByUser() }
                        .controlSize(.small)
                    Button("系统设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") { NSWorkspace.shared.open(url) }
                    }.controlSize(.small)
                }.padding(10).background(.quaternary.opacity(0.4))
            }
            if let notice = controller.store.notice {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(notice).font(.caption).lineLimit(2).help(notice).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button { _ = controller.store.flush() } label: { Image(systemName: "arrow.clockwise") }
                        .help("重试保存").accessibilityLabel("重试保存")
                    Button { controller.store.notice = nil } label: { Image(systemName: "xmark") }
                        .help("关闭提示").accessibilityLabel("关闭提示")
                }
                .buttonStyle(.plain).padding(10).background(.orange.opacity(0.07))
            }
        }
    }
}

struct AddFilesMenu: View {
    let controller: AppController
    var body: some View {
        Menu {
            Button("选择文件…", systemImage: "folder.badge.plus") { controller.chooseFiles() }
            Button("从剪贴板添加", systemImage: "clipboard") { controller.pasteFiles() }
        } label: { Label("添加文件", systemImage: "folder.badge.plus") }
        .help("添加文件或文件夹")
    }
}

struct QuickPanelView: View {
    @Bindable var controller: AppController
    @FocusState private var searchFocused: Bool
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up").font(.system(size: 17, weight: .medium))
                Text("ZaFe").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { controller.isPinned.toggle() } label: {
                    Image(systemName: controller.isPinned ? "pin.fill" : "pin")
                        .foregroundStyle(controller.isPinned ? .primary : .secondary)
                }.help(controller.isPinned ? "取消固定" : "固定面板")
                    .accessibilityLabel(controller.isPinned ? "取消固定面板" : "固定面板")
                Button { controller.showManager() } label: { Image(systemName: "sidebar.left") }
                    .help("打开管理窗口").accessibilityLabel("打开管理窗口")
            }
            .buttonStyle(.borderless).padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 13)

            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索记录", text: $controller.quickQuery).textFieldStyle(.plain)
                    .focused($searchFocused).accessibilityLabel("搜索记录")
                if !controller.quickQuery.isEmpty {
                    Button { controller.quickQuery = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain).accessibilityLabel("清除搜索")
                }
            }
            .padding(11).background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)

            HStack(spacing: 4) {
                ForEach(LibraryFilter.quickFilters) { filter in
                    Button { controller.quickFilter = filter } label: {
                        Text(filter.label).font(.system(size: 11, weight: controller.quickFilter == filter ? .semibold : .regular))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(controller.quickFilter == filter ? Color.primary.opacity(0.08) : .clear, in: Capsule())
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(controller.quickFilter == filter ? [.isSelected] : [])
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 16).padding(.vertical, 12)

            Divider()
            if controller.quickRecords.isEmpty {
                ContentUnavailableView {
                    Label(controller.quickQuery.isEmpty ? "留住有用的内容" : "没有找到记录", systemImage: controller.quickQuery.isEmpty ? "square.stack.3d.up" : "magnifyingglass")
                } actions: {
                    Button("新建便签") { controller.newNote() }
                    Button("添加文件") { controller.chooseFiles() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(selection: $controller.quickSelection) {
                        ForEach(controller.quickRecords) { record in
                            HStack(spacing: 6) {
                                RecordRow(record: record, store: controller.store, compact: true)
                                Button { controller.copyFromQuick(record) } label: { Image(systemName: "doc.on.doc").foregroundStyle(.secondary) }
                                    .buttonStyle(.borderless).help("复制").accessibilityLabel("复制 \(record.displayTitle)")
                            }
                            .tag(record.id).id(record.id)
                            .onTapGesture(count: 2) { controller.copyFromQuick(record) }
                            .contextMenu { RecordMenu(record: record, controller: controller) }
                        }
                    }
                    .listStyle(.plain).scrollContentBackground(.hidden)
                    .onChange(of: controller.quickSelection) { _, id in if let id { proxy.scrollTo(id) } }
                }
            }
            StatusArea(controller: controller)
            Divider()
            HStack(spacing: 14) {
                Button { controller.newNote() } label: { Image(systemName: "square.and.pencil") }
                    .help("新建便签 ⌘N").accessibilityLabel("新建便签")
                AddFilesMenu(controller: controller).labelStyle(.iconOnly).menuIndicator(.hidden)
                Spacer()
                Text("\(controller.quickRecords.count) 项").font(.system(size: 10)).foregroundStyle(.tertiary)
                Text(controller.settings.hotKeyLabel).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                Button { controller.showSettings() } label: { Image(systemName: "gearshape") }
                    .help("设置").accessibilityLabel("设置")
            }
            .buttonStyle(.borderless).padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 460, height: 600)
        .background(.regularMaterial)
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 10).stroke(.tint, lineWidth: 2).padding(4).allowsHitTesting(false) } }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            controller.addFiles(files)
            return true
        } isTargeted: { dropTargeted = $0 }
        .onAppear { searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .focusQuickSearch)) { _ in searchFocused = true }
        .onChange(of: controller.quickQuery) { _, _ in controller.quickSelection = controller.quickRecords.first?.id }
        .onChange(of: controller.quickFilter) { _, _ in controller.quickSelection = controller.quickRecords.first?.id }
    }
}

struct ManagerView: View {
    @Bindable var controller: AppController
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up.fill").font(.system(size: 23)).foregroundStyle(.secondary)
                    Text("ZaFe").font(.system(size: 20, weight: .semibold))
                    Spacer()
                }.padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 8)
                List(selection: $controller.mainFilter) {
                    Section {
                        ForEach([LibraryFilter.all, .clipboard, .files, .notes]) { filter in sidebarRow(filter) }
                    }
                    Section {
                        sidebarRow(.favorites)
                        sidebarRow(.trash)
                    }
                }.listStyle(.sidebar)
                HStack {
                    Button { controller.showSettings() } label: { Image(systemName: "gearshape") }.help("设置").accessibilityLabel("设置")
                    Spacer()
                    Text("仅在本机").font(.system(size: 10)).foregroundStyle(.tertiary)
                }.buttonStyle(.borderless).padding(16)
            }.navigationSplitViewColumnWidth(min: 166, ideal: 184, max: 220)
        } content: {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索", text: $controller.mainQuery).textFieldStyle(.plain).accessibilityLabel("搜索内容库")
                    if !controller.mainQuery.isEmpty {
                        Button { controller.mainQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.tertiary).accessibilityLabel("清除搜索")
                    }
                }.padding(11).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8)).padding(12)
                HStack {
                    Text((controller.mainFilter ?? .all).label).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("\(controller.mainRecords.count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
                }.padding(.horizontal, 16).padding(.bottom, 10)
                Divider()
                if controller.mainRecords.isEmpty {
                    ContentUnavailableView(controller.mainQuery.isEmpty ? "暂无记录" : "没有找到记录", systemImage: controller.mainQuery.isEmpty ? (controller.mainFilter ?? .all).symbol : "magnifyingglass")
                        .frame(maxHeight: .infinity)
                } else {
                    List(controller.mainRecords, selection: $controller.mainSelection) { record in
                        RecordRow(record: record, store: controller.store).tag(record.id)
                            .contextMenu { RecordMenu(record: record, controller: controller) }
                            .onTapGesture(count: 2) {
                                if record.deletedAt == nil, record.kind == .files { controller.openFile(record) }
                            }
                    }.listStyle(.inset).scrollContentBackground(.hidden)
                }
                StatusArea(controller: controller)
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 430)
        } detail: {
            if let record = controller.mainRecords.first(where: { $0.id == controller.mainSelection }) {
                RecordDetailView(record: record, controller: controller).id(record.id)
            } else {
                ContentUnavailableView {
                    Label("随时取用", systemImage: "square.stack.3d.up")
                } actions: {
                    Button("新建便签") { controller.newNote() }.buttonStyle(.bordered)
                    Button("添加文件") { controller.chooseFiles() }.buttonStyle(.borderless)
                }
            }
        }
        .navigationTitle("ZaFe")
        .toolbar {
            ToolbarItemGroup {
                AddFilesMenu(controller: controller)
                Button { controller.newNote() } label: { Label("新建便签", systemImage: "square.and.pencil") }
                    .help("新建便签 ⌘N")
            }
        }
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 10).stroke(.tint, lineWidth: 3).padding(6).allowsHitTesting(false) } }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            controller.addFiles(files)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private func sidebarRow(_ filter: LibraryFilter) -> some View {
        Label(filter.label, systemImage: filter.symbol).tag(filter)
            .padding(.vertical, 3)
    }
}

struct RecordDetailView: View {
    @Bindable var record: LibraryRecord
    let controller: AppController
    @State private var confirmPermanentDelete = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label(record.kind.label, systemImage: record.kind.symbol).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if record.deletedAt != nil {
                    Button("恢复", systemImage: "arrow.uturn.backward") { controller.store.restore(record) }
                    Button(role: .destructive) { confirmPermanentDelete = true } label: { Image(systemName: "trash.slash") }
                        .help("彻底删除").accessibilityLabel("彻底删除")
                } else {
                    Button { controller.store.setFavorite(record, !record.isFavorite) } label: {
                        Image(systemName: record.isFavorite ? "star.fill" : "star")
                    }.help(record.isFavorite ? "取消收藏" : "收藏").accessibilityLabel(record.isFavorite ? "取消收藏" : "收藏")
                    Button { _ = controller.clipboard.copy(record) } label: { Image(systemName: "doc.on.doc") }
                        .help("复制").accessibilityLabel("复制")
                    Button(role: .destructive) { controller.store.delete(record) } label: { Image(systemName: "trash") }
                        .help("删除").accessibilityLabel("删除")
                }
            }.buttonStyle(.borderless).padding(.horizontal, 24).padding(.vertical, 17)
            Divider()
            if let deletedAt = record.deletedAt {
                HStack {
                    Image(systemName: "clock")
                    Text("保留至 \(deletedAt.addingTimeInterval(7 * 86_400).formatted(date: .abbreviated, time: .omitted))")
                    Spacer()
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.top, 14)
            }
            detailContent.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            HStack {
                Text(record.touchedAt, format: .dateTime.year().month().day().hour().minute())
                Spacer()
                if record.kind == .note || record.kind == .text { Text("\(record.body.count) 字") }
            }.font(.system(size: 10)).foregroundStyle(.tertiary).padding(.horizontal, 24).padding(.vertical, 12)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .confirmationDialog("彻底删除？此操作无法恢复。", isPresented: $confirmPermanentDelete, titleVisibility: .visible) {
            Button("彻底删除", role: .destructive) { controller.store.permanentlyDelete([record]) }
        }
    }

    @ViewBuilder private var detailContent: some View {
        switch record.kind {
        case .note:
            VStack(alignment: .leading, spacing: 16) {
                TextField("标题", text: Binding(get: { record.title }, set: { controller.store.updateNote(record, title: $0) }))
                    .font(.system(size: 24, weight: .semibold)).textFieldStyle(.plain).disabled(record.deletedAt != nil)
                    .accessibilityLabel("便签标题")
                TextEditor(text: Binding(get: { record.body }, set: { controller.store.updateNote(record, body: $0) }))
                    .font(.system(size: 14)).lineSpacing(6).scrollContentBackground(.hidden)
                    .disabled(record.deletedAt != nil).accessibilityLabel("便签正文")
            }.padding(24)
        case .text:
            ScrollView {
                Text(record.body).font(.system(size: 14)).lineSpacing(6).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }
        case .image:
            if let url = controller.store.imageURL(for: record), let image = NSImage(contentsOf: url) {
                VStack {
                    Spacer()
                    Image(nsImage: image).resizable().scaledToFit().padding(24).accessibilityLabel("已保存的图片")
                    Spacer()
                    Text(record.subtitle).font(.caption).foregroundStyle(.secondary).padding(.bottom, 16)
                }
            } else { ContentUnavailableView("找不到图片", systemImage: "photo.badge.exclamationmark") }
        case .files:
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(record.references) { reference in fileCard(reference) }
                    if record.deletedAt == nil {
                        HStack(spacing: 12) {
                            Button("打开", systemImage: "arrow.up.forward.app") { controller.openFile(record) }
                                .buttonStyle(.borderedProminent).tint(.primary)
                            Button("快速查看", systemImage: "eye") { controller.preview(record) }.buttonStyle(.bordered)
                        }
                        HStack(spacing: 16) {
                            Button("Finder 定位") { controller.revealFile(record) }
                            Button("复制路径") { _ = controller.clipboard.copy(record, pathsOnly: true) }
                        }.buttonStyle(.link).font(.caption)
                    }
                }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func fileCard(_ reference: FileReference) -> some View {
        let available = controller.store.fileIsAvailable(reference)
        return VStack(alignment: .leading, spacing: 12) {
            Image(systemName: reference.isDirectory ? "folder.fill" : "doc.fill")
                .font(.system(size: 48, weight: .light)).foregroundStyle(.secondary).padding(.vertical, 10)
            Text(reference.name).font(.system(size: 21, weight: .semibold)).textSelection(.enabled)
            Text(reference.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if !available {
                Label("找不到文件或暂时无法访问", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
            }
            if record.deletedAt == nil {
                Button(available ? "更改关联…" : "重新定位…") { controller.relocate(record, reference: reference) }
                    .buttonStyle(.link).font(.caption)
            }
        }
    }
}

struct SettingsView: View {
    @Bindable var controller: AppController
    @State private var days = 30
    @State private var count = 1000
    @State private var megabytes = 1000

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("通用") {
                    LabeledContent("快捷面板") {
                        HotKeyRecorder(label: controller.settings.hotKeyLabel) { controller.changeHotKey($0) }.frame(width: 160, height: 25)
                    }
                    Toggle("登录时启动", isOn: Binding(get: { controller.loginItems.enabled }, set: { controller.loginItems.setEnabled($0) }))
                    if controller.loginItems.needsApproval {
                        Button("在系统设置中允许启动…") { controller.loginItems.openSystemSettings() }
                    }
                    if let error = controller.loginItems.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                }
                Section("普通剪贴板历史") {
                    limitField("保留天数", value: $days, suffix: "天")
                    limitField("最多条目", value: $count, suffix: "条")
                    limitField("容量上限", value: $megabytes, suffix: "MB")
                    HStack {
                        Text("收藏与手动内容不自动清理").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("应用") { applyLimits() }
                    }
                }
                Section {
                    LabeledContent("资料库", value: "本机存储")
                    Button("在 Finder 中显示资料库") { NSWorkspace.shared.activateFileViewerSelecting([controller.store.directory]) }
                }
            }.formStyle(.grouped)
            StatusArea(controller: controller)
        }.frame(width: 500, height: 460)
        .onAppear {
            days = controller.settings.historyDays
            count = controller.settings.historyCount
            megabytes = controller.settings.historyMegabytes
        }
    }

    private func limitField(_ label: String, value: Binding<Int>, suffix: String) -> some View {
        LabeledContent(label) {
            TextField(label, value: value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 90)
                .onSubmit { applyLimits() }.accessibilityLabel(label)
            Text(suffix).foregroundStyle(.secondary).frame(width: 25, alignment: .leading)
        }
    }

    private func applyLimits() {
        days = min(3650, max(1, days))
        count = min(100_000, max(1, count))
        megabytes = min(100_000, max(1, megabytes))
        controller.settings.historyDays = days
        controller.settings.historyCount = count
        controller.settings.historyMegabytes = megabytes
        controller.store.cleanup()
    }
}

struct HotKeyRecorder: NSViewRepresentable {
    let label: String
    let onChange: (HotKeyCombination) -> Bool
    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.bezelStyle = .rounded
        button.setAccessibilityLabel("设置快捷面板快捷键")
        button.onChange = onChange
        button.label = label
        button.title = label
        return button
    }
    func updateNSView(_ button: RecorderButton, context: Context) {
        button.label = label
        button.onChange = onChange
        if !button.recording { button.title = label }
    }
}

@MainActor
final class RecorderButton: NSButton {
    var onChange: ((HotKeyCombination) -> Bool)?
    var label = ""
    var recording = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(beginRecording)
    }
    required init?(coder: NSCoder) { return nil }
    override var acceptsFirstResponder: Bool { true }
    @objc private func beginRecording() {
        recording = true
        title = "请按快捷键…"
        window?.makeFirstResponder(self)
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { finish(); return }
        guard let combination = HotKeyCombination(event: event) else { NSSound.beep(); return }
        if onChange?(combination) == true { label = combination.label; finish() }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }
    override func resignFirstResponder() -> Bool { finish(); return super.resignFirstResponder() }
    private func finish() { recording = false; title = label }
}
