// Owner: app/UI track. The camera bubble window and its hover controls (design.md §6.3,
// docs/architecture.md §3.1).
// - The bubble panel is created once and never recreated: the screen capture references its window
//   ID. Outside a take it is ordered out when not needed; during a take "camera off" is alpha 0 +
//   click-through, still ordered in.
// - The hover controls are a second panel laid exactly over the bubble (excluded from the video).
// - Drag anywhere; on drop the model snaps it (BubblePlacement) and the window animates there.
import AppKit
import AVFoundation
import BubbleCore
import SwiftUI

@MainActor
final class BubbleWindowController {
    private let model: AppModel
    /// The live camera, or a still image (BUBBLE_FAKE mode).
    private let content: (_ cameraLive: Bool) -> BubbleContent
    let panel: FloatingPanel
    private let hoverPanel: FloatingPanel
    private let container: BubbleContainerView
    private let host: PassiveHostingView<BubbleView>
    private let hoverHost: PassiveHostingView<BubbleHoverControlsView>
    private var hoverTimer: Timer?
    private var lastHoverInside = Date.distantPast
    private var applied: BubbleState?

    init(model: AppModel, content: @escaping (_ cameraLive: Bool) -> BubbleContent) {
        self.model = model
        self.content = content
        panel = FloatingPanel(level: .floating)
        hoverPanel = FloatingPanel(level: NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1))
        host = PassiveHostingView(rootView: BubbleView(content: .waiting, diameter: BubbleSize.medium.diameter))
        hoverHost = PassiveHostingView(rootView: BubbleHoverControlsView(diameter: BubbleSize.medium.diameter, size: .medium))
        container = BubbleContainerView(frame: .zero)
        container.addSubview(host)
        host.autoresizingMask = [.width, .height]
        panel.contentView = container
        panel.title = "Bubble camera"
        hoverPanel.contentView = hoverHost
        hoverPanel.title = "Bubble controls"

        container.onDragMoved = { [weak self] delta in self?.dragMoved(delta) }
        container.onDragEnded = { [weak self] in self?.dragEnded() }
        container.onMouseEntered = { [weak self] in self?.showHover() }
        container.onDragStarted = { [weak self] in self?.hideHover() }
        hoverHost.rootView = hoverView(for: .default)

        trackChanges { [weak self] in self?.apply(self?.model.bubble) }
    }

    /// The bubble's window number: the one window of Bubble left in the video.
    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }

    // MARK: State → window

    private func apply(_ state: BubbleState?) {
        defer { applied = state }
        guard let state else {
            hideHover()
            panel.orderOut(nil)
            return
        }
        let area = state.frame ?? usableArea(for: state.display)
        let circle = BubblePlacement.frame(for: state.place, in: area)
        let frame = circle.insetBy(dx: -BubbleView.shadowPadding, dy: -BubbleView.shadowPadding)

        host.rootView = BubbleView(content: content(state.cameraLive), diameter: state.place.size.diameter,
                                   mirrored: state.mirrored, dimmed: state.dimmed, unavailable: state.cameraUnavailable)
        hoverHost.rootView = hoverView(for: state.place)

        let wasVisible = panel.isVisible && applied != nil
        if wasVisible, panel.frame != frame, !container.isDragging {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else if !container.isDragging {
            panel.setFrame(frame, display: true)
        }
        hoverPanel.setFrame(frame, display: false)

        panel.alphaValue = state.hidden ? 0 : 1
        panel.ignoresMouseEvents = state.hidden
        if state.hidden { hideHover() }
        if !panel.isVisible { panel.orderFrontRegardless() }
        model.bubbleWindowID = windowID
    }

    private func hoverView(for place: BubblePlace) -> BubbleHoverControlsView {
        BubbleHoverControlsView(
            diameter: place.size.diameter, size: place.size,
            onSize: { [weak self] size in self?.model.setBubbleSize(size) },
            onCameraOff: { [weak self] in
                self?.hideHover()
                self?.model.setCameraHidden(true)
            })
    }

    // MARK: Drag

    private var dragStartFrame: NSRect?

    private func dragMoved(_ delta: CGSize) {
        if dragStartFrame == nil { dragStartFrame = panel.frame }
        guard let start = dragStartFrame else { return }
        panel.setFrameOrigin(NSPoint(x: start.minX + delta.width, y: start.minY + delta.height))
    }

    private func dragEnded() {
        dragStartFrame = nil
        guard let state = model.bubble else { return }
        let circle = panel.frame.insetBy(dx: BubbleView.shadowPadding, dy: BubbleView.shadowPadding)
        model.bubbleDropped(frame: circle, area: state.frame ?? usableArea(for: state.display))
        // The model may land on the same place (a tiny drag): put the window back where it belongs.
        apply(model.bubble)
    }

    // MARK: Hover

    private func showHover() {
        guard let state = model.bubble, !state.hidden, !container.isDragging else { return }
        hoverPanel.setFrame(panel.frame, display: false)
        if !hoverPanel.isVisible {
            hoverPanel.alphaValue = 0
            hoverPanel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                hoverPanel.animator().alphaValue = 1
            }
        }
        lastHoverInside = Date()
        if hoverTimer == nil {
            // Tracking areas don't follow a mouse that moves from the bubble onto the controls
            // window above it; polling the mouse at 10 Hz while the controls are up does.
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkHover() }
            }
            RunLoop.main.add(hoverTimer!, forMode: .common)
        }
    }

    private func checkHover() {
        let mouse = NSEvent.mouseLocation
        let circle = panel.frame.insetBy(dx: BubbleView.shadowPadding - 6, dy: BubbleView.shadowPadding - 6)
        let inside = hoverPanel.frame.contains(mouse) && hypot(mouse.x - circle.midX, mouse.y - circle.midY) <= circle.width / 2 + 14
        if inside { lastHoverInside = Date() }
        if Date().timeIntervalSince(lastHoverInside) > 0.35 || container.isDragging { hideHover() }
    }

    private func hideHover() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        hoverPanel.orderOut(nil)
    }
}

/// The bubble window's content: drags the window, reports hover. Only the circle reacts; the
/// shadow margin around it is transparent and clicks there go to the window below.
@MainActor
final class BubbleContainerView: NSView {
    var onDragStarted: (() -> Void)?
    var onDragMoved: ((CGSize) -> Void)?
    var onDragEnded: (() -> Void)?
    var onMouseEntered: (() -> Void)?
    private(set) var isDragging = false
    private var mouseDownAt: NSPoint?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return circleContains(local) ? self : nil
    }

    private func circleContains(_ p: NSPoint) -> Bool {
        guard let c = circleRect else { return false }
        return hypot(p.x - c.midX, p.y - c.midY) <= c.width / 2
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = nil
        guard let rect = circleRect else { return }
        let t = NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { onMouseEntered?() }
    override func mouseMoved(with event: NSEvent) { if !isDragging { onMouseEntered?() } }

    override func mouseDown(with event: NSEvent) {
        mouseDownAt = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownAt else { return }
        let now = NSEvent.mouseLocation
        let delta = CGSize(width: now.x - start.x, height: now.y - start.y)
        if !isDragging {
            guard hypot(delta.width, delta.height) > 3 else { return }
            isDragging = true
            NSCursor.closedHand.push()
            onDragStarted?()
        }
        onDragMoved?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownAt = nil
        guard isDragging else { return }
        isDragging = false
        NSCursor.pop()
        onDragEnded?()
    }

    /// The circle's square; nil before the window has its size (an inset of a tiny rect is null).
    private var circleRect: NSRect? {
        let r = bounds.insetBy(dx: BubbleView.shadowPadding, dy: BubbleView.shadowPadding)
        return r.isNull || r.isEmpty ? nil : r
    }

    override func resetCursorRects() {
        if let r = circleRect { addCursorRect(r, cursor: .openHand) }
    }
}
