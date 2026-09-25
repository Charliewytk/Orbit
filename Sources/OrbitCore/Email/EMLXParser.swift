import Foundation

/// One message file from Apple Mail's local store.
public struct EMLXMessage: Sendable {
    /// The RFC 822 message bytes.
    public var rawMessage: Data
    /// Apple Mail's flag bits from the plist trailer.
    public var flags: Int
    public var dateReceived: Date?
    /// True for `.partial.emlx` files, where attachments live in a separate folder.
    public var isPartial: Bool

    public init(rawMessage: Data, flags: Int = 0, dateReceived: Date? = nil, isPartial: Bool = false) {
        self.rawMessage = rawMessage; self.flags = flags; self.dateReceived = dateReceived; self.isPartial = isPartial
    }

    /// Flag bit 0 is "read".
    public var isRead: Bool { flags & 1 != 0 }
    /// Flag bit 4 is "flagged".
    public var isFlagged: Bool { flags & (1 << 4) != 0 }

    public var parsed: ParsedMail { MIMEParser.parse(rawMessage) }
}

/// Parses Apple Mail `.emlx` files: a first line with the message's byte count,
/// then the RFC 822 message, then an XML plist trailer holding flags.
public enum EMLXParser {
    public enum ParseError: Error, Sendable { case missingLength, truncated }

    public static func parse(_ data: Data, isPartial: Bool = false) throws -> EMLXMessage {
        let bytes = [UInt8](data)
        guard let newline = bytes.firstIndex(of: 10),
              let length = Int(String(decoding: bytes[..<newline], as: UTF8.self).trimmingCharacters(in: .whitespaces)),
              length >= 0
        else { throw ParseError.missingLength }
        let start = newline + 1
        // Tolerate a slightly short file (e.g. still being written): take what's there.
        let end = min(start + length, bytes.count)
        guard end > start || length == 0 else { throw ParseError.truncated }
        let message = Data(bytes[start..<end])
        let trailer = end < bytes.count ? Data(bytes[end...]) : Data()
        let (flags, received) = readTrailer(trailer)
        return EMLXMessage(rawMessage: message, flags: flags, dateReceived: received, isPartial: isPartial)
    }

    public static func parse(contentsOf url: URL) throws -> EMLXMessage {
        try parse(Data(contentsOf: url), isPartial: url.lastPathComponent.hasSuffix(".partial.emlx"))
    }

    /// Reads `flags` and `date-received` from the plist trailer.
    static func readTrailer(_ data: Data) -> (flags: Int, received: Date?) {
        guard !data.isEmpty else { return (0, nil) }
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            let flags = (plist["flags"] as? NSNumber)?.intValue ?? (plist["flags"] as? Int) ?? 0
            let received = ((plist["date-received"] as? NSNumber)?.doubleValue ?? (plist["date-received"] as? Double))
                .map { Date(timeIntervalSince1970: $0) }
            return (flags, received)
        }
        // Fallback for a damaged plist: pull the flags integer out by hand.
        let text = String(decoding: data, as: UTF8.self)
        guard let key = text.range(of: "<key>flags</key>"),
              let open = text.range(of: "<integer>", range: key.upperBound..<text.endIndex),
              let close = text.range(of: "</integer>", range: open.upperBound..<text.endIndex)
        else { return (0, nil) }
        return (Int(text[open.upperBound..<close.lowerBound]) ?? 0, nil)
    }
}
