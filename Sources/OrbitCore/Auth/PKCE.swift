import Foundation

/// Proof Key for Code Exchange (RFC 7636), S256 method.
public struct PKCE: Codable, Hashable, Sendable {
    public let verifier: String
    public let challenge: String
    public var method: String { "S256" }

    /// A fresh random verifier (32 random bytes → 43 base64url characters).
    public init() {
        self.init(verifier: Base64URL.encode(Self.randomBytes(32)))
    }

    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = Self.challenge(for: verifier)
    }

    public static func challenge(for verifier: String) -> String {
        Base64URL.encode(SHA256Digest.hash(Data(verifier.utf8)))
    }

    /// Random OAuth `state` value.
    public static func randomState() -> String { Base64URL.encode(randomBytes(16)) }

    /// Cryptographically secure on every platform Swift supports.
    static func randomBytes(_ count: Int) -> Data {
        var rng = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
    }
}
