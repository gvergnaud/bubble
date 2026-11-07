// Owner: QA. The contract test on Bubble's REAL editor server (docs/editor-architecture.md §8 qa.2):
// EditorService in-process on a temp Application Support folder and a copy of the fixture, then the
// same request script as for the mock (web/test/contract.mjs), then the golden checks of the file it
// exported (web/test/export-check.mjs). Needs node and ffmpeg/ffprobe (Homebrew); skipped without.
// Output: $BUBBLE_EDITOR_OUT (scripts/check.sh) or build/check/editor/contract-real.
import BubbleEditor
import Foundation
import Testing

enum Tool {
    static func find(_ name: String) -> String? {
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin"
        for dir in path.split(separator: ":") where FileManager.default.isExecutableFile(atPath: "\(dir)/\(name)") { return "\(dir)/\(name)" }
        return nil
    }

    /// Runs a command, returns (status, combined output). Never blocks the cooperative pool.
    static func run(_ exe: String, _ args: [String], cwd: URL = Repo.root) async -> (Int32, String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                p.currentDirectoryURL = cwd
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin"
                p.environment = env
                let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
                do { try p.run() } catch { cont.resume(returning: (-1, "\(error)")); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }
}

@Suite(.serialized, .enabled(if: Tool.find("node") != nil && Tool.find("ffprobe") != nil, "needs node and ffmpeg"))
struct ContractTests {
    @Test(.timeLimit(.minutes(5)))
    func realServerMatchesTheContract() async throws {
        // scripts/check.sh sets the folder; other runs get their own, so two runs never share files.
        let out = ProcessInfo.processInfo.environment["BUBBLE_EDITOR_OUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("bubble-contract-out-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bubble-contract-\(UUID().uuidString.prefix(8))")
        let support = tmp.appendingPathComponent("Application Support/Bubble", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // A copy: open() tags the recording with an xattr; the repo's fixture stays untouched.
        let recording = tmp.appendingPathComponent("Bubble 2026-11-06 at 14.22.05.mp4")
        try FileManager.default.copyItem(at: Repo.url("web/fixtures/demo.mp4"), to: recording)

        let svc = EditorService(appSupport: support, webRoot: Repo.url("web/editor"), port: 0,
                                transcribers: [FixtureTranscriber(wordsFile: Repo.url("web/fixtures/demo.project.json"))])
        defer { Task { await svc.stop() } }
        let edit = try await svc.editURL(for: recording)
        let comps = try #require(URLComponents(url: edit, resolvingAgainstBaseURL: false))
        let token = try #require(comps.queryItems?.first { $0.name == "t" }?.value)
        let id = edit.deletingLastPathComponent().path == "/edit" ? edit.lastPathComponent : String(comps.path.split(separator: "/").last ?? "")
        let base = "http://127.0.0.1:\(comps.port ?? 0)"

        let node = try #require(Tool.find("node"))
        // Always the fixture engine: never the server's default, which could be Voxtral (network)
        // if a Mistral key is on this Mac.
        let (status, log) = await Tool.run(node, ["web/test/contract.mjs", "--base", base, "--token", token, "--id", id,
                                                  "--source", recording.path, "--out", out.path, "--engine", "fixture"])
        try? log.write(to: out.appendingPathComponent("contract.txt"), atomically: true, encoding: .utf8)
        let failed = log.split(separator: "\n").filter { $0.hasPrefix("FAIL") }
        #expect(status == 0, "contract on the real server: \(failed.count) FAIL\n\(failed.joined(separator: "\n"))")

        // The exported file: duration, fps, clean decode, A/V in sync with the source.
        if FileManager.default.fileExists(atPath: out.appendingPathComponent("export.mp4").path) {
            let (s2, log2) = await Tool.run(node, ["web/test/export-check.mjs", "--from", out.path, "--source", recording.path])
            try? log2.write(to: out.appendingPathComponent("export-check.txt"), atomically: true, encoding: .utf8)
            #expect(s2 == 0, "export golden checks:\n\(log2.split(separator: "\n").filter { $0.hasPrefix("FAIL") }.joined(separator: "\n"))")
        } else {
            Issue.record("no export.mp4: the export did not finish (see contract.txt)")
        }

        // The page on the real server (headless Chrome, no window): hover, selection both ways,
        // cut, speed, undo, autosave, reload. The contract left a ready transcript.
        let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        if FileManager.default.isExecutableFile(atPath: chrome) {
            let (s3, log3) = await Tool.run(node, ["web/test/page.mjs", "--base", base, "--token", token, "--id", id,
                                                   "--out", out.appendingPathComponent("page").path])
            #expect(s3 == 0, "page on the real server:\n\(log3.split(separator: "\n").filter { $0.hasPrefix("FAIL") }.joined(separator: "\n"))")
        }
    }
}
