import XCTest
@testable import OrbitCore

final class NoteMergerTests: XCTestCase {
    func handwriting() -> [TranscribedRegion] {
        [
            TranscribedRegion(regionID: "ink-1", bounds: InkRect(minX: 40, minY: 150, maxX: 600, maxY: 260),
                              segments: [NoteSegment(kind: .handwriting,
                                                     text: "Externalities cause market failure\nb/c costs fall on third partys",
                                                     confidence: 0.82)],
                              rawText: "", engines: ["Apple Vision"], escalated: false),
            TranscribedRegion(regionID: "ink-2", bounds: InkRect(minX: 40, minY: 300, maxX: 600, maxY: 420),
                              segments: [NoteSegment(kind: .handwriting, text: "Pigouvian tax corrects negative externalites = MEC",
                                                     confidence: 0.4, uncertainWords: ["Pigouvian"]),
                                         NoteSegment(kind: .math, text: "$t = MEC$", confidence: 0.9),
                                         NoteSegment(kind: .diagram, text: "[Diagram: tax wedge]", confidence: 0.7)],
                              rawText: "", engines: ["Apple Vision", "Vision model"], escalated: true),
        ]
    }

    func testOrdersByPositionAndLinksKeyPointsToHandwriting() {
        let doc = OneNoteHTMLParser.parse(NotesFixtures.pageHTML)
        let input = NotePageInput(id: "p1", title: nil, notebook: "Economics", section: "Lectures",
                                  modified: ISO8601.parse("2025-10-14T12:00:00Z"), document: doc, handwriting: handwriting(),
                                  imageDescriptions: [doc.blocks[1].src!: "Supply and demand graph with a tax"])
        let merged = NoteMerger().merge(input)
        let note = merged.note

        XCTAssertEqual(note.title, "BEM2031 Week 5 – Market failure")
        XCTAssertEqual(note.moduleCode, "BEM2031")
        XCTAssertEqual(note.week, 5)
        XCTAssertEqual(note.created, ISO8601.parse("2025-10-14T09:05:00Z"))

        // Title outline (top 53) → ink-1 (150) → ink-2 (300: text, maths, diagram) → key points (620) → image.
        XCTAssertEqual(note.segments.map(\.kind), [.typed, .handwriting, .handwriting, .math, .diagram, .typed, .diagram])
        XCTAssertEqual(note.segments[0].text, "Lecture 5")
        XCTAssertTrue(note.segments[5].text.hasPrefix("## Key points"))
        XCTAssertEqual(note.segments[6].text, "[Image: Supply and demand graph with a tax]")
        XCTAssertEqual(merged.layout.map(\.regionID), [nil, "ink-1", "ink-2", "ink-2", "ink-2", nil, nil])
        XCTAssertEqual(merged.layout[5].blockDataID, "keypts")
        XCTAssertNotNil(merged.layout[6].imageSrc)

        XCTAssertTrue(note.keyPoints.contains("Pigouvian tax corrects negative externalities"))
        XCTAssertTrue(note.fullDetail.contains("third partys"))

        // The key points block summarises both handwriting regions; "Lecture 5" summarises nothing.
        XCTAssertEqual(merged.links.links.count, 1)
        let link = merged.links.links[0]
        XCTAssertEqual(link.typedSegment, 5)
        XCTAssertEqual(link.regionIDs, ["ink-1", "ink-2"])
        XCTAssertEqual(link.handwritingSegments, [1, 2, 3, 4])
        XCTAssertEqual(merged.links.handwriting(forTyped: 5), [1, 2, 3, 4])
        XCTAssertEqual(merged.links.typed(forHandwriting: 1), [5])

        XCTAssertEqual(merged.lowConfidenceSegments, [2])
        XCTAssertTrue(merged.needsReview)
        XCTAssertEqual(merged.uncertainWords, ["Pigouvian"])
    }

    func testTypedOnlyPageWithoutPositionsKeepsDocumentOrder() {
        let doc = OneNoteHTMLParser.parse("<html><head><title>ECM1400 wk3</title></head><body><p>First</p><img src='x' alt='chart'/><p>Second</p></body></html>")
        let merged = NoteMerger(includeImages: false).merge(NotePageInput(id: "p", document: doc))
        XCTAssertEqual(merged.note.segments.map(\.text), ["First", "Second"])
        XCTAssertEqual(merged.note.moduleCode, "ECM1400")
        XCTAssertEqual(merged.note.week, 3)
        XCTAssertTrue(merged.links.links.isEmpty)
    }

    func testBuildRunsTheWholePipeline() async throws {
        let ink = try InkMLParser(pixelsPerUnit: 1).parse("""
        <ink><trace>50 100, 60 116, 70 100, 80 116, 90 100</trace><trace>100 100, 110 116, 120 100</trace></ink>
        """)
        let fetched = OneNoteFetchedPage(
            page: OneNotePage(id: "p9", title: "BEM2031 Week 6", lastModifiedDateTime: Date(timeIntervalSince1970: 1_760_000_000)),
            section: OneNoteSection(id: "s", displayName: "Lectures", notebookName: "Econ", groupPath: ["Term 1"]),
            content: OneNotePageContent(html: ""),
            document: OneNoteHTMLParser.parse(#"<body><div style="position:absolute;left:0;top:400px"><p>Demand falls</p></div></body>"#),
            ink: ink, images: [:])
        let stub = HandwritingStubOCR("Vision model", [("demand falls when price rises", 0.9)])
        let merged = try await NoteMerger().build(fetched, pipeline: HandwritingPipeline(primary: nil, fallback: stub,
                                                                                         renderer: InkRenderer(backend: .software)))
        XCTAssertEqual(merged.note.section, "Term 1 › Lectures")
        XCTAssertEqual(merged.note.notebook, "Econ")
        XCTAssertEqual(merged.note.segments.map(\.kind), [.handwriting, .typed])
        XCTAssertEqual(stub.hints.first??.contains("Demand falls"), true, "typed text is passed as a hint")
        XCTAssertEqual(merged.links.links.first?.regionIDs, ["ink-1"])
        XCTAssertEqual(merged.handwriting.first?.learnerRegion.ocrText, "demand falls when price rises")
    }
}
