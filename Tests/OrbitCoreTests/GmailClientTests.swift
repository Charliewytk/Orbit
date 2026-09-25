import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OrbitCore

final class GmailClientTests: XCTestCase {
    var stub: EmailStubTransport!
    var client: GmailClient!

    override func setUp() {
        stub = EmailStubTransport()
        client = GmailClient(tokens: StaticTokenProvider("tok"), http: HTTPClient(transport: stub))
    }

    static func fullMessage(id: String, subject: String, unread: Bool = true) -> String {
        let plain = EmailFixtures.b64url("Hi Charlie,\r\nCan you send the slides by Friday?\r\n")
        let html = EmailFixtures.b64url("<p>Hi Charlie,</p><p>Can you send the slides?</p>")
        return """
        {"id": "\(id)", "threadId": "t-\(id)", "labelIds": [\(unread ? "\"UNREAD\", " : "")"INBOX", "IMPORTANT"],
         "snippet": "Hi Charlie, Can you send the slides by Friday&#39;s lecture?",
         "internalDate": "1790068500000",
         "payload": {
           "mimeType": "multipart/alternative",
           "headers": [
             {"name": "From", "value": "Sam Jones <sam@example.com>"},
             {"name": "To", "value": "charlie@gmail.com"},
             {"name": "Cc", "value": "Pat <pat@example.com>"},
             {"name": "Subject", "value": "\(subject)"},
             {"name": "Date", "value": "Tue, 22 Sep 2026 09:15:00 +0000"}
           ],
           "body": {"size": 0},
           "parts": [
             {"partId": "0", "mimeType": "text/plain", "filename": "",
              "headers": [{"name": "Content-Type", "value": "text/plain; charset=\\"UTF-8\\""}],
              "body": {"size": 40, "data": "\(plain)"}},
             {"partId": "1", "mimeType": "text/html", "filename": "",
              "headers": [{"name": "Content-Type", "value": "text/html; charset=\\"UTF-8\\""}],
              "body": {"size": 40, "data": "\(html)"}}
           ]
         }}
        """
    }

    static func htmlOnlyMessage(id: String) -> String {
        """
        {"id": "\(id)", "threadId": "t-\(id)", "labelIds": ["INBOX"], "snippet": "Offer",
         "internalDate": "1790068500000",
         "payload": {"mimeType": "text/html",
           "headers": [{"name": "From", "value": "shop@example.com"}, {"name": "Subject", "value": "Sale"},
                       {"name": "Content-Type", "value": "text/html; charset=utf-8"}],
           "body": {"size": 10, "data": "\(EmailFixtures.b64url("<div>Big sale</div><div>Today only</div>"))"}}}
        """
    }

    func testFirstSyncListsPagesFetchesMessagesAndSkipsDeleted() async throws {
        stub.on("GET", "/users/me/profile", json: #"{"emailAddress": "charlie@gmail.com", "historyId": "5000"}"#)
        stub.on("GET", "pageToken=p2", json: #"{"messages": [{"id": "m3", "threadId": "t3"}]}"#)
        stub.on("GET", "/users/me/messages?", json: #"{"messages": [{"id": "m1", "threadId": "t1"}, {"id": "m2", "threadId": "t2"}], "nextPageToken": "p2"}"#)
        stub.on("GET", "/messages/m1?format=full", json: Self.fullMessage(id: "m1", subject: "Slides"))
        stub.on("GET", "/messages/m2?format=full", json: Self.htmlOnlyMessage(id: "m2"))
        stub.on("GET", "/messages/m3?format=full", status: 404, json: #"{"error": {"code": 404}}"#)

        let (messages, cursor) = try await client.fetchNew(since: nil)
        XCTAssertEqual(cursor, "5000")
        XCTAssertEqual(messages.map(\.id), ["m1", "m2"])

        let m1 = messages[0]
        XCTAssertEqual(m1.account, .gmail)
        XCTAssertEqual(m1.threadID, "t-m1")
        XCTAssertEqual(m1.from, "sam@example.com")
        XCTAssertEqual(m1.fromName, "Sam Jones")
        XCTAssertEqual(m1.to, ["charlie@gmail.com", "pat@example.com"])
        XCTAssertEqual(m1.subject, "Slides")
        XCTAssertEqual(m1.body, "Hi Charlie,\nCan you send the slides by Friday?\n")
        XCTAssertEqual(m1.snippet, "Hi Charlie, Can you send the slides by Friday's lecture?")
        XCTAssertEqual(m1.date, Date(timeIntervalSince1970: 1_790_068_500))
        XCTAssertTrue(m1.isUnread)
        XCTAssertTrue(m1.labels.contains("IMPORTANT"))

        XCTAssertEqual(messages[1].body, "Big sale\nToday only")
        XCTAssertFalse(messages[1].isUnread)

        let list = try XCTUnwrap(stub.requests(matching: "/users/me/messages?").first)
        let listURL = EmailStubTransport.urlString(list)
        XCTAssertTrue(listURL.contains("q=newer_than:14d"))
        XCTAssertTrue(listURL.contains("labelIds=INBOX"))
        XCTAssertEqual(list.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    func testIncrementalSyncUsesHistoryAndDedupes() async throws {
        stub.on("GET", "/history?", json: """
        {"history": [{"id": "5001", "messagesAdded": [{"message": {"id": "m4", "threadId": "t4"}}]},
                     {"id": "5002", "messagesAdded": [{"message": {"id": "m4", "threadId": "t4"}}]},
                     {"id": "5003"}],
         "historyId": "5100"}
        """)
        stub.on("GET", "/messages/m4?format=full", json: Self.fullMessage(id: "m4", subject: "Follow-up"))

        let (messages, cursor) = try await client.fetchNew(since: "5000")
        XCTAssertEqual(messages.map(\.id), ["m4"])
        XCTAssertEqual(cursor, "5100")
        let url = EmailStubTransport.urlString(try XCTUnwrap(stub.requests(matching: "/history?").first))
        XCTAssertTrue(url.contains("startHistoryId=5000"))
        XCTAssertTrue(url.contains("historyTypes=messageAdded"))
        XCTAssertTrue(stub.requests(matching: "/profile").isEmpty)
    }

    func testExpiredHistoryFallsBackToFullSync() async throws {
        stub.on("GET", "/history?", status: 404, json: #"{"error": {"code": 404, "message": "Requested entity was not found."}}"#)
        stub.on("GET", "/profile", json: #"{"historyId": "9000"}"#)
        stub.on("GET", "/users/me/messages?", json: #"{"messages": [{"id": "m1"}]}"#)
        stub.on("GET", "/messages/m1?format=full", json: Self.fullMessage(id: "m1", subject: "Again"))

        let (messages, cursor) = try await client.fetchNew(since: "1")
        XCTAssertEqual(messages.map(\.subject), ["Again"])
        XCTAssertEqual(cursor, "9000")
    }

    func testCreateDraftBuildsThreadedReplyAndNeverSends() async throws {
        stub.on("GET", "/messages/m1?format=metadata", json: """
        {"id": "m1", "threadId": "t1", "payload": {"headers": [
          {"name": "From", "value": "Sam Jones <sam@example.com>"},
          {"name": "Subject", "value": "Plans for Saturday"},
          {"name": "Message-ID", "value": "<orig@mail.example.com>"},
          {"name": "References", "value": "<first@mail.example.com>"}
        ]}}
        """)
        stub.on("POST", "/drafts", json: #"{"id": "d-1", "message": {"id": "dm-1", "threadId": "t1"}}"#)

        let original = EmailFixtures.message(id: "m1", from: "sam@example.com", subject: "Plans for Saturday")
        let id = try await client.createDraft(replyTo: original, body: "Sounds good – see you at 7!\n\nCharlie")
        XCTAssertEqual(id, "d-1")

        let post = try XCTUnwrap(stub.requests(matching: "/drafts").first)
        XCTAssertEqual(post.httpMethod, "POST")
        struct Sent: Decodable { struct M: Decodable { let raw: String; let threadId: String? }; let message: M }
        let sent = try JSONDecoder().decode(Sent.self, from: try XCTUnwrap(post.httpBody))
        XCTAssertEqual(sent.message.threadId, "t1")
        let mail = MIMEParser.parse(MIMEParser.decodeBase64URL(sent.message.raw))
        XCTAssertEqual(mail.subject, "Re: Plans for Saturday")
        XCTAssertEqual(mail.to.first?.address, "sam@example.com")
        XCTAssertEqual(mail.headers["In-Reply-To"], "<orig@mail.example.com>")
        XCTAssertEqual(mail.headers["References"], "<first@mail.example.com> <orig@mail.example.com>")
        XCTAssertEqual(mail.bodyText, "Sounds good – see you at 7!\n\nCharlie")

        XCTAssertTrue(stub.requests.allSatisfy { !EmailStubTransport.urlString($0).contains("send") })
    }

    func testReplySubjectNotDoubled() {
        let raw = GmailClient.replyMIME(to: MailAddress(address: "a@b.com"), subject: "RE: Hi", inReplyTo: nil,
                                        references: nil, body: "ok")
        XCTAssertTrue(raw.contains("Subject: RE: Hi\r\n"))
        XCTAssertFalse(raw.contains("In-Reply-To"))
        XCTAssertTrue(raw.hasSuffix("\r\n\r\nok"))
    }

    func testMarkRead() async throws {
        stub.on("POST", "/messages/m1/modify", json: #"{"id": "m1"}"#)
        try await client.markRead(id: "m1")
        let body = try XCTUnwrap(stub.requests(matching: "/modify").first?.httpBody)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"removeLabelIds":["UNREAD"]}"#)
    }
}
