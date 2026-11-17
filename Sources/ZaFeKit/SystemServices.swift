import AppKit
import Carbon.HIToolbox
import Observation
import ServiceManagement

@MainActor
final class GlobalHotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onPress: (() -> Void)?

    init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().onPress?()
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func register(code: UInt32, modifiers: UInt32) throws {
        var candidate: EventHotKeyRef?
        let status = RegisterEventHotKey(code, modifiers, EventHotKeyID(signature: 0x5A614665, id: 1),
                                         GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &candidate)
        guard status == noErr else {
            throw NSError(domain: "ZaFe.HotKey", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "快捷键已被占用或不受系统支持，请换一个组合。"])
        }
        if let reference { UnregisterEventHotKey(reference) }
        reference = candidate
    }

    func stop() {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        reference = nil
        handler = nil
    }
}

@MainActor @Observable
final class LoginItemSettings {
    private(set) var enabled = false
    private(set) var needsApproval = false
    var error: String?

    init() { refresh() }
    func refresh() {
        let status = SMAppService.mainApp.status
        enabled = status == .enabled || status == .requiresApproval
        needsApproval = status == .requiresApproval
    }
    func setEnabled(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch { self.error = "登录启动未更改：\(error.localizedDescription)" }
        refresh()
    }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

struct HotKeyCombination: Equatable {
    let code: UInt32
    let modifiers: UInt32
    let label: String

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.control, .option, .command]).isEmpty,
              ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(Int(event.keyCode)) else { return nil }
        code = UInt32(event.keyCode)
        var modifiers: UInt32 = 0
        var label = ""
        if flags.contains(.control) { modifiers |= UInt32(controlKey); label += "⌃" }
        if flags.contains(.option) { modifiers |= UInt32(optionKey); label += "⌥" }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey); label += "⇧" }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey); label += "⌘" }
        self.modifiers = modifiers
        let names: [UInt16: String] = [49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        self.label = label + (names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "\(event.keyCode)")
    }
}
