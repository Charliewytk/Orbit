import XCTest
@testable import OrbitCore

final class NoteInsightsTests: XCTestCase {
    let note = LectureNote(id: "n1", title: "Week 5 Market failure", moduleCode: "BEM2031", week: 5, segments: [
        NoteSegment(kind: .handwriting, text: "Externalities are costs or benefits to third parties"),
        NoteSegment(kind: .typed, text: "- Pigouvian tax corrects negative externalities"),
    ])

    func testSummaryIsFiveBulletsFromAPrivatePrompt() async throws {
        let p = MockLLMProvider { req in
            XCTAssertEqual(req.purpose, .privateData)
            XCTAssertTrue(req.messages[0].text.contains("UK English"))
            let user = req.messages.last!.text
            XCTAssertLessThan(user.range(of: "KEY POINTS")!.lowerBound, user.range(of: "LECTURE DETAIL")!.lowerBound)
            return "Here you go:\n1. One\n2. Two\n- Three\n* Four\n• Five\n- Six"
        }
        let summary = try await NoteInsights.summarise(note, router: LLMRouter(providers: [p]))
        XCTAssertEqual(summary, "• One\n• Two\n• Three\n• Four\n• Five")
    }

    func testFlashcardsFromJSON() async throws {
        let p = MockLLMProvider { req in
            XCTAssertTrue(req.json)
            XCTAssertTrue(req.messages[0].text.contains("key points"))
            return """
            ```json
            {"cards": [
              {"front": "What does a Pigouvian tax correct?", "back": "Negative externalities."},
              {"front": "what does a pigouvian tax correct?", "back": "Duplicate"},
              {"front": "What is an externality?", "back": "A cost or benefit to a third party."},
              {"front": " ", "back": "empty front"}
            ]}
            ```
            """
        }
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let cards = try await NoteInsights.flashcards(from: note, router: LLMRouter(providers: [p]), now: now)
        XCTAssertEqual(cards.map(\.front), ["What does a Pigouvian tax correct?", "What is an externality?"])
        XCTAssertEqual(cards.first?.noteID, "n1")
        XCTAssertEqual(cards.first?.moduleCode, "BEM2031")
        XCTAssertEqual(cards.first?.due, now)
    }

    func testMaterialIsTrimmed() {
        let long = LectureNote(id: "x", title: "T", segments: [
            NoteSegment(kind: .handwriting, text: String(repeating: "word ", count: 5000)),
        ])
        let m = NoteInsights.material(long)
        XCTAssertLessThanOrEqual(m.count, NoteInsights.maxInputCharacters)
        XCTAssertTrue(m.contains("KEY POINTS (typed):\n(none)"))
    }
}
