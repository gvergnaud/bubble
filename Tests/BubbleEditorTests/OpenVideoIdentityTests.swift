// Owner: QA. "Same video, same project" and "the video is never written" for any video
// (docs/editor-open-video.md §1, §4), on copies of web/fixtures/open-video/* in a temp folder.
// Complements editor-server's OpenAnyVideoTests (ServerUnitTests.swift): bytes, dates and
// extended attributes of a foreign file before/after everything the store does to it, a moved
// foreign file, a Finder copy of a foreign file, and the drop's tie between identical copies.
import BubbleEditor
import CryptoKit
import Foundation
import Testing

private struct FileState: Equatable {
    var sha: String; var size: Int; var modified: Date; var xattrs: [String]
    static func of(_ url: URL) throws -> FileState {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let sha = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        return FileState(sha: sha, size: attrs[.size] as? Int ?? -1, modified: attrs[.modificationDate] as? Date ?? .distantPast, xattrs: xattrNames(url))
    }
    static func xattrNames(_ url: URL) -> [String] {
        let n = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        guard n > 0 else { return [] }
        var buf = [CChar](repeating: 0, count: n)
        _ = listxattr(url.path, &buf, n, XATTR_NOFOLLOW)
        return buf.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }.sorted()
    }
}

private struct Folders {
    let root, support, recordings, desktop: URL
    init() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("bubble-identity-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        support = root.appendingPathComponent("Application Support/Bubble", isDirectory: true)
        recordings = root.appendingPathComponent("Movies/Bubble", isDirectory: true)
        desktop = root.appendingPathComponent("Desktop", isDirectory: true)
        for d in [support, recordings, desktop] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
    }
    func copy(_ fixture: String, to dir: URL, as name: String? = nil) throws -> URL {
        let url = dir.appendingPathComponent(name ?? fixture)
        try FileManager.default.copyItem(at: Repo.url("web/fixtures/open-video/\(fixture)"), to: url)
        return url
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct OpenVideoIdentityTests {
    @Test func aForeignVideoIsNeverWrittenNorTagged() async throws {
        let f = try Folders(); defer { f.clean() }
        let store = ProjectStore(appSupport: f.support)
        let video = try f.copy("h264.mov", to: f.desktop)
        let before = try FileState.of(video)
        let p = try await store.open(recording: video, recordingsFolder: f.recordings)
        _ = try await store.open(recording: video, recordingsFolder: f.recordings)
        _ = try await store.sourceFile(p.id)
        _ = try await store.relink(p.id, to: video, recordingsFolder: f.recordings)
        try await store.remove(p.id)
        #expect(try FileState.of(video) == before, "bytes, size, date and xattrs of a foreign file must not change")
        #expect(RecordingIndex.readXattr(video) == nil)
        #expect(FileManager.default.fileExists(atPath: video.path), "removing the project never deletes the video")
    }

    @Test func onlyBubblesOwnRecordingsGetTheXattrAndTheirBytesStay() async throws {
        let f = try Folders(); defer { f.clean() }
        let store = ProjectStore(appSupport: f.support)
        let rec = try f.copy("h264.mp4", to: f.recordings, as: "Bubble 2026-11-09 at 10.00.00.mp4")
        let before = try FileState.of(rec)
        let p = try await store.open(recording: rec, recordingsFolder: f.recordings)
        #expect(RecordingIndex.readXattr(rec) == p.id)
        let after = try FileState.of(rec)
        #expect(after.sha == before.sha && after.size == before.size, "the xattr is the only change to a recording")
    }

    @Test func aForeignVideoMovedOnItsDriveKeepsItsProject() async throws {
        let f = try Folders(); defer { f.clean() }
        let store = ProjectStore(appSupport: f.support)
        let video = try f.copy("hevc.mp4", to: f.desktop)
        let p = try await store.open(recording: video, recordingsFolder: f.recordings)
        let sub = f.root.appendingPathComponent("Documents/Footage", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let moved = sub.appendingPathComponent("Renamed talk.mp4")
        try FileManager.default.moveItem(at: video, to: moved)
        let (info, url) = try await store.sourceFile(p.id)
        #expect(info.state == .ok && info.name == "Renamed talk.mp4", "\(info)")
        #expect(url?.path == moved.path)
        #expect(try await store.open(recording: moved, recordingsFolder: f.recordings).id == p.id, "opening it at its new place: same project")
    }

    @Test func aCopyOfAForeignVideoIsAnotherProjectWhileTheOriginalExists() async throws {
        let f = try Folders(); defer { f.clean() }
        let store = ProjectStore(appSupport: f.support)
        let video = try f.copy("p25.mp4", to: f.desktop)
        let p = try await store.open(recording: video, recordingsFolder: f.recordings)
        let copy = f.desktop.appendingPathComponent("p25 copy.mp4")
        try FileManager.default.copyItem(at: video, to: copy)   // Finder's Duplicate: same bytes, same xattrs
        let q = try await store.open(recording: copy, recordingsFolder: f.recordings)
        #expect(q.id != p.id, "a duplicate is another file to edit")
        // The original deleted, the copy elsewhere is "the same video moved to another drive".
        let elsewhere = f.root.appendingPathComponent("p60 elsewhere.mp4")
        let other = try f.copy("p60.mp4", to: f.desktop)
        let r = try await store.open(recording: other, recordingsFolder: f.recordings)
        try FileManager.default.copyItem(at: other, to: elsewhere)
        try FileManager.default.removeItem(at: other)
        #expect(try await store.open(recording: elsewhere, recordingsFolder: f.recordings).id == r.id, "found by its fingerprint")
    }

    @Test func aMissingVideoSaysSoAndLocateChecksTheLength() async throws {
        let f = try Folders(); defer { f.clean() }
        let store = ProjectStore(appSupport: f.support)
        let video = try f.copy("h264.mp4", to: f.desktop)
        let p = try await store.open(recording: video, recordingsFolder: f.recordings)
        try FileManager.default.removeItem(at: video)
        #expect(try await store.sourceFile(p.id).info.state == .missing)
        let short = try f.copy("one-second.mp4", to: f.desktop)
        let shortBefore = try FileState.of(short)
        await #expect(throws: EditorError.self) { _ = try await store.relink(p.id, to: short, recordingsFolder: f.recordings) }
        let sameLength = try f.copy("h264.mov", to: f.desktop)
        let sameBefore = try FileState.of(sameLength)
        #expect(try await store.relink(p.id, to: sameLength, recordingsFolder: f.recordings) == false, "same length, other bytes")
        #expect(try await store.sourceFile(p.id).info.state == .ok)
        #expect(try FileState.of(short) == shortBefore && FileState.of(sameLength) == sameBefore, "locate never writes or tags a foreign file")
        #expect(RecordingIndex.readXattr(sameLength) == nil)
    }

    /// Two identical copies on the Mac: the drop opens the one whose date matches the dropped
    /// File.lastModified, else the newest (docs/editor-api.md §8).
    @Test func aDropBetweenIdenticalCopiesPicksByDateThenNewest() async throws {
        let f = try Folders(); defer { f.clean() }
        let older = try f.copy("h264.m4v", to: f.desktop, as: "talk.m4v")
        let newerDir = f.root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: newerDir, withIntermediateDirectories: true)
        let newer = try f.copy("h264.m4v", to: newerDir, as: "talk.m4v")
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000), newDate = Date(timeIntervalSince1970: 1_760_000_000)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: older.path)
        try FileManager.default.setAttributes([.modificationDate: newDate], ofItemAtPath: newer.path)

        let svc = EditorService(appSupport: f.support, webRoot: nil, port: 0, recordingsFolder: { f.recordings },
                                findFiles: { name, _ in name == "talk.m4v" ? [newer, older] : [] })
        defer { svc.stop() }
        let rec = try f.copy("h264.mp4", to: f.recordings, as: "Bubble take.mp4")
        let edit = try await svc.editURL(for: rec)
        let comps = try #require(URLComponents(url: edit, resolvingAgainstBaseURL: false))
        let token = try #require(comps.queryItems?.first { $0.name == "t" }?.value)
        let (size, head, tail) = try VideoFingerprint.hashes(of: older)

        func drop(lastModified: Date) async throws -> String? {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(comps.port ?? 0)/api/open/dropped")!)
            req.httpMethod = "POST"
            req.setValue("bubble=\(token)", forHTTPHeaderField: "Cookie")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["name": "talk.m4v", "size": size,
                "lastModified": Int64(lastModified.timeIntervalSince1970 * 1000), "head": head, "tail": tail])
            let (data, _) = try await URLSession.shared.data(for: req)
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["projectId"] as? String
        }
        let byDate = try #require(try await drop(lastModified: oldDate))
        #expect(try await svc.projectID(for: older) == byDate, "lastModified matches the older copy: that one")
        let newest = try #require(try await drop(lastModified: Date(timeIntervalSince1970: 1_500_000_000)))
        #expect(try await svc.projectID(for: newer) == newest, "no date matches: the newest copy")
        #expect(byDate != newest, "two files, two projects")
    }
}
