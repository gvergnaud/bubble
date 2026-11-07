// Owner: E2 (media). docs/editor-architecture.md §4, docs/editor-api.md §6: the export queue. One render
// at a time, cancellable, progress for the page's polling. A project's new export replaces its previous
// one (canceled if still running, file deleted); files older than 24 h are swept at each start.
import Foundation

/// What docs/editor-api.md's `ExportJob` is made from (editor-server maps it; `url` is its route).
public struct ExportJobState: Sendable, Equatable {
    public enum Status: String, Sendable, Codable { case queued, running, done, failed, canceled }

    public var id: String
    public var projectID: String
    public var status: Status
    public var progress: Double
    /// The edits revision it renders.
    public var revision: Int
    /// Seconds of the edited video (known before rendering).
    public var duration: Double
    /// The finished file (only when `.done`).
    public var file: URL?
    public var bytes: Int64?
    public var error: String?
    /// For Content-Disposition: "<title> (edited).mp4".
    public var filename: String
    public var createdAt: Date
}

public actor ExportJobs {
    public typealias Renderer = @Sendable (_ source: URL, _ pieces: [MediaPiece], _ destination: URL,
                                           _ progress: @escaping @Sendable (Double) -> Void) async throws -> ExportResult

    /// Finished exports older than this are deleted at the next start.
    public static let keepFor: TimeInterval = 24 * 3600

    private struct Entry {
        var state: ExportJobState
        let source: URL
        let pieces: [MediaPiece]
        let folder: URL
        var task: Task<Void, Never>?
    }

    private let render: Renderer
    private let now: @Sendable () -> Date
    private var entries: [String: Entry] = [:]
    private var queue: [String] = []
    private var running: String?

    public init(render: @escaping Renderer = { try await Exporter.render(source: $0, pieces: $1, to: $2, progress: $3) },
                now: @escaping @Sendable () -> Date = Date.init) {
        self.render = render
        self.now = now
    }

    /// Queues an export of `pieces` of `source` into `folder` (Projects/<id>/exports/), file `<jobId>.mp4`.
    public func start(projectID: String, revision: Int, source: URL, pieces: [MediaPiece], title: String, folder: URL) -> ExportJobState {
        for (id, e) in entries where e.state.projectID == projectID {
            if e.state.status == .queued || e.state.status == .running { cancel(id) }
            if let file = e.state.file { try? FileManager.default.removeItem(at: file) }
            entries[id]?.state.file = nil
        }
        sweep(folder)
        let id = UUID().uuidString.lowercased()
        let state = ExportJobState(id: id, projectID: projectID, status: .queued, progress: 0, revision: revision,
                                   duration: Exporter.outputDuration(pieces), file: nil, bytes: nil, error: nil,
                                   filename: Self.filename(title: title), createdAt: now())
        entries[id] = Entry(state: state, source: source, pieces: pieces, folder: folder)
        queue.append(id)
        startNext()
        return state
    }

    /// At launch (no render runs yet): deletes render work folders left by a crash in every
    /// `Projects/<id>/exports/`, and exports older than `keepFor`.
    public static func sweepLeftovers(projectsFolder: URL, now: Date = Date()) {
        let fm = FileManager.default
        for dir in (try? fm.contentsOfDirectory(at: projectsFolder, includingPropertiesForKeys: nil)) ?? [] {
            let exports = dir.appendingPathComponent("exports", isDirectory: true)
            for f in (try? fm.contentsOfDirectory(at: exports, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                let name = f.lastPathComponent
                let modified = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if (name.hasPrefix(".") && name.hasSuffix(".partial")) || (f.pathExtension == "mp4" && now.timeIntervalSince(modified) > keepFor) {
                    try? fm.removeItem(at: f)
                }
            }
        }
    }

    public func job(_ id: String) -> ExportJobState? { entries[id]?.state }

    public func latest(projectID: String) -> ExportJobState? {
        entries.values.map(\.state).filter { $0.projectID == projectID }.max { $0.createdAt < $1.createdAt }
    }

    /// Cancels a queued or running job (no-op once it is finished). Returns its state.
    @discardableResult
    public func cancel(_ id: String) -> ExportJobState? {
        guard var e = entries[id] else { return nil }
        switch e.state.status {
        case .queued:
            queue.removeAll { $0 == id }
            e.state.status = .canceled
            entries[id] = e
        case .running:
            e.state.status = .canceled
            entries[id] = e
            e.task?.cancel()   // the render deletes its partial file; finished() keeps .canceled
        case .done, .failed, .canceled:
            break
        }
        return entries[id]?.state
    }

    /// Waits until a job is over and its render has cleaned up (tests, and the app at quit).
    public func wait(_ id: String) async -> ExportJobState? {
        while let e = entries[id], e.task != nil || e.state.status == .queued || e.state.status == .running {
            if let task = e.task { await task.value } else { try? await Task.sleep(for: .milliseconds(20)) }
        }
        return entries[id]?.state
    }

    /// "<title> (edited).mp4", without characters a file name cannot hold.
    public static func filename(title: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:\"\n\r\t").union(.controlCharacters)
        var clean = String(String.UnicodeScalarView(title.unicodeScalars.filter { !bad.contains($0) }))
            .trimmingCharacters(in: .whitespaces)
        if clean.hasPrefix(".") { clean = String(clean.drop { $0 == "." }) }
        if clean.isEmpty { clean = "Recording" }
        return "\(clean) (edited).mp4"
    }

    // MARK: - Private

    private func startNext() {
        guard running == nil, !queue.isEmpty else { return }
        let id = queue.removeFirst()
        guard var e = entries[id], e.state.status == .queued else { return startNext() }
        running = id
        e.state.status = .running
        let destination = e.folder.appendingPathComponent("\(id).mp4")
        let render = self.render, source = e.source, pieces = e.pieces
        let jobs = self
        e.task = Task {
            let result: Result<ExportResult, Error>
            do {
                result = .success(try await render(source, pieces, destination) { p in
                    Task { await jobs.setProgress(id, p) }
                })
            } catch { result = .failure(error) }
            await jobs.finished(id, result, destination)
        }
        entries[id] = e
    }

    private func setProgress(_ id: String, _ p: Double) {
        guard entries[id]?.state.status == .running else { return }
        let current = entries[id]?.state.progress ?? 0   // read first: one access to `entries` at a time
        entries[id]?.state.progress = max(current, min(1, p))
    }

    private func finished(_ id: String, _ result: Result<ExportResult, Error>, _ destination: URL) {
        if running == id { running = nil }
        if var e = entries[id] {
            e.task = nil
            switch result {
            case .success(let r) where e.state.status == .canceled:
                _ = r
                try? FileManager.default.removeItem(at: destination)
            case .success(let r):
                e.state.status = .done
                e.state.progress = 1
                e.state.file = destination
                e.state.bytes = r.bytes
                e.state.duration = r.duration
            case .failure where e.state.status == .canceled || Task.isCancelled:
                e.state.status = .canceled
            case .failure(let error):
                if error is CancellationError { e.state.status = .canceled } else {
                    e.state.status = .failed
                    e.state.error = (error as? Exporter.Failure)?.description ?? "The export failed (\(error.localizedDescription))."
                }
            }
            entries[id] = e
        }
        startNext()
    }

    /// Deletes exports in `folder` older than `keepFor`, and work folders of renders not running (a crash).
    private func sweep(_ folder: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let runningWork = running.map { Exporter.partialFolder(for: folder.appendingPathComponent("\($0).mp4")).lastPathComponent }
        for f in files {
            let name = f.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".partial") {
                if name != runningWork { try? fm.removeItem(at: f) }
            } else if f.pathExtension == "mp4" {
                let modified = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if now().timeIntervalSince(modified) > Self.keepFor { try? fm.removeItem(at: f) }
            }
        }
    }
}
