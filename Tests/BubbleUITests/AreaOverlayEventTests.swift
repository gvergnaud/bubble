// Owner: app/UI track. Drives the Area overlay with synthetic mouse events, offscreen (the window
// is never ordered in): a drag must draw a rectangle. Regression: in 0.1.4 the overlay covered the
// screen but dragging drew nothing.
import AppKit
import BubbleCore
import BubbleUI
import SwiftUI
import Testing

@MainActor @Suite struct AreaOverlayEventTests {
    final class Box { var rects: [CGRect] = [] }

    static func mouse(_ type: NSEvent.EventType, _ p: CGPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                           clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    @Test func aDragDrawsTheArea() {
        let size = CGSize(width: 800, height: 500)
        let box = Box()
        var actions = AreaOverlayActions()
        actions.setRect = { box.rects.append($0) }
        let window = AreaOverlayHost.makeWindow(size: size, state: AreaOverlayState(displaySize: size), actions: actions)
        let root = try! #require(window.contentView)
        let hit = root.superview.map { root.hitTest(root.convert(CGPoint(x: 100, y: 100), to: $0)) } ?? root.hitTest(CGPoint(x: 100, y: 100))
        #expect(hit === root, "the overlay itself takes the mouse (no SwiftUI view in the way)")
        // A window that is never ordered in doesn't route events by itself (no window server), so
        // the events go to the view the window's hit test picks, as AppKit would for a real click.
        let target = try! #require(hit)
        #expect(target.acceptsFirstMouse(for: nil), "the first click in a background app's overlay counts")
        // Window coordinates are bottom-left: from (100, 400) to (500, 100) = top-left (100,100)-(500,400).
        target.mouseDown(with: Self.mouse(.leftMouseDown, CGPoint(x: 100, y: 400), in: window))
        for i in 1...10 {
            let t = CGFloat(i) / 10
            target.mouseDragged(with: Self.mouse(.leftMouseDragged, CGPoint(x: 100 + 400 * t, y: 400 - 300 * t), in: window))
        }
        target.mouseUp(with: Self.mouse(.leftMouseUp, CGPoint(x: 500, y: 100), in: window))
        let last = box.rects.last
        #expect(last != nil, "a drag on the overlay must draw an area")
        if let last {
            #expect(abs(last.minX - 100) < 2 && abs(last.minY - 100) < 2)
            #expect(abs(last.width - 400) < 2 && abs(last.height - 300) < 2)
        }
    }
}
