// Owner: E2 (media). docs/editor-architecture.md §4, docs/editor-api.md §4.
// The recording's audio as peaks: one byte per 1/50 s, the peak of |sample| (0..255) with a gentle
// gain of 1.4, mono. Same formula as web/fixtures/make-demo.py, so the fixture and the server agree.
import AVFoundation
import Foundation

public enum Waveform {
    public static let peaksPerSecond = 50
    public static let sampleRate = 48_000
    public static let gain: Float = 1.4

    public enum Failure: Error, Equatable {
        case unreadable(String)
    }

    /// Peaks of every audio track mixed to mono (empty `Data` when the file has no audio). Streamed:
    /// memory stays flat whatever the length. Throws on cancellation.
    public static func peaks(of url: URL) async throws -> Data {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return Data() }
        let duration = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: monoFloat32Settings(sampleRate: sampleRate))
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw Failure.unreadable(reader.error?.localizedDescription ?? "cannot read audio") }
        defer { if reader.status == .reading { reader.cancelReading() } }

        var accumulator = PeakAccumulator(samplesPerPeak: sampleRate / peaksPerSecond, gain: gain)
        accumulator.reserve(Int(duration * Double(peaksPerSecond)) + 1)
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            try forEachFloatChunk(in: buffer) { accumulator.add($0) }
        }
        if reader.status == .failed { throw Failure.unreadable(reader.error?.localizedDescription ?? "audio read failed") }
        return accumulator.finish()
    }

    /// Interleaved Float32 LPCM, mono (AVFoundation downmixes and resamples).
    static func monoFloat32Settings(sampleRate: Int) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
         AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
         AVLinearPCMIsBigEndianKey: false]
    }

    /// Calls `body` with the Float32 samples of an LPCM sample buffer (no copy when contiguous).
    static func forEachFloatChunk(in buffer: CMSampleBuffer, _ body: (UnsafeBufferPointer<Float>) -> Void) throws {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return }
        let length = CMBlockBufferGetDataLength(block)
        if CMBlockBufferIsRangeContiguous(block, atOffset: 0, length: length) {
            var pointer: UnsafeMutablePointer<CChar>?
            let status = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &pointer)
            guard status == noErr, let pointer else { throw Failure.unreadable("audio buffer (\(status))") }
            pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { body(UnsafeBufferPointer(start: $0, count: length / 4)) }
        } else {
            var copy = [Float](repeating: 0, count: length / 4)
            let status = copy.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            guard status == noErr else { throw Failure.unreadable("audio buffer (\(status))") }
            copy.withUnsafeBufferPointer(body)
        }
    }
}

/// Pure: samples in, one byte per `samplesPerPeak` out. A partial last window still gives a peak.
struct PeakAccumulator {
    let samplesPerPeak: Int
    let gain: Float
    private(set) var bytes: [UInt8] = []
    private var current: Float = 0
    private var count = 0

    init(samplesPerPeak: Int, gain: Float) {
        self.samplesPerPeak = samplesPerPeak
        self.gain = gain
    }

    mutating func reserve(_ n: Int) { bytes.reserveCapacity(n) }

    mutating func add(_ samples: UnsafeBufferPointer<Float>) {
        for s in samples {
            let a = abs(s)
            if a > current { current = a }
            count += 1
            if count == samplesPerPeak { flush() }
        }
    }

    mutating func add(_ samples: [Float]) { samples.withUnsafeBufferPointer { add($0) } }

    mutating func finish() -> Data {
        if count > 0 { flush() }
        return Data(bytes)
    }

    static func byte(peak: Float, gain: Float) -> UInt8 {
        let v = peak * 255 * gain
        guard v.isFinite, v > 0 else { return 0 }
        return UInt8(min(255, v))   // truncation, like the fixture's int()
    }

    private mutating func flush() {
        bytes.append(Self.byte(peak: current, gain: gain))
        current = 0
        count = 0
    }
}
