import Foundation

/// One part of a MIME multipart body.
public struct MultipartPart: Sendable, Hashable {
    /// Header names are lower-cased.
    public var headers: [String: String]
    public var body: Data

    public var contentType: String? { headers["content-type"] }
    /// Content type without parameters, lower-cased (e.g. "text/html").
    public var mimeType: String? {
        contentType?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }
    public var text: String { String(decoding: body, as: UTF8.self) }
}

/// Splits `multipart/related` (and other multipart) bodies, as returned by
/// OneNote's page content endpoint when InkML is requested.
public enum MultipartParser {
    /// Reads the `boundary=` parameter from a Content-Type header.
    public static func boundary(fromContentType contentType: String) -> String? {
        for param in contentType.split(separator: ";").dropFirst() {
            let kv = param.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, kv[0].lowercased() == "boundary" else { continue }
            return kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    public static func parse(_ data: Data, boundary: String) -> [MultipartPart] {
        let bytes = [UInt8](data)
        let delimiter = [UInt8](("--" + boundary).utf8)
        var positions: [Int] = []
        var from = 0
        while let i = find(delimiter, in: bytes, from: from) {
            // A delimiter must start a line.
            if i == 0 || bytes[i - 1] == 0x0A { positions.append(i) }
            from = i + delimiter.count
        }
        var parts: [MultipartPart] = []
        for (n, start) in positions.enumerated() {
            var s = start + delimiter.count
            // "--boundary--" closes the body.
            if s + 1 < bytes.count, bytes[s] == 0x2D, bytes[s + 1] == 0x2D { break }
            // Skip transport padding and the line break after the delimiter.
            while s < bytes.count, bytes[s] == 0x20 || bytes[s] == 0x09 { s += 1 }
            if s < bytes.count, bytes[s] == 0x0D { s += 1 }
            if s < bytes.count, bytes[s] == 0x0A { s += 1 }
            var e = n + 1 < positions.count ? positions[n + 1] : bytes.count
            // The line break before the next delimiter belongs to the delimiter.
            if e > s, bytes[e - 1] == 0x0A { e -= 1 }
            if e > s, bytes[e - 1] == 0x0D { e -= 1 }
            guard e >= s else { continue }
            parts.append(part(Array(bytes[s..<e])))
        }
        return parts
    }

    static func part(_ bytes: [UInt8]) -> MultipartPart {
        // Headers end at the first blank line (CRLF CRLF, or bare LF LF).
        var headerEnd: Int?
        var bodyStart = 0
        if bytes.first == 0x0D || bytes.first == 0x0A {
            headerEnd = 0
            bodyStart = bytes.first == 0x0D && bytes.count > 1 ? 2 : 1
        } else if let i = find([0x0D, 0x0A, 0x0D, 0x0A], in: bytes, from: 0) {
            headerEnd = i; bodyStart = i + 4
        } else if let i = find([0x0A, 0x0A], in: bytes, from: 0) {
            headerEnd = i; bodyStart = i + 2
        }
        guard let headerEnd else { return MultipartPart(headers: [:], body: Data(bytes)) }
        var headers: [String: String] = [:]
        let headerText = String(decoding: bytes[0..<headerEnd], as: UTF8.self)
        for line in headerText.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return MultipartPart(headers: headers, body: Data(bytes[min(bodyStart, bytes.count)...]))
    }

    static func find(_ needle: [UInt8], in hay: [UInt8], from: Int) -> Int? {
        guard !needle.isEmpty, hay.count >= needle.count, from <= hay.count - needle.count else { return nil }
        let first = needle[0]
        var i = from
        while i <= hay.count - needle.count {
            if hay[i] == first {
                var j = 1
                while j < needle.count, hay[i + j] == needle[j] { j += 1 }
                if j == needle.count { return i }
            }
            i += 1
        }
        return nil
    }
}
