import Foundation

public enum LLMRole: String, Codable, Sendable { case system, user, assistant }

public struct LLMMessage: Codable, Hashable, Sendable {
    public var role: LLMRole
    public var text: String
    /// PNG/JPEG image data for vision requests (handwriting, screenshots).
    public var images: [Data]

    public init(_ role: LLMRole, _ text: String, images: [Data] = []) {
        self.role = role; self.text = text; self.images = images
    }
    public static func system(_ t: String) -> LLMMessage { .init(.system, t) }
    public static func user(_ t: String, images: [Data] = []) -> LLMMessage { .init(.user, t, images: images) }
    public static func assistant(_ t: String) -> LLMMessage { .init(.assistant, t) }
}

/// Why a request is being made. The router uses this to pick a provider.
public enum LLMPurpose: String, Codable, Sendable {
    /// Talking to you. Best model available.
    case chat
    /// Judgement calls (triage, planning). Prefer the stronger model.
    case reasoning
    /// Many small jobs (sorting hundreds of emails). Prefer local.
    case bulk
    /// Content that shouldn't leave the Mac. Local only.
    case privateData
    /// Reading images (handwriting, screenshots).
    case vision
}

public struct LLMRequest: Sendable {
    public var messages: [LLMMessage]
    public var purpose: LLMPurpose
    /// Ask for a JSON object response.
    public var json: Bool
    public var temperature: Double
    public var maxTokens: Int?

    public init(messages: [LLMMessage], purpose: LLMPurpose = .reasoning, json: Bool = false,
                temperature: Double = 0.2, maxTokens: Int? = nil) {
        self.messages = messages; self.purpose = purpose; self.json = json
        self.temperature = temperature; self.maxTokens = maxTokens
    }
}

public enum LLMProviderKind: String, Codable, Sendable { case cleanapis, opencode, ollama, mock }

public protocol LLMProvider: Sendable {
    var kind: LLMProviderKind { get }
    var displayName: String { get }
    /// True if the provider runs entirely on this Mac.
    var isLocal: Bool { get }
    var supportsVision: Bool { get }
    func isAvailable() async -> Bool
    func complete(_ request: LLMRequest) async throws -> String
}

public enum LLMError: Error, CustomStringConvertible, Sendable {
    case noProviderAvailable([String])
    case invalidJSON(String)
    case emptyResponse
    case providerError(String)

    public var description: String {
        switch self {
        case .noProviderAvailable(let errs):
            "No AI available. Is OpenCode or Ollama running? \(errs.joined(separator: "; "))"
        case .invalidJSON(let s): "AI returned invalid JSON: \(s.prefix(200))"
        case .emptyResponse: "AI returned an empty response"
        case .providerError(let m): m
        }
    }
}

/// Pulls the first JSON object/array out of a model response. Models often wrap
/// JSON in ```json fences or add a sentence before it.
public enum JSONExtractor {
    public static func extract(_ text: String) -> String? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fence = s.range(of: "```") {
            var inner = String(s[fence.upperBound...])
            if inner.hasPrefix("json") { inner.removeFirst(4) }
            if let close = inner.range(of: "```") { inner = String(inner[..<close.lowerBound]) }
            s = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let startIdx = s.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        let open = s[startIdx]
        let close: Character = open == "{" ? "}" : "]"
        var depth = 0
        var inString = false
        var escaped = false
        for i in s[startIdx...].indices {
            let c = s[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                continue
            }
            if c == "\"" { inString = true }
            else if c == open { depth += 1 }
            else if c == close {
                depth -= 1
                if depth == 0 { return String(s[startIdx...i]) }
            }
        }
        return nil
    }
}
