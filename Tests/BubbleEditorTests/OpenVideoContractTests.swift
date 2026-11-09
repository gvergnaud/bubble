// Owner: QA. "Open any video" on Bubble's REAL editor server (docs/editor-api.md §8,
// docs/editor-open-video.md): EditorService in-process on a temp Application Support folder, with a
// fake open panel and a fake Spotlight lookup that the request script steers through files, then the
// same script as for the mock (web/test/open-video.mjs). The videos are copies of
// web/fixtures/open-video/* in a temp folder (the script renames and deletes some). Needs node.
// Output: $BUBBLE_EDITOR_OUT/open-video-real or a temp folder.
import BubbleEditor
import Foundation
import Testing

/// The fake panel and lookup: `<dir>/pick` is a path, "cancel" or "hold" (a held panel answers when
/// the file changes); `<dir>/found` lists the paths the lookup returns, one per line.
struct SteeredMac: Sendable {
    let dir: URL
    private var pickFile: URL { dir.appendingPathComponent("pick") }
    private func read(_ name: String) -> String {
        (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func pickVideo(_ pick: VideoPick) async -> URL? {
        var answer = read("pick")
        while answer == "hold" {
            try? await Task.sleep(for: .milliseconds(50))
            answer = read("pick")
        }
        return answer.isEmpty || answer == "cancel" ? nil : URL(fileURLWithPath: answer)
    }

    func findFiles(name: String, size: Int64) async -> [URL] {
        read("found").split(separator: "\n").map { URL(fileURLWithPath: String($0)) }.filter { $0.lastPathComponent == name }
    }
}

@Suite(.serialized, .enabled(if: Tool.find("node") != nil, "needs node"))
struct OpenVideoContractTests {
    @Test(.timeLimit(.minutes(3)))
    func realServerOpensAnyVideo() async throws {
        let out = (ProcessInfo.processInfo.environment["BUBBLE_EDITOR_OUT"].map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("bubble-open-video-out-\(UUID().uuidString.prefix(8))"))
            .appendingPathComponent("open-video-real")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("bubble-open-video-\(UUID().uuidString.prefix(8))")
        let support = tmp.appendingPathComponent("Application Support/Bubble", isDirectory: true)
        let recordings = tmp.appendingPathComponent("Movies/Bubble", isDirectory: true)
        let media = tmp.appendingPathComponent("Desktop", isDirectory: true)
        let steer = tmp.appendingPathComponent("steer", isDirectory: true)
        for d in [support, recordings, steer] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        defer { try? fm.removeItem(at: tmp) }
        try fm.copyItem(at: Repo.url("web/fixtures/open-video"), to: media)
        try? fm.removeItem(at: media.appendingPathComponent("make.sh"))
        // A Bubble recording, only to get the server's token through editURL (the app's own path).
        let recording = recordings.appendingPathComponent("Bubble 2026-11-09 at 10.00.00.mp4")
        try fm.copyItem(at: Repo.url("web/fixtures/open-video/h264.m4v"), to: recording)

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
        let (status, log) = await Tool.run(node, ["web/test/open-video.mjs", "--base", "http://127.0.0.1:\(comps.port ?? 0)",
                                                  "--token", token, "--media", media.path, "--steer", steer.path, "--out", out.path])
        try? log.write(to: out.appendingPathComponent("open-video.txt"), atomically: true, encoding: .utf8)
        let failed = log.split(separator: "\n").filter { $0.hasPrefix("FAIL") }
        #expect(status == 0, "open-video on the real server: \(failed.count) FAIL\n\(failed.joined(separator: "\n"))\n\(status != 1 ? log : "")")
    }
}
