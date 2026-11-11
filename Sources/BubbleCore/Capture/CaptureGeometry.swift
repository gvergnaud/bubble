// Geometry of window and area recording. Owner: capture track. Pure values, no ScreenCaptureKit:
// unit-test it. Spec: docs/architecture.md (window/area recording).
//
// Two global coordinate spaces meet here:
// - AppKit global points (NSWindow.frame, NSScreen.frame, the app's area rectangle): origin at the
//   BOTTOM-left of the main display, y up.
// - CG global points (CGWindowListCopyWindowInfo bounds, CGDisplayBounds, SCWindow.frame): origin at
//   the TOP-left of the main display, y down.
// SCStreamConfiguration.sourceRect is in the recorded display's own points, top-left origin.

import CoreGraphics

public enum CaptureGeometry {
    /// A crop smaller than this (points, either side) is not worth recording.
    public static let minimumSide: CGFloat = 64

    /// AppKit global → CG global. `mainDisplayHeight`: height in points of the main display
    /// (the one at the origin of both spaces).
    public static func cgGlobal(fromAppKit rect: CGRect, mainDisplayHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainDisplayHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// CG global → AppKit global. The same flip, both ways.
    public static func appKitGlobal(fromCG rect: CGRect, mainDisplayHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainDisplayHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The part of `rect` (CG global) on the display (`displayBounds`, CG global), in the display's
    /// own points (top-left origin), rounded out to whole points. nil if less than `minimumSide`
    /// of it is on that display.
    public static func crop(_ rect: CGRect, onDisplay displayBounds: CGRect) -> CGRect? {
        let visible = rect.standardized.intersection(displayBounds)
        guard !visible.isNull, visible.width >= minimumSide, visible.height >= minimumSide else { return nil }
        let local = visible.offsetBy(dx: -displayBounds.minX, dy: -displayBounds.minY)
        return local.integral
    }

    /// Share of `rect` (CG global) that is on the display, 0...1.
    public static func fractionOnDisplay(_ rect: CGRect, displayBounds: CGRect) -> CGFloat {
        let area = rect.width * rect.height
        guard area > 0 else { return 0 }
        let visible = rect.standardized.intersection(displayBounds)
        guard !visible.isNull else { return 0 }
        return visible.width * visible.height / area
    }

    /// Encoder settings for a crop of `cropSize` points at `scale` pixels per point: native pixels,
    /// long side capped, even sizes (VideoSettings.forDisplay does exactly that).
    public static func videoSettings(cropSize: CGSize, scale: CGFloat, maxLongSide: Int = 3840, fps: Int = 30) -> VideoSettings {
        VideoSettings.forDisplay(pointSize: cropSize, scale: scale, maxLongSide: maxLongSide, fps: fps)
    }

    // MARK: Following a window during a take

    /// What the window server says about the recorded window now. nil = it no longer exists.
    public struct WindowSample: Sendable, Equatable {
        /// CG global points.
        public var bounds: CGRect
        public var isOnScreen: Bool
        /// Its app is hidden (⌘H): NSRunningApplication.isHidden.
        public var appHidden: Bool
        public init(bounds: CGRect, isOnScreen: Bool, appHidden: Bool = false) {
            self.bounds = bounds; self.isOnScreen = isOnScreen; self.appHidden = appHidden
        }
    }

    public enum WindowChange: Sendable, Equatable {
        case unchanged
        /// New crop, in the display's own points.
        case moved(crop: CGRect)
        /// Can't be recorded now (app hidden, minimized or on another Space, mostly on another
        /// display): pause.
        case hidden(WindowHiddenReason)
        /// Back after `hidden`, at this crop. The take stays paused (the user resumes).
        case visibleAgain(crop: CGRect)
        /// Closed (or its app quit): stop and save.
        case gone
    }

    /// Compares the last known crop with a new sample. `wasHidden`: the last decision was `hidden`.
    /// Less than half the window on the recorded display, and more of it on another display
    /// (`otherDisplays`, CG global), counts as hidden (.otherDisplay): the crop never switches
    /// display (design.md §11.4). Less than half on ours and no more anywhere else is the minimize
    /// animation shrinking the window into the Dock (seen in the real run): wait, `.unchanged`.
    public static func follow(lastCrop: CGRect, wasHidden: Bool, sample: WindowSample?, displayBounds: CGRect,
                              otherDisplays: [CGRect] = []) -> WindowChange {
        guard let sample else { return .gone }
        let reason: WindowHiddenReason?
        let onOurs = fractionOnDisplay(sample.bounds, displayBounds: displayBounds)
        if sample.appHidden {
            reason = .appHidden
        } else if !sample.isOnScreen {
            reason = .notOnScreen
        } else if onOurs < 0.5 {
            let elsewhere = otherDisplays.map { fractionOnDisplay(sample.bounds, displayBounds: $0) }.max() ?? 0
            guard elsewhere > onOurs else { return .unchanged }
            reason = .otherDisplay
        } else {
            reason = nil
        }
        guard reason == nil, let crop = crop(sample.bounds, onDisplay: displayBounds) else {
            return wasHidden ? .unchanged : .hidden(reason ?? .otherDisplay)
        }
        if wasHidden { return .visibleAgain(crop: crop) }
        return crop == lastCrop ? .unchanged : .moved(crop: crop)
    }
}
