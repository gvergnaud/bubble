// Owner: E2 (media). docs/editor-architecture.md §4: the export's sound, with a short crossfade at every
// join (a cut, or a change of speed) instead of a butt splice, which clicks. Each kept piece is read on its
// own (pitch kept at its rate) with a little extra sound on both sides: the end of a piece fades out over
// the sound just after it in the recording while the next piece fades in over the sound just before it.
// Equal-power curves (cos/sin): the level stays even across the join. The picture is not touched: it
// stays a hard cut.
import AVFoundation
import CoreMedia
import Foundation

/// Where every piece's sound goes in the output, in samples. Pure (tested).
struct AudioJoinPlan: Equatable {
    struct Part: Equatable {
        /// Source seconds to read (the piece plus its extensions), clamped to the recording.
        var sourceStart: Double
        var sourceEnd: Double
        var rate: Double
        /// Output sample of this part's first sample (the piece's start minus its fade-in half).
        var outputStart: Int
        /// Samples this part fills in the output (its extensions included).
        var length: Int
        /// Samples read before the part and thrown away. The pitch-keeping (spectral) stretcher ramps up over
        /// its first ~15 ms, sometimes drops out somewhere in its first ~110 ms (it depends on how its buffers
        /// fall: 2-3 runs in 30 at 30 ms of pre-roll, none at 150 ms or more), and rings out past its end.
        /// So a part reads 200 ms more on both sides. Its timing is right: onsets within 4 ms at 1.5× and 2×,
        /// 10 ms at 0.5×.
        var preRoll: Int
        /// Samples of crossfade with the previous part (0 for the first) and the next part (0 for the last).
        var fadeIn: Int
        var fadeOut: Int
        /// The next piece continues the same sound (a speed change, no cut). Still an equal-power fade: the
        /// pitch-keeping stretcher decorrelates the two sides, and an equal-gain fade dipped 3-4 dB there
        /// (measured on noise); equal power stays within ±1.5 dB at every join.
        var continuesIntoNext: Bool
    }

    var parts: [Part]
    /// Output samples in all.
    var total: Int

    /// `outputStarts[i]`: where piece i starts in the output (seconds); `end`: the output's end (seconds).
    /// `crossfade`: total length of a fade (seconds), shortened where a piece is too short or the recording
    /// has no sound beyond.
    static func make(pieces: [MediaPiece], outputStarts: [Double], end: Double, sourceDuration: Double,
                     crossfade: Double, sampleRate: Int) -> AudioJoinPlan {
        let sr = Double(sampleRate)
        let n = pieces.count
        guard n > 0 else { return AudioJoinPlan(parts: [], total: 0) }
        let starts = outputStarts.map { Int(($0 * sr).rounded()) } + [Int((end * sr).rounded())]
        let lengths = (0..<n).map { max(0, starts[$0 + 1] - starts[$0]) }
        let wanted = max(0, Int((crossfade / 2 * sr).rounded()))
        // Half-length of the fade at the join before piece i (0 for i = 0).
        var half = [Int](repeating: 0, count: n + 1)
        for i in 1..<max(1, n) where i < n {
            let before = pieces[i - 1], after = pieces[i]
            let roomAfterPrevious = Int(((sourceDuration - before.end) / before.rate * sr).rounded(.down))
            let roomBeforeNext = Int((after.start / after.rate * sr).rounded(.down))
            half[i] = max(0, min(wanted, lengths[i - 1] / 2, lengths[i] / 2, roomAfterPrevious, roomBeforeNext))
        }
        let roll = Int((Self.roll * sr).rounded())
        let parts = (0..<n).map { i -> Part in
            let p = pieces[i]
            let hIn = half[i], hOut = half[i + 1]
            let first = p.start - Double(hIn) / sr * p.rate
            let pre = max(0, min(roll, Int((first / p.rate * sr).rounded(.down))))
            return Part(sourceStart: max(0, first - Double(pre) / sr * p.rate),
                        sourceEnd: min(sourceDuration, p.end + Double(hOut + roll) / sr * p.rate),
                        rate: p.rate, outputStart: starts[i] - hIn, length: lengths[i] + hIn + hOut, preRoll: pre,
                        fadeIn: 2 * hIn, fadeOut: 2 * hOut,
                        continuesIntoNext: i + 1 < n && abs(pieces[i + 1].start - p.end) < 1e-6)
        }
        return AudioJoinPlan(parts: parts, total: starts[n])
    }

    /// Extra sound read before and after each part (seconds of output), see `Part.preRoll`.
    static let roll = 0.200

    /// Gains of the outgoing and incoming sides at sample k of a fade of `length` samples.
    static func gains(_ k: Int, of length: Int, equalPower: Bool) -> (out: Float, in: Float) {
        let t = (Double(k) + 0.5) / Double(max(1, length))
        if equalPower { return (Float(cos(t * .pi / 2)), Float(sin(t * .pi / 2))) }
        return (Float(1 - t), Float(t))
    }
}

/// Pulls the joined sound as LPCM sample buffers (48 kHz mono Float32), one piece's reader at a time.
/// Used by the export's audio pump on its own queue.
final class AudioJoiner: @unchecked Sendable {
    static let sampleRate = 48_000
    enum Failure: Error { case read(String) }

    private let track: AVAssetTrack
    private let available: CMTimeRange
    private let plan: AudioJoinPlan
    private let format: CMAudioFormatDescription
    private let lock = NSLock()

    private var index = -1
    private var reader: AVAssetReader?
    private var output: AVAssetReaderOutput?
    private var position = 0          // samples of the current part produced so far (padding included)
    private var leadingZeros = 0      // silence before the recording's sound starts, in the current part's raw stream
    private var raw = 0               // raw samples of the current part so far (pre-roll and padding included)
    private var skipped = 0           // pre-roll samples thrown away so far
    private var previousTail: [Float] = []   // the previous part's last `fadeOut` samples (its fade-out side)
    private var previousEqualPower = true
    private var held: [Float] = []           // the current part's tail, held for the next part
    private var emitted = 0           // output samples handed out
    private var canceled = false

    init(track: AVAssetTrack, available: CMTimeRange, plan: AudioJoinPlan) throws {
        self.track = track; self.available = available; self.plan = plan
        var asbd = AudioStreamBasicDescription(mSampleRate: Double(Self.sampleRate), mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                               mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                                    magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        guard status == noErr, let fmt else { throw Failure.read("audio format (\(status))") }
        format = fmt
    }

    /// Flag only (any thread): the next `next()` returns nil. The reader is cancelled by `close()` on the
    /// pump's queue, never from another thread while it may be inside `copyNextSampleBuffer()`.
    func cancel() { lock.withLock { canceled = true } }

    /// Stops the current reader. Call it on the queue that calls `next()`.
    func close() {
        cancel()
        reader?.cancelReading()
        reader = nil; output = nil
    }

    /// Renders the whole joined sound to `url`: raw 16-bit PCM, mono 48 kHz (what `PCMFileSource` reads).
    /// Returns the samples written; stops early (fewer samples) when cancelled. Blocking: run it off the
    /// cooperative pool.
    func render(to url: URL, progress: (Double) -> Void) throws -> Int {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        guard fm.createFile(atPath: url.path, contents: nil) else { throw Failure.read("cannot create \(url.lastPathComponent)") }
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close(); close() }
        var lastReport = -1.0
        while let buffer = try next() {
            var pcm = Data()
            try Waveform.forEachFloatChunk(in: buffer) { samples in
                pcm.reserveCapacity(samples.count * 2)
                for s in samples {
                    let v = Int16(max(-32768, min(32767, (s * 32767).rounded())))
                    withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
                }
            }
            try out.write(contentsOf: pcm)
            let p = plan.total > 0 ? Double(emitted) / Double(plan.total) : 1
            if p - lastReport >= 0.01 { lastReport = p; progress(min(1, p)) }
        }
        return emitted
    }

    /// "part 3/107, 1234/5678 samples, 9 s out" (stall reports).
    var progressDescription: String {
        "part \(index + 1)/\(plan.parts.count), \(position)/\(index >= 0 && index < plan.parts.count ? plan.parts[index].length : 0), \(emitted / Self.sampleRate) s out"
    }

    /// The next buffer of output sound, nil at the end.
    func next() throws -> CMSampleBuffer? {
        while true {
            if lock.withLock({ canceled }) { return nil }
            if index >= plan.parts.count { return nil }
            if index < 0 || position >= plan.parts[index].length {
                try openNext()
                if index >= plan.parts.count { return nil }   // the last part has no fade-out: nothing held
                continue
            }
            let part = plan.parts[index]
            let chunk = try readChunk(part)
            let out = place(chunk, in: part)
            if !out.isEmpty { return try makeBuffer(out) }
        }
    }

    // MARK: - Private

    private func openNext() throws {
        reader?.cancelReading()
        reader = nil; output = nil
        if index >= 0 {
            previousTail = held
            previousEqualPower = true   // see `continuesIntoNext`
        }
        held = []
        index += 1
        position = 0; raw = 0; skipped = 0
        guard index < plan.parts.count else { return }
        let part = plan.parts[index]
        let ts: CMTimeScale = 600_000
        let want = CMTimeRange(start: CMTime(seconds: part.sourceStart, preferredTimescale: ts),
                               end: CMTime(seconds: part.sourceEnd, preferredTimescale: ts))
        let have = want.intersection(available)
        leadingZeros = have.isEmpty ? part.preRoll + part.length
            : Int(((have.start - want.start).seconds / part.rate * Double(Self.sampleRate)).rounded())
        guard !have.isEmpty, have.duration.seconds > 1e-6 else { return }   // no sound here: silence
        let comp = AVMutableComposition()
        guard let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure.read("composition")
        }
        do { try t.insertTimeRange(have, of: track, at: .zero) } catch { throw Failure.read(error.localizedDescription) }
        if part.rate != 1 {
            comp.scaleTimeRange(CMTimeRange(start: .zero, duration: have.duration),
                                toDuration: CMTime(seconds: have.duration.seconds / part.rate, preferredTimescale: ts))
        }
        let r: AVAssetReader
        do { r = try AVAssetReader(asset: comp) } catch { throw Failure.read(error.localizedDescription) }
        let o = AVAssetReaderAudioMixOutput(audioTracks: [t], audioSettings: Waveform.monoFloat32Settings(sampleRate: Self.sampleRate))
        o.audioTimePitchAlgorithm = .spectral
        r.add(o)
        guard r.startReading() else { throw Failure.read(r.error?.localizedDescription ?? "startReading") }
        reader = r; output = o
    }

    /// The next samples of the current part: its raw stream (silence where the recording has no sound,
    /// the reader's sound, then silence to the end) without the pre-roll, cut to the part's exact length
    /// (a time-stretched piece comes out a few ms long).
    private func readChunk(_ part: AudioJoinPlan.Part) throws -> [Float] {
        while true {
            var chunk: [Float]
            if raw < leadingZeros {
                chunk = [Float](repeating: 0, count: min(4800, leadingZeros - raw))
            } else if let output, let sample = output.copyNextSampleBuffer() {
                chunk = []
                try Waveform.forEachFloatChunk(in: sample) { chunk.append(contentsOf: $0) }
            } else {
                if let reader, reader.status == .failed { throw Failure.read(reader.error?.localizedDescription ?? "audio read") }
                reader?.cancelReading(); reader = nil; output = nil
                chunk = [Float](repeating: 0, count: 4800)   // the sound ran out: silence to the part's end
            }
            raw += chunk.count
            if skipped < part.preRoll {
                let d = min(part.preRoll - skipped, chunk.count)
                chunk.removeFirst(d); skipped += d
            }
            if !chunk.isEmpty { return Array(chunk.prefix(part.length - position)) }
        }
    }

    /// Mixes the part's head with the previous part's held tail, holds back its own tail; returns what can
    /// go out now.
    private func place(_ chunk: [Float], in part: AudioJoinPlan.Part) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(chunk.count)
        let holdFrom = part.length - part.fadeOut
        for (offset, s) in chunk.enumerated() {
            let k = position + offset
            if k < part.fadeIn {
                let g = AudioJoinPlan.gains(k, of: part.fadeIn, equalPower: previousEqualPower)
                out.append((k < previousTail.count ? previousTail[k] : 0) * g.out + s * g.in)
            } else if k >= holdFrom {
                held.append(s)
            } else {
                out.append(s)
            }
        }
        position += chunk.count
        return out
    }

    private func makeBuffer(_ samples: [Float]) throws -> CMSampleBuffer {
        let bytes = samples.count * 4
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                        customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                                        flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == noErr, let block else { throw Failure.read("audio block (\(status))") }
        status = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        guard status == noErr else { throw Failure.read("audio copy (\(status))") }
        var buffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: samples.count,
            presentationTimeStamp: CMTime(value: CMTimeValue(emitted), timescale: CMTimeScale(Self.sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &buffer)
        guard status == noErr, let buffer else { throw Failure.read("audio buffer (\(status))") }
        emitted += samples.count
        return buffer
    }
}

/// The rendered sound read back as LPCM sample buffers (16-bit mono 48 kHz), 0.1 s at a time. Plain file
/// reads: no AVAssetReader runs next to the video's (two readers at once stalled under load, see Exporter).
final class PCMFileSource: @unchecked Sendable {
    private let handle: FileHandle
    private let format: CMAudioFormatDescription
    private var emitted = 0

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        var asbd = AudioStreamBasicDescription(mSampleRate: Double(AudioJoiner.sampleRate), mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
                                               mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                                    magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        guard status == noErr, let fmt else { throw AudioJoiner.Failure.read("audio format (\(status))") }
        format = fmt
    }

    deinit { try? handle.close() }

    func next() throws -> CMSampleBuffer? {
        guard let data = try handle.read(upToCount: AudioJoiner.sampleRate / 10 * 2), data.count >= 2 else { return nil }
        let count = data.count / 2
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count * 2, blockAllocator: nil,
                                                        customBlockSource: nil, offsetToData: 0, dataLength: count * 2,
                                                        flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == noErr, let block else { throw AudioJoiner.Failure.read("audio block (\(status))") }
        status = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: count * 2) }
        guard status == noErr else { throw AudioJoiner.Failure.read("audio copy (\(status))") }
        var buffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: count,
            presentationTimeStamp: CMTime(value: CMTimeValue(emitted), timescale: CMTimeScale(AudioJoiner.sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &buffer)
        guard status == noErr, let buffer else { throw AudioJoiner.Failure.read("audio buffer (\(status))") }
        emitted += count
        return buffer
    }
}
