// Owner: QA. Headless page checks of "open any video" on Bubble's REAL editor server: EditorService
// in-process with the fake panel and lookup (SteeredMac, OpenVideoContractTests.swift), copies of
// web/fixtures/open-video/*, and one project whose drive isn't connected; then
// web/test/page-open-real.mjs drives the page in headless Chrome (no window).
// Output: $BUBBLE_EDITOR_OUT/../page-open-real or a temp folder. Needs node and Google Chrome.
import BubbleEditor
import Foundation
import Testing

private let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

@Suite(.serialized, .enabled(if: Tool.find("node") != nil && FileManager.default.isExecutableFile(atPath: chrome), "needs node and Chrome"))
struct OpenVideoPageTests {
    @Test(.timeLimit(.minutes(4)))
    func pageOpensAnyVideoOnTheRealServer() async throws {
        let fm = FileManager.default
        let out = (ProcessInfo.processInfo.environment["BUBBLE_EDITOR_OUT"].map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
            ?? fm.temporaryDirectory.appendingPathComponent("bubble-open-page-out-\(UUID().uuidString.prefix(8))"))
            .appendingPathComponent("page-open-real")
        try? fm.removeItem(at: out)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)

        let tmp = fm.temporaryDirectory.appendingPathComponent("bubble-open-page-\(UUID().uuidString.prefix(8))")
        let support = tmp.appendingPathComponent("Application Support/Bubble", isDirectory: true)
        let recordings = tmp.appendingPathComponent("Movies/Bubble", isDirectory: true)
        let media = tmp.appendingPathComponent("Desktop", isDirectory: true)
        let steer = tmp.appendingPathComponent("steer", isDirectory: true)
        for d in [support, recordings, steer] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        defer { try? fm.removeItem(at: tmp) }
        try fm.copyItem(at: Repo.url("web/fixtures/open-video"), to: media)
        try? fm.removeItem(at: media.appendingPathComponent("make.sh"))
        let recording = recordings.appendingPathComponent("Bubble 2026-11-09 at 10.00.00.mp4")
        try fm.copyItem(at: Repo.url("web/fixtures/open-video/hevc.mp4"), to: recording)

        // A project whose video was on a drive that isn't connected: opened from a temp copy, then
        // pointed at /Volumes/BubbleQA-T7 (no bookmark), before the server's store reads it.
        let keynote = tmp.appendingPathComponent("Keynote rehearsal.mp4")
        try fm.copyItem(at: Repo.url("web/fixtures/open-video/p60.mp4"), to: keynote)
        let made = try await ProjectStore(appSupport: support).open(recording: keynote, recordingsFolder: recordings)
        try fm.removeItem(at: keynote)
        let json = support.appendingPathComponent("Projects/\(made.id)/project.json")
        var p = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any])
        p["recordingPath"] = "/Volumes/BubbleQA-T7/Footage/Keynote rehearsal.mp4"
        p["bookmark"] = nil
        try JSONSerialization.data(withJSONObject: p).write(to: json)

        let mac = SteeredMac(dir: steer)
        let svc = EditorService(appSupport: support, webRoot: Repo.url("web/editor"), port: 0,
                                transcribers: [FixtureTranscriber(wordsFile: Repo.url("web/fixtures/demo.project.json"))],
                                recordingsFolder: { recordings },
                                pickVideo: { await mac.pickVideo($0) },
                                bringPanelToFront: {}, onOpened: { _ in }, revealInFinder: { _ in },
                                findFiles: { await mac.findFiles(name: $0, size: $1) })
        defer { Task { await svc.stop() } }
        let edit = try await svc.editURL(for: recording)
        let comps = try #require(URLComponents(url: edit, resolvingAgainstBaseURL: false))
        let token = try #require(comps.queryItems?.first { $0.name == "t" }?.value)

        let node = try #require(Tool.find("node"))
        let (status, log) = await Tool.run(node, ["web/test/page-open-real.mjs", "--base", "http://127.0.0.1:\(comps.port ?? 0)",
                                                  "--token", token, "--media", media.path, "--steer", steer.path, "--out", out.path])
        try? log.write(to: out.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
        let failed = log.split(separator: "\n").filter { $0.hasPrefix("FAIL") }
        #expect(status == 0, "page-open-real: \(failed.count) FAIL\n\(failed.joined(separator: "\n"))\n\(status != 1 ? log : "")")
    }
}
