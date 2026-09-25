import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum OAuthProviderKind: String, Codable, Sendable { case google, microsoft, custom }

/// Endpoints, client and scopes for one OAuth provider. Client IDs come from
/// the app's config (never hard-coded here).
public struct OAuthConfig: Codable, Hashable, Sendable {
    public var provider: OAuthProviderKind
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var clientID: String
    /// Only for Google "Desktop" clients, which need one even with PKCE. iOS clients have none.
    public var clientSecret: String?
    /// e.g. "com.orbit.app:/oauth2redirect" or "com.googleusercontent.apps.123-abc:/oauth2redirect".
    public var redirectURI: String
    public var scopes: [String]
    /// Extra query items for the authorize URL (e.g. access_type=offline).
    public var extraAuthorizeParameters: [String: String]

    public init(provider: OAuthProviderKind = .custom, authorizationEndpoint: URL, tokenEndpoint: URL,
                clientID: String, clientSecret: String? = nil, redirectURI: String, scopes: [String],
                extraAuthorizeParameters: [String: String] = [:]) {
        self.provider = provider; self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint; self.clientID = clientID; self.clientSecret = clientSecret
        self.redirectURI = redirectURI; self.scopes = scopes; self.extraAuthorizeParameters = extraAuthorizeParameters
    }

    /// The URL scheme the web sign-in sheet should watch for.
    public var callbackScheme: String? { URL(string: redirectURI)?.scheme }

    public static let googleScopes = [
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/calendar",
        "openid", "email",
    ]

    public static let microsoftScopes = [
        "offline_access", "User.Read", "Mail.Read", "Mail.ReadWrite", "Notes.Read", "Calendars.Read",
    ]

    /// Gmail + Google Calendar. `prompt=consent` makes Google always return a refresh token.
    public static func google(clientID: String, redirectURI: String, clientSecret: String? = nil,
                              scopes: [String] = OAuthConfig.googleScopes) -> OAuthConfig {
        OAuthConfig(provider: .google,
                    authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
                    tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
                    clientID: clientID, clientSecret: clientSecret, redirectURI: redirectURI, scopes: scopes,
                    extraAuthorizeParameters: ["access_type": "offline", "prompt": "consent"])
    }

    /// Exeter Microsoft 365 (work/school accounts): mail, OneNote, calendar.
    public static func microsoft(clientID: String, redirectURI: String, tenant: String = "organizations",
                                 scopes: [String] = OAuthConfig.microsoftScopes) -> OAuthConfig {
        let base = "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0"
        return OAuthConfig(provider: .microsoft,
                           authorizationEndpoint: URL(string: base + "/authorize")!,
                           tokenEndpoint: URL(string: base + "/token")!,
                           clientID: clientID, redirectURI: redirectURI, scopes: scopes,
                           extraAuthorizeParameters: ["response_mode": "query"])
    }
}

/// Tokens for one signed-in account. Stored in the keychain as JSON.
public struct OAuthTokens: Codable, Hashable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiry: Date?
    public var scope: String?
    public var idToken: String?
    public var tokenType: String?

    public init(accessToken: String, refreshToken: String? = nil, expiry: Date? = nil,
                scope: String? = nil, idToken: String? = nil, tokenType: String? = "Bearer") {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiry = expiry
        self.scope = scope; self.idToken = idToken; self.tokenType = tokenType
    }

    /// True when the access token expires within `leeway` seconds of `now`.
    public func expires(within leeway: TimeInterval, of now: Date = Date()) -> Bool {
        guard let expiry else { return false }
        return expiry.timeIntervalSince(now) <= leeway
    }

    /// Claims from the (unverified) ID token payload. Fine for display, not for trust decisions.
    public var idTokenClaims: [String: Any]? {
        guard let idToken else { return nil }
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2, let data = Base64URL.decode(String(parts[1])) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The account's email address, if the ID token has one.
    public var email: String? {
        let claims = idTokenClaims
        return (claims?["email"] as? String) ?? (claims?["preferred_username"] as? String)
    }
}

public enum OAuthError: Error, CustomStringConvertible, Sendable, Equatable {
    case notSignedIn
    case cancelled
    case stateMismatch
    case missingCode
    case invalidCallback(String)
    case noRefreshToken
    /// The refresh token was revoked or expired: the user must sign in again.
    case reauthenticationRequired(String)
    case provider(code: String, description: String?)
    case couldNotStart

    public var description: String {
        switch self {
        case .notSignedIn: "Not signed in"
        case .cancelled: "Sign-in was cancelled"
        case .stateMismatch: "Sign-in response didn't match the request (state mismatch)"
        case .missingCode: "Sign-in response had no authorisation code"
        case .invalidCallback(let s): "Unexpected sign-in callback: \(s)"
        case .noRefreshToken: "No refresh token stored; please sign in again"
        case .reauthenticationRequired(let s): "Please sign in again (\(s))"
        case .provider(let code, let desc): "Sign-in error \(code)\(desc.map { ": \($0)" } ?? "")"
        case .couldNotStart: "Couldn't open the sign-in window"
        }
    }
}

/// A prepared authorize request: open `url`, then pass the callback to `OAuthClient.code(from:expecting:)`.
public struct AuthorizationRequest: Sendable, Hashable {
    public var url: URL
    public var state: String
    public var pkce: PKCE
}

/// Builds authorize URLs and talks to the token endpoint.
public struct OAuthClient: Sendable {
    public var config: OAuthConfig
    public var http: HTTPClient

    public init(config: OAuthConfig, http: HTTPClient = HTTPClient()) {
        self.config = config; self.http = http
    }

    public func authorizationRequest(state: String = PKCE.randomState(), pkce: PKCE = PKCE(),
                                     loginHint: String? = nil) -> AuthorizationRequest {
        AuthorizationRequest(url: authorizationURL(state: state, pkce: pkce, loginHint: loginHint),
                             state: state, pkce: pkce)
    }

    public func authorizationURL(state: String, pkce: PKCE, loginHint: String? = nil) -> URL {
        var fields: [(String, String)] = [
            ("response_type", "code"),
            ("client_id", config.clientID),
            ("redirect_uri", config.redirectURI),
            ("scope", config.scopes.joined(separator: " ")),
            ("state", state),
            ("code_challenge", pkce.challenge),
            ("code_challenge_method", pkce.method),
        ]
        fields += config.extraAuthorizeParameters.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        if let loginHint { fields.append(("login_hint", loginHint)) }
        var comps = URLComponents(url: config.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        comps.percentEncodedQuery = FormEncoding.encode(fields)
        return comps.url!
    }

    /// Pulls the authorisation code out of the redirect URL, checking `state`.
    public func code(from callback: URL, expecting state: String) throws -> String {
        guard let comps = URLComponents(url: callback, resolvingAgainstBaseURL: false) else {
            throw OAuthError.invalidCallback(callback.absoluteString)
        }
        var items: [String: String] = [:]
        for item in comps.queryItems ?? [] { items[item.name] = item.value ?? "" }
        if let error = items["error"] {
            if error == "access_denied" { throw OAuthError.cancelled }
            throw OAuthError.provider(code: error, description: items["error_description"])
        }
        guard items["state"] == state else { throw OAuthError.stateMismatch }
        guard let code = items["code"], !code.isEmpty else { throw OAuthError.missingCode }
        return code
    }

    struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double?
        let scope: String?
        let id_token: String?
        let token_type: String?
    }

    struct ErrorResponse: Decodable { let error: String; let error_description: String? }

    public func exchange(code: String, pkce: PKCE, now: Date = Date()) async throws -> OAuthTokens {
        var fields: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", config.redirectURI),
            ("client_id", config.clientID),
            ("code_verifier", pkce.verifier),
        ]
        if let secret = config.clientSecret { fields.append(("client_secret", secret)) }
        let res = try await tokenRequest(fields)
        return OAuthTokens(accessToken: res.access_token, refreshToken: res.refresh_token,
                           expiry: res.expires_in.map { now.addingTimeInterval($0) }, scope: res.scope,
                           idToken: res.id_token, tokenType: res.token_type)
    }

    /// Refreshes the access token. Providers often omit a new refresh token or
    /// ID token; the old ones are kept in that case.
    public func refresh(_ tokens: OAuthTokens, now: Date = Date()) async throws -> OAuthTokens {
        guard let refreshToken = tokens.refreshToken else { throw OAuthError.noRefreshToken }
        var fields: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", config.clientID),
        ]
        if let secret = config.clientSecret { fields.append(("client_secret", secret)) }
        if config.provider == .microsoft { fields.append(("scope", config.scopes.joined(separator: " "))) }
        let res = try await tokenRequest(fields)
        return OAuthTokens(accessToken: res.access_token, refreshToken: res.refresh_token ?? refreshToken,
                           expiry: res.expires_in.map { now.addingTimeInterval($0) },
                           scope: res.scope ?? tokens.scope, idToken: res.id_token ?? tokens.idToken,
                           tokenType: res.token_type ?? tokens.tokenType)
    }

    private func tokenRequest(_ fields: [(String, String)]) async throws -> TokenResponse {
        do {
            return try await http.form(TokenResponse.self, config.tokenEndpoint, fields: fields)
        } catch let error as HTTPError {
            if let body = error.body.data(using: .utf8),
               let e = try? JSONDecoder().decode(ErrorResponse.self, from: body) {
                if e.error == "invalid_grant" {
                    throw OAuthError.reauthenticationRequired(e.error_description ?? e.error)
                }
                throw OAuthError.provider(code: e.error, description: e.error_description)
            }
            throw error
        }
    }
}
