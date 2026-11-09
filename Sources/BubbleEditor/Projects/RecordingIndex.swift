// Recording ↔ project id (docs/editor-architecture.md §1, §3). Owner: E1.
// The id lives in an extended attribute of the recording (`local.bubble.project-id`: metadata,
// the video bytes are never written) and in `Projects/index.json` (path, size, creation date),
// so a project survives a rename or a move in Finder, and a copy without the xattr is still found.
import CryptoKit
import Foundation

public struct RecordingIndex: Sendable {
    public struct Entry: Codable, Sendable, Equatable {
        public var id: String
        public var path: String
        public var bytes: Int64
        public var createdAt: String
    }

    public static let xattrName = "local.bubble.project-id"

    /// `Projects/index.json`.
    public let file: URL

    public init(file: URL) { self.file = file }

    /// Facts about a recording file used to find it again.
    public struct FileFacts: Sendable, Equatable {
        public var bytes: Int64
        public var created: Date
        public init(bytes: Int64, created: Date) { self.bytes = bytes; self.created = created }

        public static func of(_ url: URL) throws -> FileFacts {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let created = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
            return FileFacts(bytes: bytes, created: created)
        }
    }

    // MARK: index.json

    public func entries() -> [Entry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    func write(_ entries: [Entry]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(entries).write(to: file, options: .atomic)
    }

    /// Adds or replaces the entry of `id`.
    public func record(id: String, recording: URL, facts: FileFacts) throws {
        var all = entries().filter { $0.id != id }
        all.append(Entry(id: id, path: recording.standardizedFileURL.resolvingSymlinksInPath().path, bytes: facts.bytes,
                         createdAt: ISO8601.string(facts.created)))
        try write(all)
    }

    /// The project id of `recording`: its xattr first; else the index by path; else by size +
    /// creation date (a moved file without the xattr). nil: a recording never opened.
    /// `projectPath` gives where a project last saw its recording (nil: no such project, so a
    /// stale xattr is ignored). A project whose recording still exists at another path belongs to
    /// that file: this one is a copy (a Finder duplicate carries the xattr) and gets its own project.
    public func lookup(_ recording: URL, facts: FileFacts, projectPath: (String) -> String?) -> String? {
        let path = recording.standardizedFileURL.resolvingSymlinksInPath().path
        func owns(_ id: String) -> Bool {
            guard let owner = projectPath(id) else { return false }
            return owner == path || !FileManager.default.fileExists(atPath: owner)
        }
        if let id = Self.readXattr(recording), owns(id) { return id }
        let all = entries()
        if let e = all.first(where: { $0.path == path }), owns(e.id) { return e.id }
        let created = ISO8601.string(facts.created)
        if let e = all.first(where: { $0.bytes == facts.bytes && $0.createdAt == created }), owns(e.id) { return e.id }
        return nil
    }

    public func entry(id: String) -> Entry? { entries().first { $0.id == id } }

    public func remove(id: String) throws { try write(entries().filter { $0.id != id }) }

    // MARK: xattr

    public static func readXattr(_ url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path else { return nil }
            let size = getxattr(path, xattrName, nil, 0, 0, 0)
            guard size > 0, size < 256 else { return nil }
            var buf = [UInt8](repeating: 0, count: size)
            guard getxattr(path, xattrName, &buf, size, 0, 0) == size else { return nil }
            return String(bytes: buf, encoding: .utf8)
        }
    }

    /// Best effort: a read-only volume just means the index is the only link.
    @discardableResult
    public static func writeXattr(_ url: URL, id: String) -> Bool {
        url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            let bytes = Array(id.utf8)
            return setxattr(path, xattrName, bytes, bytes.count, 0, 0) == 0
        }
    }
}

/// What a video file is, whatever its name or place (docs/editor-open-video.md §4): its size, its
/// length, and the sha256 of its first and last 1 MB (of the whole file, twice, under 2 MB). The
/// page computes the same hashes for a dropped file.
public struct VideoFingerprint: Codable, Sendable, Equatable {
    public var bytes: Int64
    public var duration: Double
    public var head: String
    public var tail: String

    public static let window = 1 << 20

    public init(bytes: Int64, duration: Double, head: String, tail: String) {
        self.bytes = bytes; self.duration = duration; self.head = head; self.tail = tail
    }

    public static func of(_ url: URL, duration: Double) throws -> VideoFingerprint {
        let (bytes, head, tail) = try hashes(of: url)
        return VideoFingerprint(bytes: bytes, duration: duration, head: head, tail: tail)
    }

    /// `of`, off the cooperative pool: a slow or sleeping disk blocks a dispatch thread, never a
    /// Swift concurrency one (BlockingRead, editor-architecture.md §4).
    public static func read(_ url: URL, duration: Double) async throws -> VideoFingerprint {
        try await BlockingRead.run { _ in try of(url, duration: duration) }
    }

    /// `hashes`, off the cooperative pool.
    public static func readHashes(of url: URL) async throws -> (bytes: Int64, head: String, tail: String) {
        try await BlockingRead.run { _ in try hashes(of: url) }
    }

    /// Size and the two hashes; reads 2 MB at most, whatever the size. Blocking: prefer `readHashes`.
    public static func hashes(of url: URL) throws -> (bytes: Int64, head: String, tail: String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        if size < UInt64(2 * window) {
            let all = try handle.readToEnd() ?? Data()
            let h = sha256(all)
            return (Int64(size), h, h)
        }
        let head = try handle.read(upToCount: window) ?? Data()
        try handle.seek(toOffset: size - UInt64(window))
        let tail = try handle.read(upToCount: window) ?? Data()
        return (Int64(size), sha256(head), sha256(tail))
    }

    /// Same bytes at both ends and same size: the same file for our purposes.
    public func sameBytes(as other: VideoFingerprint) -> Bool {
        bytes == other.bytes && head == other.head && tail == other.tail
    }

    /// Same bytes and the same length (±0.05 s: two probes of one file agree to the ms).
    public func matches(_ other: VideoFingerprint) -> Bool {
        sameBytes(as: other) && abs(duration - other.duration) < 0.05
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension URL {
    /// Whether this file is inside `folder` (both standardized, symlinks resolved).
    func isInside(_ folder: URL) -> Bool {
        let f = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let p = standardizedFileURL.resolvingSymlinksInPath().path
        return p.hasPrefix(f.hasSuffix("/") ? f : f + "/")
    }
}

enum ISO8601 {
    static func string(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false)
            .timeSeparator(.colon).timeZone(separator: .omitted))
    }
}
