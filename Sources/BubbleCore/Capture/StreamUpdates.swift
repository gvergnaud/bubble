// One serial path for every change to a running SCStream (crop, mic, filter). Owner: capture track.
// Spec: docs/architecture.md §3.4 (architect review: crop updates at 10 Hz must not finish out of
// order or share a mutable configuration).

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit

/// Applies the latest wanted value, one call at a time. While a call is in flight, newer values
/// replace each other; when the call returns, the newest one is applied if it differs from what
/// was applied last. So a burst of changes ends on the last one, and calls never overlap.
public actor LatestOnly<Value: Equatable & Sendable> {
    /// `(applied, wanted)`: the value in effect and the one to apply.
    private let apply: @Sendable (Value, Value) async throws -> Void
    private var wanted: Value
    private var applied: Value
    private var running = false
    private var waiters: [CheckedContinuation<Error?, Never>] = []

    /// `initial`: the value already in effect (not applied again).
    public init(initial: Value, apply: @escaping @Sendable (_ applied: Value, _ wanted: Value) async throws -> Void) {
        self.apply = apply
        wanted = initial
        applied = initial
    }

    public var current: Value { wanted }
    public var inEffect: Value { applied }

    /// Changes the wanted value, then returns once a call made it take effect (nil) or failed
    /// (that error; the change stays wanted and the next update tries it again).
    @discardableResult
    public func update(_ change: @Sendable (inout Value) -> Void) async -> Error? {
        change(&wanted)
        if running { return await withCheckedContinuation { waiters.append($0) } }
        running = true
        var failure: Error?
        while wanted != applied {
            let (from, next) = (applied, wanted)
            do {
                try await apply(from, next)
                applied = next
            } catch {
                failure = error
                break
            }
        }
        running = false
        let done = waiters
        waiters = []
        for waiter in done { waiter.resume(returning: failure) }
        return failure
    }
}

/// Everything in an SCStreamConfiguration that can change during a take, as a value: a fresh
/// configuration is made from it for each call, never shared or mutated in flight.
struct StreamSettings: Sendable, Equatable {
    var width: Int
    var height: Int
    var fps: Int
    var showClicks: Bool
    var microphoneID: String?
    var computerSound: Bool
    /// Window/area mode: the recorded part of the display, display points.
    var crop: CGRect?

    func makeConfiguration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = true
        config.showMouseClicks = showClicks
        config.captureMicrophone = microphoneID != nil
        config.microphoneCaptureDeviceID = microphoneID
        config.capturesAudio = computerSound
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        if let crop {
            config.sourceRect = crop
            config.preservesAspectRatio = true
        }
        return config
    }
}

/// What a running stream should show: its settings and its content filter. Changes are ordered:
/// a crop only replaces an older crop (`cropSequence`), a filter an older filter (`filterVersion`),
/// since they come from tasks that may reach the path out of order.
struct StreamState: Sendable, Equatable {
    var settings: StreamSettings
    var cropSequence = 0
    var filterVersion = 0
    nonisolated(unsafe) var filter: SCContentFilter

    static func == (a: StreamState, b: StreamState) -> Bool {
        a.settings == b.settings && a.filterVersion == b.filterVersion
    }

    mutating func setCrop(_ crop: CGRect, sequence: Int) {
        guard sequence > cropSequence else { return }
        cropSequence = sequence
        settings.crop = crop
    }

    mutating func setFilter(_ filter: SCContentFilter, version: Int) {
        guard version > filterVersion else { return }
        filterVersion = version
        self.filter = filter
    }
}
