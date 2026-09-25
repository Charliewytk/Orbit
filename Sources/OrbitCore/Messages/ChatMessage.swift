import Foundation

/// One message from an imported chat (WhatsApp export, Instagram download,
/// iMessage, a screenshot or shared text). Everything in Phase 5 works on these.
public struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var sender: String
    public var date: Date
    public var text: String
    public var isFromMe: Bool
    public var source: MessageSource
    /// Chat or thread name, so messages from many chats can be kept apart.
    public var conversation: String?

    public init(id: String = UUID().uuidString, sender: String, date: Date, text: String,
                isFromMe: Bool = false, source: MessageSource, conversation: String? = nil) {
        self.id = id; self.sender = sender; self.date = date; self.text = text
        self.isFromMe = isFromMe; self.source = source; self.conversation = conversation
    }
}

/// Small text helpers shared by the message importers.
public enum MessageText {
    /// Direction marks and other invisible characters WhatsApp and iOS sprinkle into exports.
    static let invisible: Set<Unicode.Scalar> = [
        "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}", "\u{202A}", "\u{202B}", "\u{202C}",
        "\u{202D}", "\u{202E}", "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}", "\u{FEFF}",
    ]
    /// Non-breaking and narrow spaces (e.g. U+202F before "pm" on iOS 17+).
    static let oddSpaces: Set<Unicode.Scalar> = ["\u{00A0}", "\u{202F}", "\u{2007}", "\u{2009}"]

    /// Removes invisible marks and turns odd spaces into plain spaces.
    public static func clean(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars where !invisible.contains(u) {
            out.append(oddSpaces.contains(u) ? " " : u)
        }
        return String(out)
    }

    /// Case- and accent-insensitive name comparison key.
    public static func nameKey(_ s: String) -> String {
        clean(s).trimmingCharacters(in: CharacterSet(charactersIn: "~ ").union(.whitespacesAndNewlines))
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// True if `sender` is one of your own names (profile name, "Me", phone number…).
    public static func isMe(_ sender: String, myNames: Set<String>) -> Bool {
        let key = nameKey(sender)
        return myNames.contains { nameKey($0) == key }
    }
}
