import Foundation

/// Reads Exeter mail from Apple Mail's local store, for when the university
/// blocks third-party apps from Microsoft Graph.
///
/// Add the Exeter account to the Mac's Mail app, then Orbit reads the files at
/// `~/Library/Mail/V*/<account-uuid>/**/*.mbox/**/Messages/*.emlx`.
///
/// **Needs Full Disk Access** (System Settings → Privacy & Security → Full Disk
/// Access → add Orbit), and the Mac app must not be sandboxed, or the Mail
/// folder is invisible. Without it, `fetchNew` throws `MailError.accessDenied`.
/// This is macOS only in practice; on iOS the folder doesn't exist.
///
/// The cursor is the newest file modification time seen.
public struct AppleMailReader: MailProvider {
    public let account: MailAccount = .exeter
    public var providerID: String { "exeter-applemail" }

    /// Usually `~/Library/Mail`.
    public var root: URL
    /// Account folders to read (e.g. `…/V10/<uuid>`). Empty = everything under `root`.
    /// Use `detectAccountFolders(root:addressSuffix:)` to find the Exeter one.
    public var accountFolders: [URL]
    /// Keep only mail addressed (To/Cc) to this domain. Nil = no filter.
    public var addressSuffix: String?
    /// How far back the first sync looks.
    public var initialLookback: TimeInterval
    /// Maximum messages returned per sync (newest first).
    public var maxMessages: Int
    /// Mailboxes to skip (matched against the `.mbox` folder name, case-insensitive prefix).
    public var skippedMailboxes: [String]

    public init(root: URL = AppleMailReader.defaultRoot, accountFolders: [URL] = [],
                addressSuffix: String? = "@exeter.ac.uk", initialLookback: TimeInterval = 14 * 86_400,
                maxMessages: Int = 300,
                skippedMailboxes: [String] = ["Sent", "Drafts", "Deleted", "Trash", "Junk", "Outbox", "Archive", "Notes"]) {
        self.root = root; self.accountFolders = accountFolders; self.addressSuffix = addressSuffix
        self.initialLookback = initialLookback; self.maxMessages = maxMessages; self.skippedMailboxes = skippedMailboxes
    }

    public static var defaultRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Mail", isDirectory: true)
    }

    /// One emlx file found on disk.
    public struct MessageFile: Hashable, Sendable {
        public var url: URL
        public var modified: Date
        /// Mail's row ID, the file name without extensions (e.g. "12345").
        public var rowID: String
        /// The containing mailbox, e.g. "INBOX".
        public var mailbox: String
    }

    // MARK: MailProvider

    public func fetchNew(since cursor: String?) async throws -> (messages: [EmailMessage], cursor: String?) {
        let since = cursor.flatMap(Self.cursorDate) ?? Date().addingTimeInterval(-initialLookback)
        let files = try scan(modifiedAfter: since)
        var messages: [EmailMessage] = []
        for file in files.sorted(by: { $0.modified > $1.modified }) {
            guard messages.count < maxMessages else { break }
            guard let message = try? load(file), matchesAddress(message) else { continue }
            messages.append(message)
        }
        let newest = max(files.map(\.modified).max() ?? since, since)
        return (messages, Self.cursorString(newest))
    }

    /// Cursors are seconds since 1970 as a string, which round-trips file times exactly.
    static func cursorString(_ date: Date) -> String { String(date.timeIntervalSince1970) }
    static func cursorDate(_ s: String) -> Date? { Double(s).map(Date.init(timeIntervalSince1970:)) ?? ISO8601.parse(s) }

    public func fetchMessage(id: String) async throws -> EmailMessage {
        let roots = accountFolders.isEmpty ? [root] : accountFolders
        for r in roots {
            if let file = try Self.messageFiles(in: r, skipping: skippedMailboxes).first(where: { $0.rowID == id }) {
                return try load(file)
            }
        }
        throw MailError.notFound(id)
    }

    /// Opens a reply in Mail.app with `body` filled in, for you to edit and send.
    /// Needs Automation permission for Mail. Not available off macOS.
    public func createDraft(replyTo message: EmailMessage, body: String) async throws -> String {
        #if os(macOS)
        let subject = message.subject.lowercased().hasPrefix("re:") ? message.subject : "Re: \(message.subject)"
        func q(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let source = """
        tell application "Mail"
            set m to make new outgoing message with properties {subject:\(q(subject)), content:\(q(body)), visible:true}
            tell m to make new to recipient at end of to recipients with properties {address:\(q(message.from))}
        end tell
        """
        let failure: String? = await MainActor.run {
            var error: NSDictionary?
            _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
            return error.map { "\($0)" }
        }
        if let failure { throw MailError.accessDenied("Mail.app automation failed: \(failure)") }
        return "applemail-compose-\(message.id)"
        #else
        throw MailError.unsupported("Drafts via Apple Mail")
        #endif
    }

    // MARK: Scanning

    /// Message files under the configured folders modified after `date`.
    public func scan(modifiedAfter date: Date) throws -> [MessageFile] {
        let roots = accountFolders.isEmpty ? [root] : accountFolders
        return try roots.flatMap { try Self.messageFiles(in: $0, skipping: skippedMailboxes) }
            .filter { $0.modified > date }
    }

    public func load(_ file: MessageFile) throws -> EmailMessage {
        let emlx = try EMLXParser.parse(contentsOf: file.url)
        return emlx.parsed.emailMessage(
            id: file.rowID, account: .exeter, isUnread: !emlx.isRead, labels: [file.mailbox],
            fallbackDate: emlx.dateReceived ?? file.modified
        )
    }

    func matchesAddress(_ m: EmailMessage) -> Bool {
        guard let suffix = addressSuffix?.lowercased(), !suffix.isEmpty else { return true }
        return m.to.contains { $0.lowercased().hasSuffix(suffix) }
    }

    /// Finds account folders (`V*/<uuid>`) whose recent mail is addressed to `addressSuffix`.
    /// Samples up to `sample` messages per account.
    public static func detectAccountFolders(root: URL = defaultRoot, addressSuffix: String = "@exeter.ac.uk",
                                            sample: Int = 20) throws -> [URL] {
        let fm = FileManager.default
        try checkReadable(root)
        let versions = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("V") && $0.lastPathComponent.dropFirst().allSatisfy(\.isNumber) }
        var hits: [URL] = []
        for v in versions {
            let accounts = (try? fm.contentsOfDirectory(at: v, includingPropertiesForKeys: nil)) ?? []
            for acct in accounts where acct.lastPathComponent != "MailData" {
                let files = (try? messageFiles(in: acct, skipping: ["Sent", "Drafts", "Junk"]))?
                    .sorted { $0.modified > $1.modified }.prefix(sample) ?? []
                let matched = files.contains { file in
                    guard let parsed = try? EMLXParser.parse(contentsOf: file.url).parsed else { return false }
                    return (parsed.to + parsed.cc).contains { $0.address.lowercased().hasSuffix(addressSuffix.lowercased()) }
                }
                if matched { hits.append(acct) }
            }
        }
        return hits
    }

    /// True when this process can list Apple Mail's folder (i.e. has Full Disk Access
    /// and Mail has been set up at least once).
    public static func canReadMailFolder(root: URL = defaultRoot) -> Bool {
        (try? checkReadable(root)) != nil
    }

    /// Every `.emlx` / `.partial.emlx` under `folder`, skipping mailboxes by name.
    /// Kept synchronous so the directory enumerator isn't used from an async context.
    static func messageFiles(in folder: URL, skipping skipped: [String]) throws -> [MessageFile] {
        try checkReadable(folder)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles]) else { return [] }
        let skippedLower = skipped.map { $0.lowercased() }
        var out: [MessageFile] = []
        while let url = walker.nextObject() as? URL {
            let name = url.lastPathComponent
            if name.hasSuffix(".mbox"), skippedLower.contains(where: { name.lowercased().hasPrefix($0) }) {
                walker.skipDescendants()
                continue
            }
            guard name.hasSuffix(".emlx") else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile ?? true else { continue }
            let rowID = String(name.prefix { $0 != "." })
            let mailbox = url.pathComponents.last { $0.hasSuffix(".mbox") }.map { String($0.dropLast(5)) } ?? ""
            out.append(MessageFile(url: url, modified: values?.contentModificationDate ?? .distantPast,
                                   rowID: rowID, mailbox: mailbox))
        }
        return out
    }

    private static func checkReadable(_ url: URL) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw MailError.accessDenied("\(url.path) not found. Add the account to Mail and give Orbit Full Disk Access.")
        }
        // POSIX permissions say "readable" even when macOS privacy protection blocks
        // the folder, so actually list it.
        guard FileManager.default.isReadableFile(atPath: url.path),
              (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil else {
            throw MailError.accessDenied("Orbit needs Full Disk Access to read \(url.path).")
        }
    }
}
