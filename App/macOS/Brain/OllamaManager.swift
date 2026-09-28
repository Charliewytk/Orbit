import Foundation
import Observation
import OrbitCore

/// Ollama status and model downloads (via Ollama's own HTTP API, so no
/// terminal is needed).
@MainActor
@Observable
final class OllamaManager {
    struct Recommended: Identifiable, Hashable {
        var model: String
        var why: String
        var id: String { model }
    }

    static let recommended: [Recommended] = [
        Recommended(model: "qwen3:8b", why: "Backup chat and email sorting"),
        Recommended(model: "qwen2.5vl:7b", why: "Reads your handwriting"),
        Recommended(model: "nomic-embed-text", why: "Smart note search"),
    ]

    let baseURL = URL(string: "http://localhost:11434")!
    private(set) var available = false
    private(set) var installed: [String] = []
    private(set) var pulling: Set<String> = []
    var lastError: String?
    /// Last time Ollama answered (for the health check).
    private(set) var lastSeen: Date?
    private(set) var lastChecked: Date?

    func refresh() async {
        lastChecked = Date()
        do {
            installed = try await OllamaProvider(baseURL: baseURL).installedModels().sorted()
            available = true
            lastSeen = Date()
        } catch {
            installed = []
            available = false
        }
    }

    /// Recommended models that aren't downloaded yet.
    var missingRecommended: [String] { Self.recommended.map(\.model).filter { !isInstalled($0) } }

    func isInstalled(_ model: String) -> Bool {
        installed.contains { $0 == model || $0 == model + ":latest" || $0.hasPrefix(model + ":") && !model.contains(":") }
    }

    private struct PullBody: Encodable { let model: String; let stream: Bool }
    private struct PullReply: Decodable { let status: String? }

    /// Same as `ollama pull <model>`. Can take a while for big models.
    func pull(_ model: String) async {
        guard !pulling.contains(model) else { return }
        pulling.insert(model)
        defer { pulling.remove(model) }
        do {
            let reply = try await HTTPClient(timeout: 3 * 3600).post(
                PullReply.self, baseURL.appendingPathComponent("api/pull"), body: PullBody(model: model, stream: false))
            if let s = reply.status, s != "success" { lastError = "Ollama said: \(s)" } else { lastError = nil }
        } catch {
            lastError = "Couldn't download \(model): \(error)"
        }
        await refresh()
    }
}
