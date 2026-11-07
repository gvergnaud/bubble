// Encoder settings for a take. Owner: capture track. Pure values; spec: docs/architecture.md §3.

import CoreGraphics
import Foundation

public struct VideoSettings: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public var averageBitRate: Int
    public var keyFrameIntervalSeconds: Double
    public var fragmentIntervalSeconds: Double

    public init(width: Int, height: Int, fps: Int = 30, averageBitRate: Int,
                keyFrameIntervalSeconds: Double = 2, fragmentIntervalSeconds: Double = 2) {
        self.width = width; self.height = height; self.fps = fps; self.averageBitRate = averageBitRate
        self.keyFrameIntervalSeconds = keyFrameIntervalSeconds; self.fragmentIntervalSeconds = fragmentIntervalSeconds
    }

    /// Native pixels of the display, long side capped at `maxLongSide`, even sizes, aspect kept.
    /// e.g. 1512x982 pt @2x -> 3024x1964; 2560x1440 pt @2x (5K) -> 3840x2160.
    public static func forDisplay(pointSize: CGSize, scale: CGFloat, maxLongSide: Int = 3840, fps: Int = 30) -> VideoSettings {
        var w = Double(pointSize.width * scale)
        var h = Double(pointSize.height * scale)
        let longSide = max(w, h)
        if longSide > Double(maxLongSide), longSide > 0 {
            let k = Double(maxLongSide) / longSide
            w *= k; h *= k
        }
        let width = evenPixels(w), height = evenPixels(h)
        return VideoSettings(width: width, height: height, fps: fps,
                             averageBitRate: bitRate(width: width, height: height, fps: fps))
    }

    /// clamp(w × h × fps × 0.04, 4 Mb/s, 16 Mb/s): ≈ 7 Mb/s at 3024×1964, 30 fps.
    public static func bitRate(width: Int, height: Int, fps: Int) -> Int {
        let raw = Double(width) * Double(height) * Double(fps) * 0.04
        return Int(min(max(raw, 4_000_000), 16_000_000))
    }

    /// H.264 4:2:0 wants even sizes. Rounds down to even, at least 2.
    private static func evenPixels(_ value: Double) -> Int {
        max(2, Int(value.rounded()) / 2 * 2)
    }
}

public struct AudioSettings: Sendable, Equatable {
    public var sampleRate: Double = 48_000
    public var channels: Int = 1
    public var bitRate: Int = 128_000
    public init() {}
}
