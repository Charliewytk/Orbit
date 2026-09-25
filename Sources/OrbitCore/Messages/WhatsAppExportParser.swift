import Foundation

/// Reads a WhatsApp "Export chat" file. WhatsApp has no API for personal chats,
/// so exporting (chat → ⋯ → Export chat → Without media) is the supported way in.
///
/// Handles both layouts:
/// - iOS:     `[14/10/2026, 19:32:05] Sam: text`
/// - Android: `14/10/2026, 19:32 - Sam: text`
/// with 2- or 4-digit years, 12-hour times ("7:32 pm", "7:32 PM" with a narrow
/// no-break space), multi-line messages and the invisible direction marks WhatsApp
/// adds. System lines ("Messages and calls are end-to-end encrypted…") and media
/// placeholders ("<Media omitted>", "image omitted") are dropped.
///
/// Dates are day/month (UK) unless the file can only be month/day (a first
/// number never above 12 and a second one that is).
public struct WhatsAppExportParser: Sendable {
    /// Your own display names in exports, used to set `isFromMe`.
    public var myNames: Set<String>
    public var timeZone: TimeZone

    public init(myNames: Set<String> = [], timeZone: TimeZone = TimeZone(identifier: "Europe/London")!) {
        self.myNames = myNames; self.timeZone = timeZone
    }

    public enum ExportError: Error, CustomStringConvertible, Sendable {
        case noChatText
        case zipUnsupported(String)

        public var description: String {
            switch self {
            case .noChatText: "No chat text (.txt) was found in the export."
            case .zipUnsupported(let why): "Couldn't open the WhatsApp .zip: \(why). Share the _chat.txt file instead."
            }
        }
    }

    // MARK: Files

    /// Reads an exported `.txt`, or a `.zip` export containing `_chat.txt`.
    public func parse(fileAt url: URL, conversation: String? = nil) throws -> [ChatMessage] {
        let name = conversation ?? Self.conversationName(from: url)
        if url.pathExtension.lowercased() == "zip" {
            return parse(try Self.chatText(fromZipAt: url), conversation: name)
        }
        return parse(Self.decodeText(try Data(contentsOf: url)), conversation: name)
    }

    /// "WhatsApp Chat - Sam.zip" / "WhatsApp Chat with Sam.txt" → "Sam".
    static func conversationName(from url: URL) -> String? {
        var base = url.deletingPathExtension().lastPathComponent
        for prefix in ["WhatsApp Chat - ", "WhatsApp Chat with ", "WhatsApp Chat "] where base.hasPrefix(prefix) {
            base = String(base.dropFirst(prefix.count))
        }
        return base == "_chat" || base.isEmpty ? nil : base
    }

    /// Pulls the chat text out of an exported .zip.
    ///
    /// Uses the built-in ZIP reader (stored entries everywhere, DEFLATE on Apple
    /// platforms via the Compression-backed `NSData.decompressed`). On macOS it
    /// falls back to `/usr/bin/unzip` for anything the reader can't handle. On iOS
    /// the share extension usually receives `_chat.txt` directly, and Files can unzip.
    public static func chatText(fromZipAt url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        do {
            let archive = try ChatExportZip(data: data)
            guard let entry = archive.entries.first(where: { $0.name.hasSuffix("_chat.txt") })
                    ?? archive.entries.first(where: { $0.name.lowercased().hasSuffix(".txt") && !$0.name.hasPrefix("__MACOSX") })
            else { throw ExportError.noChatText }
            return decodeText(try archive.contents(of: entry))
        } catch let error as ExportError {
            throw error
        } catch {
            #if os(macOS)
            return try unzipWithTool(url)
            #else
            throw ExportError.zipUnsupported("\(error)")
            #endif
        }
    }

    #if os(macOS)
    /// Runs `/usr/bin/unzip` (always present on macOS) to read the chat text.
    static func unzipWithTool(_ url: URL) throws -> String {
        func run(_ args: [String]) throws -> Data {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw ExportError.zipUnsupported("unzip exited \(p.terminationStatus)") }
            return data
        }
        let names = String(decoding: try run(["-Z1", url.path]), as: UTF8.self).split(separator: "\n").map(String.init)
        guard let entry = names.first(where: { $0.hasSuffix("_chat.txt") }) ?? names.first(where: { $0.lowercased().hasSuffix(".txt") })
        else { throw ExportError.noChatText }
        return decodeText(try run(["-p", url.path, entry]))
    }
    #endif

    /// UTF-8 (with or without BOM), falling back to UTF-16 and Latin-1.
    static func decodeText(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16) { return s }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    // MARK: Text

    static let iosHeader = PlanRegex(#"^\[(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{2,4}),?\s+(\d{1,2})[:.](\d{2})(?:[:.](\d{2}))?\s*([ap])?\.?\s?m?\.?\]\s?(.*)$"#)
    static let androidHeader = PlanRegex(#"^(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{2,4}),?\s+(\d{1,2})[:.](\d{2})(?:[:.](\d{2}))?\s*([ap])?\.?\s?m?\.?\s[-–]\s(.*)$"#)

    /// System and placeholder lines that aren't real messages.
    static let systemPatterns = PlanRegex(
        #"^(?:messages and calls are end-to-end encrypted|messages to this (?:chat|group) are now secured|<media omitted>|(?:image|video|audio|sticker|gif|document|contact card) omitted|<attached: [^>]+>|this message was deleted|you deleted this message|missed (?:voice|video) call|null$|waiting for this message|.* (?:created group|added you|changed the subject|changed this group's icon|left$|joined using this group's invite link|changed their phone number)|your security code with .* changed|.* is a contact\.?$|disappearing messages)"#)

    struct Header {
        var day: Int, month: Int, year: Int, hour: Int, minute: Int, second: Int
        var ampm: String?
        var rest: String
        var isIOS: Bool
    }

    /// Parses exported chat text into messages, oldest first.
    public func parse(_ text: String, conversation: String? = nil) -> [ChatMessage] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)

        // Pass 1: split into (header, body lines).
        var raw: [(Header, [String])] = []
        for line in lines {
            let original = String(line)
            let cleaned = MessageText.clean(original)
            if let h = Self.header(cleaned) {
                raw.append((h, []))
            } else if !raw.isEmpty {
                raw[raw.count - 1].1.append(cleaned)
            }
        }
        let monthFirst = Self.looksMonthFirst(raw.map(\.0))

        // Pass 2: build messages.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        var out: [ChatMessage] = []
        for (index, (h, extra)) in raw.enumerated() {
            var hour = h.hour
            if let ap = h.ampm { hour = PlanTimeParser.apply(ap, to: h.hour) }
            let comps = DateComponents(timeZone: timeZone, year: h.year < 100 ? 2000 + h.year : h.year,
                                       month: monthFirst ? h.day : h.month, day: monthFirst ? h.month : h.day,
                                       hour: hour, minute: h.minute, second: h.second)
            guard let date = cal.date(from: comps) else { continue }

            // "Sam: hello" → sender + text. No colon means a system line.
            guard !Self.isSystem(h.rest), let colon = h.rest.range(of: ": ") else { continue }
            let sender = String(h.rest[..<colon.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: "~ ").union(.whitespaces))
            var body = String(h.rest[colon.upperBound...])
            if !extra.isEmpty { body += "\n" + extra.joined(separator: "\n") }
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sender.isEmpty, !body.isEmpty, !Self.isSystem(body) else { continue }

            out.append(ChatMessage(id: "wa-\(conversation ?? "chat")-\(index)", sender: sender, date: date, text: body,
                                   isFromMe: MessageText.isMe(sender, myNames: myNames), source: .whatsapp,
                                   conversation: conversation))
        }
        return out
    }

    static func header(_ line: String) -> Header? {
        for (regex, isIOS) in [(iosHeader, true), (androidHeader, false)] {
            guard let m = regex.firstMatch(in: line),
                  let d = Int(m.group(1) ?? ""), let mo = Int(m.group(2) ?? ""), let y = Int(m.group(3) ?? ""),
                  let h = Int(m.group(4) ?? ""), let mi = Int(m.group(5) ?? ""), h <= 23, mi <= 59 else { continue }
            return Header(day: d, month: mo, year: y, hour: h, minute: mi, second: Int(m.group(6) ?? "") ?? 0,
                          ampm: m.group(7)?.lowercased(), rest: m.group(8) ?? "", isIOS: isIOS)
        }
        return nil
    }

    static func isSystem(_ body: String) -> Bool {
        systemPatterns.contains(body.lowercased())
    }

    /// True only if the file can't be day/month: no first number above 12 and some second number is.
    static func looksMonthFirst(_ headers: [Header]) -> Bool {
        !headers.contains { $0.day > 12 } && headers.contains { $0.month > 12 }
    }
}
