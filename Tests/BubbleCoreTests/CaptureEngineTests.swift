// Owner: capture track. The capture engineer's own checks of the writer, the pump and the mixer,
// on synthetic media only (no screen, camera or mic). QA's suites (WriterTests, AudioMixerTests...)
// are the gate; these are the quick loops next to the code.
import AVFoundation
import BubbleCore
import BubbleTesting
import CoreMedia
import Foundation
import Testing

private func tempURL(_ name: String) -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bubble-capture-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(name)
}

private func frameTime(_ i: Int, fps: Int = 30) -> CMTime { CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)) }

private struct FileFacts { var duration: Double; var videoFrames: Int; var audioSeconds: Double; var tracks: Int }

private func facts(_ url: URL) async throws -> FileFacts {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration).seconds
    let tracks = try await asset.load(.tracks)
    var frames = 0, audio = 0.0
    if let video = try await asset.loadTracks(withMediaType: .video).first {
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        reader.add(out); reader.startReading()
        // Off the cooperative pool (BubbleTesting.offPool): a sync read loop there starved the parallel gate.
        frames = await offPool {
            var n = 0
            while let sb = out.copyNextSampleBuffer() { n += CMSampleBufferGetNumSamples(sb) }
            return n
        }
    }
    if let a = try await asset.loadTracks(withMediaType: .audio).first {
        audio = try await a.load(.timeRange).duration.seconds
    }
    return FileFacts(duration: duration, videoFrames: frames, audioSeconds: audio, tracks: tracks.count)
}

/// Writes `seconds` of synthetic video + sine through FramePump, with the screen frozen in `staticSpan`.
private func writeSynthetic(_ url: URL, seconds: Double, staticSpan: Range<Double>? = nil, width: Int = 640, height: Int = 400) async throws -> RecordingWriter {
    let video = VideoSettings(width: width, height: height, averageBitRate: 4_000_000)
    let writer = try RecordingWriter(url: url, video: video, audio: AudioSettings(), realTime: false)
    let box = CaptureErrorBox()
    let pump = FramePump(fps: 30) { pb, t in
        do { try writer.appendVideo(pb, at: t) } catch { box.error = error }
    }
    let ticks = Int(seconds * 30)
    var audioSample: Int64 = 0
    for i in 0..<ticks {
        let t = Double(i) / 30
        if staticSpan?.contains(t) != true { pump.submit(SyntheticFrames.frame(width: width, height: height, index: i)) }
        pump.tick(at: frameTime(i))
        while Double(audioSample + 1024) / 48_000 <= Double(i + 1) / 30 {
            try writer.appendAudio(SyntheticAudio.pcm(frames: 1024, startSample: audioSample), at: CMTime(value: audioSample, timescale: 48_000))
            audioSample += 1024
        }
        if let e = box.error { throw e }
    }
    try await writer.finish(at: CMTime(seconds: seconds, preferredTimescale: 600))
    return writer
}

private final class CaptureErrorBox: @unchecked Sendable { var error: Error? }

@Suite struct CaptureWriterTests {
    @Test func staticScreenWithAudioThroughThePump() async throws {
        let url = tempURL("static.mp4")
        _ = try await writeSynthetic(url, seconds: 10, staticSpan: 3.0..<5.5)
        let f = try await facts(url)
        #expect(abs(f.duration - 10) < 0.1)
        #expect(f.videoFrames == 300)
        #expect(f.tracks == 2)
        #expect(abs(f.audioSeconds - 10) < 0.1)
    }

    @Test func staticEndStillLastsUntilStop() async throws {
        let url = tempURL("static-end.mp4")
        let writer = try RecordingWriter(url: url, video: VideoSettings(width: 320, height: 200, averageBitRate: 4_000_000), audio: nil, realTime: false)
        for i in 0..<60 { try writer.appendVideo(SyntheticFrames.frame(width: 320, height: 200, index: i), at: frameTime(i)) }
        try await writer.finish(at: CMTime(seconds: 5, preferredTimescale: 600))
        let f = try await facts(url)
        #expect(abs(f.duration - 5) < 0.1)
    }

    @Test func nonIncreasingVideoTimeThrows() throws {
        let url = tempURL("order.mp4")
        let writer = try RecordingWriter(url: url, video: VideoSettings(width: 320, height: 200, averageBitRate: 4_000_000), audio: nil, realTime: false)
        let pb = SyntheticFrames.frame(width: 320, height: 200, index: 0)
        try writer.appendVideo(pb, at: frameTime(1))
        #expect(throws: WriterError.nonIncreasingTime) { try writer.appendVideo(pb, at: frameTime(1)) }
    }

    @Test func refusesAnExistingFile() throws {
        let url = tempURL("exists.mp4")
        FileManager.default.createFile(atPath: url.path, contents: Data([1]))
        #expect(throws: (any Error).self) {
            _ = try RecordingWriter(url: url, video: VideoSettings(width: 320, height: 200, averageBitRate: 4_000_000), audio: nil)
        }
    }
}

@Suite struct CaptureMixerTests {
    private func host(_ s: Double) -> CMTime { CMTime(seconds: 1000 + s, preferredTimescale: 48_000) }

    private func samples(_ chunks: [(AVAudioPCMBuffer, CMTime)]) -> [Float] {
        chunks.flatMap { Array(UnsafeBufferPointer(start: $0.0.floatChannelData![0], count: Int($0.0.frameLength))) }
    }

    @Test func contiguousChunksFromOneSource() {
        let mixer = AudioMixer(sources: [.microphone], maxWait: 0.2)
        let origin = host(0)
        for k in 0..<50 { mixer.push(SyntheticAudio.sineSampleBuffer(frames: 960, startSample: Int64(k * 960), origin: origin), from: .microphone) }
        let out = mixer.pull(upToHost: host(1.2))
        #expect(!out.isEmpty)
        for (a, b) in zip(out, out.dropFirst()) {
            #expect(b.1 == a.1 + CMTime(value: CMTimeValue(a.0.frameLength), timescale: 48_000))
        }
        #expect(out.allSatisfy { $0.0.frameLength == 1024 })
        // 1.0 s of input, output up to 1.0 s (1.2 - maxWait): ~46 chunks.
        #expect(out.count == 46)
    }

    @Test func sumIsClampedAndHolesAreSilent() {
        let mixer = AudioMixer(sources: [.microphone, .computer], maxWait: 0.2)
        let origin = host(0)
        mixer.push(SyntheticAudio.constantSampleBuffer(0.8, frames: 4800, startSample: 0, origin: origin), from: .microphone)
        mixer.push(SyntheticAudio.constantSampleBuffer(0.7, frames: 2400, startSample: 0, origin: origin), from: .computer)
        // mic hole from 0.1 s to 0.2 s, then mic again
        mixer.push(SyntheticAudio.constantSampleBuffer(0.25, frames: 4800, startSample: 9600, origin: origin), from: .microphone)
        let out = samples(mixer.flush(upToHost: host(0.3)))
        #expect(out.count == 14400)
        #expect(out[100] == 1)          // 0.8 + 0.7 clamped
        #expect(out[3000] == 0.8)       // computer ended
        #expect(out[6000] == 0)         // hole
        #expect(out[10000] == 0.25)
    }

    @Test func resamples44100() {
        let mixer = AudioMixer(sources: [.microphone], maxWait: 0.2)
        for k in 0..<44 { mixer.push(SyntheticAudio.sineSampleBuffer(frames: 1000, startSample: Int64(k * 1000), sampleRate: 44_100, origin: host(0)), from: .microphone) }
        let out = samples(mixer.flush(upToHost: host(1.0)))
        #expect(out.count == 48_000)
        let energy = out[1000..<46_000].map { $0 * $0 }.reduce(0, +) / Float(45_000)
        #expect(energy > 0.02) // sine 0.25 → mean square 0.031
    }

    @Test func deadSourceDoesNotStall() {
        let mixer = AudioMixer(sources: [.microphone, .computer], maxWait: 0.2)
        for k in 0..<10 { mixer.push(SyntheticAudio.sineSampleBuffer(frames: 4800, startSample: Int64(k * 4800), origin: host(0)), from: .microphone) }
        let out = mixer.pull(upToHost: host(1.2))
        #expect(out.count == 46)
    }
}

@Suite struct CapturePumpTests {
    @Test func repeatsTheLatestFrameAndSkipsJitter() {
        final class Sink: @unchecked Sendable { var times: [Double] = [] }
        let sink = Sink()
        let pump = FramePump(fps: 30) { _, t in sink.times.append(t.seconds) }
        pump.tick(at: frameTime(0)) // nothing before the first frame
        pump.submit(SyntheticFrames.makeBuffer(width: 16, height: 16))
        pump.tick(at: frameTime(1))
        pump.tick(at: frameTime(1) + CMTime(value: 1, timescale: 1000)) // jitter: skipped
        pump.tick(at: frameTime(2))
        pump.tick(at: frameTime(3))
        #expect(sink.times.count == 3)
        #expect(pump.skippedTicks == 1)
    }
}


@Suite struct CaptureSessionTests {
    /// 12 s of host time, paused from 3.517 s to 5.517 s (not on a chunk or frame boundary):
    /// 10 s of video, audio as long as video, no writer error.
    @Test func pauseOffTheChunkGridKeepsAudioAndVideoTogether() async throws {
        let url = tempURL("session-pause.mp4")
        let video = VideoSettings(width: 640, height: 400, averageBitRate: 4_000_000)
        let writer = try RecordingWriter(url: url, video: video, audio: AudioSettings(), realTime: false)
        let session = RecordingSession(writer: writer, audioSources: [.microphone], audioMaxWait: 0.05)
        let failure = CaptureErrorBox()
        session.onFailure = { failure.error = WriterError.appendFailed($0) }
        let origin = CMTime(seconds: 5000, preferredTimescale: 48_000)
        func host(_ s: Double) -> CMTime { origin + CMTime(seconds: s, preferredTimescale: 48_000) }
        var micSample: Int64 = 0
        for i in 0..<(12 * 30) {
            let s = Double(i) / 30
            // the mic delivers 480-sample buffers, a little behind
            while Double(micSample + 480) / 48_000 <= s {
                session.audio(SyntheticAudio.sineSampleBuffer(frames: 480, startSample: micSample, origin: origin), from: .microphone)
                micSample += 480
            }
            if i % 2 == 0 { session.screenFrame(SyntheticFrames.frame(width: 640, height: 400, index: i % 30), at: host(s)) }
            if abs(s - 3.5) < 1e-6 { session.pause(at: host(3.517)) }
            if abs(s - 5.5) < 1e-6 { session.resume(at: host(5.517)) }
            session.tick(at: host(s))
        }
        let end = session.prepareFinish(at: host(12))
        try await writer.finish(at: end)
        #expect(failure.error == nil)
        #expect(abs(end.seconds - 10) < 0.001)
        let f = try await facts(url)
        #expect(abs(f.duration - 10) < 0.05)
        #expect(abs(f.audioSeconds - 10) < 0.03)
        #expect(abs(f.videoFrames - 300) <= 1)
        #expect(writer.audioFramesTrimmed == 0)
    }
}


@Suite struct CaptureGeometryTests {
    // Main display 1512x982 pt at the origin; a second display 1920x1080 to its right, top-aligned.
    let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let right = CGRect(x: 1512, y: 0, width: 1920, height: 1080)

    @Test func appKitAndCGAreTheSameFlipBothWays() {
        let ak = CGRect(x: 100, y: 50, width: 400, height: 300) // 50 pt above the bottom
        let cg = CaptureGeometry.cgGlobal(fromAppKit: ak, mainDisplayHeight: 982)
        #expect(cg == CGRect(x: 100, y: 632, width: 400, height: 300))
        #expect(CaptureGeometry.appKitGlobal(fromCG: cg, mainDisplayHeight: 982) == ak)
    }

    @Test func cropIsDisplayLocalAndClamped() {
        // a window on the second display, partly off its bottom edge
        let w = CGRect(x: 1612, y: 900, width: 600, height: 400)
        #expect(CaptureGeometry.crop(w, onDisplay: right) == CGRect(x: 100, y: 900, width: 600, height: 180))
        #expect(CaptureGeometry.crop(w, onDisplay: main) == nil) // not on the main display
    }

    @Test func tinyOrFractionalCrops() {
        #expect(CaptureGeometry.crop(CGRect(x: 10, y: 10, width: 40, height: 400), onDisplay: main) == nil)
        #expect(CaptureGeometry.crop(CGRect(x: 10.4, y: 10.6, width: 300.2, height: 200), onDisplay: main)
                == CGRect(x: 10, y: 10, width: 301, height: 201))
    }

    @Test func outputSizeIsNativeEvenAndCapped() {
        let v = CaptureGeometry.videoSettings(cropSize: CGSize(width: 801, height: 601), scale: 2)
        #expect(v.width == 1602 && v.height == 1202)
        let big = CaptureGeometry.videoSettings(cropSize: CGSize(width: 2560, height: 1440), scale: 2)
        #expect(big.width == 3840 && big.height == 2160)
        #expect(v.width % 2 == 0 && v.height % 2 == 0)
    }

    @Test func followingAWindow() {
        let start = CGRect(x: 100, y: 100, width: 800, height: 600)
        let crop0 = CaptureGeometry.crop(start, onDisplay: main)!
        typealias S = CaptureGeometry.WindowSample
        // same place
        #expect(CaptureGeometry.follow(lastCrop: crop0, wasHidden: false, sample: S(bounds: start, isOnScreen: true), displayBounds: main) == .unchanged)
        // moved
        let moved = start.offsetBy(dx: 50, dy: 20)
        #expect(CaptureGeometry.follow(lastCrop: crop0, wasHidden: false, sample: S(bounds: moved, isOnScreen: true), displayBounds: main)
                == .moved(crop: CGRect(x: 150, y: 120, width: 800, height: 600)))
        // minimized
        #expect(CaptureGeometry.follow(lastCrop: crop0, wasHidden: false, sample: S(bounds: start, isOnScreen: false), displayBounds: main) == .hidden(.notOnScreen))
        // still hidden: no repeat
        #expect(CaptureGeometry.follow(lastCrop: crop0, wasHidden: true, sample: S(bounds: start, isOnScreen: false), displayBounds: main) == .unchanged)
        // mostly dragged onto the other display
        let across = CGRect(x: 1300, y: 100, width: 800, height: 600)
        let right = CGRect(x: main.maxX, y: 0, width: 1920, height: 1080)
        #expect(CaptureGeometry.follow(lastCrop: crop0, wasHidden: false, sample: S(bounds: across, isOnScreen: true), displayBounds: main,
                                       otherDisplays: [right]) == .hidden(.otherDisplay))
        // the minimize animation: shrinking into the Dock, mostly below every display: wait
        let genie = CGRect(x: main.midX, y: main.maxY - 30, width: 60, height: 120)
        #expect(CaptureGeometry.follow(lastCrop: crop0, wasHidden: false, sample: S(bounds: genie, isOnScreen: true), displayBounds: main,
                                       otherDisplays: [right]) == .unchanged)
        // its app hidden (⌘H)
        #expect(CaptureGeometry.follow(lastCrop: crop0, wasHidden: false, sample: S(bounds: start, isOnScreen: false, appHidden: true), displayBounds: main) == .hidden(.appHidden))
        // back
        #expect(CaptureGeometry.follow(lastCrop: crop0, wasHidden: true, sample: S(bounds: start, isOnScreen: true), displayBounds: main)
                == .visibleAgain(crop: crop0))
        // closed
        #expect(CaptureGeometry.follow(lastCrop: crop0, wasHidden: false, sample: nil, displayBounds: main) == .gone)
    }
}

@Suite struct CaptureStreamUpdateTests {
    /// Records what a slow apply was asked to do.
    actor Calls {
        var seen: [Int] = []
        func add(_ value: Int) { seen.append(value) }
    }

    @Test func aBurstEndsOnTheLastValueWithoutOverlap() async {
        let calls = Calls()
        let path = LatestOnly(initial: 0) { _, wanted in
            await calls.add(wanted)
            try await Task.sleep(for: .milliseconds(300))
        }
        // Changes say "at least n" (like crops ordered by sequence), so the order in which
        // concurrent callers reach the actor does not matter; only the coalescing does.
        let first = Task { await path.update { $0 = max($0, 1) } }
        while await calls.seen.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }   // 1 in flight
        async let second = path.update { $0 = max($0, 2) }
        async let third = path.update { $0 = max($0, 3) }
        let results = await [first.value, second, third]
        #expect(results.allSatisfy { $0 == nil })
        #expect(await calls.seen == [1, 3])
        #expect(await path.inEffect == 3)
    }

    @Test func aFailureIsReturnedAndRetriedByTheNextUpdate() async {
        struct Boom: Error {}
        let calls = Calls()
        let path = LatestOnly(initial: 0) { _, wanted in
            await calls.add(wanted)
            if wanted == 1 { throw Boom() }
        }
        #expect(await path.update { $0 = 1 } is Boom)
        #expect(await path.inEffect == 0)
        #expect(await path.update { $0 = 2 } == nil)
        #expect(await path.inEffect == 2)
        #expect(await calls.seen == [1, 2])
    }
}
