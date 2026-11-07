// Mic + computer sound into one contiguous mono track. Owner: capture track.
// Spec: docs/architecture.md §3.2.
//
// Confinement: not thread-safe. push() and pull() come from one serial queue (writerQueue in the
// app, the test's thread in tests). `@unchecked Sendable` only so that queue's blocks can hold it.

import AVFoundation
import CoreMedia
import os

public enum AudioSource: Sendable, Hashable { case microphone, computer }

/// Turns one or two live audio streams (mic, computer sound; any format) into one contiguous
/// 48 kHz mono Float32 stream: resample, place by timestamp, sum, fill holes with silence.
/// A source that sends nothing for `maxWait` counts as silent, so a dead mic never stalls the file.
/// 0.5 s by default: Bluetooth mics (AirPods) deliver 100-250 ms late.
///
/// Sample positions are absolute: index = host seconds × sampleRate. Each source keeps its own
/// continuity cursor, so the small jitter of buffer timestamps never clicks: a buffer that lands
/// within 10 ms of where the previous one ended is placed right after it; further away it is placed
/// by its own timestamp (a real hole, filled with silence, or an overlap, trimmed).
public final class AudioMixer: @unchecked Sendable {
    public static let chunkFrames = 1024

    public let sources: Set<AudioSource>
    public let sampleRate: Double
    public let maxWait: TimeInterval
    public let outputFormat: AVAudioFormat

    private var lanes: [AudioSource: Lane] = [:]
    /// Next output sample index. nil until the first buffer arrives.
    private var cursor: Int64?
    private let log = Logger(subsystem: "local.bubble.Bubble", category: "AudioMixer")

    public init(sources: Set<AudioSource>, sampleRate: Double = 48_000, maxWait: TimeInterval = 0.5) {
        self.sources = sources
        self.sampleRate = sampleRate
        self.maxWait = maxWait
        outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        for source in sources { lanes[source] = Lane(sampleRate: sampleRate, outputFormat: outputFormat) }
    }

    /// Buffers dropped because they came after their slot was already mixed (later than maxWait).
    public private(set) var lateFrames: Int64 = 0

    public func push(_ buffer: CMSampleBuffer, from source: AudioSource) {
        guard let lane = lanes[source] else { return }
        let pts = buffer.presentationTimeStamp
        guard buffer.isValid, pts.isNumeric, let samples = lane.convert(buffer) else { return }
        place(samples, at: pts, in: lane)
    }

    /// Mono Float32 samples at `sampleRate`, starting at host time `host`. For tests and for sources
    /// already in the mixer's format.
    public func push(samples: [Float], atHost host: CMTime, from source: AudioSource) {
        guard let lane = lanes[source], host.isNumeric else { return }
        place(samples, at: host, in: lane)
    }

    /// Mixed audio ready up to `host` (minus maxWait), in host time: whole 1024-frame chunks.
    public func pull(upToHost host: CMTime) -> [(AVAudioPCMBuffer, CMTime)] {
        guard host.isNumeric else { return [] }
        let limit = index(of: host) - Int64((maxWait * sampleRate).rounded())
        return mix(upTo: limit, partialLast: false)
    }

    /// Everything up to `host` (no maxWait), the last chunk possibly short. At stop.
    public func flush(upToHost host: CMTime) -> [(AVAudioPCMBuffer, CMTime)] {
        guard host.isNumeric else { return [] }
        return mix(upTo: index(of: host), partialLast: true)
    }

    // MARK: - Private

    private func index(of time: CMTime) -> Int64 {
        Int64((time.seconds * sampleRate).rounded())
    }

    private func place(_ samples: [Float], at pts: CMTime, in lane: Lane) {
        guard !samples.isEmpty else { return }
        var start = index(of: pts)
        if let end = lane.end, abs(start - end) <= Int64(0.010 * sampleRate) { start = end }
        if cursor == nil { cursor = start }
        lane.write(samples, at: start, droppingBefore: cursor!, late: &lateFrames)
    }

    private func mix(upTo limit: Int64, partialLast: Bool) -> [(AVAudioPCMBuffer, CMTime)] {
        guard var position = cursor else { return [] }
        var out: [(AVAudioPCMBuffer, CMTime)] = []
        let chunk = Int64(Self.chunkFrames)
        while position < limit {
            let count = min(chunk, limit - position)
            if count < chunk && !partialLast { break }
            let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            let dst = buffer.floatChannelData![0]
            dst.initialize(repeating: 0, count: Int(count))
            for lane in lanes.values { lane.add(into: dst, from: position, count: Int(count)) }
            for i in 0..<Int(count) { dst[i] = min(1, max(-1, dst[i])) }
            out.append((buffer, CMTime(value: position, timescale: CMTimeScale(sampleRate))))
            position += count
        }
        cursor = position
        for lane in lanes.values { lane.discard(before: position) }
        return out
    }
}

/// One source: its converter and its pending samples. Same confinement as AudioMixer.
private final class Lane {
    let sampleRate: Double
    let outputFormat: AVAudioFormat
    /// Pending samples; samples[i] is at absolute index base + i.
    private var samples: [Float] = []
    private var base: Int64 = 0
    /// End index of the last buffer placed (continuity cursor).
    private(set) var end: Int64?

    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?

    init(sampleRate: Double, outputFormat: AVAudioFormat) {
        self.sampleRate = sampleRate
        self.outputFormat = outputFormat
    }

    /// Any LPCM CMSampleBuffer → mono Float32 at sampleRate. nil if it cannot be read.
    func convert(_ buffer: CMSampleBuffer) -> [Float]? {
        guard let description = buffer.formatDescription,
              let asbd = description.audioStreamBasicDescription, asbd.mFormatID == kAudioFormatLinearPCM else { return nil }
        let frames = CMSampleBufferGetNumSamples(buffer)
        guard frames > 0 else { return [] }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        input.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(buffer, at: 0, frameCount: Int32(frames),
                                                                  into: input.mutableAudioBufferList)
        guard status == noErr else { return nil }
        return convert(input)
    }

    func convert(_ input: AVAudioPCMBuffer) -> [Float]? {
        let format = input.format
        let frames = Int(input.frameLength)
        if format.commonFormat == .pcmFormatFloat32, format.sampleRate == sampleRate, format.channelCount == 1,
           let data = input.floatChannelData {
            return Array(UnsafeBufferPointer(start: data[0], count: frames))
        }
        if converter == nil || converterInput != format {
            converter = AVAudioConverter(from: format, to: outputFormat)
            converter?.downmix = true
            converterInput = format
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(frames) * sampleRate / format.sampleRate) + 64
        var result: [Float] = []
        let feed = OneShotFeed(input)
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                guard let next = feed.take() else { inputStatus.pointee = .noDataNow; return nil }
                inputStatus.pointee = .haveData
                return next
            }
            if output.frameLength > 0, let data = output.floatChannelData {
                result.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
            }
            if status == .error { return nil }
            if status != .haveData || output.frameLength == 0 { break }
        }
        return result
    }

    /// Writes samples at absolute index `start`, overwriting any overlap, dropping what is before `floor`.
    func write(_ new: [Float], at start: Int64, droppingBefore floor: Int64, late: inout Int64) {
        var start = start
        var slice = new[...]
        if start < floor {
            let skip = Int(min(Int64(slice.count), floor - start))
            late += Int64(skip)
            slice = slice.dropFirst(skip)
            start = floor
        }
        end = max(end ?? 0, start + Int64(slice.count))
        guard !slice.isEmpty else { return }
        if samples.isEmpty { base = start }
        if start < base {
            // Earlier than what is pending (a timestamp jump back): keep the newest, drop the rest.
            samples.removeAll(keepingCapacity: true)
            base = start
        }
        let offset = Int(start - base)
        if offset > samples.count { samples.append(contentsOf: repeatElement(0, count: offset - samples.count)) }
        let overlap = min(slice.count, samples.count - offset)
        if overlap > 0 {
            samples.replaceSubrange(offset..<(offset + overlap), with: slice.prefix(overlap))
        }
        samples.append(contentsOf: slice.dropFirst(overlap))
    }

    /// Adds samples [from, from + count) into dst; missing samples count as silence.
    func add(into dst: UnsafeMutablePointer<Float>, from: Int64, count: Int) {
        let lo = max(from, base), hi = min(from + Int64(count), base + Int64(samples.count))
        guard lo < hi else { return }
        samples.withUnsafeBufferPointer { src in
            for i in lo..<hi { dst[Int(i - from)] += src[Int(i - base)] }
        }
    }

    func discard(before index: Int64) {
        guard index > base else { return }
        let n = Int(min(Int64(samples.count), index - base))
        samples.removeFirst(n)
        base = samples.isEmpty ? index : base + Int64(n)
    }
}

/// Hands one buffer to AVAudioConverter's input block, then reports no data. The block runs
/// synchronously inside convert(), on the caller's queue.
private final class OneShotFeed: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? { defer { buffer = nil }; return buffer }
}
