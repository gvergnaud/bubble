// Owner: app/UI track. Global shortcuts with Carbon RegisterEventHotKey: they work from any app and
// need no Accessibility permission (docs/architecture.md §1).
// ⌥⇧L / ⌥⇧P / ⌥⇧C are registered for the app's lifetime. Esc and Return are registered only while
// the countdown is up (so the countdown never has to take the focus from the user's app).
import AppKit
import Carbon.HIToolbox
import os

@MainActor
public final class Hotkeys {
    public enum Key: UInt32, Sendable, CaseIterable {
        case startStop = 1, pauseResume, discard, escape, returnKey, keypadEnter
    }

    /// Called on the main actor when a registered key is pressed.
    public var onPress: (@MainActor (Key) -> Void)?

    private var refs: [Key: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private static let signature: OSType = 0x4255_424C // 'BUBL'
    private let log = Logger(subsystem: "local.bubble.Bubble", category: "Hotkeys")

    public init() {}

    /// Installs the handler and registers ⌥⇧L/P/C. Returns the actions macOS refused (in use by another app).
    @discardableResult
    public func registerShortcuts() -> Set<HotkeyAction> {
        installHandler()
        var failed: Set<HotkeyAction> = []
        let mods = UInt32(optionKey | shiftKey)
        if !register(.startStop, keyCode: UInt32(kVK_ANSI_L), modifiers: mods) { failed.insert(.startStop) }
        if !register(.pauseResume, keyCode: UInt32(kVK_ANSI_P), modifiers: mods) { failed.insert(.pauseResume) }
        if !register(.discard, keyCode: UInt32(kVK_ANSI_C), modifiers: mods) { failed.insert(.discard) }
        return failed
    }

    /// Esc and Return go to the countdown while it is up, whatever app is in front.
    public func setCountdownKeys(_ on: Bool) {
        if on {
            _ = register(.escape, keyCode: UInt32(kVK_Escape), modifiers: 0)
            _ = register(.returnKey, keyCode: UInt32(kVK_Return), modifiers: 0)
            _ = register(.keypadEnter, keyCode: UInt32(kVK_ANSI_KeypadEnter), modifiers: 0)
        } else {
            for key in [Key.escape, .returnKey, .keypadEnter] { unregister(key) }
        }
    }

    private func register(_ key: Key, keyCode: UInt32, modifiers: UInt32) -> Bool {
        guard refs[key] == nil else { return true }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: key.rawValue)
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            log.error("RegisterEventHotKey \(String(describing: key)) failed: \(status)")
            return false
        }
        refs[key] = ref
        return true
    }

    private func unregister(_ key: Key) {
        if let ref = refs.removeValue(forKey: key) { UnregisterEventHotKey(ref) }
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == Hotkeys.signature, let key = Key(rawValue: id.id) else {
                return OSStatus(eventNotHandledErr)
            }
            // Carbon delivers application-target events on the main thread.
            MainActor.assumeIsolated {
                let hotkeys = Unmanaged<Hotkeys>.fromOpaque(userData).takeUnretainedValue()
                hotkeys.onPress?(key)
            }
            return noErr
        }, 1, &spec, me, &handler)
    }
}
