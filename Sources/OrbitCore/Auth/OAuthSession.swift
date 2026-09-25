import Foundation

/// One signed-in account. Hands out access tokens, refreshing them shortly
/// before they expire and saving the refreshed tokens to the store.
/// Concurrent callers share a single refresh.
public actor OAuthSession: AccessTokenProvider {
    public nonisolated let account: String
    public let client: OAuthClient
    public let store: TokenStore
    /// Refresh when the token expires within this many seconds.
    public var refreshLeeway: TimeInterval
    private let now: @Sendable () -> Date
    private var tokens: OAuthTokens?
    private var loaded = false
    private var refreshing: Task<OAuthTokens, Error>?

    public init(account: String, client: OAuthClient, store: TokenStore, tokens: OAuthTokens? = nil,
                refreshLeeway: TimeInterval = 120, now: @escaping @Sendable () -> Date = { Date() }) {
        self.account = account; self.client = client; self.store = store
        self.tokens = tokens; self.loaded = tokens != nil
        self.refreshLeeway = refreshLeeway; self.now = now
    }

    private func current() throws -> OAuthTokens? {
        if !loaded { tokens = try store.load(account: account); loaded = true }
        return tokens
    }

    public var isSignedIn: Bool { ((try? current()) ?? nil) != nil }

    public func currentTokens() throws -> OAuthTokens? { try current() }

    /// Store tokens from a fresh sign-in.
    public func signIn(with tokens: OAuthTokens) throws {
        try store.save(tokens, account: account)
        self.tokens = tokens; loaded = true
    }

    public func signOut() throws {
        refreshing?.cancel(); refreshing = nil
        try store.delete(account: account)
        tokens = nil; loaded = true
    }

    public func accessToken() async throws -> String {
        guard let t = try current() else { throw OAuthError.notSignedIn }
        if !t.expires(within: refreshLeeway, of: now()) { return t.accessToken }
        return try await refresh().accessToken
    }

    /// Forces a refresh (e.g. after a 401).
    @discardableResult
    public func refresh() async throws -> OAuthTokens {
        if let refreshing { return try await refreshing.value }
        guard let t = try current() else { throw OAuthError.notSignedIn }
        let client = client, time = now()
        let task = Task { try await client.refresh(t, now: time) }
        refreshing = task
        defer { refreshing = nil }
        let fresh = try await task.value
        tokens = fresh
        try store.save(fresh, account: account)
        return fresh
    }
}
