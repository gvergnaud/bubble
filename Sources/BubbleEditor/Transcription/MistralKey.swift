// Owner: E2 (transcription). docs/editor-architecture.md §5, docs/editor-api.md §5: the user's Mistral API key.
// Kept in his Keychain (generic password, service local.bubble.Bubble.mistral), pasted from the editor's
// settings; MISTRAL_API_KEY from the launch environment when the Keychain has none. Never logged, never in
// an error message or a response.
import Foundation
import Security

/// Where a secret lives. The Keychain in the app; a fake in tests (tests never touch the user's Keychain).
public protocol SecretStore: Sendable {
    func read() -> String?
    func write(_ secret: String) throws
    func delete() throws
}

public struct KeychainSecretStore: SecretStore {
    public let service: String
    public let account: String

    public init(service: String = "local.bubble.Bubble.mistral", account: String = "api-key") {
        self.service = service; self.account = account
    }

    public struct Failure: Error, CustomStringConvertible {
        public let status: OSStatus
        public var description: String { "Keychain error \(status)." }
    }

    private var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    public func read() -> String? {
        var q = query
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    public func write(_ secret: String) throws {
        let data = Data(secret.utf8)
        let update: [CFString: Any] = [kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
            add[kSecAttrLabel] = "Bubble: Mistral API key"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}

public struct MistralKey: Sendable {
    public enum Source: String, Sendable, Codable { case keychain, environment, none }

    public enum Verification: Sendable, Equatable {
        case valid
        case invalid
        /// Mistral could not be reached (offline): the key may be fine. → 502 `unreachable`.
        case unreachable
    }

    public enum SaveError: Error, Equatable, CustomStringConvertible {
        case invalid
        case unreachable
        case store(String)

        public var description: String {
            switch self {
            case .invalid: "This key didn't work."
            case .unreachable: "Mistral can't be reached right now. Check the connection and try again."
            case .store(let m): "The key could not be saved in the Keychain (\(m))."
            }
        }
    }

    public typealias Verifier = @Sendable (_ key: String) async -> Verification

    public static let environmentVariable = "MISTRAL_API_KEY"

    let store: any SecretStore
    let environmentKey: String?
    let verifier: Verifier

    /// `environment`: read once (the launch environment).
    public init(store: any SecretStore = KeychainSecretStore(),
                environment: [String: String] = ProcessInfo.processInfo.environment,
                verifier: @escaping Verifier = MistralKey.verifyOnline) {
        self.store = store
        let env = environment[Self.environmentVariable]?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.environmentKey = (env?.isEmpty ?? true) ? nil : env
        self.verifier = verifier
    }

    /// The key to use: the Keychain's, else the environment's.
    public func current() -> (key: String, source: Source)? {
        if let k = store.read() { return (k, .keychain) }
        if let k = environmentKey { return (k, .environment) }
        return nil
    }

    public var source: Source { current()?.source ?? .none }

    /// Verifies the key with Mistral (one request, no audio), then keeps it in the Keychain.
    public func save(_ key: String) async throws(SaveError) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty, !k.contains(where: \.isWhitespace) else { throw .invalid }
        switch await verifier(k) {
        case .invalid: throw .invalid
        case .unreachable: throw .unreachable
        case .valid: break
        }
        do { try store.write(k) } catch { throw .store("\(error)") }
    }

    /// Removes the Keychain's key (the environment's, if any, takes over).
    public func delete() throws { try store.delete() }

    /// GET https://api.mistral.ai/v1/models with the key: 200 valid, 401/403 invalid, anything else unreachable.
    public static let verifyOnline: Verifier = { key in
        var request = URLRequest(url: URL(string: "https://api.mistral.ai/v1/models")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        guard let (_, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse else {
            return .unreachable
        }
        switch http.statusCode {
        case 200: return .valid
        case 401, 403: return .invalid
        default: return .unreachable
        }
    }
}

/// In-memory store, for tests and BUBBLE_FAKE runs.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    public init(_ value: String? = nil) { self.value = value }
    public func read() -> String? { lock.withLock { value } }
    public func write(_ secret: String) throws { lock.withLock { value = secret } }
    public func delete() throws { lock.withLock { value = nil } }
}
