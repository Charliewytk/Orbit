import Foundation
import Observation
import OrbitCore

/// Google, Exeter Microsoft and ELE sign-ins. OAuth tokens live in the
/// Keychain (synchronizable, so iCloud Keychain carries them to the iPhone).
@MainActor
@Observable
final class AccountManager {
    @ObservationIgnored let tokenStore: KeychainTokenStore
    private(set) var google: OAuthSession?
    private(set) var microsoft: OAuthSession?
    private(set) var googleConnected = false
    private(set) var microsoftConnected = false
    private(set) var googleEmail: String?
    private(set) var microsoftEmail: String?
    private(set) var moodle: MoodleCredentials?
    /// Which sign-in is in progress ("google", "microsoft", "ele").
    private(set) var busy: String?
    var lastError: String?

    init() {
        tokenStore = KeychainTokenStore(service: "\(AppConfig.bundleID).tokens", synchronizable: true)
        if let c = googleConfig { google = OAuthSession(account: "google", client: OAuthClient(config: c), store: tokenStore) }
        if let c = microsoftConfig { microsoft = OAuthSession(account: "microsoft", client: OAuthClient(config: c), store: tokenStore) }
        moodle = KeychainBlob.load(MoodleCredentials.self, key: "ele")
    }

    var googleConfig: OAuthConfig? {
        guard let id = AppConfig.googleClientID, let redirect = AppConfig.googleRedirectURI else { return nil }
        return .google(clientID: id, redirectURI: redirect)
    }

    var microsoftConfig: OAuthConfig? {
        guard let id = AppConfig.microsoftClientID else { return nil }
        return .microsoft(clientID: id, redirectURI: AppConfig.microsoftRedirectURI)
    }

    var eleConnected: Bool { moodle != nil }

    func refreshStatus() async {
        googleConnected = await google?.isSignedIn ?? false
        microsoftConnected = await microsoft?.isSignedIn ?? false
        var gEmail: String?
        if googleConnected, let session = google { gEmail = (try? await session.currentTokens())?.email }
        googleEmail = gEmail
        var mEmail: String?
        if microsoftConnected, let session = microsoft { mEmail = (try? await session.currentTokens())?.email }
        microsoftEmail = mEmail
    }

    // MARK: Google

    func connectGoogle() async {
        guard let config = googleConfig else {
            lastError = "Google isn't set up yet: add GOOGLE_CLIENT_ID to Config/Secrets.xcconfig (see docs/SETUP.md)."
            return
        }
        await signIn(config: config, account: "google") { self.google = $0 }
    }

    func disconnectGoogle() async {
        try? await google?.signOut()
        await refreshStatus()
    }

    // MARK: Microsoft (Exeter)

    func connectMicrosoft() async {
        guard let config = microsoftConfig else {
            lastError = "Microsoft isn't set up yet: add MICROSOFT_CLIENT_ID to Config/Secrets.xcconfig (see docs/SETUP.md)."
            return
        }
        await signIn(config: config, account: "microsoft") { self.microsoft = $0 }
    }

    func disconnectMicrosoft() async {
        try? await microsoft?.signOut()
        await refreshStatus()
    }

    private func signIn(config: OAuthConfig, account: String, assign: (OAuthSession) -> Void) async {
        busy = account
        defer { busy = nil }
        do {
            let client = OAuthClient(config: config)
            let authenticator = WebAuthenticator(callbackScheme: config.callbackScheme ?? "orbit")
            let tokens = try await client.signIn(using: authenticator)
            let session = OAuthSession(account: account, client: client, store: tokenStore)
            try await session.signIn(with: tokens)
            assign(session)
            lastError = nil
        } catch OAuthError.cancelled {
            // The user closed the sheet.
        } catch let error as OAuthError {
            if case .provider(let code, let description) = error,
               code.contains("consent") || (description ?? "").localizedCaseInsensitiveContains("admin") {
                lastError = "Exeter needs an admin to approve Orbit. Use the Apple Mail and PDF-folder options instead (see docs/SETUP.md)."
            } else {
                lastError = "\(account.capitalized) sign-in failed: \(error)"
            }
        } catch {
            lastError = "\(account.capitalized) sign-in failed: \(error.localizedDescription)"
        }
        await refreshStatus()
    }

    // MARK: ELE (Moodle)

    /// Signs in the way the Moodle mobile app does (Microsoft SSO in a web sheet).
    func connectELE() async {
        busy = "ele"
        defer { busy = nil }
        do {
            let passport = MoodleAuth.makePassport()
            var launch: URL?
            if let config = try? await MoodleAuth().siteConfig() {
                if !config.isMobileAccessAvailable {
                    lastError = "ELE has the Moodle app switched off. Paste your ELE calendar export link instead."
                    return
                }
                if config.loginType.usesSSO { launch = config.launchURL }
            }
            let scheme = MoodleAuth.defaultURLScheme
            let url = MoodleAuth.ssoLaunchURL(passport: passport, urlScheme: scheme, launchURL: launch)
            let authenticator = WebAuthenticator(callbackScheme: scheme)
            let callback = try await authenticator.authenticate(url: url, callbackScheme: scheme)
            let credentials = try MoodleAuth.parseSSOCallback(url: callback, passport: passport)
            try KeychainBlob.save(credentials, key: "ele")
            moodle = credentials
            lastError = nil
        } catch OAuthError.cancelled {
        } catch {
            lastError = "ELE sign-in didn't work (\(error)). You can paste your ELE calendar export link instead."
        }
    }

    func disconnectELE() {
        KeychainBlob.delete(key: "ele")
        moodle = nil
    }
}
