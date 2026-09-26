import Foundation

/// A mailbox Orbit can read from and save reply drafts into.
///
/// Orbit never sends mail: providers deliberately have no `send`. Drafts land in
/// the account's Drafts folder so you can review and send them yourself.
public protocol MailProvider: Sendable {
    var account: MailAccount { get }
    /// Short stable name used to key sync cursors, e.g. "gmail" or "exeter-graph".
    var providerID: String { get }
    /// New inbox mail since `cursor` (nil = first sync, which pulls recent mail).
    /// Returns the cursor to pass next time.
    func fetchNew(since cursor: String?) async throws -> (messages: [EmailMessage], cursor: String?)
    func fetchMessage(id: String) async throws -> EmailMessage
    /// Saves a reply draft (never sends). Returns the draft's ID.
    func createDraft(replyTo message: EmailMessage, body: String) async throws -> String
    /// Marks a message read. Optional: the default throws `MailError.unsupported`.
    func markRead(id: String) async throws
    /// Archives, trashes, or undoes one of those. Optional: the default throws `MailError.unsupported`.
    /// There is deliberately no permanent delete and no send.
    func apply(_ action: MailboxAction, ids: [String]) async throws
}

extension MailProvider {
    public var providerID: String { account.rawValue }
    public func markRead(id: String) async throws { throw MailError.unsupported("markRead") }
    public func apply(_ action: MailboxAction, ids: [String]) async throws { throw MailError.unsupported(action.rawValue) }
}

/// Mailbox changes Orbit can make. Trash is recoverable for 30 days; nothing is deleted for good.
public enum MailboxAction: String, Codable, Sendable, CaseIterable {
    /// Remove from the inbox (Gmail: drop the INBOX label).
    case archive
    /// Move to Trash.
    case trash
    /// Undo `archive` (put the INBOX label back).
    case unarchive
    /// Undo `trash`.
    case untrash

    /// The action that undoes this one.
    public var inverse: MailboxAction {
        switch self {
        case .archive: .unarchive
        case .unarchive: .archive
        case .trash: .untrash
        case .untrash: .trash
        }
    }

    /// "Archived", "Moved to Trash"…
    public var pastTense: String {
        switch self {
        case .archive: "Archived"
        case .trash: "Moved to Trash"
        case .unarchive: "Moved back to Inbox"
        case .untrash: "Restored from Trash"
        }
    }
}

public enum MailError: Error, CustomStringConvertible, Sendable, Equatable {
    case unsupported(String)
    case notFound(String)
    case badResponse(String)
    case accessDenied(String)

    public var description: String {
        switch self {
        case .unsupported(let what): "\(what) isn't supported by this mail account"
        case .notFound(let id): "Email \(id) wasn't found"
        case .badResponse(let why): "Unexpected mail server response: \(why)"
        case .accessDenied(let why): "Can't read mail: \(why)"
        }
    }
}

/// An address such as `Jane Smith <j.smith@exeter.ac.uk>`.
public struct MailAddress: Codable, Hashable, Sendable {
    public var name: String?
    public var address: String

    public init(name: String? = nil, address: String) {
        let n = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = (n?.isEmpty ?? true) ? nil : n
        self.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lowercased part after the "@".
    public var domain: String {
        guard let at = address.lastIndex(of: "@") else { return "" }
        return address[address.index(after: at)...].lowercased()
    }

    /// Lowercased part before the "@".
    public var localPart: String {
        guard let at = address.lastIndex(of: "@") else { return address.lowercased() }
        return address[..<at].lowercased()
    }

    /// Parses one address. Handles `Name <a@b>`, `"Last, First" <a@b>`, `a@b (Name)` and bare `a@b`.
    /// Encoded words in the display name are decoded.
    public static func parse(_ raw: String) -> MailAddress? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let lt = s.lastIndex(of: "<"), let gt = s[lt...].firstIndex(of: ">") {
            let addr = String(s[s.index(after: lt)..<gt])
            var name = String(s[..<lt]).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
                name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
            }
            return MailAddress(name: MIMEParser.decodeEncodedWords(name), address: addr)
        }
        if let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")"), open < close {
            let addr = String(s[..<open])
            let name = String(s[s.index(after: open)..<close])
            return MailAddress(name: MIMEParser.decodeEncodedWords(name), address: addr)
        }
        return s.contains("@") ? MailAddress(address: s) : nil
    }

    /// Parses a comma-separated list, respecting quotes and angle brackets.
    public static func parseList(_ raw: String) -> [MailAddress] {
        var items: [String] = []
        var current = ""
        var inQuotes = false
        var inAngle = false
        for ch in raw {
            switch ch {
            case "\"": inQuotes.toggle(); current.append(ch)
            case "<" where !inQuotes: inAngle = true; current.append(ch)
            case ">" where !inQuotes: inAngle = false; current.append(ch)
            case ",", ";":
                if inQuotes || inAngle { current.append(ch) } else { items.append(current); current = "" }
            default: current.append(ch)
            }
        }
        items.append(current)
        return items.compactMap(parse)
    }

    /// `Name <address>` or just the address, for headers.
    public var formatted: String {
        guard let name else { return address }
        return "\(MIMEParser.encodeHeaderWord(name)) <\(address)>"
    }
}
