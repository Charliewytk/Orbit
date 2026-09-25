import Foundation

/// Pure-Swift MD5 (RFC 1321). Only used to check Moodle's SSO signature,
/// which is `md5(siteURL + passport)`. CryptoKit's `Insecure.MD5` isn't
/// available on Linux, so this keeps OrbitCore portable. Not for security.
public enum MD5 {
    private static let shifts: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]

    /// K[i] = floor(abs(sin(i + 1)) × 2^32).
    private static let table: [UInt32] = (0..<64).map { UInt32(truncatingIfNeeded: Int64(abs(sin(Double($0 + 1))) * 4_294_967_296)) }

    /// The 16-byte digest of `data`.
    public static func digest(_ data: Data) -> [UInt8] {
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) &* 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for i in 0..<8 { message.append(UInt8(truncatingIfNeeded: bitLength >> (8 * UInt64(i)))) }

        var a0: UInt32 = 0x67452301, b0: UInt32 = 0xefcdab89, c0: UInt32 = 0x98badcfe, d0: UInt32 = 0x10325476
        var words = [UInt32](repeating: 0, count: 16)
        for chunk in stride(from: 0, to: message.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                words[i] = UInt32(message[j]) | UInt32(message[j + 1]) << 8 | UInt32(message[j + 2]) << 16 | UInt32(message[j + 3]) << 24
            }
            var a = a0, b = b0, c = c0, d = d0
            for i in 0..<64 {
                var f: UInt32, g: Int
                switch i {
                case 0..<16: f = (b & c) | (~b & d); g = i
                case 16..<32: f = (d & b) | (~d & c); g = (5 * i + 1) % 16
                case 32..<48: f = b ^ c ^ d; g = (3 * i + 5) % 16
                default: f = c ^ (b | ~d); g = (7 * i) % 16
                }
                f = f &+ a &+ table[i] &+ words[g]
                a = d; d = c; c = b
                b = b &+ ((f << shifts[i]) | (f >> (32 - shifts[i])))
            }
            a0 = a0 &+ a; b0 = b0 &+ b; c0 = c0 &+ c; d0 = d0 &+ d
        }
        return [a0, b0, c0, d0].flatMap { v in (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * UInt32($0))) } }
    }

    /// Lower-case hex digest of the UTF-8 bytes of `string`.
    public static func hex(_ string: String) -> String {
        digest(Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
