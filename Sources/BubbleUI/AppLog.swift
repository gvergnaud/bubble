// Owner: app/UI track. A plain text log of what the app does, readable without Console:
// ~/Library/Logs/Bubble/bubble.log (launch, permissions, the menu bar item, clicks, the panel).
// Also sent to the unified log (subsystem local.bubble.Bubble). Never logs screen content.
import Foundation
import os

public enum AppLog {
    private static let queue = DispatchQueue(label: "local.bubble.Bubble.log")
    private static let logger = Logger(subsystem: "local.bubble.Bubble", category: "App")

    public static let url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Bubble/bubble.log")

    /// Off in tests (they set BUBBLE_NO_FILE_LOG) so test runs don't write to the user's log.
    private static let toFile = ProcessInfo.processInfo.environment["BUBBLE_NO_FILE_LOG"] == nil
        && !ProcessInfo.processInfo.processName.contains("xctest")
        && !ProcessInfo.processInfo.processName.contains("PackageTests")
        // Swift Testing runs in this helper: without it, test runs wrote "camera start failed" lines.
        && !ProcessInfo.processInfo.processName.contains("swiftpm-testing-helper")

    public static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        guard toFile else { return }
        let line = "\(timestamp()) [\(ProcessInfo.processInfo.processIdentifier)] \(message)\n"
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Keep it small: start over past 2 MB.
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 2_000_000 {
                try? fm.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
