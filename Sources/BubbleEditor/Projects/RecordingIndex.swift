// Recording ↔ project id (docs/editor-architecture.md §1, §3). Owner: E1.
// The id lives in an extended attribute of the recording (`local.bubble.project-id`: metadata,
// the video bytes are never written) and in `Projects/index.json` (path, size, creation date),
// so a project survives a rename or a move in Finder, and a copy without the xattr is still found.
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
        all.append(Entry(id: id, path: recording.standardizedFileURL.path, bytes: facts.bytes,
                         createdAt: ISO8601.string(facts.created)))
        try write(all)
    }

    /// The project id of `recording`: its xattr first; else the index by path; else by size +
    /// creation date (a moved copy without the xattr). nil: a recording never opened.
    /// `exists` says whether a project folder still has that id (a stale xattr is ignored).
    public func lookup(_ recording: URL, facts: FileFacts, exists: (String) -> Bool) -> String? {
        if let id = Self.readXattr(recording), exists(id) { return id }
        let all = entries()
        let path = recording.standardizedFileURL.path
        if let e = all.first(where: { $0.path == path }), exists(e.id) { return e.id }
        let created = ISO8601.string(facts.created)
        if let e = all.first(where: { $0.bytes == facts.bytes && $0.createdAt == created }), exists(e.id) { return e.id }
        return nil
    }

    public func entry(id: String) -> Entry? { entries().first { $0.id == id } }

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

enum ISO8601 {
    static func string(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false)
            .timeSeparator(.colon).timeZone(separator: .omitted))
    }
}
