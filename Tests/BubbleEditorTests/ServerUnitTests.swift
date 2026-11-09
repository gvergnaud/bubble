// Owner: E1 (editor-server), with qa's OK. Unit tests of the server pieces: EditPlan, Range, Auth,
// RecordingIndex, and the server over a real loopback socket on a temp Application Support folder
// with the fixture as the recording. The full API contract is qa's (ContractTests + web/test/contract.mjs).
@testable import BubbleEditor
import Foundation
import Testing

private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let fixtureVideo = repo.appendingPathComponent("web/fixtures/demo.mp4")

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("bubble-editor-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@Suite struct EditPlanTests {
    let segs = [Segment(start: 8.025, end: 8.221, rate: 0), Segment(start: 16.913, end: 19.76, rate: 0), Segment(start: 43.05, end: 52.067, rate: 1.5)]

    @Test func fixtureEditsAreValid() { #expect(EditPlan.validate(segs, duration: 68.638) == nil) }

    @Test func piecesSkipCutsAndKeepRates() {
        let p = EditPlan.pieces(duration: 68.638, segments: segs)
        #expect(p.map(\.rate) == [1, 1, 1, 1.5, 1])
        #expect(p.first == .init(start: 0, end: 8.025, rate: 1))
        #expect(p.last == .init(start: 52.067, end: 68.638, rate: 1))
        let expected = 68.638 - 0.196 - 2.847 - (9.017 - 9.017 / 1.5)
        #expect(abs(EditPlan.outputDuration(duration: 68.638, segments: segs) - expected) < 1e-9)
    }

    @Test func outputTime() {
        #expect(EditPlan.outputTime(forSource: 5, duration: 68.638, segments: segs) == 5)
        #expect(abs(EditPlan.outputTime(forSource: 8.1, duration: 68.638, segments: segs) - 8.025) < 1e-9)   // inside a cut
        #expect(abs(EditPlan.outputTime(forSource: 68.638, duration: 68.638, segments: segs)
                    - EditPlan.outputDuration(duration: 68.638, segments: segs)) < 1e-9)
    }

    @Test func emptyIsOnePiece() {
        #expect(EditPlan.pieces(duration: 10, segments: []) == [.init(start: 0, end: 10, rate: 1)])
    }

    @Test func invalid() {
        #expect(EditPlan.validate([.init(start: 2, end: 1, rate: 0)], duration: 10) != nil)
        #expect(EditPlan.validate([.init(start: 0, end: 2, rate: 0), .init(start: 1, end: 3, rate: 2)], duration: 10) != nil)
        #expect(EditPlan.validate([.init(start: 0, end: 2, rate: 1)], duration: 10) != nil)
        #expect(EditPlan.validate([.init(start: 0, end: 2, rate: 5)], duration: 10) != nil)
        #expect(EditPlan.validate([.init(start: 0, end: 0.01, rate: 0)], duration: 10) != nil)
        #expect(EditPlan.validate([.init(start: 0, end: 11, rate: 0)], duration: 10) != nil)
        #expect(EditPlan.validate([.init(start: 0, end: 10.0005, rate: 0)], duration: 10) == nil)
    }

    /// qa's golden cases, when they exist (web/fixtures/edits-cases.json): only the valid/invalid verdict here.
    @Test func goldenCasesVerdicts() throws {
        let file = repo.appendingPathComponent("web/fixtures/edits-cases.json")
        guard let data = try? Data(contentsOf: file),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cases = root["cases"] as? [[String: Any]] else { return }
        let duration = (root["duration"] as? Double) ?? 68.638
        for c in cases {
            guard let raw = c["segments"] as? [[String: Any]], let valid = c["valid"] as? Bool,
                  let segs = try? Router.segments(raw) else { continue }
            let d = (c["duration"] as? Double) ?? duration
            #expect((EditPlan.validate(segs, duration: d) == nil) == valid, "\(c["name"] ?? "?")")
        }
    }
}

@Suite struct RangeAndAuthTests {
    @Test func ranges() {
        #expect(StaticFiles.byteRange(nil, size: 1000) == .none)
        #expect(StaticFiles.byteRange("bytes=0-99", size: 1000) == .range(0, 99))
        #expect(StaticFiles.byteRange("bytes=900-", size: 1000) == .range(900, 999))
        #expect(StaticFiles.byteRange("bytes=-100", size: 1000) == .range(900, 999))
        #expect(StaticFiles.byteRange("bytes=-5000", size: 1000) == .range(0, 999))
        #expect(StaticFiles.byteRange("bytes=0-5000", size: 1000) == .range(0, 999))
        #expect(StaticFiles.byteRange("bytes=1000-", size: 1000) == .unsatisfiable)
        #expect(StaticFiles.byteRange("bytes=5-2", size: 1000) == .unsatisfiable)
        #expect(StaticFiles.byteRange("bytes=0-1,5-6", size: 1000) == .none)
        #expect(StaticFiles.byteRange("items=0-1", size: 1000) == .none)
    }

    @Test func tokenFileIsStableAndPrivate() throws {
        let dir = try tempDir()
        let a = try Auth.load(appSupport: dir), b = try Auth.load(appSupport: dir)
        #expect(a.token == b.token && a.token.count == 64)
        let mode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("editor-token").path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }

    @Test func hostAndCookie() {
        let auth = Auth(token: "abc")
        #expect(auth.hostAllowed("127.0.0.1:47621", port: 47621))
        #expect(auth.hostAllowed("LOCALHOST:47621", port: 47621))
        #expect(!auth.hostAllowed("evil.com:47621", port: 47621))
        #expect(!auth.hostAllowed("127.0.0.1:1", port: 47621))
        #expect(!auth.hostAllowed(nil, port: 47621))
        #expect(auth.cookieValid("x=1; bubble=abc"))
        #expect(!auth.cookieValid("bubble=abd"))
        #expect(!auth.cookieValid(nil))
    }

    @Test func pathsStayInTheRoot() throws {
        let files = StaticFiles(root: repo.appendingPathComponent("web/editor"))
        #expect(files.resolve("../mock-server.mjs") == nil)
        #expect(files.resolve("a/../../x") == nil)
        #expect(files.resolve(".hidden") == nil)
        #expect(files.resolve("index.html") != nil)
    }

    @Test func attachmentName() {
        #expect(Router.attachment("Démo \"1\" (edited).mp4") == #"attachment; filename="D_mo _1_ (edited).mp4"; filename*=UTF-8''D%C3%A9mo%20%221%22%20%28edited%29.mp4"#)
    }
}

/// Over a real socket: start, auth, project, edits, Range, waveform. No browser, nothing on screen.
@Suite(.serialized) struct LiveServerTests {
    struct Client {
        let base: String
        var cookie: String?
        let session: URLSession = {
            let c = URLSessionConfiguration.ephemeral
            c.httpShouldSetCookies = false
            c.httpCookieAcceptPolicy = .never
            return URLSession(configuration: c, delegate: NoRedirect(), delegateQueue: nil)
        }()

        func call(_ method: String, _ path: String, body: Any? = nil, headers: [String: String] = [:]) async throws -> (Int, Data, HTTPURLResponse) {
            var r = URLRequest(url: URL(string: base + path)!)
            r.httpMethod = method
            if let cookie { r.setValue("bubble=\(cookie)", forHTTPHeaderField: "Cookie") }
            for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
            if let body { r.httpBody = try JSONSerialization.data(withJSONObject: body); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let (data, res) = try await session.data(for: r)
            let http = res as! HTTPURLResponse
            return (http.statusCode, data, http)
        }
    }

    final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    @Test func endToEnd() async throws {
        let dir = try tempDir()
        let rec = dir.appendingPathComponent("My demo.mp4")
        try FileManager.default.copyItem(at: fixtureVideo, to: rec)
        let before = try Data(contentsOf: rec)
        let svc = EditorService(appSupport: dir, webRoot: repo.appendingPathComponent("web/editor"), port: 0, recordingsFolder: { dir })
        defer { svc.stop() }
        let edit = try await svc.editURL(for: rec)
        let port = try #require(svc.port)
        let comps = try #require(URLComponents(url: edit, resolvingAgainstBaseURL: false))
        let id = String(comps.path.dropFirst("/edit/".count))
        let token = try #require(comps.queryItems?.first { $0.name == "t" }?.value)
        #expect(try await svc.editURL(for: rec) == edit, "same project on a second open")

        var c = Client(base: "http://127.0.0.1:\(port)")
        // Auth.
        var (code, _, res) = try await c.call("GET", "/edit/\(id)?t=\(token)")
        #expect(code == 302)
        #expect(res.value(forHTTPHeaderField: "Location") == "/edit/\(id)")
        #expect(res.value(forHTTPHeaderField: "Set-Cookie")?.contains("HttpOnly; SameSite=Strict") == true)
        (code, _, _) = try await c.call("GET", "/api/projects/\(id)")
        #expect(code == 401)
        (code, _, _) = try await c.call("GET", "/edit/\(id)")
        #expect(code == 200, "the page is public")
        c.cookie = token
        (code, _, _) = try await c.call("GET", "/api/projects/\(id)", headers: ["Host": "evil.example:\(port)"])
        #expect(code == 403)

        // Project.
        var data: Data
        (code, data, _) = try await c.call("GET", "/api/projects/\(id)")
        #expect(code == 200)
        let p = try JSONDecoder().decode(Project.self, from: data)
        #expect(p.title == "My demo" && p.video.width == 1280 && p.video.height == 720 && abs(p.video.duration - 68.6) < 0.2)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(obj["export"] is NSNull)
        #expect((obj["transcript"] as! [String: Any])["engine"] is NSNull)
        (code, _, _) = try await c.call("GET", "/api/projects/nope")
        #expect(code == 404)

        // Edits.
        let segs: [[String: Any]] = [["start": 1, "end": 2, "rate": 0], ["start": 10, "end": 20, "rate": 1.5]]
        (code, data, _) = try await c.call("PUT", "/api/projects/\(id)/edits", body: ["revision": 0, "segments": segs])
        #expect(code == 200 && String(decoding: data, as: UTF8.self) == #"{"revision":1}"#)
        (code, data, _) = try await c.call("PUT", "/api/projects/\(id)/edits", body: ["revision": 0, "segments": []])
        #expect(code == 409)
        let stale = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(stale["error"] as? String == "stale")
        (code, _, _) = try await c.call("PUT", "/api/projects/\(id)/edits", body: ["revision": 1, "segments": [["start": 2, "end": 1, "rate": 0]]])
        #expect(code == 422)
        (code, data, _) = try await c.call("PATCH", "/api/projects/\(id)", body: ["title": "  Renamed "])
        let renamed = try JSONDecoder().decode(Project.self, from: data)
        #expect(code == 200 && renamed.title == "Renamed")

        // Persisted: a fresh store reads the same project.
        let again = try await ProjectStore(appSupport: dir).project(id)
        #expect(again.edits.revision == 1 && again.title == "Renamed")

        // Range on the source.
        let size = before.count
        (code, data, res) = try await c.call("GET", "/media/\(id)/source", headers: ["Range": "bytes=0-99"])
        #expect(code == 206 && data.count == 100 && res.value(forHTTPHeaderField: "Content-Range") == "bytes 0-99/\(size)")
        (code, data, _) = try await c.call("GET", "/media/\(id)/source", headers: ["Range": "bytes=-500"])
        #expect(code == 206 && data == before.suffix(500))
        (code, _, res) = try await c.call("GET", "/media/\(id)/source", headers: ["Range": "bytes=\(size)-"])
        #expect(code == 416 && res.value(forHTTPHeaderField: "Content-Range") == "bytes */\(size)")
        (code, data, _) = try await c.call("GET", "/media/\(id)/source")
        #expect(code == 200 && data == before)

        // Static files.
        (code, _, _) = try await c.call("GET", "/editor/app.js")
        #expect(code == 200)
        (code, _, _) = try await c.call("GET", "/editor/..%2Fmock-server.mjs")
        #expect(code == 404)

        // Waveform + poster (E2's code, through the server).
        var waveform: [String: Any] = [:]
        for _ in 0..<20 {
            (code, data, _) = try await c.call("GET", "/api/projects/\(id)/waveform")
            if code == 200 { waveform = try JSONSerialization.jsonObject(with: data) as! [String: Any]; break }
            #expect(code == 202)
            try await Task.sleep(for: .milliseconds(500))
        }
        #expect(waveform["peaksPerSecond"] as? Int == 50)
        let peaks = Data(base64Encoded: waveform["peaks"] as? String ?? "") ?? Data()
        #expect(abs(peaks.count - Int(p.video.duration * 50)) <= 2)
        (code, data, res) = try await c.call("GET", "/media/\(id)/poster.jpg")
        #expect(code == 200 && data.starts(with: [0xFF, 0xD8]) && res.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")

        // Engines: none configured → 422 on transcription.
        (code, data, _) = try await c.call("GET", "/api/engines")
        #expect(code == 200 && String(decoding: data, as: UTF8.self) == #"{"engines":[]}"#)
        (code, _, _) = try await c.call("POST", "/api/projects/\(id)/transcription", body: [:])
        #expect(code == 422)

        // The recording was only read.
        #expect(try Data(contentsOf: rec) == before)
        #expect(RecordingIndex.readXattr(rec) == id)
    }

    @Test func transcriptionAndExport() async throws {
        let dir = try tempDir()
        let rec = dir.appendingPathComponent("demo.mp4")
        try FileManager.default.copyItem(at: fixtureVideo, to: rec)
        let svc = EditorService(appSupport: dir, webRoot: nil, port: 0,
                                transcribers: [FixtureTranscriber(wordsFile: repo.appendingPathComponent("web/fixtures/demo.project.json"))])
        defer { svc.stop() }
        let edit = try await svc.editURL(for: rec)
        let comps = try #require(URLComponents(url: edit, resolvingAgainstBaseURL: false))
        let id = String(comps.path.dropFirst("/edit/".count))
        let c = Client(base: "http://127.0.0.1:\(try #require(svc.port))", cookie: comps.queryItems?.first { $0.name == "t" }?.value)

        var (code, data, res) = try await c.call("POST", "/api/projects/\(id)/transcription", body: ["engine": "fixture"])
        #expect(code == 202)
        let queued = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect((queued["transcript"] as? [String: Any])?["status"] as? String == "queued")
        var project: Project?
        for _ in 0..<50 {
            (code, data, _) = try await c.call("GET", "/api/projects/\(id)")
            project = try JSONDecoder().decode(Project.self, from: data)
            if project?.transcript.status == .ready || project?.transcript.status == .failed { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(project?.transcript.status == .ready)
        #expect((project?.transcript.words.count ?? 0) > 50)
        (code, _, _) = try await c.call("POST", "/api/projects/\(id)/transcription", body: ["engine": "nope"])
        #expect(code == 422)

        (code, _, _) = try await c.call("PUT", "/api/projects/\(id)/edits", body: ["revision": 0, "segments": [["start": 5, "end": 60, "rate": 0]]])
        #expect(code == 200)
        (code, data, _) = try await c.call("POST", "/api/projects/\(id)/export", body: [:])
        #expect(code == 202)
        var job = try JSONDecoder().decode(ExportJob.self, from: data)
        #expect(job.revision == 1 && abs(job.duration - (68.638 - 55)) < 0.1)
        (code, _, _) = try await c.call("GET", "/api/exports/\(job.id)/file")
        #expect(code == 409 || job.status == .done)
        for _ in 0..<120 where !job.isFinished {
            try await Task.sleep(for: .milliseconds(250))
            (code, data, _) = try await c.call("GET", "/api/exports/\(job.id)")
            job = try JSONDecoder().decode(ExportJob.self, from: data)
        }
        #expect(job.status == .done && job.url == "/api/exports/\(job.id)/file")
        (code, data, res) = try await c.call("GET", job.url ?? "/")
        #expect(code == 200 && data.count == job.bytes)
        #expect(res.value(forHTTPHeaderField: "Content-Disposition")?.contains(#"filename="demo (edited).mp4""#) == true)
        (code, data, _) = try await c.call("GET", "/api/projects/\(id)")
        #expect(try JSONDecoder().decode(Project.self, from: data).export?.id == job.id)
        (code, _, _) = try await c.call("GET", "/api/exports/nope")
        #expect(code == 404)
    }
}

/// Engines, settings and the Mistral key routes, in-process (no socket), on a fake media.
@Suite struct SettingsRoutesTests {
    actor FakeMedia: EditorMedia {
        var key: String?
        func waveformPeaks(of source: URL) async throws -> Data { Data() }
        func posterJPEG(of source: URL) async throws -> Data { Data() }
        func engines() async -> [Engine] {
            [Engine(id: "voxtral-mini-transcribe-3", name: "Voxtral 3 (Mistral API)", local: false, available: key != nil,
                    why: key == nil ? "Add your Mistral API key." : nil),
             Engine(id: "apple-local", name: "On this Mac", local: true, available: true)]
        }
        func startTranscription(_ request: TranscriptionRequest) async throws -> Transcript { .none }
        func startExport(_ request: ExportRequest) async throws -> ExportJob { throw EditorError.failed("no") }
        func exportJob(id: String) async -> ExportJob? { nil }
        func cancelExport(id: String) async -> ExportJob? { nil }
        func exportFile(id: String) async -> (file: URL, filename: String)? { nil }
        func latestExport(projectID: String) async -> ExportJob? { nil }
        func settings() async -> EditorSettings { EditorSettings(mistralKey: key == nil ? .none : .keychain) }
        func setMistralKey(_ key: String) async throws -> [Engine] {
            if key == "offline" { throw EditorError.unreachable("Mistral can't be reached.") }
            guard key == "good" else { throw EditorError.invalidKey("Mistral refused this key.") }
            self.key = key
            return await engines()
        }
        func deleteMistralKey() async -> [Engine] { key = nil; return await engines() }
    }

    func call(_ router: Router, _ method: String, _ path: String, _ body: String = "") async -> (Int, String) {
        let r = await router.handle(HTTPRequest(method: method, path: path,
                                                headers: ["Host": "127.0.0.1:47621", "Cookie": "bubble=tok"], body: Data(body.utf8)))
        return (r.status, String(decoding: r.data ?? Data(), as: UTF8.self))
    }

    @Test func keyLifecycle() async throws {
        let router = Router(auth: Auth(token: "tok"), files: StaticFiles(root: nil),
                            store: ProjectStore(appSupport: try tempDir()), media: FakeMedia())
        var (code, body) = await call(router, "GET", "/api/engines")
        #expect(code == 200)
        #expect(body.contains(#""id":"apple-local","name":"On this Mac","local":true,"available":true,"default":true"#))
        #expect(body.contains(#""available":false,"why":"Add your Mistral API key.","default":false"#))
        (code, body) = await call(router, "GET", "/api/settings")
        #expect(code == 200 && body == #"{"mistralKey":"none"}"#)
        (code, body) = await call(router, "PUT", "/api/settings/mistral-key", #"{"key":"bad"}"#)
        #expect(code == 422 && body.contains(#""error":"invalid_key""#) && !body.contains("bad"))
        (code, _) = await call(router, "PUT", "/api/settings/mistral-key", #"{"key":"offline"}"#)
        #expect(code == 502)
        (code, _) = await call(router, "PUT", "/api/settings/mistral-key", "{}")
        #expect(code == 422)
        (code, body) = await call(router, "PUT", "/api/settings/mistral-key", #"{"key":" good "}"#)
        #expect(code == 200 && !body.contains("good"))
        #expect(body.contains(#""id":"voxtral-mini-transcribe-3","name":"Voxtral 3 (Mistral API)","local":false,"available":true,"default":true"#))
        (code, body) = await call(router, "GET", "/api/settings")
        #expect(body == #"{"mistralKey":"keychain"}"#)
        (code, body) = await call(router, "DELETE", "/api/settings/mistral-key")
        #expect(code == 200 && body.contains(#""id":"apple-local","name":"On this Mac","local":true,"available":true,"default":true"#))
        (code, _) = await call(router, "POST", "/api/settings")
        #expect(code == 405)
        let r = await router.handle(HTTPRequest(method: "GET", path: "/api/settings", headers: ["Host": "127.0.0.1:47621"]))
        #expect(r.status == 401)
    }

    @Test func exactlyOneDefault() {
        let a = Engine(id: "a", name: "A", local: false, available: false), b = Engine(id: "b", name: "B", local: true, available: false)
        #expect(Engine.withDefault([a, b]).map(\.isDefault) == [true, false])
        var c = b; c.available = true
        #expect(Engine.withDefault([a, c]).map(\.isDefault) == [false, true])
        #expect(Engine.withDefault([]).isEmpty)
    }

    @Test func orderedJSON() throws {
        let w = Word(start: 1, end: 1.5, text: "a \"b\"\n", speaker: "S1", filler: true, approximate: true)
        #expect(String(decoding: try OrderedJSON.encode(w), as: UTF8.self)
                == #"{"start":1,"end":1.5,"text":"a \"b\"\n","speaker":"S1","filler":true,"approximate":true}"#)
        #expect(String(decoding: try OrderedJSON.encode(Word(start: 0.25, end: 2, text: "x", speaker: "S1")), as: UTF8.self)
                == #"{"start":0.25,"end":2,"text":"x","speaker":"S1"}"#)
    }
}

/// editor-api.md §5: opening a project with no transcript starts one (no Transcribe button).
@Suite struct AutoTranscriptionTests {
    func open(transcribers: [any Transcriber]) async throws -> (EditorService, LiveServerTests.Client, String) {
        let dir = try tempDir()
        let rec = dir.appendingPathComponent("demo.mp4")
        try FileManager.default.copyItem(at: fixtureVideo, to: rec)
        let svc = EditorService(appSupport: dir, webRoot: nil, port: 0, transcribers: transcribers)
        let comps = try #require(URLComponents(url: try await svc.editURL(for: rec), resolvingAgainstBaseURL: false))
        let c = LiveServerTests.Client(base: "http://127.0.0.1:\(try #require(svc.port))", cookie: comps.queryItems?.first { $0.name == "t" }?.value)
        return (svc, c, String(comps.path.dropFirst("/edit/".count)))
    }

    @Test func firstOpenStartsTheDefaultEngine() async throws {
        let fixture = FixtureTranscriber(wordsFile: repo.appendingPathComponent("web/fixtures/demo.project.json"), delay: .milliseconds(300))
        let (svc, c, id) = try await open(transcribers: [fixture])
        defer { svc.stop() }
        // Two pages open at once: one job, both answers say it started.
        async let a = c.call("GET", "/api/projects/\(id)")
        async let b = c.call("GET", "/api/projects/\(id)")
        for (code, data, _) in [try await a, try await b] {
            #expect(code == 200)
            let t = try JSONDecoder().decode(Project.self, from: data).transcript
            #expect([.queued, .running, .ready].contains(t.status) && t.engine == "fixture", "\(t.status)")
        }
        var t = Transcript.none
        for _ in 0..<50 {
            let (_, data, _) = try await c.call("GET", "/api/projects/\(id)")
            t = try JSONDecoder().decode(Project.self, from: data).transcript
            if t.status == .ready { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(t.status == .ready && t.words.count > 50)
    }

    @Test func noEngineFailsOnceAndStays() async throws {
        let (svc, c, id) = try await open(transcribers: [])
        defer { svc.stop() }
        for _ in 0..<2 {
            let (code, data, _) = try await c.call("GET", "/api/projects/\(id)")
            let t = try JSONDecoder().decode(Project.self, from: data).transcript
            #expect(code == 200 && t.status == .failed && (t.error ?? "").count > 5)
        }
    }
}

/// Opening any video (editor-api.md §8): page panel, drop, identity, list, delete. Real copies of
/// the fixture in temp folders; the panel and Spotlight are fakes.
@Suite(.serialized) struct OpenAnyVideoTests {
    final class Calls: @unchecked Sendable {
        let lock = NSLock()
        var opened: [URL] = []
        var fronted = 0
        func add(_ u: URL) { lock.withLock { opened.append(u) } }
        func front() { lock.withLock { fronted += 1 } }
    }

    struct Rig {
        let svc: EditorService
        let c: LiveServerTests.Client
        let dir: URL, movies: URL, elsewhere: URL
        let calls: Calls
    }

    /// `pick`: what the fake panel returns (after `delay`).
    func rig(pick: URL? = nil, delay: Duration = .zero, found: [URL] = []) async throws -> Rig {
        let dir = try tempDir()
        let movies = dir.appendingPathComponent("Movies/Bubble"), elsewhere = dir.appendingPathComponent("Desktop")
        try FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let calls = Calls()
        let svc = EditorService(appSupport: dir.appendingPathComponent("Support"), webRoot: nil, port: 0,
                                recordingsFolder: { movies },
                                pickVideo: { _ in try? await Task.sleep(for: delay); return pick },
                                bringPanelToFront: { calls.front() },
                                onOpened: { calls.add($0) },
                                findFiles: { _, _ in found })
        let port = try await svc.start()
        let token = try Auth.load(appSupport: dir.appendingPathComponent("Support")).token
        return Rig(svc: svc, c: LiveServerTests.Client(base: "http://127.0.0.1:\(port)", cookie: token),
                   dir: dir, movies: movies, elsewhere: elsewhere, calls: calls)
    }

    func json(_ d: Data) throws -> [String: Any] { try JSONSerialization.jsonObject(with: d) as! [String: Any] }

    func poll(_ c: LiveServerTests.Client, _ openID: String) async throws -> [String: Any] {
        for _ in 0..<100 {
            let (_, d, _) = try await c.call("GET", "/api/open/\(openID)")
            let s = try json(d)
            if s["state"] as? String != "pending" { return s }
            try await Task.sleep(for: .milliseconds(50))
        }
        return [:]
    }

    @Test func openVideoFromThePageNeverTouchesAForeignFile() async throws {
        let dir = try tempDir()
        let video = dir.appendingPathComponent("Interview raw.mov")
        try FileManager.default.copyItem(at: fixtureVideo, to: video)
        let before = try Data(contentsOf: video)
        let r = try await rig(pick: video)
        defer { r.svc.stop() }
        var (code, data, _) = try await r.c.call("POST", "/api/open")
        #expect(code == 202)
        let state = try await poll(r.c, try json(data)["openId"] as! String)
        #expect(state["state"] as? String == "opened")
        let id = try #require(state["projectId"] as? String)
        #expect(RecordingIndex.readXattr(video) == nil, "no xattr outside the recordings folder")
        #expect(try Data(contentsOf: video) == before)
        #expect(r.calls.opened.map(\.lastPathComponent) == ["Interview raw.mov"])
        (code, data, _) = try await r.c.call("GET", "/api/projects/\(id)")
        let source = try json(data)["source"] as! [String: Any]
        #expect(source["name"] as? String == "Interview raw.mov" && source["state"] as? String == "ok")
        var res: HTTPURLResponse
        (code, _, res) = try await r.c.call("GET", "/media/\(id)/source", headers: ["Range": "bytes=0-9"])
        #expect(code == 206 && res.value(forHTTPHeaderField: "Content-Type") == "video/quicktime")
        // Same file again (Dock, Open With): same project.
        #expect(try await r.svc.projectID(for: video) == id)
    }

    @Test func aSecondOpenWhileThePanelIsUpIsBusy() async throws {
        let r = try await rig(pick: nil, delay: .milliseconds(400))
        defer { r.svc.stop() }
        let (code1, d1, _) = try await r.c.call("POST", "/api/open")
        let (code2, d2, _) = try await r.c.call("POST", "/api/open")
        let busy = try json(d2)
        #expect(code1 == 202 && code2 == 409 && busy["error"] as? String == "busy")
        #expect(r.calls.fronted == 1)
        #expect(try await poll(r.c, try json(d1)["openId"] as! String)["state"] as? String == "canceled")
        let (code3, _, _) = try await r.c.call("GET", "/api/open/nope")
        #expect(code3 == 404)
    }

    @Test func noPanelInThisBuildIs501() async throws {
        let dir = try tempDir()
        let svc = EditorService(appSupport: dir, webRoot: nil, port: 0)
        defer { svc.stop() }
        let port = try await svc.start()
        let c = LiveServerTests.Client(base: "http://127.0.0.1:\(port)", cookie: try Auth.load(appSupport: dir).token)
        #expect(try await c.call("POST", "/api/open").0 == 501)
    }

    @Test func dropFindsTheFileByItsBytes() async throws {
        let dir = try tempDir()
        let video = dir.appendingPathComponent("clip.mp4")
        try FileManager.default.copyItem(at: fixtureVideo, to: video)
        let other = dir.appendingPathComponent("sub/clip.mp4")   // same name and size, other bytes
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        var bytes = try Data(contentsOf: fixtureVideo); bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: other)
        let r = try await rig(found: [other, video])
        defer { r.svc.stop() }
        let (size, head, tail) = try VideoFingerprint.hashes(of: video)
        let body: [String: Any] = ["name": "clip.mp4", "size": size, "lastModified": 0, "head": head, "tail": tail]
        var (code, data, _) = try await r.c.call("POST", "/api/open/dropped", body: body)
        #expect(code == 200)
        let id = try #require(try json(data)["projectId"] as? String)
        #expect(try await r.svc.projectID(for: video) == id)
        var wrong = body; wrong["head"] = String(repeating: "0", count: 64)
        (code, data, _) = try await r.c.call("POST", "/api/open/dropped", body: wrong)
        let notFound = try json(data)
        #expect(code == 404 && notFound["error"] as? String == "not_found")
        wrong["head"] = "../etc/passwd"
        #expect(try await r.c.call("POST", "/api/open/dropped", body: wrong).0 == 422)
    }

    @Test func identityFollowsMovesAndSplitsCopies() async throws {
        let r = try await rig()
        defer { r.svc.stop() }
        // A Bubble recording: xattr. Its Finder duplicate carries the xattr but is another project.
        let rec = r.movies.appendingPathComponent("Bubble take.mp4")
        try FileManager.default.copyItem(at: fixtureVideo, to: rec)
        let id = try await r.svc.projectID(for: rec)
        #expect(RecordingIndex.readXattr(rec) == id)
        let dup = r.movies.appendingPathComponent("Bubble take copy.mp4")
        try FileManager.default.copyItem(at: rec, to: dup)
        #expect(RecordingIndex.readXattr(dup) == id)
        let dupID = try await r.svc.projectID(for: dup)
        #expect(dupID != id)
        // Renamed in place: the bookmark (or the xattr) finds it.
        let renamed = r.movies.appendingPathComponent("Renamed.mp4")
        try FileManager.default.moveItem(at: rec, to: renamed)
        #expect(try await r.svc.projectID(for: renamed) == id)
        // A foreign file moved to "another drive" (copied, original deleted): the fingerprint.
        let foreign = r.elsewhere.appendingPathComponent("talk.mp4")
        try FileManager.default.copyItem(at: fixtureVideo, to: foreign)
        let fid = try await r.svc.projectID(for: foreign)
        let moved = r.dir.appendingPathComponent("talk.mp4")
        try FileManager.default.copyItem(at: foreign, to: moved)
        // While the original exists, the copy is another project...
        let copyID = try await r.svc.projectID(for: moved)
        #expect(copyID != fid)
        // ...and when a file is copied then its original deleted, the fingerprint relinks it.
        let away = r.dir.appendingPathComponent("away/talk.mp4")
        try FileManager.default.createDirectory(at: away.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: foreign, to: away)
        try FileManager.default.removeItem(at: foreign)
        let (_, d, _) = try await r.c.call("GET", "/api/projects/\(fid)")
        let gone = try json(d)
        #expect((gone["source"] as? [String: Any])?["state"] as? String == "missing")
        // Two projects share those bytes now (fid gone, copyID at `moved`): fid is the one whose file is gone.
        #expect(try await r.svc.projectID(for: away) == fid)
        #expect(RecordingIndex.readXattr(away) == nil)
    }

    @Test func listAndForget() async throws {
        let r = try await rig()
        defer { r.svc.stop() }
        let v = r.elsewhere.appendingPathComponent("a.mp4")
        try FileManager.default.copyItem(at: fixtureVideo, to: v)
        let id = try await r.svc.projectID(for: v)
        var (code, data, _) = try await r.c.call("GET", "/api/projects")
        let list = try #require(try json(data)["projects"] as? [[String: Any]])
        #expect(code == 200 && list.count == 1 && list[0]["id"] as? String == id)
        #expect((list[0]["file"] as? [String: Any])?["folder"] as? String != nil)
        (code, _, _) = try await r.c.call("DELETE", "/api/projects/\(id)")
        #expect(code == 204 && FileManager.default.fileExists(atPath: v.path))
        (code, _, _) = try await r.c.call("GET", "/api/projects/\(id)")
        #expect(code == 404)
        (code, data, _) = try await r.c.call("GET", "/api/projects")
        let empty = try json(data)
        #expect((empty["projects"] as? [Any])?.isEmpty == true)
    }

    @Test func refusesWhatItCannotEdit() async throws {
        let r = try await rig()
        defer { r.svc.stop() }
        let mkv = r.elsewhere.appendingPathComponent("x.mkv")
        try FileManager.default.copyItem(at: fixtureVideo, to: mkv)
        await #expect(throws: EditorError.refused(code: "unsupported_format",
                                                  message: "Bubble can't open .mkv files. It edits MP4, MOV and M4V videos. Convert it to MP4 first.")) {
            _ = try await r.svc.editURL(for: mkv)
        }
    }

    @Test func accentedNamesMatchInBothUnicodeForms() async throws {
        let nfc = "R\u{E9}sum\u{E9}.mov", nfd = "Re\u{301}sume\u{301}.mov"
        let q = Spotlight.query(name: nfc, size: 5)
        #expect(q.contains("\"\(nfc)\"") && q.contains("\"\(nfd)\"") && q.hasSuffix(" && kMDItemFSSize == 5"))
        #expect(Spotlight.query(name: "plain.mp4", size: 5) == #"kMDItemFSName == "plain.mp4" && kMDItemFSSize == 5"#)
        // On disk in NFD (as a Finder copy may be), dropped from the browser in NFC.
        let dir = try tempDir()
        let video = dir.appendingPathComponent(nfd)
        try FileManager.default.copyItem(at: fixtureVideo, to: video)
        let r = try await rig(found: [video])
        defer { r.svc.stop() }
        let (size, head, tail) = try VideoFingerprint.hashes(of: video)
        let (code, data, _) = try await r.c.call("POST", "/api/open/dropped",
                                                 body: ["name": nfc, "size": size, "lastModified": 0, "head": head, "tail": tail])
        #expect(code == 200 && (try? json(data))?["projectId"] is String)
    }

    @Test func spotlightQueryIsEscaped() {
        #expect(Spotlight.query(name: #"a "b" \c*.mp4"#, size: 12) == #"kMDItemFSName == "a \"b\" \\c\*.mp4" && kMDItemFSSize == 12"#)
    }
}
