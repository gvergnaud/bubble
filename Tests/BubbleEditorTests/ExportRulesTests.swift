// Owner: E2 (media). Export of videos Bubble didn't record (docs/editor-open-video.md §4): the source's
// rate snapped (24/25/30/50/60, at most 60), at most 3840 px, rotation kept, HDR tone-mapped to SDR
// BT.709 and tagged, the first sound track. qa's fake videos (web/fixtures/open-video/) + one
// synthetic 4K+ file. No network, no Speech, no Keychain.
@testable import BubbleEditor
import AVFoundation
import CoreImage
import Foundation
import Testing

@Suite(.timeLimit(.minutes(2))) struct ExportRulesTests {
    static func fixture(_ name: String) -> URL { MediaCheckTests.file(name) }

    struct Out {
        var fps: Float
        var size: CGSize
        var transform: CGAffineTransform
        var frameTimes: [Double]
        var audioTracks: Int
        var color: [String: String]
        var url: URL
    }

    /// Exports the whole file (one piece) and reads back what matters here.
    func export(_ source: URL, in dir: URL) async throws -> Out {
        let duration = try await AVURLAsset(url: source).load(.duration).seconds
        let out = dir.appendingPathComponent(source.deletingPathExtension().lastPathComponent + "-out.mp4")
        try await Exporter.render(source: source, pieces: [MediaPiece(start: 0, end: duration, rate: 1)], to: out)
        let asset = AVURLAsset(url: out, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let v = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let (fps, size, transform, formats) = try await v.load(.nominalFrameRate, .naturalSize, .preferredTransform, .formatDescriptions)
        var color: [String: String] = [:]
        if let f = formats.first {
            for (name, key) in [("primaries", kCMFormatDescriptionExtension_ColorPrimaries),
                                ("transfer", kCMFormatDescriptionExtension_TransferFunction),
                                ("matrix", kCMFormatDescriptionExtension_YCbCrMatrix)] {
                color[name] = CMFormatDescriptionGetExtension(f, extensionKey: key) as? String
            }
        }
        return Out(fps: fps, size: size, transform: transform, frameTimes: try await Probe.read(out).frameTimes,
                   audioTracks: try await asset.loadTracks(withMediaType: .audio).count, color: color, url: out)
    }

    @Test(arguments: [("p60.mp4", 60), ("p25.mp4", 25), ("h264.mp4", 30)])
    func keepsTheSourceRate(name: String, rate: Int) async throws {
        let dir = try MediaFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = try await export(Self.fixture(name), in: dir)
        #expect(abs(Double(out.fps) - Double(rate)) < 0.5, "\(out.fps) fps")
        #expect(abs(out.frameTimes.count - 2 * rate) <= 1, "\(out.frameTimes.count) frames")
        let step = 1 / Double(rate)
        let bad = zip(out.frameTimes, out.frameTimes.dropFirst()).filter { abs(($1 - $0) - step) > 0.001 }
        #expect(bad.isEmpty, "\(bad.count) gaps ≠ 1/\(rate) s")
    }

    @Test func keepsRotationAndTheFirstSoundTrack() async throws {
        let dir = try MediaFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rotated = try await export(Self.fixture("rotated.mp4"), in: dir)
        let shown = CGRect(origin: .zero, size: rotated.size).applying(rotated.transform).size
        #expect(abs(shown.width) == 180 && abs(shown.height) == 320, "\(shown)")
        #expect(try await export(Self.fixture("two-audio.mp4"), in: dir).audioTracks == 1)
        #expect(try await export(Self.fixture("no-sound.mp4"), in: dir).audioTracks == 0)
        // A sound it can't read: the video exports without it, and the transcript says no sound at once.
        #expect(try await export(Self.fixture("vorbis-audio.mp4"), in: dir).audioTracks == 0)
        let jobs = TranscriptionJobs(engines: [FixtureTranscriber(wordsFile: MediaFixtures.demoProject)])
        let state = try await jobs.start(projectID: "v", source: Self.fixture("vorbis-audio.mp4"), folder: dir)
        #expect(state.status == .failed && state.errorCode == TranscriptionState.noSound)
    }

    @Test func taggedRec709AndHDRIsToneMapped() async throws {
        let dir = try MediaFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec709 = ["primaries": kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String,
                      "transfer": kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String,
                      "matrix": kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String]
        let hdr = try await export(Self.fixture("hdr-hlg.mov"), in: dir)
        let sdr = try await export(Self.fixture("h264.mov"), in: dir)
        #expect(hdr.color == rec709, "\(hdr.color)")
        #expect(sdr.color == rec709, "\(sdr.color)")
        // The pixels themselves are converted, not only the tags: BT.2020 HLG → 709 makes this pattern
        // darker (mean Y 121.2 → 117.1 decoded as is) and its colours stronger (chroma 131.9 → 134.0).
        // An SDR source passes through unchanged. With no conversion (the export before this rule) the
        // HDR export kept 121.2 / 131.9 and its BT.2020 HLG tags in an 8-bit H.264: all four checks fail.
        let hdrIn = try await Self.planes(Self.fixture("hdr-hlg.mov")), hdrOut = try await Self.planes(hdr.url)
        #expect(hdrOut.y < hdrIn.y - 2, "Y \(hdrIn.y) → \(hdrOut.y)")
        #expect(hdrOut.chroma > hdrIn.chroma + 1, "chroma \(hdrIn.chroma) → \(hdrOut.chroma)")
        let sdrIn = try await Self.planes(Self.fixture("h264.mov")), sdrOut = try await Self.planes(sdr.url)
        #expect(abs(sdrOut.y - sdrIn.y) < 1 && abs(sdrOut.chroma - sdrIn.chroma) < 1,
                "SDR Y \(sdrIn.y) → \(sdrOut.y), chroma \(sdrIn.chroma) → \(sdrOut.chroma)")
    }

    @Test func scalesDownAbove3840() async throws {
        let dir = try MediaFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = dir.appendingPathComponent("big.mp4")
        try await Self.writeGrey(big, width: 4096, height: 2160, frames: 15)
        let out = try await export(big, in: dir)
        #expect(out.size == CGSize(width: 3840, height: 2026), "\(out.size)")
    }

    // MARK: Helpers

    /// Mean Y and mean chroma strength (|Cb − 128| + |Cr − 128|) of the 16th frame, decoded as stored
    /// (8-bit 4:2:0, no colour conversion).
    static func planes(_ url: URL) async throws -> (y: Double, chroma: Double) {
        let asset = AVURLAsset(url: url)
        nonisolated(unsafe) let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        nonisolated(unsafe) let readAsset = asset
        return try await BlockingRead.run { _ in
            let reader = try AVAssetReader(asset: readAsset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
            reader.add(output)
            reader.startReading()
            defer { reader.cancelReading() }
            var sample: CMSampleBuffer?
            for _ in 0..<16 { if let next = output.copyNextSampleBuffer() { sample = next } }
            guard let sample, let img = CMSampleBufferGetImageBuffer(sample) else { return (0, 0) }
            CVPixelBufferLockBaseAddress(img, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(img, .readOnly) }
            let w = CVPixelBufferGetWidthOfPlane(img, 0), h = CVPixelBufferGetHeightOfPlane(img, 0)
            let yp = CVPixelBufferGetBaseAddressOfPlane(img, 0)!.assumingMemoryBound(to: UInt8.self)
            let cp = CVPixelBufferGetBaseAddressOfPlane(img, 1)!.assumingMemoryBound(to: UInt8.self)
            let yr = CVPixelBufferGetBytesPerRowOfPlane(img, 0), cr = CVPixelBufferGetBytesPerRowOfPlane(img, 1)
            var sy = 0.0, sc = 0.0
            for j in 0..<h { for i in 0..<w { sy += Double(yp[j * yr + i]) } }
            for j in 0..<(h / 2) { for i in 0..<(w / 2) {
                sc += abs(Double(cp[j * cr + 2 * i]) - 128) + abs(Double(cp[j * cr + 2 * i + 1]) - 128)
            } }
            return (sy / Double(w * h), sc / Double(w * h / 4))
        }
    }

    /// `frames` grey frames at 30 fps, H.264, `width`×`height`.
    static func writeGrey(_ url: URL, width: Int, height: Int, frames: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for f in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let b = try #require(buffer)
            CVPixelBufferLockBaseAddress(b, [])
            memset(CVPixelBufferGetBaseAddress(b), 128, CVPixelBufferGetDataSize(b))
            CVPixelBufferUnlockBaseAddress(b, [])
            #expect(adaptor.append(b, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed, "\(String(describing: writer.error))")
    }
}
