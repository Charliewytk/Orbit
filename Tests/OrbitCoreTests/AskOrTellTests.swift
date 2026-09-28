import XCTest
@testable import OrbitCore

final class AskOrTellTests: XCTestCase {
    func testQuestionsAsk() {
        XCTAssertEqual(AskOrTell.classify("What's my week like?"), .ask)
        XCTAssertEqual(AskOrTell.classify("when is the stats exam"), .ask)
        XCTAssertEqual(AskOrTell.classify("Lighten today"), .ask)
        XCTAssertEqual(AskOrTell.classify("quiz me on week 2"), .ask)
    }

    func testThingsToDoTell() {
        XCTAssertEqual(AskOrTell.classify("essay plan 2h by Fri"), .tell)
        XCTAssertEqual(AskOrTell.classify("call mum tomorrow 6pm"), .tell)
        XCTAssertEqual(AskOrTell.classify("island trip booking"), .tell)
        XCTAssertEqual(AskOrTell.classify(""), .tell)
    }
}
