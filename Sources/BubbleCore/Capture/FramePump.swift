// Constant frame rate for the video track: the fix for the writer bug. Owner: capture track.
// Spec: docs/architecture.md §6.
//
// Confinement: not thread-safe. submit() and tick() come from one serial queue (writerQueue in the
// app, the test's thread in tests). `@unchecked Sendable` only so that queue's blocks can hold it.

import CoreMedia
import CoreVideo

/// Keeps the video track at a constant frame rate: ScreenCaptureKit sends no frame while the screen
/// does not change, and AVAssetWriter with movie fragments + audio fails (-16341) after a video gap.
/// `submit` stores the latest screen frame; `tick` (30 Hz timer in the app, direct calls in tests)
/// appends the latest frame at that tick's time.
public final class FramePump: @unchecked Sendable {
    public let fps: Int
    private let sink: @Sendable (CVPixelBuffer, CMTime) -> Void
    private var latest: CVPixelBuffer?
    private var lastTick: CMTime?

    /// Ticks (frames handed to the sink) and ticks skipped because they came too soon after the last.
    public private(set) var ticks = 0
    public private(set) var skippedTicks = 0

    public init(fps: Int, sink: @escaping @Sendable (CVPixelBuffer, CMTime) -> Void) {
        self.fps = max(1, fps)
        self.sink = sink
    }

    /// The newest screen frame. Nothing is written until the next tick.
    public func submit(_ pixelBuffer: CVPixelBuffer) {
        latest = pixelBuffer
    }

    /// The frame that the next tick would append (nil before the first submit).
    public var latestFrame: CVPixelBuffer? { latest }

    /// Appends the latest frame at `time`. Does nothing before the first frame, and ignores a tick
    /// less than half a frame after the previous one (timer jitter), so times stay strictly increasing.
    public func tick(at time: CMTime) {
        guard let latest, time.isNumeric else { return }
        if let lastTick {
            let half = CMTime(value: 1, timescale: CMTimeScale(fps * 2))
            if time - lastTick < half { skippedTicks += 1; return }
        }
        lastTick = time
        ticks += 1
        sink(latest, time)
    }

    /// Drops the held frame (at stop, so SCK's buffer goes back to its pool).
    public func reset() {
        latest = nil
        lastTick = nil
    }
}
