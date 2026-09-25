import Foundation

/// Talks to Ollama running on the Mac (default http://localhost:11434).
/// Free and fully offline. Used as the backup AI, for bulk jobs, for private
/// data, and (with a vision model) for reading handwriting.
public struct OllamaProvider: LLMProvider {
    public let kind: LLMProviderKind = .ollama
    public var displayName: String { "Ollama (\(model))" }
    public let isLocal = true
    public var supportsVision: Bool { visionModel != nil }

    public var baseURL: URL
    public var model: String
    public var visionModel: String?
    public var embeddingModel: String
    public var http: HTTPClient

    public init(baseURL: URL = URL(string: "http://localhost:11434")!, model: String = "qwen3:8b",
                visionModel: String? = "qwen2.5vl:7b", embeddingModel: String = "nomic-embed-text",
                http: HTTPClient = HTTPClient(timeout: 300)) {
        self.baseURL = baseURL; self.model = model; self.visionModel = visionModel
        self.embeddingModel = embeddingModel; self.http = http
    }

    struct Tags: Decodable { struct M: Decodable { let name: String }; let models: [M] }

    public func installedModels() async throws -> [String] {
        try await http.get(Tags.self, baseURL.appendingPathComponent("api/tags"), timeout: 3).models.map(\.name)
    }

    public func isAvailable() async -> Bool {
        guard let models = try? await installedModels() else { return false }
        return models.contains { $0 == model || $0.hasPrefix(model + ":") || model.hasPrefix($0) }
    }

    struct ChatBody: Encodable {
        struct Msg: Encodable { let role: String; let content: String; let images: [String]? }
        struct Options: Encodable { let temperature: Double; let num_predict: Int? }
        let model: String
        let messages: [Msg]
        let stream: Bool
        let format: String?
        let options: Options
        /// Qwen 3 "thinking" is slow and not needed for these jobs.
        let think: Bool?
    }

    struct ChatResponse: Decodable { struct Msg: Decodable { let content: String }; let message: Msg }

    public func complete(_ request: LLMRequest) async throws -> String {
        let hasImages = request.messages.contains { !$0.images.isEmpty }
        let useModel = hasImages ? (visionModel ?? model) : model
        let body = ChatBody(
            model: useModel,
            messages: request.messages.map {
                .init(role: $0.role.rawValue, content: $0.text,
                      images: $0.images.isEmpty ? nil : $0.images.map { $0.base64EncodedString() })
            },
            stream: false,
            format: request.json ? "json" : nil,
            options: .init(temperature: request.temperature, num_predict: request.maxTokens),
            think: useModel.hasPrefix("qwen3") ? false : nil
        )
        let res = try await http.post(ChatResponse.self, baseURL.appendingPathComponent("api/chat"), body: body)
        return Self.stripThinking(res.message.content)
    }

    /// Removes <think>…</think> blocks some models emit.
    static func stripThinking(_ s: String) -> String {
        var out = s
        while let a = out.range(of: "<think>"), let b = out.range(of: "</think>", range: a.upperBound..<out.endIndex) {
            out.removeSubrange(a.lowerBound..<b.upperBound)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct EmbedBody: Encodable { let model: String; let input: [String] }
    struct EmbedResponse: Decodable { let embeddings: [[Double]] }

    /// Text embeddings for note search (runs locally).
    public func embed(_ texts: [String]) async throws -> [[Double]] {
        guard !texts.isEmpty else { return [] }
        return try await http.post(EmbedResponse.self, baseURL.appendingPathComponent("api/embed"),
                                   body: EmbedBody(model: embeddingModel, input: texts)).embeddings
    }
}
