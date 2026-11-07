// Owner: QA track. Opens a recording and says what is really in it, by decoding every frame
// (AVFoundation only). Used by the writer tests and `bubble-diag check`.
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

public struct MediaReport: Sendable, Codable, CustomStringConvertible {
    public var path: String
    public var bytes: Int64
    public var playable: Bool
    /// Container duration (what a player shows).
    public var duration: Double
    public var videoTracks: Int
    public var audioTracks: Int
    public var width: Int
    public var height: Int
    public var codec: String
    /// Frames that decoded, and the time of the last one + one frame (what really plays).
    public var decodedFrames: Int
    public var decodedSeconds: Double
    /// Largest gap between two consecutive video frames (seconds). CFR at 30 fps = 0.033.
    public var maxFrameGap: Double
    public var audioSeconds: Double
    public var audioSampleRate: Double
    public var audioChannels: Int
    /// Fragmented mp4 (has 'moof' boxes): what keeps a crashed file playable.
    public var fragmented: Bool
    public var errors: [String]

    public var description: String {
        var s = String(format: "%@: %@, %.3f s, %d×%d %@, %d frames decoded (%.3f s), max gap %.3f s, audio %.3f s %@",
                       (path as NSString).lastPathComponent, playable ? "playable" : "NOT playable", duration, width, height,
                       codec, decodedFrames, decodedSeconds, maxFrameGap, audioSeconds,
                       audioTracks > 0 ? String(format: "%.0f Hz %d ch", audioSampleRate, audioChannels) : "(none)")
        s += String(format: ", %.1f MB%@", Double(bytes) / 1e6, fragmented ? ", fragmented" : "")
        if !errors.isEmpty { s += "; errors: " + errors.joined(separator: "; ") }
        return s
    }
}

public enum MediaProbe {
    public static func inspect(_ url: URL) async -> MediaReport {
        var r = MediaReport(path: url.path, bytes: 0, playable: false, duration: 0, videoTracks: 0, audioTracks: 0,
                            width: 0, height: 0, codec: "", decodedFrames: 0, decodedSeconds: 0, maxFrameGap: 0,
                            audioSeconds: 0, audioSampleRate: 0, audioChannels: 0, fragmented: false, errors: [])
        r.bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        r.fragmented = hasBox("moof", in: url)
        let asset = AVURLAsset(url: url)
        do {
            r.playable = try await asset.load(.isPlayable)
            r.duration = try await asset.load(.duration).seconds
            let videos = try await asset.loadTracks(withMediaType: .video)
            let audios = try await asset.loadTracks(withMediaType: .audio)
            r.videoTracks = videos.count; r.audioTracks = audios.count
            if let v = videos.first {
                let size = try await v.load(.naturalSize)
                r.width = Int(size.width); r.height = Int(size.height)
                if let desc = try await v.load(.formatDescriptions).first {
                    r.codec = fourCC(CMFormatDescriptionGetMediaSubType(desc))
                }
                let (n, last, gap, err) = decodeVideo(asset: asset, track: v)
                r.decodedFrames = n; r.maxFrameGap = gap
                r.decodedSeconds = n > 0 ? last + 1.0 / 30 : 0
                if let err { r.errors.append(err) }
            }
            if let a = audios.first {
                if let desc = try await a.load(.formatDescriptions).first,
                   let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
                    r.audioSampleRate = asbd.mSampleRate; r.audioChannels = Int(asbd.mChannelsPerFrame)
                }
                let (secs, err) = decodeAudio(asset: asset, track: a)
                r.audioSeconds = secs
                if let err { r.errors.append(err) }
            }
        } catch {
            r.errors.append("load: \(error.localizedDescription)")
        }
        return r
    }

    /// Decodes every video frame. Returns (count, last PTS, largest gap, error).
    static func decodeVideo(asset: AVAsset, track: AVAssetTrack) -> (Int, Double, Double, String?) {
        guard let reader = try? AVAssetReader(asset: asset) else { return (0, 0, 0, "cannot open a reader") }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else { return (0, 0, 0, "startReading: \(reader.error?.localizedDescription ?? "?")") }
        var n = 0, last = -1.0, gap = 0.0
        while let sb = out.copyNextSampleBuffer() {
            guard CMSampleBufferGetImageBuffer(sb) != nil else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            if last >= 0 { gap = max(gap, t - last) }
            last = t; n += 1
        }
        let err = reader.status == .failed ? "video decode: \(reader.error?.localizedDescription ?? "?")" : nil
        return (n, max(0, last), gap, err)
    }

    static func decodeAudio(asset: AVAsset, track: AVAssetTrack) -> (Double, String?) {
        guard let reader = try? AVAssetReader(asset: asset) else { return (0, "cannot open a reader") }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
                                                                         AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                                                                         AVLinearPCMIsNonInterleaved: false])
        reader.add(out)
        guard reader.startReading() else { return (0, "audio startReading failed") }
        var end = 0.0
        while let sb = out.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            end = max(end, pts + CMSampleBufferGetDuration(sb).seconds)
        }
        let err = reader.status == .failed ? "audio decode: \(reader.error?.localizedDescription ?? "?")" : nil
        return (end, err)
    }

    /// Decoded BGRA frame nearest to `time`.
    public static func frame(of url: URL, at time: Double) async throws -> CVPixelBuffer? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(out)
        reader.startReading()
        var best: CVPixelBuffer?
        while let sb = out.copyNextSampleBuffer() {
            let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            if let ib = CMSampleBufferGetImageBuffer(sb) { best = ib }
            if t >= time - 0.001 { break }
        }
        reader.cancelReading()
        return best
    }

    /// Decoded mono Float32 samples of the first audio track at 48 kHz.
    public static func audioSamples(of url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
                                                                         AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
                                                                         AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        reader.add(out)
        reader.startReading()
        var samples: [Float] = []
        while let sb = out.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sb) {
            let len = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: len / 4)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            samples += chunk
        }
        return samples
    }

    /// PSNR (dB) of the luma-ish RGB between two BGRA buffers of the same size. ∞ when identical.
    public static func psnr(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double {
        let w = min(CVPixelBufferGetWidth(a), CVPixelBufferGetWidth(b)), h = min(CVPixelBufferGetHeight(a), CVPixelBufferGetHeight(b))
        CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let pa = CVPixelBufferGetBaseAddress(a)!.assumingMemoryBound(to: UInt8.self)
        let pb = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
        let ra = CVPixelBufferGetBytesPerRow(a), rb = CVPixelBufferGetBytesPerRow(b)
        var se = 0.0, n = 0.0
        for y in 0..<h {
            for x in 0..<w {
                for c in 0..<3 {
                    let d = Double(pa[y * ra + x * 4 + c]) - Double(pb[y * rb + x * 4 + c])
                    se += d * d
                }
                n += 3
            }
        }
        let mse = se / n
        return mse == 0 ? .infinity : 10 * log10(255 * 255 / mse)
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8(code >> 24 & 0xff), UInt8(code >> 16 & 0xff), UInt8(code >> 8 & 0xff), UInt8(code & 0xff)]
        return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
    }

    /// True if a top-level box of that type exists (walks the box headers, reads no media).
    public static func hasBox(_ type: String, in url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        var offset: UInt64 = 0
        let end = (try? fh.seekToEnd()) ?? 0
        while offset + 8 <= end {
            try? fh.seek(toOffset: offset)
            guard let head = try? fh.read(upToCount: 16), head.count >= 8 else { return false }
            var size = UInt64(head[0]) << 24 | UInt64(head[1]) << 16 | UInt64(head[2]) << 8 | UInt64(head[3])
            let name = String(bytes: head[4..<8], encoding: .ascii) ?? ""
            if name == type { return true }
            if size == 1, head.count >= 16 { size = head[8..<16].reduce(0) { $0 << 8 | UInt64($1) } }
            if size == 0 { return false }
            if size < 8 { return false }
            offset += size
        }
        return false
    }
}
