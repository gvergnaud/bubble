// Free-space rules. Owner: capture track. Spec: docs/design.md 7.4, docs/architecture.md §3.3.

import Foundation

public enum DiskDecision: Sendable, Equatable { case ok, refuseStart, warn, stopAndSave }

public enum DiskPolicy {
    public static let refuseStartBelow: Int64 = 1_000_000_000
    public static let warnBelow: Int64 = 2_000_000_000
    public static let stopBelow: Int64 = 300_000_000

    /// Before a take: refuse under 1 GB. During a take: stop and save under 300 MB, warn under 2 GB.
    public static func decide(bytesFree: Int64, recording: Bool) -> DiskDecision {
        if !recording { return bytesFree < refuseStartBelow ? .refuseStart : .ok }
        if bytesFree < stopBelow { return .stopAndSave }
        if bytesFree < warnBelow { return .warn }
        return .ok
    }

    /// Minutes left at `bytesPerSecond` before the stop threshold. Used for the low-disk message.
    public static func minutesLeft(bytesFree: Int64, bytesPerSecond: Double) -> Int {
        guard bytesPerSecond > 0 else { return Int.max }
        let usable = Double(max(0, bytesFree - stopBelow))
        return Int(usable / bytesPerSecond / 60)
    }

    /// Free space for the volume of `url` (`volumeAvailableCapacityForImportantUsage`), nil if unknown.
    public static func bytesFree(at url: URL) -> Int64? {
        var probe = url
        // The file or folder may not exist yet: ask its nearest existing parent.
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
