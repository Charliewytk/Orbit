import Foundation
#if canImport(Vision)
import Vision
#endif

// Convention shared by all engines: a word the engine wasn't sure about is
// written "[?word]" in the line text ("[?]" if it had no guess at all).
// `HandwritingPipeline` turns these markers into `NoteSegment.uncertainWords`.

// MARK: - Apple Vision

#if canImport(Vision)
/// First-pass OCR with Apple's Vision framework (on-device, fast, decent on handwriting).
public struct AppleVisionOCR: OCREngine {
    public var name: String { "Apple Vision" }
    public var languages: [String]
    /// Terms Vision should prefer, e.g. the personal vocabulary from `PersonalHandwritingProfile`.
    public var customWords: [String]
    /// Mark words where Vision's top two candidates disagree as "[?word]".
    public var markAmbiguousWords: Bool

    public init(languages: [String] = ["en-GB"], customWords: [String] = [], markAmbiguousWords: Bool = true) {
        self.languages = languages; self.customWords = customWords; self.markAmbiguousWords = markAmbiguousWords
    }

    public func recognize(image: Data, hint: String?) async throws -> OCRResult {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try recognizeNow(image)) } catch { cont.resume(throwing: error) }
            }
        }
    }

    func recognizeNow(_ image: Data) throws -> OCRResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        request.customWords = customWords
        let handler = VNImageRequestHandler(data: image, options: [:])
        try handler.perform([request])
        let observations = (request.results ?? []).sorted {
            // Top-to-bottom (Vision's y grows upwards), then left-to-right.
            abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.01
                ? $0.boundingBox.midY > $1.boundingBox.midY : $0.boundingBox.minX < $1.boundingBox.minX
        }
        var lines: [OCRLine] = []
        for obs in observations {
            let candidates = obs.topCandidates(2)
            guard let best = candidates.first else { continue }
            var text = best.string
            if markAmbiguousWords, candidates.count > 1 {
                text = Self.markDisagreements(best.string, candidates[1].string)
            }
            let b = obs.boundingBox
            // Vision boxes are normalised with a bottom-left origin; OCRLine wants top-left.
            lines.append(OCRLine(text: text, confidence: Double(best.confidence),
                                 box: [Double(b.minX), Double(1 - b.maxY), Double(b.width), Double(b.height)]))
        }
        return OCRResult(lines: lines, engine: name)
    }

    /// Wraps words of `best` that differ from the runner-up in "[?…]" (same word count only).
    static func markDisagreements(_ best: String, _ other: String) -> String {
        let a = best.split(separator: " "), b = other.split(separator: " ")
        guard a.count == b.count else { return best }
        return zip(a, b).map { $0.lowercased() == $1.lowercased() ? String($0) : "[?\($0)]" }.joined(separator: " ")
    }
}
#endif

// MARK: - Local vision model (Ollama)

/// The "clever" pass: a vision model via `LLMRouter` (purpose `.vision`, so a
/// local Ollama model is preferred). Handles messy writing, maths and diagrams.
public struct OllamaVisionOCR: OCREngine {
    public var name: String { "Vision model" }
    public var router: LLMRouter
    /// Module terms and names the student uses, to steer ambiguous readings.
    public var vocabulary: [String]
    public var purpose: LLMPurpose

    public init(router: LLMRouter, vocabulary: [String] = [], purpose: LLMPurpose = .vision) {
        self.router = router; self.vocabulary = vocabulary; self.purpose = purpose
    }

    public static let systemPrompt = """
    You transcribe a university student's handwritten lecture notes from an image.
    Rules:
    1. Transcribe exactly what is written, word for word. Do not summarise, correct, reorder or add anything.
    2. Keep the original line breaks: one handwritten line per output line.
    3. If a word is hard to read, write your best guess as [?guess]. If you cannot guess at all, write [?].
    4. Write maths as LaTeX between $ signs, for example $\\frac{dy}{dx} = 2x$.
    5. For a diagram, graph, table sketch or arrow chart, write one line: [Diagram: short description, including any labels].
    6. Keep the student's abbreviations and symbols as written (e.g. "w/", "b/c", "→", "∴").
    7. Output only the transcription. No introduction, no comments, no code fences.
    """

    func prompt(hint: String?) -> String {
        var s = "Transcribe this handwriting."
        if !vocabulary.isEmpty {
            s += "\nWords this student often uses (prefer these spellings when the writing matches): "
                + vocabulary.prefix(150).joined(separator: ", ")
        }
        if let hint, !hint.isEmpty { s += "\nContext (may help with hard words): \(hint.prefix(600))" }
        return s
    }

    public func recognize(image: Data, hint: String?) async throws -> OCRResult {
        let request = LLMRequest(messages: [.system(Self.systemPrompt), .user(prompt(hint: hint), images: [image])],
                                 purpose: purpose, temperature: 0)
        return Self.parse(try await router.complete(request), engine: name)
    }

    /// Turns the model's reply into lines, estimating confidence from "[?]" markers.
    public static func parse(_ reply: String, engine: String = "Vision model") -> OCRResult {
        // Drop code-fence lines ("```", "```text") wherever the model put them.
        var rawLines = reply.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !($0.hasPrefix("```") && !$0.dropFirst(3).contains(" ")) }
        // Drop a chatty first line such as "Here is the transcription:".
        if let first = rawLines.first(where: { !$0.isEmpty }), first.hasSuffix(":"),
           first.range(of: #"^(here|sure|transcription|the (handwritten )?text)"#, options: [.regularExpression, .caseInsensitive]) != nil {
            rawLines.remove(at: rawLines.firstIndex(of: first)!)
        }
        let lines = rawLines.filter { !$0.isEmpty }.map { line -> OCRLine in
            OCRLine(text: line, confidence: confidence(line))
        }
        return OCRResult(lines: lines, engine: engine)
    }

    /// 0.9 for a clean line, falling with the share of "[?]" words.
    static func confidence(_ line: String) -> Double {
        if line.hasPrefix("[Diagram") { return 0.7 }
        let words = line.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return 0 }
        let unsure = UncertainMarkers.count(in: line)
        return max(0.1, 0.9 * (1 - Double(unsure) / Double(words.count)))
    }
}

/// Finds and strips "[?word]" markers.
public enum UncertainMarkers {
    static let regex = try! NSRegularExpression(pattern: #"\[\?([^\]\s]*)\]"#)

    public static func count(in text: String) -> Int {
        regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// Returns the text with markers replaced by their guesses, and the uncertain words.
    /// A marker with no guess stays as "[?]".
    public static func strip(_ text: String) -> (text: String, uncertain: [String]) {
        var out = text
        var words: [String] = []
        for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(m.range, in: out), let g = Range(m.range(at: 1), in: text) else { continue }
            let word = String(text[g])
            if word.isEmpty { continue }
            words.append(word)
            out.replaceSubrange(whole, with: word)
        }
        return (out, words.reversed())
    }
}

// MARK: - External helper (TrOCR / Texify)

#if os(macOS) || os(Linux)
/// Runs the optional Python helper (`Tools/handwriting/orbit_ocr.py`) for TrOCR
/// or Texify. It must print JSON: `{"lines": [{"text": "…", "confidence": 0.8}]}`.
/// Not available on iOS (no `Process`).
public struct ExternalCommandOCR: OCREngine {
    public var name: String
    /// Usually the venv's python, e.g. ~/Library/Application Support/Orbit/ocr-venv/bin/python3.
    public var executable: URL
    /// Script path; nil if `executable` is the helper itself.
    public var script: URL?
    /// e.g. ["--math"] for Texify or ["--checkpoint", path] for a fine-tuned TrOCR.
    public var extraArguments: [String]
    public var timeout: TimeInterval

    public init(name: String = "TrOCR", executable: URL = URL(fileURLWithPath: "/usr/bin/python3"),
                script: URL?, extraArguments: [String] = [], timeout: TimeInterval = 120) {
        self.name = name; self.executable = executable; self.script = script
        self.extraArguments = extraArguments; self.timeout = timeout
    }

    public struct Failed: Error, CustomStringConvertible {
        public var status: Int32
        public var stderr: String
        public var description: String { "OCR helper failed (\(status)): \(stderr.prefix(300))" }
    }

    public func recognize(image: Data, hint: String?) async throws -> OCRResult {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-ocr-\(UUID().uuidString).png")
        try image.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var args = (script.map { [$0.path] } ?? []) + ["--image", tmp.path] + extraArguments
        if let hint, !hint.isEmpty { args += ["--hint", String(hint.prefix(300))] }
        let out = try await run(args)
        return try Self.parse(out, engine: name)
    }

    func run(_ arguments: [String]) async throws -> Data {
        let executable = executable, timeout = timeout
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = executable
                p.arguments = arguments
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do { try p.run() } catch { cont.resume(throwing: error); return }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                // Read before waiting so a full pipe can't deadlock the helper.
                let errBox = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { errBox.data = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                group.wait()
                killer.cancel()
                let errData = errBox.data
                if p.terminationStatus == 0 {
                    cont.resume(returning: data)
                } else {
                    cont.resume(throwing: Failed(status: p.terminationStatus, stderr: String(decoding: errData, as: UTF8.self)))
                }
            }
        }
    }

    /// Holds stderr read on another thread; the DispatchGroup orders the accesses.
    final class DataBox: @unchecked Sendable { var data = Data() }

    struct Output: Decodable {
        struct Line: Decodable { let text: String; let confidence: Double? }
        let lines: [Line]
        let engine: String?
    }

    static func parse(_ data: Data, engine: String) throws -> OCRResult {
        // Libraries sometimes print warnings to stdout; take the last JSON object.
        let text = String(decoding: data, as: UTF8.self)
        let jsonText = text.components(separatedBy: .newlines).reversed()
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") } ?? text
        let o = try JSONDecoder().decode(Output.self, from: Data(jsonText.utf8))
        return OCRResult(lines: o.lines.map { OCRLine(text: $0.text, confidence: $0.confidence ?? 0.5) },
                         engine: o.engine ?? engine)
    }
}
#endif
