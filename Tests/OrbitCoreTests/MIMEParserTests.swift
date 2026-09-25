import XCTest
@testable import OrbitCore

final class MIMEParserTests: XCTestCase {
    static let alternative = """
    From: =?UTF-8?B?RHIgSm9zw6kgU21pdGg=?= <j.smith@exeter.ac.uk>
    To: "Student, Charlie" <cw123@exeter.ac.uk>, other@example.com
    Subject: =?utf-8?Q?BEM2031_essay_=E2=80=93?=
     =?utf-8?B?IGRlYWRsaW5lIGV4dGVuZGVk?=
    Date: Tue, 22 Sep 2026 10:15:00 +0100 (BST)
    Message-ID: <abc123@exeter.ac.uk>
    MIME-Version: 1.0
    Content-Type: multipart/alternative;
     boundary="==outer=="

    This is a multi-part message in MIME format.

    --==outer==
    Content-Type: text/plain; charset="utf-8"
    Content-Transfer-Encoding: quoted-printable

    Hi Charlie,=0A=0AThe deadline is now Friday =E2=80=93 5pm. This is a long l=
    ine that was soft-wrapped.
    --==outer==
    Content-Type: text/html; charset=utf-8
    Content-Transfer-Encoding: base64

    PHA+SGkgQ2hhcmxpZSw8L3A+PHA+VGhlIGRlYWRsaW5lIGlzIG5vdyBGcmlkYXkuPC9wPg==
    --==outer==--
    """

    func testMultipartAlternativeWithQPBase64AndEncodedWords() throws {
        let mail = MIMEParser.parse(Self.alternative.replacingOccurrences(of: "\n", with: "\r\n"))
        XCTAssertEqual(mail.subject, "BEM2031 essay – deadline extended")
        XCTAssertEqual(mail.from?.name, "Dr José Smith")
        XCTAssertEqual(mail.from?.address, "j.smith@exeter.ac.uk")
        XCTAssertEqual(mail.to.map(\.address), ["cw123@exeter.ac.uk", "other@example.com"])
        XCTAssertEqual(mail.to.first?.name, "Student, Charlie")
        XCTAssertEqual(mail.messageID, "<abc123@exeter.ac.uk>")
        XCTAssertEqual(mail.root.contentType, "multipart/alternative")
        XCTAssertEqual(mail.root.parts.count, 2)
        XCTAssertEqual(mail.bodyText,
                       "Hi Charlie,\n\nThe deadline is now Friday – 5pm. This is a long line that was soft-wrapped.")
        let html = try XCTUnwrap(mail.root.firstPart(ofType: "text/html"))
        XCTAssertEqual(html.text, "<p>Hi Charlie,</p><p>The deadline is now Friday.</p>")
        // 10:15 BST = 09:15 UTC.
        XCTAssertEqual(mail.date, Date(timeIntervalSince1970: 1_790_068_500))
    }

    func testNestedMixedSkipsAttachmentsAndFallsBackToHTML() {
        let raw = """
        Subject: Nested
        Content-Type: multipart/mixed; boundary=mix

        --mix
        Content-Type: multipart/alternative; boundary="alt"

        --alt
        Content-Type: text/html; charset=windows-1252
        Content-Transfer-Encoding: quoted-printable

        <div>=93Quoted=94 caf=E9</div><div>next</div>
        --alt--
        --mix
        Content-Type: text/plain; name="notes.txt"
        Content-Disposition: attachment; filename="notes.txt"

        attachment text
        --mix--
        """
        let mail = MIMEParser.parse(raw)
        XCTAssertEqual(mail.root.parts.count, 2)
        XCTAssertEqual(mail.root.parts[0].parts.count, 1)
        XCTAssertTrue(mail.root.parts[1].isAttachment)
        XCTAssertEqual(mail.bodyText, "“Quoted” café\nnext")
    }

    func testLatin1HeaderAndBody() {
        var data = Data("Subject: =?iso-8859-1?Q?R=E9union?=\nContent-Type: text/plain; charset=iso-8859-1\n\n".utf8)
        data.append(contentsOf: [0x43, 0x61, 0x66, 0xE9])  // "Café" in Latin-1
        let mail = MIMEParser.parse(data)
        XCTAssertEqual(mail.subject, "Réunion")
        XCTAssertEqual(mail.bodyText, "Café")
    }

    func testEncodedWordEdgeCases() {
        XCTAssertEqual(MIMEParser.decodeEncodedWords("=?UTF-8?Q?a?= =?UTF-8?Q?b?="), "ab")
        XCTAssertEqual(MIMEParser.decodeEncodedWords("Re: =?UTF-8?Q?caf=C3=A9?= time"), "Re: café time")
        XCTAssertEqual(MIMEParser.decodeEncodedWords("plain =? not encoded"), "plain =? not encoded")
    }

    func testDates() {
        let expected = Date(timeIntervalSince1970: 1_790_068_500)
        XCTAssertEqual(MIMEParser.parseDate("22 Sep 2026 09:15:00 GMT"), expected)
        XCTAssertEqual(MIMEParser.parseDate("Tue, 22 Sep 2026 05:15:00 -0400"), expected)
        XCTAssertEqual(MIMEParser.parseDate("Tue, 22 Sep 26 09:15 +0000"), expected)
        XCTAssertNil(MIMEParser.parseDate("not a date"))
    }

    func testAddressesAndBase64URL() {
        let list = MailAddress.parseList(#""Smith, Jo" <jo@x.com>, bob@y.com (Bob), <z@z.com>"#)
        XCTAssertEqual(list.map(\.address), ["jo@x.com", "bob@y.com", "z@z.com"])
        XCTAssertEqual(list.map(\.name), ["Smith, Jo", "Bob", nil])
        XCTAssertEqual(list[0].formatted, #""Smith, Jo" <jo@x.com>"#)
        XCTAssertEqual(String(decoding: MIMEParser.decodeBase64URL("PDw_Pz4-"), as: UTF8.self), "<<??>>")
    }
}
