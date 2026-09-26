import AppKit
import Foundation
import OrbitCore
import WebKit

/// ELE through the website, like a logged-in browser.
///
/// Sign-in happens in a normal window with a WKWebView (Exeter Microsoft SSO
/// and MFA work there). Cookies live in the persistent default website data
/// store, so re-login is rare. Syncing then uses a hidden WKWebView on the same
/// store: it loads /my/ once, reads `M.cfg.sesskey`, and runs `fetch()` inside
/// the page so every request carries the session cookies.
@MainActor
final class ELEWebSession: NSObject {
    static let home = URL(string: "https://ele.exeter.ac.uk/my/")!
    static let host = "ele.exeter.ac.uk"
    /// A normal Safari user agent: some SSO pages refuse "embedded browser" agents.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    enum SessionError: LocalizedError {
        case notSignedIn
        case http(Int, String)
        case script(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .notSignedIn: "ELE needs you to sign in again."
            case let .http(code, url): "ELE returned HTTP \(code) for \(url)"
            case let .script(s): "ELE page script failed: \(s)"
            case .timeout: "ELE took too long to respond."
            }
        }
    }

    private var worker: WKWebView?
    private var workerReadyAt: Date?
    private(set) var sesskey: String?
    private var navigationWaiter: NavigationWaiter?
    private var loginController: ELELoginWindowController?

    // MARK: Configuration

    static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        return config
    }

    // MARK: Sign-in window

    /// Shows the ELE login window and returns true once the dashboard loads with a session.
    func signIn() async -> Bool {
        if let existing = loginController {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return await existing.result()
        }
        let controller = ELELoginWindowController()
        loginController = controller
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let ok = await controller.result()
        loginController = nil
        if ok {
            // Force the worker to pick up the new cookies.
            sesskey = nil
            workerReadyAt = nil
        }
        return ok
    }

    /// Clears ELE and Microsoft cookies (sign out).
    func signOut() async {
        sesskey = nil
        workerReadyAt = nil
        worker = nil
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let matching = records.filter { r in
            ["exeter.ac.uk", "microsoftonline.com", "microsoft.com", "live.com", "msauth.net", "msftauth.net"]
                .contains { r.displayName.contains($0) }
        }
        await store.removeData(ofTypes: types, for: matching)
    }

    // MARK: Worker

    private func makeWorker() -> WKWebView {
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900), configuration: Self.makeConfiguration())
        view.customUserAgent = Self.userAgent
        view.navigationDelegate = self
        return view
    }

    /// Loads the dashboard in the hidden web view and reads the session key.
    /// Throws `.notSignedIn` if ELE sends us to the login page.
    @discardableResult
    func prepare(force: Bool = false) async throws -> String {
        if !force, let key = sesskey, let at = workerReadyAt, Date().timeIntervalSince(at) < 20 * 60 { return key }
        let view = worker ?? makeWorker()
        worker = view
        try await load(Self.home, in: view)
        guard let url = view.url, url.host == Self.host, !url.path.hasPrefix("/login") else {
            sesskey = nil
            throw SessionError.notSignedIn
        }
        let key = try await view.callAsyncJavaScript(
            "return (typeof M !== 'undefined' && M.cfg && M.cfg.sesskey) ? M.cfg.sesskey : '';",
            arguments: [:], in: nil, contentWorld: .page) as? String ?? ""
        guard !key.isEmpty else { sesskey = nil; throw SessionError.notSignedIn }
        sesskey = key
        workerReadyAt = Date()
        return key
    }

    private func load(_ url: URL, in view: WKWebView) async throws {
        navigationWaiter?.finish(.failure(CancellationError()))
        let waiter = NavigationWaiter()
        navigationWaiter = waiter
        view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60))
        let timeout = Task { @MainActor [weak waiter] in
            try? await Task.sleep(for: .seconds(60))
            waiter?.finish(.failure(SessionError.timeout))
        }
        defer { timeout.cancel() }
        try await waiter.wait()
        // SSO bounces through several redirects; a JS redirect may follow didFinish.
        try? await Task.sleep(for: .milliseconds(400))
    }

    private func page() async throws -> WKWebView {
        try await prepare()
        guard let worker else { throw SessionError.notSignedIn }
        return worker
    }

    // MARK: Fetching

    /// GETs a page with the session cookies and returns its text.
    func fetchText(_ url: URL) async throws -> String {
        let view = try await page()
        let js = """
        try {
          const r = await fetch(url, {credentials: 'include', redirect: 'follow'});
          const t = await r.text();
          return {status: r.status, url: r.url, text: t};
        } catch (e) { return {status: 0, url: url, text: '', error: String(e)}; }
        """
        let result = try await view.callAsyncJavaScript(js, arguments: ["url": url.absoluteString], in: nil, contentWorld: .page)
        let dict = result as? [String: Any] ?? [:]
        let status = (dict["status"] as? NSNumber)?.intValue ?? 0
        let finalURL = dict["url"] as? String ?? ""
        let text = dict["text"] as? String ?? ""
        try checkSession(status: status, finalURL: finalURL, text: text, error: dict["error"] as? String)
        guard (200..<400).contains(status) else { throw SessionError.http(status, url.absoluteString) }
        return text
    }

    /// Downloads a file (base64 through JS) and returns its bytes and content type.
    func fetchData(_ url: URL) async throws -> (data: Data, contentType: String, finalURL: String) {
        let view = try await page()
        let js = """
        try {
          const r = await fetch(url, {credentials: 'include', redirect: 'follow'});
          const type = r.headers.get('content-type') || '';
          const bytes = new Uint8Array(await r.arrayBuffer());
          let s = '';
          for (let i = 0; i < bytes.length; i += 0x8000) {
            s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
          }
          return {status: r.status, url: r.url, type: type, data: btoa(s)};
        } catch (e) { return {status: 0, url: url, type: '', data: '', error: String(e)}; }
        """
        let result = try await view.callAsyncJavaScript(js, arguments: ["url": url.absoluteString], in: nil, contentWorld: .page)
        let dict = result as? [String: Any] ?? [:]
        let status = (dict["status"] as? NSNumber)?.intValue ?? 0
        let finalURL = dict["url"] as? String ?? ""
        let type = dict["type"] as? String ?? ""
        let data = Data(base64Encoded: dict["data"] as? String ?? "") ?? Data()
        if type.contains("text/html") {
            try checkSession(status: status, finalURL: finalURL, text: String(decoding: data.prefix(100_000), as: UTF8.self),
                             error: dict["error"] as? String)
        } else {
            try checkSession(status: status, finalURL: finalURL, text: "", error: dict["error"] as? String)
        }
        guard (200..<400).contains(status) else { throw SessionError.http(status, url.absoluteString) }
        return (data, type, finalURL)
    }

    /// HEAD request (redirects followed): the final file URL, ETag, Last-Modified and size,
    /// so unchanged files aren't downloaded again.
    func head(_ url: URL) async throws -> ResourceCache.Head {
        let view = try await page()
        let js = """
        try {
          const r = await fetch(url, {method: 'HEAD', credentials: 'include', redirect: 'follow'});
          return {status: r.status, url: r.url, type: r.headers.get('content-type') || '',
                  etag: r.headers.get('etag') || '', modified: r.headers.get('last-modified') || '',
                  length: r.headers.get('content-length') || ''};
        } catch (e) { return {status: 0, url: url, error: String(e)}; }
        """
        let result = try await view.callAsyncJavaScript(js, arguments: ["url": url.absoluteString], in: nil, contentWorld: .page)
        let dict = result as? [String: Any] ?? [:]
        let status = (dict["status"] as? NSNumber)?.intValue ?? 0
        let finalURL = dict["url"] as? String ?? url.absoluteString
        try checkSession(status: status, finalURL: finalURL, text: "", error: dict["error"] as? String)
        guard (200..<400).contains(status) else { throw SessionError.http(status, url.absoluteString) }
        func nonEmpty(_ key: String) -> String? {
            let s = (dict[key] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            return s.isEmpty ? nil : s
        }
        return ResourceCache.Head(finalURL: finalURL, etag: nonEmpty("etag"), lastModified: nonEmpty("modified"),
                                  bytes: nonEmpty("length").flatMap(Int.init), contentType: nonEmpty("type") ?? "")
    }

    /// Calls one Moodle AJAX function (POST /lib/ajax/service.php) and returns the raw response.
    func ajax(_ method: String, args: [String: Any]) async throws -> Data {
        let key = try await prepare()
        let view = try await page()
        let body = String(decoding: ELEWebParser.ajaxBody(method: method, args: args), as: UTF8.self)
        let js = """
        try {
          const r = await fetch(url, {method: 'POST', credentials: 'include',
                                      headers: {'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest'},
                                      body: body});
          return {status: r.status, url: r.url, text: await r.text()};
        } catch (e) { return {status: 0, url: url, text: '', error: String(e)}; }
        """
        let url = ELEWebParser.ajaxURL(sesskey: key, method: method).absoluteString
        let result = try await view.callAsyncJavaScript(js, arguments: ["url": url, "body": body], in: nil, contentWorld: .page)
        let dict = result as? [String: Any] ?? [:]
        let status = (dict["status"] as? NSNumber)?.intValue ?? 0
        let text = dict["text"] as? String ?? ""
        try checkSession(status: status, finalURL: dict["url"] as? String ?? "", text: text, error: dict["error"] as? String)
        do {
            _ = try ELEWebParser.ajaxData(Data(text.utf8))
        } catch ELEWebError.sessionExpired {
            // Maybe only the sesskey went stale: reload the dashboard once before giving up.
            sesskey = nil
            workerReadyAt = nil
            throw SessionError.notSignedIn
        } catch {
            // Other Moodle errors are left for the parser to report.
        }
        return Data(text.utf8)
    }

    private func checkSession(status: Int, finalURL: String, text: String, error: String?) throws {
        let lower = finalURL.lowercased()
        if lower.contains("/login/") || lower.contains("login.microsoftonline.com") || lower.contains("/auth/") {
            sesskey = nil; throw SessionError.notSignedIn
        }
        if !text.isEmpty, ELEWebParser.looksLikeLoginPage(text) { sesskey = nil; throw SessionError.notSignedIn }
        // A cross-origin redirect to Microsoft makes fetch() throw a TypeError.
        if status == 0, let error, error.contains("TypeError") || error.contains("Load failed") {
            sesskey = nil; throw SessionError.notSignedIn
        }
        if status == 0, let error { throw SessionError.script(error) }
    }
}

extension ELEWebSession: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { navigationWaiter?.finish(.success(())) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { navigationWaiter?.finish(Self.isCancel(error) ? .success(()) : .failure(error)) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            // -999 happens when a redirect replaces the load; wait for the next didFinish.
            if Self.isCancel(error) { return }
            navigationWaiter?.finish(.failure(error))
        }
    }

    nonisolated static func isCancel(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }
}

/// Resumes once when a navigation finishes, fails or times out.
@MainActor
final class NavigationWaiter {
    private var continuation: CheckedContinuation<Void, Error>?
    private var pending: Result<Void, Error>?

    func wait() async throws {
        if let pending { return try pending.get() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            if let pending { c.resume(with: pending) } else { continuation = c }
        }
    }

    func finish(_ result: Result<Void, Error>) {
        guard pending == nil else { return }
        pending = result
        continuation?.resume(with: result)
        continuation = nil
    }
}

// MARK: - Login window

/// A window with ELE's real login page. Closes itself once the dashboard shows a session.
@MainActor
final class ELELoginWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private let webView: WKWebView
    private let status = NSTextField(labelWithString: "Sign in with your Exeter account. This window closes by itself when you're in.")
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var outcome: Bool?

    init() {
        webView = WKWebView(frame: .zero, configuration: ELEWebSession.makeConfiguration())
        webView.customUserAgent = ELEWebSession.userAgent
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Sign in to ELE"
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
        webView.load(URLRequest(url: ELEWebSession.home))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func result() async -> Bool {
        if let outcome { return outcome }
        return await withCheckedContinuation { waiters.append($0) }
    }

    private func complete(_ ok: Bool) {
        guard outcome == nil else { return }
        outcome = ok
        waiters.forEach { $0.resume(returning: ok) }
        waiters = []
    }

    // Logged in = on ele.exeter.ac.uk/my/ with a Moodle session key.
    private func checkLoggedIn() {
        guard outcome == nil, let url = webView.url, url.host == ELEWebSession.host, url.path.hasPrefix("/my") else { return }
        Task { @MainActor in
            let key = try? await webView.callAsyncJavaScript(
                "return (typeof M !== 'undefined' && M.cfg && M.cfg.sesskey) ? M.cfg.sesskey : '';",
                arguments: [:], in: nil, contentWorld: .page) as? String
            guard let key, !key.isEmpty, outcome == nil else { return }
            status.stringValue = "✓ Signed in to ELE. Fetching your modules…"
            status.textColor = .systemGreen
            try? await Task.sleep(for: .milliseconds(900))
            complete(true)
            close()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        checkLoggedIn()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let host = webView.url?.host {
            status.stringValue = host.contains("microsoft") ? "Signing in with Exeter Microsoft (MFA may be needed)…"
                : host == ELEWebSession.host ? "Loading ELE…" : "Signing in…"
        }
    }

    // Microsoft sometimes opens pop-ups; keep them in this window.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func windowWillClose(_ notification: Notification) {
        complete(false)
    }
}
