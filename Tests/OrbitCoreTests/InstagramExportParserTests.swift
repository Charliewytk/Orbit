import XCTest
@testable import OrbitCore

final class InstagramExportParserTests: XCTestCase {
    // Exactly how Instagram writes it: UTF-8 bytes escaped as \u00XX code points, newest first.
    static let fixture = #"""
    {
      "participants": [{"name": "Zo\u00c3\u00ab Marsh"}, {"name": "Charlie"}],
      "messages": [
        {"sender_name": "Zo\u00c3\u00ab Marsh", "timestamp_ms": 1792003000000, "content": "see you there \u00f0\u009f\u0091\u008d"},
        {"sender_name": "Charlie", "timestamp_ms": 1792002900000, "content": "Liked a message"},
        {"sender_name": "Charlie", "timestamp_ms": 1792002800000, "content": "yes! the caf\u00c3\u00a9 on Gandy St?"},
        {"sender_name": "Zo\u00c3\u00ab Marsh", "timestamp_ms": 1792002750000, "photos": [{"uri": "x.jpg"}]},
        {"sender_name": "Zo\u00c3\u00ab Marsh", "timestamp_ms": 1792002720000, "content": "coffee tomorrow at 11?"}
      ],
      "title": "Zo\u00c3\u00ab Marsh",
      "is_still_participant": true,
      "thread_path": "inbox/zoemarsh_123456"
    }
    """#

    func testFixesMojibake() {
        XCTAssertEqual(InstagramExportParser.fixMojibake("caf\u{00C3}\u{00A9}"), "café")
        XCTAssertEqual(InstagramExportParser.fixMojibake("\u{00F0}\u{009F}\u{0091}\u{008D}"), "👍")
        XCTAssertEqual(InstagramExportParser.fixMojibake("already fine é 👍"), "already fine é 👍")
        XCTAssertEqual(InstagramExportParser.fixMojibake("plain"), "plain")
    }

    func testParsesThread() throws {
        let thread = try InstagramExportParser(myNames: ["Charlie"]).parse(Data(Self.fixture.utf8))
        XCTAssertEqual(thread.title, "Zoë Marsh")
        XCTAssertEqual(thread.participants, ["Zoë Marsh", "Charlie"])
        XCTAssertEqual(thread.messages.map(\.text), ["coffee tomorrow at 11?", "yes! the café on Gandy St?", "see you there 👍"])
        XCTAssertEqual(thread.messages.map(\.isFromMe), [false, true, false])
        XCTAssertEqual(thread.messages[0].sender, "Zoë Marsh")
        XCTAssertEqual(thread.messages[0].date, Date(timeIntervalSince1970: 1_792_002_720))
        XCTAssertEqual(thread.messages[0].source, .instagram)
    }

    func testReadsExportFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let thread = root.appendingPathComponent("your_instagram_activity/messages/inbox/zoemarsh_123456")
        try FileManager.default.createDirectory(at: thread, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(Self.fixture.utf8).write(to: thread.appendingPathComponent("message_1.json"))
        let older = #"{"participants":[{"name":"Charlie"}],"messages":[{"sender_name":"Charlie","timestamp_ms":1760000000000,"content":"hey"}],"title":"Zo\u00c3\u00ab Marsh"}"#
        try Data(older.utf8).write(to: thread.appendingPathComponent("message_2.json"))

        let threads = try InstagramExportParser(myNames: ["Charlie"]).parse(exportFolder: root)
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].messages.count, 4)
        XCTAssertEqual(threads[0].messages.first?.text, "hey")
    }
}
