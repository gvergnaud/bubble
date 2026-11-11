// Owner: app/UI track. The windows of "record a window or an area" (design.md §11.3): the Area
// overlay (whole display, dimmed, draw / move / resize the area) and the corner brackets that mark
// the area during a take. Neither is in the video because the recorder's filter excludes every
// window of Bubble but the bubble. sharingType = .none is only a second line: recent macOS
// versions let ScreenCaptureKit capture such windows anyway.
import AppKit
import BubbleCore
import Observation
import SwiftUI

/// A borderless panel that takes the keyboard (Return, Esc, ⇧ / ⌘ while dragging) without
/// activating Bubble, so the user's app keeps its place.
private final class OverlayPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onReturn: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        sharingType = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        title = "Bubble area"
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onReturn?() // Return, keypad Enter
        case 53: onCancel?()     // Esc
        default: super.keyDown(with: event)
        }
    }
}

@MainActor
@Observable
private final class OverlayStore {
    var state = AreaOverlayState(displaySize: .zero)
}

@MainActor
final class AreaOverlayWindowController {
    private let model: AppModel
    private let panel = OverlayPanel()
    private let store = OverlayStore()
    private var shown: AreaOverlayRequest?

    init(model: AppModel) {
        self.model = model
        panel.contentView = NSHostingView(rootView: OverlayRoot(store: store, actions: actions()))
        panel.onCancel = { [weak self] in self?.model.areaCanceled() }
        panel.onReturn = { [weak self] in self?.use() }
        trackChanges { [weak self] in self?.apply() }
    }

    private func actions() -> AreaOverlayActions {
        var a = AreaOverlayActions()
        a.setRect = { [weak self] in self?.store.state.rect = $0 }
        a.use = { [weak self] in self?.use() }
        a.cancel = { [weak self] in self?.model.areaCanceled() }
        return a
    }

    private func apply() {
        let request = model.areaOverlay
        guard request != shown else { return }
        shown = request
        guard let request else {
            panel.orderOut(nil)
            AppLog.info("area overlay: closed")
            return
        }
        let screen = request.display.frame
        store.state = AreaOverlayState(displaySize: screen.size,
                                       rect: request.rect.map { Self.local($0, in: screen) },
                                       startsRecording: request.startsRecording)
        panel.setFrame(screen, display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        AppLog.info("area overlay: shown on \(request.display.name)\(request.startsRecording ? " (from ⌥⇧L)" : "")")
    }

    private func use() {
        guard let request = shown, store.state.canUse, let rect = store.state.rect else { return }
        model.areaChosen(Self.global(rect, in: request.display.frame))
    }

    /// AppKit global (bottom-left origin) → the overlay's top-left coordinates.
    static func local(_ r: CGRect, in screen: CGRect) -> CGRect {
        CGRect(x: r.minX - screen.minX, y: screen.maxY - r.maxY, width: r.width, height: r.height)
    }

    static func global(_ r: CGRect, in screen: CGRect) -> CGRect {
        CGRect(x: screen.minX + r.minX, y: screen.maxY - r.maxY, width: r.width, height: r.height)
    }
}

private struct OverlayRoot: View {
    let store: OverlayStore
    let actions: AreaOverlayActions
    var body: some View { AreaOverlayView(state: store.state, actions: actions) }
}

/// Four white corner brackets around the area during a take (click-through, not recorded).
@MainActor
final class BracketsWindowController {
    private let model: AppModel
    private let panel = FloatingPanel(level: .screenSaver)
    private var shown: CGRect?

    init(model: AppModel) {
        self.model = model
        panel.ignoresMouseEvents = true
        panel.sharingType = .none
        panel.title = "Bubble area brackets"
        trackChanges { [weak self] in self?.apply() }
    }

    private func apply() {
        let frame = model.bracketsFrame
        guard frame != shown else { return }
        shown = frame
        guard let frame else { panel.orderOut(nil); return }
        // Just outside the area, so the brackets themselves stay out of the shot.
        let outer = frame.insetBy(dx: -4, dy: -4)
        panel.contentView = NSHostingView(rootView: CornerBracketsView(size: outer.size))
        panel.setFrame(outer, display: true)
        panel.orderFrontRegardless()
    }
}
