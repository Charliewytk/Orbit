#if canImport(AuthenticationServices)
import Foundation
import AuthenticationServices
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Shows the provider's sign-in page in a system web sheet
/// (`ASWebAuthenticationSession`) and returns the redirect URL.
/// Works on macOS and iOS; not available in app extensions.
@available(iOSApplicationExtension, unavailable)
@available(macOSApplicationExtension, unavailable)
@MainActor
public final class WebAuthenticator: NSObject, ASWebAuthenticationPresentationContextProviding {
    /// Default URL scheme to watch for, e.g. "com.orbit.app".
    public var callbackScheme: String
    /// true → don't share cookies with Safari (always shows a fresh login).
    public var prefersEphemeralSession: Bool
    private var session: ASWebAuthenticationSession?

    public init(callbackScheme: String = "com.orbit.app", prefersEphemeralSession: Bool = false) {
        self.callbackScheme = callbackScheme
        self.prefersEphemeralSession = prefersEphemeralSession
        super.init()
    }

    /// Authenticators with a sheet open. Keeps each one (and its session) alive
    /// until the sheet finishes, even if the caller drops its reference.
    private static var active: Set<WebAuthenticator> = []

    /// Opens `url` and waits for the redirect back to `callbackScheme`.
    public func authenticate(url: URL, callbackScheme scheme: String? = nil) async throws -> URL {
        let watched = scheme ?? callbackScheme
        OrbitLog.log("auth", "Opening sign-in sheet for \(url.host ?? "?") (callback scheme \(watched))")
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            var resumed = false
            let finish: (Result<URL, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                cont.resume(with: result)
            }
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: watched) { callbackURL, error in
                // Not guaranteed to arrive on the main thread on every macOS version.
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    self.session = nil
                    Self.active.remove(self)
                    if let error {
                        if let authError = error as? ASWebAuthenticationSessionError, authError.code == .canceledLogin {
                            OrbitLog.log("auth", "Sign-in sheet closed by the user")
                            finish(.failure(OAuthError.cancelled))
                        } else {
                            OrbitLog.log("auth", "Sign-in sheet failed: \(error.localizedDescription) (\(error))")
                            finish(.failure(error))
                        }
                        return
                    }
                    guard let callbackURL else {
                        OrbitLog.log("auth", "Sign-in sheet returned no URL")
                        finish(.failure(OAuthError.invalidCallback("empty")))
                        return
                    }
                    OrbitLog.log("auth", "Sign-in sheet returned to \(callbackURL.scheme ?? "?"):\(callbackURL.path)")
                    finish(.success(callbackURL))
                } }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = prefersEphemeralSession
            self.session = session
            Self.active.insert(self)
            #if canImport(AppKit) && !canImport(UIKit)
            // A menu-bar or background app would otherwise open the sheet behind other apps.
            NSApplication.shared.activate(ignoringOtherApps: true)
            #endif
            if session.start() {
                OrbitLog.log("auth", "Sign-in sheet started")
            } else {
                OrbitLog.log("auth", "ASWebAuthenticationSession.start() returned false")
                self.session = nil
                Self.active.remove(self)
                finish(.failure(OAuthError.couldNotStart))
            }
        }
    }

    public func cancel() {
        session?.cancel()
        session = nil
        Self.active.remove(self)
    }

    // MARK: ASWebAuthenticationPresentationContextProviding

    public nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // AuthenticationServices always asks on the main thread.
        MainActor.assumeIsolated { Self.currentAnchor() }
    }

    private static func currentAnchor() -> ASPresentationAnchor {
        #if canImport(UIKit)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let key = scenes.flatMap(\.windows).first(where: \.isKeyWindow) { return key }
        if let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first {
            return scene.windows.first ?? UIWindow(windowScene: scene)
        }
        return ASPresentationAnchor()
        #else
        let app = NSApplication.shared
        // Prefer a real, visible document window over panels and the menu-bar popover.
        let visible = app.windows.filter { $0.isVisible && !$0.isMiniaturized }
        if let key = app.keyWindow, key.isVisible { return key }
        if let main = app.mainWindow, main.isVisible { return main }
        if let window = visible.first(where: { $0.canBecomeMain }) ?? visible.first(where: { $0.canBecomeKey }) {
            return window
        }
        OrbitLog.log("auth", "No visible window to anchor the sign-in sheet; using a standalone window")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.center()
        return window
        #endif
    }
}

@available(iOSApplicationExtension, unavailable)
@available(macOSApplicationExtension, unavailable)
extension OAuthClient {
    /// Full interactive sign-in: web sheet → code → tokens.
    @MainActor
    public func signIn(using authenticator: WebAuthenticator, loginHint: String? = nil) async throws -> OAuthTokens {
        let request = authorizationRequest(loginHint: loginHint)
        OrbitLog.log("auth", "\(config.provider.rawValue): redirect URI \(config.redirectURI), scopes \(config.scopes.joined(separator: " "))")
        let callback = try await authenticator.authenticate(url: request.url, callbackScheme: config.callbackScheme)
        let code: String
        do {
            code = try self.code(from: callback, expecting: request.state)
        } catch {
            OrbitLog.log("auth", "\(config.provider.rawValue): callback rejected: \(error)")
            throw error
        }
        OrbitLog.log("auth", "\(config.provider.rawValue): got authorisation code, exchanging for tokens")
        do {
            let tokens = try await exchange(code: code, pkce: request.pkce)
            OrbitLog.log("auth", "\(config.provider.rawValue): token exchange OK (refresh token: \(tokens.refreshToken != nil ? "yes" : "no"), id token: \(tokens.idToken != nil ? "yes" : "no"), scope: \(tokens.scope ?? "-"))")
            return tokens
        } catch {
            OrbitLog.log("auth", "\(config.provider.rawValue): token exchange failed: \(error)")
            throw error
        }
    }
}
#endif
