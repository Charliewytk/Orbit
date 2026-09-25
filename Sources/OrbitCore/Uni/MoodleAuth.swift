import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A Moodle web-service token for one site. Store it in the Keychain.
public struct MoodleCredentials: Codable, Hashable, Sendable {
    public var siteURL: URL
    public var token: String
    /// Lets Orbit open ELE pages already logged in (see `MoodleClient.autoLoginURL`).
    public var privateToken: String?

    public init(siteURL: URL, token: String, privateToken: String? = nil) {
        self.siteURL = siteURL; self.token = token; self.privateToken = privateToken
    }
}

/// How the site wants the mobile app to log in (`tool_mobile` "typeoflogin").
public enum MoodleLoginType: Int, Codable, Sendable {
    /// Username and password inside the app (`/login/token.php`).
    case app = 1
    /// Log in through the system browser, then hand a token back to the app (SSO).
    case browser = 2
    /// Log in through an embedded browser (also SSO via launch.php).
    case embedded = 3
    case unknown = 0

    public var usesSSO: Bool { self == .browser || self == .embedded }
}

/// The site's public mobile configuration (`tool_mobile_get_public_config`).
public struct MoodleSiteConfig: Hashable, Sendable {
    public var siteName: String?
    public var wwwroot: String?
    public var httpsWWWRoot: String?
    public var webServicesEnabled: Bool
    public var mobileServiceEnabled: Bool
    public var loginType: MoodleLoginType
    /// launch.php URL to start SSO from, if the site gives one.
    public var launchURL: URL?
    /// SSO buttons shown on the login page (e.g. "Microsoft").
    public var identityProviders: [IdentityProvider]
    public var maintenanceEnabled: Bool
    public var maintenanceMessage: String?

    public struct IdentityProvider: Hashable, Sendable {
        public var name: String
        public var url: URL?
    }

    /// Mobile access is available (maintenance aside).
    public var isMobileAccessAvailable: Bool { mobileServiceEnabled && webServicesEnabled }

    init(json j: MoodleJSON) {
        siteName = j["sitename"].string
        wwwroot = j["wwwroot"].string
        httpsWWWRoot = j["httpswwwroot"].string
        // Older sites omit enablewebservices; assume on if the mobile service is on.
        mobileServiceEnabled = j["enablemobilewebservice"].bool ?? false
        webServicesEnabled = j["enablewebservices"].bool ?? mobileServiceEnabled
        loginType = MoodleLoginType(rawValue: j["typeoflogin"].int ?? 0) ?? .unknown
        launchURL = j["launchurl"].string.flatMap(URL.init(string:))
        identityProviders = j["identityproviders"].array.map {
            IdentityProvider(name: UniHTML.text($0["name"].string ?? ""), url: $0["url"].string.flatMap(URL.init(string:)))
        }
        maintenanceEnabled = j["maintenanceenabled"].bool ?? false
        maintenanceMessage = j["maintenancemessage"].string.map(UniHTML.text)
    }
}

/// Signing in to ELE (Exeter's Moodle) the way the official Moodle app does.
///
/// Exeter uses Microsoft SSO, so the main path is the mobile-app SSO launch:
/// 1. `let passport = MoodleAuth.makePassport()`
/// 2. Open `ssoLaunchURL(...)` in `ASWebAuthenticationSession` with the same callback scheme.
/// 3. The user signs in with Microsoft; ELE redirects to `<scheme>://token=<base64>`.
/// 4. `parseSSOCallback(url:passport:siteURL:)` checks the signature and returns credentials.
///
/// Caveat: sites can force their own URL scheme (`tool_mobile | forcedurlscheme`,
/// default "moodlemobile"), in which case the redirect ignores ours. That's why
/// `defaultURLScheme` is "moodlemobile": `ASWebAuthenticationSession` catches the
/// callback inside the session, so it doesn't clash with the Moodle app.
public struct MoodleAuth: Sendable {
    public static let exeterSite = URL(string: "https://ele.exeter.ac.uk")!
    public static let service = "moodle_mobile_app"
    public static let defaultURLScheme = "moodlemobile"

    public var http: HTTPClient
    public init(http: HTTPClient = HTTPClient(timeout: 30)) { self.http = http }

    /// A random one-off value tying the SSO response to this request.
    public static func makePassport() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// The page to open for SSO:
    /// `{site}/admin/tool/mobile/launch.php?service=moodle_mobile_app&passport=…&urlscheme=…`.
    /// Pass `launchURL` from `MoodleSiteConfig` if the site advertises a different one.
    public static func ssoLaunchURL(site: URL = exeterSite, passport: String, urlScheme: String = defaultURLScheme,
                                    launchURL: URL? = nil) -> URL {
        let base = launchURL ?? siteRoot(site).appendingPathComponent("admin/tool/mobile/launch.php")
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        comps.queryItems = (comps.queryItems ?? []).filter { !["service", "passport", "urlscheme"].contains($0.name) } + [
            URLQueryItem(name: "service", value: service),
            URLQueryItem(name: "passport", value: passport),
            URLQueryItem(name: "urlscheme", value: urlScheme),
        ]
        return comps.url!
    }

    /// Reads the SSO redirect `<scheme>://token=<base64>` (with or without "//").
    /// The token decodes to `signature:::token[:::privatetoken]`, where
    /// signature = md5(siteURL + passport). http/https and trailing-slash variants
    /// of the site URL are accepted, as the Moodle app does.
    public static func parseSSOCallback(url: URL, passport: String, siteURL: URL = exeterSite) throws -> MoodleCredentials {
        try parseSSOCallback(url.absoluteString, passport: passport, siteURL: siteURL)
    }

    public static func parseSSOCallback(_ callback: String, passport: String, siteURL: URL = exeterSite) throws -> MoodleCredentials {
        guard let range = callback.range(of: "token=") else { throw MoodleError.invalidSSOCallback(callback) }
        var encoded = String(callback[range.upperBound...])
        if let end = encoded.firstIndex(where: { $0 == "&" || $0 == "#" }) { encoded = String(encoded[..<end]) }
        encoded = encoded.removingPercentEncoding ?? encoded
        // Tolerate URL-safe alphabets, stray whitespace and missing padding.
        encoded = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: " ", with: "+").trimmingCharacters(in: .whitespacesAndNewlines)
        while encoded.count % 4 != 0 { encoded += "=" }
        guard let data = Data(base64Encoded: encoded), let decoded = String(data: data, encoding: .utf8) else {
            throw MoodleError.invalidSSOCallback(callback)
        }
        let parts = decoded.components(separatedBy: ":::")
        guard parts.count >= 2, !parts[1].isEmpty else { throw MoodleError.invalidSSOCallback(callback) }

        let signature = parts[0].lowercased()
        guard signatureCandidates(siteURL).contains(where: { MD5.hex($0 + passport) == signature }) else {
            throw MoodleError.signatureMismatch
        }
        return MoodleCredentials(siteURL: siteRoot(siteURL), token: parts[1],
                                 privateToken: parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil)
    }

    static func signatureCandidates(_ site: URL) -> [String] {
        let root = siteRoot(site).absoluteString
        var out: [String] = []
        for base in [root, root.replacingOccurrences(of: "https://", with: "http://"),
                     root.replacingOccurrences(of: "http://", with: "https://")] {
            for s in [base, base + "/"] where !out.contains(s) { out.append(s) }
        }
        return out
    }

    /// Site URL without a trailing slash (Moodle's `$CFG->wwwroot`).
    static func siteRoot(_ site: URL) -> URL {
        var s = site.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s) ?? site
    }

    /// Secondary path: username/password via `/login/token.php`. This usually
    /// fails on SSO-only sites like ELE (the error says to use the browser).
    public func passwordLogin(site: URL = exeterSite, username: String, password: String) async throws -> MoodleCredentials {
        let url = Self.siteRoot(site).appendingPathComponent("login/token.php")
        let body = FormEncoding.encode([("username", username), ("password", password), ("service", Self.service)])
        let data = try await http.data("POST", url, headers: ["Content-Type": "application/x-www-form-urlencoded",
                                                             "Accept": "application/json"], body: Data(body.utf8))
        let json = try MoodleJSON.parse(data)
        if let error = MoodleError.from(json) {
            if case .exception(let code, let msg) = error { throw MoodleError.login(errorCode: code, message: msg) }
            throw error
        }
        guard let token = json["token"].string, !token.isEmpty else {
            throw MoodleError.unexpectedResponse(String(decoding: data, as: UTF8.self))
        }
        return MoodleCredentials(siteURL: Self.siteRoot(site), token: token, privateToken: json["privatetoken"].string)
    }

    /// Checks whether the mobile service is on and which login type the site
    /// wants. Tries the no-login AJAX endpoint first, then the REST server.
    public func siteConfig(site: URL = exeterSite) async throws -> MoodleSiteConfig {
        let root = Self.siteRoot(site)
        var ajaxError: Error?
        do {
            var comps = URLComponents(url: root.appendingPathComponent("lib/ajax/service-nologin.php"), resolvingAgainstBaseURL: false)!
            comps.queryItems = [URLQueryItem(name: "info", value: "tool_mobile_get_public_config")]
            let body = Data(#"[{"index":0,"methodname":"tool_mobile_get_public_config","args":{}}]"#.utf8)
            let data = try await http.data("POST", comps.url!, headers: ["Content-Type": "application/json",
                                                                         "Accept": "application/json"], body: body)
            let json = try MoodleJSON.parse(data)
            let first = json[0]
            if first["error"].bool == false, first["data"].object != nil { return MoodleSiteConfig(json: first["data"]) }
            if let e = first["exception"].object {
                ajaxError = MoodleError.exception(errorCode: e["errorcode"]?.string ?? "unknown", message: e["message"]?.string ?? "")
            } else {
                ajaxError = MoodleError.from(json) ?? MoodleError.unexpectedResponse(String(decoding: data, as: UTF8.self))
            }
        } catch {
            ajaxError = error
        }
        do {
            let fields = [("wsfunction", "tool_mobile_get_public_config"), ("moodlewsrestformat", "json")]
            let data = try await http.data("POST", root.appendingPathComponent("webservice/rest/server.php"),
                                           headers: ["Content-Type": "application/x-www-form-urlencoded"],
                                           body: Data(FormEncoding.encode(fields).utf8))
            let json = try MoodleJSON.parse(data)
            if let error = MoodleError.from(json) { throw error }
            return MoodleSiteConfig(json: json)
        } catch {
            throw ajaxError ?? error
        }
    }
}
