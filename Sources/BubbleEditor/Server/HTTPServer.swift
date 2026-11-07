// A small HTTP/1.1 server on Network.framework, loopback only (docs/editor-architecture.md §2).
// Owner: E1. Keep-alive, Content-Length bodies (≤ 1 MB), no chunked encoding; file bodies are
// streamed in 256 KB chunks so a 2 GB recording never sits in memory. What to answer is the
// `Handler`'s job (Router); this file only speaks HTTP.
import Foundation
import Network
import Synchronization

public struct HTTPRequest: Sendable {
    public var method: String
    /// Percent-decoded path, without the query.
    public var path: String
    public var query: [String: String]
    /// Lowercased names.
    public var headers: [String: String]
    public var body: Data
    /// The port the server is bound to (for the Host check).
    public var localPort: UInt16

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:],
                body: Data = Data(), localPort: UInt16 = BubbleEditor.defaultPort) {
        self.method = method; self.path = path; self.query = query
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { $1 })
        self.body = body; self.localPort = localPort
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// Parses a request target ("/a%20b?x=1") into a path and a query.
    static func split(target: String) -> (path: String, query: [String: String])? {
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard let rawPath = parts.first, let path = String(rawPath).removingPercentEncoding, path.hasPrefix("/") else { return nil }
        var query: [String: String] = [:]
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let decode = { (s: Substring) in String(s).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(s) }
                query[decode(kv[0])] = kv.count > 1 ? decode(kv[1]) : ""
            }
        }
        return (path, query)
    }
}

public struct HTTPResponse: Sendable {
    public enum Body: Sendable {
        case data(Data)
        /// `length` bytes of `file` from `offset`, read as they are sent.
        case file(URL, offset: UInt64, length: UInt64)
    }

    public var status: Int
    public var headers: [(String, String)]
    public var body: Body

    public init(status: Int, headers: [(String, String)] = [], body: Body = .data(Data())) {
        self.status = status; self.headers = headers; self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.last { $0.0.lowercased() == name.lowercased() }?.1
    }

    public var bodyLength: UInt64 {
        switch body {
        case .data(let d): UInt64(d.count)
        case .file(_, _, let length): length
        }
    }

    /// The body when it is in memory (tests).
    public var data: Data? { if case .data(let d) = body { d } else { nil } }

    static let reasons: [Int: String] = [
        200: "OK", 202: "Accepted", 204: "No Content", 206: "Partial Content", 302: "Found",
        304: "Not Modified", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
        405: "Method Not Allowed", 409: "Conflict", 413: "Content Too Large", 416: "Range Not Satisfiable",
        422: "Unprocessable Content", 431: "Request Header Fields Too Large", 500: "Internal Server Error",
    ]

    func head(keepAlive: Bool) -> Data {
        var s = "HTTP/1.1 \(status) \(Self.reasons[status] ?? "Status")\r\n"
        for (k, v) in headers where k.lowercased() != "content-length" && k.lowercased() != "connection" {
            s += "\(k): \(v)\r\n"
        }
        s += "Content-Length: \(bodyLength)\r\n"
        s += keepAlive ? "Connection: keep-alive\r\n" : "Connection: close\r\n"
        s += "\r\n"
        return Data(s.utf8)
    }
}

public final class HTTPServer: Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    public static let maxBody = 1 << 20
    static let maxHead = 64 << 10
    static let chunk = 256 << 10

    let handler: Handler
    let queue = DispatchQueue(label: "bubble.editor.http")
    private let state = Mutex<State>(State())

    private struct State {
        var listener: NWListener?
        var port: UInt16?
        var connections: [ObjectIdentifier: NWConnection] = [:]
    }

    public init(handler: @escaping Handler) { self.handler = handler }

    public var port: UInt16? { state.withLock { $0.port } }

    /// Binds 127.0.0.1:`port`, or the next free port up to `port + tries - 1`. `port` 0 = any free
    /// port (tests). Returns the bound port. Idempotent: a running server returns its port.
    public func start(port: UInt16 = BubbleEditor.defaultPort, tries: Int = 20) async throws -> UInt16 {
        if let p = self.port { return p }
        var lastError: Error = EditorError.failed("No free port for the editor.")
        for candidate in 0..<max(1, port == 0 ? 1 : tries) {
            let p = port == 0 ? 0 : port &+ UInt16(candidate)
            do {
                let bound = try await listen(on: p)
                return bound
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func listen(on port: UInt16) async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = false
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }

        let once = Mutex(false)
        let bound: UInt16 = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { s in
                switch s {
                case .ready:
                    if once.withLock({ let was = $0; $0 = true; return !was }) {
                        cont.resume(returning: listener.port?.rawValue ?? port)
                    }
                case .failed(let e), .waiting(let e):
                    if once.withLock({ let was = $0; $0 = true; return !was }) {
                        listener.cancel()
                        cont.resume(throwing: e)
                    }
                case .cancelled:
                    if once.withLock({ let was = $0; $0 = true; return !was }) {
                        cont.resume(throwing: EditorError.failed("The editor server stopped."))
                    }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        state.withLock { $0.listener = listener; $0.port = bound }
        return bound
    }

    /// Closes the listener and every open connection. Safe to call twice, or before start.
    public func stop() {
        let (listener, conns) = state.withLock { s -> (NWListener?, [NWConnection]) in
            defer { s.listener = nil; s.port = nil; s.connections = [:] }
            return (s.listener, Array(s.connections.values))
        }
        listener?.cancel()
        conns.forEach { $0.cancel() }
    }

    private func accept(_ conn: NWConnection) {
        let key = ObjectIdentifier(conn)
        guard let port = state.withLock({ s -> UInt16? in
            guard s.listener != nil else { return nil }
            s.connections[key] = conn
            return s.port
        }) else { conn.cancel(); return }
        let c = HTTPConnection(conn: conn, queue: queue)
        Task {
            await c.serve(port: port, handler: handler)
            conn.cancel()
            _ = self.state.withLock { $0.connections.removeValue(forKey: key) }
        }
    }
}

/// One client. `serve` runs sequentially in one task: the buffer is never shared.
private final class HTTPConnection: @unchecked Sendable {
    let conn: NWConnection
    var buffer = Data()
    var closed = false

    init(conn: NWConnection, queue: DispatchQueue) {
        self.conn = conn
        conn.start(queue: queue)
    }

    func serve(port: UInt16, handler: HTTPServer.Handler) async {
        while !closed {
            let parsed: Parsed
            do { parsed = try await readRequest(port: port) } catch { return }
            switch parsed {
            case .eof: return
            case .bad(let status):
                let r = HTTPResponse(status: status, headers: [("Content-Type", "application/json")],
                                     body: .data(Data(#"{"error":"bad_request","message":"Bad request."}"#.utf8)))
                try? await write(r, method: "GET", keepAlive: false)
                return
            case .request(let req, let keepAlive):
                let res = await handler(req)
                do { try await write(res, method: req.method, keepAlive: keepAlive) } catch { return }
                if !keepAlive { return }
            }
        }
    }

    enum Parsed { case eof, bad(Int), request(HTTPRequest, keepAlive: Bool) }

    private func readRequest(port: UInt16) async throws -> Parsed {
        let separator = Data("\r\n\r\n".utf8)
        var headEnd: Range<Data.Index>?
        while true {
            headEnd = buffer.range(of: separator)
            if headEnd != nil { break }
            if buffer.count > HTTPServer.maxHead { return .bad(431) }
            guard let more = try await receive() else { return buffer.isEmpty ? .eof : .bad(400) }
            buffer.append(more)
        }
        guard let headEnd, let head = String(data: buffer[buffer.startIndex..<headEnd.lowerBound], encoding: .utf8) else { return .bad(400) }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3, let (path, query) = HTTPRequest.split(target: String(first[1])) else { return .bad(400) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        if headers["transfer-encoding"] != nil { return .bad(400) }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .bad(400) }
        if length > HTTPServer.maxBody { return .bad(413) }
        buffer.removeSubrange(buffer.startIndex..<headEnd.upperBound)
        while buffer.count < length {
            guard let more = try await receive() else { return .eof }
            buffer.append(more)
        }
        let body = Data(buffer.prefix(length))
        buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + length)
        buffer = Data(buffer)   // re-base indices at 0
        let version = String(first[2])
        let connection = headers["connection"]?.lowercased() ?? ""
        let keepAlive = version == "HTTP/1.1" ? !connection.contains("close") : connection.contains("keep-alive")
        let req = HTTPRequest(method: String(first[0]).uppercased(), path: path, query: query, headers: headers,
                              body: body, localPort: port)
        return .request(req, keepAlive: keepAlive)
    }

    private func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { data, _, isComplete, error in
                if let data, !data.isEmpty { cont.resume(returning: data) }
                else if let error { cont.resume(throwing: error) }
                else if isComplete { cont.resume(returning: nil) }
                else { cont.resume(returning: Data()) }
            }
        }
    }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    private func write(_ res: HTTPResponse, method: String, keepAlive: Bool) async throws {
        let head = res.head(keepAlive: keepAlive)
        if method == "HEAD" { try await send(head); return }
        switch res.body {
        case .data(let d):
            try await send(head + d)
        case .file(let url, let offset, let length):
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: offset)
            try await send(head)
            var left = length
            while left > 0 {
                let n = Int(min(UInt64(HTTPServer.chunk), left))
                guard let chunk = try handle.read(upToCount: n), !chunk.isEmpty else { closed = true; return }
                try await send(chunk)
                left -= UInt64(chunk.count)
            }
        }
    }
}
