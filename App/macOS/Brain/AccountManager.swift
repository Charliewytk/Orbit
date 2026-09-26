import Foundation
import Observation
import OrbitCore

/// Google, Exeter Microsoft and ELE sign-ins. OAuth tokens live in the
/// Keychain; if the keychain refuses (the unsigned download build), they go to
/// a private file in Application Support instead, so a sign-in is never lost.
@MainActor
@Observable
final class AccountManager {
    @ObservationIgnored let tokenStore: FallbackTokenStore
    private(set) var google: OAuthSession?
    private(set) var microsoft: OAuthSession?
    private(set) var googleConnected = false
    private(set) var microsoftConnected = false
    private(set) var googleEmail: String?
    private(set) var microsoftEmail: String?
    private(set) var moodle: MoodleCredentials?
    /// Which sign-in is in progress ("google", "microsoft", "ele").
    private(set) var busy: String?
    /// What the Google / Microsoft sign-in is doing right now, e.g. "Waiting for Google…".
    private(set) var googleProgress: String?
    private(set) var microsoftProgress: String?
    /// The last Google / Microsoft sign-in problem, shown under its Connect button.
    var googleError: String?
    var microsoftError: String?
    var lastError: String?

    private static let googleEmailKey = "googleAccountEmail"
    private static let microsoftEmailKey = "microsoftAccountEmail"

    init() {
        let keychain = KeychainTokenStore(service: "\(AppConfig.bundleID).tokens", synchronizable: true)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let files = FileTokenStore(directory: base.appendingPathComponent("Orbit/Accounts", isDirectory: true))
        tokenStore = FallbackTokenStore(primary: keychain, secondary: files)
        OrbitLog.log("accounts", "Orbit \(AppConfig.appVersion) starting. Keychain: \(KeychainSupport.modernAvailable ? "modern" : "classic login keychain (unsigned build)"). Google client: \(AppConfig.googleClientID == nil ? "missing" : "present"), redirect \(AppConfig.googleRedirectURI ?? "-"). Microsoft client: \(AppConfig.microsoftClientID == nil ? "none" : "present")")
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

    /// Microsoft Graph sign-in is an optional advanced extra: only offered when a client ID was built in.
    var microsoftAvailable: Bool { microsoftConfig != nil }

    var eleConnected: Bool { moodle != nil }

    func refreshStatus() async {
        googleConnected = await google?.isSignedIn ?? false
        microsoftConnected = await microsoft?.isSignedIn ?? false
        var gEmail: String?
        if googleConnected, let session = google { gEmail = (try? await session.currentTokens())?.email }
        googleEmail = googleConnected ? (gEmail ?? UserDefaults.standard.string(forKey: Self.googleEmailKey)) : nil
        var mEmail: String?
        if microsoftConnected, let session = microsoft { mEmail = (try? await session.currentTokens())?.email }
        microsoftEmail = microsoftConnected ? (mEmail ?? UserDefaults.standard.string(forKey: Self.microsoftEmailKey)) : nil
    }

    // MARK: Google

    /// Signs in to Google. Returns true when Orbit is now connected.
    @discardableResult
    func connectGoogle() async -> Bool {
        OrbitLog.log("google", "Connect pressed")
        googleError = nil
        guard let config = googleConfig else {
            googleError = "This copy of Orbit was built without a Google client ID, so Google can't be connected. Please tell us (Settings → Diagnostics → Copy log)."
            OrbitLog.log("google", "No Google client ID in Info.plist (OrbitGoogleClientID)")
            return false
        }
        guard config.callbackScheme == AppConfig.googleReversedClientID else {
            googleError = "Orbit's Google settings don't match (redirect \(config.redirectURI)). Please send us the log."
            OrbitLog.log("google", "Callback scheme \(config.callbackScheme ?? "nil") doesn't match reversed client ID \(AppConfig.googleReversedClientID ?? "nil")")
            return false
        }
        let ok = await signIn(config: config, account: "google", label: "Google") { self.google = $0 }
        if ok, let session = google {
            var email = (try? await session.currentTokens())?.email
            if email == nil { email = await fetchGoogleEmail(session) }
            if let email { UserDefaults.standard.set(email, forKey: Self.googleEmailKey) }
            OrbitLog.log("google", "Signed in as \(email ?? "(email unknown)")")
            await refreshStatus()
        }
        return ok && googleConnected
    }

    /// Asks Google who is signed in (used when the ID token has no email).
    private func fetchGoogleEmail(_ session: OAuthSession) async -> String? {
        struct UserInfo: Decodable { let email: String? }
        do {
            let token = try await session.accessToken()
            let info = try await HTTPClient(timeout: 20).get(UserInfo.self, URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!,
                                                            headers: ["Authorization": "Bearer \(token)"])
            return info.email
        } catch {
            OrbitLog.log("google", "Couldn't read the account's email address: \(error)")
            return nil
        }
    }

    func disconnectGoogle() async {
        OrbitLog.log("google", "Disconnect pressed")
        try? await google?.signOut()
        UserDefaults.standard.removeObject(forKey: Self.googleEmailKey)
        googleError = nil
        await refreshStatus()
    }

    // MARK: Microsoft (Exeter, optional advanced)

    @discardableResult
    func connectMicrosoft() async -> Bool {
        OrbitLog.log("microsoft", "Connect pressed")
        microsoftError = nil
        guard let config = microsoftConfig else {
            microsoftError = "Microsoft sign-in isn't available in this build. Use Apple Mail and Calendar instead (see the Exeter step)."
            return false
        }
        let ok = await signIn(config: config, account: "microsoft", label: "Microsoft") { self.microsoft = $0 }
        if ok, let email = microsoftEmail { UserDefaults.standard.set(email, forKey: Self.microsoftEmailKey) }
        return ok && microsoftConnected
    }

    func disconnectMicrosoft() async {
        OrbitLog.log("microsoft", "Disconnect pressed")
        try? await microsoft?.signOut()
        UserDefaults.standard.removeObject(forKey: Self.microsoftEmailKey)
        microsoftError = nil
        await refreshStatus()
    }

    private func setProgress(_ account: String, _ text: String?) {
        if account == "google" { googleProgress = text } else { microsoftProgress = text }
    }

    private func setError(_ account: String, _ text: String?) {
        if account == "google" { googleError = text } else { microsoftError = text }
        if let text { OrbitLog.log(account, "Error shown to user: \(text)") }
    }

    /// Runs the web sign-in and stores the tokens. Returns true on success.
    private func signIn(config: OAuthConfig, account: String, label: String, assign: (OAuthSession) -> Void) async -> Bool {
        busy = account
        setProgress(account, "Waiting for \(label)… finish signing in in the window that opened.")
        defer {
            busy = nil
            setProgress(account, nil)
        }
        var succeeded = false
        do {
            let client = OAuthClient(config: config)
            let authenticator = WebAuthenticator(callbackScheme: config.callbackScheme ?? "orbit")
            let tokens = try await client.signIn(using: authenticator)
            setProgress(account, "Saving your \(label) sign-in…")
            let session = OAuthSession(account: account, client: client, store: tokenStore)
            do {
                try await session.signIn(with: tokens)
            } catch {
                OrbitLog.log(account, "Couldn't save tokens anywhere: \(error)")
                throw error
            }
            assign(session)
            setError(account, nil)
            succeeded = true
        } catch OAuthError.cancelled {
            OrbitLog.log(account, "Sign-in cancelled")
            setError(account, "Sign-in was cancelled. Press Connect to try again.")
        } catch OAuthError.couldNotStart {
            setError(account, "Orbit couldn't open the \(label) sign-in window. Bring Orbit's main window to the front and try again.")
        } catch let error as OAuthError {
            if case .provider(let code, let description) = error,
               code.contains("consent") || (description ?? "").localizedCaseInsensitiveContains("admin") {
                setError(account, "Exeter needs an admin to approve this. No problem: use Apple Mail and Calendar instead (the Exeter step).")
            } else {
                setError(account, "\(label) sign-in failed: \(error)")
            }
        } catch {
            setError(account, "\(label) sign-in failed: \(error.localizedDescription)")
        }
        await refreshStatus()
        OrbitLog.log(account, "Sign-in finished: \(succeeded ? "connected" : "not connected")")
        return succeeded
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
