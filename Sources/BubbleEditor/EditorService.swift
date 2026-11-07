// The editor, as the app sees it (docs/editor-architecture.md §2, §7). Owner: E1.
// The app (BubbleUI, through a closure wired in main.swift) calls `editURL(for:)` and opens the URL
// with NSWorkspace; `stop()` at quit. The server starts lazily on the first `editURL`.
import Foundation
import os
import Synchronization

public final class EditorService: Sendable {
    static let log = Logger(subsystem: "local.bubble.Bubble", category: "Editor")
    public let appSupport: URL
    public let store: ProjectStore
    let webRoot: URL?
    let preferredPort: UInt16
    let media: EditorMedia
    private let lifecycle = Lifecycle()

    /// - appSupport: `~/Library/Application Support/Bubble` (a temp folder in tests).
    /// - webRoot: the page's files (`Bubble.app/Contents/Resources/editor`, or the repo's `web/editor` in debug).
    /// - port: 47621 by default (the next free one if taken); 0 = any free port (tests).
    /// - transcribers: the engines, in the order the page lists them (the first available is the default).
    /// - media: replaces E2's media + jobs (tests).
    public init(appSupport: URL, webRoot: URL?, port: UInt16 = BubbleEditor.defaultPort,
                transcribers: [any Transcriber] = [], mistralKey: MistralKey? = nil, probe: VideoProbe = AVVideoProbe(), media: EditorMedia? = nil) {
        self.appSupport = appSupport
        self.webRoot = webRoot
        self.preferredPort = port
        let store = ProjectStore(appSupport: appSupport, probe: probe)
        self.store = store
        self.media = media ?? LiveMedia(store: store, transcribers: transcribers, mistralKey: mistralKey)
    }

    /// Starts the server if it is not running (idempotent, safe to call concurrently). Returns the port.
    @discardableResult
    public func start() async throws -> UInt16 {
        try await lifecycle.start { [self] in
            let auth = try Auth.load(appSupport: appSupport)
            // Crash leftovers (work audio, half renders, exports older than 24 h), before any job runs.
            TranscriptionJobs.sweepLeftovers(projectsFolder: store.projectsFolder)
            ExportJobs.sweepLeftovers(projectsFolder: store.projectsFolder)
            let router = Router(auth: auth, files: StaticFiles(root: webRoot), store: store, media: media)
            let server = HTTPServer(handler: { await router.handle($0) })
            let port = try await server.start(port: preferredPort)
            if preferredPort != 0, port != preferredPort {
                // The cookie is per host:port: a tab bookmarked on the usual port won't connect this time.
                Self.log.notice("editor: port \(self.preferredPort, privacy: .public) is taken, serving on \(port, privacy: .public)")
            }
            return (server, auth, port)
        }
    }

    /// `http://127.0.0.1:<port>/edit/<id>?t=<token>`: starts the server, finds or creates the
    /// recording's project. Throws a LocalizedError with a short message.
    public func editURL(for recording: URL) async throws -> URL {
        let port = try await start()
        let project = try await store.open(recording: recording)
        guard let token = lifecycle.token,
              let url = URL(string: "http://127.0.0.1:\(port)\(EditorURLs.edit(project.id))?t=\(token)") else {
            throw EditorError.failed("The editor did not start.")
        }
        return url
    }

    /// The project id of a recording (created on first call). For tests and the app's own lookups.
    public func projectID(for recording: URL) async throws -> String { try await store.open(recording: recording).id }

    /// The running server's port, nil when stopped.
    public var port: UInt16? { lifecycle.port }

    /// Stops the server (at quit). Safe if never started; a later `editURL` starts it again.
    public func stop() { lifecycle.stop() }
}

/// Start once, even when several callers race; stop from any thread.
private final class Lifecycle: Sendable {
    typealias Started = (server: HTTPServer, auth: Auth, port: UInt16)
    private struct State { var starting: Task<Started, Error>?; var running: Started? }
    private let state = Mutex(State())

    var port: UInt16? { state.withLock { $0.running?.port } }
    var token: String? { state.withLock { $0.running?.auth.token } }

    func start(_ make: @escaping @Sendable () async throws -> Started) async throws -> UInt16 {
        let task = state.withLock { s -> Task<Started, Error> in
            if let t = s.starting { return t }
            let t = Task { try await make() }
            s.starting = t
            return t
        }
        do {
            let started = try await task.value
            let ok = state.withLock { s -> Bool in
                guard s.starting == task else { return false }   // stopped meanwhile
                s.running = started
                return true
            }
            guard ok else { started.server.stop(); throw EditorError.failed("The editor server was stopped.") }
            return started.port
        } catch {
            state.withLock { if $0.starting == task { $0.starting = nil } }
            throw error
        }
    }

    func stop() {
        let (running, starting) = state.withLock { s in
            defer { s.running = nil; s.starting = nil }
            return (s.running, s.starting)
        }
        running?.server.stop()
        starting?.cancel()
    }
}

/// E2's media and jobs behind the server's seam (`EditorMedia`).
final class LiveMedia: EditorMedia {
    let exports = ExportJobs()
    let transcription: TranscriptionJobs
    /// nil: no Mistral engine in this build (the settings routes answer 'none' / 422).
    let mistralKey: MistralKey?

    init(store: ProjectStore, transcribers: [any Transcriber], mistralKey: MistralKey?) {
        self.mistralKey = mistralKey
        transcription = TranscriptionJobs(engines: transcribers, onUpdate: { id, state in
            try? await store.setTranscript(id, Self.transcript(state))
        })
    }

    func waveformPeaks(of source: URL) async throws -> Data { try await Waveform.peaks(of: source) }
    func posterJPEG(of source: URL) async throws -> Data { try await Poster.jpeg(of: source) }

    func engines() async -> [Engine] {
        await transcription.engines().map { Engine(id: $0.id, name: $0.name, local: $0.local, available: $0.available, why: $0.why) }
    }

    func startTranscription(_ r: TranscriptionRequest) async throws -> Transcript {
        do {
            return Self.transcript(try await transcription.start(projectID: r.projectID, source: r.source, engine: r.engine, folder: r.folder))
        } catch let f as TranscriptionJobs.Failure {
            throw EditorError.invalid(f.description)
        }
    }

    func startExport(_ r: ExportRequest) async throws -> ExportJob {
        Self.job(await exports.start(projectID: r.projectID, revision: r.revision, source: r.source,
                                     pieces: r.pieces.map { MediaPiece(start: $0.start, end: $0.end, rate: $0.rate) },
                                     title: r.title, folder: r.folder))
    }

    func exportJob(id: String) async -> ExportJob? { await exports.job(id).map(Self.job) }
    func cancelExport(id: String) async -> ExportJob? { await exports.cancel(id).map(Self.job) }
    func latestExport(projectID: String) async -> ExportJob? { await exports.latest(projectID: projectID).map(Self.job) }

    func settings() async -> EditorSettings {
        EditorSettings(mistralKey: EditorSettings.KeySource(rawValue: mistralKey?.source.rawValue ?? "none") ?? .none)
    }

    func setMistralKey(_ key: String) async throws -> [Engine] {
        guard let mistralKey else { throw EditorError.invalidKey("This build of Bubble has no Mistral engine.") }
        do { try await mistralKey.save(key) } catch {
            switch error {
            case .invalid: throw EditorError.invalidKey(error.description)
            case .unreachable: throw EditorError.unreachable(error.description)
            case .store: throw EditorError.failed(error.description)
            }
        }
        return await engines()
    }

    func deleteMistralKey() async -> [Engine] {
        try? mistralKey?.delete()
        return await engines()
    }

    func exportFile(id: String) async -> (file: URL, filename: String)? {
        guard let s = await exports.job(id), s.status == .done, let file = s.file else { return nil }
        return (file, s.filename)
    }

    static func job(_ s: ExportJobState) -> ExportJob {
        ExportJob(id: s.id, status: ExportJob.Status(rawValue: s.status.rawValue) ?? .failed, progress: s.progress,
                  revision: s.revision, duration: (s.duration * 1000).rounded() / 1000,
                  url: s.status == .done ? EditorURLs.exportFile(s.id) : nil,
                  bytes: s.bytes.map { Int($0) }, error: s.error)
    }

    static func transcript(_ s: TranscriptionState) -> Transcript {
        Transcript(status: Transcript.Status(rawValue: s.status.rawValue) ?? .failed, progress: s.progress, engine: s.engine,
                   language: s.language, error: s.error,
                   speakers: s.speakers.map { Speaker(id: $0.id, name: $0.name) },
                   words: s.words.map { Word(start: $0.start, end: $0.end, text: $0.text, speaker: $0.speaker, filler: $0.filler,
                                              approximate: $0.approximate) })
    }
}
