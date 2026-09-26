import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Gmail via the REST API (v1).
///
/// - First sync lists recent inbox mail (`newer_than:14d`, capped) and records the
///   mailbox `historyId` as the cursor.
/// - Later syncs ask `users.history.list` for messages added since that ID. If
///   Google has expired the ID (HTTP 404) it falls back to a fresh first sync.
/// - Drafts are saved with `users.drafts.create`; nothing is ever sent.
public struct GmailClient: MailProvider {
    public let account: MailAccount = .gmail
    public var http: HTTPClient
    public var tokens: AccessTokenProvider
    public var baseURL: URL
    /// Search used for the first sync.
    public var initialQuery: String
    /// Only mail with these labels is synced.
    public var labelIDs: [String]
    public var maxInitialMessages: Int
    public var maxConcurrentFetches: Int

    /// Needed for mark-as-read, Archive and Trash (never sending).
    public static let modifyScope = "https://www.googleapis.com/auth/gmail.modify"

    /// OAuth scopes: read mail, save drafts, and mark as read / archive / trash.
    public static let scopes = [
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/gmail.compose",
        "https://www.googleapis.com/auth/gmail.modify",
    ]

    public init(tokens: AccessTokenProvider, http: HTTPClient = HTTPClient(),
                baseURL: URL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me")!,
                initialQuery: String = "newer_than:14d", labelIDs: [String] = ["INBOX"],
                maxInitialMessages: Int = 150, maxConcurrentFetches: Int = 5) {
        self.tokens = tokens; self.http = http; self.baseURL = baseURL; self.initialQuery = initialQuery
        self.labelIDs = labelIDs; self.maxInitialMessages = maxInitialMessages
        self.maxConcurrentFetches = maxConcurrentFetches
    }

    // MARK: Sync

    public func fetchNew(since cursor: String?) async throws -> (messages: [EmailMessage], cursor: String?) {
        let headers = try await authHeaders()
        if let cursor {
            do {
                return try await incrementalSync(from: cursor, headers: headers)
            } catch let error as HTTPError where error.status == 404 {
                // History ID too old: start again from a full list.
            }
        }
        return try await fullSync(headers: headers)
    }

    func fullSync(headers: [String: String]) async throws -> (messages: [EmailMessage], cursor: String?) {
        // Take the history ID first so nothing arriving mid-sync is missed next time.
        let profile = try await http.get(Profile.self, url("profile"), headers: headers)
        var ids: [String] = []
        var pageToken: String?
        repeat {
            var query = [URLQueryItem(name: "q", value: initialQuery),
                         URLQueryItem(name: "maxResults", value: String(min(100, maxInitialMessages)))]
            query += labelIDs.map { URLQueryItem(name: "labelIds", value: $0) }
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page = try await http.get(ListResponse.self, url("messages", query), headers: headers)
            ids += (page.messages ?? []).map(\.id)
            pageToken = page.nextPageToken
        } while pageToken != nil && ids.count < maxInitialMessages
        let messages = try await fetchAll(Array(ids.prefix(maxInitialMessages)), headers: headers)
        return (messages, profile.historyId)
    }

    func incrementalSync(from historyID: String, headers: [String: String]) async throws -> (messages: [EmailMessage], cursor: String?) {
        var ids: [String] = []
        var seen = Set<String>()
        var latest = historyID
        var pageToken: String?
        repeat {
            var query = [URLQueryItem(name: "startHistoryId", value: historyID),
                         URLQueryItem(name: "historyTypes", value: "messageAdded")]
            if let label = labelIDs.first { query.append(URLQueryItem(name: "labelId", value: label)) }
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page = try await http.get(HistoryResponse.self, url("history", query), headers: headers)
            for record in page.history ?? [] {
                for added in record.messagesAdded ?? [] where seen.insert(added.message.id).inserted {
                    ids.append(added.message.id)
                }
            }
            if let h = page.historyId { latest = h }
            pageToken = page.nextPageToken
        } while pageToken != nil
        return (try await fetchAll(ids, headers: headers), latest)
    }

    /// Fetches full messages, skipping any deleted since they were listed.
    func fetchAll(_ ids: [String], headers: [String: String]) async throws -> [EmailMessage] {
        let found = try await EmailConcurrency.map(ids, limit: maxConcurrentFetches) { [self] id -> EmailMessage? in
            do { return try await fetchMessage(id: id, headers: headers) }
            catch let error as HTTPError where error.status == 404 { return nil }
        }
        return found.compactMap { $0 }
    }

    public func fetchMessage(id: String) async throws -> EmailMessage {
        try await fetchMessage(id: id, headers: try await authHeaders())
    }

    func fetchMessage(id: String, headers: [String: String]) async throws -> EmailMessage {
        let raw = try await http.get(GmailMessage.self, url("messages/\(id)", [URLQueryItem(name: "format", value: "full")]),
                                     headers: headers)
        return Self.emailMessage(from: raw)
    }

    // MARK: Drafts and flags

    public func createDraft(replyTo message: EmailMessage, body: String) async throws -> String {
        let headers = try await authHeaders()
        // EmailMessage doesn't keep Message-ID/References, so fetch just those headers.
        let wanted = ["Message-ID", "References", "Reply-To", "From", "Subject"]
        let meta = try await http.get(
            GmailMessage.self,
            url("messages/\(message.id)", [URLQueryItem(name: "format", value: "metadata")]
                + wanted.map { URLQueryItem(name: "metadataHeaders", value: $0) }),
            headers: headers)
        let h = MIMEHeaders((meta.payload?.headers ?? []).map { .init(name: $0.name, value: $0.value) })
        let to = h["Reply-To"].flatMap { MailAddress.parseList($0).first }
            ?? h["From"].flatMap { MailAddress.parseList($0).first }
            ?? MailAddress(name: message.fromName, address: message.from)
        let raw = Self.replyMIME(to: to, subject: h.decoded("Subject") ?? message.subject,
                                 inReplyTo: h["Message-ID"], references: h["References"], body: body)
        let draft = DraftBody(message: .init(raw: MIMEParser.encodeBase64URL(Data(raw.utf8)),
                                             threadId: meta.threadId ?? message.threadID))
        return try await http.post(DraftResponse.self, url("drafts"), body: draft, headers: headers).id
    }

    public func markRead(id: String) async throws {
        let body = try HTTPClient.encoder.encode(["removeLabelIds": ["UNREAD"]])
        var headers = try await authHeaders()
        headers["Content-Type"] = "application/json"
        _ = try await http.data("POST", url("messages/\(id)/modify"), headers: headers, body: body)
    }

    /// Archive (batchModify, remove INBOX), Trash (messages.trash), and their undos.
    /// Needs `gmail.modify`. Never deletes permanently.
    public func apply(_ action: MailboxAction, ids: [String]) async throws {
        let ids = Array(Set(ids)).sorted()
        guard !ids.isEmpty else { return }
        var h = try await authHeaders()
        h["Content-Type"] = "application/json"
        let headers = h
        switch action {
        case .archive, .unarchive:
            // batchModify takes up to 1000 ids per call.
            for start in stride(from: 0, to: ids.count, by: 1000) {
                let chunk = Array(ids[start..<min(ids.count, start + 1000)])
                let body = BatchModify(ids: chunk, addLabelIds: action == .unarchive ? ["INBOX"] : nil,
                                       removeLabelIds: action == .archive ? ["INBOX"] : nil)
                _ = try await http.data("POST", url("messages/batchModify"), headers: headers,
                                        body: try HTTPClient.encoder.encode(body))
            }
        case .trash, .untrash:
            _ = try await EmailConcurrency.map(ids, limit: maxConcurrentFetches) { [self] id -> Bool in
                do {
                    _ = try await http.data("POST", url("messages/\(id)/\(action == .trash ? "trash" : "untrash")"),
                                            headers: headers, body: nil)
                } catch let error as HTTPError where error.status == 404 {
                    // Already gone: nothing to do.
                }
                return true
            }
        }
    }

    struct BatchModify: Encodable {
        let ids: [String]
        let addLabelIds: [String]?
        let removeLabelIds: [String]?
    }

    /// Builds an RFC 2822 reply with threading headers. Base64 body if it isn't plain ASCII.
    public static func replyMIME(to: MailAddress, subject: String, inReplyTo: String?, references: String?,
                                 body: String, from: MailAddress? = nil, date: Date = Date()) -> String {
        let reSubject = subject.range(of: "^(re|aw|sv):", options: [.regularExpression, .caseInsensitive]) != nil
            ? subject : "Re: \(subject)"
        var lines: [String] = []
        if let from { lines.append("From: \(from.formatted)") }
        lines.append("To: \(to.formatted)")
        lines.append("Subject: \(MIMEParser.encodeHeader(reSubject))")
        lines.append("Date: \(MIMEParser.formatDate(date))")
        if let inReplyTo {
            lines.append("In-Reply-To: \(inReplyTo)")
            let refs = [references, inReplyTo].compactMap { $0 }.joined(separator: " ")
            lines.append("References: \(refs)")
        }
        lines.append("MIME-Version: 1.0")
        lines.append("Content-Type: text/plain; charset=\"UTF-8\"")
        let normalised = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        if normalised.unicodeScalars.allSatisfy(\.isASCII) {
            lines.append("Content-Transfer-Encoding: 7bit")
            return lines.joined(separator: "\r\n") + "\r\n\r\n" + normalised
        }
        lines.append("Content-Transfer-Encoding: base64")
        let b64 = Data(normalised.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        return lines.joined(separator: "\r\n") + "\r\n\r\n" + b64
    }

    // MARK: Decoding

    static func emailMessage(from m: GmailMessage) -> EmailMessage {
        let root = m.payload.map(mimePart) ?? MIMEPart()
        let parsed = ParsedMail(root: root)
        let snippet = HTMLToText.decodeEntities(m.snippet ?? "")
        let body = parsed.bodyText
        let internalDate = m.internalDate.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
        let labels = m.labelIds ?? []
        return EmailMessage(
            id: m.id, account: .gmail, threadID: m.threadId, from: parsed.from?.address ?? "",
            fromName: parsed.from?.name, to: (parsed.to + parsed.cc).map(\.address), subject: parsed.subject,
            snippet: snippet.isEmpty ? MIMEParser.snippet(body) : snippet, body: body.isEmpty ? snippet : body,
            date: internalDate ?? parsed.date ?? Date(), isUnread: labels.contains("UNREAD"), labels: labels
        )
    }

    /// Converts Gmail's payload tree into the shared MIME model. Gmail has already
    /// undone the transfer encoding; `body.data` is base64url of the raw bytes.
    static func mimePart(_ p: GmailMessage.Part) -> MIMEPart {
        var fields = (p.headers ?? []).map { MIMEHeaders.Field(name: $0.name, value: $0.value) }
        let headers = MIMEHeaders(fields)
        if let name = p.filename, !name.isEmpty, headers["Content-Disposition"] == nil {
            fields.append(.init(name: "Content-Disposition", value: "attachment; filename=\"\(name)\""))
        }
        let params = headers["Content-Type"].map { MIMEParser.parseContentType($0).parameters } ?? [:]
        return MIMEPart(headers: MIMEHeaders(fields), contentType: (p.mimeType ?? "text/plain").lowercased(),
                        parameters: params, body: p.body?.data.map(MIMEParser.decodeBase64URL) ?? Data(),
                        parts: (p.parts ?? []).map(mimePart))
    }

    // MARK: Plumbing

    private func authHeaders() async throws -> [String: String] {
        ["Authorization": "Bearer \(try await tokens.accessToken())"]
    }

    private func url(_ path: String, _ query: [URLQueryItem] = []) -> URL {
        var c = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        return c.url!
    }

    struct Profile: Decodable { let historyId: String }

    struct MessageRef: Decodable { let id: String; let threadId: String? }

    struct ListResponse: Decodable {
        let messages: [MessageRef]?
        let nextPageToken: String?
    }

    struct HistoryResponse: Decodable {
        struct Record: Decodable {
            struct Added: Decodable { let message: MessageRef }
            let messagesAdded: [Added]?
        }
        let history: [Record]?
        let nextPageToken: String?
        let historyId: String?
    }

    struct GmailMessage: Decodable {
        struct Header: Decodable { let name: String; let value: String }
        struct Body: Decodable { let size: Int?; let data: String?; let attachmentId: String? }
        struct Part: Decodable {
            let mimeType: String?
            let filename: String?
            let headers: [Header]?
            let body: Body?
            let parts: [Part]?
        }
        let id: String
        let threadId: String?
        let labelIds: [String]?
        let snippet: String?
        let internalDate: String?
        let payload: Part?
    }

    struct DraftBody: Encodable {
        struct Message: Encodable { let raw: String; let threadId: String? }
        let message: Message
    }

    struct DraftResponse: Decodable { let id: String }
}
