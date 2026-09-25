import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OrbitCore

final class GraphMailClientTests: XCTestCase {
    var stub: EmailStubTransport!
    var client: GraphMailClient!
    let base = "https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages/delta"

    override func setUp() {
        stub = EmailStubTransport()
        client = GraphMailClient(tokens: StaticTokenProvider("ms-tok"), http: HTTPClient(transport: stub))
    }

    static func message(id: String, subject: String, body: String, contentType: String = "text",
                        isRead: Bool = false, extra: String = "") -> String {
        """
        {"id": "\(id)", "conversationId": "conv-\(id)", "subject": "\(subject)", "bodyPreview": "",
         "body": {"contentType": "\(contentType)", "content": "\(body)"},
         "from": {"emailAddress": {"name": "Dr Ada Lovelace", "address": "a.lovelace@exeter.ac.uk"}},
         "toRecipients": [{"emailAddress": {"name": "Charlie", "address": "cw123@exeter.ac.uk"}}],
         "ccRecipients": [],
         "receivedDateTime": "2026-09-22T09:15:00Z", "isRead": \(isRead), "categories": ["Blue"]\(extra)}
        """
    }

    func testInitialDeltaFollowsNextLinkAndStoresDeltaLink() async throws {
        stub.on("GET", "$skiptoken=page2", json: """
        {"value": [\(Self.message(id: "AAMk3", subject: "Seminar room change", body: "<p>Now in <b>Amory</b> 128</p>", contentType: "html"))],
         "@odata.deltaLink": "\(base)?$deltatoken=xyz"}
        """)
        stub.on("GET", "messages/delta?", json: """
        {"value": [\(Self.message(id: "AAMk1", subject: "Assessment 1 feedback", body: "Your feedback is ready.\\r\\nWell done.")),
                   {"id": "AAMk2", "@removed": {"reason": "deleted"}}],
         "@odata.nextLink": "\(base)?$skiptoken=page2"}
        """)

        let (messages, cursor) = try await client.fetchNew(since: nil)
        XCTAssertEqual(cursor, "\(base)?$deltatoken=xyz")
        XCTAssertEqual(messages.map(\.id), ["AAMk1", "AAMk3"])

        let first = messages[0]
        XCTAssertEqual(first.account, .exeter)
        XCTAssertEqual(first.from, "a.lovelace@exeter.ac.uk")
        XCTAssertEqual(first.fromName, "Dr Ada Lovelace")
        XCTAssertEqual(first.to, ["cw123@exeter.ac.uk"])
        XCTAssertEqual(first.threadID, "conv-AAMk1")
        XCTAssertEqual(first.body, "Your feedback is ready.\nWell done.")
        XCTAssertEqual(first.snippet, "Your feedback is ready. Well done.")
        XCTAssertEqual(first.date, Date(timeIntervalSince1970: 1_790_068_500))
        XCTAssertTrue(first.isUnread)
        XCTAssertEqual(messages[1].body, "Now in Amory 128")

        let firstReq = try XCTUnwrap(stub.requests.first)
        let url = EmailStubTransport.urlString(firstReq)
        XCTAssertTrue(url.contains("$select=id,conversationId,subject"))
        XCTAssertTrue(url.contains("$filter=receivedDateTime ge "))
        XCTAssertEqual(firstReq.value(forHTTPHeaderField: "Authorization"), "Bearer ms-tok")
        XCTAssertTrue(firstReq.value(forHTTPHeaderField: "Prefer")?.contains(#"outlook.body-content-type="text""#) == true)
    }

    func testIncrementalUsesDeltaLink() async throws {
        stub.on("GET", "$deltatoken=xyz", json: """
        {"value": [\(Self.message(id: "AAMk4", subject: "Reminder", body: "Hand-in tomorrow", isRead: true))],
         "@odata.deltaLink": "\(base)?$deltatoken=next"}
        """)
        let (messages, cursor) = try await client.fetchNew(since: "\(base)?$deltatoken=xyz")
        XCTAssertEqual(messages.map(\.id), ["AAMk4"])
        XCTAssertFalse(messages[0].isUnread)
        XCTAssertEqual(cursor, "\(base)?$deltatoken=next")
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testExpiredDeltaTokenStartsOver() async throws {
        stub.on("GET", "$deltatoken=old", status: 410, json: #"{"error": {"code": "SyncStateNotFound"}}"#)
        stub.on("GET", "messages/delta?", json: #"{"value": [], "@odata.deltaLink": "https://graph/delta?$deltatoken=fresh"}"#)
        let (messages, cursor) = try await client.fetchNew(since: "\(base)?$deltatoken=old")
        XCTAssertTrue(messages.isEmpty)
        XCTAssertEqual(cursor, "https://graph/delta?$deltatoken=fresh")
        XCTAssertTrue(GraphMailClient.isExpiredSyncState(HTTPError(status: 400, body: #"{"code":"resyncRequired"}"#, url: "")))
        XCTAssertFalse(GraphMailClient.isExpiredSyncState(HTTPError(status: 401, body: "", url: "")))
    }

    func testCreateReplyDraftKeepsQuotedOriginal() async throws {
        stub.on("POST", "/createReply", json: """
        {"id": "draft-1", "body": {"contentType": "text", "content": "From: Dr Ada Lovelace\\nSent: Tuesday\\n\\nCan you present on Friday?"}}
        """)
        stub.on("PATCH", "/me/messages/draft-1", json: #"{"id": "draft-1"}"#)

        let original = EmailFixtures.message(id: "AA/b+c=", account: .exeter, subject: "Presentation")
        let id = try await client.createDraft(replyTo: original, body: "Yes, happy to.\n\nCharlie")
        XCTAssertEqual(id, "draft-1")

        let create = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(create.httpMethod, "POST")
        XCTAssertTrue(create.url!.absoluteString.hasSuffix("/me/messages/AA%2Fb%2Bc=/createReply"))

        let patch = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(patch.httpMethod, "PATCH")
        struct Patch: Decodable { struct B: Decodable { let contentType: String; let content: String }; let body: B }
        let body = try JSONDecoder().decode(Patch.self, from: try XCTUnwrap(patch.httpBody)).body
        XCTAssertEqual(body.contentType, "Text")
        XCTAssertTrue(body.content.hasPrefix("Yes, happy to.\n\nCharlie\n\nFrom: Dr Ada Lovelace"))
        XCTAssertTrue(stub.requests.allSatisfy { !($0.url?.absoluteString.contains("/send") ?? false) })
    }

    func testFetchMessageAndMarkRead() async throws {
        stub.on("GET", "/me/messages/AAMk9", json: Self.message(id: "AAMk9", subject: "One", body: "Body"))
        stub.on("PATCH", "/me/messages/AAMk9", json: #"{"id": "AAMk9", "isRead": true}"#)
        let m = try await client.fetchMessage(id: "AAMk9")
        XCTAssertEqual(m.subject, "One")
        try await client.markRead(id: "AAMk9")
        let patch = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(String(decoding: try XCTUnwrap(patch.httpBody), as: UTF8.self), #"{"isRead":true}"#)
    }
}
