import AppKit
import SwiftUI

final class StatusDropPanel: NSPanel {
    private static let size = NSSize(width: 232, height: 68)
    private let feedback = DropFeedback()

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let content = NSHostingView(rootView: StatusDropView(feedback: feedback))
        content.safeAreaRegions = []
        contentView = content
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    static func frame(below anchor: NSRect, in visible: NSRect) -> NSRect {
        let visible = visible.insetBy(dx: 8, dy: 0)
        let size = NSSize(width: min(Self.size.width, visible.width), height: min(Self.size.height, visible.height))
        let x = min(max(anchor.midX - size.width / 2, visible.minX), visible.maxX - size.width)
        let y = max(visible.minY, min(anchor.minY, visible.maxY) - size.height)
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    static func activationFrame(below anchor: NSRect, in visible: NSRect) -> NSRect {
        let panel = frame(below: anchor, in: visible).insetBy(dx: -16, dy: 0)
        return NSRect(x: panel.minX, y: panel.minY - 56, width: panel.width, height: panel.height + 56)
            .intersection(visible)
    }

    func show(below anchor: NSRect, in visible: NSRect) {
        setTargeted(false)
        setFrame(Self.frame(below: anchor, in: visible), display: true)
        orderFrontRegardless()
    }

    func setTargeted(_ targeted: Bool) { feedback.isTargeted = targeted }
}

@Observable @MainActor
private final class DropFeedback {
    var isTargeted = false
}

private struct StatusDropView: View {
    let feedback: DropFeedback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let targeted = feedback.isTargeted
        let shape = RoundedRectangle(cornerRadius: 17)
        HStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(targeted ? Color.accentColor : Color.primary)
                .scaleEffect(targeted && !reduceMotion ? 1.14 : 1)
                .frame(width: 28)
                .accessibilityHidden(true)
                .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.55), value: targeted)
            ZStack(alignment: .leading) {
                Text("将文件拖到这里")
                    .scaleEffect(targeted && !reduceMotion ? 0.12 : 1, anchor: .leading)
                    .offset(x: targeted && !reduceMotion ? -19 : 0)
                    .opacity(targeted ? 0 : 1)
                    .accessibilityHidden(targeted)
                    .animation(reduceMotion ? nil : .easeIn(duration: 0.19), value: targeted)
                Text("松手添加文件")
                    .opacity(targeted ? 1 : 0)
                    .accessibilityHidden(!targeted)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.14).delay(targeted ? 0.15 : 0), value: targeted)
            }
            .font(.system(size: 14, weight: .semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(reduceTransparency ? AnyShapeStyle(.background) : AnyShapeStyle(.regularMaterial), in: shape)
        .overlay { shape.strokeBorder(targeted ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: targeted ? 1.5 : 1) }
        .padding(.top, 7)
    }
}
