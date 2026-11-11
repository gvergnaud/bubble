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

/// The overlay's content: the drawing (SwiftUI, no mouse), the drag (this AppKit view: mouseDown /
/// Dragged / Up, first click included) and the bar (its own SwiftUI view, clickable).
@MainActor
final class AreaOverlayContainer: NSView {
    var state: AreaOverlayState { didSet { refresh() } }
    var actions: AreaOverlayActions
    private let drawing: NSHostingView<AreaOverlayView>
    private let bar: PassiveHostingView<AreaOverlayBar>
    private var drag: AreaDrag?

    init(state: AreaOverlayState, actions: AreaOverlayActions) {
        self.state = state
        self.actions = actions
        drawing = NSHostingView(rootView: AreaOverlayView(state: state, showsBar: false))
        bar = PassiveHostingView(rootView: AreaOverlayBar(state: state, actions: actions))
        super.init(frame: CGRect(origin: .zero, size: state.displaySize))
        drawing.sizingOptions = []
        addSubview(drawing)
        addSubview(bar)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// The bar's buttons get their clicks; everywhere else, this view (the drag).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        guard bounds.contains(p) else { return nil }
        if !bar.isHidden, bar.frame.contains(p) { return bar.hitTest(p) ?? bar }
        return self
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        drag = AreaDrag(at: convert(event.locationInWindow, from: nil), current: state.rect)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let flags = event.modifierFlags
        let r = drag.rect(at: convert(event.locationInWindow, from: nil), bounds: bounds.size,
                          shift: flags.contains(.shift), command: flags.contains(.command))
        state.rect = r
        actions.setRect(r)
    }

    override func mouseUp(with event: NSEvent) { drag = nil }

    private func refresh() {
        drawing.frame = CGRect(origin: .zero, size: state.displaySize)
        drawing.rootView = AreaOverlayView(state: state, showsBar: false)
        bar.rootView = AreaOverlayBar(state: state, actions: actions)
        guard let r = state.rect else { bar.isHidden = true; return }
        bar.isHidden = false
        let size = bar.fittingSize
        let origin = AreaGeometry.barOrigin(for: r, barSize: size, bounds: state.displaySize)
        bar.frame = CGRect(origin: origin, size: size)
    }
}

@MainActor
final class AreaOverlayWindowController {
    private let model: AppModel
    private let panel = OverlayPanel()
    private var container: AreaOverlayContainer?
    private var shown: AreaOverlayRequest?

    init(model: AppModel) {
        self.model = model
        panel.onCancel = { [weak self] in self?.model.areaCanceled() }
        panel.onReturn = { [weak self] in self?.use() }
        trackChanges { [weak self] in self?.apply() }
    }

    private func actions() -> AreaOverlayActions {
        var a = AreaOverlayActions()
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
        let state = AreaOverlayState(displaySize: screen.size,
                                     rect: request.rect.map { Self.local($0, in: screen) },
                                     startsRecording: request.startsRecording)
        let container = AreaOverlayContainer(state: state, actions: actions())
        self.container = container
        panel.contentView = container
        panel.setFrame(screen, display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(container)
        AppLog.info("area overlay: shown on \(request.display.name)\(request.startsRecording ? " (from ⌥⇧L)" : "")")
    }

    private func use() {
        guard let request = shown, let state = container?.state, state.canUse, let rect = state.rect else { return }
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

/// The overlay's window and view as the app builds them, for the event test (driven offscreen).
@MainActor
public enum AreaOverlayHost {
    public static func makeWindow(size: CGSize, state: AreaOverlayState, actions: AreaOverlayActions) -> NSWindow {
        let panel = OverlayPanel()
        panel.contentView = AreaOverlayContainer(state: state, actions: actions)
        panel.setFrame(CGRect(origin: .zero, size: size), display: false)
        return panel
    }
}

/// The window about to be recorded: a 3 pt blue outline around it during the 3-2-1 (design.md
/// §11.6; click-through, not recorded).
@MainActor
final class WindowOutlineController {
    private let model: AppModel
    private let panel = FloatingPanel(level: .screenSaver)
    private var shown: CGRect?

    init(model: AppModel) {
        self.model = model
        panel.ignoresMouseEvents = true
        panel.sharingType = .none
        panel.title = "Bubble window outline"
        trackChanges { [weak self] in self?.apply() }
    }

    private func apply() {
        let frame = model.countdownWindowFrame
        guard frame != shown else { return }
        shown = frame
        guard let frame else { panel.orderOut(nil); return }
        let outer = frame.insetBy(dx: -3, dy: -3)
        panel.contentView = NSHostingView(rootView: WindowOutlineView(size: outer.size))
        panel.setFrame(outer, display: true)
        panel.orderFrontRegardless()
    }
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
