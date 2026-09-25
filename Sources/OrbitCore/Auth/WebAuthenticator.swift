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

    /// Opens `url` and waits for the redirect back to `callbackScheme`.
    public func authenticate(url: URL, callbackScheme scheme: String? = nil) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme ?? callbackScheme) {
                [weak self] callbackURL, error in
                Task { @MainActor in self?.session = nil }
                if let error {
                    if let authError = error as? ASWebAuthenticationSessionError, authError.code == .canceledLogin {
                        cont.resume(throwing: OAuthError.cancelled)
                    } else {
                        cont.resume(throwing: error)
                    }
                    return
                }
                guard let callbackURL else {
                    cont.resume(throwing: OAuthError.invalidCallback("empty"))
                    return
                }
                cont.resume(returning: callbackURL)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = prefersEphemeralSession
            self.session = session
            if !session.start() {
                self.session = nil
                cont.resume(throwing: OAuthError.couldNotStart)
            }
        }
    }

    public func cancel() {
        session?.cancel()
        session = nil
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
        return NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow
            ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
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
        let callback = try await authenticator.authenticate(url: request.url, callbackScheme: config.callbackScheme)
        let code = try code(from: callback, expecting: request.state)
        return try await exchange(code: code, pkce: request.pkce)
    }
}
#endif
