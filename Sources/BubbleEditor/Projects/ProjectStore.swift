// Projects on disk (docs/editor-architecture.md §3). Owner: E1.
//   <appSupport>/Projects/index.json        recording ↔ id (RecordingIndex)
//   <appSupport>/Projects/<id>/project.json  StoredProject (the Project minus derived URLs), version 1
//   <appSupport>/Projects/<id>/waveform.bin, poster.jpg, transcript-raw/, exports/
// One actor, one file per project, atomic writes: a crash never leaves half a project.
// The recording itself is only read (and tagged with an xattr by RecordingIndex).
@preconcurrency import AVFoundation
import BubbleCore
import Foundation

/// What `project.json` holds.
public struct StoredProject: Codable, Sendable, Equatable {
    public struct VideoFacts: Codable, Sendable, Equatable {
        public var duration: Double
        public var width: Int
        public var height: Int
        public var fps: Double
        public init(duration: Double, width: Int, height: Int, fps: Double) {
            self.duration = duration; self.width = width; self.height = height; self.fps = fps
        }
    }

    public var version: Int
    public var id: String
    public var title: String
    public var createdAt: String
    public var updatedAt: String
    /// Where the recording was last seen.
    public var recordingPath: String
    public var video: VideoFacts
    public var transcript: Transcript
    public var edits: Edits
    /// A macOS bookmark of the video (follows renames and moves on its volume; carries the
    /// volume's name for the offline state). nil in projects made before 2026-11-09.
    public var bookmark: Data? = nil
    /// Size, length and end hashes: finds the video again after a move to another volume.
    public var fingerprint: VideoFingerprint? = nil

    /// The API shape (editor-api.md §2): URLs derived from the id, `export` from the export jobs.
    public func api(export: ExportJob?, source: SourceFile) -> Project {
        Project(id: id, title: title, createdAt: createdAt, updatedAt: updatedAt,
                video: Video(url: EditorURLs.source(id), duration: video.duration, width: video.width,
                             height: video.height, fps: video.fps, posterUrl: EditorURLs.poster(id)),
                waveform: WaveformRef(url: EditorURLs.waveform(id)), transcript: transcript, edits: edits,
                export: export, source: source)
    }
}

/// Reads duration, size and frame rate of a recording. A protocol so tests can skip AVFoundation.
public protocol VideoProbe: Sendable {
    func facts(of recording: URL) async throws -> StoredProject.VideoFacts
}

public struct AVVideoProbe: VideoProbe {
    public init() {}
    public func facts(of recording: URL) async throws -> StoredProject.VideoFacts {
        // What Bubble can't edit is refused here, with the sentence the page and the app show.
        do { _ = try await MediaCheck.inspect(recording) } catch {
            if error == .missing { throw EditorError.sourceMissing }
            throw EditorError.refused(code: error.code, message: error.description)
        }
        let asset = AVURLAsset(url: recording)
        // The longest track, as ffprobe's format duration and the browser's <video>.duration see it
        // (the movie duration can be a few ms short of the audio's end).
        var duration = try await asset.load(.duration).seconds
        for track in try await asset.load(.tracks) {
            let end = try await track.load(.timeRange).end.seconds
            if end.isFinite { duration = max(duration, end) }
        }
        guard duration.isFinite, duration > 0 else { throw EditorError.failed("This file has no video Bubble can read.") }
        var width = 0, height = 0, fps = 30.0
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let (size, transform, rate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
            let r = CGRect(origin: .zero, size: size).applying(transform)
            width = Int(abs(r.width).rounded()); height = Int(abs(r.height).rounded())
            if rate > 0 { fps = (Double(rate) * 1000).rounded() / 1000 }
        }
        return .init(duration: (duration * 1000).rounded() / 1000, width: width, height: height, fps: fps)
    }
}

public actor ProjectStore {
    public let projectsFolder: URL
    let index: RecordingIndex
    let probe: VideoProbe
    let now: @Sendable () -> Date
    private var cache: [String: StoredProject] = [:]

    /// `appSupport`: `~/Library/Application Support/Bubble` (a temp folder in tests).
    public init(appSupport: URL, probe: VideoProbe = AVVideoProbe(), now: @escaping @Sendable () -> Date = Date.init) {
        projectsFolder = appSupport.appendingPathComponent("Projects", isDirectory: true)
        index = RecordingIndex(file: projectsFolder.appendingPathComponent("index.json"))
        self.probe = probe
        self.now = now
    }

    public nonisolated func folder(_ id: String) -> URL { projectsFolder.appendingPathComponent(id, isDirectory: true) }
    nonisolated func file(_ id: String) -> URL { folder(id).appendingPathComponent("project.json") }

    /// Ids are ours (UUIDs) but come back in URLs: never let one name a path outside Projects/.
    public nonisolated static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    // MARK: open (identity: docs/editor-open-video.md §4, editor-api.md §8)

    /// The project of a video, created on first open (id, title = file name, video facts, bookmark,
    /// fingerprint). Same video, same project, in this order: the xattr (Bubble's own recordings
    /// only) or the index by path; a bookmark that resolves to this file; the fingerprint, when the
    /// project's own file is gone (moved to another volume). A project whose file still exists
    /// elsewhere belongs to that file: this one is a copy and gets its own project.
    /// `recordingsFolder`: Bubble's save folder (nil = RecordingFiles.defaultFolder). Only files
    /// inside it get the xattr; nothing is ever written to other files.
    @discardableResult
    public func open(recording: URL, recordingsFolder: URL? = nil) async throws -> StoredProject {
        let url = recording.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: url.path) else { throw EditorError.sourceMissing }
        let own = url.isInside(recordingsFolder ?? RecordingFiles.defaultFolder)
        let facts = try RecordingIndex.FileFacts.of(url)
        let video = try await probe.facts(of: url)   // refuses what Bubble can't edit, every time
        let fingerprint = try await VideoFingerprint.read(url, duration: video.duration)
        // No await below this line: two opens of one file can't both make a project (actor reentrancy).

        var found = index.lookup(url, facts: facts, projectPath: { id in
            guard let p = try? self.load(id) else { return nil }
            return self.currentPath(p) ?? p.recordingPath
        })
        if let id = found, !own, RecordingIndex.readXattr(url) == id, index.entry(id: id)?.path != url.path {
            found = nil   // an xattr on a foreign file is not ours to trust (a copied recording keeps it)
        }
        if found == nil {
            found = allProjects().first { p in p.bookmark.flatMap(Self.resolve)?.path == url.path }?.id
        }
        if found == nil {
            let fp = fingerprint
            found = allProjects().first { p in
                guard let old = p.fingerprint, old.sameBytes(as: fp), abs(old.duration - fp.duration) <= 0.1 else { return false }
                return currentPath(p) == nil   // its file is gone: this is it, moved
            }?.id
        }

        let stamp = ISO8601.string(now())
        var p: StoredProject
        if let id = found, let existing = try? load(id) {
            p = existing
        } else {
            let id = UUID().uuidString.lowercased()
            p = StoredProject(version: 1, id: id, title: url.deletingPathExtension().lastPathComponent,
                              createdAt: ISO8601.string(facts.created), updatedAt: stamp,
                              recordingPath: url.path, video: video, transcript: .none, edits: Edits())
            try FileManager.default.createDirectory(at: folder(id), withIntermediateDirectories: true)
        }
        p.recordingPath = url.path
        p.bookmark = Self.bookmark(url) ?? p.bookmark
        p.fingerprint = fingerprint
        try save(p)
        if own, RecordingIndex.readXattr(url) != p.id { RecordingIndex.writeXattr(url, id: p.id) }
        try index.record(id: p.id, recording: url, facts: facts)
        return p
    }

    /// Locate: link a project to another file (the user picked it in Bubble's panel). Throws
    /// `.refused(different_video)` when the length differs by more than 0.1 s. Returns whether the
    /// bytes are the same as the file it had (false: same length, other bytes).
    public func relink(_ id: String, to newFile: URL, recordingsFolder: URL? = nil) async throws -> Bool {
        _ = try project(id)
        let url = newFile.standardizedFileURL.resolvingSymlinksInPath()
        let video = try await probe.facts(of: url)
        let fp = try await VideoFingerprint.read(url, duration: video.duration)
        var p = try project(id)   // read after the awaits: edits saved meanwhile are kept
        guard abs(video.duration - p.video.duration) <= 0.1 else {
            throw EditorError.refused(code: "different_video", message: "This video is a different length, so your edits wouldn't line up.")
        }
        let same = p.fingerprint.map { $0.sameBytes(as: fp) } ?? true
        p.recordingPath = url.path
        p.bookmark = Self.bookmark(url)
        p.fingerprint = fp
        p.updatedAt = ISO8601.string(now())
        try save(p)
        if url.isInside(recordingsFolder ?? RecordingFiles.defaultFolder) { RecordingIndex.writeXattr(url, id: id) }
        try index.record(id: id, recording: url, facts: try RecordingIndex.FileFacts.of(url))
        return same
    }

    /// Forgets a project: its folder (edits, transcript, waveform, poster, exports) and its index
    /// entry. Never the video, and its xattr stays (harmless: no project behind it).
    public func remove(_ id: String) throws {
        _ = try project(id)
        try FileManager.default.removeItem(at: folder(id))
        try index.remove(id: id)
        cache[id] = nil
    }

    /// Every project on disk, last edited first.
    public func allProjects() -> [StoredProject] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: projectsFolder.path)) ?? []
        return ids.filter(Self.isValidID).compactMap { try? load($0) }.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: where the video is

    /// The video's file and its state. A file moved on its volume is found by its bookmark (and
    /// the new place remembered); a file on an unmounted volume is `offline`.
    public func sourceFile(_ id: String) throws -> (info: SourceFile, url: URL?) {
        var p = try project(id)
        if let path = currentPath(p) {
            if path != p.recordingPath { p.recordingPath = path; try? save(p) }
            return (Self.info(path: path, state: .ok), URL(fileURLWithPath: path))
        }
        if let volume = offlineVolume(p) { return (Self.info(path: p.recordingPath, state: .offline, volume: volume), nil) }
        return (Self.info(path: p.recordingPath, state: .missing), nil)
    }

    /// The video's file, or `.sourceMissing` / `.sourceOffline`.
    public func source(_ id: String) throws -> URL {
        let (info, url) = try sourceFile(id)
        if let url { return url }
        if info.state == .offline, let v = info.volume { throw EditorError.sourceOffline(volume: v) }
        throw EditorError.sourceMissing
    }

    /// Where the project's video is now: its last path, else where its bookmark resolves. nil: gone.
    nonisolated func currentPath(_ p: StoredProject) -> String? {
        if FileManager.default.fileExists(atPath: p.recordingPath) { return p.recordingPath }
        if let url = p.bookmark.flatMap(Self.resolve), FileManager.default.fileExists(atPath: url.path) { return url.path }
        return nil
    }

    /// The volume's name when the video was on a volume that isn't mounted now.
    nonisolated func offlineVolume(_ p: StoredProject) -> String? {
        let parts = p.recordingPath.split(separator: "/")
        guard parts.count > 2, parts[0] == "Volumes" else { return nil }
        guard !FileManager.default.fileExists(atPath: "/Volumes/\(parts[1])") else { return nil }
        if let data = p.bookmark, let v = URL.resourceValues(forKeys: [.volumeNameKey], fromBookmarkData: data)?.volumeName { return v }
        return String(parts[1])
    }

    nonisolated static func bookmark(_ url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: [.volumeNameKey], relativeTo: nil)
    }

    nonisolated static func resolve(_ data: Data) -> URL? {
        var stale = false
        return (try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale))?.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// "Desktop", "Movies/Bubble" (under the home folder), "T7/Footage" (on a volume), else the full folder path.
    nonisolated static func info(path: String, state: SourceFile.State, volume: String? = nil) -> SourceFile {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var folder = parent
        if parent == home { folder = "Home" }
        else if parent.hasPrefix(home + "/") { folder = String(parent.dropFirst(home.count + 1)) }
        else if parent.hasPrefix("/Volumes/") { folder = String(parent.dropFirst("/Volumes/".count)) }
        return SourceFile(name: url.lastPathComponent, folder: folder, path: path, state: state, volume: volume)
    }

    // MARK: read

    /// Throws `.notFound` for an id with no project folder.
    public func project(_ id: String) throws -> StoredProject {
        guard Self.isValidID(id) else { throw EditorError.notFound("No such project.") }
        return try load(id)
    }

    // MARK: write

    /// PUT /edits: `revision` is the one the page started from. Returns the new revision.
    public func saveEdits(_ id: String, revision: Int, segments: [Segment]) throws -> Int {
        var p = try project(id)
        guard revision == p.edits.revision else { throw EditorError.stale(p.edits) }
        if let why = EditPlan.validate(segments, duration: p.video.duration) { throw EditorError.invalid(why) }
        p.edits = Edits(revision: p.edits.revision + 1, segments: segments)
        p.updatedAt = ISO8601.string(now())
        try save(p)
        return p.edits.revision
    }

    /// PATCH: an empty title keeps the old one; speakers are renamed by id (unknown ids ignored).
    public func update(_ id: String, title: String?, speakers: [Speaker]?) throws -> StoredProject {
        var p = try project(id)
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { p.title = t }
        for s in speakers ?? [] {
            if let i = p.transcript.speakers.firstIndex(where: { $0.id == s.id }) { p.transcript.speakers[i].name = s.name }
        }
        p.updatedAt = ISO8601.string(now())
        try save(p)
        return p
    }

    /// Called by the transcription job as it goes. Names the user gave to speakers are kept when
    /// a new transcript arrives with the same ids.
    public func setTranscript(_ id: String, _ transcript: Transcript) throws {
        var p = try project(id)
        var t = transcript
        for i in t.speakers.indices {
            if let old = p.transcript.speakers.first(where: { $0.id == t.speakers[i].id }),
               old.name != Self.defaultName(old.id) { t.speakers[i].name = old.name }
        }
        p.transcript = t
        p.updatedAt = ISO8601.string(now())
        try save(p)
    }

    static func defaultName(_ id: String) -> String {
        id.hasPrefix("S") ? "Speaker \(id.dropFirst())" : id
    }

    // MARK: disk

    private func load(_ id: String) throws -> StoredProject {
        if let p = cache[id] { return p }
        guard let data = try? Data(contentsOf: file(id)) else { throw EditorError.notFound("No such project.") }
        var p: StoredProject
        do { p = try JSONDecoder().decode(StoredProject.self, from: data) }
        catch { throw EditorError.failed("This project's file is damaged (\(file(id).path)).") }
        // A job cut short by a quit: back to none, so the next open starts it again (no Transcribe
        // button). Real failures stay failed.
        if p.transcript.status == .queued || p.transcript.status == .running {
            p.transcript = .none
            try? save(p)
        }
        cache[id] = p
        return p
    }

    private func save(_ p: StoredProject) throws {
        try FileManager.default.createDirectory(at: folder(p.id), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(p).write(to: file(p.id), options: .atomic)
        cache[p.id] = p
    }
}
