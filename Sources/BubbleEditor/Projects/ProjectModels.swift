// The Codable mirror of docs/editor-api.md (page ↔ server contract), field for field. Owner: E1.
// Optional fields the contract types as `T | null` are always written (as null); fields it types as
// `field?: T` are left out when absent. Times are seconds in source time.
import Foundation

// MARK: - Project (editor-api.md §2)

public struct Project: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var createdAt: String
    public var updatedAt: String
    public var video: Video
    public var waveform: WaveformRef
    public var transcript: Transcript
    public var edits: Edits
    public var export: ExportJob?
    /// Where the video file is, and whether it's reachable (editor-api.md §2, §8).
    public var source: SourceFile

    public init(id: String, title: String, createdAt: String, updatedAt: String, video: Video,
                waveform: WaveformRef, transcript: Transcript, edits: Edits, export: ExportJob?, source: SourceFile) {
        self.id = id; self.title = title; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.video = video; self.waveform = waveform; self.transcript = transcript; self.edits = edits
        self.export = export; self.source = source
    }

    enum CodingKeys: String, CodingKey { case id, title, createdAt, updatedAt, video, waveform, transcript, edits, export, source }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(video, forKey: .video)
        try c.encode(waveform, forKey: .waveform)
        try c.encode(transcript, forKey: .transcript)
        try c.encode(edits, forKey: .edits)
        try c.encode(export, forKey: .export)   // null when none
        try c.encode(source, forKey: .source)
    }
}

/// Where a project's video is (editor-api.md §2). `path` is for a tooltip only: the page never
/// sends a path back.
public struct SourceFile: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case ok, missing, offline }
    public var name: String
    /// Display name of its folder: "Desktop", "Movies/Bubble", "T7/Footage".
    public var folder: String
    public var path: String
    public var state: State
    /// With `offline`: the volume's name.
    public var volume: String?

    public init(name: String, folder: String, path: String, state: State, volume: String? = nil) {
        self.name = name; self.folder = folder; self.path = path; self.state = state; self.volume = volume
    }
}

/// GET /api/projects (editor-api.md §8).
public struct ProjectSummary: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var duration: Double
    public var editedDuration: Double
    public var posterUrl: String?
    public var updatedAt: String
    public var file: SourceFile

    enum CodingKeys: String, CodingKey { case id, title, duration, editedDuration, posterUrl, updatedAt, file }

    public init(id: String, title: String, duration: Double, editedDuration: Double, posterUrl: String?, updatedAt: String, file: SourceFile) {
        self.id = id; self.title = title; self.duration = duration; self.editedDuration = editedDuration
        self.posterUrl = posterUrl; self.updatedAt = updatedAt; self.file = file
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(duration, forKey: .duration)
        try c.encode(editedDuration, forKey: .editedDuration)
        try c.encode(posterUrl, forKey: .posterUrl)   // null when not made or unreachable
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(file, forKey: .file)
    }
}

public struct ProjectList: Codable, Sendable, Equatable {
    public var projects: [ProjectSummary]
    public init(projects: [ProjectSummary]) { self.projects = projects }
}

/// GET /api/open/:openId (editor-api.md §8).
public struct OpenState: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case pending, opened, canceled, failed }
    public var state: State
    public var projectId: String?
    public var sameBytes: Bool?
    /// 'unsupported_format' | 'no_video' | 'different_video'
    public var error: String?
    public var message: String?

    public init(state: State, projectId: String? = nil, sameBytes: Bool? = nil, error: String? = nil, message: String? = nil) {
        self.state = state; self.projectId = projectId; self.sameBytes = sameBytes; self.error = error; self.message = message
    }
}

public struct Video: Codable, Sendable, Equatable {
    public var url: String
    public var duration: Double
    public var width: Int
    public var height: Int
    public var fps: Double
    public var posterUrl: String

    public init(url: String, duration: Double, width: Int, height: Int, fps: Double, posterUrl: String) {
        self.url = url; self.duration = duration; self.width = width; self.height = height
        self.fps = fps; self.posterUrl = posterUrl
    }
}

public struct WaveformRef: Codable, Sendable, Equatable {
    public var url: String
    public init(url: String) { self.url = url }
}

// MARK: - Transcript

public struct Transcript: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case none, queued, running, ready, failed }

    public var status: Status
    public var progress: Double
    public var engine: String?
    public var language: String?
    public var error: String?
    /// `'no_sound'` with `failed`: no Retry, no engine switch.
    public var errorCode: String?
    public var speakers: [Speaker]
    public var words: [Word]

    public init(status: Status, progress: Double = 0, engine: String? = nil, language: String? = nil,
                error: String? = nil, errorCode: String? = nil, speakers: [Speaker] = [], words: [Word] = []) {
        self.status = status; self.progress = progress; self.engine = engine; self.language = language
        self.error = error; self.errorCode = errorCode; self.speakers = speakers; self.words = words
    }

    public static let none = Transcript(status: .none)

    enum CodingKeys: String, CodingKey { case status, progress, engine, language, error, errorCode, speakers, words }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status, forKey: .status)
        try c.encode(progress, forKey: .progress)
        try c.encode(engine, forKey: .engine)          // null when none
        try c.encode(language, forKey: .language)      // null when none
        try c.encodeIfPresent(error, forKey: .error)   // only when 'failed'
        try c.encodeIfPresent(errorCode, forKey: .errorCode)
        try c.encode(speakers, forKey: .speakers)
        try c.encode(words, forKey: .words)
    }
}

public struct Speaker: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct Word: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    public var speaker: String
    /// `filler?: true` in the contract: written only when true.
    public var filler: Bool
    /// `approximate?: true`: the time was estimated, not measured. Written only when true.
    public var approximate: Bool

    public init(start: Double, end: Double, text: String, speaker: String, filler: Bool = false, approximate: Bool = false) {
        self.start = start; self.end = end; self.text = text; self.speaker = speaker; self.filler = filler
        self.approximate = approximate
    }

    enum CodingKeys: String, CodingKey { case start, end, text, speaker, filler, approximate }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        text = try c.decode(String.self, forKey: .text)
        speaker = try c.decode(String.self, forKey: .speaker)
        filler = try c.decodeIfPresent(Bool.self, forKey: .filler) ?? false
        approximate = try c.decodeIfPresent(Bool.self, forKey: .approximate) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encode(text, forKey: .text)
        try c.encode(speaker, forKey: .speaker)
        if filler { try c.encode(true, forKey: .filler) }
        if approximate { try c.encode(true, forKey: .approximate) }
    }
}

// MARK: - Edits (editor-api.md §3)

public struct Edits: Codable, Sendable, Equatable {
    public var revision: Int
    public var segments: [Segment]
    public init(revision: Int = 0, segments: [Segment] = []) { self.revision = revision; self.segments = segments }
}

/// `rate 0` = cut; any other rate = played at that speed. Rate 1 is never a segment.
public struct Segment: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var rate: Double
    public init(start: Double, end: Double, rate: Double) { self.start = start; self.end = end; self.rate = rate }
}

// MARK: - Export (editor-api.md §6)

public struct ExportJob: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case queued, running, done, failed, canceled }

    public var id: String
    public var status: Status
    public var progress: Double
    public var revision: Int
    public var duration: Double
    public var url: String?
    public var bytes: Int?
    public var error: String?

    public init(id: String, status: Status, progress: Double, revision: Int, duration: Double,
                url: String? = nil, bytes: Int? = nil, error: String? = nil) {
        self.id = id; self.status = status; self.progress = progress; self.revision = revision
        self.duration = duration; self.url = url; self.bytes = bytes; self.error = error
    }

    public var isFinished: Bool { status == .done || status == .failed || status == .canceled }
}

// MARK: - Engines (editor-api.md §5)

public struct Engine: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var local: Bool
    public var available: Bool
    public var why: String?
    /// `default` in the contract: true on exactly one engine of a list.
    public var isDefault: Bool

    public init(id: String, name: String, local: Bool, available: Bool, why: String? = nil, isDefault: Bool = false) {
        self.id = id; self.name = name; self.local = local; self.available = available; self.why = why
        self.isDefault = isDefault
    }

    enum CodingKeys: String, CodingKey { case id, name, local, available, why, isDefault = "default" }

    /// Marks exactly one default: the first available engine, else the first one.
    public static func withDefault(_ engines: [Engine]) -> [Engine] {
        guard !engines.isEmpty else { return [] }
        if engines.filter(\.isDefault).count == 1 { return engines }
        let pick = engines.firstIndex(where: \.available) ?? 0
        return engines.enumerated().map { i, e in var e = e; e.isDefault = i == pick; return e }
    }
}

/// GET /api/settings. Where the Mistral key comes from; never the key itself.
public struct EditorSettings: Codable, Sendable, Equatable {
    public enum KeySource: String, Codable, Sendable { case keychain, environment, none }
    public var mistralKey: KeySource
    public init(mistralKey: KeySource) { self.mistralKey = mistralKey }
}

public struct EngineList: Codable, Sendable, Equatable {
    public var engines: [Engine]
    public init(engines: [Engine]) { self.engines = engines }
}

// MARK: - Small bodies

public struct WaveformPayload: Codable, Sendable, Equatable {
    public var peaksPerSecond: Int
    public var encoding: String
    public var peaks: String
    public init(peaks: Data, peaksPerSecond: Int = 50) {
        self.peaksPerSecond = peaksPerSecond; self.encoding = "uint8-base64"; self.peaks = peaks.base64EncodedString()
    }
}

public struct APIError: Codable, Sendable, Equatable {
    public var error: String
    public var message: String
    public init(_ error: String, _ message: String) { self.error = error; self.message = message }
}

// MARK: - URLs the server derives (never stored)

public enum EditorURLs {
    public static func source(_ id: String) -> String { "/media/\(id)/source" }
    public static func poster(_ id: String) -> String { "/media/\(id)/poster.jpg" }
    public static func waveform(_ id: String) -> String { "/api/projects/\(id)/waveform" }
    public static func exportFile(_ jobID: String) -> String { "/api/exports/\(jobID)/file" }
    public static func edit(_ id: String) -> String { "/edit/\(id)" }
}

// MARK: - The media seam (E1 ↔ E2)

/// What the server needs from the media + transcription track (E2). `EditorService` adapts E2's
/// types (Waveform, Poster, ExportJobs, TranscriptionJobs) to this; tests pass a fake.
public protocol EditorMedia: Sendable {
    /// Peaks, 1 byte per 1/50 s (editor-api.md §4). May take a while on a long recording.
    func waveformPeaks(of source: URL) async throws -> Data
    /// A JPEG frame at 1 s, 1280 px wide at most.
    func posterJPEG(of source: URL) async throws -> Data

    func engines() async -> [Engine]
    /// Queues a transcription; transcript updates come back through `TranscriptSink`.
    /// Throws `EditorError.invalid` for an unknown or unavailable engine.
    func startTranscription(_ request: TranscriptionRequest) async throws -> Transcript

    func startExport(_ request: ExportRequest) async throws -> ExportJob
    func exportJob(id: String) async -> ExportJob?
    func cancelExport(id: String) async -> ExportJob?
    /// The finished file of a job, with the name the download should get.
    func exportFile(id: String) async -> (file: URL, filename: String)?
    func latestExport(projectID: String) async -> ExportJob?

    /// GET /api/settings.
    func settings() async -> EditorSettings
    /// PUT /api/settings/mistral-key: checks the key with Mistral (no audio), stores it in the
    /// Keychain, returns the engines. Throws `.invalidKey` or `.unreachable`.
    func setMistralKey(_ key: String) async throws -> [Engine]
    /// DELETE /api/settings/mistral-key: removes the Keychain item, returns the engines.
    func deleteMistralKey() async -> [Engine]
    /// DELETE /api/projects/:id: stop its jobs before its folder goes.
    func forget(projectID: String) async
}

/// Fakes and builds without the Mistral engine: no key to manage.
extension EditorMedia {
    public func settings() async -> EditorSettings { EditorSettings(mistralKey: .none) }
    public func setMistralKey(_ key: String) async throws -> [Engine] {
        throw EditorError.invalidKey("This build of Bubble has no Mistral engine.")
    }
    public func deleteMistralKey() async -> [Engine] { await engines() }
    public func forget(projectID: String) async {}
}

public struct TranscriptionRequest: Sendable {
    public var projectID: String
    public var source: URL
    public var engine: String?
    /// `Projects/<id>/`: raw answers go to `transcript-raw/<engine>.json` inside it.
    public var folder: URL
    public init(projectID: String, source: URL, engine: String?, folder: URL) {
        self.projectID = projectID; self.source = source; self.engine = engine; self.folder = folder
    }
}

public struct ExportRequest: Sendable {
    public var projectID: String
    public var revision: Int
    public var source: URL
    public var pieces: [EditPlan.Piece]
    /// Seconds of the edited video (`EditPlan.outputDuration`).
    public var duration: Double
    public var title: String
    /// `Projects/<id>/exports/`.
    public var folder: URL
    public init(projectID: String, revision: Int, source: URL, pieces: [EditPlan.Piece], duration: Double,
                title: String, folder: URL) {
        self.projectID = projectID; self.revision = revision; self.source = source; self.pieces = pieces
        self.duration = duration; self.title = title; self.folder = folder
    }
}

/// Errors the routes turn into status codes. `LocalizedError` so the app can show the message.
public enum EditorError: Error, LocalizedError, Equatable {
    case notFound(String)
    case sourceMissing
    case invalid(String)
    case stale(Edits)
    case notReady(String)
    case failed(String)
    /// 422 invalid_key: Mistral refused the key.
    case invalidKey(String)
    /// 502 unreachable: Mistral could not be reached.
    case unreachable(String)
    /// 404 source_offline: the video is on a volume that isn't connected.
    case sourceOffline(volume: String)
    /// 422 unsupported_format / no_video: refused at open (MediaCheck's sentence).
    case refused(code: String, message: String)
    /// 409 busy: a Bubble panel is already up.
    case busy
    /// 501 not_available: this build has no app around the server (headless, tests).
    case notAvailable(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let m), .invalid(let m), .notReady(let m), .failed(let m), .invalidKey(let m), .unreachable(let m),
             .notAvailable(let m): m
        case .sourceMissing: "The video is not where it was. Locate it, or open it again from Bubble."
        case .sourceOffline(let v): "This video is on \"\(v)\", which isn't connected. Connect it to play and download; your edits are kept."
        case .refused(_, let m): m
        case .busy: "The file panel is already open in Bubble."
        case .stale: "Another tab saved first."
        }
    }
}
