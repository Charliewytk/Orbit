import XCTest
@testable import OrbitCore

final class IMessageDecodingTests: XCTestCase {
    /// A trimmed-down typedstream as found in `message.attributedBody`.
    static func attributedBody(_ text: String) -> Data {
        let utf8 = Array(text.utf8)
        var b: [UInt8] = [0x04, 0x0B] + Array("streamtyped".utf8) + [0x81, 0xE8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84, 0x12]
        b += Array("NSAttributedString".utf8) + [0x00, 0x84, 0x84, 0x08] + Array("NSObject".utf8) + [0x00, 0x85, 0x92, 0x84, 0x84, 0x84, 0x08]
        b += Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2B]
        if utf8.count < 0x80 {
            b.append(UInt8(utf8.count))
        } else {
            b += [0x81, UInt8(utf8.count & 0xFF), UInt8(utf8.count >> 8)]
        }
        b += utf8 + [0x86, 0x84, 0x02, 0x69, 0x49, 0x01, 0x0F, 0x92, 0x84, 0x84, 0x84, 0x0C]
        b += Array("NSDictionary".utf8) + [0x00, 0x94, 0x84, 0x01, 0x69, 0x01]
        return Data(b)
    }

    func testDecodesShortAttributedBody() {
        XCTAssertEqual(IMessageDecoding.text(fromAttributedBody: Self.attributedBody("dinner sat 7pm? 🍝")), "dinner sat 7pm? 🍝")
    }

    func testDecodesLongAttributedBody() {
        let long = String(repeating: "revision session in the Forum library tomorrow at 2, bring notes. ", count: 4)
        XCTAssertGreaterThan(long.utf8.count, 0x80)
        XCTAssertEqual(IMessageDecoding.text(fromAttributedBody: Self.attributedBody(long)),
                       long.trimmingCharacters(in: .whitespaces))
    }

    func testStripsAttachmentPlaceholder() {
        XCTAssertEqual(IMessageDecoding.text(fromAttributedBody: Self.attributedBody("\u{FFFC}look at this")), "look at this")
        XCTAssertNil(IMessageDecoding.text(fromAttributedBody: Self.attributedBody("\u{FFFC}")))
    }

    func testRejectsGarbage() {
        XCTAssertNil(IMessageDecoding.text(fromAttributedBody: Data([0x01, 0x02, 0x03])))
        XCTAssertNil(IMessageDecoding.text(fromAttributedBody: Data("NSString".utf8)))
    }

    func testAppleDatesInNanosecondsAndSeconds() {
        let date = Date(timeIntervalSince1970: 1_792_002_720)   // 14 Oct 2026 18:32 UTC
        let seconds: Int64 = 1_792_002_720 - 978_307_200
        XCTAssertEqual(IMessageDecoding.date(fromAppleTimestamp: seconds), date)
        XCTAssertEqual(IMessageDecoding.date(fromAppleTimestamp: seconds * 1_000_000_000), date)
        XCTAssertEqual(IMessageDecoding.appleTimestamp(from: date), seconds * 1_000_000_000)
        XCTAssertEqual(IMessageDecoding.appleTimestamp(from: date, nanoseconds: false), seconds)
    }
}
