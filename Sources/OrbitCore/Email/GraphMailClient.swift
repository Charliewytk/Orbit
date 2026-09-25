import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Exeter (Microsoft 365) mail through Microsoft Graph.
///
/// Uses the inbox delta query: the first sync pulls the last two weeks and every
/// page is followed until Graph returns a `@odata.deltaLink`, which is stored as
/// the cursor. Later syncs just GET that link. If Graph says the sync state has
/// expired, it starts again from scratch. Bodies are requested as plain text via
/// `Prefer: outlook.body-content-type="text"`.
///
/// Uses the same Exeter sign-in as OneNote. If the university blocks third-party
/// apps, use `AppleMailReader` instead.
public struct GraphMailClient: MailProvider {
    public let account: MailAccount = .exeter
    public var providerID: String { "exeter-graph" }
    public var http: HTTPClient
    public var tokens: AccessTokenProvider
    public var baseURL: URL
    /// How far back the first sync looks.
    public var initialLookback: TimeInterval
    public var pageSize: Int
    /// Safety cap on pages per sync. If hit, the next page link becomes the cursor.
    public var maxPages: Int

    /// Delegated permissions: read mail, save drafts and mark read.
    public static let scopes = ["Mail.ReadWrite", "offline_access"]
    static let selectFields = "id,conversationId,subject,bodyPreview,body,from,toRecipients,ccRecipients,receivedDateTime,isRead,categories"

    public init(tokens: AccessTokenProvider, http: HTTPClient = HTTPClient(),
                baseURL: URL = URL(string: "https://graph.microsoft.com/v1.0")!,
                initialLookback: TimeInterval = 14 * 86_400, pageSize: Int = 50, maxPages: Int = 40) {
        self.tokens = tokens; self.http = http; self.baseURL = baseURL
        self.initialLookback = initialLookback; self.pageSize = pageSize; self.maxPages = maxPages
    }

    // MARK: Sync

    public func fetchNew(since cursor: String?) async throws -> (messages: [EmailMessage], cursor: String?) {
        let headers = try await headers()
        if let cursor, let link = URL(string: cursor) {
            do {
                return try await follow(link, headers: headers)
            } catch let error as HTTPError where Self.isExpiredSyncState(error) {
                // Delta token expired: fall through to a full sync.
            }
        }
        return try await follow(initialDeltaURL(now: Date()), headers: headers)
    }

    func initialDeltaURL(now: Date) -> URL {
        let since = ISO8601.string(now.addingTimeInterval(-initialLookback))
        var c = URLComponents(url: baseURL.appendingPathComponent("me/mailFolders/inbox/messages/delta"),
                              resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "$select", value: Self.selectFields),
            URLQueryItem(name: "$filter", value: "receivedDateTime ge \(since)"),
            URLQueryItem(name: "$orderby", value: "receivedDateTime desc"),
        ]
        return c.url!
    }

    /// Follows `@odata.nextLink` pages until a delta link (the next cursor) appears.
    func follow(_ start: URL, headers: [String: String]) async throws -> (messages: [EmailMessage], cursor: String?) {
        var byID: [String: EmailMessage] = [:]
        var order: [String] = []
        var next: URL? = start
        var pages = 0
        while let url = next {
            let page = try await http.get(DeltaPage.self, url, headers: headers)
            for m in page.value {
                if m.removed != nil { byID[m.id] = nil; continue }
                if byID[m.id] == nil { order.append(m.id) }
                byID[m.id] = Self.emailMessage(from: m)
            }
            if let delta = page.deltaLink {
                return (order.compactMap { byID[$0] }, delta)
            }
            next = page.nextLink.flatMap(URL.init(string:))
            pages += 1
            if pages >= maxPages, let resume = next {
                return (order.compactMap { byID[$0] }, resume.absoluteString)
            }
        }
        throw MailError.badResponse("Graph delta ended without a deltaLink")
    }

    public func fetchMessage(id: String) async throws -> EmailMessage {
        var c = URLComponents(url: messageURL(id), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "$select", value: Self.selectFields)]
        let m = try await http.get(GraphMessage.self, c.url!, headers: try await headers())
        return Self.emailMessage(from: m)
    }

    // MARK: Drafts and flags

    /// Creates a reply draft (Graph fills in recipients, subject and threading),
    /// then puts `body` above the quoted original.
    public func createDraft(replyTo message: EmailMessage, body: String) async throws -> String {
        let headers = try await headers()
        let draft = try await http.json(
            GraphMessage.self, "POST", messageURL(message.id, "/createReply"),
            headers: headers, body: Data("{}".utf8))
        let quoted = draft.body?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = quoted.isEmpty ? body : body + "\n\n" + quoted
        let patch = try HTTPClient.encoder.encode(BodyPatch(body: .init(contentType: "Text", content: text)))
        var h = headers
        h["Content-Type"] = "application/json"
        _ = try await http.data("PATCH", messageURL(draft.id), headers: h, body: patch)
        return draft.id
    }

    public func markRead(id: String) async throws {
        var h = try await headers()
        h["Content-Type"] = "application/json"
        _ = try await http.data("PATCH", messageURL(id), headers: h,
                                body: Data("{\"isRead\":true}".utf8))
    }

    // MARK: Decoding

    static func emailMessage(from m: GraphMessage) -> EmailMessage {
        let raw = m.body?.content ?? ""
        let body = m.body?.contentType.lowercased() == "html" ? HTMLToText.convert(raw) : raw
        let preview = m.bodyPreview ?? ""
        return EmailMessage(
            id: m.id, account: .exeter, threadID: m.conversationId,
            from: m.from?.emailAddress.address ?? "", fromName: m.from?.emailAddress.name,
            to: ((m.toRecipients ?? []) + (m.ccRecipients ?? [])).compactMap(\.emailAddress.address),
            subject: m.subject ?? "", snippet: preview.isEmpty ? MIMEParser.snippet(body) : preview,
            body: body.replacingOccurrences(of: "\r\n", with: "\n"),
            date: m.receivedDateTime.flatMap(ISO8601.parse) ?? Date(),
            isUnread: !(m.isRead ?? false), labels: m.categories ?? []
        )
    }

    /// Graph reports an expired delta token as 410 Gone, or 400 with a sync-state error code.
    static func isExpiredSyncState(_ e: HTTPError) -> Bool {
        if e.status == 410 { return true }
        let b = e.body.lowercased()
        return e.status == 400 && (b.contains("syncstate") || b.contains("resyncrequired") || b.contains("invaliddeltatoken"))
    }

    // MARK: Plumbing

    private func headers() async throws -> [String: String] {
        [
            "Authorization": "Bearer \(try await tokens.accessToken())",
            "Prefer": "outlook.body-content-type=\"text\", odata.maxpagesize=\(pageSize)",
        ]
    }

    /// `/me/messages/{id}`, with the ID escaped (Graph IDs can contain "/" and "+").
    func messageURL(_ id: String, _ suffix: String = "") -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/+")
        let escaped = id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
        return URL(string: baseURL.absoluteString + "/me/messages/" + escaped + suffix)!
    }

    struct Recipient: Decodable {
        struct Address: Decodable { let name: String?; let address: String? }
        let emailAddress: Address
    }

    struct GraphMessage: Decodable {
        struct Body: Decodable { let contentType: String; let content: String }
        struct Removed: Decodable { let reason: String? }
        let id: String
        let conversationId: String?
        let subject: String?
        let bodyPreview: String?
        let body: Body?
        let from: Recipient?
        let toRecipients: [Recipient]?
        let ccRecipients: [Recipient]?
        let receivedDateTime: String?
        let isRead: Bool?
        let categories: [String]?
        let removed: Removed?

        enum CodingKeys: String, CodingKey {
            case id, conversationId, subject, bodyPreview, body, from, toRecipients, ccRecipients
            case receivedDateTime, isRead, categories
            case removed = "@removed"
        }
    }

    struct DeltaPage: Decodable {
        let value: [GraphMessage]
        let nextLink: String?
        let deltaLink: String?
        enum CodingKeys: String, CodingKey {
            case value
            case nextLink = "@odata.nextLink"
            case deltaLink = "@odata.deltaLink"
        }
    }

    struct BodyPatch: Encodable {
        struct Body: Encodable { let contentType: String; let content: String }
        let body: Body
    }
}
