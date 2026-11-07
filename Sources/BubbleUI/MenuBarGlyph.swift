import AppKit
import SwiftUI

/// Bubble's menu bar icon: two bubbles, a big one and a small one at its bottom-left
/// (option B on the design review page, the user's pick). Owned by design.
///
/// - `idle`: a template image, so it follows the menu bar's tint (light, dark, tinted).
/// - `recording`: the same glyph, the big bubble in system red, the small one in the
///   menu bar's text color. Not a template, so the red stays red.
///
/// Geometry, in points, on a 17 × 17 canvas (origin bottom-left):
/// big bubble center (10, 10) radius 6.75; small bubble center (3.5, 3.5) radius 2.75,
/// with a clear gap around it cut out of the big one (radius 4.25, so 1.5 pt of air).
@MainActor
enum MenuBarGlyph {
    static let size = NSSize(width: 17, height: 17)

    static let idle: NSImage = {
        let image = NSImage(size: size, flipped: false) { _ in
            draw(big: .black, small: .black)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Bubble"
        return image
    }()

    static let recording: NSImage = {
        // The handler runs at draw time with the status button's appearance,
        // so labelColor resolves to the menu bar's text color (dark or light).
        let image = NSImage(size: size, flipped: false) { _ in
            draw(big: .systemRed, small: .labelColor)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Recording"
        return image
    }()

    private static func draw(big: NSColor, small: NSColor) {
        disc(center: NSPoint(x: 10, y: 10), radius: 6.75, color: big)
        clear(center: NSPoint(x: 3.5, y: 3.5), radius: 4.25)
        disc(center: NSPoint(x: 3.5, y: 3.5), radius: 2.75, color: small)
    }

    private static func disc(center: NSPoint, radius: CGFloat, color: NSColor) {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                    width: radius * 2, height: radius * 2)).fill()
    }

    private static func clear(center: NSPoint, radius: CGFloat) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        context.compositingOperation = .clear
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                    width: radius * 2, height: radius * 2)).fill()
        context.restoreGraphicsState()
    }
}

/// The same glyph for SwiftUI labels (e.g. MenuBarLabelView). Template when idle,
/// so it takes the primary color; red big bubble while recording.
struct MenuBarGlyphView: View {
    var recording = false

    var body: some View {
        Image(nsImage: recording ? MenuBarGlyph.recording : MenuBarGlyph.idle)
            .frame(width: MenuBarGlyph.size.width, height: MenuBarGlyph.size.height)
    }
}
