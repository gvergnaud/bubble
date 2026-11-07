// Owner: QA track. A crash mid-take leaves a playable file (design.md principle 5, architecture.md §8.1).
// Spawns bubble-diag (built by `swift build`, which scripts/check.sh runs first): it writes in real
// time and abort()s, then the file is decoded. BUBBLE_DIAG=<path> overrides the binary.
import BubbleTesting
import Foundation
import Testing

enum Diag {
    static var binary: URL {
        if let p = ProcessInfo.processInfo.environment["BUBBLE_DIAG"] { return URL(fileURLWithPath: p) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return root.appendingPathComponent(".build/debug/bubble-diag")
    }

    /// Runs bubble-diag, returns (exit status, terminated by a signal, output).
    static func run(_ args: [String]) throws -> (status: Int32, signaled: Bool, output: String) {
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, p.terminationReason == .uncaughtSignal, String(decoding: data, as: UTF8.self))
    }
}

@Suite(.serialized)
struct CrashTests {
    /// Killed at 9 s of a 20 s take: at most one fragment (2 s) lost, so ≥ 7.9 s must decode.
    @Test(.timeLimit(.minutes(1)))
    func abortMidTakeLeavesAPlayableFile() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: Diag.binary.path), "build bubble-diag first: swift build")
        let url = tempMovie("crash")
        defer { cleanUp(url) }
        let r = try Diag.run(["synthetic", url.path, "--seconds", "20", "--crash-after", "9", "--static-gaps"])
        #expect(r.signaled, "bubble-diag should have aborted: \(r.output)")
        #expect(r.output.contains("crashing on purpose"), "\(r.output)")
        let report = await MediaProbe.inspect(url)
        #expect(report.playable, "\(report)")
        #expect(report.fragmented, "a crashed file is made of movie fragments: \(report)")
        #expect(report.decodedSeconds >= 7.9, "\(report)")
        #expect(report.decodedSeconds <= 9.2, "\(report)")
        #expect(report.audioTracks == 1 && report.audioSeconds >= 7.5, "\(report)")
        #expect(report.errors.isEmpty, "\(report)")
    }

    /// Same, faster than real time, killed right after a pause: the cut is still in the file.
    @Test(.timeLimit(.minutes(1)))
    func abortAfterAPause() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: Diag.binary.path), "build bubble-diag first: swift build")
        let url = tempMovie("crash-pause")
        defer { cleanUp(url) }
        let r = try Diag.run(["synthetic", url.path, "--seconds", "30", "--pause", "4:3", "--crash-after", "12.5", "--fast"])
        #expect(r.signaled, "\(r.output)")
        let report = await MediaProbe.inspect(url)
        #expect(report.playable, "\(report)")
        // Killed at 12.5 s of video: the fragment that ends at 10 s is on disk, the next one is not.
        #expect(report.decodedSeconds >= 10.0, "\(report)")
        // The tail of a crashed file can lose one frame at the last fragment boundary (seen: 0.067 s).
        #expect(report.maxFrameGap < 0.1, "\(report)")
    }

    @Test func diagCheckFailsOnAMissingOrBrokenFile() throws {
        try #require(FileManager.default.isExecutableFile(atPath: Diag.binary.path))
        let junk = tempMovie("junk")
        try Data(repeating: 0x42, count: 4096).write(to: junk)
        defer { cleanUp(junk) }
        #expect(try Diag.run(["check", junk.path]).status == 1)
        #expect(try Diag.run(["check", "/nonexistent/x.mp4"]).status == 1)
    }
}
