// Owner: QA track. RecordingWriter + FramePump on synthetic frames and sine audio (docs/architecture.md §6, §8.1).
// Faster than real time (realTime: false). Files go to $TMPDIR and are deleted unless BUBBLE_KEEP_FILES=1.
import AVFoundation
import BubbleCore
import BubbleTesting
import CoreMedia
import Foundation
import Testing

// MARK: - Harness

/// Collects errors thrown inside FramePump's @Sendable sink.
final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    private(set) var appended = 0
    func add(_ e: Error) { lock.lock(); items.append("\(e)"); lock.unlock() }
    func count() { lock.lock(); appended += 1; lock.unlock() }
    var errors: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

func tempMovie(_ name: String) -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bubble-tests", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8)).mp4")
    try? FileManager.default.removeItem(at: url)
    return url
}
func cleanUp(_ url: URL) {
    if ProcessInfo.processInfo.environment["BUBBLE_KEEP_FILES"] == nil { try? FileManager.default.removeItem(at: url) }
}
func ft(_ tick: Int, fps: Int = 30) -> CMTime { CMTime(value: CMTimeValue(tick), timescale: CMTimeScale(fps)) }

/// A synthetic take: `seconds` of 30 fps ticks. The screen changes every tick except inside `staticSpans`
/// (no submit: what SCK does on a still screen). Audio: 1600 samples of sine per tick when `audio`.
struct SyntheticTake {
    var seconds: Double
    var width = 1280, height = 800
    var audio = true
    var staticSpans: [ClosedRange<Double>] = []
    /// Host-time pauses: (pause at, resume at), in seconds of the synthetic host clock.
    var pauses: [(Double, Double)] = []

    /// Returns the writer's file time at stop.
    @discardableResult
    func write(to url: URL, errors: ErrorBox) async throws -> CMTime {
        let video = VideoSettings.forDisplay(pointSize: CGSize(width: width, height: height), scale: 1)
        let writer = try RecordingWriter(url: url, video: video, audio: audio ? AudioSettings() : nil, realTime: false)
        let pump = FramePump(fps: 30) { pb, time in
            do { try writer.appendVideo(pb, at: time); errors.count() } catch { errors.add(error) }
        }
        var timeline = Timeline()
        let hostOrigin = 1000.0
        func host(_ s: Double) -> CMTime { CMTime(seconds: hostOrigin + s, preferredTimescale: 48_000) }
        timeline.start(at: host(0))
        // Frames are drawn at the take's size, cached by index so the run stays quick.
        var cache: [Int: CVPixelBuffer] = [:]
        func frame(_ i: Int) -> CVPixelBuffer {
            let k = i % 60
            if let f = cache[k] { return f }
            let f = SyntheticFrames.frame(width: video.width, height: video.height, index: k)
            cache[k] = f; return f
        }
        let hostSeconds = seconds + pauses.reduce(0) { $0 + ($1.1 - $1.0) }
        let ticks = Int((hostSeconds * 30).rounded())
        var audioSample: Int64 = 0
        var lastFileTime = CMTime.zero
        for i in 0..<ticks {
            let h = Double(i) / 30
            for p in pauses {
                if abs(h - p.0) < 1e-9 { timeline.pause(at: host(h)) }
                if abs(h - p.1) < 1e-9 { timeline.resume(at: host(h)) }
            }
            if !staticSpans.contains(where: { $0.contains(h) }) { pump.submit(frame(i)) }
            guard let fileTime = timeline.fileTime(forHost: host(h)) else { continue }
            pump.tick(at: fileTime)
            if audio {
                let pcm = SyntheticAudio.pcm(frames: 1600, startSample: audioSample)
                do { try writer.appendAudio(pcm, at: CMTime(value: audioSample, timescale: 48_000)) } catch { errors.add(error) }
                audioSample += 1600
            }
            lastFileTime = fileTime
        }
        let stop = CMTimeAdd(lastFileTime, ft(1))
        try await writer.finish(at: stop)
        return stop
    }
}

// MARK: - FramePump

@Suite
struct FramePumpTests {
    final class Sink: @unchecked Sendable {
        var calls: [(CVPixelBuffer, CMTime)] = []
    }
    @Test func noFrameBeforeTheFirstSubmit() {
        let sink = Sink()
        let pump = FramePump(fps: 30) { sink.calls.append(($0, $1)) }
        pump.tick(at: ft(0)); pump.tick(at: ft(1))
        #expect(sink.calls.isEmpty)
    }
    @Test func everyTickAppendsTheLatestFrame() {
        let sink = Sink()
        let pump = FramePump(fps: 30) { sink.calls.append(($0, $1)) }
        let a = SyntheticFrames.frame(width: 64, height: 64, index: 1)
        let b = SyntheticFrames.frame(width: 64, height: 64, index: 2)
        pump.submit(a)
        pump.tick(at: ft(0)); pump.tick(at: ft(1)); pump.tick(at: ft(2))   // static screen: a, a, a
        pump.submit(a); pump.submit(b)                                     // two frames between ticks: the last wins
        pump.tick(at: ft(3))
        #expect(sink.calls.count == 4)
        #expect(sink.calls[0].0 === a && sink.calls[2].0 === a && sink.calls[3].0 === b)
        #expect(sink.calls.map(\.1) == [ft(0), ft(1), ft(2), ft(3)])
    }
}

// MARK: - Writer

@Suite(.serialized, .timeLimit(.minutes(1)))
struct WriterTests {
    @Test func tenSecondFile() async throws {
        let url = tempMovie("ten-seconds"); defer { cleanUp(url) }
        let errors = ErrorBox()
        try await SyntheticTake(seconds: 10).write(to: url, errors: errors)
        #expect(errors.errors.isEmpty)
        let r = await MediaProbe.inspect(url)
        #expect(r.playable, "\(r)")
        #expect(abs(r.duration - 10) <= 0.1, "\(r)")
        #expect(r.videoTracks == 1 && r.audioTracks == 1, "\(r)")
        #expect(r.codec == "avc1", "\(r)")
        #expect(r.width == 1280 && r.height == 800, "\(r)")
        #expect(abs(r.decodedFrames - 300) <= 1, "\(r)")
        #expect(r.maxFrameGap < 0.04, "constant frame rate: \(r)")
        #expect(abs(r.audioSeconds - 10) <= 0.1, "\(r)")
        #expect(r.audioSampleRate == 48_000 && r.audioChannels == 1, "\(r)")
        // A finished file is a regular movie (AVAssetWriter folds the fragments in at finish); the
        // fragments are checked on a crashed file in CrashTests.
        #expect(r.errors.isEmpty, "\(r)")
    }

    /// §6 regression: a 2.5 s still screen while audio goes on used to fail the writer (-16341).
    @Test func staticScreenWithAudio() async throws {
        let url = tempMovie("static-screen"); defer { cleanUp(url) }
        let errors = ErrorBox()
        try await SyntheticTake(seconds: 10, staticSpans: [3.0...5.5]).write(to: url, errors: errors)
        #expect(errors.errors.isEmpty, "\(errors.errors)")
        let r = await MediaProbe.inspect(url)
        #expect(abs(r.duration - 10) <= 0.1, "\(r)")
        #expect(abs(r.decodedFrames - 300) <= 1, "\(r)")
        #expect(r.maxFrameGap < 0.04, "\(r)")
        #expect(r.errors.isEmpty, "\(r)")
    }

    /// Several static spans across fragment boundaries, video + audio, 20 s.
    @Test func manyStaticSpans() async throws {
        let url = tempMovie("static-many"); defer { cleanUp(url) }
        let errors = ErrorBox()
        try await SyntheticTake(seconds: 20, staticSpans: [1.9...2.3, 4.0...8.5, 9.9...10.1, 12.0...19.9]).write(to: url, errors: errors)
        #expect(errors.errors.isEmpty, "\(errors.errors)")
        let r = await MediaProbe.inspect(url)
        #expect(abs(r.duration - 20) <= 0.1, "\(r)")
        #expect(abs(r.decodedFrames - 600) <= 1, "\(r)")
    }

    /// Pause 3 s at host 4 s, then 2 s at host 9 s: a 10 s file with no gap.
    @Test func pauseCutsTheFile() async throws {
        let url = tempMovie("pause"); defer { cleanUp(url) }
        let errors = ErrorBox()
        try await SyntheticTake(seconds: 10, pauses: [(4, 7), (9, 11)]).write(to: url, errors: errors)
        #expect(errors.errors.isEmpty, "\(errors.errors)")
        let r = await MediaProbe.inspect(url)
        #expect(abs(r.duration - 10) <= 0.1, "\(r)")
        #expect(abs(r.decodedFrames - 300) <= 1, "\(r)")
        #expect(r.maxFrameGap < 0.04, "no hole where the pause was: \(r)")
        #expect(abs(r.audioSeconds - 10) <= 0.1, "\(r)")
    }

    /// The screen goes still at 5 s and Stop comes at 8 s: the file lasts 8 s (spike: 6.25 s without the fix).
    @Test func finishAtStopTimeAfterAStaticEnd() async throws {
        let url = tempMovie("static-end"); defer { cleanUp(url) }
        let video = VideoSettings.forDisplay(pointSize: CGSize(width: 640, height: 400), scale: 1)
        let writer = try RecordingWriter(url: url, video: video, audio: nil, realTime: false)
        for i in 0..<150 { try writer.appendVideo(SyntheticFrames.frame(width: video.width, height: video.height, index: i), at: ft(i)) }
        try await writer.finish(at: CMTime(seconds: 8, preferredTimescale: 600))
        let r = await MediaProbe.inspect(url)
        #expect(abs(r.duration - 8) <= 0.1, "\(r)")
        #expect(r.playable, "\(r)")
    }

    @Test func videoOnlyFile() async throws {
        let url = tempMovie("video-only"); defer { cleanUp(url) }
        let errors = ErrorBox()
        try await SyntheticTake(seconds: 5, audio: false).write(to: url, errors: errors)
        let r = await MediaProbe.inspect(url)
        #expect(errors.errors.isEmpty)
        #expect(r.videoTracks == 1 && r.audioTracks == 0, "\(r)")
        #expect(abs(r.duration - 5) <= 0.1, "\(r)")
    }

    @Test func nonIncreasingVideoTimeIsRefused() async throws {
        let url = tempMovie("non-increasing"); defer { cleanUp(url) }
        let video = VideoSettings.forDisplay(pointSize: CGSize(width: 320, height: 200), scale: 1)
        let writer = try RecordingWriter(url: url, video: video, audio: nil, realTime: false)
        let f = SyntheticFrames.frame(width: video.width, height: video.height, index: 0)
        try writer.appendVideo(f, at: ft(0))
        try writer.appendVideo(f, at: ft(1))
        #expect(throws: (any Error).self) { try writer.appendVideo(f, at: ft(1)) }
        try await writer.finish(at: ft(2))
    }

    @Test func bytesWrittenGrows() async throws {
        let url = tempMovie("bytes"); defer { cleanUp(url) }
        let errors = ErrorBox()
        try await SyntheticTake(seconds: 3).write(to: url, errors: errors)
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        #expect(size > 10_000)
    }

    /// Text must stay sharp: a decoded frame vs its source, PSNR ≥ 35 dB, at the real MacBook Pro size.
    @Test func textIsSharp() async throws {
        let url = tempMovie("sharpness"); defer { cleanUp(url) }
        let video = VideoSettings.forDisplay(pointSize: CGSize(width: 1512, height: 982), scale: 2)
        let writer = try RecordingWriter(url: url, video: video, audio: nil, realTime: false)
        let source = SyntheticFrames.frame(width: video.width, height: video.height, index: 7)
        for i in 0..<90 { try writer.appendVideo(source, at: ft(i)) }   // a still screen, 3 s
        try await writer.finish(at: ft(90))
        let decoded = try #require(try await MediaProbe.frame(of: url, at: 2.5))
        #expect(CVPixelBufferGetWidth(decoded) == 3024 && CVPixelBufferGetHeight(decoded) == 1964)
        let psnr = MediaProbe.psnr(source, decoded)
        #expect(psnr >= 35, "PSNR \(psnr) dB")
    }
}
