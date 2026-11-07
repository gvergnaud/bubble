// Owner: E2 (transcription). docs/editor-architecture.md §5: the recording's audio as a 16 kHz mono
// 16-bit WAV (what every speech engine takes), same timeline as the source (t = 0 is the source's 0).
// ~1.9 MB per minute. Streamed: memory stays flat.
import AVFoundation
import Foundation

public enum AudioExtract {
    public static let sampleRate = 16_000

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case sourceMissing
        case noAudio
        case readFailed(String)

        public var description: String {
            switch self {
            case .sourceMissing: "The recording is missing: it was moved or deleted."
            case .noAudio: "The recording has no sound to transcribe."
            case .readFailed(let m): "Could not read the recording's sound: \(m)"
            }
        }
    }

    public struct Output: Sendable, Equatable {
        public var url: URL
        public var duration: Double
        public var bytes: Int64
    }

    /// Writes `destination` (replaced). Every audio track mixed to mono; a source whose audio starts
    /// late gets leading silence so word times stay source times.
    @discardableResult
    public static func wav(from source: URL, to destination: URL) async throws -> Output {
        guard FileManager.default.fileExists(atPath: source.path) else { throw Failure.sourceMissing }
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw Failure.noAudio }
        var firstStart = Double.infinity
        for t in tracks { firstStart = min(firstStart, try await t.load(.timeRange).start.seconds) }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false])
        reader.add(output)
        guard reader.startReading() else { throw Failure.readFailed(reader.error?.localizedDescription ?? "startReading") }
        defer { if reader.status == .reading { reader.cancelReading() } }

        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: destination)
        guard fm.createFile(atPath: destination.path, contents: wavHeader(dataBytes: 0)) else {
            throw Failure.readFailed("cannot create \(destination.lastPathComponent)")
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.seekToEnd()

        var dataBytes = 0
        var written = false
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            if !written {
                // Lead-in silence when the first sample is after 0 (keeps source time).
                let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                let lead = max(0, (pts.isFinite ? pts : firstStart.isFinite ? firstStart : 0))
                let n = Int((lead * Double(sampleRate)).rounded()) * 2
                if n > 0 { try handle.write(contentsOf: Data(count: n)); dataBytes += n }
                written = true
            }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = Data(count: length)
            let status = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            guard status == noErr else { throw Failure.readFailed("audio buffer (\(status))") }
            try handle.write(contentsOf: chunk)
            dataBytes += length
        }
        if reader.status == .failed { throw Failure.readFailed(reader.error?.localizedDescription ?? "read") }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: wavHeader(dataBytes: dataBytes))
        return Output(url: destination, duration: Double(dataBytes / 2) / Double(sampleRate), bytes: Int64(dataBytes + 44))
    }

    /// RIFF/WAVE header, PCM 16-bit mono at `sampleRate`.
    static func wavHeader(dataBytes: Int) -> Data {
        var d = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(truncatingIfNeeded: v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(truncatingIfNeeded: v).littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return d
    }
}
