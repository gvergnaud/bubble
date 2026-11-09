// Owner: E2 (media). MediaCheck on qa's fake videos (web/fixtures/open-video/, 2 s 320×180):
// docs/editor-open-video.md §4. No network, no Speech, no Keychain.
@testable import BubbleEditor
import CoreMedia
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1))) struct MediaCheckTests {
    static let dir = MediaFixtures.repo.appendingPathComponent("web/fixtures/open-video")
    static func file(_ name: String) -> URL { dir.appendingPathComponent(name) }

    @Test(arguments: [("h264.mp4", "H.264"), ("h264.mov", "H.264"), ("h264.m4v", "H.264"), ("hevc.mp4", "HEVC"),
                      ("prores.mov", "ProRes 422 Proxy")])
    func readsTheFormatsBubbleEdits(name: String, codec: String) async throws {
        let info = try await MediaCheck.inspect(Self.file(name))
        #expect(info.codec == codec)
        #expect(info.width == 320 && info.height == 180)
        #expect(abs(info.fps - 30) < 0.5, "\(info.fps)")
        #expect(abs(info.duration - 2) < 0.1)
        #expect(info.hasAudio && !info.hdr)
    }

    @Test func frameRatesSizesAndTheRest() async throws {
        #expect(abs(try await MediaCheck.inspect(Self.file("p60.mp4")).fps - 60) < 0.5)
        #expect(abs(try await MediaCheck.inspect(Self.file("p25.mp4")).fps - 25) < 0.5)
        let rotated = try await MediaCheck.inspect(Self.file("rotated.mp4"))
        #expect(rotated.width == 180 && rotated.height == 320)   // shown upright
        #expect(try await MediaCheck.inspect(Self.file("hdr-hlg.mov")).hdr)
        #expect(!(try await MediaCheck.inspect(Self.file("no-sound.mp4")).hasAudio))
        #expect(try await MediaCheck.inspect(Self.file("two-audio.mp4")).hasAudio)
        // A sound AVFoundation can't read (Vorbis in MP4): opens, counts as no sound.
        #expect(!(try await MediaCheck.inspect(Self.file("vorbis-audio.mp4")).hasAudio))
    }

    @Test(arguments: [
        ("h264.mkv", MediaCheck.Refusal.unsupportedContainer(ext: "mkv"), "Bubble can't open .mkv files. It edits MP4, MOV and M4V videos. Convert it to MP4 first."),
        ("clip.webm", .unsupportedContainer(ext: "webm"), "Bubble can't open .webm files. It edits MP4, MOV and M4V videos. Convert it to MP4 first."),
        ("not-a-video.mp4", .unsupportedContainer(ext: "mp4"), "Bubble can't open .mp4 files. It edits MP4, MOV and M4V videos. Convert it to MP4 first."),
        ("vp9.mp4", .undecodable(codec: "VP9"), "Bubble can't read this video's format (VP9). Convert it to H.264 or HEVC MP4 first."),
        ("audio-only.mp4", .noVideo, "This file has no video."),
        ("audio-only.m4a", .noVideo, "This file has no video."),
        ("gone.mp4", .missing, "The video is missing: it was moved or deleted."),
    ])
    func refusesWithASentence(name: String, refusal: MediaCheck.Refusal, sentence: String) async {
        await #expect(throws: refusal) { try await MediaCheck.inspect(Self.file(name)) }
        #expect(refusal.description == sentence)
    }

    @Test func refusalCodesAreTheAPIs() {
        #expect(MediaCheck.Refusal.unsupportedContainer(ext: "mkv").code == "unsupported_format")
        #expect(MediaCheck.Refusal.undecodable(codec: "VP9").code == "unsupported_format")
        #expect(MediaCheck.Refusal.noVideo.code == "no_video")
    }

    @Test func frameRateIsTheMedianShortIntervalOfAVariableRateFile() {
        // A screen recording at 30 fps that holds still: frames 1/30 s apart when it moves, long pauses
        // (its average is ~8 fps), a few jittery frames 1/60 s apart.
        var times: [Double] = []
        var t = 0.0
        for k in 0..<120 {
            times.append(t)
            t += k % 10 == 9 ? 0.6 : (k % 17 == 0 ? 1.0 / 60 : 1.0 / 30)
        }
        #expect(abs(MediaCheck.frameRate(times: times, nominal: 8) - 30) < 0.01)
        #expect(MediaCheck.frameRate(times: [0, 0.5, 1], nominal: 29.97) == 29.97)   // too few: nominal
        #expect(MediaCheck.frameRate(times: [], nominal: 0) == 0)
    }

    @Test func outputRateIsSnappedAndCapped() {
        #expect([23.976, 24, 25, 29.97, 30, 48, 50, 59.94, 60, 120, 240].map(Exporter.outputFrameRate) == [24, 24, 25, 30, 30, 50, 50, 60, 60, 60, 60])
        #expect(Exporter.outputFrameRate(0) == 30 && Exporter.outputFrameRate(.nan) == 30)
        #expect(Exporter.outputFrameRate(10) == 30 && Exporter.outputFrameRate(15) == 30)   // mostly still: Bubble's 30
    }

    @Test func bigVideosAreScaledToFitIn3840() {
        #expect(Exporter.outputSize(width: 4096, height: 2160) == (3840, 2026))
        #expect(Exporter.outputSize(width: 2160, height: 7680) == (1080, 3840))
        #expect(Exporter.outputSize(width: 1919, height: 1081) == (1918, 1080))   // even, never scaled up
        #expect(Exporter.outputSize(width: 3840, height: 2160) == (3840, 2160))
    }
}
