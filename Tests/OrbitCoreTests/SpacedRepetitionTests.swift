import XCTest
@testable import OrbitCore

final class SpacedRepetitionTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSM2Intervals() {
        var card = Flashcard(front: "Q", back: "A", due: now)
        card = SpacedRepetition.review(card, grade: 4, now: now)
        XCTAssertEqual(card.intervalDays, 1)
        XCTAssertEqual(card.repetitions, 1)
        XCTAssertEqual(card.easeFactor, 2.5, accuracy: 1e-9) // grade 4 leaves ease unchanged
        XCTAssertEqual(card.due, now.addingTimeInterval(86400))

        card = SpacedRepetition.review(card, grade: 4, now: now)
        XCTAssertEqual(card.intervalDays, 6)
        card = SpacedRepetition.review(card, grade: 4, now: now)
        XCTAssertEqual(card.intervalDays, 15) // 6 × 2.5
        card = SpacedRepetition.review(card, grade: 5, now: now)
        XCTAssertEqual(card.easeFactor, 2.6, accuracy: 1e-9)
        XCTAssertEqual(card.intervalDays, 38) // round(15 × 2.5), then ease rises

        card = SpacedRepetition.review(card, grade: 2, now: now)
        XCTAssertEqual(card.repetitions, 0)
        XCTAssertEqual(card.intervalDays, 1)
        XCTAssertEqual(card.easeFactor, 2.28, accuracy: 1e-9)
    }

    func testEaseFloor() {
        var card = Flashcard(front: "Q", back: "A")
        for _ in 0..<10 { card = SpacedRepetition.review(card, grade: 0, now: now) }
        XCTAssertEqual(card.easeFactor, 1.3, accuracy: 1e-9)
    }

    func testLearningSteps() {
        var card = Flashcard(front: "Q", back: "A", due: now)
        card = SpacedRepetition.reviewWithLearningSteps(card, grade: 1, now: now)
        XCTAssertEqual(card.due, now.addingTimeInterval(600))
        XCTAssertEqual(card.intervalDays, 0)
        XCTAssertEqual(card.easeFactor, 2.5) // no penalty while learning

        card = SpacedRepetition.reviewWithLearningSteps(card, grade: 4, now: now)
        XCTAssertEqual(card.due, now.addingTimeInterval(86400))
        XCTAssertEqual(card.repetitions, 1)

        card = SpacedRepetition.reviewWithLearningSteps(card, grade: 4, now: now)
        XCTAssertEqual(card.intervalDays, 6)

        card = SpacedRepetition.reviewWithLearningSteps(card, grade: 1, now: now)
        XCTAssertEqual(card.due, now.addingTimeInterval(600)) // forgotten: back to the 10-minute step
        XCTAssertLessThan(card.easeFactor, 2.5)
    }

    func testDueCards() {
        let cards = [
            Flashcard(moduleCode: "A", front: "later", back: "", due: now.addingTimeInterval(3600)),
            Flashcard(moduleCode: "A", front: "old", back: "", due: now.addingTimeInterval(-86400)),
            Flashcard(moduleCode: "B", front: "now", back: "", due: now),
        ]
        XCTAssertEqual(SpacedRepetition.dueCards(cards, now: now).map(\.front), ["old", "now"])
        XCTAssertEqual(SpacedRepetition.dueCards(cards, now: now, moduleCode: "B").map(\.front), ["now"])
        XCTAssertEqual(SpacedRepetition.dueCards(cards, now: now, limit: 1).map(\.front), ["old"])
    }
}
