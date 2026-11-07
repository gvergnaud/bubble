// The routes of docs/editor-api.md, exactly (same codes and error shapes as web/mock-server.mjs).
// Owner: E1. Pure dispatch: state lives in ProjectStore (projects) and EditorMedia (E2's jobs).
import Foundation
import Synchronization

public final class Router: Sendable {
    let auth: Auth
    let files: StaticFiles
    let store: ProjectStore
    let media: EditorMedia
    /// Waveforms being computed, by project id (a second request answers 202 without restarting it).
    private let waveformTasks = Mutex<[String: Task<Data, Error>]>([:])
    /// Projects whose auto-transcription is being started (two GETs at once start it once).
    private let autoStarting = Mutex<[String: Task<Transcript?, Never>]>([:])
    /// How long GET /waveform waits for a first computation before answering 202.
    let waveformWait: Duration

    public init(auth: Auth, files: StaticFiles, store: ProjectStore, media: EditorMedia, waveformWait: Duration = .milliseconds(1500)) {
        self.auth = auth; self.files = files; self.store = store; self.media = media; self.waveformWait = waveformWait
    }

    public func handle(_ req: HTTPRequest) async -> HTTPResponse {
        guard auth.hostAllowed(req.header("host"), port: req.localPort) else {
            return Self.error(403, "bad_host", "Wrong Host header.")
        }
        let path = req.path
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)   // ["", "api", ...]

        // Page and assets: public. /edit/:id?t=<token> sets the cookie and redirects.
        if parts.count == 3, parts[1] == "edit", ProjectStore.isValidID(parts[2]) {
            guard req.method == "GET" || req.method == "HEAD" else { return Self.methodNotAllowed }
            if auth.tokenValid(req.query["t"]) {
                return HTTPResponse(status: 302, headers: [("Location", EditorURLs.edit(parts[2])), ("Set-Cookie", auth.setCookie),
                                                           ("Cache-Control", "no-store")])
            }
            return files.page(req)
        }
        if path.hasPrefix("/editor/") {
            guard req.method == "GET" || req.method == "HEAD" else { return Self.methodNotAllowed }
            return files.asset(req)
        }

        // Everything else needs the cookie.
        guard auth.cookieValid(req.header("cookie")) else { return Self.error(401, "unauthorized", "Open this page from Bubble.") }

        do {
            return try await route(req, parts)
        } catch let e as EditorError {
            return Self.response(for: e)
        } catch {
            return Self.error(500, "failed", "The editor server failed: \(error.localizedDescription)")
        }
    }

    private func route(_ req: HTTPRequest, _ p: [String]) async throws -> HTTPResponse {
        let m = req.method
        switch (p.count, p.count > 1 ? p[1] : "") {
        case (3, "api") where p[2] == "engines":
            guard m == "GET" else { return Self.methodNotAllowed }
            return Self.json(200, EngineList(engines: Engine.withDefault(await media.engines())))

        // The Mistral key goes page → server only: never in an answer, never logged.
        case (3, "api") where p[2] == "settings":
            guard m == "GET" else { return Self.methodNotAllowed }
            return Self.json(200, await media.settings())

        case (4, "api") where p[2] == "settings" && p[3] == "mistral-key":
            switch m {
            case "PUT":
                guard let key = (Self.object(req.body)?["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
                    throw EditorError.invalid("Needs { key }.")
                }
                return Self.json(200, EngineList(engines: Engine.withDefault(try await media.setMistralKey(key))))
            case "DELETE":
                return Self.json(200, EngineList(engines: Engine.withDefault(await media.deleteMistralKey())))
            default:
                return Self.methodNotAllowed
            }

        case (4, "media"):
            guard m == "GET" || m == "HEAD" else { return Self.methodNotAllowed }
            let id = p[2]
            switch p[3] {
            case "source":
                let url = try await store.source(id)
                return StaticFiles.file(url, req, type: "video/mp4", headers: [("Cache-Control", "no-cache")])
            case "poster.jpg":
                return StaticFiles.file(try await poster(id), req, type: "image/jpeg", headers: [("Cache-Control", "no-cache")])
            default: return Self.noRoute
            }

        case (4, "api") where p[2] == "exports", (5, "api") where p[2] == "exports" && p[4] == "file":
            let jobID = p[3]
            guard let job = await media.exportJob(id: jobID) else { throw EditorError.notFound("No such export.") }
            if p.count == 5 {
                guard m == "GET" || m == "HEAD" else { return Self.methodNotAllowed }
                guard job.status == .done, let (file, name) = await media.exportFile(id: jobID) else {
                    return Self.error(409, "not_ready", "The export is not finished.")
                }
                return StaticFiles.file(file, req, type: "video/mp4", headers: [("Content-Disposition", Self.attachment(name)),
                                                                                ("Cache-Control", "no-store")])
            }
            switch m {
            case "GET": return Self.json(200, job)
            case "DELETE": return Self.json(200, await media.cancelExport(id: jobID) ?? job)
            default: return Self.methodNotAllowed
            }

        case (4, "api") where p[2] == "projects", (5, "api") where p[2] == "projects":
            return try await project(req, id: p[3], sub: p.count == 5 ? p[4] : "")

        default:
            return Self.noRoute
        }
    }

    private func project(_ req: HTTPRequest, id: String, sub: String) async throws -> HTTPResponse {
        let stored = try await store.project(id)
        switch (sub, req.method) {
        case ("", "GET"):
            var stored = stored
            if stored.transcript.status == .none, let t = await autoTranscribe(id) { stored.transcript = t }
            return Self.json(200, stored.api(export: await media.latestExport(projectID: id)))

        case ("", "PATCH"):
            guard let body = Self.object(req.body) else { throw EditorError.invalid("Body is not JSON.") }
            let title = body["title"] as? String
            let speakers = (body["speakers"] as? [Any])?.compactMap { item -> Speaker? in
                guard let d = item as? [String: Any], let sid = d["id"] as? String, let name = d["name"] as? String else { return nil }
                return Speaker(id: sid, name: name)
            }
            let p = try await store.update(id, title: title, speakers: speakers)
            return Self.json(200, p.api(export: await media.latestExport(projectID: id)))

        case ("edits", "PUT"):
            guard let body = Self.object(req.body), let revision = Self.integer(body["revision"]) else {
                throw EditorError.invalid("Needs { revision, segments }.")
            }
            // Stale wins over invalid (the mock's order): the page must first take the other tab's edits.
            if revision != stored.edits.revision { throw EditorError.stale(stored.edits) }
            let segments = try Self.segments(body["segments"])
            let new = try await store.saveEdits(id, revision: revision, segments: segments)
            return Self.json(200, ["revision": new])

        case ("waveform", "GET"):
            return try await waveform(id)

        case ("transcription", "POST"):
            let body = Self.object(req.body) ?? [:]
            let engine = body["engine"] as? String
            let source = try await store.source(id)
            let t = try await media.startTranscription(TranscriptionRequest(projectID: id, source: source, engine: engine,
                                                                            folder: store.folder(id)))
            try await store.setTranscript(id, t)
            return Self.json(202, ["transcript": t])

        case ("export", "POST"):
            let source = try await store.source(id)
            let pieces = EditPlan.pieces(duration: stored.video.duration, segments: stored.edits.segments)
            let duration = (EditPlan.outputDuration(duration: stored.video.duration, segments: stored.edits.segments) * 1000).rounded() / 1000
            let job = try await media.startExport(ExportRequest(projectID: id, revision: stored.edits.revision, source: source,
                                                                pieces: pieces, duration: duration, title: stored.title,
                                                                folder: store.folder(id).appendingPathComponent("exports", isDirectory: true)))
            return Self.json(202, job)

        case ("", _), ("edits", _), ("waveform", _), ("transcription", _), ("export", _):
            return Self.methodNotAllowed
        default:
            return Self.noRoute
        }
    }

    // MARK: auto-transcription (editor-api.md §5: no Transcribe button)

    /// Opening a project with no transcript starts one with the default engine. Returns the
    /// transcript to answer with: queued, or failed with a sentence when no engine can run. nil:
    /// nothing started (the recording is missing). Requests that arrive while one is starting it
    /// wait for that same start and answer the same transcript.
    private func autoTranscribe(_ id: String) async -> Transcript? {
        let task = autoStarting.withLock { tasks -> Task<Transcript?, Never> in
            if let t = tasks[id] { return t }
            let t = Task { await self.startAutoTranscription(id) }
            tasks[id] = t
            return t
        }
        let transcript = await task.value
        autoStarting.withLock { if $0[id] == task { $0[id] = nil } }
        return transcript
    }

    private func startAutoTranscription(_ id: String) async -> Transcript? {
        // Re-read: a request that just finished may have started it.
        guard let p = try? await store.project(id) else { return nil }
        if p.transcript.status != .none { return p.transcript }
        guard let source = try? await store.source(id) else { return nil }
        var t: Transcript
        do {
            t = try await media.startTranscription(TranscriptionRequest(projectID: id, source: source, engine: nil, folder: store.folder(id)))
        } catch {
            t = Transcript(status: .failed, error: (error as? LocalizedError)?.errorDescription ?? "The transcription could not start.")
        }
        // The job's own updates may already be ahead (a fast engine): keep the newest.
        if let now = try? await store.project(id), now.transcript.status != .none { return now.transcript }
        try? await store.setTranscript(id, t)
        return t
    }

    // MARK: waveform + poster (cached in the project folder)

    private func waveform(_ id: String) async throws -> HTTPResponse {
        let cache = store.folder(id).appendingPathComponent("waveform.bin")
        if let data = try? Data(contentsOf: cache) { return Self.json(200, WaveformPayload(peaks: data)) }
        let source = try await store.source(id)
        let task = waveformTasks.withLock { tasks -> Task<Data, Error> in
            if let t = tasks[id] { return t }
            let media = self.media
            let t = Task<Data, Error> {
                let peaks = try await media.waveformPeaks(of: source)
                try peaks.write(to: cache, options: .atomic)
                return peaks
            }
            tasks[id] = t
            return t
        }
        // Short recordings: answer at once. Long ones: 202 and the page retries.
        let ready = await withTaskGroup(of: Bool.self) { g -> Bool in
            g.addTask { _ = try? await task.value; return true }
            g.addTask { [waveformWait] in try? await Task.sleep(for: waveformWait); return false }
            let first = await g.next() ?? false
            g.cancelAll()
            return first
        }
        if ready {
            waveformTasks.withLock { _ = $0.removeValue(forKey: id) }
            do { return Self.json(200, WaveformPayload(peaks: try await task.value)) }
            catch { throw EditorError.failed("Could not read the recording's audio: \(error.localizedDescription)") }
        }
        return Self.json(202, ["status": "pending"])
    }

    private func poster(_ id: String) async throws -> URL {
        let file = store.folder(id).appendingPathComponent("poster.jpg")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        let source = try await store.source(id)
        let jpeg = try await media.posterJPEG(of: source)
        try jpeg.write(to: file, options: .atomic)
        return file
    }

    // MARK: bodies

    static func object(_ body: Data) -> [String: Any]? {
        if body.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    static func integer(_ v: Any?) -> Int? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d == d.rounded() && abs(d) < 1e15 ? Int(d) : nil
    }

    static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    /// Same messages as the mock's `validate` for the shape errors; the rules are EditPlan's.
    static func segments(_ v: Any?) throws -> [Segment] {
        guard let list = v as? [Any] else { throw EditorError.invalid("segments must be an array") }
        return try list.enumerated().map { i, item in
            guard let d = item as? [String: Any], let s = number(d["start"]), let e = number(d["end"]), let r = number(d["rate"]) else {
                throw EditorError.invalid("segment \(i): start, end, rate must be numbers")
            }
            return Segment(start: s, end: e, rate: r)
        }
    }

    // MARK: responses

    static func json<T: Encodable>(_ status: Int, _ value: T) -> HTTPResponse {
        let data = (try? OrderedJSON.encode(value)) ?? Data(#"{"error":"failed","message":"Could not encode the answer."}"#.utf8)
        return HTTPResponse(status: status, headers: [("Content-Type", "application/json"), ("Cache-Control", "no-store")], body: .data(data))
    }

    public static func error(_ status: Int, _ code: String, _ message: String) -> HTTPResponse {
        json(status, APIError(code, message))
    }

    static var noRoute: HTTPResponse { error(404, "not_found", "No such route.") }
    static var methodNotAllowed: HTTPResponse { error(405, "method_not_allowed", "This route does not take that method.") }

    static func response(for e: EditorError) -> HTTPResponse {
        switch e {
        case .notFound(let m): error(404, "not_found", m)
        case .sourceMissing: error(404, "source_missing", e.errorDescription ?? "")
        case .invalid(let m): error(422, "invalid", m)
        case .stale(let edits): json(409, StaleBody(error: "stale", edits: edits))
        case .notReady(let m): error(409, "not_ready", m)
        case .failed(let m): error(500, "failed", m)
        case .invalidKey(let m): error(422, "invalid_key", m)
        case .unreachable(let m): error(502, "unreachable", m)
        }
    }

    struct StaleBody: Encodable { var error: String; var edits: Edits }

    /// `attachment; filename="<ascii>"; filename*=UTF-8''<utf8>` (titles can hold anything).
    static func attachment(_ name: String) -> String {
        let ascii = String(name.unicodeScalars.map { $0.isASCII && $0 != "\"" && $0 != "\\" && $0.value >= 0x20 ? Character($0) : "_" })
        let utf8 = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ascii
        return "attachment; filename=\"\(ascii)\"; filename*=UTF-8''\(utf8)"
    }
}
