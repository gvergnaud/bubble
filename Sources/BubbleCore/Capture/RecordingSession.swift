// The recording core of one take: frames and audio in host time → pump, mixer, timeline → writer.
// Owner: capture track. Spec: docs/architecture.md §3 (pipeline, Pause, Stop, Writer failure).
//
// Confinement: every method runs on ONE serial queue (LiveRecorder's writerQueue: SCK's sample
// handlers and the 30 Hz tick are delivered there). No locks; `@unchecked Sendable` only so that
// queue's blocks can hold it. It knows nothing about ScreenCaptureKit, so tests drive it with
// synthetic frames and a fake host clock, faster than real time.

import AVFoundation
import CoreMedia
import os

public final class RecordingSession: @unchecked Sendable {
    public let writer: RecordingWriter
    public private(set) var timeline = Timeline()
    /// The first writer failure (disk full, encoder error). Nothing is written after it.
    public private(set) var failure: String?
    /// Called once, on the queue, after the first frame is written (its host time).
    public var onFirstFrame: (@Sendable (CMTime) -> Void)?
    /// Called once, on the queue, when the writer fails.
    public var onFailure: (@Sendable (String) -> Void)?

    private let mixer: AudioMixer?
    /// The pump's sink gets FILE times: slots of the 30 fps grid (see pumpVideo).
    private lazy var pump = FramePump(fps: writer.video.fps) { [unowned self] pixelBuffer, time in
        self.writeFrame(pixelBuffer, at: time)
    }
    /// Next slot of the constant-frame-rate grid, in frames of file time (slot n is at n / fps).
    private var nextSlot: Int64 = 0
    private var finished = false
    private var lastDropCheck: CMTime?
    private var lastDropCount = 0
    private let log = Logger(subsystem: "local.bubble.Bubble", category: "RecordingSession")

    /// `audioSources` empty = no audio track (the writer must have been made with `audio: nil`).
    /// `audioMaxWait`: how late a source may be (AudioMixer).
    public init(writer: RecordingWriter, audioSources: Set<AudioSource>, audioMaxWait: TimeInterval = 0.5) {
        self.writer = writer
        mixer = audioSources.isEmpty ? nil : AudioMixer(sources: audioSources, maxWait: audioMaxWait)
    }

    public var isStarted: Bool { timeline.isStarted }

    // MARK: Inputs (host time)

    /// A complete screen frame. The first one starts the take at its capture time and is written at once.
    public func screenFrame(_ pixelBuffer: CVPixelBuffer, at host: CMTime) {
        guard !finished, failure == nil else { return }
        pump.submit(pixelBuffer)
        if !timeline.isStarted, host.isNumeric {
            timeline.start(at: host)
            pumpVideo(upTo: .zero)
            if failure == nil { onFirstFrame?(host) }
        }
    }

    public func audio(_ buffer: CMSampleBuffer, from source: AudioSource) {
        guard !finished else { return }
        mixer?.push(buffer, from: source)
    }

    /// The 30 Hz tick: the mixed audio that is ready, then the latest frame at `host`.
    public func tick(at host: CMTime) {
        guard timeline.isStarted, !finished, failure == nil else { return }
        if let mixer { writeAudio(mixer.pull(upToHost: host)) }
        if let now = timeline.fileTime(forHost: host) { pumpVideo(upTo: now) }
        logDrops(at: host)
    }

    /// Frames dropped under load leave a video gap, and a gap can fail the writer at the next
    /// fragment (§6). Logged once per fragment interval when it happens, to see it coming.
    private func logDrops(at host: CMTime) {
        let interval = CMTime(seconds: writer.video.fragmentIntervalSeconds, preferredTimescale: 600)
        guard let last = lastDropCheck else { lastDropCheck = host; return }
        guard host - last >= interval else { return }
        lastDropCheck = host
        let dropped = writer.videoFramesDropped
        if dropped > lastDropCount {
            log.warning("encoder busy: \(dropped - self.lastDropCount, privacy: .public) frames dropped in the last \(interval.seconds, privacy: .public) s (\(dropped, privacy: .public) in all)")
            lastDropCount = dropped
        }
    }

    public func pause(at host: CMTime) { timeline.pause(at: host) }
    public func resume(at host: CMTime) { timeline.resume(at: host) }

    /// Seconds of video at `host`, paused time excluded.
    public func elapsed(atHost host: CMTime) -> TimeInterval { timeline.elapsed(atHost: host) }

    // MARK: Stop

    /// On the queue, after capture stopped: writes the audio up to `host` and returns the file time
    /// to end the file at. Then call `writer.finish(at:)` (off the queue is fine: nothing else
    /// touches the session any more).
    public func prepareFinish(at host: CMTime) -> CMTime {
        let end = CMTime(seconds: timeline.elapsed(atHost: host), preferredTimescale: 48_000)
        if !finished, failure == nil, timeline.isStarted {
            if let mixer { writeAudio(mixer.flush(upToHost: host)) }
            // Fill the grid up to the end (a slot exactly at the end would last 0 s: left out).
            let frame = CMTime(value: 1, timescale: CMTimeScale(writer.video.fps))
            pumpVideo(upTo: end - CMTimeMultiplyByFloat64(frame, multiplier: 0.5))
        }
        finished = true
        pump.reset()
        return end
    }

    // MARK: - Private

    /// Video sits on an exact grid of file time: slot n at n / fps. Each tick appends the latest
    /// frame to every slot due since the last tick, so a late tick (timer jitter, a busy queue) is
    /// caught up instead of leaving a hole, and the first frame's delivery delay never shows as a
    /// gap. Past 1 s behind (a long stall), the older slots are skipped.
    /// Known limit: that skip leaves a video gap, the condition that fails the fragment writer
    /// (-16341, docs/architecture.md §6). So a system freeze over 1 s may end the take through
    /// the failure path (file kept, playable to the last fragment). Accepted (architect review).
    private func pumpVideo(upTo time: CMTime) {
        guard time.isNumeric, failure == nil else { return }
        let fps = Int64(writer.video.fps)
        let due = Int64((time.seconds * Double(fps)).rounded(.down))
        if due - nextSlot >= fps {
            log.warning("video \(due - self.nextSlot, privacy: .public) frames behind: skipping to the last second")
            nextSlot = due - fps + 1
        }
        while nextSlot <= due, failure == nil {
            pump.tick(at: CMTime(value: nextSlot, timescale: CMTimeScale(fps)))
            nextSlot += 1
        }
    }

    private func writeFrame(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard failure == nil else { return }
        do {
            try writer.appendVideo(pixelBuffer, at: time)
        } catch WriterError.nonIncreasingTime {
            // Cannot happen on the grid; skip rather than fail the take.
        } catch {
            fail(error)
        }
    }

    /// Mixer chunks are in host time; keep the parts outside the paused spans, at their file times.
    private func writeAudio(_ chunks: [(AVAudioPCMBuffer, CMTime)]) {
        for (buffer, host) in chunks where failure == nil {
            for (part, time) in Self.split(buffer, at: host, by: timeline) {
                do {
                    try writer.appendAudio(part, at: time)
                } catch WriterError.nonIncreasingTime {
                    log.error("audio chunk out of order at \(time.seconds, privacy: .public) s, dropped")
                } catch {
                    fail(error)
                }
            }
        }
    }

    /// Splits a chunk that starts at host time `host` into the runs of samples that have a file time.
    static func split(_ buffer: AVAudioPCMBuffer, at host: CMTime, by timeline: Timeline) -> [(AVAudioPCMBuffer, CMTime)] {
        let frames = Int(buffer.frameLength)
        let rate = buffer.format.sampleRate
        func hostOf(_ i: Int) -> CMTime { host + CMTime(value: CMTimeValue(i), timescale: CMTimeScale(rate)) }
        // Fast path: first and last samples are in the same live span.
        if let first = timeline.fileTime(forHost: hostOf(0)), let last = timeline.fileTime(forHost: hostOf(frames - 1)),
           abs((last - first).seconds - Double(frames - 1) / rate) < 0.5 / rate {
            return [(buffer, first)]
        }
        var runs: [(Int, Int, CMTime)] = []
        var i = 0
        while i < frames {
            guard let start = timeline.fileTime(forHost: hostOf(i)) else { i += 1; continue }
            var j = i + 1
            while j < frames, timeline.fileTime(forHost: hostOf(j)) != nil { j += 1 }
            runs.append((i, j, start))
            i = j
        }
        return runs.compactMap { from, to, time in
            guard let part = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(to - from)),
                  let src = buffer.floatChannelData?[0], let dst = part.floatChannelData?[0] else { return nil }
            part.frameLength = AVAudioFrameCount(to - from)
            dst.update(from: src + from, count: to - from)
            return (part, time)
        }
    }

    private func fail(_ error: Error) {
        guard failure == nil else { return }
        let message: String
        if case WriterError.appendFailed(let text) = error { message = text } else { message = "\(error)" }
        failure = message
        log.error("writer failed: \(message, privacy: .public)")
        onFailure?(message)
    }
}
