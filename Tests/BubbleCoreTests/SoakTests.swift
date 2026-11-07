// Owner: QA track. Opt-in soak (BUBBLE_SOAK=1 scripts/check.sh): a 2-hour synthetic take through
// bubble-diag, faster than real time, with still-screen spans. Checks the duration, that every frame
// decodes, that audio and video end together, and that the writer process's memory stays flat.
// BUBBLE_SOAK_SECONDS overrides the length (default 7200).
import BubbleTesting
import Foundation
import Testing

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["BUBBLE_SOAK"] != nil, "opt-in: BUBBLE_SOAK=1"))
struct SoakTests {
    static func rssKB(_ pid: Int32) -> Int? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "rss=", "-p", "\(pid)"]
        let pipe = Pipe(); p.standardOutput = pipe
        try? p.run(); p.waitUntilExit()
        return Int(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test(.timeLimit(.minutes(120)))
    func twoHoursFasterThanRealTime() async throws {
        let seconds = Double(ProcessInfo.processInfo.environment["BUBBLE_SOAK_SECONDS"] ?? "") ?? 7200
        let url = tempMovie("soak")
        defer { cleanUp(url) }
        let p = Process()
        p.executableURL = Diag.binary
        p.arguments = ["synthetic", url.path, "--seconds", "\(seconds)", "--static-gaps", "--fast", "--size", "1512x982"]
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        try p.run()
        // Sample the writer's memory every 2 s while it runs.
        var samples: [(Date, Int)] = []
        while p.isRunning {
            if let kb = Self.rssKB(p.processIdentifier) { samples.append((Date(), kb)) }
            try await Task.sleep(for: .seconds(2))
        }
        let log = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(p.terminationStatus == 0, "\(log)")

        // Memory: after the first 10 % (encoder warm-up), the max stays within 64 MB of the median.
        let steady = samples.dropFirst(samples.count / 10).map(\.1).sorted()
        if let maxKB = steady.last, !steady.isEmpty {
            let median = steady[steady.count / 2]
            #expect(maxKB - median < 64 * 1024, "RSS grew: median \(median / 1024) MB, max \(maxKB / 1024) MB over \(samples.count) samples")
        }

        let r = await MediaProbe.inspect(url)
        #expect(r.playable, "\(r)")
        #expect(abs(r.duration - seconds) <= 0.1, "\(r)")
        #expect(abs(Double(r.decodedFrames) - seconds * 30) <= 1, "\(r)")
        #expect(r.maxFrameGap < 0.04, "\(r)")
        #expect(abs(r.audioSeconds - r.decodedSeconds) < 1.0 / 30 + 0.025, "A/V drift at the end: \(r)")
        #expect(r.errors.isEmpty, "\(r)")
    }
}
