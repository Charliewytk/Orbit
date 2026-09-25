import Foundation
#if os(macOS) && canImport(SQLite3)
import SQLite3
#endif

/// Helpers for the formats inside Messages' `chat.db`. Kept separate from the
/// reader so they build (and are tested) on every platform.
public enum IMessageDecoding {
    /// Seconds between 1970-01-01 and Apple's 2001-01-01 epoch.
    public static let appleEpochOffset: TimeInterval = 978_307_200

    /// `message.date` is seconds since 2001 on old macOS and nanoseconds since
    /// macOS 10.13. Anything above 1e11 can't be seconds (that's year 5170).
    public static func date(fromAppleTimestamp value: Int64) -> Date {
        let seconds = abs(value) > 100_000_000_000 ? Double(value) / 1_000_000_000 : Double(value)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    public static func appleTimestamp(from date: Date, nanoseconds: Bool = true) -> Int64 {
        let seconds = date.timeIntervalSinceReferenceDate
        return nanoseconds ? Int64(seconds * 1_000_000_000) : Int64(seconds)
    }

    /// Pulls the plain text out of `message.attributedBody`, an NSAttributedString
    /// archived as a typedstream. Newer macOS leaves `message.text` empty and only
    /// fills this column.
    ///
    /// Heuristic: find the "NSString" class name, skip to the `+` (0x2B) marker, then
    /// read a length (one byte, or 0x81 + UInt16 LE, or 0x82 + UInt32 LE) and that many UTF-8 bytes.
    public static func text(fromAttributedBody data: Data) -> String? {
        let b = [UInt8](data)
        for marker in ["NSString", "NSMutableString"] {
            let m = [UInt8](marker.utf8)
            guard let at = firstIndex(of: m, in: b) else { continue }
            var i = at + m.count
            let limit = min(b.count, i + 16)
            while i < limit, b[i] != 0x2B { i += 1 }
            guard i < limit, i + 1 < b.count else { continue }
            i += 1
            var length = Int(b[i]), start = i + 1
            if b[i] == 0x81, i + 2 < b.count {
                length = Int(b[i + 1]) | Int(b[i + 2]) << 8; start = i + 3
            } else if b[i] == 0x82, i + 4 < b.count {
                length = Int(b[i + 1]) | Int(b[i + 2]) << 8 | Int(b[i + 3]) << 16 | Int(b[i + 4]) << 24; start = i + 5
            }
            guard length > 0, start + length <= b.count else { continue }
            let text = String(decoding: b[start..<(start + length)], as: UTF8.self)
                .replacingOccurrences(of: "\u{FFFC}", with: "")   // attachment placeholder
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return nil
    }

    static func firstIndex(of needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard !needle.isEmpty, hay.count >= needle.count else { return nil }
        outer: for i in 0...(hay.count - needle.count) {
            for j in 0..<needle.count where hay[i + j] != needle[j] { continue outer }
            return i
        }
        return nil
    }
}

public enum IMessageError: Error, CustomStringConvertible, Sendable {
    /// macOS blocks ~/Library/Messages until Orbit has Full Disk Access.
    case fullDiskAccessRequired
    case sqlite(String)
    case unsupportedPlatform

    public var description: String {
        switch self {
        case .fullDiskAccessRequired:
            "Orbit needs Full Disk Access to read Messages. Open System Settings → Privacy & Security → Full Disk Access and switch Orbit on."
        case .sqlite(let s): "Couldn't read Messages: \(s)"
        case .unsupportedPlatform: "iMessage import only works on the Mac."
        }
    }
}

#if os(macOS) && canImport(SQLite3)
/// Reads iMessage/SMS history from the Mac's local Messages database
/// (`~/Library/Messages/chat.db`). Fully local and read-only.
///
/// **Requires Full Disk Access** for Orbit (System Settings → Privacy &
/// Security → Full Disk Access). Without it the file can't be opened and
/// `IMessageError.fullDiskAccessRequired` is thrown.
///
/// The database is opened with `mode=ro&immutable=1`, so Orbit never writes to
/// it or takes locks that Messages would notice.
public struct IMessageReader: Sendable {
    public var databaseURL: URL
    /// Sender name used for your own messages.
    public var myName: String

    public static var defaultDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db")
    }

    public init(databaseURL: URL = IMessageReader.defaultDatabaseURL, myName: String = "Me") {
        self.databaseURL = databaseURL; self.myName = myName
    }

    /// True if the database can be opened (i.e. Full Disk Access is granted).
    public func hasAccess() -> Bool {
        guard let db = try? open() else { return false }
        sqlite3_close(db)
        return true
    }

    /// Messages newer than `since`, oldest first. Use the last message's date as
    /// the cursor for the next call.
    public func messages(since: Date, limit: Int = 5000) throws -> [ChatMessage] {
        let db = try open()
        defer { sqlite3_close(db) }

        // Detect whether dates are stored in seconds (old macOS) or nanoseconds.
        let maxDate = try queryInt(db, "SELECT MAX(date) FROM message") ?? 0
        let cursor = IMessageDecoding.appleTimestamp(from: since, nanoseconds: maxDate > 100_000_000_000)

        let sql = """
            SELECT m.guid, m.text, m.attributedBody, m.date, m.is_from_me, h.id, c.chat_identifier, c.display_name
            FROM message m
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            LEFT JOIN chat c ON c.ROWID = cmj.chat_id
            WHERE m.date > ?1 AND m.associated_message_type = 0
            ORDER BY m.date ASC
            LIMIT ?2
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw IMessageError.sqlite(errorMessage(db)) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cursor)
        sqlite3_bind_int64(stmt, 2, Int64(limit))

        var out: [ChatMessage] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw IMessageError.sqlite(errorMessage(db)) }
            let guid = string(stmt, 0) ?? UUID().uuidString
            var text = string(stmt, 1)?.replacingOccurrences(of: "\u{FFFC}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text?.isEmpty ?? true, let blob = blob(stmt, 2) {
                text = IMessageDecoding.text(fromAttributedBody: blob)
            }
            guard let text, !text.isEmpty else { continue }
            let fromMe = sqlite3_column_int(stmt, 4) != 0
            let handle = string(stmt, 5) ?? "Unknown"
            let chat = string(stmt, 7).flatMap { $0.isEmpty ? nil : $0 } ?? string(stmt, 6) ?? handle
            out.append(ChatMessage(id: "im-\(guid)", sender: fromMe ? myName : handle,
                                   date: IMessageDecoding.date(fromAppleTimestamp: sqlite3_column_int64(stmt, 3)),
                                   text: text, isFromMe: fromMe, source: .imessage, conversation: chat))
        }
        return out
    }

    // MARK: SQLite plumbing

    func open() throws -> OpaquePointer {
        let fm = FileManager.default
        guard fm.fileExists(atPath: databaseURL.path) else { throw IMessageError.fullDiskAccessRequired }
        guard fm.isReadableFile(atPath: databaseURL.path) else { throw IMessageError.fullDiskAccessRequired }
        var db: OpaquePointer?
        let uri = databaseURL.absoluteString + "?mode=ro&immutable=1"
        let rc = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map(errorMessage) ?? "code \(rc)"
            if let db { sqlite3_close(db) }
            if rc == SQLITE_CANTOPEN || rc == SQLITE_AUTH || rc == SQLITE_PERM { throw IMessageError.fullDiskAccessRequired }
            throw IMessageError.sqlite(message)
        }
        return db
    }

    func queryInt(_ db: OpaquePointer, _ sql: String) throws -> Int64? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let message = errorMessage(db)
            // "authorization denied" here also means no Full Disk Access.
            if message.contains("authorization") { throw IMessageError.fullDiskAccessRequired }
            throw IMessageError.sqlite(message)
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    func string(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: c)
    }

    func blob(_ stmt: OpaquePointer?, _ col: Int32) -> Data? {
        guard let p = sqlite3_column_blob(stmt, col) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, col)))
    }

    func errorMessage(_ db: OpaquePointer) -> String { String(cString: sqlite3_errmsg(db)) }
}
#endif
