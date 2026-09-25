import XCTest
@testable import OrbitCore

final class WhatsAppExportParserTests: XCTestCase {
    static let london = TimeZone(identifier: "Europe/London")!

    static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = london
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    func testParsesIOSExport() {
        let text = """
        \u{200E}[14/10/2026, 19:30:12] Sam Taylor: \u{200E}Messages and calls are end-to-end encrypted. No one outside of this chat, not even WhatsApp, can read or listen to them.
        [14/10/2026, 19:32:05] Sam Taylor: fancy dinner sat 7pm?
        [14/10/2026, 19:33:40] Charlie: yes!! where?
        thinking Côte
        or Rendezvous
        [14/10/2026, 19:34:02] Sam Taylor: \u{200E}image omitted
        \u{200E}[14/10/2026, 19:34:30] Charlie: \u{200E}<attached: 00000012-PHOTO-2026-10-14-19-34-30.jpg>
        [14/10/2026, 19:35:00] Sam Taylor: Côte it is, see you then 👍
        """
        let messages = WhatsAppExportParser(myNames: ["charlie"]).parse(text, conversation: "Sam")
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0].sender, "Sam Taylor")
        XCTAssertEqual(messages[0].text, "fancy dinner sat 7pm?")
        XCTAssertEqual(messages[0].date, Self.date(2026, 10, 14, 19, 32, 5))
        XCTAssertFalse(messages[0].isFromMe)
        XCTAssertEqual(messages[1].text, "yes!! where?\nthinking Côte\nor Rendezvous")
        XCTAssertTrue(messages[1].isFromMe)
        XCTAssertEqual(messages[2].text, "Côte it is, see you then 👍")
        XCTAssertEqual(messages[2].source, .whatsapp)
        XCTAssertEqual(messages[2].conversation, "Sam")
    }

    func testParsesIOS12HourWithNarrowSpaceAndTwoDigitYear() {
        let text = "[14/10/26, 7:32:05\u{202F}PM] Sam: drinks later?\n[15/10/26, 12:05:00\u{202F}AM] ~\u{202F}Priya: I'm in"
        let messages = WhatsAppExportParser().parse(text)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].date, Self.date(2026, 10, 14, 19, 32, 5))
        XCTAssertEqual(messages[1].date, Self.date(2026, 10, 15, 0, 5))
        XCTAssertEqual(messages[1].sender, "Priya")
    }

    func testParsesAndroidExport() {
        let text = """
        14/10/2026, 19:30 - Messages and calls are end-to-end encrypted. No one outside of this chat, not even WhatsApp, can read or listen to them. Tap to learn more.
        14/10/2026, 19:32 - Sam: fancy the pub tomorrow at 8?
        14/10/2026, 19:33 - Charlie: <Media omitted>
        14/10/2026, 19:34 - Charlie: go on then
        but only a couple
        14/10/26, 7:40 pm - Sam: 🍻
        14/10/26, 7:41 p.m. - Sam: This message was deleted
        """
        let messages = WhatsAppExportParser(myNames: ["Charlie"]).parse(text)
        XCTAssertEqual(messages.map(\.text), ["fancy the pub tomorrow at 8?", "go on then\nbut only a couple", "🍻"])
        XCTAssertEqual(messages.map(\.isFromMe), [false, true, false])
        XCTAssertEqual(messages[2].date, Self.date(2026, 10, 14, 19, 40))
    }

    func testDetectsMonthFirstExports() {
        let text = "10/14/26, 7:32 PM - Sam: hi\n10/15/26, 9:00 AM - Sam: morning"
        let messages = WhatsAppExportParser().parse(text)
        XCTAssertEqual(messages.first?.date, Self.date(2026, 10, 14, 19, 32))
        XCTAssertEqual(messages.last?.date, Self.date(2026, 10, 15, 9, 0))
    }

    func testKeepsDayMonthWhenAmbiguous() {
        let messages = WhatsAppExportParser().parse("03/04/2026, 10:00 - Sam: hi")
        XCTAssertEqual(messages.first?.date, Self.date(2026, 4, 3, 10, 0))
    }

    func testReadsStoredZipExport() throws {
        // A .zip with _chat.txt and a photo, as produced by "Export chat" (stored, not deflated).
        let zip = Data(base64Encoded: "UEsDBBQAAAAAADSUOV3uaILeUQAAAFEAAAAJAAAAX2NoYXQudHh0WzE0LzEwLzIwMjYsIDE5OjMyOjA1XSBTYW06IGRpbm5lciBzYXQgN3BtPwpbMTQvMTAvMjAyNiwgMTk6MzM6MDBdIENoYXJsaWU6IHllcyEKUEsDBBQAAAAAADSUOV1lTTolAwAAAAMAAAAmAAAAMDAwMDAwMDMtUEhPVE8tMjAyNi0xMC0xNC0xOS0zNC0wMC5qcGf/2P9QSwECFAMUAAAAAAA0lDld7miC3lEAAABRAAAACQAAAAAAAAAAAAAAgAEAAAAAX2NoYXQudHh0UEsBAhQDFAAAAAAANJQ5XWVNOiUDAAAAAwAAACYAAAAAAAAAAAAAAIABeAAAADAwMDAwMDAzLVBIT1RPLTIwMjYtMTAtMTQtMTktMzQtMDAuanBnUEsFBgAAAAACAAIAiwAAAL8AAAAAAA==")!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("WhatsApp Chat - Sam.zip")
        try zip.write(to: url)

        let archive = try ChatExportZip(data: zip)
        XCTAssertEqual(archive.entries.map(\.name), ["_chat.txt", "00000003-PHOTO-2026-10-14-19-34-00.jpg"])
        let messages = try WhatsAppExportParser(myNames: ["Charlie"]).parse(fileAt: url)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].conversation, "Sam")
        XCTAssertEqual(messages[0].text, "dinner sat 7pm?")
        XCTAssertTrue(messages[1].isFromMe)
    }

    func testRejectsNonZip() {
        XCTAssertThrowsError(try ChatExportZip(data: Data("not a zip at all, just some text".utf8)))
    }
}
