import Foundation

/// A DM thread from Instagram's "Download your information" export.
public struct InstagramThread: Hashable, Sendable {
    public var title: String
    public var participants: [String]
    /// Oldest first.
    public var messages: [ChatMessage]

    public init(title: String, participants: [String], messages: [ChatMessage]) {
        self.title = title; self.participants = participants; self.messages = messages
    }
}

/// Reads Instagram's JSON data download (Settings → Your activity → Download
/// your information → Messages, JSON format). There's no API for personal DMs,
/// so this export (or screenshots) is how Instagram plans get into Orbit.
///
/// Files live at `messages/inbox/<thread>/message_1.json` (newer exports nest
/// that under `your_instagram_activity/`). Instagram writes the text as UTF-8
/// bytes escaped as Latin-1 code points ("cafÃ©"), which `fixMojibake` undoes.
public struct InstagramExportParser: Sendable {
    /// Your Instagram display name(s), used to set `isFromMe`.
    public var myNames: Set<String>

    public init(myNames: Set<String> = []) { self.myNames = myNames }

    struct File: Decodable {
        struct Participant: Decodable { let name: String }
        struct Message: Decodable {
            let sender_name: String
            let timestamp_ms: Double
            let content: String?
        }
        let participants: [Participant]?
        let messages: [Message]
        let title: String?
        let thread_path: String?
    }

    /// Parses one `message_N.json` file.
    public func parse(_ data: Data) throws -> InstagramThread {
        let file = try JSONDecoder().decode(File.self, from: data)
        let participants = (file.participants ?? []).map { Self.fixMojibake($0.name) }
        let title = file.title.map(Self.fixMojibake) ?? participants.filter { !MessageText.isMe($0, myNames: myNames) }.joined(separator: ", ")
        let key = file.thread_path ?? title
        let messages: [ChatMessage] = file.messages.enumerated().compactMap { i, m in
            guard let raw = m.content else { return nil }
            let text = Self.fixMojibake(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !Self.isSystem(text) else { return nil }
            let sender = Self.fixMojibake(m.sender_name)
            return ChatMessage(id: "ig-\(key)-\(Int64(m.timestamp_ms))-\(i)", sender: sender,
                               date: Date(timeIntervalSince1970: m.timestamp_ms / 1000), text: text,
                               isFromMe: MessageText.isMe(sender, myNames: myNames), source: .instagram,
                               conversation: title)
        }
        return InstagramThread(title: title, participants: participants, messages: messages.sorted { $0.date < $1.date })
    }

    /// Reads every thread in an unzipped export folder, merging `message_1.json`, `message_2.json`… per thread.
    public func parse(exportFolder: URL) throws -> [InstagramThread] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: exportFolder, includingPropertiesForKeys: nil) else { return [] }
        var byFolder: [String: [URL]] = [:]
        for case let url as URL in walker
        where url.lastPathComponent.hasPrefix("message_") && url.pathExtension == "json"
            && url.path.contains("/inbox/") {
            byFolder[url.deletingLastPathComponent().path, default: []].append(url)
        }
        return try byFolder.keys.sorted().compactMap { folder in
            var merged: InstagramThread?
            for url in byFolder[folder]!.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let t = try parse(Data(contentsOf: url))
                if merged == nil { merged = t } else { merged!.messages += t.messages }
            }
            merged?.messages.sort { $0.date < $1.date }
            return merged
        }
    }

    /// Undoes Instagram's double encoding: "cafÃ©" → "café", "ð\u{9f}\u{91}\u{8d}" → "👍".
    /// Strings that aren't mojibake are returned unchanged.
    public static func fixMojibake(_ s: String) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(s.unicodeScalars.count)
        for u in s.unicodeScalars {
            guard u.value <= 0xFF else { return s }
            bytes.append(UInt8(u.value))
        }
        guard bytes.contains(where: { $0 >= 0x80 }) else { return s }
        return String(bytes: bytes, encoding: .utf8) ?? s
    }

    static let systemPattern = PlanRegex(
        #"^(?:liked a message|reacted .{1,8} to your message|.{0,60}\bsent an attachment\.?|.{0,60}\bstarted a (?:video|audio) chat|(?:video|audio) chat ended|.{0,60}\bshared a story\.?|.{0,60}\bmentioned you in their story|this message was unsent\.?|you missed a (?:video|audio) chat)$"#)

    static func isSystem(_ text: String) -> Bool { systemPattern.contains(text) }
}
