import Foundation

public struct OCRLine: Codable, Hashable, Sendable {
    public var text: String
    /// 0–1.
    public var confidence: Double
    /// Normalised bounding box (0–1, origin top-left) if known.
    public var box: [Double]?
    public init(text: String, confidence: Double, box: [Double]? = nil) {
        self.text = text; self.confidence = confidence; self.box = box
    }
}

public struct OCRResult: Codable, Hashable, Sendable {
    public var lines: [OCRLine]
    public var engine: String
    public init(lines: [OCRLine], engine: String) { self.lines = lines; self.engine = engine }
    public var text: String { lines.map(\.text).joined(separator: "\n") }
    public var meanConfidence: Double {
        lines.isEmpty ? 0 : lines.map(\.confidence).reduce(0, +) / Double(lines.count)
    }
}

/// Reads text from an image (PNG/JPEG data). Implementations: Apple Vision,
/// a local vision model through Ollama, and optional open-source helpers.
public protocol OCREngine: Sendable {
    var name: String { get }
    func recognize(image: Data, hint: String?) async throws -> OCRResult
}
