import XCTest
@testable import OrbitCore

struct StubFailure: Error {}

/// Returns a fixed result and counts calls.
final class HandwritingStubOCR: OCREngine, @unchecked Sendable {
    let name: String
    let result: OCRResult?
    private(set) var calls = 0
    private(set) var hints: [String?] = []

    init(_ name: String, _ lines: [(String, Double)]?) {
        self.name = name
        result = lines.map { OCRResult(lines: $0.map { OCRLine(text: $0.0, confidence: $0.1) }, engine: name) }
    }

    func recognize(image: Data, hint: String?) async throws -> OCRResult {
        calls += 1; hints.append(hint)
        guard let result else { throw StubFailure() }
        return result
    }
}

final class HandwritingPipelineTests: XCTestCase {
    func testOllamaVisionOCRPromptAndParsing() async throws {
        let mock = MockLLMProvider(displayName: "ollama-vision", isLocal: true, supportsVision: true) { req in
            XCTAssertEqual(req.purpose, .vision)
            XCTAssertEqual(req.messages.last?.images.count, 1)
            XCTAssertTrue(req.messages[0].text.contains("[?guess]"))
            XCTAssertTrue(req.messages[0].text.contains("[Diagram:"))
            XCTAssertTrue(req.messages.last!.text.contains("Pigouvian"))
            XCTAssertTrue(req.messages.last!.text.contains("Market failure"))
            return """
            Here is the transcription:
            ```
            Supply [?curve] shifts left

            $P = MC$
            [Diagram: supply and demand with a tax wedge]
            ```
            """
        }
        let ocr = OllamaVisionOCR(router: LLMRouter(providers: [mock]), vocabulary: ["Pigouvian"])
        let result = try await ocr.recognize(image: Data([1, 2, 3]), hint: "Market failure")
        XCTAssertEqual(result.lines.map(\.text), ["Supply [?curve] shifts left", "$P = MC$",
                                                 "[Diagram: supply and demand with a tax wedge]"])
        XCTAssertEqual(result.lines[0].confidence, 0.9 * (1 - 1.0 / 4), accuracy: 0.001)
        XCTAssertEqual(result.lines[1].confidence, 0.9)
        XCTAssertEqual(result.lines[2].confidence, 0.7)
    }

    func testUncertainMarkers() {
        let (text, words) = UncertainMarkers.strip("the [?elastic] demand [?] and [?curve].")
        XCTAssertEqual(text, "the elastic demand [?] and curve.")
        XCTAssertEqual(words, ["elastic", "curve"])
        XCTAssertEqual(UncertainMarkers.count(in: "a [?b] [?]"), 2)
    }

    func testConfidentPrimaryIsNotEscalated() async throws {
        let apple = HandwritingStubOCR("Apple Vision", [("Externalities cause market failure", 0.92)])
        let model = HandwritingStubOCR("Vision model", [("should not be used", 0.9)])
        let pipeline = HandwritingPipeline(primary: apple, fallback: model)
        let r = try await pipeline.transcribe(image: Data([0]), regionID: "r1")
        XCTAssertEqual(model.calls, 0)
        XCTAssertFalse(r.escalated)
        XCTAssertEqual(r.segments, [NoteSegment(kind: .handwriting, text: "Externalities cause market failure", confidence: 0.92)])
    }

    func testLowConfidenceEscalatesMergesAndClassifies() async throws {
        let apple = HandwritingStubOCR("Apple Vision", [("Externalities are costs or benefits", 0.7), ("MC - MB", 0.2)])
        let model = HandwritingStubOCR("Vision model", [
            ("Externalities are [?costs] or benefits", 0.6),
            ("Pigouvian [?tacks] fixes it", 0.6),
            ("$MC = MB$", 0.9),
            ("[Diagram: supply and demand]", 0.7),
            ("[?Welfare] loss", 0.45),
        ])
        var profile = PersonalHandwritingProfile()
        profile.recordCorrection(ocr: "tacks", correct: "tax", count: 2)
        let pipeline = HandwritingPipeline(primary: apple, fallback: model, profile: profile)
        let r = try await pipeline.transcribe(image: Data([0]), regionID: "r1", hint: "BEM2031")

        XCTAssertEqual(model.calls, 1)
        XCTAssertEqual(model.hints, ["BEM2031"])
        XCTAssertTrue(r.escalated)
        XCTAssertEqual(r.engines, ["Apple Vision", "Vision model"])
        XCTAssertEqual(r.segments.map(\.kind), [.handwriting, .math, .diagram, .handwriting])
        XCTAssertEqual(r.segments[0].text, "Externalities are costs or benefits\nPigouvian tax fixes it")
        XCTAssertEqual(r.segments[0].uncertainWords, [], "Vision agreed on 'costs'; the profile fixed 'tacks'")
        XCTAssertEqual(r.segments[1].text, "$MC = MB$")
        XCTAssertEqual(r.segments[3].uncertainWords, ["Welfare"])
        XCTAssertTrue(r.rawText.contains("[?tacks]"), "raw text keeps the misreading for learning")
    }

    func testFallsBackWhenPrimaryFailsAndThrowsWhenAllFail() async throws {
        let broken = HandwritingStubOCR("Apple Vision", nil)
        let model = HandwritingStubOCR("Vision model", [("Hello", 0.9)])
        let r = try await HandwritingPipeline(primary: broken, fallback: model).transcribe(image: Data(), regionID: "x")
        XCTAssertEqual(r.text, "Hello")

        do {
            _ = try await HandwritingPipeline(primary: broken, fallback: HandwritingStubOCR("m", nil))
                .transcribe(image: Data(), regionID: "x")
            XCTFail("expected failure")
        } catch HandwritingPipelineError.allEnginesFailed(let errors) {
            XCTAssertEqual(errors.count, 2)
        }
    }

    func testDiagramShapedInkEscalatesAndMathEngineRuns() async throws {
        let apple = HandwritingStubOCR("Apple Vision", [("x2 + y2", 0.9)])
        let model = HandwritingStubOCR("Vision model", [("$x^2 + y^2 = r^2$", 0.9)])
        let texify = HandwritingStubOCR("Texify", [("x^{2}+y^{2}=r^{2}", 0.8)])
        let pipeline = HandwritingPipeline(primary: apple, fallback: model, mathEngine: texify)
        let strokes = [
            InkStroke(id: "a", points: [InkPoint(x: 0, y: 0), InkPoint(x: 0, y: 200)]),
            InkStroke(id: "b", points: [InkPoint(x: 0, y: 200), InkPoint(x: 300, y: 200)]),
            InkMLParserTests.word(10, 210), InkMLParserTests.word(60, 210),
        ]
        let region = InkRegion(id: "r", strokes: strokes, lines: [InkRect(minX: 0, minY: 205, maxX: 100, maxY: 226)],
                               bounds: InkRect.union(strokes.map(\.bounds))!)
        let r = try await pipeline.transcribe(region)
        XCTAssertEqual(model.calls, 1, "diagram-like ink goes to the vision model")
        XCTAssertEqual(texify.calls, 1)
        XCTAssertEqual(r.segments, [NoteSegment(kind: .math, text: "$x^{2}+y^{2}=r^{2}$", confidence: 0.8)])
        XCTAssertNotNil(r.image, "rendered PNG kept")
        XCTAssertEqual(r.bounds, region.bounds)
    }

    #if os(macOS) || os(Linux)
    func testExternalCommandOCRReadsJSON() async throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("fake-ocr-\(UUID().uuidString).sh")
        try """
        #!/bin/sh
        echo "some warning from torch"
        echo '{"lines": [{"text": "Demand curve", "confidence": 0.81}, {"text": "shifts"}], "engine": "trocr"}'
        """.write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }
        let ocr = ExternalCommandOCR(executable: URL(fileURLWithPath: "/bin/sh"), script: script)
        let r = try await ocr.recognize(image: Data([1]), hint: nil)
        XCTAssertEqual(r.lines.map(\.text), ["Demand curve", "shifts"])
        XCTAssertEqual(r.lines.map(\.confidence), [0.81, 0.5])
        XCTAssertEqual(r.engine, "trocr")
    }
    #endif
}
