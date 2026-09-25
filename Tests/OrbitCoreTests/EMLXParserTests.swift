import XCTest
@testable import OrbitCore

enum EMLXFixture {
    static func message(to: String, subject: String, body: String = "Please see the attached handbook.") -> String {
        """
        From: Module Lead <m.lead@exeter.ac.uk>\r
        To: \(to)\r
        Subject: \(subject)\r
        Date: Tue, 22 Sep 2026 09:15:00 +0000\r
        Message-ID: <\(subject.filter(\.isLetter))@exeter.ac.uk>\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        \(body)\r

        """
    }

    static func emlx(_ message: String, flags: Int) -> Data {
        let bytes = Data(message.utf8)
        var data = Data("\(bytes.count)        \n".utf8)
        data.append(bytes)
        data.append(Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>date-received</key>
            <integer>1790068500</integer>
            <key>flags</key>
            <integer>\(flags)</integer>
        </dict>
        </plist>

        """.utf8))
        return data
    }
}

final class EMLXParserTests: XCTestCase {
    func testParsesLengthMessageAndFlags() throws {
        let msg = EMLXFixture.message(to: "cw123@exeter.ac.uk", subject: "Week 1 reading")
        let emlx = try EMLXParser.parse(EMLXFixture.emlx(msg, flags: 8_590_195_713))  // bit 0 set = read
        XCTAssertTrue(emlx.isRead)
        XCTAssertEqual(emlx.rawMessage, Data(msg.utf8))
        XCTAssertEqual(emlx.dateReceived, Date(timeIntervalSince1970: 1_790_068_500))
        XCTAssertEqual(emlx.parsed.subject, "Week 1 reading")
        XCTAssertEqual(emlx.parsed.bodyText.trimmingCharacters(in: .whitespacesAndNewlines),
                       "Please see the attached handbook.")
    }

    func testUnreadAndBadInput() throws {
        let emlx = try EMLXParser.parse(EMLXFixture.emlx(EMLXFixture.message(to: "a@b.c", subject: "x"), flags: 0))
        XCTAssertFalse(emlx.isRead)
        XCTAssertThrowsError(try EMLXParser.parse(Data("not a number\nFrom: x".utf8)))
    }

    func testFlagsFallbackForDamagedPlist() {
        let trailer = Data("<plist><dict><key>flags</key><integer>1</integer></dict".utf8)
        XCTAssertEqual(EMLXParser.readTrailer(trailer).flags, 1)
    }
}

final class EmailAppleMailReaderTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-mail-\(UUID().uuidString)")
        let exeterAcct = root.appendingPathComponent("V10/EXETER-UUID")
        let gmailAcct = root.appendingPathComponent("V10/GMAIL-UUID")
        try write(EMLXFixture.message(to: "cw123@exeter.ac.uk", subject: "Unread inbox"), flags: 0,
                  to: exeterAcct.appendingPathComponent("INBOX.mbox/ABC/Data/1/Messages/101.emlx"))
        try write(EMLXFixture.message(to: "Charlie <CW123@Exeter.ac.uk>", subject: "Partial read"), flags: 1,
                  to: exeterAcct.appendingPathComponent("INBOX.mbox/ABC/Data/Messages/102.partial.emlx"))
        try write(EMLXFixture.message(to: "someone@exeter.ac.uk", subject: "Sent item"), flags: 1,
                  to: exeterAcct.appendingPathComponent("Sent Messages.mbox/DEF/Data/Messages/103.emlx"))
        try write(EMLXFixture.message(to: "me@gmail.com", subject: "Gmail item"), flags: 0,
                  to: gmailAcct.appendingPathComponent("INBOX.mbox/GHI/Data/Messages/201.emlx"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ message: String, flags: Int, to url: URL, modified: Date = Date()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try EMLXFixture.emlx(message, flags: flags).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    func testReadsExeterMailAndSkipsSentAndOtherAccounts() async throws {
        let reader = AppleMailReader(root: root)
        let (messages, cursor) = try await reader.fetchNew(since: nil)
        XCTAssertEqual(Set(messages.map(\.id)), ["101", "102"])
        let unread = try XCTUnwrap(messages.first { $0.id == "101" })
        XCTAssertTrue(unread.isUnread)
        XCTAssertEqual(unread.account, .exeter)
        XCTAssertEqual(unread.labels, ["INBOX"])
        XCTAssertEqual(unread.from, "m.lead@exeter.ac.uk")
        XCTAssertFalse(try XCTUnwrap(messages.first { $0.id == "102" }).isUnread)

        // Nothing new since the cursor…
        let again = try await reader.fetchNew(since: cursor)
        XCTAssertTrue(again.messages.isEmpty)

        // …until a newer file appears.
        try write(EMLXFixture.message(to: "cw123@exeter.ac.uk", subject: "Brand new"), flags: 0,
                  to: root.appendingPathComponent("V10/EXETER-UUID/INBOX.mbox/ABC/Data/Messages/104.emlx"),
                  modified: Date().addingTimeInterval(60))
        let third = try await reader.fetchNew(since: again.cursor)
        XCTAssertEqual(third.messages.map(\.subject), ["Brand new"])
    }

    func testDetectsAccountFolderAndFetchesByID() async throws {
        let folders = try AppleMailReader.detectAccountFolders(root: root)
        XCTAssertEqual(folders.map(\.lastPathComponent), ["EXETER-UUID"])

        let reader = AppleMailReader(root: root, accountFolders: folders, addressSuffix: nil)
        let message = try await reader.fetchMessage(id: "102")
        XCTAssertEqual(message.subject, "Partial read")
        do {
            _ = try await reader.fetchMessage(id: "201")  // other account
            XCTFail("expected notFound")
        } catch let error as MailError {
            XCTAssertEqual(error, .notFound("201"))
        }
    }

    func testOldFilesIgnoredOnFirstSyncAndMissingRootReported() async throws {
        try write(EMLXFixture.message(to: "cw123@exeter.ac.uk", subject: "Ancient"), flags: 0,
                  to: root.appendingPathComponent("V10/EXETER-UUID/INBOX.mbox/ABC/Data/Messages/99.emlx"),
                  modified: Date().addingTimeInterval(-60 * 86_400))
        let messages = try await AppleMailReader(root: root).fetchNew(since: nil).messages
        XCTAssertFalse(messages.contains { $0.id == "99" })

        let missing = AppleMailReader(root: root.appendingPathComponent("nope"))
        do {
            _ = try await missing.fetchNew(since: nil)
            XCTFail("expected accessDenied")
        } catch let error as MailError {
            guard case .accessDenied = error else { return XCTFail("\(error)") }
        }
    }
}
