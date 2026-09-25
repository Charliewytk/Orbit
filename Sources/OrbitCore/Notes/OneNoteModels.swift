import Foundation

// Value types for the Microsoft Graph OneNote API
// (https://learn.microsoft.com/graph/api/resources/onenote-api-overview).

public struct OneNoteNotebook: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var displayName: String
    public var lastModifiedDateTime: Date?
    public var isDefault: Bool?

    public init(id: String, displayName: String, lastModifiedDateTime: Date? = nil, isDefault: Bool? = nil) {
        self.id = id; self.displayName = displayName
        self.lastModifiedDateTime = lastModifiedDateTime; self.isDefault = isDefault
    }
}

public struct OneNoteSectionGroup: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var displayName: String
    public var lastModifiedDateTime: Date?

    public init(id: String, displayName: String, lastModifiedDateTime: Date? = nil) {
        self.id = id; self.displayName = displayName; self.lastModifiedDateTime = lastModifiedDateTime
    }
}

public struct OneNoteSection: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var displayName: String
    public var lastModifiedDateTime: Date?
    /// Filled in by `OneNoteClient`: the notebook this section lives in.
    public var notebookName: String?
    /// Filled in by `OneNoteClient`: section group names from the notebook down, if nested.
    public var groupPath: [String]?

    public init(id: String, displayName: String, lastModifiedDateTime: Date? = nil,
                notebookName: String? = nil, groupPath: [String]? = nil) {
        self.id = id; self.displayName = displayName; self.lastModifiedDateTime = lastModifiedDateTime
        self.notebookName = notebookName; self.groupPath = groupPath
    }

    /// "Notebook › Group › Section", for display and module-code detection.
    public var fullPath: String {
        ([notebookName].compactMap { $0 } + (groupPath ?? []) + [displayName]).joined(separator: " › ")
    }
}

public struct OneNotePage: Identifiable, Codable, Hashable, Sendable {
    public struct ParentRef: Codable, Hashable, Sendable {
        public var id: String
        public var displayName: String?
        public init(id: String, displayName: String? = nil) { self.id = id; self.displayName = displayName }
    }

    public var id: String
    public var title: String?
    public var createdDateTime: Date?
    public var lastModifiedDateTime: Date?
    public var contentUrl: String?
    public var level: Int?
    public var order: Int?
    public var parentSection: ParentRef?
    public var parentNotebook: ParentRef?

    public init(id: String, title: String? = nil, createdDateTime: Date? = nil, lastModifiedDateTime: Date? = nil,
                contentUrl: String? = nil, level: Int? = nil, order: Int? = nil,
                parentSection: ParentRef? = nil, parentNotebook: ParentRef? = nil) {
        self.id = id; self.title = title; self.createdDateTime = createdDateTime
        self.lastModifiedDateTime = lastModifiedDateTime; self.contentUrl = contentUrl
        self.level = level; self.order = order; self.parentSection = parentSection; self.parentNotebook = parentNotebook
    }
}

/// The raw parts of `GET /pages/{id}/content?includeInkML=true`.
public struct OneNotePageContent: Codable, Hashable, Sendable {
    public var html: String
    /// Present when the page has pen strokes.
    public var inkML: String?

    public init(html: String, inkML: String? = nil) { self.html = html; self.inkML = inkML }
}

/// Everything Orbit needs from one page: metadata, parsed blocks, strokes and image bytes.
public struct OneNoteFetchedPage: Sendable {
    public var page: OneNotePage
    public var section: OneNoteSection?
    public var content: OneNotePageContent
    public var document: OneNotePageDocument
    public var ink: InkDocument?
    /// Downloaded image bytes keyed by the `src` used in the HTML.
    public var images: [String: Data]

    public init(page: OneNotePage, section: OneNoteSection?, content: OneNotePageContent,
                document: OneNotePageDocument, ink: InkDocument?, images: [String: Data]) {
        self.page = page; self.section = section; self.content = content
        self.document = document; self.ink = ink; self.images = images
    }
}

/// Where incremental sync got up to: the newest `lastModifiedDateTime` seen per section.
public struct OneNoteSyncCursor: Codable, Hashable, Sendable {
    public var sections: [String: Date]
    public var lastSync: Date?

    public init(sections: [String: Date] = [:], lastSync: Date? = nil) {
        self.sections = sections; self.lastSync = lastSync
    }
}

public struct OneNoteChangeSet: Sendable {
    /// Pages created or edited since the cursor, newest first per section.
    public var pages: [(section: OneNoteSection, page: OneNotePage)]
    /// Save this and pass it to the next sync.
    public var cursor: OneNoteSyncCursor
}

public enum OneNoteError: Error, CustomStringConvertible, Sendable, Equatable {
    /// Graph throttled us (HTTP 429, or 503 with Retry-After). Wait `retryAfter` seconds.
    case rateLimited(retryAfter: TimeInterval?)
    /// The token was rejected (HTTP 401). Sign in again.
    case unauthorized
    /// The multipart page response had no HTML part.
    case malformedContent(String)

    public var description: String {
        switch self {
        case .rateLimited(let s): "OneNote is rate-limiting Orbit" + (s.map { "; retry in \(Int($0))s" } ?? "")
        case .unauthorized: "Microsoft sign-in expired. Please sign in again."
        case .malformedContent(let why): "Couldn't read OneNote page: \(why)"
        }
    }
}
