import XCTest
@testable import OrbitCore

final class PlanTimeParserTests: XCTestCase {
    static let london = TimeZone(identifier: "Europe/London")!
    let parser = PlanTimeParser()

    static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = london
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    /// Wednesday 14 October 2026, 19:32 (BST): when the message was sent.
    let sent = PlanTimeParserTests.date(2026, 10, 14, 19, 32)

    func start(_ text: String, _ ref: Date? = nil) -> Date? { parser.parse(text, relativeTo: ref ?? sent)?.start }

    func testRelativeDaysAndTimes() {
        XCTAssertEqual(start("tomorrow at 7"), Self.date(2026, 10, 15, 19, 0))
        XCTAssertEqual(start("tmrw 8pm?"), Self.date(2026, 10, 15, 20, 0))
        XCTAssertEqual(start("sat 7pm"), Self.date(2026, 10, 17, 19, 0))
        XCTAssertEqual(start("Saturday night"), Self.date(2026, 10, 17, 20, 0))
        XCTAssertEqual(start("tonight"), Self.date(2026, 10, 14, 20, 0))
        XCTAssertEqual(start("fri?"), Self.date(2026, 10, 16, 12, 0))
        XCTAssertEqual(start("next fri at 6"), Self.date(2026, 10, 23, 18, 0))
        XCTAssertEqual(start("this fri 18:30"), Self.date(2026, 10, 16, 18, 30))
        XCTAssertEqual(start("brunch sunday"), Self.date(2026, 10, 18, 11, 0))
        XCTAssertEqual(start("dinner at 7"), Self.date(2026, 10, 14, 19, 0), "32 minutes ago still counts as today")
    }

    func testUKClockPhrases() {
        let morning = Self.date(2026, 10, 14, 9, 0)
        XCTAssertEqual(start("half 7", morning), Self.date(2026, 10, 14, 19, 30))
        XCTAssertEqual(start("half past 7 tomorrow morning"), Self.date(2026, 10, 15, 7, 30))
        XCTAssertEqual(start("quarter past 8", morning), Self.date(2026, 10, 14, 20, 15))
        XCTAssertEqual(start("quarter to eight", morning), Self.date(2026, 10, 14, 19, 45))
        XCTAssertEqual(start("7:30", morning), Self.date(2026, 10, 14, 19, 30))
        XCTAssertEqual(start("07:30 tomorrow"), Self.date(2026, 10, 15, 7, 30))
        XCTAssertEqual(start("meet at 7.30pm"), Self.date(2026, 10, 14, 19, 30))
        XCTAssertEqual(start("coffee at 10?", morning), Self.date(2026, 10, 14, 10, 0))
        XCTAssertEqual(start("noon", morning), Self.date(2026, 10, 14, 12, 0))
        XCTAssertEqual(start("noon tomorrow"), Self.date(2026, 10, 15, 12, 0))
        XCTAssertEqual(start("pub at 9"), Self.date(2026, 10, 14, 21, 0))
    }

    func testTimeOnlyRollsToTomorrowOnceItHasPassed() {
        // 7:30 (pm) was two hours before a 21:30 message, so it must mean tomorrow.
        XCTAssertEqual(start("7:30", Self.date(2026, 10, 14, 21, 30)), Self.date(2026, 10, 15, 19, 30))
        XCTAssertEqual(start("7:30", sent), Self.date(2026, 10, 14, 19, 30))
    }

    func testExplicitDates() {
        let earlyOct = Self.date(2026, 10, 10, 12, 0)
        XCTAssertEqual(start("on the 14th", earlyOct), Self.date(2026, 10, 14, 12, 0))
        XCTAssertEqual(start("on the 14th", Self.date(2026, 10, 20)), Self.date(2026, 11, 14, 12, 0))
        XCTAssertEqual(start("14/10 at 7:30", earlyOct), Self.date(2026, 10, 14, 19, 30))
        XCTAssertEqual(start("14/1", earlyOct), Self.date(2027, 1, 14, 12, 0))
        XCTAssertEqual(start("3/11/26 2pm", earlyOct), Self.date(2026, 11, 3, 14, 0))
        XCTAssertEqual(start("21st oct 8pm", earlyOct), Self.date(2026, 10, 21, 20, 0))
        XCTAssertEqual(start("Nov 2nd", earlyOct), Self.date(2026, 11, 2, 12, 0))
    }

    func testWeekendAndVaguePhrases() throws {
        let weekend = try XCTUnwrap(parser.parse("this weekend?", relativeTo: sent))
        XCTAssertEqual(weekend.start, Self.date(2026, 10, 17, 12, 0))
        XCTAssertTrue(weekend.isVague)
        XCTAssertLessThan(weekend.confidence, 0.4)

        let lectures = try XCTUnwrap(parser.parse("after lectures?", relativeTo: Self.date(2026, 10, 14, 10, 0)))
        XCTAssertEqual(lectures.start, Self.date(2026, 10, 14, 17, 0))
        XCTAssertTrue(lectures.isVague)
        XCTAssertFalse(lectures.hasTime)
        XCTAssertLessThan(lectures.confidence, 0.4)

        let exact = try XCTUnwrap(parser.parse("sat 7pm", relativeTo: sent))
        XCTAssertTrue(exact.hasDate && exact.hasTime && !exact.isVague)
        XCTAssertGreaterThan(exact.confidence, 0.8)
        XCTAssertEqual(exact.matchedText, "sat 7pm")
    }

    func testNoTimeMeansNil() {
        XCTAssertNil(start("I sat in the library all day"))
        XCTAssertNil(start("got 2 essays due, send help"))
        XCTAssertNil(start("it was £7.50 lol"))
        XCTAssertNil(start("haha yes"))
    }

    func testBritishSummerTimeEnds() {
        // Clocks go back on Sunday 25 October 2026: 7pm that day is 19:00 GMT.
        XCTAssertEqual(start("sun 7pm"), Self.date(2026, 10, 18, 19, 0))
        let later = start("sun 7pm", Self.date(2026, 10, 19, 9, 0))
        XCTAssertEqual(later, Date(timeIntervalSince1970: 1_792_954_800))   // 2026-10-25T19:00:00Z
    }
}
