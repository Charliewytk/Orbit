import Foundation

/// What the Mac has downloaded from ELE, so files are fetched once and only
/// again when they change (new pluginfile revision, ETag or Last-Modified).
public struct ResourceCache: Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public var cmid: Int
        /// The file URL after redirects (Moodle puts a revision number in it).
        public var finalURL: String?
        public var etag: String?
        public var lastModified: String?
        public var bytes: Int?
        public var fetchedAt: Date?
        public var checkedAt: Date
        public var characters: Int
        /// Why it wasn't indexed ("too large", "no text", an error).
        public var skipped: String?

        public init(cmid: Int, finalURL: String? = nil, etag: String? = nil, lastModified: String? = nil, bytes: Int? = nil,
                    fetchedAt: Date? = nil, checkedAt: Date = Date(), characters: Int = 0, skipped: String? = nil) {
            self.cmid = cmid; self.finalURL = finalURL; self.etag = etag; self.lastModified = lastModified; self.bytes = bytes
            self.fetchedAt = fetchedAt; self.checkedAt = checkedAt; self.characters = characters; self.skipped = skipped
        }
    }

    /// A HEAD response.
    public struct Head: Hashable, Sendable {
        public var finalURL: String
        public var etag: String?
        public var lastModified: String?
        public var bytes: Int?
        public var contentType: String

        public init(finalURL: String, etag: String? = nil, lastModified: String? = nil, bytes: Int? = nil, contentType: String = "") {
            self.finalURL = finalURL; self.etag = etag; self.lastModified = lastModified; self.bytes = bytes; self.contentType = contentType
        }
    }

    public static let maxBytes = 40 * 1024 * 1024

    public var entries: [Int: Entry] = [:]
    /// Items ELE reported as changed (core_course_get_updates_since) — refetch next time.
    public var dirty: Set<Int> = []

    public init() {}

    /// New items are always fetched; known ones are re-checked (a cheap HEAD) daily, or at once when dirty.
    public func needsCheck(_ cmid: Int, now: Date = Date(), recheckAfter: TimeInterval = 86400) -> Bool {
        guard let e = entries[cmid] else { return true }
        if dirty.contains(cmid) { return true }
        if e.fetchedAt == nil && e.skipped == nil { return true }
        return now.timeIntervalSince(e.checkedAt) >= recheckAfter
    }

    /// True when a HEAD response shows the file we already have.
    public func isUnchanged(_ cmid: Int, head: Head) -> Bool {
        guard let e = entries[cmid], e.fetchedAt != nil, !dirty.contains(cmid) else { return false }
        if let a = e.etag, let b = head.etag { return a == b }
        if let a = e.lastModified, let b = head.lastModified { return a == b && e.finalURL == head.finalURL }
        return e.finalURL == head.finalURL && (e.bytes == nil || head.bytes == nil || e.bytes == head.bytes)
    }

    public static func tooLarge(_ bytes: Int?) -> Bool { (bytes ?? 0) > maxBytes }

    public mutating func markChecked(_ cmid: Int, now: Date = Date()) {
        entries[cmid, default: Entry(cmid: cmid)].checkedAt = now
    }

    public mutating func record(_ cmid: Int, head: Head?, characters: Int, skipped: String? = nil, now: Date = Date()) {
        var e = entries[cmid] ?? Entry(cmid: cmid)
        if let head {
            e.finalURL = head.finalURL; e.etag = head.etag; e.lastModified = head.lastModified; e.bytes = head.bytes
        }
        e.checkedAt = now
        if skipped == nil { e.fetchedAt = now }
        e.characters = characters
        e.skipped = skipped
        entries[cmid] = e
        dirty.remove(cmid)
    }
}
