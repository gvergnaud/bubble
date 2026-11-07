// File names and folder for takes. Owner: capture track. Spec: docs/design.md 7.4 (same-second name).

import Foundation

public enum RecordingFiles {
    /// "~/Movies/Bubble/Bubble 2026-11-06 at 14.22.05.mp4", then " (2)", " (3)" if taken.
    /// Local time, Gregorian calendar, whatever the user's locale.
    public static func newURL(in folder: URL, date: Date, exists: (URL) -> Bool) -> URL {
        let base = "Bubble " + stamp(date)
        var n = 1
        while true {
            let name = n == 1 ? "\(base).mp4" : "\(base) (\(n)).mp4"
            let url = folder.appendingPathComponent(name, isDirectory: false)
            if !exists(url) { return url }
            n += 1
        }
    }

    public static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Bubble", isDirectory: true)
    }

    /// Creates the folder (and its parents) if needed.
    public static func ensureFolder(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// A new URL in `folder` (created if needed), checked against the disk.
    public static func newURL(in folder: URL, date: Date = Date()) throws -> URL {
        try ensureFolder(folder)
        return newURL(in: folder, date: date) { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: date)
    }
}
