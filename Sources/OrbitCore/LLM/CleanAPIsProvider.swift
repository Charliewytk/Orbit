import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os)
import os.log
#endif

// MARK: - CleanAPIs (https://cleanapis.com/v1 — OpenAI-compatible)

/// Cloud brain for Orbit via CleanAPIs. OpenAI-compatible `POST /chat/completions`.
///
/// Auth: `Authorization: Bearer <key>` where key is resolved in this order:
///   1. `apiKey` passed to `init` (from Settings / Secrets.xcconfig / env)
///   2. `CLEANAPIS_API_KEY` / `CLEANAPI_API_KEY` env vars
///   3. `~/.local/share/opencode/auth.json` → `cleanapis.key` (shared with `opencode`)
///   4. `~/.config/opencode/auth.json` legacy fallback
///
/// Privacy: LLMRouter never sends `.privateData` to this provider (see
/// `LLMRouter.order(for:)`). Callers should still only send summaries / digests
/// to cloud — full email bodies, full note text, and the note search index stay
/// in `~/Library/Application Support/Orbit` and never leave the Mac.
///
/// Cost/token logging: `usage` from the response is logged to `os.log` and
/// exposed via `lastUsage` / `totalTokens` so the app can show spend.
public struct CleanAPIsProvider: LLMProvider {
    public let kind: LLMProviderKind = .cleanapis
    public var displayName: String { "CleanAPIs (\(model))" }
    public let isLocal = false
    public var supportsVision: Bool

    public var baseURL: URL
    public var model: String
    public var apiKey: String?
    public var http: HTTPClient
    /// Extra headers (e.g. `X-Title`).
    public var extraHeaders: [String: String]

    // MARK: Usage tracking

    public struct Usage: Sendable, Equatable {
        public var promptTokens: Int
        public var completionTokens: Int
        public var totalTokens: Int { promptTokens + completionTokens }
        /// Approximate USD if the caller knows pricing; provider leaves nil.
        public var costUSD: Double?
    }
    /// Last call's usage, if the server returned it.
    public private(set) var lastUsage: Usage?
    /// Running totals for this process (not persisted — diagnostics only).
    public static var totalPromptTokens: Int = 0
    public static var totalCompletionTokens: Int = 0

    #if canImport(os)
    private static let log = Logger(subsystem: "com.charliewytk.orbit", category: "CleanAPIs")
    #endif

    public init(
        baseURL: URL = URL(string: "https://cleanapis.com/v1")!,
        model: String = "claude-opus-5.5",
        apiKey: String? = nil,
        supportsVision: Bool = true,
        http: HTTPClient = HTTPClient(timeout: 120),
        extraHeaders: [String: String] = [:]
    ) {
        self.baseURL = baseURL
        // Accept "cleanapis/claude-opus-5.5" or "claude-opus-5.5" — strip prefix for the wire.
        if model.contains("/") { self.model = model.split(separator: "/").last.map(String.init) ?? model }
        else { self.model = model }
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.supportsVision = supportsVision
        self.http = http
        self.extraHeaders = extraHeaders
    }

    // MARK: - LLMProvider

    public func isAvailable() async -> Bool {
        guard let key = resolvedKey(), !key.isEmpty else { return false }
        // Cheap health check: GET /models and look for our model.
        // Don't treat a missing model as "unavailable" — CleanAPIs may gate by key.
        var req = URLRequest(url: baseURL.appendingPathComponent("models"))
        req.httpMethod = "GET"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.timeoutInterval = 5
        do {
            let (_, resp) = try await http.transport.send(req)
            return (200..<300).contains(resp.statusCode)
        } catch {
            return false
        }
    }

    public func complete(_ request: LLMRequest) async throws -> String {
        guard let key = resolvedKey(), !key.isEmpty else {
            throw LLMError.noProviderAvailable(["CleanAPIs: no API key — set CLEANAPIS_API_KEY or put it in ~/.local/share/opencode/auth.json"])
        }
        let body = makeBody(request)
        let url = baseURL.appendingPathComponent("chat/completions")
        var headers: [String: String] = ["Authorization": "Bearer \(key)"]
        for (k, v) in extraHeaders { headers[k] = v }

        // Retry on transient failures.
        let maxAttempts = 3
        var lastError: Error?
        for attempt in 0..<maxAttempts {
            do {
                let res: ChatCompletionResponse = try await http.post(ChatCompletionResponse.self, url, body: body, headers: headers)
                if let u = res.usage {
                    #if canImport(os)
                    Self.log.info("CleanAPIs \(self.model, privacy: .public) usage prompt=\(u.prompt_tokens) completion=\(u.completion_tokens) total=\(u.prompt_tokens + u.completion_tokens)")
                    #endif
                    Self.totalPromptTokens += u.prompt_tokens
                    Self.totalCompletionTokens += u.completion_tokens
                }
                let text = res.choices.first?.message.content ?? ""
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LLMError.emptyResponse }
                return text
            } catch let err as HTTPError {
                lastError = err
                let retryable = err.status == 429 || (500..<600).contains(err.status)
                if retryable && attempt + 1 < maxAttempts {
                    let delay = retryDelay(for: err, attempt: attempt)
                    #if canImport(os)
                    Self.log.warning("CleanAPIs HTTP \(err.status) — retry \(attempt + 1)/\(maxAttempts) after \(delay)s: \(err.body.prefix(200), privacy: .public)")
                    #endif
                    try? await Task.sleep(for: .seconds(delay))
                    continue
                }
                throw err
            } catch {
                lastError = error
                // Non-HTTP errors (decode, transport) — retry once if transient.
                if attempt + 1 < maxAttempts, (error as NSError).domain == NSURLErrorDomain {
                    try? await Task.sleep(for: .seconds(Double(attempt + 1) * 2))
                    continue
                }
                throw error
            }
        }
        throw lastError ?? LLMError.noProviderAvailable(["CleanAPIs: retry exhausted"])
    }

    // MARK: - Body

    struct ChatBody: Encodable {
        struct Msg: Encodable {
            struct ContentPart: Encodable {
                let type: String // "text" | "image_url"
                let text: String?
                struct ImageURL: Encodable { let url: String }
                let image_url: ImageURL?
                static func text(_ t: String) -> ContentPart { .init(type: "text", text: t, image_url: nil) }
                static func imageURL(_ dataURL: String) -> ContentPart { .init(type: "image_url", text: nil, image_url: .init(url: dataURL)) }
            }
            let role: String
            // String for simple messages, [ContentPart] when images are present.
            let content: ContentValue
            enum ContentValue: Encodable {
                case string(String)
                case parts([ContentPart])
                func encode(to encoder: Encoder) throws {
                    var c = encoder.singleValueContainer()
                    switch self {
                    case .string(let s): try c.encode(s)
                    case .parts(let p): try c.encode(p)
                    }
                }
            }
        }
        let model: String
        let messages: [Msg]
        let temperature: Double
        let max_tokens: Int?
        let stream: Bool
        let response_format: ResponseFormat?

        struct ResponseFormat: Encodable { let type: String } // "json_object"
    }

    struct ChatCompletionResponse: Decodable {
        struct Choice: Decodable { struct Msg: Decodable { let content: String? }; let message: Msg }
        struct Usage: Decodable { let prompt_tokens: Int; let completion_tokens: Int; let total_tokens: Int? }
        let choices: [Choice]
        let usage: Usage?
    }

    func makeBody(_ request: LLMRequest) -> ChatBody {
        let msgs: [ChatBody.Msg] = request.messages.map { m in
            if m.images.isEmpty {
                return .init(role: m.role.rawValue, content: .string(m.text))
            } else {
                var parts: [ChatBody.Msg.ContentPart] = []
                if !m.text.isEmpty { parts.append(.text(m.text)) }
                for d in m.images {
                    let b64 = d.base64EncodedString()
                    // CleanAPIs / Anthropic via OpenAI compat accepts data URLs.
                    let url = "data:image/png;base64,\(b64)"
                    parts.append(.imageURL(url))
                }
                return .init(role: m.role.rawValue, content: .parts(parts))
            }
        }
        return ChatBody(
            model: model,
            messages: msgs,
            temperature: request.temperature,
            max_tokens: request.maxTokens,
            stream: false,
            response_format: request.json ? .init(type: "json_object") : nil
        )
    }

    func retryDelay(for err: HTTPError, attempt: Int) -> Double {
        // Respect Retry-After if present in body.
        if let data = err.body.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let retryAfter = obj["retry_after"] as? Double { return retryAfter }
        // Otherwise exponential backoff: 2, 4, 8s + jitter, capped.
        let base = pow(2.0, Double(attempt + 1))
        return min(base + Double.random(in: 0...0.5), 20)
    }

    // MARK: - Key resolution

    /// Resolve the key without writing it to logs. Prefers the injected value,
    /// then env, then the opencode auth file (so `opencode auth` and Orbit share one key).
    func resolvedKey() -> String? {
        if let k = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty { return k }
        for envKey in ["CLEANAPIS_API_KEY", "CLEANAPI_API_KEY", "CLEAN_APIS_API_KEY"] {
            if let v = ProcessInfo.processInfo.environment[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
        }
        if let v = UserDefaults.standard.string(forKey: CleanAPIKeys.key)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
        if let fromFile = Self.keyFromAuthFile()?.trimmingCharacters(in: .whitespacesAndNewlines), !fromFile.isEmpty { return fromFile }
        return nil
    }

    /// Reads `~/.local/share/opencode/auth.json` → `cleanapis.key` (and legacy `cleanapi`).
    public static func keyFromAuthFile() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/share/opencode/auth.json",
            "\(home)/.config/opencode/auth.json",
        ]
        for path in candidates {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            for providerKey in ["cleanapis", "cleanapi"] {
                if let entry = obj[providerKey] as? [String: Any], let k = entry["key"] as? String, !k.isEmpty { return k }
                if let entry = obj[providerKey] as? String, !entry.isEmpty { return entry }
            }
        }
        return nil
    }

    /// Redacted preview for diagnostics (e.g. "cc_HmCe…iLgLR").
    public var keyPreview: String? {
        guard let k = resolvedKey(), k.count > 8 else { return nil }
        return "\(k.prefix(6))…\(k.suffix(4))"
    }
}

// Single source of truth for CleanAPIs UserDefaults keys (used by provider + App).
public enum CleanAPIKeys {
    public static let key = "cleanapis_api_key"
    public static let model = "cleanapis_model"
    public static let baseURL = "cleanapis_base_url"
    public static let enabled = "cleanapis_enabled"
}
