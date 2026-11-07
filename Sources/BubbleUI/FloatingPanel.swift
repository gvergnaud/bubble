// Owner: app/UI track. The borderless, transparent, non-activating panel every floating piece uses
// (bubble, hover controls, countdown, toasts): above other windows, on every Space and over
// full-screen apps, never takes the focus from the user's app.
import AppKit
import BubbleCore
import SwiftUI

@MainActor
final class FloatingPanel: NSPanel {
    init(contentRect: NSRect = .zero, level: NSWindow.Level = .floating) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.level = level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// An NSHostingView that does not size the window by itself and lets the first click act at once.
final class PassiveHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = []
    }
    @MainActor required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Runs `apply` now and again after each change of the observable values it read.
@MainActor
func trackChanges(_ apply: @escaping @MainActor () -> Void) {
    withObservationTracking {
        apply()
    } onChange: {
        Task { @MainActor in trackChanges(apply) }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func with(displayID: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.displayID == displayID }
    }
}

/// The usable area of a display (above the Dock, below the menu bar), in AppKit global points.
/// Falls back to the display's frame when no NSScreen matches (fake displays in BUBBLE_FAKE mode
/// are mapped onto the real screens by index).
@MainActor
func usableArea(for display: DisplayInfo) -> CGRect {
    if let screen = NSScreen.with(displayID: display.id) { return screen.visibleFrame }
    if let screen = NSScreen.screens.first(where: { $0.frame == display.frame }) { return screen.visibleFrame }
    return NSScreen.main?.visibleFrame ?? display.frame
}
