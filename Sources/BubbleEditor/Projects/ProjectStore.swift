// Projects on disk (docs/editor-architecture.md §3). Owner: E1.
//   <appSupport>/Projects/index.json        recording ↔ id (RecordingIndex)
//   <appSupport>/Projects/<id>/project.json  StoredProject (the Project minus derived URLs), version 1
//   <appSupport>/Projects/<id>/waveform.bin, poster.jpg, transcript-raw/, exports/
// One actor, one file per project, atomic writes: a crash never leaves half a project.
// The recording itself is only read (and tagged with an xattr by RecordingIndex).
@preconcurrency import AVFoundation
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

    /// The API shape (editor-api.md §2): URLs derived from the id, `export` from the export jobs.
    public func api(export: ExportJob?) -> Project {
        Project(id: id, title: title, createdAt: createdAt, updatedAt: updatedAt,
                video: Video(url: EditorURLs.source(id), duration: video.duration, width: video.width,
                             height: video.height, fps: video.fps, posterUrl: EditorURLs.poster(id)),
                waveform: WaveformRef(url: EditorURLs.waveform(id)), transcript: transcript, edits: edits,
                export: export)
    }
}

/// Reads duration, size and frame rate of a recording. A protocol so tests can skip AVFoundation.
public protocol VideoProbe: Sendable {
    func facts(of recording: URL) async throws -> StoredProject.VideoFacts
}

public struct AVVideoProbe: VideoProbe {
    public init() {}
    public func facts(of recording: URL) async throws -> StoredProject.VideoFacts {
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

    // MARK: open

    /// The project of `recording`, created on first open (id, title = file name, video facts,
    /// xattr + index). Also updates where the recording is (it may have moved).
    @discardableResult
    public func open(recording: URL) async throws -> StoredProject {
        let recording = recording.standardizedFileURL
        guard FileManager.default.fileExists(atPath: recording.path) else { throw EditorError.sourceMissing }
        let facts = try RecordingIndex.FileFacts.of(recording)
        if let id = index.lookup(recording, facts: facts, exists: { FileManager.default.fileExists(atPath: file($0).path) }),
           var p = try? load(id) {
            if p.recordingPath != recording.path {
                p.recordingPath = recording.path
                try save(p)
            }
            if RecordingIndex.readXattr(recording) != id { RecordingIndex.writeXattr(recording, id: id) }
            try index.record(id: id, recording: recording, facts: facts)
            return p
        }
        let video = try await probe.facts(of: recording)
        let id = UUID().uuidString.lowercased()
        let stamp = ISO8601.string(now())
        let p = StoredProject(version: 1, id: id, title: recording.deletingPathExtension().lastPathComponent,
                              createdAt: ISO8601.string(facts.created), updatedAt: stamp,
                              recordingPath: recording.path, video: video, transcript: .none, edits: Edits())
        try FileManager.default.createDirectory(at: folder(id), withIntermediateDirectories: true)
        try save(p)
        RecordingIndex.writeXattr(recording, id: id)
        try index.record(id: id, recording: recording, facts: facts)
        return p
    }

    // MARK: read

    /// Throws `.notFound` for an id with no project folder.
    public func project(_ id: String) throws -> StoredProject {
        guard Self.isValidID(id) else { throw EditorError.notFound("No such project.") }
        return try load(id)
    }

    /// The recording's file, if it is still where we last saw it.
    public func source(_ id: String) throws -> URL {
        let p = try project(id)
        let url = URL(fileURLWithPath: p.recordingPath)
        guard FileManager.default.fileExists(atPath: url.path) else { throw EditorError.sourceMissing }
        return url
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
        // A job cut short by a quit: say so rather than spin forever.
        if p.transcript.status == .queued || p.transcript.status == .running {
            p.transcript.status = .failed
            p.transcript.error = "The transcription stopped when Bubble quit. Try again."
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
