import Foundation
#if canImport(Security)
import Security
#endif

/// Where OAuth tokens live, keyed by account (e.g. "google:me@gmail.com").
public protocol TokenStore: Sendable {
    func load(account: String) throws -> OAuthTokens?
    func save(_ tokens: OAuthTokens, account: String) throws
    func delete(account: String) throws
}

/// Tokens kept in memory only. For tests and previews.
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private var items: [String: OAuthTokens]
    private let lock = NSLock()

    public init(_ items: [String: OAuthTokens] = [:]) { self.items = items }

    public func load(account: String) throws -> OAuthTokens? {
        lock.lock(); defer { lock.unlock() }
        return items[account]
    }

    public func save(_ tokens: OAuthTokens, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        items[account] = tokens
    }

    public func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        items[account] = nil
    }

    public var accounts: [String] {
        lock.lock(); defer { lock.unlock() }
        return items.keys.sorted()
    }
}

#if canImport(Security)
public struct KeychainError: Error, CustomStringConvertible, Sendable {
    public var status: OSStatus
    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String?
        return "Keychain error \(status)\(message.map { ": \($0)" } ?? "")"
    }
}

#if os(macOS)
/// Whether this build can use the modern (data-protection) keychain. That needs
/// a signed app with an application identifier; the free unsigned download
/// doesn't have one, so it falls back to the classic login keychain (not synced).
public enum KeychainSupport {
    public static let modernAvailable: Bool = {
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.orbit.keychain-probe",
            kSecAttrAccount as String: "probe",
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemCopyMatching(probe as CFDictionary, nil)
        return status != errSecMissingEntitlement
    }()
}
#endif

/// Stores tokens as generic passwords. Synchronizable items travel through
/// iCloud Keychain, so signing in on the Mac also signs in the iPhone.
public struct KeychainTokenStore: TokenStore {
    public var service: String
    public var synchronizable: Bool
    /// Shared keychain access group (needed if the widget/extension reads tokens).
    public var accessGroup: String?

    public init(service: String = "com.orbit.tokens", synchronizable: Bool = true, accessGroup: String? = nil) {
        self.service = service; self.synchronizable = synchronizable; self.accessGroup = accessGroup
    }

    private func baseQuery(account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #if os(macOS)
        // Synchronizable items need the modern (iOS-style) keychain on macOS.
        // The classic file keychain (unsigned builds) doesn't take the synchronizable
        // or access-group attributes, so only the modern keychain gets them.
        let modern = KeychainSupport.modernAvailable
        if modern {
            q[kSecUseDataProtectionKeychain as String] = true
            if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
            q[kSecAttrSynchronizable as String] = synchronizable ? kCFBooleanTrue as Any : kCFBooleanFalse as Any
        }
        #else
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        q[kSecAttrSynchronizable as String] = synchronizable ? kCFBooleanTrue as Any : kCFBooleanFalse as Any
        #endif
        return q
    }

    public func load(account: String) throws -> OAuthTokens? {
        var q = baseQuery(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = item as? Data else { return nil }
        return try JSONDecoder().decode(OAuthTokens.self, from: data)
    }

    public func save(_ tokens: OAuthTokens, account: String) throws {
        let data = try JSONEncoder().encode(tokens)
        let query = baseQuery(account: account)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            // Synchronizable items can't use a ...ThisDeviceOnly class.
            #if os(macOS)
            if KeychainSupport.modernAvailable { add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock }
            #else
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            #endif
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
#endif

/// Tokens as JSON files readable only by this user (0600), e.g. in Application
/// Support. The fallback when the keychain refuses an unsigned build.
public struct FileTokenStore: TokenStore {
    public var directory: URL

    public init(directory: URL) { self.directory = directory }

    private func url(_ account: String) -> URL {
        let safe = account.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return directory.appendingPathComponent("token-\(String(safe)).json")
    }

    public func load(account: String) throws -> OAuthTokens? {
        guard let data = try? Data(contentsOf: url(account)) else { return nil }
        return try JSONDecoder().decode(OAuthTokens.self, from: data)
    }

    public func save(_ tokens: OAuthTokens, account: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let file = url(account)
        try JSONEncoder().encode(tokens).write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    public func delete(account: String) throws {
        let file = url(account)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}

/// Tries `primary` (the keychain) and falls back to `secondary` (a file) if it
/// throws, so a keychain problem never silently loses a sign-in.
public struct FallbackTokenStore: TokenStore {
    public var primary: TokenStore
    public var secondary: TokenStore

    public init(primary: TokenStore, secondary: TokenStore) {
        self.primary = primary; self.secondary = secondary
    }

    public func load(account: String) throws -> OAuthTokens? {
        do {
            if let tokens = try primary.load(account: account) { return tokens }
        } catch {
            OrbitLog.log("keychain", "Reading \(account) from the keychain failed: \(error)")
        }
        return try secondary.load(account: account)
    }

    public func save(_ tokens: OAuthTokens, account: String) throws {
        do {
            try primary.save(tokens, account: account)
            try? secondary.delete(account: account)
        } catch {
            OrbitLog.log("keychain", "Saving \(account) to the keychain failed (\(error)); saving to a private file instead")
            try secondary.save(tokens, account: account)
        }
    }

    public func delete(account: String) throws {
        var firstError: Error?
        do { try primary.delete(account: account) } catch { firstError = error }
        do { try secondary.delete(account: account) } catch { firstError = firstError ?? error }
        if let firstError { throw firstError }
    }
}
