import XCTest
@testable import OrbitCore

final class MD5Tests: XCTestCase {
    func testKnownVectors() {
        XCTAssertEqual(MD5.hex(""), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(MD5.hex("abc"), "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(MD5.hex("message digest"), "f96b697d7cb7938d525a2f31aaf161d0")
        XCTAssertEqual(MD5.hex("The quick brown fox jumps over the lazy dog"), "9e107d9d372bb6826bd81d3542a419d6")
        // Longer than one 64-byte block.
        XCTAssertEqual(MD5.hex(String(repeating: "1234567890", count: 8)), "57edf4a22be3c955ac49da2e2107b67a")
        XCTAssertEqual(MD5.hex("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"), "d174ab98d277d9f5a5611c2c9f419d9f")
    }
}
