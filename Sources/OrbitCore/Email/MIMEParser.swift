import Foundation

/// Email headers in their original order. Lookups are case-insensitive and
/// return the unfolded raw value (use `MIMEParser.decodeEncodedWords` for display text).
public struct MIMEHeaders: Hashable, Sendable {
    public struct Field: Hashable, Sendable {
        public var name: String
        public var value: String
        public init(name: String, value: String) { self.name = name; self.value = value }
    }

    public var fields: [Field]
    public init(_ fields: [Field] = []) { self.fields = fields }

    public subscript(_ name: String) -> String? {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public func all(_ name: String) -> [String] {
        fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    /// The header with RFC 2047 encoded words decoded.
    public func decoded(_ name: String) -> String? { self[name].map(MIMEParser.decodeEncodedWords) }
}

/// One node of a MIME tree. Leaf bodies are already transfer-decoded
/// (base64 / quoted-printable) but still in their original charset.
public struct MIMEPart: Hashable, Sendable {
    public var headers: MIMEHeaders
    /// Lowercased media type, e.g. "text/plain" or "multipart/alternative".
    public var contentType: String
    /// Lowercased parameter names, e.g. "charset", "boundary".
    public var parameters: [String: String]
    public var body: Data
    public var parts: [MIMEPart]

    public init(headers: MIMEHeaders = MIMEHeaders(), contentType: String = "text/plain",
                parameters: [String: String] = [:], body: Data = Data(), parts: [MIMEPart] = []) {
        self.headers = headers; self.contentType = contentType; self.parameters = parameters
        self.body = body; self.parts = parts
    }

    public var isMultipart: Bool { contentType.hasPrefix("multipart/") }
    public var charset: String? { parameters["charset"] }

    /// True for attachments (which are never used as the message text).
    public var isAttachment: Bool {
        let disposition = headers["Content-Disposition"]?.lowercased() ?? ""
        return disposition.hasPrefix("attachment")
    }

    /// Body decoded to a string, for text parts.
    public var text: String { MIMEParser.decode(body, charset: charset) }

    /// Depth-first search for the first non-attachment part of a type.
    public func firstPart(ofType type: String) -> MIMEPart? {
        if isAttachment { return nil }
        if contentType == type { return self }
        for p in parts { if let hit = p.firstPart(ofType: type) { return hit } }
        return nil
    }

    /// The readable text: text/plain if there is one, otherwise HTML converted to text.
    public var bestText: String {
        if let plain = firstPart(ofType: "text/plain")?.text,
           !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return plain.replacingOccurrences(of: "\r\n", with: "\n")
        }
        if let html = firstPart(ofType: "text/html")?.text { return HTMLToText.convert(html) }
        return ""
    }
}

/// A whole parsed message with the commonly used headers pulled out.
public struct ParsedMail: Hashable, Sendable {
    public var root: MIMEPart
    public init(root: MIMEPart) { self.root = root }

    public var headers: MIMEHeaders { root.headers }
    public var subject: String { headers.decoded("Subject")?.trimmingCharacters(in: .whitespaces) ?? "" }
    public var from: MailAddress? { headers["From"].flatMap { MailAddress.parseList($0).first } }
    public var to: [MailAddress] { headers.all("To").flatMap(MailAddress.parseList) }
    public var cc: [MailAddress] { headers.all("Cc").flatMap(MailAddress.parseList) }
    public var replyTo: MailAddress? { headers["Reply-To"].flatMap { MailAddress.parseList($0).first } }
    public var date: Date? { headers["Date"].flatMap(MIMEParser.parseDate) }
    public var messageID: String? { headers["Message-ID"]?.trimmingCharacters(in: .whitespaces) }
    public var bodyText: String { root.bestText }

    /// Converts to Orbit's email model. `to` includes Cc recipients so account filters see them.
    public func emailMessage(id: String, account: MailAccount, isUnread: Bool = true,
                             labels: [String] = [], fallbackDate: Date = Date()) -> EmailMessage {
        let body = bodyText
        return EmailMessage(
            id: id, account: account, threadID: messageID, from: from?.address ?? "",
            fromName: from?.name, to: (to + cc).map(\.address), subject: subject,
            snippet: MIMEParser.snippet(body), body: body, date: date ?? fallbackDate,
            isUnread: isUnread, labels: labels
        )
    }
}

/// A small, dependency-free RFC 822 / MIME parser used for Apple Mail files and
/// shared helpers (charsets, encoded words, dates) used by the API clients.
public enum MIMEParser {
    public static func parse(_ data: Data) -> ParsedMail {
        ParsedMail(root: parsePart(ArraySlice([UInt8](data))))
    }

    public static func parse(_ string: String) -> ParsedMail { parse(Data(string.utf8)) }

    public static func parsePart(_ bytes: ArraySlice<UInt8>, depth: Int = 0) -> MIMEPart {
        let (headerBytes, body) = splitHeaders(bytes)
        let headers = parseHeaders(headerText(headerBytes))
        let (type, params) = parseContentType(headers["Content-Type"] ?? "text/plain")
        var part = MIMEPart(headers: headers, contentType: type, parameters: params)
        if type.hasPrefix("multipart/"), let boundary = params["boundary"], depth < 20 {
            part.parts = splitMultipart(body, boundary: boundary).map { parsePart($0, depth: depth + 1) }
        } else {
            let encoding = headers["Content-Transfer-Encoding"]?.trimmingCharacters(in: .whitespaces).lowercased()
            switch encoding {
            case "base64": part.body = decodeBase64(body)
            case "quoted-printable": part.body = decodeQuotedPrintable(body)
            default: part.body = Data(body)
            }
        }
        return part
    }

    // MARK: Headers

    /// Parses a header block, unfolding continuation lines.
    public static func parseHeaders(_ text: String) -> MIMEHeaders {
        var fields: [MIMEHeaders.Field] = []
        // Split on Character.isNewline: in Swift "\r\n" is one Character, so splitting on "\n" alone misses it.
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            if let first = line.first, first == " " || first == "\t" {
                if !fields.isEmpty { fields[fields.count - 1].value += " " + line.trimmingCharacters(in: .whitespaces) }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { fields.append(.init(name: name, value: value)) }
        }
        return MIMEHeaders(fields)
    }

    /// Splits `type/subtype; key=value; key="quoted value"` into a lowercased type and parameters.
    public static func parseContentType(_ value: String) -> (type: String, parameters: [String: String]) {
        var pieces: [String] = []
        var current = ""
        var inQuotes = false
        for ch in value {
            if ch == "\"" { inQuotes.toggle(); current.append(ch) }
            else if ch == ";" && !inQuotes { pieces.append(current); current = "" }
            else { current.append(ch) }
        }
        pieces.append(current)
        let type = pieces.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        var params: [String: String] = [:]
        for p in pieces.dropFirst() {
            guard let eq = p.firstIndex(of: "=") else { continue }
            let key = p[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var val = p[p.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\""), val.hasSuffix("\""), val.count >= 2 { val = String(val.dropFirst().dropLast()) }
            params[key] = val
        }
        return (type.isEmpty ? "text/plain" : type, params)
    }

    // MARK: Encoded words (RFC 2047)

    /// Decodes `=?utf-8?B?…?=` and `=?iso-8859-1?Q?…?=` words. Whitespace between
    /// adjacent encoded words is dropped, as the RFC requires.
    public static func decodeEncodedWords(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        var out = ""
        var gap = ""
        var afterEncoded = false
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "=", let (text, next) = encodedWord(in: s, at: i) {
                if !afterEncoded { out += gap }
                gap = ""
                out += text
                afterEncoded = true
                i = next
                continue
            }
            let ch = s[i]
            if afterEncoded && (ch == " " || ch == "\t") {
                gap.append(ch)
            } else {
                out += gap; gap = ""; afterEncoded = false
                out.append(ch)
            }
            i = s.index(after: i)
        }
        return out + gap
    }

    private static func encodedWord(in s: String, at start: String.Index) -> (String, String.Index)? {
        guard s[start...].hasPrefix("=?") else { return nil }
        let afterPrefix = s.index(start, offsetBy: 2)
        guard let q1 = s[afterPrefix...].firstIndex(of: "?") else { return nil }
        let charset = String(s[afterPrefix..<q1].split(separator: "*").first ?? "")
        let encIdx = s.index(after: q1)
        guard encIdx < s.endIndex else { return nil }
        let enc = s[encIdx].uppercased()
        let q2 = s.index(after: encIdx)
        guard q2 < s.endIndex, s[q2] == "?", enc == "B" || enc == "Q" else { return nil }
        let textStart = s.index(after: q2)
        guard let end = s.range(of: "?=", range: textStart..<s.endIndex) else { return nil }
        let text = s[textStart..<end.lowerBound]
        guard !text.contains(" ") else { return nil }
        let bytes: Data
        if enc == "B" {
            bytes = decodeBase64(ArraySlice(Array(text.utf8)))
        } else {
            var raw: [UInt8] = []
            var u = Array(text.utf8)[...]
            while let b = u.popFirst() {
                if b == UInt8(ascii: "_") { raw.append(0x20) }
                else if b == UInt8(ascii: "="), u.count >= 2, let v = hexByte(u[u.startIndex], u[u.startIndex + 1]) {
                    raw.append(v); u = u.dropFirst(2)
                } else { raw.append(b) }
            }
            bytes = Data(raw)
        }
        return (decode(bytes, charset: charset), end.upperBound)
    }

    /// Encodes a header value as a UTF-8 encoded word if it isn't plain ASCII.
    public static func encodeHeader(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { !$0.isASCII }) else { return s }
        // Keep each word under the 75-char limit, splitting on character boundaries.
        var words: [String] = []
        var chunk = ""
        for ch in s {
            if (chunk + String(ch)).utf8.count > 45 { words.append(chunk); chunk = "" }
            chunk.append(ch)
        }
        if !chunk.isEmpty { words.append(chunk) }
        return words.map { "=?UTF-8?B?\(Data($0.utf8).base64EncodedString())?=" }.joined(separator: "\r\n ")
    }

    /// A display name for an address header: quoted if needed, encoded if non-ASCII.
    public static func encodeHeaderWord(_ s: String) -> String {
        if s.unicodeScalars.contains(where: { !$0.isASCII }) { return encodeHeader(s) }
        let specials = CharacterSet(charactersIn: "()<>[]:;@\\,.\"")
        guard s.unicodeScalars.contains(where: specials.contains) else { return s }
        return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: Transfer encodings

    public static func decodeQuotedPrintable(_ bytes: ArraySlice<UInt8>) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var i = bytes.startIndex
        let end = bytes.endIndex
        while i < end {
            let b = bytes[i]
            guard b == UInt8(ascii: "=") else { out.append(b); i += 1; continue }
            if i + 1 < end, bytes[i + 1] == 10 { i += 2; continue }                       // soft break "=\n"
            if i + 2 < end, bytes[i + 1] == 13, bytes[i + 2] == 10 { i += 3; continue }   // soft break "=\r\n"
            if i + 2 < end, let v = hexByte(bytes[i + 1], bytes[i + 2]) { out.append(v); i += 3; continue }
            if i + 1 == end { break }  // trailing "=" at end of body
            out.append(b); i += 1
        }
        return Data(out)
    }

    public static func decodeQuotedPrintable(_ s: String) -> Data { decodeQuotedPrintable(ArraySlice(Array(s.utf8))) }

    /// Lenient base64: ignores line breaks and junk, and fixes missing padding.
    public static func decodeBase64(_ bytes: ArraySlice<UInt8>) -> Data {
        var clean = bytes.filter { b in
            (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || (b >= 48 && b <= 57) || b == 43 || b == 47
        }
        if clean.count % 4 == 1 { clean.removeLast() }  // a lone trailing char can't encode a byte
        while clean.count % 4 != 0 { clean.append(UInt8(ascii: "=")) }
        return Data(base64Encoded: Data(clean)) ?? Data()
    }

    /// Gmail's URL-safe base64 (`-` and `_`, often unpadded).
    public static func decodeBase64URL(_ s: String) -> Data {
        let std = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return decodeBase64(ArraySlice(Array(std.utf8)))
    }

    public static func encodeBase64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: Charsets

    /// Decodes text in the given charset. Unknown charsets try UTF-8, then Windows-1252
    /// (which is also used for ISO-8859-1, as browsers do, since mislabelled mail is common).
    public static func decode(_ data: Data, charset: String?) -> String {
        let cs = (charset ?? "utf-8").trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).lowercased()
        switch cs {
        case "iso-8859-1", "iso8859-1", "latin1", "latin-1", "l1", "iso-8859-15", "windows-1252", "cp1252", "x-cp1252":
            return windows1252(data)
        case "utf-16", "utf16":
            return String(data: data, encoding: .utf16) ?? windows1252(data)
        case "utf-16le": return String(data: data, encoding: .utf16LittleEndian) ?? windows1252(data)
        case "utf-16be": return String(data: data, encoding: .utf16BigEndian) ?? windows1252(data)
        default:
            return String(data: data, encoding: .utf8) ?? windows1252(data)
        }
    }

    private static let cp1252High: [UInt32] = [
        0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F,
        0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178,
    ]

    private static func windows1252(_ data: Data) -> String {
        var s = String.UnicodeScalarView()
        for b in data {
            let v = (0x80...0x9F).contains(b) ? cp1252High[Int(b) - 0x80] : UInt32(b)
            if let scalar = Unicode.Scalar(v) { s.append(scalar) }
        }
        return String(s)
    }

    // MARK: Dates

    private static let zoneOffsets: [String: Int] = [
        "UT": 0, "UTC": 0, "GMT": 0, "Z": 0, "BST": 60, "CET": 60, "CEST": 120,
        "EST": -300, "EDT": -240, "CST": -360, "CDT": -300, "MST": -420, "MDT": -360, "PST": -480, "PDT": -420,
    ]
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let weekdays: Set<String> = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]

    /// Parses RFC 2822 dates like `Tue, 23 Sep 2026 10:15:00 +0100 (BST)`, tolerating
    /// missing weekday, seconds or zone and two-digit years.
    public static func parseDate(_ raw: String) -> Date? {
        var s = ""
        var depth = 0
        for ch in raw {  // strip (comments)
            if ch == "(" { depth += 1 } else if ch == ")" { depth = max(0, depth - 1) } else if depth == 0 { s.append(ch) }
        }
        var tokens = s.replacingOccurrences(of: ",", with: " ").split(whereSeparator: \.isWhitespace).map(String.init)
        if let first = tokens.first, weekdays.contains(first.prefix(3).lowercased()) { tokens.removeFirst() }
        guard tokens.count >= 4 else { return nil }
        var day: Int?, monthIndex: Int?
        // Accept both "23 Sep" and "Sep 23".
        if let d = Int(tokens[0]) { day = d; monthIndex = months.firstIndex(of: tokens[1].prefix(3).lowercased()) }
        else if let d = Int(tokens[1]) { day = d; monthIndex = months.firstIndex(of: tokens[0].prefix(3).lowercased()) }
        guard let day, let monthIndex, var year = Int(tokens[2]) else { return nil }
        if year < 50 { year += 2000 } else if year < 100 { year += 1900 }
        let time = tokens[3].split(separator: ":").compactMap { Int($0) }
        guard time.count >= 2 else { return nil }
        var offsetMinutes = 0
        if tokens.count >= 5 {
            let z = tokens[4]
            if let sign = z.first, sign == "+" || sign == "-", z.count >= 5, let hhmm = Int(z.dropFirst().prefix(4)) {
                offsetMinutes = (hhmm / 100 * 60 + hhmm % 100) * (sign == "-" ? -1 : 1)
            } else {
                offsetMinutes = zoneOffsets[z.uppercased()] ?? 0
            }
        }
        var cal = Calendar(identifier: .gregorian)
        guard let tz = TimeZone(secondsFromGMT: offsetMinutes * 60) else { return nil }
        cal.timeZone = tz
        return cal.date(from: DateComponents(year: year, month: monthIndex + 1, day: day, hour: time[0],
                                             minute: time[1], second: time.count > 2 ? time[2] : 0))
    }

    /// RFC 2822 date string for outgoing headers.
    public static func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss '+0000'"
        return f.string(from: date)
    }

    // MARK: Helpers

    /// A one-line preview of body text (about 200 characters).
    public static func snippet(_ body: String, length: Int = 200) -> String {
        let flat = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count <= length ? flat : String(flat.prefix(length)) + "…"
    }

    private static func splitHeaders(_ bytes: ArraySlice<UInt8>) -> (ArraySlice<UInt8>, ArraySlice<UInt8>) {
        var i = bytes.startIndex
        // No headers at all: the part starts with a blank line.
        if bytes.first == 10 { return (bytes[i..<i], bytes.dropFirst()) }
        if bytes.starts(with: [13, 10]) { return (bytes[i..<i], bytes.dropFirst(2)) }
        while i < bytes.endIndex {
            if bytes[i] == 10 {
                let n = i + 1
                if n < bytes.endIndex, bytes[n] == 10 { return (bytes[bytes.startIndex..<i], bytes[(n + 1)...]) }
                if n + 1 < bytes.endIndex, bytes[n] == 13, bytes[n + 1] == 10 {
                    return (bytes[bytes.startIndex..<i], bytes[(n + 2)...])
                }
            }
            i += 1
        }
        return (bytes, bytes[bytes.endIndex...])
    }

    private static func headerText(_ bytes: ArraySlice<UInt8>) -> String {
        String(bytes: bytes, encoding: .utf8) ?? windows1252(Data(bytes))
    }

    /// Splits a multipart body on `--boundary` lines. The line break before a
    /// boundary belongs to the boundary, not the part.
    static func splitMultipart(_ body: ArraySlice<UInt8>, boundary: String) -> [ArraySlice<UInt8>] {
        let delim = Array("--\(boundary)".utf8)
        var parts: [ArraySlice<UInt8>] = []
        var partStart: Int?
        var lineStart = body.startIndex
        while lineStart < body.endIndex {
            let lineEnd = body[lineStart...].firstIndex(of: 10) ?? body.endIndex
            var contentEnd = lineEnd
            if contentEnd > lineStart, body[contentEnd - 1] == 13 { contentEnd -= 1 }
            let line = body[lineStart..<contentEnd]
            if line.starts(with: delim) {
                let tail = line.dropFirst(delim.count)
                let isClose = tail.starts(with: [45, 45])
                if (isClose ? tail.dropFirst(2) : tail).allSatisfy({ $0 == 32 || $0 == 9 }) {
                    if let s = partStart {
                        var end = lineStart
                        if end > s, body[end - 1] == 10 { end -= 1 }
                        if end > s, body[end - 1] == 13 { end -= 1 }
                        parts.append(body[s..<max(s, end)])
                    }
                    if isClose { return parts }
                    partStart = min(lineEnd + 1, body.endIndex)
                }
            }
            lineStart = min(lineEnd + 1, body.endIndex)
        }
        // Truncated message with no closing boundary: keep what we have.
        if let s = partStart, s < body.endIndex { parts.append(body[s...]) }
        return parts
    }

    private static func hexByte(_ a: UInt8, _ b: UInt8) -> UInt8? {
        func v(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: c - 48
            case 65...70: c - 55
            case 97...102: c - 87
            default: nil
            }
        }
        guard let hi = v(a), let lo = v(b) else { return nil }
        return hi << 4 | lo
    }
}
