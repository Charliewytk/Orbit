import Foundation

/// Talks to OpenCode's headless server (`opencode serve`) on the Mac.
///
/// OpenCode already has your model setup (its free models, or any accounts
/// you've connected), so Orbit just borrows it. Orbit sends each request as a
/// one-off session with OpenCode's coding tools switched off, so it only
/// ever answers questions and never touches files.
///
/// Server API used:
///   POST   /session                  → create a session
///   POST   /session/{id}/message     → send a prompt, get the reply parts
///   DELETE /session/{id}             → clean up
///   GET    /config/providers         → list models (health check + picker)
public struct OpenCodeProvider: LLMProvider {
    public let kind: LLMProviderKind = .opencode
    public var displayName: String { model.map { "OpenCode (\($0.modelID))" } ?? "OpenCode" }
    public let isLocal = false
    public var supportsVision: Bool

    public var baseURL: URL
    /// nil → OpenCode's own default model.
    public var model: ModelRef?
    public var http: HTTPClient
    /// Basic-auth password if you set OPENCODE_SERVER_PASSWORD.
    public var password: String?

    public struct ModelRef: Codable, Hashable, Sendable {
        public var providerID: String
        public var modelID: String
        public init(providerID: String, modelID: String) { self.providerID = providerID; self.modelID = modelID }
        /// Parses "provider/model", e.g. "opencode/big-pickle".
        public init?(_ s: String) {
            let parts = s.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            self.init(providerID: parts[0], modelID: parts[1])
        }
        public var string: String { "\(providerID)/\(modelID)" }
    }

    public init(baseURL: URL = URL(string: "http://127.0.0.1:4096")!, model: ModelRef? = nil,
                supportsVision: Bool = true, password: String? = nil,
                http: HTTPClient = HTTPClient(timeout: 240)) {
        self.baseURL = baseURL; self.model = model; self.supportsVision = supportsVision
        self.password = password; self.http = http
    }

    var headers: [String: String] {
        guard let password else { return [:] }
        return ["Authorization": "Basic " + Data("opencode:\(password)".utf8).base64EncodedString()]
    }

    // MARK: Models

    public struct ProviderInfo: Decodable, Sendable {
        public let id: String
        public let name: String?
        public let models: [String: ModelInfo]
    }
    public struct ModelInfo: Decodable, Sendable {
        public let id: String?
        public let name: String?
        public struct Cost: Decodable, Sendable { public let input: Double?; public let output: Double? }
        public let cost: Cost?
        public var isFree: Bool { (cost?.input ?? 0) == 0 && (cost?.output ?? 0) == 0 }
    }
    struct ProvidersResponse: Decodable { let providers: [ProviderInfo]; let `default`: [String: String]? }

    /// All models OpenCode can use, with free ones first.
    public func availableModels() async throws -> [(ref: ModelRef, name: String, free: Bool)] {
        let res = try await http.get(ProvidersResponse.self, baseURL.appendingPathComponent("config/providers"),
                                      headers: headers, timeout: 5)
        var out: [(ModelRef, String, Bool)] = []
        for p in res.providers {
            for (key, m) in p.models {
                out.append((ModelRef(providerID: p.id, modelID: m.id ?? key), m.name ?? key, m.isFree))
            }
        }
        return out.sorted { ($0.2 ? 0 : 1, $0.1) < ($1.2 ? 0 : 1, $1.1) }
    }

    public func isAvailable() async -> Bool {
        (try? await http.data("GET", baseURL.appendingPathComponent("config/providers"), headers: headers, timeout: 3)) != nil
    }

    // MARK: Prompting

    struct SessionCreate: Encodable { let title: String }
    struct Session: Decodable { let id: String }

    struct PartInput: Encodable {
        let type: String
        let text: String?
        let mime: String?
        let url: String?
        static func text(_ t: String) -> PartInput { .init(type: "text", text: t, mime: nil, url: nil) }
        static func image(_ d: Data) -> PartInput {
            .init(type: "file", text: nil, mime: "image/png", url: "data:image/png;base64," + d.base64EncodedString())
        }
    }

    struct PromptBody: Encodable {
        let model: ModelRef?
        let system: String?
        let tools: [String: Bool]
        let parts: [PartInput]
    }

    struct PromptResponse: Decodable {
        struct Part: Decodable { let type: String; let text: String? }
        let parts: [Part]
    }

    /// OpenCode's built-in coding tools, all switched off for Orbit's requests.
    static let disabledTools: [String: Bool] = Dictionary(uniqueKeysWithValues: [
        "bash", "edit", "write", "read", "glob", "grep", "list", "patch", "webfetch",
        "websearch", "todowrite", "todoread", "task", "multiedit", "lsp_diagnostics", "lsp_hover",
    ].map { ($0, false) })

    public func complete(_ request: LLMRequest) async throws -> String {
        let session = try await http.post(Session.self, baseURL.appendingPathComponent("session"),
                                          body: SessionCreate(title: "Orbit"), headers: headers, timeout: 10)
        defer {
            let url = baseURL.appendingPathComponent("session/\(session.id)")
            let h = headers, client = http
            Task { _ = try? await client.data("DELETE", url, headers: h, timeout: 5) }
        }

        // OpenCode sessions take one user turn at a time, so earlier turns are
        // folded into a transcript inside the prompt.
        let system = request.messages.filter { $0.role == .system }.map(\.text).joined(separator: "\n\n")
        let turns = request.messages.filter { $0.role != .system }
        var text = ""
        if turns.count > 1 {
            text += "Conversation so far:\n"
            for m in turns.dropLast() { text += "\n[\(m.role.rawValue)]\n\(m.text)\n" }
            text += "\n---\nReply to this latest message:\n"
        }
        text += turns.last?.text ?? ""
        if request.json { text += "\n\nRespond with only a JSON object. No prose, no markdown fences." }

        var parts: [PartInput] = [.text(text)]
        if supportsVision { parts += turns.flatMap(\.images).map(PartInput.image) }

        let body = PromptBody(model: model, system: system.isEmpty ? nil : system,
                              tools: Self.disabledTools, parts: parts)
        let res = try await http.post(PromptResponse.self,
                                      baseURL.appendingPathComponent("session/\(session.id)/message"),
                                      body: body, headers: headers)
        return res.parts.filter { $0.type == "text" }.compactMap(\.text).joined()
    }
}
