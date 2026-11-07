// Static files and file bodies (docs/editor-architecture.md §2). Owner: E1.
// `/edit/:id` → `<webRoot>/index.html`, `/editor/*` → `<webRoot>/*` (the bundle's
// Resources/editor/, or the repo's web/editor/ in debug). Paths are normalized and must stay in
// the root. Any file body honours `Range` (bytes=a-b, a-, -n → 206; out of bounds → 416).
import Foundation

public struct StaticFiles: Sendable {
    /// nil: no page bundled (a placeholder page says so).
    public let root: URL?

    public init(root: URL?) { self.root = root?.standardizedFileURL.resolvingSymlinksInPath() }

    static let mime: [String: String] = [
        "html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "mjs": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8", "svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg",
        "jpeg": "image/jpeg", "json": "application/json", "woff2": "font/woff2", "woff": "font/woff",
        "mp4": "video/mp4", "mov": "video/quicktime", "m4a": "audio/mp4", "ico": "image/x-icon", "txt": "text/plain; charset=utf-8",
        "webp": "image/webp", "gif": "image/gif", "map": "application/json",
    ]

    public static func mimeType(_ url: URL) -> String { mime[url.pathExtension.lowercased()] ?? "application/octet-stream" }

    /// The page.
    public func page(_ req: HTTPRequest) -> HTTPResponse {
        guard let root else {
            return HTTPResponse(status: 200, headers: [("Content-Type", "text/html; charset=utf-8"), ("Cache-Control", "no-cache")],
                                body: .data(Data("<!doctype html><p>The editor page is not bundled with this build of Bubble.</p>".utf8)))
        }
        return Self.file(root.appendingPathComponent("index.html"), req, headers: [("Cache-Control", "no-cache")])
    }

    /// `/editor/<rest>`.
    public func asset(_ req: HTTPRequest) -> HTTPResponse {
        guard let file = resolve(String(req.path.dropFirst("/editor/".count))) else { return Self.notFound }
        return Self.file(file, req, headers: [("Cache-Control", "no-cache")])
    }

    /// A path inside the root, or nil (`..`, absolute, hidden files, folders, missing).
    func resolve(_ relative: String) -> URL? {
        guard let root else { return nil }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." || $0.hasPrefix(".") || $0.contains("\0") }) else { return nil }
        let url = parts.reduce(root) { $0.appendingPathComponent(String($1)) }.standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/") else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return url
    }

    static var notFound: HTTPResponse { Router.error(404, "not_found", "No such file.") }

    /// A file body with Range support.
    public static func file(_ url: URL, _ req: HTTPRequest, type: String? = nil, headers extra: [(String, String)] = []) -> HTTPResponse {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return notFound }
        var headers: [(String, String)] = [("Content-Type", type ?? mimeType(url)), ("Accept-Ranges", "bytes")] + extra
        switch byteRange(req.header("range"), size: size) {
        case .none:
            return HTTPResponse(status: 200, headers: headers, body: .file(url, offset: 0, length: size))
        case .unsatisfiable:
            return HTTPResponse(status: 416, headers: [("Content-Range", "bytes */\(size)")])
        case .range(let a, let b):
            headers.append(("Content-Range", "bytes \(a)-\(b)/\(size)"))
            return HTTPResponse(status: 206, headers: headers, body: .file(url, offset: a, length: b - a + 1))
        }
    }

    enum ByteRange: Equatable { case none, unsatisfiable, range(UInt64, UInt64) }

    /// One range of `bytes=a-b`, `bytes=a-`, `bytes=-n`. Several ranges or a malformed header: the
    /// whole file (RFC 9110 lets a server ignore Range).
    static func byteRange(_ header: String?, size: UInt64) -> ByteRange {
        guard let header = header?.trimmingCharacters(in: .whitespaces), header.hasPrefix("bytes=") else { return .none }
        let spec = header.dropFirst("bytes=".count)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return .none }
        let a = spec[..<dash].trimmingCharacters(in: .whitespaces), b = spec[spec.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        if a.isEmpty {
            guard let n = UInt64(b) else { return .none }
            guard n > 0, size > 0 else { return .unsatisfiable }
            return .range(size - min(n, size), size - 1)
        }
        guard let start = UInt64(a) else { return .none }
        if !b.isEmpty, UInt64(b) == nil { return .none }
        let end = b.isEmpty ? size &- 1 : min(UInt64(b)!, size &- 1)
        guard start < size, start <= end else { return .unsatisfiable }
        return .range(start, end)
    }
}
