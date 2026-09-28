import Foundation

// Ed Discussion (edstem.org). Exeter's courses are on the US region
// (edstem.org/us, API us.edstem.org); EU and AU are selectable in Settings.
// Ed has no public API docs for students, but its web app talks to a JSON API
// that accepts the same token:
//   GET https://us.edstem.org/api/user                              → you + your courses
//   GET https://us.edstem.org/api/courses/{id}/threads?limit=30&sort=new
//   GET https://us.edstem.org/api/threads/{id}?view=1               → one thread with replies
// Auth: header `x-token: <token>` (the web app's token, read from its localStorage
// after the student signs in) or `Authorization: Bearer <token>` for an API token
// made at edstem.org/us/settings/api-tokens. The token is a secret: never log it.

public enum EdRegion: String, Codable, Sendable, CaseIterable, Identifiable {
    case us, eu, au

    /// Exeter's Ed courses live on the US region.
    public static let `default`: EdRegion = .us

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .us: "US (edstem.org/us)"
        case .eu: "EU (edstem.org/eu)"
        case .au: "Australia (edstem.org/au)"
        }
    }

    public var loginURL: URL { webBase.appendingPathComponent("login") }
    public var dashboardURL: URL { webBase.appendingPathComponent("dashboard") }
    public var apiTokensURL: URL { webBase.appendingPathComponent("settings/api-tokens") }

    public var apiBase: URL {
        switch self {
        case .eu: URL(string: "https://eu.edstem.org/api/")!
        case .us: URL(string: "https://us.edstem.org/api/")!
        case .au: URL(string: "https://edstem.org/api/")!
        }
    }

    /// The web app (login and thread links).
    public var webBase: URL {
        switch self {
        case .eu: URL(string: "https://edstem.org/eu/")!
        case .us: URL(string: "https://edstem.org/us/")!
        case .au: URL(string: "https://edstem.org/au/")!
        }
    }

    public func threadURL(courseID: Int, threadID: Int) -> String {
        webBase.appendingPathComponent("courses/\(courseID)/discussion/\(threadID)").absoluteString
    }
}

// MARK: - API types

public struct EdUser: Codable, Hashable, Sendable {
    public var id: Int
    public var name: String
    public var email: String?
    public var role: String?
}

public struct EdCourse: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var code: String
    public var name: String
    public var year: String?
    public var session: String?
    public var status: String?

    public init(id: Int, code: String, name: String, year: String? = nil, session: String? = nil, status: String? = nil) {
        self.id = id; self.code = code; self.name = name; self.year = year; self.session = session; self.status = status
    }

    /// "BEE1022" from "BEE1022 - Economic Principles" or "BEE1022-2026".
    public var moduleCode: String? { EdText.moduleCode(in: code) ?? EdText.moduleCode(in: name) }
    public var isActive: Bool { (status ?? "active") == "active" }
}

public struct EdEnrolment: Codable, Hashable, Sendable {
    public struct Role: Codable, Hashable, Sendable { public var role: String? }
    public var course: EdCourse
    public var role: Role?
}

public struct EdUserResponse: Codable, Sendable {
    public var user: EdUser
    public var courses: [EdEnrolment]
}

/// A thread author as listed alongside threads.
public struct EdAuthor: Codable, Hashable, Sendable {
    public var id: Int
    public var name: String?
    public var role: String?
    /// "admin", "staff", "mentor", "student" (the role in this course).
    public var courseRole: String?

    public var isStaff: Bool {
        let r = (courseRole ?? role ?? "").lowercased()
        return r == "admin" || r == "staff" || r == "mentor" || r == "tutor" || r == "instructor"
    }
}

public struct EdComment: Codable, Hashable, Sendable {
    public var id: Int
    public var userId: Int?
    public var type: String?
    public var document: String?
    public var createdAt: String?
    public var isAnonymous: Bool?
    public var comments: [EdComment]?

    /// This reply and every reply under it.
    public var flattened: [EdComment] { [self] + (comments ?? []).flatMap(\.flattened) }
}

public struct EdThread: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var courseId: Int
    public var userId: Int?
    public var number: Int?
    /// "post", "question", "announcement".
    public var type: String?
    public var title: String
    /// Plain text of the post (Ed also sends `content`, an XML document; not needed).
    public var document: String?
    public var category: String?
    public var subcategory: String?
    public var replyCount: Int?
    public var isPinned: Bool?
    public var isPrivate: Bool?
    public var isAnonymous: Bool?
    public var isAnswered: Bool?
    public var isStaffAnswered: Bool?
    public var isWatched: Bool?
    public var isSeen: Bool?
    public var newReplyCount: Int?
    public var createdAt: String?
    public var updatedAt: String?
    /// Some endpoints embed the author.
    public var user: EdAuthor?
    public var answers: [EdComment]?
    public var comments: [EdComment]?

    public var created: Date? { createdAt.flatMap(EdText.date) }
    public var updated: Date? { updatedAt.flatMap(EdText.date) }
    public var isAnnouncement: Bool { (type ?? "").lowercased() == "announcement" }
    public var text: String { (document ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    public var allReplies: [EdComment] { ((answers ?? []) + (comments ?? [])).flatMap(\.flattened) }
}

public struct EdThreadsResponse: Codable, Sendable {
    public var threads: [EdThread]
    public var users: [EdAuthor]?
}

public struct EdThreadResponse: Codable, Sendable {
    public var thread: EdThread
    public var users: [EdAuthor]?
}

public enum EdError: Error, Equatable, CustomStringConvertible, Sendable {
    case unauthorized
    case http(Int)
    case badResponse(String)

    public var description: String {
        switch self {
        case .unauthorized: "Ed needs you to sign in again."
        case let .http(code): "Ed returned HTTP \(code)."
        case let .badResponse(s): "Ed sent something unexpected: \(s)"
        }
    }
}

// MARK: - Client

public struct EdClient: Sendable {
    public enum TokenKind: String, Codable, Sendable {
        /// The web app's session token (x-token header).
        case session
        /// A personal API token (Authorization: Bearer).
        case apiToken
    }

    public var http: HTTPClient
    public var region: EdRegion
    private let token: String
    public var tokenKind: TokenKind

    public init(token: String, tokenKind: TokenKind = .session, region: EdRegion = .default, http: HTTPClient = HTTPClient(timeout: 30)) {
        self.token = token; self.tokenKind = tokenKind; self.region = region; self.http = http
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private var headers: [String: String] {
        var h = ["Accept": "application/json"]
        switch tokenKind {
        case .session: h["x-token"] = token
        case .apiToken: h["Authorization"] = "Bearer \(token)"
        }
        return h
    }

    func get<T: Decodable>(_ type: T.Type, _ path: String, query: [URLQueryItem] = []) async throws -> T {
        var c = URLComponents(url: region.apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        let data: Data
        do {
            data = try await http.data("GET", c.url!, headers: headers)
        } catch let e as HTTPError {
            if e.status == 401 || e.status == 403 { throw EdError.unauthorized }
            throw EdError.http(e.status)
        }
        do { return try Self.decoder.decode(T.self, from: data) } catch {
            throw EdError.badResponse(String(describing: error).prefix(200).description)
        }
    }

    public func user() async throws -> EdUserResponse {
        try await get(EdUserResponse.self, "user")
    }

    public func threads(courseID: Int, limit: Int = 30, offset: Int = 0, sort: String = "new") async throws -> EdThreadsResponse {
        try await get(EdThreadsResponse.self, "courses/\(courseID)/threads",
                      query: [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "offset", value: String(offset)),
                              URLQueryItem(name: "sort", value: sort)])
    }

    public func thread(id: Int) async throws -> EdThreadResponse {
        try await get(EdThreadResponse.self, "threads/\(id)", query: [URLQueryItem(name: "view", value: "1")])
    }

    /// Decoding helpers for tests and the web-view path.
    public static func decodeUser(_ data: Data) throws -> EdUserResponse { try decoder.decode(EdUserResponse.self, from: data) }
    public static func decodeThreads(_ data: Data) throws -> EdThreadsResponse { try decoder.decode(EdThreadsResponse.self, from: data) }
    public static func decodeThread(_ data: Data) throws -> EdThreadResponse { try decoder.decode(EdThreadResponse.self, from: data) }
}

// MARK: - Text helpers

public enum EdText {
    /// Ed timestamps look like "2026-09-21T09:14:03.512948+01:00" (microseconds).
    public static func date(_ s: String) -> Date? {
        if let d = ISO8601.parse(s) { return d }
        // Trim the fraction to milliseconds and try again.
        guard let dot = s.firstIndex(of: ".") else { return nil }
        let afterDot = s[s.index(after: dot)...]
        let digits = afterDot.prefix { $0.isNumber }
        let rest = afterDot.dropFirst(digits.count)
        let trimmed = String(s[..<dot]) + "." + String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0) + rest
        return ISO8601.parse(trimmed) ?? ISO8601.parse(String(s[..<dot]) + rest)
    }

    /// First Exeter-style module code (three letters + four digits).
    public static func moduleCode(in s: String) -> String? {
        guard let r = s.uppercased().range(of: "[A-Z]{3}[0-9]{4}", options: .regularExpression) else { return nil }
        return String(s.uppercased()[r])
    }

    /// Collapses whitespace and shortens.
    public static func snippet(_ s: String, _ max: Int = 220) -> String {
        let flat = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
    }
}
