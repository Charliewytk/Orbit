import XCTest
@testable import OrbitCore

final class QuickAddParserTests: XCTestCase {
    typealias F = SchedFixtures
    /// Wednesday 7 October 2026, 10:00 BST.
    let now = SchedFixtures.date(2026, 10, 7, 10)
    var parser: QuickAddParser { QuickAddParser(now: now, timeZone: F.tz) }

    func testEssayPlanExample() {
        let r = parser.parse("essay plan for BEM2031, 2h, before Friday")
        XCTAssertEqual(r.task.title, "Essay plan")
        XCTAssertEqual(r.task.estimateMinutes, 120)
        XCTAssertEqual(r.task.moduleCode, "BEM2031")
        XCTAssertEqual(r.task.deadline, F.date(2026, 10, 9), "before Friday = before Friday starts")
        XCTAssertEqual(r.task.energy, .high)
        XCTAssertEqual(r.task.priority, .normal)
        XCTAssertEqual(r.deadlineText, "before Friday")
        XCTAssertEqual(r.estimateText, "2h")
        XCTAssertGreaterThanOrEqual(r.confidence, 0.8)
    }

    func testReadingExample() {
        let r = parser.parse("read ch3 45 mins tomorrow high priority")
        XCTAssertEqual(r.task.title, "Read ch3")
        XCTAssertEqual(r.task.estimateMinutes, 45)
        XCTAssertEqual(r.task.deadline, F.date(2026, 10, 8, 23, 59))
        XCTAssertEqual(r.task.priority, .high)
    }

    func testRevisionExample() {
        let r = parser.parse("revise stats by 12 Nov !!")
        XCTAssertEqual(r.task.title, "Revise stats")
        XCTAssertEqual(r.task.deadline, F.date(2026, 11, 12, 23, 59))
        XCTAssertEqual(r.task.priority, .high)
        XCTAssertEqual(r.task.energy, .high)
        XCTAssertFalse(r.hasExplicitEstimate)
        XCTAssertEqual(r.task.estimateMinutes, 60)
    }

    func testShortCall() {
        let r = parser.parse("call landlord 10m")
        XCTAssertEqual(r.task.title, "Call landlord")
        XCTAssertEqual(r.task.estimateMinutes, 10)
        XCTAssertEqual(r.task.energy, .low)
        XCTAssertNil(r.task.deadline)
        XCTAssertLessThanOrEqual(r.task.minBlockMinutes, 10)
    }

    func testRecurrenceIsIgnored() {
        let r = parser.parse("gym every monday at 7am")
        XCTAssertEqual(r.task.title, "Gym")
        XCTAssertNil(r.task.deadline)
        XCTAssertEqual(r.ignoredRecurrence, "every monday at 7am")
        XCTAssertEqual(parser.parse("stretch daily 10 mins").task.title, "Stretch")
    }

    func testEstimateFormats() {
        let cases: [(String, Int)] = [
            ("x 1.5h", 90), ("x 90m", 90), ("x half an hour", 30), ("x an hour and a half", 90),
            ("x 1h30", 90), ("x 1h 15m", 75), ("x 2 hours", 120), ("x 3 hrs", 180), ("x an hour", 60),
            ("x for 20 minutes", 20), ("x ~40min", 40), ("x 1 hour 30 mins", 90), ("x quarter of an hour", 15),
        ]
        for (text, minutes) in cases {
            let r = parser.parse(text)
            XCTAssertEqual(r.task.estimateMinutes, minutes, text)
            XCTAssertEqual(r.task.title, "X", text)
        }
    }

    func testDeadlineFormats() {
        let cases: [(String, Date)] = [
            ("x today", F.date(2026, 10, 7, 23, 59)),
            ("x tonight", F.date(2026, 10, 7, 23, 59)),
            ("x tomorrow", F.date(2026, 10, 8, 23, 59)),
            ("x by Friday", F.date(2026, 10, 9, 23, 59)),
            ("x before Friday 5pm", F.date(2026, 10, 9, 17)),
            ("x next week", F.date(2026, 10, 18, 23, 59)),
            ("x in 3 days", F.date(2026, 10, 10, 23, 59)),
            ("x by 12 Nov", F.date(2026, 11, 12, 23, 59)),
            ("x 12/11", F.date(2026, 11, 12, 23, 59)),
            ("x end of week", F.date(2026, 10, 9, 17)),
            ("x due on monday", F.date(2026, 10, 12, 23, 59)),
        ]
        for (text, date) in cases {
            let r = parser.parse(text)
            XCTAssertEqual(r.task.deadline, date, text)
            XCTAssertEqual(r.task.title, "X", text)
        }
    }

    func testPriorityMarkers() {
        XCTAssertEqual(parser.parse("urgent: email tutor").task.priority, .critical)
        XCTAssertEqual(parser.parse("urgent: email tutor").task.title, "Email tutor")
        XCTAssertEqual(parser.parse("urgent: email tutor").task.energy, .low)
        XCTAssertEqual(parser.parse("pay rent !!!").task.priority, .critical)
        XCTAssertEqual(parser.parse("tidy room low priority").task.priority, .low)
        XCTAssertEqual(parser.parse("tidy room low priority").task.title, "Tidy room")
        XCTAssertEqual(parser.parse("book dentist!").task.priority, .normal)
    }

    func testEnergyHints() {
        XCTAssertEqual(parser.parse("deep work on dissertation 3h").task.energy, .high)
        XCTAssertEqual(parser.parse("deep work on dissertation 3h").task.title, "Dissertation")
        XCTAssertEqual(parser.parse("on-call rota for Sam").task.title, "On-call rota for Sam")
        XCTAssertEqual(parser.parse("quick tidy of notes").task.energy, .low)
        XCTAssertEqual(parser.parse("quick tidy of notes").task.title, "Tidy of notes")
        XCTAssertEqual(parser.parse("quick tidy of notes").task.estimateMinutes, 20)
        XCTAssertEqual(parser.parse("focus: problem sheet 4").task.energy, .high)
        XCTAssertEqual(parser.parse("pick up parcel").task.energy, .medium)
    }

    func testModuleCodeCaseInsensitive() {
        let r = parser.parse("bem2031 seminar reading")
        XCTAssertEqual(r.task.moduleCode, "BEM2031")
        XCTAssertEqual(r.task.title, "Seminar reading")
        XCTAssertEqual(parser.parse("Lab write-up (ECM1400) by Thursday").task.moduleCode, "ECM1400")
        XCTAssertEqual(parser.parse("Lab write-up (ECM1400) by Thursday").task.title, "Lab write-up")
    }

    func testStartDate() {
        let r = parser.parse("work on dissertation from Monday, 3h")
        XCTAssertEqual(r.task.earliestStart, F.date(2026, 10, 12))
        XCTAssertNil(r.task.deadline)
        XCTAssertEqual(r.task.title, "Work on dissertation")
    }

    func testConfidence() {
        let bare = parser.parse("buy milk")
        let rich = parser.parse("essay plan for BEM2031, 2h, before Friday")
        XCTAssertGreaterThan(rich.confidence, bare.confidence)
        XCTAssertLessThan(parser.parse("2h tomorrow").confidence, bare.confidence)
    }

    func testEmptyTitleFallsBack() {
        let r = parser.parse("tomorrow")
        XCTAssertFalse(r.task.title.isEmpty)
        XCTAssertLessThan(r.confidence, 0.5)
    }
}
