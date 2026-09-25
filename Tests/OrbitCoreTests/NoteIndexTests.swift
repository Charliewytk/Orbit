import XCTest
@testable import OrbitCore

/// Embeds by counting a few concept words, so "levy" and "tax" land close together.
struct NoteIndexStubEmbedder: NoteEmbedder {
    func embed(_ texts: [String]) async throws -> [[Double]] {
        texts.map { t in
            let l = t.lowercased()
            return [l.contains("tax") || l.contains("levy") ? 1 : 0,
                    l.contains("elastic") ? 1 : 0,
                    l.contains("inflation") || l.contains("prices rising") ? 1 : 0]
        }
    }
}

final class NoteIndexTests: XCTestCase {
    let notes = [
        LectureNote(id: "n1", title: "Week 5 Market failure", moduleCode: "BEM2031", week: 5, segments: [
            NoteSegment(kind: .typed, text: "## Key points\n- A Pigouvian tax corrects negative externalities"),
            NoteSegment(kind: .handwriting, text: "The government sets the tax equal to marginal external cost at the optimum", confidence: 0.8),
        ]),
        LectureNote(id: "n2", title: "Week 3 Elasticity", moduleCode: "BEM2031", week: 3, segments: [
            NoteSegment(kind: .typed, text: "Price elasticity of demand measures responsiveness"),
            NoteSegment(kind: .handwriting, text: "Elastic goods: many substitutes. A tax on elastic goods raises little revenue"),
        ]),
        LectureNote(id: "n3", title: "Monetary policy", moduleCode: "BEM1002", week: 2, segments: [
            NoteSegment(kind: .typed, text: "Inflation targeting at 2% by the Bank of England"),
        ]),
    ]

    func testBM25RanksTheMostRelevantNoteFirst() {
        var index = NoteIndex()
        index.add(notes)
        let hits = index.search("pigouvian tax externalities")
        XCTAssertEqual(hits.first?.chunk.noteID, "n1")
        XCTAssertEqual(hits.first?.chunk.kind, .typed)
        XCTAssertTrue(hits.first!.chunk.heading.hasPrefix("Week 5 Market failure › Key points"))
        XCTAssertTrue(hits.contains { $0.chunk.noteID == "n2" }, "the elasticity note mentions tax too")
        XCTAssertFalse(hits.contains { $0.chunk.noteID == "n3" })

        XCTAssertEqual(index.search("elasticities").first?.chunk.noteID, "n2", "light stemming matches plurals")
        XCTAssertTrue(index.search("inflation", moduleCode: "BEM2031").isEmpty)
        XCTAssertEqual(index.search("inflation", moduleCode: "bem1002").first?.chunk.noteID, "n3")
        XCTAssertTrue(index.search("the of and").isEmpty, "stopwords alone match nothing")
    }

    func testReplacingAndRemovingNotesKeepsStatsConsistent() {
        var index = NoteIndex()
        index.add(notes)
        var edited = notes[2]
        edited.segments = [NoteSegment(kind: .typed, text: "Quantitative easing expands the money supply")]
        index.add(edited)
        XCTAssertTrue(index.search("inflation").isEmpty)
        XCTAssertEqual(index.search("quantitative easing").first?.chunk.noteID, "n3")
        index.remove(noteID: "n3")
        XCTAssertEqual(index.noteIDs, ["n1", "n2"])
        XCTAssertNil(index.docFreq["quantitative"])
    }

    func testChunksLongNotesWithOverlapAndHeadings() {
        let para = (1...40).map { "Sentence \($0) about consumer surplus and welfare." }.joined(separator: " ")
        let note = LectureNote(id: "long", title: "Welfare", segments: [
            NoteSegment(kind: .handwriting, text: "# Consumer surplus\n" + para + "\n# Producer surplus\nArea above supply curve"),
        ])
        let chunks = NoteIndex.chunk(note, size: 800, overlap: 150)
        XCTAssertGreaterThan(chunks.count, 2)
        XCTAssertTrue(chunks.allSatisfy { $0.text.count <= 800 })
        XCTAssertTrue(chunks[1].heading.hasSuffix("Lecture detail › Consumer surplus"))
        XCTAssertTrue(chunks.last!.heading.hasSuffix("Producer surplus"))
        // Overlap: the next chunk starts with the end of the previous one.
        let carried = chunks[1].text.components(separatedBy: "\n")[0]
        XCTAssertGreaterThan(carried.count, 50)
        XCTAssertTrue(chunks[0].text.hasSuffix(carried))
    }

    func testHybridSearchFindsSemanticMatchesAndRoundTrips() async throws {
        var index = NoteIndex()
        index.add(notes)
        let embedded = try await index.embedMissing(using: NoteIndexStubEmbedder(), batchSize: 2)
        XCTAssertEqual(embedded, index.chunks.count)

        let hits = await index.search("levy on pollution", embedder: NoteIndexStubEmbedder())
        XCTAssertEqual(hits.first?.chunk.noteID, "n1", "no keyword overlap, found by meaning")
        XCTAssertNotNil(hits.first?.semanticScore)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-index-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try index.save(to: url)
        let loaded = try NoteIndex.load(from: url)
        XCTAssertEqual(loaded.chunks, index.chunks)
        XCTAssertEqual(loaded.search("pigouvian").map(\.chunk.id), index.search("pigouvian").map(\.chunk.id))
    }

    func testSnippetCentresOnTheMatch() {
        let text = String(repeating: "filler words here ", count: 30) + "the Pigouvian tax fixes it " + String(repeating: "more filler ", count: 30)
        let s = NoteIndex.snippet(text, query: "pigouvian")
        XCTAssertTrue(s.contains("Pigouvian tax"))
        XCTAssertTrue(s.hasPrefix("…") && s.hasSuffix("…"))
        XCTAssertLessThanOrEqual(s.count, 222)
    }

    func testAnswerUsesPrivateDataAndCitesNotes() async throws {
        let cloud = MockLLMProvider(displayName: "cloud", isLocal: false) { _ in XCTFail("notes must stay local"); return "" }
        let local = MockLLMProvider(displayName: "local", isLocal: true) { req in
            XCTAssertEqual(req.purpose, .privateData)
            XCTAssertTrue(req.messages.last!.text.contains("[1] Week 5 Market failure (BEM2031, Week 5) — Key points"))
            return "A Pigouvian tax set equal to marginal external cost corrects the externality [1][2]. See also [9]."
        }
        var index = NoteIndex()
        index.add(notes)
        let answer = try await index.answer("How does a Pigouvian tax work?", using: LLMRouter(providers: [cloud, local]))
        XCTAssertTrue(answer.text.contains("[1]"))
        XCTAssertEqual(answer.citations.map(\.index), [1, 2])
        XCTAssertEqual(answer.citations.first?.title, "Week 5 Market failure")
        XCTAssertEqual(answer.citations.first?.moduleCode, "BEM2031")

        let none = try await NoteIndex().answer("anything?", using: LLMRouter(providers: [local]))
        XCTAssertTrue(none.citations.isEmpty)
    }
}
