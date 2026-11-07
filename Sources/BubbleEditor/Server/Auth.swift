// Editor auth (docs/editor-architecture.md §2, editor-api.md §1). Owner: E1.
// A per-install token (32 random bytes, hex) in `<appSupport>/editor-token`, mode 0600, stable
// across launches. Bubble opens `/edit/:id?t=<token>`; the server answers with the cookie
// `bubble=<token>; HttpOnly; SameSite=Strict` and a redirect to the clean URL. `/api/*` and
// `/media/*` need the cookie. Every request needs a `Host` of 127.0.0.1:<port> or localhost:<port>
// (DNS rebinding). The page does nothing for any of it.
import Foundation
import Security

public struct Auth: Sendable {
    public static let cookieName = "bubble"
    public let token: String

    public init(token: String) { self.token = token }

    /// Reads the token file, or makes it (0600) on first use.
    public static func load(appSupport: URL) throws -> Auth {
        let file = appSupport.appendingPathComponent("editor-token")
        if let s = try? String(contentsOf: file, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count == 64, t.allSatisfy(\.isHexDigit) {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                return Auth(token: t)
            }
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw EditorError.failed("Could not make the editor's token.")
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        // Created 0600 from the start: never readable by others, not even for a moment.
        guard FileManager.default.createFile(atPath: file.path, contents: Data(token.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw EditorError.failed("Could not write \(file.path).")
        }
        return Auth(token: token)
    }

    public func hostAllowed(_ host: String?, port: UInt16) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "127.0.0.1:\(port)" || host == "localhost:\(port)"
    }

    public func cookieValid(_ cookieHeader: String?) -> Bool {
        guard let cookieHeader else { return false }
        for part in cookieHeader.split(separator: ";") {
            let kv = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == Self.cookieName, Self.constantTimeEqual(String(kv[1]), token) { return true }
        }
        return false
    }

    public func tokenValid(_ t: String?) -> Bool { t.map { Self.constantTimeEqual($0, token) } ?? false }

    public var setCookie: String {
        "\(Self.cookieName)=\(token); HttpOnly; SameSite=Strict; Path=/; Max-Age=31536000"
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
