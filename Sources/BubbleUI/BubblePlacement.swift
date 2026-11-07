// Owner: app/UI track. Where the camera bubble sits: sizes, corners, snap, per-display memory.
// Pure math on CGRects (AppKit global points, origin bottom-left). Tested in BubblePlacementTests.
import CoreGraphics
import Foundation

public enum BubbleSize: String, Sendable, CaseIterable, Codable {
    case small, medium, large

    /// Diameter in points (design.md §6.3).
    public var diameter: CGFloat {
        switch self {
        case .small: 120
        case .medium: 180
        case .large: 260
        }
    }

    public var letter: String {
        switch self {
        case .small: "S"
        case .medium: "M"
        case .large: "L"
        }
    }

    public var name: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }
}

public enum BubbleCorner: String, Sendable, CaseIterable, Codable {
    case bottomLeft, bottomRight, topLeft, topRight
}

/// The bubble's place on one display. Remembered per display.
public struct BubblePlace: Sendable, Equatable, Codable {
    public var size: BubbleSize
    /// Set when the bubble is snapped to a corner (it stays there when resized).
    public var corner: BubbleCorner?
    /// Center of the bubble relative to the display's usable area, in 0...1 on each axis. Used when
    /// `corner` is nil. Relative so it survives a resolution change.
    public var relativeCenter: CGPoint

    public init(size: BubbleSize = .medium, corner: BubbleCorner? = .bottomLeft, relativeCenter: CGPoint = .zero) {
        self.size = size; self.corner = corner; self.relativeCenter = relativeCenter
    }

    /// Design default: M, bottom-left, 24 pt margin.
    public static let `default` = BubblePlace()
}

public enum BubblePlacement {
    /// Distance from the display's edges when snapped to a corner.
    public static let margin: CGFloat = 24
    /// A drop closer than this to a corner position snaps to it.
    public static let snapDistance: CGFloat = 64

    /// The key under which a display's bubble place is remembered.
    public static func displayKey(_ id: CGDirectDisplayID) -> String { String(id) }

    /// The bubble's square frame for `place` inside `area` (the display's usable area).
    public static func frame(for place: BubblePlace, in area: CGRect) -> CGRect {
        let d = place.size.diameter
        if let corner = place.corner {
            return CGRect(origin: cornerOrigin(corner, diameter: d, in: area), size: CGSize(width: d, height: d))
        }
        let center = CGPoint(x: area.minX + place.relativeCenter.x * area.width,
                             y: area.minY + place.relativeCenter.y * area.height)
        let rect = CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)
        return clamp(rect, in: area)
    }

    /// Where a bubble dropped at `dropped` (its frame after a drag) ends up: snapped to the nearest
    /// corner within `snapDistance`, else kept where it is, always fully inside `area`.
    /// A drop whose center is off the area (another display) snaps to the nearest corner.
    public static func place(afterDropping dropped: CGRect, size: BubbleSize, in area: CGRect) -> BubblePlace {
        let d = size.diameter
        let center = CGPoint(x: dropped.midX, y: dropped.midY)
        let nearest = BubbleCorner.allCases.min { a, b in
            distance(dropped.origin, cornerOrigin(a, diameter: d, in: area)) <
                distance(dropped.origin, cornerOrigin(b, diameter: d, in: area))
        }!
        if !area.contains(center) || distance(dropped.origin, cornerOrigin(nearest, diameter: d, in: area)) <= snapDistance {
            return BubblePlace(size: size, corner: nearest)
        }
        let clamped = clamp(CGRect(origin: dropped.origin, size: CGSize(width: d, height: d)), in: area)
        return BubblePlace(size: size, corner: nil, relativeCenter: relative(CGPoint(x: clamped.midX, y: clamped.midY), in: area))
    }

    /// The same place with another size: a snapped bubble stays in its corner, a free one keeps its center.
    public static func resized(_ place: BubblePlace, to size: BubbleSize) -> BubblePlace {
        var p = place
        p.size = size
        return p
    }

    /// The frame while dragging: follows the mouse but never leaves `area`'s display entirely
    /// (the drop decides the final place).
    public static func dragFrame(start: CGRect, mouseDelta: CGSize) -> CGRect {
        start.offsetBy(dx: mouseDelta.width, dy: mouseDelta.height)
    }

    public static func cornerOrigin(_ corner: BubbleCorner, diameter d: CGFloat, in area: CGRect) -> CGPoint {
        switch corner {
        case .bottomLeft: CGPoint(x: area.minX + margin, y: area.minY + margin)
        case .bottomRight: CGPoint(x: area.maxX - margin - d, y: area.minY + margin)
        case .topLeft: CGPoint(x: area.minX + margin, y: area.maxY - margin - d)
        case .topRight: CGPoint(x: area.maxX - margin - d, y: area.maxY - margin - d)
        }
    }

    static func clamp(_ rect: CGRect, in area: CGRect) -> CGRect {
        var r = rect
        r.origin.x = min(max(r.minX, area.minX), area.maxX - r.width)
        r.origin.y = min(max(r.minY, area.minY), area.maxY - r.height)
        return r
    }

    static func relative(_ point: CGPoint, in area: CGRect) -> CGPoint {
        CGPoint(x: area.width > 0 ? (point.x - area.minX) / area.width : 0.5,
                y: area.height > 0 ? (point.y - area.minY) / area.height : 0.5)
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}
