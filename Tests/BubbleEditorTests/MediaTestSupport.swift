// Owner: E2 (media). Test helpers: a synthetic A/V file whose flashes and beeps happen at known times
// (white frames + 1 kHz beeps), and probes that find them again in an export.
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

enum MediaFixtures {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let demo = repo.appendingPathComponent("web/fixtures/demo.mp4")
    static let demoProject = repo.appendingPathComponent("web/fixtures/demo.project.json")
    static let demoWaveform = repo.appendingPathComponent("web/fixtures/demo.waveform.json")

    static func tempDir(_ name: String = #function) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bubble-editor-media-\(name.filter { $0.isLetter || $0.isNumber })-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    struct DemoEdits: Decodable {
        struct Seg: Decodable { var start: Double; var end: Double; var rate: Double }
        struct Edits: Decodable { var segments: [Seg] }
        struct Video: Decodable { var duration: Double }
        var edits: Edits
        var video: Video
    }

    /// Kept pieces from segments (same rule as EditPlan.pieces): gaps at 1×, rate-0 segments dropped.
    static func pieces(duration: Double, segments: [(Double, Double, Double)]) -> [MediaPiece_] {
        var out: [MediaPiece_] = []
        var t = 0.0
        for (s, e, r) in segments {
            if s > t { out.append(.init(start: t, end: s, rate: 1)) }
            if r > 0 { out.append(.init(start: s, end: e, rate: r)) }
            t = e
        }
        if t < duration { out.append(.init(start: t, end: duration, rate: 1)) }
        return out
    }

    /// Output time of source time `t`, nil when `t` is cut.
    static func outputTime(of t: Double, in pieces: [MediaPiece_]) -> Double? {
        var acc = 0.0
        for p in pieces {
            if t >= p.start && t < p.end { return acc + (t - p.start) / p.rate }
            acc += (p.end - p.start) / p.rate
        }
        return nil
    }
}

/// Plain mirror of `MediaPiece` so the helpers don't depend on the type under test.
struct MediaPiece_: Equatable { var start: Double; var end: Double; var rate: Double }

enum SyntheticAV {
    static let width = 320, height = 240, fps = 30, sampleRate = 48_000
    static let beepLength = 0.1, beepHz = 1000.0

    /// `seconds` of black video with white frames during each beep, and 1 kHz beeps at `beeps` (source times).
    /// `variableFrameRate`: like the recorder on a static screen, a frame only when the picture changes
    /// (plus one every 10 frames).
    static func make(_ url: URL, seconds: Double, beeps: [Double], variableFrameRate: Bool = false, audio withAudio: Bool = true,
                     audioSeconds: Double? = nil, signal: (@Sendable (Double) -> Float)? = nil) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height])
        let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000])
        writer.add(vIn)
        if withAudio { writer.add(aIn) }
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        let white = buffer(255), black = buffer(0)
        let isBeep: @Sendable (Double) -> Bool = { t in beeps.contains { t >= $0 - 1e-9 && t < $0 + beepLength - 1e-9 } }

        let chunk = sampleRate / 10   // 0.1 s
        let totalFrames = Int((seconds * Double(fps)).rounded())
        let totalSamples = withAudio ? Int((audioSeconds ?? seconds) * Double(sampleRate)) : 0
        var frame = 0, sample = 0
        var lastWhite: Bool?
        var videoFinished = false
        // Whichever input is behind (and ready) gets its next piece: the writer interleaves offline and
        // holds back the input that runs ahead, so never wait on one while the other is behind.
        while frame < totalFrames || sample < totalSamples {
            let videoTime = frame < totalFrames ? Double(frame) / Double(fps) : .infinity
            let audioTime = sample < totalSamples ? Double(sample) / Double(sampleRate) : .infinity
            var progressed = false
            if videoTime <= audioTime {
                let w = isBeep(videoTime)
                let wanted = !variableFrameRate || w != lastWhite || frame % 10 == 0 || frame == totalFrames - 1
                if !wanted {
                    lastWhite = w; frame += 1; progressed = true
                } else if vIn.isReadyForMoreMediaData {
                    guard adaptor.append(w ? white : black, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))) else { throw writer.error! }
                    lastWhite = w; frame += 1; progressed = true
                }
            }
            if !progressed, sample < totalSamples, aIn.isReadyForMoreMediaData {
                let n = min(chunk, totalSamples - sample)
                guard aIn.append(audio(start: sample, count: n, value: signal ?? { isBeep($0) ? Float(0.5 * sin(2 * .pi * beepHz * $0)) : 0 })) else { throw writer.error! }
                sample += n; progressed = true
                // An input that has all its data must say so at once: the writer holds the other one
                // back while it waits to interleave.
                if sample >= totalSamples { aIn.markAsFinished() }
            }
            if !progressed, frame < totalFrames, vIn.isReadyForMoreMediaData, videoTime > audioTime {
                let w = isBeep(videoTime)
                guard adaptor.append(w ? white : black, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))) else { throw writer.error! }
                lastWhite = w; frame += 1; progressed = true
            }
            // Same for video: when audio runs longer, an open video input would hold the audio back forever.
            if frame >= totalFrames && !videoFinished { vIn.markAsFinished(); videoFinished = true }
            if !progressed { try await Task.sleep(for: .milliseconds(1)) }
        }
        if !videoFinished { vIn.markAsFinished() }
        writer.endSession(atSourceTime: CMTime(seconds: max(seconds, audioSeconds ?? 0), preferredTimescale: 600))
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? NSError(domain: "synthetic", code: 1) }
    }

    private static func buffer(_ v: UInt8) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        memset(CVPixelBufferGetBaseAddress(pb!), Int32(v), CVPixelBufferGetBytesPerRow(pb!) * height)
        CVPixelBufferUnlockBaseAddress(pb!, [])
        return pb!
    }

    private static func audio(start: Int, count: Int, value: (Double) -> Float) -> CMSampleBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        pcm.frameLength = AVAudioFrameCount(count)
        let p = pcm.floatChannelData![0]
        for i in 0..<count {
            let t = Double(start + i) / Double(sampleRate)
            p[i] = value(t)
        }
        var asbd = format.streamDescription.pointee
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                                        presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(sampleRate)),
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                             formatDescription: fmt, sampleCount: CMItemCount(count), sampleTimingEntryCount: 1,
                             sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb)
        CMSampleBufferSetDataBufferFromAudioBufferList(sb!, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                       flags: 0, bufferList: pcm.audioBufferList)
        return sb!
    }
}

/// What an export really holds: frame times, flashes, beeps.
struct Probe {
    var duration: Double
    var videoDuration: Double
    var audioDuration: Double
    var frameTimes: [Double]
    /// Times of black→white frame changes.
    var flashes: [Double]
    /// Audio Float32 mono 48 kHz.
    var samples: [Float]

    static func read(_ url: URL) async throws -> Probe {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let v = try await asset.loadTracks(withMediaType: .video).first!
        let a = try await asset.loadTracks(withMediaType: .audio).first
        let reader = try AVAssetReader(asset: asset)
        let vOut = AVAssetReaderTrackOutput(track: v, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(vOut)
        var aOut: AVAssetReaderTrackOutput?
        if let a {
            let o = AVAssetReaderTrackOutput(track: a, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
            reader.add(o); aOut = o
        }
        reader.startReading()
        var times: [Double] = [], flashes: [Double] = [], samples: [Float] = []
        var wasWhite = false
        // Read audio fully first would stall the video side for a long file; alternate instead.
        var vDone = false, aDone = aOut == nil
        while !vDone || !aDone {
            if !vDone {
                if let sb = vOut.copyNextSampleBuffer() {
                    if let img = CMSampleBufferGetImageBuffer(sb) {
                        let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                        times.append(t)
                        CVPixelBufferLockBaseAddress(img, .readOnly)
                        let base = CVPixelBufferGetBaseAddress(img)!.assumingMemoryBound(to: UInt8.self)
                        let row = CVPixelBufferGetBytesPerRow(img)
                        let px = base[(CVPixelBufferGetHeight(img) / 2) * row + (CVPixelBufferGetWidth(img) / 2) * 4 + 1]
                        CVPixelBufferUnlockBaseAddress(img, .readOnly)
                        let white = px > 128
                        if white && !wasWhite { flashes.append(t) }
                        wasWhite = white
                    }
                } else { vDone = true }
            }
            if !aDone, let aOut {
                if let sb = aOut.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sb) {
                    let n = CMBlockBufferGetDataLength(block) / 4
                    var chunk = [Float](repeating: 0, count: n)
                    chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
                    samples += chunk
                } else { aDone = true }
            }
        }
        times.sort()
        return Probe(duration: try await asset.load(.duration).seconds,
                     videoDuration: try await v.load(.timeRange).duration.seconds,
                     audioDuration: try await a?.load(.timeRange).duration.seconds ?? 0,
                     frameTimes: times, flashes: flashes, samples: samples)
    }

    /// Times where the sound starts after ≥ 0.15 s of quiet (1 ms windows over 0.05).
    var beeps: [Double] {
        var out: [Double] = []
        let w = 48
        var quiet = 0
        var i = 0
        while i + w <= samples.count {
            var peak: Float = 0
            for j in i..<(i + w) { peak = max(peak, abs(samples[j])) }
            if peak > 0.1 {
                if quiet >= 150 {
                    // refine to the first loud sample in the window
                    let k = (i..<(i + w)).first { abs(samples[$0]) > 0.05 } ?? i
                    out.append(Double(k) / 48_000)
                }
                quiet = 0
            } else { quiet += 1 }
            i += w
        }
        return out
    }

    /// Dominant frequency from zero crossings in [t, t + length).
    func frequency(at t: Double, length: Double) -> Double {
        let a = Int(t * 48_000), b = min(samples.count, Int((t + length) * 48_000))
        guard b > a + 2 else { return 0 }
        var crossings = 0
        for i in (a + 1)..<b where (samples[i - 1] < 0) != (samples[i] < 0) { crossings += 1 }
        return Double(crossings) / 2 / (Double(b - a) / 48_000)
    }
}
