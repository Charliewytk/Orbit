import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OrbitCore

/// Canned HTTP responses for the mail clients. Routes match on a substring of the
/// (percent-decoded) URL, first match wins; `once` routes are used up after one hit.
final class EmailStubTransport: HTTPTransport, @unchecked Sendable {
    struct Route { var method: String?; var match: String; var status: Int; var body: String; var once: Bool }

    private let lock = NSLock()
    private var routes: [Route] = []
    private var _requests: [URLRequest] = []

    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    func on(_ method: String? = nil, _ match: String, status: Int = 200, json: String, once: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        routes.append(Route(method: method, match: match, status: status, body: json, once: once))
    }

    func requests(matching s: String) -> [URLRequest] {
        requests.filter { Self.urlString($0).contains(s) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = Self.urlString(request)
        let method = request.httpMethod ?? "GET"
        let route: Route? = lock.withLock {
            _requests.append(request)
            let index = routes.firstIndex { ($0.method == nil || $0.method == method) && url.contains($0.match) }
            let route = index.map { routes[$0] }
            if let index, routes[index].once { routes.remove(at: index) }
            return route
        }
        guard let route else {
            return (Data("{\"error\":\"no stub for \(method) \(url)\"}".utf8), response(request, 599))
        }
        return (Data(route.body.utf8), response(request, route.status))
    }

    private func response(_ r: URLRequest, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: r.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    static func urlString(_ r: URLRequest) -> String {
        let s = r.url?.absoluteString ?? ""
        return s.removingPercentEncoding ?? s
    }
}

/// An in-memory mailbox for coordinator tests.
final class EmailStubProvider: MailProvider, @unchecked Sendable {
    let account: MailAccount
    let providerID: String
    private let lock = NSLock()
    private var batches: [[EmailMessage]]
    private var failure: Error?
    private(set) var cursorsSeen: [String?] = []
    private(set) var drafts: [(String, String)] = []

    init(account: MailAccount, id: String? = nil, batches: [[EmailMessage]], failure: Error? = nil) {
        self.account = account; self.providerID = id ?? account.rawValue
        self.batches = batches; self.failure = failure
    }

    func fetchNew(since cursor: String?) async throws -> (messages: [EmailMessage], cursor: String?) {
        try lock.withLock {
            cursorsSeen.append(cursor)
            if let failure { throw failure }
            let batch = batches.isEmpty ? [] : batches.removeFirst()
            return (batch, "c\(cursorsSeen.count)")
        }
    }

    func fetchMessage(id: String) async throws -> EmailMessage { throw MailError.notFound(id) }

    func createDraft(replyTo message: EmailMessage, body: String) async throws -> String {
        lock.withLock { drafts.append((message.id, body)) }
        return "draft-\(message.id)"
    }
}

enum EmailFixtures {
    static func message(id: String, account: MailAccount = .gmail, from: String = "friend@example.com",
                        name: String? = "Sam Friend", subject: String = "Hello", body: String = "Just saying hi.",
                        labels: [String] = []) -> EmailMessage {
        EmailMessage(id: id, account: account, from: from, fromName: name, to: ["me@example.com"],
                     subject: subject, snippet: String(body.prefix(100)), body: body,
                     date: Date(timeIntervalSince1970: 1_790_000_000), labels: labels)
    }

    /// Gmail-style base64url without padding.
    static func b64url(_ s: String) -> String { MIMEParser.encodeBase64URL(Data(s.utf8)) }
}
