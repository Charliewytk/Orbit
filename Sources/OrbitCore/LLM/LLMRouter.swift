import Foundation

/// Picks which AI to use for each request and falls back automatically.
///
/// Rules:
/// - Local-only mode, or `.privateData` → Ollama only (cloud never sees private data).
/// - `.bulk` → Ollama first (free, fast, private), then cloud.
/// - `.vision` → Ollama first (local vision), then cloud.
/// - `.chat` / `.reasoning` → CleanAPIs (cloud brain, claude-opus-5.5) first, then OpenCode, then Ollama.
/// A provider that fails is skipped for a cool-down period, so one outage
/// doesn't slow every request.
public actor LLMRouter {
    public private(set) var providers: [LLMProvider]
    public var localOnly: Bool
    public var coolDown: TimeInterval
    private var failedUntil: [String: Date] = [:]
    private var lastUsed: LLMProviderKind?

    public init(providers: [LLMProvider], localOnly: Bool = false, coolDown: TimeInterval = 300) {
        self.providers = providers; self.localOnly = localOnly; self.coolDown = coolDown
    }

    public func setLocalOnly(_ on: Bool) { localOnly = on }
    public func setProviders(_ p: [LLMProvider]) { providers = p; failedUntil = [:] }
    public func lastProvider() -> LLMProviderKind? { lastUsed }

    /// Supplies relevant course knowledge + the student profile for a request (see `KnowledgeContext`).
    public typealias ContextProvider = @Sendable (LLMRequest) async -> String?
    private var contextProvider: ContextProvider?
    public func setContextProvider(_ p: ContextProvider?) { contextProvider = p }

    /// Chat and free-text reasoning get the knowledge context as an extra system message.
    /// JSON extraction, bulk and vision jobs don't (keeps them fast and on-format).
    public static func wantsKnowledge(_ r: LLMRequest) -> Bool {
        (r.purpose == .chat || r.purpose == .reasoning) && !r.json
            && !r.messages.contains { $0.role == .system && $0.text.hasPrefix(KnowledgeContext.marker) }
    }

    func withKnowledge(_ request: LLMRequest) async -> LLMRequest {
        guard let contextProvider, Self.wantsKnowledge(request),
              let ctx = await contextProvider(request), !ctx.isEmpty else { return request }
        var r = request
        let insertAt = r.messages.lastIndex { $0.role == .system }.map { $0 + 1 } ?? 0
        r.messages.insert(.system(KnowledgeContext.marker + "\n" + ctx), at: insertAt)
        return r
    }

    /// The order providers will be tried in for a purpose.
    public func order(for purpose: LLMPurpose) -> [LLMProvider] {
        var list = providers
        if localOnly || purpose == .privateData { list = list.filter(\.isLocal) }
        if purpose == .vision { list = list.filter(\.supportsVision) }

        // Cloud-first for chat/reasoning (CleanAPIs brain), local-first for bulk/vision/private.
        let ordered: [LLMProvider]
        switch purpose {
        case .bulk, .vision, .privateData:
            let preferred = list.filter(\.isLocal)
            let rest = list.filter { !$0.isLocal }
            ordered = preferred + rest
        default:
            // Prefer cloud providers in the order the caller supplied them
            // (CleanAPIs first when present), then OpenCode, then local.
            // This keeps localOnly / privateData filtering but makes chat feel smart.
            let cloud = list.filter { !$0.isLocal }
            let local = list.filter(\.isLocal)
            // Within cloud, prefer cleanapis over opencode when both present.
            let cloudSorted = cloud.sorted { a, b in
                let aIsClean = a.kind == .cleanapis
                let bIsClean = b.kind == .cleanapis
                if aIsClean != bIsClean { return aIsClean }
                return false
            }
            ordered = cloudSorted + local
        }

        let now = Date()
        return ordered.filter { (failedUntil[$0.displayName] ?? .distantPast) <= now }
            + ordered.filter { (failedUntil[$0.displayName] ?? .distantPast) > now }
    }

    public func complete(_ request: LLMRequest) async throws -> String {
        let request = await withKnowledge(request)
        var errors: [String] = []
        for p in order(for: request.purpose) {
            do {
                let text = try await p.complete(request)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LLMError.emptyResponse }
                failedUntil[p.displayName] = nil
                lastUsed = p.kind
                return text
            } catch {
                failedUntil[p.displayName] = Date().addingTimeInterval(coolDown)
                errors.append("\(p.displayName): \(error)")
            }
        }
        throw LLMError.noProviderAvailable(errors)
    }

    public func complete(system: String, user: String, purpose: LLMPurpose = .reasoning,
                         images: [Data] = []) async throws -> String {
        try await complete(LLMRequest(messages: [.system(system), .user(user, images: images)], purpose: purpose))
    }

    /// Asks for JSON and decodes it. If the reply doesn't parse, asks once more
    /// with the error, which fixes most small-model mistakes.
    public func completeJSON<T: Decodable>(_ type: T.Type, _ request: LLMRequest,
                                           decoder: JSONDecoder = LLMRouter.jsonDecoder) async throws -> T {
        var req = request
        req.json = true
        var lastText = ""
        for attempt in 0..<2 {
            lastText = try await complete(req)
            if let json = JSONExtractor.extract(lastText), let data = json.data(using: .utf8) {
                do { return try decoder.decode(T.self, from: data) } catch {
                    if attempt == 0 {
                        req.messages.append(.assistant(lastText))
                        req.messages.append(.user("That JSON didn't match the required format (\(error)). Reply with only the corrected JSON."))
                    }
                }
            } else if attempt == 0 {
                req.messages.append(.assistant(lastText))
                req.messages.append(.user("Reply with only valid JSON, no other text."))
            }
        }
        throw LLMError.invalidJSON(lastText)
    }

    /// Accepts ISO dates with or without time/zone, which models produce inconsistently.
    public static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = ISO8601.parse(s) ?? FlexibleDate.parse(s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date \(s)")
        }
        return d
    }()

    /// Status of each provider for the settings screen.
    public func status() async -> [(name: String, kind: LLMProviderKind, available: Bool)] {
        var out: [(String, LLMProviderKind, Bool)] = []
        for p in providers { out.append((p.displayName, p.kind, await p.isAvailable())) }
        return out
    }
}

/// Parses the local-time date formats models tend to produce.
public enum FlexibleDate {
    public static func parse(_ s: String, timeZone: TimeZone = TimeZone(identifier: "Europe/London")!) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB_POSIX")
        f.timeZone = timeZone
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}

/// A scripted provider for tests and previews.
public struct MockLLMProvider: LLMProvider {
    public let kind: LLMProviderKind
    public var displayName: String
    public var isLocal: Bool
    public var supportsVision: Bool
    public var available: Bool
    public var responder: @Sendable (LLMRequest) throws -> String

    public init(displayName: String = "Mock", isLocal: Bool = true, supportsVision: Bool = true,
                available: Bool = true, kind: LLMProviderKind = .mock,
                responder: @escaping @Sendable (LLMRequest) throws -> String) {
        self.kind = kind
        self.displayName = displayName; self.isLocal = isLocal; self.supportsVision = supportsVision
        self.available = available; self.responder = responder
    }

    public func isAvailable() async -> Bool { available }
    public func complete(_ request: LLMRequest) async throws -> String { try responder(request) }
}
