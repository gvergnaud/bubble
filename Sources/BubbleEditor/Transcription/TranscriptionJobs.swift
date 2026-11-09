// Owner: E2 (transcription). docs/editor-architecture.md §5: the transcription queue. One job at a time:
// AudioExtract → engine → Words.post → onUpdate (editor-server stores it with ProjectStore.setTranscript).
// The engine's raw answer is kept in <project>/transcript-raw/<engine>.json.
import AVFoundation
import Foundation

/// What docs/editor-api.md's `Transcript` is made from (editor-server maps it).
public struct TranscriptionState: Sendable, Equatable {
    public enum Status: String, Sendable, Codable { case none, queued, running, ready, failed }

    public var status: Status
    public var progress: Double
    public var engine: String?
    public var language: String?
    /// A sentence for the user, when `.failed`.
    public var error: String?
    /// A failure the page treats on its own (no Retry, no engine switch): `no_sound`.
    public var errorCode: String?
    public var speakers: [TranscriptSpeaker]
    public var words: [TranscriptWord]

    public init(status: Status, progress: Double = 0, engine: String? = nil, language: String? = nil, error: String? = nil,
                errorCode: String? = nil, speakers: [TranscriptSpeaker] = [], words: [TranscriptWord] = []) {
        self.status = status; self.progress = progress; self.engine = engine; self.language = language
        self.error = error; self.errorCode = errorCode; self.speakers = speakers; self.words = words
    }

    /// `errorCode` of a source without a sound track (docs/editor-open-video.md §4).
    public static let noSound = "no_sound"

    /// Status `.none` (no transcript). Not named `none`: `states[id] = .none` would delete the entry.
    public static let empty = TranscriptionState(status: .none)
}

public actor TranscriptionJobs {
    public typealias OnUpdate = @Sendable (_ projectID: String, _ state: TranscriptionState) async -> Void

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unknownEngine(String)
        case unavailable(engine: String, why: String)
        case noEngine

        public var description: String {
            switch self {
            case .unknownEngine(let id): "Unknown transcription engine \"\(id)\"."
            case .unavailable(let id, let why): "\(id) is not available: \(why)"
            case .noEngine: "No transcription engine is available."
            }
        }
    }

    private struct Job {
        let projectID: String
        let source: URL
        let engine: any Transcriber
        let folder: URL
        let language: String?
        let duration: Double?
    }

    private let transcribers: [any Transcriber]
    private let onUpdate: OnUpdate
    private var states: [String: TranscriptionState] = [:]
    private var queue: [Job] = []
    private var running: (projectID: String, task: Task<Void, Never>)?
    private var lastSent: [String: Double] = [:]

    /// `engines` in the order the page lists them; the first available one is the default.
    public init(engines: [any Transcriber], onUpdate: @escaping OnUpdate = { _, _ in }) {
        self.transcribers = engines
        self.onUpdate = onUpdate
    }

    public func engines() async -> [EngineInfo] {
        var out: [EngineInfo] = []
        for t in transcribers {
            let a = await t.availability()
            out.append(EngineInfo(id: t.id, name: t.name, local: t.isLocal, available: a.isAvailable, why: a.why))
        }
        return out
    }

    /// Queues (or restarts) the transcription of `source`. `engine` nil = the first available one.
    /// Throws `Failure` for an unknown or unavailable engine (→ 422). `folder` = Projects/<id>/.
    /// `duration`: the source's, to clamp word times (optional).
    public func start(projectID: String, source: URL, engine: String? = nil, folder: URL,
                      language: String? = nil, duration: Double? = nil) async throws -> TranscriptionState {
        let chosen = try await pick(engine)
        cancel(projectID: projectID, notify: false)
        // No sound track: failed at once (milliseconds), never queued behind other videos' jobs.
        if await Self.hasNoSound(source) {
            let failed = TranscriptionState(status: .failed, engine: chosen.id, error: AudioExtract.Failure.noAudio.description,
                                            errorCode: TranscriptionState.noSound)
            states[projectID] = failed
            await onUpdate(projectID, failed)
            return failed
        }
        let state = TranscriptionState(status: .queued, engine: chosen.id)
        states[projectID] = state
        queue.append(Job(projectID: projectID, source: source, engine: chosen, folder: folder, language: language, duration: duration))
        await onUpdate(projectID, state)
        startNext()
        return state
    }

    /// A readable file without a sound track it can decode (a missing or unreadable one is the job's to
    /// report).
    static func hasNoSound(_ source: URL) async -> Bool {
        let asset = AVURLAsset(url: source)
        guard FileManager.default.fileExists(atPath: source.path),
              let tracks = try? await asset.load(.tracks), !tracks.isEmpty else { return false }
        return await MediaCheck.soundTracks(of: asset).isEmpty
    }

    /// Name of the extracted audio in a project folder while a job runs (deleted on every exit).
    public static let workAudioName = "transcribe-audio.wav"

    /// At launch (no job runs yet): deletes extracted audio left by a crash in every `Projects/<id>/`.
    public static func sweepLeftovers(projectsFolder: URL) {
        let fm = FileManager.default
        for dir in (try? fm.contentsOfDirectory(at: projectsFolder, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: dir.appendingPathComponent(workAudioName))
        }
    }

    /// The live state of a project's job (nil when none ran since launch: use the stored transcript).
    public func state(projectID: String) -> TranscriptionState? { states[projectID] }

    /// Stops a queued or running job; its state goes back to `.none`.
    public func cancel(projectID: String) {
        cancel(projectID: projectID, notify: true)
    }

    /// Waits until the project's job is no longer queued or running (tests).
    public func wait(projectID: String) async -> TranscriptionState? {
        while let s = states[projectID], s.status == .queued || s.status == .running {
            if let r = running, r.projectID == projectID { await r.task.value } else { try? await Task.sleep(for: .milliseconds(20)) }
        }
        return states[projectID]
    }

    // MARK: - Private

    private func pick(_ id: String?) async throws -> any Transcriber {
        if let id {
            guard let t = transcribers.first(where: { $0.id == id }) else { throw Failure.unknownEngine(id) }
            if case .unavailable(let why) = await t.availability() { throw Failure.unavailable(engine: t.name, why: why) }
            return t
        }
        for t in transcribers where await t.availability().isAvailable { return t }
        throw Failure.noEngine
    }

    private func cancel(projectID: String, notify: Bool) {
        let wasQueued = queue.contains { $0.projectID == projectID }
        queue.removeAll { $0.projectID == projectID }
        var wasRunning = false
        if let r = running, r.projectID == projectID {
            r.task.cancel(); running = nil; wasRunning = true
        }
        if (wasQueued || wasRunning) && notify {
            states[projectID] = TranscriptionState.empty
            Task { await onUpdate(projectID, TranscriptionState.empty) }
        }
        if wasRunning { startNext() }
    }

    private func startNext() {
        guard running == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(job)
        }
        running = (job.projectID, task)
    }

    private func run(_ job: Job) async {
        let pid = job.projectID, engineID = job.engine.id
        await update(pid, TranscriptionState(status: .running, progress: 0, engine: engineID))
        let audio = job.folder.appendingPathComponent(Self.workAudioName)
        defer { try? FileManager.default.removeItem(at: audio) }
        do {
            try await AudioExtract.wav(from: job.source, to: audio)
            try Task.checkCancellation()
            await update(pid, TranscriptionState(status: .running, progress: 0.05, engine: engineID))
            let result = try await job.engine.transcribe(audio: audio, language: job.language) { [weak self] p in
                Task { await self?.progress(pid, engine: engineID, 0.05 + 0.9 * min(1, max(0, p))) }
            }
            try Task.checkCancellation()
            if let raw = result.raw { saveRaw(raw, engine: engineID, folder: job.folder) }
            let posted = Words.post(result, duration: job.duration)
            await finish(pid, TranscriptionState(status: .ready, progress: 1, engine: engineID, language: result.language,
                                                 speakers: posted.speakers, words: posted.words))
        } catch is CancellationError {
            // cancel() already set the state.
        } catch {
            if Task.isCancelled { return }
            let code = (error as? AudioExtract.Failure) == .noAudio ? TranscriptionState.noSound : nil
            await finish(pid, TranscriptionState(status: .failed, engine: engineID, error: Self.message(for: error), errorCode: code))
        }
    }

    private func progress(_ pid: String, engine: String, _ p: Double) async {
        guard let s = states[pid], s.status == .running, s.engine == engine, p > s.progress else { return }
        states[pid]?.progress = p
        if p - (lastSent[pid] ?? 0) >= 0.01 { await update(pid, states[pid]!) }
    }

    private func update(_ pid: String, _ state: TranscriptionState) async {
        guard running?.projectID == pid, !Task.isCancelled else { return }
        states[pid] = state
        lastSent[pid] = state.progress
        await onUpdate(pid, state)
    }

    private func finish(_ pid: String, _ state: TranscriptionState) async {
        guard running?.projectID == pid, !Task.isCancelled else { return }
        states[pid] = state
        lastSent[pid] = nil
        running = nil
        await onUpdate(pid, state)
        startNext()
    }

    private func saveRaw(_ raw: Data, engine: String, folder: URL) {
        let dir = folder.appendingPathComponent("transcript-raw", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = engine.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
        try? raw.write(to: dir.appendingPathComponent("\(safe.isEmpty ? "engine" : safe).json"), options: .atomic)
    }

    /// A sentence for the user: ours as written, an engine's `LocalizedError.errorDescription`, else generic.
    static func message(for error: Error) -> String {
        let text: String? = switch error {
        case let e as AudioExtract.Failure: e.description
        case let e as Failure: e.description
        case let e as LocalizedError: e.errorDescription
        default: nil
        }
        let t = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? "The transcription failed (\(error.localizedDescription))." : t
    }
}
