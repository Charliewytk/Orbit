import XCTest
@testable import OrbitCore

final class OneNoteClientTests: XCTestCase {
    let base = "https://graph.microsoft.com/v1.0/"

    func makeClient() -> (OneNoteClient, NotesStubTransport) {
        let stub = NotesStubTransport()
        let client = OneNoteClient(tokens: StaticTokenProvider("tok"), http: HTTPClient(transport: stub), pageSize: 2)
        return (client, stub)
    }

    func stubHierarchy(_ stub: NotesStubTransport) {
        stub.on("me/onenote/notebooks", json: """
        {"@odata.context":"x","value":[{"id":"nb1","displayName":"Economics BEM2031","lastModifiedDateTime":"2025-10-14T12:00:00Z","isDefault":false}]}
        """)
        stub.on("me/onenote/notebooks/nb1/sections", json: """
        {"value":[{"id":"s1","displayName":"Lectures","lastModifiedDateTime":"2025-10-14T12:00:00Z"}]}
        """)
        stub.on("me/onenote/notebooks/nb1/sectionGroups", json: #"{"value":[{"id":"g1","displayName":"Term 1"}]}"#)
        stub.on("me/onenote/sectionGroups/g1/sections", json: """
        {"value":[{"id":"s2","displayName":"Seminars","lastModifiedDateTime":"2025-10-01T09:00:00Z"}]}
        """)
        stub.on("me/onenote/sectionGroups/g1/sectionGroups", json: #"{"value":[{"id":"g2","displayName":"Extra"}]}"#)
        stub.on("me/onenote/sectionGroups/g2/sections", json: #"{"value":[{"id":"s3","displayName":"Reading"}]}"#)
        stub.on("me/onenote/sectionGroups/g2/sectionGroups", json: #"{"value":[]}"#)
        stub.on("me/onenote/sections/s1/pages?$orderby=lastModifiedDateTime desc", json: """
        {"value":[
          {"id":"p1","title":"Week 5 Market failure","createdDateTime":"2025-10-14T10:05:00Z","lastModifiedDateTime":"2025-10-14T11:00:00.1234567Z",
           "contentUrl":"https://graph.microsoft.com/v1.0/me/onenote/pages/p1/content","parentSection":{"id":"s1","displayName":"Lectures"}},
          {"id":"p2","title":"Week 4","createdDateTime":"2025-10-07T10:05:00Z","lastModifiedDateTime":"2025-10-10T09:00:00Z"}
        ],
        "@odata.nextLink":"https://graph.microsoft.com/v1.0/me/onenote/sections/s1/pages?$skip=2"}
        """)
        stub.on("sections/s1/pages?$skip=2", json: """
        {"value":[{"id":"p3","title":"Week 3","lastModifiedDateTime":"2025-10-01T09:00:00Z"}]}
        """)
        stub.on("me/onenote/sections/s2/pages", json: """
        {"value":[{"id":"p9","title":"Seminar 1","lastModifiedDateTime":"2025-10-01T09:00:00Z"}]}
        """)
    }

    func testListsNotebooksAndSectionsIncludingNestedGroups() async throws {
        let (client, stub) = makeClient()
        stubHierarchy(stub)
        let notebooks = try await client.notebooks()
        XCTAssertEqual(notebooks.map(\.displayName), ["Economics BEM2031"])
        let sections = try await client.sections(in: notebooks[0])
        XCTAssertEqual(sections.map(\.id), ["s1", "s2", "s3"])
        XCTAssertEqual(sections[2].groupPath, ["Term 1", "Extra"])
        XCTAssertEqual(sections[2].fullPath, "Economics BEM2031 › Term 1 › Extra › Reading")
        XCTAssertEqual(stub.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    func testPagesFollowNextLinkAndStopAtCursor() async throws {
        let (client, stub) = makeClient()
        stubHierarchy(stub)
        let all = try await client.pages(inSection: "s1")
        XCTAssertEqual(all.map(\.id), ["p1", "p2", "p3"])
        XCTAssertEqual(all[0].parentSection?.displayName, "Lectures")
        XCTAssertNotNil(all[0].lastModifiedDateTime)
        XCTAssertTrue(stub.requestedURLs[0].contains("$orderby=lastModifiedDateTime desc"))
        XCTAssertTrue(stub.requestedURLs[0].contains("$top=2"))

        let before = stub.requests.count
        let cutoff = ISO8601.parse("2025-10-12T00:00:00Z")!
        let recent = try await client.pages(inSection: "s1", modifiedAfter: cutoff)
        XCTAssertEqual(recent.map(\.id), ["p1"])
        XCTAssertEqual(stub.requests.count - before, 1, "should not fetch the next page once past the cursor")
    }

    func testIncrementalSyncAdvancesCursorAndSkipsUnchangedSections() async throws {
        let (client, stub) = makeClient()
        stubHierarchy(stub)
        let sections = try await client.allSections().filter { $0.id != "s3" }
        let first = try await client.changes(since: OneNoteSyncCursor(), in: sections)
        XCTAssertEqual(first.pages.map(\.page.id), ["p1", "p2", "p3", "p9"])
        XCTAssertEqual(first.cursor.sections["s1"], ISO8601.parse("2025-10-14T11:00:00.1234567Z"))

        let before = stub.requests.count
        let second = try await client.changes(since: first.cursor, in: sections)
        XCTAssertTrue(second.pages.isEmpty)
        XCTAssertEqual(stub.requests.count, before, "unchanged sections shouldn't be listed")
    }

    func testRateLimitThrowsTypedError() async throws {
        let (client, stub) = makeClient()
        stub.on("me/onenote/notebooks", .init(status: 429, headers: ["Retry-After": "7"], body: Data("{}".utf8)))
        do {
            _ = try await client.notebooks()
            XCTFail("expected rate limit")
        } catch let e as OneNoteError {
            XCTAssertEqual(e, .rateLimited(retryAfter: 7))
        }
        stub.on("me/onenote/sections/s1/pages", .init(status: 401, body: Data()))
        do { _ = try await client.pages(inSection: "s1"); XCTFail() } catch let e as OneNoteError {
            XCTAssertEqual(e, .unauthorized)
        }
        XCTAssertEqual(OneNoteClient.retryAfter("Wed, 21 Oct 2025 07:28:10 GMT", now: ISO8601.parse("2025-10-21T07:28:00Z")!), 10)
    }

    func testMultipartPageContentAndImages() async throws {
        let (client, stub) = makeClient()
        stub.on("me/onenote/pages/p1/content", .init(
            headers: ["Content-Type": "multipart/related; boundary=\(NotesFixtures.boundary); type=\"text/html\""],
            body: NotesFixtures.multipartBody))
        stub.on("resources/0-imgfull!1-abc/$value", .init(headers: ["Content-Type": "image/png"], body: Data([0x89, 0x50, 0x4E, 0x47])))

        let content = try await client.pageContent(pageID: "p1")
        XCTAssertTrue(content.html.hasPrefix("<html"))
        XCTAssertTrue(content.html.hasSuffix("</html>"))
        XCTAssertTrue(content.inkML?.contains("<inkml:trace") ?? false)
        XCTAssertTrue(stub.requestedURLs.last!.contains("includeIDs=true&includeInkML=true"))

        let page = OneNotePage(id: "p1", title: "Week 5 Market failure")
        let fetched = try await client.fetchPage(page)
        XCTAssertEqual(fetched.document.title, "BEM2031 Week 5 – Market failure")
        XCTAssertEqual(fetched.ink?.strokes.count, 2)
        let src = fetched.document.blocks.first { $0.kind == .image }!.src!
        XCTAssertEqual(fetched.images[src], Data([0x89, 0x50, 0x4E, 0x47]))
        let imageRequest = stub.requests.last!
        XCTAssertTrue(imageRequest.url!.absoluteString.contains("0-imgfull"), "uses the full-resolution image")
        XCTAssertEqual(imageRequest.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    func testPlainHTMLContentWithoutInk() throws {
        let c = try OneNoteClient.decodeContent(Data("<html><body><p>Hi</p></body></html>".utf8), contentType: "text/html")
        XCTAssertNil(c.inkML)
        XCTAssertEqual(OneNoteHTMLParser.parse(c.html).typedText, "Hi")
    }

    func testMultipartParserHandlesQuotedBoundaryAndLF() {
        XCTAssertEqual(MultipartParser.boundary(fromContentType: "multipart/related; boundary=\"a b\""), "a b")
        let body = "preamble\n--xyz\nContent-Type: text/plain\n\nhello\n--xyz\nContent-Type: application/json\n\n{}\n--xyz--\n"
        let parts = MultipartParser.parse(Data(body.utf8), boundary: "xyz")
        XCTAssertEqual(parts.map(\.mimeType), ["text/plain", "application/json"])
        XCTAssertEqual(parts.map(\.text), ["hello", "{}"])
    }
}
