import Foundation

/// Anything that can hand out a fresh OAuth access token (Google or Microsoft).
/// API clients depend on this instead of on a specific login implementation.
public protocol AccessTokenProvider: Sendable {
    func accessToken() async throws -> String
}

/// A fixed token, for tests and quick scripts.
public struct StaticTokenProvider: AccessTokenProvider {
    public var token: String
    public init(_ token: String) { self.token = token }
    public func accessToken() async throws -> String { token }
}
