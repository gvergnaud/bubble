// Owner: QA track. The pure pieces of the capture engine (docs/architecture.md §8.1).
import BubbleCore
import CoreMedia
import Foundation
import Testing

private func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600_000) }
private func secs(_ time: CMTime?) -> Double? { time.map { $0.seconds } }

@Suite struct VideoSettingsTests {
    @Test func macBookProNativePixels() {
        let v = VideoSettings.forDisplay(pointSize: CGSize(width: 1512, height: 982), scale: 2)
        #expect(v.width == 3024 && v.height == 1964)
        #expect(v.fps == 30)
    }
    @Test func fiveKIsCappedAt3840() {
        let v = VideoSettings.forDisplay(pointSize: CGSize(width: 2560, height: 1440), scale: 2)
        #expect(v.width == 3840 && v.height == 2160)
    }
    @Test func portraitDisplayCapsTheLongSide() {
        let v = VideoSettings.forDisplay(pointSize: CGSize(width: 1440, height: 2560), scale: 2)
        #expect(v.width == 2160 && v.height == 3840)
    }
    @Test func fullHDAt1x() {
        let v = VideoSettings.forDisplay(pointSize: CGSize(width: 1920, height: 1080), scale: 1)
        #expect(v.width == 1920 && v.height == 1080)
    }
    @Test(arguments: [(1001.0, 701.0), (1365.0, 767.0), (3.0, 3.0), (1511.5, 981.5)])
    func oddSizesAreMadeEven(size: (Double, Double)) {
        let v = VideoSettings.forDisplay(pointSize: CGSize(width: size.0, height: size.1), scale: 1)
        #expect(v.width % 2 == 0 && v.height % 2 == 0)
        #expect(abs(Double(v.width) - size.0) <= 2 && abs(Double(v.height) - size.1) <= 2)
    }
    @Test func aspectIsKeptWhenCapped() {
        let v = VideoSettings.forDisplay(pointSize: CGSize(width: 3440, height: 1440), scale: 2)
        #expect(v.width == 3840)
        #expect(abs(Double(v.width) / Double(v.height) - 3440.0 / 1440.0) < 0.01)
    }
    @Test func bitRateIsClamped() {
        let mbp = VideoSettings.forDisplay(pointSize: CGSize(width: 1512, height: 982), scale: 2)
        #expect((6_500_000...7_500_000).contains(mbp.averageBitRate))       // ≈ 7 Mb/s
        let small = VideoSettings.forDisplay(pointSize: CGSize(width: 800, height: 600), scale: 1)
        #expect(small.averageBitRate == 4_000_000)
        let fourK = VideoSettings.forDisplay(pointSize: CGSize(width: 2560, height: 1440), scale: 2)
        #expect(fourK.averageBitRate == 9_953_280)                          // 3840×2160×30×0.04, under the cap
        #expect(VideoSettings.bitRate(width: 3840, height: 2160, fps: 60) == 16_000_000)
    }
    @Test func keyFramesAndFragmentsEvery2s() {
        let v = VideoSettings.forDisplay(pointSize: CGSize(width: 1512, height: 982), scale: 2)
        #expect(v.keyFrameIntervalSeconds == 2 && v.fragmentIntervalSeconds == 2)
    }
    @Test func audioDefaults() {
        let a = AudioSettings()
        #expect(a.sampleRate == 48_000 && a.channels == 1 && a.bitRate == 128_000)
    }
}

@Suite struct TimelineTests {
    @Test func nilBeforeStart() {
        let tl = Timeline()
        #expect(tl.fileTime(forHost: t(10)) == nil)
        #expect(tl.elapsed(atHost: t(10)) == 0)
    }
    @Test func fileTimeIsHostMinusStart() {
        var tl = Timeline(); tl.start(at: t(100))
        #expect(secs(tl.fileTime(forHost: t(100))) == 0)
        #expect(abs(secs(tl.fileTime(forHost: t(103.5)))! - 3.5) < 1e-6)
        #expect(tl.fileTime(forHost: t(99)) == nil)   // captured before the start
    }
    @Test func pauseCutsTheSpan() {
        var tl = Timeline(); tl.start(at: t(0))
        tl.pause(at: t(5))
        #expect(tl.fileTime(forHost: t(6)) == nil)
        #expect(abs(tl.elapsed(atHost: t(8)) - 5) < 1e-6)   // frozen while paused
        tl.resume(at: t(9))
        #expect(abs(secs(tl.fileTime(forHost: t(9)))! - 5) < 1e-6)
        #expect(abs(secs(tl.fileTime(forHost: t(12)))! - 8) < 1e-6)
        #expect(abs(tl.elapsed(atHost: t(12)) - 8) < 1e-6)
    }
    @Test func multiplePauses() {
        var tl = Timeline(); tl.start(at: t(0))
        tl.pause(at: t(2)); tl.resume(at: t(4))      // −2
        tl.pause(at: t(6)); tl.resume(at: t(10))     // −4
        tl.pause(at: t(11)); tl.resume(at: t(11.5))  // −0.5
        #expect(abs(secs(tl.fileTime(forHost: t(20)))! - 13.5) < 1e-6)
        #expect(abs(tl.elapsed(atHost: t(20)) - 13.5) < 1e-6)
        // A sample captured inside a past pause, arriving late, is still dropped.
        #expect(tl.fileTime(forHost: t(7)) == nil)
        // One captured before a pause, arriving late, is kept at its time.
        #expect(abs(secs(tl.fileTime(forHost: t(5)))! - 3) < 1e-6)
    }
    @Test func fileTimeIsMonotonicAcrossPauses() {
        var tl = Timeline(); tl.start(at: t(0))
        tl.pause(at: t(1)); tl.resume(at: t(3))
        var last = -1.0
        for i in 0..<200 {
            if let f = tl.fileTime(forHost: t(Double(i) * 0.025)) {
                #expect(f.seconds > last); last = f.seconds
            }
        }
    }
    @Test func doublePauseAndStrayResumeAreIgnored() {
        var tl = Timeline(); tl.start(at: t(0))
        tl.resume(at: t(1))                       // not paused: ignored
        tl.pause(at: t(2)); tl.pause(at: t(3))    // second pause ignored
        tl.resume(at: t(4))
        #expect(abs(tl.elapsed(atHost: t(5)) - 3) < 1e-6)
    }
    @Test func pauseAtHostClockScale() {
        // Real host times are large (uptime in ns). Make sure nothing overflows or loses precision.
        let base = CMTime(value: 812_345_678_901_234, timescale: 1_000_000_000)
        var tl = Timeline(); tl.start(at: base)
        tl.pause(at: base + t(60)); tl.resume(at: base + t(3600))
        let f = tl.fileTime(forHost: base + t(3601))!
        #expect(abs(f.seconds - 61) < 1e-6)
    }
}

@Suite struct RecordingFilesTests {
    let date: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 6; c.hour = 14; c.minute = 22; c.second = 5
        return Calendar(identifier: .gregorian).date(from: c)!
    }()
    let folder = URL(fileURLWithPath: "/tmp/bubble-tests", isDirectory: true)

    @Test func nameFormat() {
        let url = RecordingFiles.newURL(in: folder, date: date) { _ in false }
        #expect(url.lastPathComponent == "Bubble 2026-11-06 at 14.22.05.mp4")
        #expect(url.deletingLastPathComponent().path == folder.path)
    }
    @Test func sameSecondGetsANumber() {
        var taken: Set<String> = ["Bubble 2026-11-06 at 14.22.05.mp4"]
        let second = RecordingFiles.newURL(in: folder, date: date) { taken.contains($0.lastPathComponent) }
        #expect(second.lastPathComponent == "Bubble 2026-11-06 at 14.22.05 (2).mp4")
        taken.insert(second.lastPathComponent)
        let third = RecordingFiles.newURL(in: folder, date: date) { taken.contains($0.lastPathComponent) }
        #expect(third.lastPathComponent == "Bubble 2026-11-06 at 14.22.05 (3).mp4")
    }
    @Test func defaultFolderIsMoviesBubble() {
        #expect(RecordingFiles.defaultFolder.path.hasSuffix("/Movies/Bubble"))
    }
    @Test func folderIsCreated() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bubble-\(UUID().uuidString)/a/b", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent().deletingLastPathComponent()) }
        let url = try RecordingFiles.newURL(in: tmp, date: date)
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: tmp.path, isDirectory: &isDir) && isDir.boolValue)
        #expect(url.lastPathComponent == "Bubble 2026-11-06 at 14.22.05.mp4")
    }
}

@Suite struct DiskPolicyTests {
    let gb: Int64 = 1_000_000_000
    @Test func beforeStart() {
        #expect(DiskPolicy.decide(bytesFree: 600_000_000, recording: false) == .refuseStart)
        #expect(DiskPolicy.decide(bytesFree: gb - 1, recording: false) == .refuseStart)
        #expect(DiskPolicy.decide(bytesFree: gb, recording: false) == .ok)
        #expect(DiskPolicy.decide(bytesFree: 1_500_000_000, recording: false) == .ok)
    }
    @Test func whileRecording() {
        #expect(DiskPolicy.decide(bytesFree: 50 * gb, recording: true) == .ok)
        #expect(DiskPolicy.decide(bytesFree: 2 * gb, recording: true) == .ok)
        #expect(DiskPolicy.decide(bytesFree: 2 * gb - 1, recording: true) == .warn)
        #expect(DiskPolicy.decide(bytesFree: 600_000_000, recording: true) == .warn)   // < 1 GB never refuses mid-take
        #expect(DiskPolicy.decide(bytesFree: 300_000_000, recording: true) == .warn)
        #expect(DiskPolicy.decide(bytesFree: 299_999_999, recording: true) == .stopAndSave)
        #expect(DiskPolicy.decide(bytesFree: 0, recording: true) == .stopAndSave)
    }
    @Test func minutesLeft() {
        // 1.8 GB free at 1 MB/s: (1.8 GB − 300 MB) / 1 MB/s = 1500 s = 25 min.
        #expect(DiskPolicy.minutesLeft(bytesFree: 1_800_000_000, bytesPerSecond: 1_000_000) == 25)
        #expect(DiskPolicy.minutesLeft(bytesFree: 100_000_000, bytesPerSecond: 1_000_000) == 0)
    }
    @Test func bytesFreeForAMissingFolder() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)/x.mp4")
        #expect((DiskPolicy.bytesFree(at: missing) ?? 0) > 0)
    }
}
