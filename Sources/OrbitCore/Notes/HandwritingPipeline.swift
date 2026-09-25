import Foundation

/// One handwriting region after OCR, ready for `NoteMerger`.
public struct TranscribedRegion: Codable, Hashable, Sendable {
    public var regionID: String
    /// Page position (px), so the region can be ordered among typed blocks.
    public var bounds: InkRect?
    /// Handwriting, maths and diagram segments, top to bottom.
    public var segments: [NoteSegment]
    /// Engine output before personal corrections (with "[?…]" markers). Used for learning.
    public var rawText: String
    public var engines: [String]
    /// True if the vision model was asked because Apple Vision wasn't good enough.
    public var escalated: Bool
    /// The rendered PNG, kept for diagrams and training data.
    public var image: Data?

    public init(regionID: String, bounds: InkRect?, segments: [NoteSegment], rawText: String,
                engines: [String], escalated: Bool, image: Data? = nil) {
        self.regionID = regionID; self.bounds = bounds; self.segments = segments; self.rawText = rawText
        self.engines = engines; self.escalated = escalated; self.image = image
    }

    public var text: String { segments.map(\.text).joined(separator: "\n") }
    public var confidence: Double {
        segments.isEmpty ? 0 : segments.map(\.confidence).reduce(0, +) / Double(segments.count)
    }
}

public enum HandwritingPipelineError: Error, CustomStringConvertible, Sendable {
    case noEngine
    case renderFailed(String)
    case allEnginesFailed([String])

    public var description: String {
        switch self {
        case .noEngine: "No handwriting reader is set up"
        case .renderFailed(let id): "Couldn't draw ink region \(id)"
        case .allEnginesFailed(let errs): "Couldn't read handwriting: \(errs.joined(separator: "; "))"
        }
    }
}

/// Reads handwriting: Apple Vision first; if it's unsure (mean confidence below
/// `confidenceThreshold`) or the region looks like maths or a diagram, the local vision
/// model is asked too and the results merged. Personal corrections are applied last.
public struct HandwritingPipeline: Sendable {
    public var primary: OCREngine?
    public var fallback: OCREngine?
    /// Optional LaTeX specialist (Texify via `ExternalCommandOCR`) for maths regions.
    public var mathEngine: OCREngine?
    public var renderer: InkRenderer
    public var profile: PersonalHandwritingProfile?
    public var confidenceThreshold: Double
    /// Keep rendered PNGs on the results (for diagrams and fine-tuning data).
    public var keepImages: Bool

    public init(primary: OCREngine?, fallback: OCREngine? = nil, mathEngine: OCREngine? = nil,
                renderer: InkRenderer = InkRenderer(), profile: PersonalHandwritingProfile? = nil,
                confidenceThreshold: Double = 0.6, keepImages: Bool = true) {
        self.primary = primary; self.fallback = fallback; self.mathEngine = mathEngine; self.renderer = renderer
        self.profile = profile; self.confidenceThreshold = confidenceThreshold; self.keepImages = keepImages
    }

    /// Apple Vision (where available) backed by the vision model, both using the profile's vocabulary.
    public static func standard(router: LLMRouter, profile: PersonalHandwritingProfile? = nil,
                                mathEngine: OCREngine? = nil) -> HandwritingPipeline {
        let words = profile?.customWords ?? []
        #if canImport(Vision)
        let primary: OCREngine? = AppleVisionOCR(customWords: words)
        #else
        let primary: OCREngine? = nil
        #endif
        return HandwritingPipeline(primary: primary, fallback: OllamaVisionOCR(router: router, vocabulary: words),
                                   mathEngine: mathEngine, profile: profile)
    }

    // MARK: Transcribing

    public func transcribe(_ regions: [InkRegion], hint: String? = nil) async throws -> [TranscribedRegion] {
        var out: [TranscribedRegion] = []
        for r in regions { out.append(try await transcribe(r, hint: hint)) }
        return out
    }

    public func transcribe(_ region: InkRegion, hint: String? = nil) async throws -> TranscribedRegion {
        guard let png = renderer.render(region) else { throw HandwritingPipelineError.renderFailed(region.id) }
        return try await transcribe(image: png, regionID: region.id, bounds: region.bounds,
                                    features: region.features, hint: hint)
    }

    /// Reads an image directly (PDF pages, photos). `features` come from ink when known.
    public func transcribe(image: Data, regionID: String, bounds: InkRect? = nil,
                           features: InkRegionFeatures? = nil, hint: String? = nil) async throws -> TranscribedRegion {
        guard primary != nil || fallback != nil else { throw HandwritingPipelineError.noEngine }
        var engines: [String] = []
        var errors: [String] = []
        var first: OCRResult?
        if let primary {
            do { first = try await primary.recognize(image: image, hint: hint); engines.append(primary.name) }
            catch { errors.append("\(primary.name): \(error)") }
        }

        let diagramLike = features?.looksLikeDiagram ?? false
        let mathLike = first.map { Self.mathScore($0.text) > 0.2 } ?? false
        var missedLines = false
        if let found = first?.lines.count, let expected = features?.lineCount {
            missedLines = Double(found) < 0.5 * Double(expected)
        }
        let escalate = first == nil || first!.lines.isEmpty || first!.meanConfidence < confidenceThreshold
            || diagramLike || mathLike || missedLines

        var second: OCRResult?
        if escalate, let fallback {
            do { second = try await fallback.recognize(image: image, hint: hint); engines.append(fallback.name) }
            catch { errors.append("\(fallback.name): \(error)") }
        }
        guard var merged = Self.merge(first, second, threshold: confidenceThreshold) else {
            throw HandwritingPipelineError.allEnginesFailed(errors)
        }

        if let mathEngine, Self.isMostlyMath(merged),
           let latex = try? await mathEngine.recognize(image: image, hint: hint), !latex.lines.isEmpty {
            merged = OCRResult(lines: latex.lines.map {
                let t = $0.text.trimmingCharacters(in: .whitespaces)
                return OCRLine(text: t.hasPrefix("$") ? t : "$\(t)$", confidence: $0.confidence, box: $0.box)
            }, engine: merged.engine + "+" + mathEngine.name)
            engines.append(mathEngine.name)
        }

        return TranscribedRegion(regionID: regionID, bounds: bounds, segments: segments(from: merged),
                                 rawText: merged.text, engines: engines, escalated: escalate && second != nil,
                                 image: keepImages ? image : nil)
    }

    // MARK: Merging

    /// Prefers the vision model's reading (it copes with maths and diagrams), but clears
    /// its "[?word]" doubts where Apple Vision confidently read the same word.
    static func merge(_ a: OCRResult?, _ b: OCRResult?, threshold: Double) -> OCRResult? {
        guard let b, !b.lines.isEmpty else {
            if let a { return a }
            return b
        }
        guard let a, !a.lines.isEmpty else { return b }
        let confident = Set(a.lines.filter { $0.confidence >= threshold }
            .flatMap { $0.text.split(whereSeparator: \.isWhitespace).map { HandwritingTextNormalizer.key(String($0)) } })
        let aWords = Set(a.text.split(whereSeparator: \.isWhitespace).map { HandwritingTextNormalizer.key(String($0)) })
        let bWords = Set(b.text.split(whereSeparator: \.isWhitespace).map { HandwritingTextNormalizer.key(String($0)) })
        let agreement = bWords.isEmpty ? 0 : Double(aWords.intersection(bWords).count) / Double(aWords.union(bWords).count)
        let lines = b.lines.map { line -> OCRLine in
            let words = line.text.split(separator: " ", omittingEmptySubsequences: false).map { raw -> String in
                let w = PersonalHandwritingProfile.WordParts(String(raw))
                return w.uncertain && confident.contains(HandwritingTextNormalizer.key(w.core)) ? w.plain : String(raw)
            }
            let text = words.joined(separator: " ")
            let base = line.text.hasPrefix("[Diagram") ? line.confidence : OllamaVisionOCR.confidence(text)
            return OCRLine(text: text, confidence: min(0.97, max(base, line.confidence) + 0.1 * agreement), box: line.box)
        }
        return OCRResult(lines: lines, engine: a.engine + "+" + b.engine)
    }

    // MARK: Segments

    /// Applies personal corrections, pulls out "[?]" doubts, and groups lines by kind.
    func segments(from result: OCRResult) -> [NoteSegment] {
        var out: [NoteSegment] = []
        var pending: (kind: NoteSegmentKind, lines: [String], confs: [Double], unsure: [String])?
        func flush() {
            guard let p = pending else { return }
            out.append(NoteSegment(kind: p.kind, text: p.lines.joined(separator: "\n"),
                                   confidence: p.confs.reduce(0, +) / Double(max(p.confs.count, 1)),
                                   uncertainWords: p.unsure))
            pending = nil
        }
        for line in result.lines {
            let corrected = profile?.apply(to: line.text) ?? line.text
            let (text, unsure) = UncertainMarkers.strip(corrected)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let kind = Self.kind(of: trimmed)
            // If corrections resolved some doubts, confidence rises with the fewer markers left.
            let conf = UncertainMarkers.count(in: corrected) < UncertainMarkers.count(in: line.text)
                ? max(line.confidence, OllamaVisionOCR.confidence(corrected)) : line.confidence
            if pending?.kind != kind { flush(); pending = (kind, [], [], []) }
            pending!.lines.append(trimmed); pending!.confs.append(conf); pending!.unsure += unsure
        }
        flush()
        return out
    }

    static func kind(of line: String) -> NoteSegmentKind {
        if line.hasPrefix("[Diagram") { return .diagram }
        if line.hasPrefix("$") && line.hasSuffix("$") && line.count > 2 { return .math }
        let words = line.split(whereSeparator: \.isWhitespace).filter { $0.count > 2 && $0.allSatisfy(\.isLetter) }
        if mathScore(line) > 0.35 && words.count <= 2 { return .math }
        return .handwriting
    }

    static let mathSymbols: Set<Character> = [
        "=", "+", "−", "×", "÷", "^", "√", "∑", "∫", "∂", "∆", "Δ", "≤", "≥", "≠", "±", "∞", "π", "θ", "λ",
        "μ", "σ", "α", "β", "_", "{", "}", "\\", "$", "<", ">", "*", "/",
    ]

    /// Share of non-space characters that are maths symbols (digits count a third).
    static func mathScore(_ text: String) -> Double {
        var symbols = 0.0, total = 0.0
        for c in text where !c.isWhitespace {
            total += 1
            if mathSymbols.contains(c) { symbols += 1 } else if c.isNumber { symbols += 0.33 }
        }
        return total == 0 ? 0 : symbols / total
    }

    static func isMostlyMath(_ r: OCRResult) -> Bool {
        let kinds = r.lines.map { kind(of: $0.text.trimmingCharacters(in: .whitespaces)) }
        return !kinds.isEmpty && Double(kinds.filter { $0 == .math }.count) / Double(kinds.count) > 0.5
    }
}

extension InkRenderer {
    /// One PNG per written line of a region (for line-level training data).
    public func renderLines(_ region: InkRegion) -> [Data] {
        region.lines.compactMap { box in
            let strokes = region.strokes.filter {
                let b = $0.bounds
                return b.midY >= box.minY && b.midY <= box.maxY && b.maxX >= box.minX && b.minX <= box.maxX
            }
            return strokes.isEmpty ? nil : render(strokes, lineHeight: box.height)
        }
    }
}
