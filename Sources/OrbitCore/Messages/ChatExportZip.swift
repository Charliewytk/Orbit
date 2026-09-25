import Foundation

/// Minimal read-only ZIP reader for chat exports (WhatsApp "Export chat" .zip).
///
/// Supports stored entries on every platform and DEFLATE entries on Apple
/// platforms, where `NSData.decompressed(using: .zlib)` decodes raw DEFLATE.
/// No ZIP64, encryption or multi-disk archives: exports never use them.
public struct ChatExportZip: Sendable {
    public struct Entry: Hashable, Sendable {
        public var name: String
        public var method: UInt16
        public var compressedSize: Int
        public var uncompressedSize: Int
        var localHeaderOffset: Int
    }

    public enum ZipError: Error, CustomStringConvertible, Sendable {
        case notAZip, corrupt(String), unsupportedMethod(UInt16), encrypted

        public var description: String {
            switch self {
            case .notAZip: "Not a ZIP file"
            case .corrupt(let s): "Corrupt ZIP (\(s))"
            case .unsupportedMethod(let m): "Unsupported ZIP compression method \(m) on this platform"
            case .encrypted: "Encrypted ZIP entries aren't supported"
            }
        }
    }

    let bytes: [UInt8]
    public let entries: [Entry]

    public init(data: Data) throws {
        bytes = [UInt8](data)
        entries = try Self.readDirectory(bytes)
    }

    func u16(_ at: Int) -> Int { Self.u16(bytes, at) }
    func u32(_ at: Int) -> Int { Self.u32(bytes, at) }
    static func u16(_ b: [UInt8], _ at: Int) -> Int { Int(b[at]) | Int(b[at + 1]) << 8 }
    static func u32(_ b: [UInt8], _ at: Int) -> Int { u16(b, at) | u16(b, at + 2) << 16 }

    static func readDirectory(_ b: [UInt8]) throws -> [Entry] {
        guard b.count >= 22 else { throw ZipError.notAZip }
        // End-of-central-directory record: last 22 bytes plus an optional comment.
        var eocd = -1
        var i = b.count - 22
        let floor = max(0, b.count - 22 - 65_535)
        while i >= floor {
            if b[i] == 0x50, b[i + 1] == 0x4B, b[i + 2] == 0x05, b[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }
        let count = u16(b, eocd + 10)
        var p = u32(b, eocd + 16)
        var entries: [Entry] = []
        for _ in 0..<count {
            guard p + 46 <= b.count, u32(b, p) == 0x0201_4B50 else { throw ZipError.corrupt("central directory") }
            let flags = u16(b, p + 8)
            let nameLen = u16(b, p + 28), extraLen = u16(b, p + 30), commentLen = u16(b, p + 32)
            guard p + 46 + nameLen <= b.count else { throw ZipError.corrupt("name") }
            let nameBytes = Array(b[(p + 46)..<(p + 46 + nameLen)])
            // UTF-8 when flagged or valid, otherwise the old DOS code page (close enough as Latin-1).
            let name = flags & 0x800 != 0 ? String(decoding: nameBytes, as: UTF8.self)
                : String(bytes: nameBytes, encoding: .utf8) ?? String(nameBytes.map { Character(Unicode.Scalar($0)) })
            if flags & 1 != 0, !name.hasSuffix("/") {
                entries.append(Entry(name: name, method: 0xFFFF, compressedSize: 0, uncompressedSize: 0, localHeaderOffset: -1))
            } else {
                entries.append(Entry(name: name, method: UInt16(u16(b, p + 10)), compressedSize: u32(b, p + 20),
                                     uncompressedSize: u32(b, p + 24), localHeaderOffset: u32(b, p + 42)))
            }
            p += 46 + nameLen + extraLen + commentLen
        }
        return entries
    }

    /// The uncompressed bytes of an entry.
    public func contents(of entry: Entry) throws -> Data {
        if entry.method == 0xFFFF { throw ZipError.encrypted }
        let h = entry.localHeaderOffset
        guard h >= 0, h + 30 <= bytes.count, u32(h) == 0x0403_4B50 else { throw ZipError.corrupt("local header") }
        let start = h + 30 + u16(h + 26) + u16(h + 28)
        let end = start + entry.compressedSize
        guard end <= bytes.count else { throw ZipError.corrupt("entry data") }
        let raw = Data(bytes[start..<end])
        switch entry.method {
        case 0:
            return raw
        case 8:
            #if canImport(Darwin)
            return try (raw as NSData).decompressed(using: .zlib) as Data
            #else
            throw ZipError.unsupportedMethod(8)
            #endif
        default:
            throw ZipError.unsupportedMethod(entry.method)
        }
    }
}
