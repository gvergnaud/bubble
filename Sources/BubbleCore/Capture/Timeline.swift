// Pause/resume math. Owner: capture track. Pure value; spec: docs/architecture.md §3 (Pause).

import CoreMedia

/// Maps host-clock times (CMClockGetHostTimeClock, the clock of every ScreenCaptureKit sample) to
/// file times, cutting out paused spans. Pure value: unit-test it without any capture.
///
/// A sample is judged by the host time it was captured at, not by when it arrives: a mic buffer
/// captured just before Pause but delivered after it is still written, and one captured during a
/// past pause is dropped even if it arrives after Resume.
public struct Timeline: Sendable, Equatable {
    private struct Span: Sendable, Equatable { var start: CMTime; var end: CMTime }

    private var startHost: CMTime?
    /// Closed paused spans, in host time, in order.
    private var pauses: [Span] = []
    /// Host time of the current pause, if paused.
    private var pausedAt: CMTime?

    public init() {}

    public var isStarted: Bool { startHost != nil }
    public var isPaused: Bool { pausedAt != nil }

    public mutating func start(at host: CMTime) {
        startHost = host
        pauses = []
        pausedAt = nil
    }

    /// Ignored before start or when already paused.
    public mutating func pause(at host: CMTime) {
        guard let startHost, pausedAt == nil else { return }
        pausedAt = CMTimeMaximum(host, CMTimeMaximum(startHost, pauses.last?.end ?? startHost))
    }

    /// Ignored when not paused.
    public mutating func resume(at host: CMTime) {
        guard let pausedAt else { return }
        pauses.append(Span(start: pausedAt, end: CMTimeMaximum(host, pausedAt)))
        self.pausedAt = nil
    }

    /// nil before start or while paused (drop the sample).
    public func fileTime(forHost host: CMTime) -> CMTime? {
        guard let startHost, host.isNumeric, host >= startHost else { return nil }
        if let pausedAt, host >= pausedAt { return nil }
        var cut = CMTime.zero
        for span in pauses {
            if host < span.start { break }
            if host < span.end { return nil }
            cut = cut + (span.end - span.start)
        }
        return host - startHost - cut
    }

    /// Seconds of video at `host` (paused time excluded). 0 before start; frozen while paused.
    public func elapsed(atHost host: CMTime) -> TimeInterval {
        guard let startHost else { return 0 }
        var end = host
        if let pausedAt, end > pausedAt { end = pausedAt }
        guard end > startHost else { return 0 }
        var cut = CMTime.zero
        for span in pauses where span.start < end {
            cut = cut + (CMTimeMinimum(span.end, end) - span.start)
        }
        return max(0, (end - startHost - cut).seconds)
    }
}
