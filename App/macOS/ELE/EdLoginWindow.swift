import AppKit
import Foundation
import WebKit
import OrbitCore

/// Ed Discussion sign-in. Ed's web app keeps its API token in localStorage, so
/// after the student signs in (Exeter SSO) Orbit reads it from the page, checks
/// it against /api/user and keeps it in the Keychain. The token never goes in
/// the log. The web view uses the persistent default store, so a later silent
/// refresh (`EdTokenHarvester`) can pick up a renewed token without a window.
enum EdWeb {
    /// Settings → Uni → Ed region (US by default: that's where Exeter's courses are).
    static let regionKey = "features.ed.region"
    static var region: EdRegion {
        UserDefaults.standard.string(forKey: regionKey).flatMap(EdRegion.init(rawValue:)) ?? .default
    }
    static var loginURL: URL { region.loginURL }
    static var dashboardURL: URL { region.dashboardURL }

    /// Every localStorage entry whose key mentions a token: {key: value}.
    static let tokenScript = """
    const out = {};
    try {
      for (let i = 0; i < localStorage.length; i++) {
        const k = localStorage.key(i);
        if (/token/i.test(k)) out[k] = localStorage.getItem(k) || '';
      }
    } catch (e) {}
    return out;
    """

    /// Likely tokens, best first ("authToken" before anything else).
    static func candidates(_ raw: Any?) -> [String] {
        guard let dict = raw as? [String: Any] else { return [] }
        let ranked = dict.keys.sorted { a, b in
            func rank(_ k: String) -> Int { k == "authToken" ? 0 : k.lowercased().contains("authtoken") ? 1 : 2 }
            return (rank(a), a) < (rank(b), b)
        }
        var out: [String] = []
        for key in ranked {
            guard var value = dict[key] as? String else { continue }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \n"))
            guard value.count >= 16, value.count <= 4096,
                  value.range(of: "^[A-Za-z0-9._\\-]+$", options: .regularExpression) != nil else { continue }
            if !out.contains(value) { out.append(value) }
        }
        return out
    }

    /// The first candidate Ed accepts, with the signed-in user.
    static func validate(_ candidates: [String]) async -> (token: String, user: EdUserResponse)? {
        for token in candidates {
            if let user = try? await EdClient(token: token, tokenKind: .session, region: region).user() {
                return (token, user)
            }
        }
        return nil
    }
}

/// A window with Ed's real login page. Closes itself once a working token is found.
@MainActor
final class EdLoginWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private let webView: WKWebView
    private let status = NSTextField(labelWithString: "Sign in to Ed with your Exeter account. This window closes by itself when you're in.")
    private var waiters: [CheckedContinuation<(String, EdUserResponse)?, Never>] = []
    private var outcome: (String, EdUserResponse)??
    private var poll: Task<Void, Never>?
    private var checking = false

    init() {
        webView = WKWebView(frame: .zero, configuration: ELEWebSession.makeConfiguration())
        webView.customUserAgent = ELEWebSession.userAgent
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Sign in to Ed Discussion"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 520)
        super.init(window: window)

        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        let bar = NSStackView(views: [status])
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        let stack = NSStackView(views: [bar, webView])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        webView.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = stack
        NSLayoutConstraint.activate([
            webView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.load(URLRequest(url: EdWeb.loginURL))
        // Ed is a single-page app: after SSO it routes without a full navigation, so also poll.
        poll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.checkToken()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The token and user, or nil if the window was closed first.
    func result() async -> (String, EdUserResponse)? {
        if let outcome { return outcome }
        return await withCheckedContinuation { waiters.append($0) }
    }

    private func complete(_ value: (String, EdUserResponse)?) {
        guard outcome == nil else { return }
        outcome = .some(value)
        poll?.cancel()
        waiters.forEach { $0.resume(returning: value) }
        waiters = []
    }

    private func checkToken() {
        guard outcome == nil, !checking, let host = webView.url?.host, host.hasSuffix("edstem.org") else { return }
        checking = true
        Task { @MainActor in
            defer { checking = false }
            let raw = try? await webView.callAsyncJavaScript(EdWeb.tokenScript, arguments: [:], in: nil, contentWorld: .page)
            let candidates = EdWeb.candidates(raw)
            guard !candidates.isEmpty, outcome == nil else { return }
            guard let found = await EdWeb.validate(candidates) else { return }
            status.stringValue = "Signed in to Ed as \(found.user.user.name). Reading your courses…"
            status.textColor = .systemGreen
            try? await Task.sleep(for: .milliseconds(900))
            complete((found.token, found.user))
            close()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        checkToken()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let host = webView.url?.host {
            status.stringValue = host.contains("microsoft") ? "Signing in with Exeter Microsoft (MFA may be needed)…"
                : host.hasSuffix("edstem.org") ? "Loading Ed…" : "Signing in…"
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func windowWillClose(_ notification: Notification) {
        complete(nil)
    }
}

/// Reads a fresh token from Ed's page in a hidden web view (same cookies and
/// storage as the login window), for when the stored one has expired.
@MainActor
final class EdTokenHarvester: NSObject, WKNavigationDelegate {
    private var view: WKWebView?
    private var waiter: NavigationWaiter?

    func harvest() async -> (token: String, user: EdUserResponse)? {
        let web = view ?? WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900), configuration: ELEWebSession.makeConfiguration())
        web.customUserAgent = ELEWebSession.userAgent
        web.navigationDelegate = self
        view = web
        let w = NavigationWaiter()
        waiter = w
        web.load(URLRequest(url: EdWeb.dashboardURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 40))
        let timeout = Task { @MainActor [weak w] in
            try? await Task.sleep(for: .seconds(40))
            w?.finish(.failure(CancellationError()))
        }
        defer { timeout.cancel() }
        guard (try? await w.wait()) != nil else { return nil }
        for _ in 0..<5 {
            try? await Task.sleep(for: .seconds(2))
            let raw = try? await web.callAsyncJavaScript(EdWeb.tokenScript, arguments: [:], in: nil, contentWorld: .page)
            let candidates = EdWeb.candidates(raw)
            if !candidates.isEmpty, let found = await EdWeb.validate(candidates) { return found }
        }
        return nil
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { waiter?.finish(.success(())) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { waiter?.finish(ELEWebSession.isCancel(error) ? .success(()) : .failure(error)) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            if ELEWebSession.isCancel(error) { return }
            waiter?.finish(.failure(error))
        }
    }
}
