// Window mode's chooser: Apple's own window picker (SCContentSharingPicker). Owner: capture track.
// Spec: docs/architecture.md §3.4 (Picking), docs/design.md §11.
//
// Main actor. One pick at a time (a second call while one is up returns nil; a pick the picker never
// answered for over a minute is dropped as canceled, so a silent present failure cannot block picks). The picker hands back
// a content filter; its `includedWindows` (macOS 15.2+) gives the window. Below 15.2, isAvailable is
// false and the app does not offer window mode.

import AppKit
import CoreGraphics
@preconcurrency import ScreenCaptureKit

@MainActor
public final class LiveWindowPicker: NSObject, WindowPicking {
    private var pending: CheckedContinuation<PickedWindow?, Never>?
    private var pendingSince = Date.distantPast
    /// Counts picks: only the newest one deactivates the picker when it ends.
    private var pickNumber = 0
    static let staleAfter: TimeInterval = 60

    public override init() { super.init() }

    public var isAvailable: Bool {
        if #available(macOS 15.2, *) { return true }
        return false
    }

    public func pickWindow() async -> PickedWindow? {
        guard isAvailable else { return nil }
        if pending != nil {
            guard Date().timeIntervalSince(pendingSince) > Self.staleAfter else { return nil }
            CaptureLog.info("window picker: the last pick never got an answer; dropped")
            finish(nil)
        }
        pickNumber += 1
        let number = pickNumber
        let picker = SCContentSharingPicker.shared
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleWindow]
        if let bundleID = Bundle.main.bundleIdentifier { config.excludedBundleIDs = [bundleID] }
        picker.defaultConfiguration = config
        picker.add(self)
        picker.isActive = true
        CaptureLog.info("window picker: shown")
        let picked = await withCheckedContinuation { (continuation: CheckedContinuation<PickedWindow?, Never>) in
            pending = continuation
            pendingSince = Date()
            picker.present(using: .window)
        }
        if number == pickNumber {
            picker.isActive = false
            picker.remove(self)
        }
        CaptureLog.info("window picker: \(picked.map { "picked \($0.appName) — \($0.title) (\($0.id))" } ?? "canceled")")
        return picked
    }

    private func finish(_ window: PickedWindow?) {
        pending?.resume(returning: window)
        pending = nil
    }

    /// The picked window, as the contract wants it (AppKit global frame, the display holding most of it).
    nonisolated static func picked(from filter: SCContentFilter) -> PickedWindow? {
        guard #available(macOS 15.2, *), let window = filter.includedWindows.first else { return nil }
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        let frame = CaptureGeometry.appKitGlobal(fromCG: window.frame, mainDisplayHeight: mainHeight)
        return PickedWindow(id: window.windowID, title: window.title ?? "",
                            appName: window.owningApplication?.applicationName ?? "",
                            frame: frame, displayID: displayHoldingMost(of: window.frame))
    }

    /// The active display with the largest share of `rect` (CG global); the main display if none.
    nonisolated static func displayHoldingMost(of rect: CGRect) -> CGDirectDisplayID {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return CGMainDisplayID() }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return CGMainDisplayID() }
        return ids.prefix(Int(count)).max { a, b in
            CaptureGeometry.fractionOnDisplay(rect, displayBounds: CGDisplayBounds(a))
                < CaptureGeometry.fractionOnDisplay(rect, displayBounds: CGDisplayBounds(b))
        } ?? CGMainDisplayID()
    }
}

extension LiveWindowPicker: SCContentSharingPickerObserver {
    nonisolated public func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.finish(nil) }
    }

    nonisolated public func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        let window = Self.picked(from: filter)
        Task { @MainActor in self.finish(window) }
    }

    nonisolated public func contentSharingPickerStartDidFailWithError(_ error: Error) {
        CaptureLog.info("window picker: failed: \(error.localizedDescription)")
        Task { @MainActor in self.finish(nil) }
    }
}
