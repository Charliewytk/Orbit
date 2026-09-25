import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reads OneNote notebooks through Microsoft Graph, using the same Exeter
/// Microsoft sign-in as Exeter mail (scope `Notes.Read`).
///
/// Endpoints used:
///   GET /me/onenote/notebooks
///   GET /me/onenote/notebooks/{id}/sections · /sectionGroups
///   GET /me/onenote/sectionGroups/{id}/sections · /sectionGroups
///   GET /me/onenote/sections/{id}/pages?$orderby=lastModifiedDateTime desc
///   GET /me/onenote/pages/{id}/content?includeIDs=true&includeInkML=true
///   GET <resource URL from <img src>>  (needs the bearer token)
public struct OneNoteClient: Sendable {
    public var http: HTTPClient
    public var tokens: AccessTokenProvider
    public var baseURL: URL
    /// `$top` for page listings (Graph allows up to 100).
    public var pageSize: Int
    /// Stops runaway section-group recursion.
    public var maxGroupDepth: Int

    public init(tokens: AccessTokenProvider, http: HTTPClient = HTTPClient(),
                baseURL: URL = URL(string: "https://graph.microsoft.com/v1.0")!,
                pageSize: Int = 100, maxGroupDepth: Int = 6) {
        self.tokens = tokens; self.http = http; self.baseURL = baseURL
        self.pageSize = pageSize; self.maxGroupDepth = maxGroupDepth
    }

    struct Collection<T: Decodable>: Decodable {
        let value: [T]
        let nextLink: String?
        enum CodingKeys: String, CodingKey { case value; case nextLink = "@odata.nextLink" }
    }

    // MARK: Listing

    public func notebooks() async throws -> [OneNoteNotebook] {
        try await all(OneNoteNotebook.self, endpoint("me/onenote/notebooks"))
    }

    /// Every section in a notebook, including those inside section groups (recursively).
    public func sections(in notebook: OneNoteNotebook) async throws -> [OneNoteSection] {
        let direct = try await all(OneNoteSection.self, endpoint("me/onenote/notebooks/\(notebook.id)/sections"))
        let groups = try await all(OneNoteSectionGroup.self, endpoint("me/onenote/notebooks/\(notebook.id)/sectionGroups"))
        var out = direct.map { s -> OneNoteSection in
            var s = s; s.notebookName = notebook.displayName; s.groupPath = []; return s
        }
        for g in groups {
            out += try await sections(inGroup: g, notebookName: notebook.displayName, path: [g.displayName], depth: 1)
        }
        return out
    }

    func sections(inGroup group: OneNoteSectionGroup, notebookName: String, path: [String],
                  depth: Int) async throws -> [OneNoteSection] {
        var out = try await all(OneNoteSection.self, endpoint("me/onenote/sectionGroups/\(group.id)/sections")).map {
            var s = $0; s.notebookName = notebookName; s.groupPath = path; return s
        }
        guard depth < maxGroupDepth else { return out }
        let nested = try await all(OneNoteSectionGroup.self, endpoint("me/onenote/sectionGroups/\(group.id)/sectionGroups"))
        for g in nested {
            out += try await sections(inGroup: g, notebookName: notebookName, path: path + [g.displayName], depth: depth + 1)
        }
        return out
    }

    /// All sections across all notebooks.
    public func allSections() async throws -> [OneNoteSection] {
        var out: [OneNoteSection] = []
        for nb in try await notebooks() { out += try await sections(in: nb) }
        return out
    }

    /// Pages in a section, most recently edited first. With `modifiedAfter`,
    /// paging stops at the first page that isn't newer, so incremental syncs are cheap.
    public func pages(inSection sectionID: String, modifiedAfter: Date? = nil) async throws -> [OneNotePage] {
        var url: URL? = endpoint("me/onenote/sections/\(sectionID)/pages",
                                 query: [("$orderby", "lastModifiedDateTime desc"), ("$top", String(pageSize))])
        var out: [OneNotePage] = []
        while let next = url {
            let batch = try await get(Collection<OneNotePage>.self, next)
            for page in batch.value {
                if let cutoff = modifiedAfter, let m = page.lastModifiedDateTime, m <= cutoff { return out }
                out.append(page)
            }
            url = batch.nextLink.flatMap(URL.init(string:))
        }
        return out
    }

    // MARK: Content

    /// The page's HTML and, if it has pen strokes, its InkML.
    public func pageContent(pageID: String) async throws -> OneNotePageContent {
        let url = endpoint("me/onenote/pages/\(pageID)/content",
                           query: [("includeIDs", "true"), ("includeInkML", "true")])
        let (data, response) = try await send(url, accept: "multipart/related, text/html")
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? "text/html"
        return try Self.decodeContent(data, contentType: contentType)
    }

    /// Splits a page content response into its HTML and InkML parts.
    public static func decodeContent(_ data: Data, contentType: String) throws -> OneNotePageContent {
        guard contentType.lowercased().hasPrefix("multipart/") else {
            return OneNotePageContent(html: String(decoding: data, as: UTF8.self))
        }
        guard let boundary = MultipartParser.boundary(fromContentType: contentType) else {
            throw OneNoteError.malformedContent("multipart response without a boundary")
        }
        let parts = MultipartParser.parse(data, boundary: boundary)
        let html = parts.first { $0.mimeType == "text/html" || $0.mimeType == "application/xhtml+xml" }
            ?? parts.first { $0.text.range(of: "<html", options: .caseInsensitive) != nil }
        let ink = parts.first { $0.mimeType == "application/inkml+xml" }
            ?? parts.first { $0.text.contains("<inkml:ink") || $0.text.contains("<ink ") || $0.text.contains("<ink>") }
        guard let html else { throw OneNoteError.malformedContent("no HTML part") }
        return OneNotePageContent(html: html.text, inkML: ink?.text)
    }

    /// Downloads an image or file resource (e.g. an `<img src>` from page HTML).
    public func resource(_ url: URL) async throws -> Data {
        try await send(url, accept: "*/*").0
    }

    /// Fetches, parses and (optionally) downloads images for one page.
    public func fetchPage(_ page: OneNotePage, section: OneNoteSection? = nil, downloadImages: Bool = true,
                          inkParser: InkMLParser = InkMLParser()) async throws -> OneNoteFetchedPage {
        let content = try await pageContent(pageID: page.id)
        let document = OneNoteHTMLParser.parse(content.html)
        let ink = try content.inkML.map { try inkParser.parse($0) }
        var images: [String: Data] = [:]
        if downloadImages {
            for block in document.blocks where block.kind == .image {
                // Full resolution reads better for OCR when OneNote provides it.
                guard let src = block.src, images[src] == nil,
                      let url = URL(string: block.fullResolutionSrc ?? src) else { continue }
                images[src] = try await resource(url)
            }
        }
        return OneNoteFetchedPage(page: page, section: section, content: content, document: document,
                                  ink: ink, images: images)
    }

    // MARK: Incremental sync

    /// Pages changed since `cursor` across `sections`. Sections whose own
    /// `lastModifiedDateTime` hasn't moved are skipped without listing pages.
    /// If Graph rate-limits part-way, the error is thrown and the old cursor stays valid.
    public func changes(since cursor: OneNoteSyncCursor, in sections: [OneNoteSection],
                        now: Date = Date()) async throws -> OneNoteChangeSet {
        var next = cursor
        var changed: [(section: OneNoteSection, page: OneNotePage)] = []
        for section in sections {
            let since = cursor.sections[section.id]
            if let since, let modified = section.lastModifiedDateTime, modified <= since { continue }
            let pages = try await pages(inSection: section.id, modifiedAfter: since)
            changed += pages.map { (section, $0) }
            if let newest = pages.compactMap(\.lastModifiedDateTime).max() {
                next.sections[section.id] = max(newest, since ?? .distantPast)
            }
        }
        next.lastSync = now
        return OneNoteChangeSet(pages: changed, cursor: next)
    }

    // MARK: HTTP

    func endpoint(_ path: String, query: [(String, String)] = []) -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#")
        let escaped = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        var s = baseURL.absoluteString.hasSuffix("/") ? baseURL.absoluteString : baseURL.absoluteString + "/"
        s += escaped
        if !query.isEmpty {
            s += "?" + query.map { "\($0.0)=\(FormEncoding.escape($0.1))" }.joined(separator: "&")
        }
        return URL(string: s)!
    }

    func all<T: Decodable>(_ type: T.Type, _ first: URL) async throws -> [T] {
        var url: URL? = first
        var out: [T] = []
        while let next = url {
            let batch = try await get(Collection<T>.self, next)
            out += batch.value
            url = batch.nextLink.flatMap(URL.init(string:))
        }
        return out
    }

    func get<T: Decodable>(_ type: T.Type, _ url: URL) async throws -> T {
        let (data, _) = try await send(url, accept: "application/json")
        return try HTTPClient.decoder.decode(T.self, from: data)
    }

    /// Sends directly through the transport so throttling headers can be read.
    func send(_ url: URL, accept: String) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url, timeoutInterval: http.timeout)
        req.httpMethod = "GET"
        req.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        let (data, response) = try await http.transport.send(req)
        switch response.statusCode {
        case 200..<300:
            return (data, response)
        case 401:
            throw OneNoteError.unauthorized
        case 429:
            throw OneNoteError.rateLimited(retryAfter: Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After")))
        case 503 where response.value(forHTTPHeaderField: "Retry-After") != nil:
            throw OneNoteError.rateLimited(retryAfter: Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After")))
        default:
            throw HTTPError(status: response.statusCode, body: String(decoding: data, as: UTF8.self), url: url.absoluteString)
        }
    }

    /// Retry-After is either delay-seconds or an HTTP date.
    static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Double(value) { return max(0, seconds) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }
}
