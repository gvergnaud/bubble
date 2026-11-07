// The capture engine's lines in the app's plain-text log, ~/Library/Logs/Bubble/bubble.log
// (the same file and format as BubbleUI's AppLog). Owner: capture track. Never logs media content.
//
// Thread-safe: lines are appended with O_APPEND writes of one whole line, so they never mix with
// AppLog's lines written from another queue.

import Foundation
import os

public enum CaptureLog {
    private static let queue = DispatchQueue(label: "local.bubble.Bubble.capturelog")
    private static let logger = Logger(subsystem: "local.bubble.Bubble", category: "Capture")

    static let url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Bubble/bubble.log")

    /// Off in tests, like AppLog (BUBBLE_NO_FILE_LOG, or a test runner process).
    private static let toFile: Bool = {
        let info = ProcessInfo.processInfo
        return info.environment["BUBBLE_NO_FILE_LOG"] == nil
            && !info.processName.contains("xctest") && !info.processName.contains("PackageTests")
    }()

    public static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        guard toFile else { return }
        let line = "\(timestamp()) [\(ProcessInfo.processInfo.processIdentifier)] \(message)\n"
        queue.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else { return }
            defer { close(fd) }
            let bytes = Array(line.utf8)
            _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
